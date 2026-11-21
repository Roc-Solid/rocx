//! Components, rendered on the server: a page of them (`render_page`), a document for the browser
//! to hydrate (web/runtime.js's `hydrateDocument`), as web/runtime.js's `renderToString` renders
//! one in Node.
//!
//! A page's markup arrives as JSON (`Html.serialize!`, when the host runs the page's box), every
//! hole a computation Roc gave the host to keep (`keep!`). Rendering walks it (`html`), running each
//! hole once (`once`), with no tracking and nothing waiting: a memo is computed when it is made, and
//! a server function's call is answered by its route, in-process (`roc_call`: the app's `respond!`,
//! as for the browser's request), its answer noted for the page (`record!`). The answers go in a
//! script before `</body>`, with the script that starts the browser's side (`/rocx/start.js`).
//!
//! A failure (`fail!`, or reading a memo that failed) ends the computation that met it, as the JS
//! runtime throws `Failed`: the host jumps back to that computation's guard (`roc::fail`), and the
//! nearest `<Errored>` renders its fallback, given why. What the failed run allocated is freed (the
//! guard's list); what it had registered here (boxes, signals, memos, rows) is forgotten, unreleased,
//! since its memory is gone. A crash ends the render: the page is answered with 500.
//!
//! The markers are the runtime's, byte for byte: `<!--x-->…<!--/x-->` around a text hole,
//! `<!--html-->`, `<!--list-->`, `<!--show-->`, `<!--for-->` with `<!--row-->`s or a
//! `<!--fallback-->`, `<!--loading-->`, `<!--errored-->` (`<!--errored:failed-->` once it has).
//! A `<NoHydration>` is `<!--nohydration-->…<!--/nohydration-->`, and inside it there are none:
//! the browser never hydrates what is there, so it needs no markers, and finds the region's end by
//! the first `<!--/nohydration-->`. A server function called inside one isn't recorded for the
//! page: the browser never calls it.

use crate::abi::{RocErasedCallable as Callable, RocStr};
use crate::hosted::{self, Asked};
use crate::roc::{self, Crash};
use bytes::Bytes;
use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;

#[derive(Clone, Default)]
struct Scope {
    /// The value each context's nearest provider gives (its id), by the context's name.
    contexts: HashMap<String, u64>,
    /// Inside an element whose text the HTML parser reads as text, markup and comments too
    /// (RCDATA: `<title>`, `<textarea>`): holes write no comments there.
    rcdata: bool,
    /// Inside a `<NoHydration>`, which the browser never hydrates: holes write no comments there,
    /// what is called isn't recorded for the page, and a handler is refused (it would never run).
    region: bool,
}

/// The elements whose content the HTML parser reads as text (RCDATA): a hole inside one writes no
/// comments, which would show, and the browser binds it to the element's text.
const RCDATA: [&str; 2] = ["title", "textarea"];

/// `inner` between a hole's comments (`<!--label-->…<!--/label-->`), or as it is inside RCDATA or
/// a `<NoHydration>`.
fn marked(scope: &Scope, label: &str, inner: &str) -> String {
    if scope.rcdata || scope.region { inner.to_string() } else { format!("<!--{label}-->{inner}<!--/{label}-->") }
}

/// What is running: a hole (its scope; in an `<Errored>`'s fallback, what failed) or a memo.
struct Frame {
    scope: Scope,
    problem: Option<String>,
    memo: Option<u64>,
}

struct Memo {
    runner: Callable,
    value: Option<Callable>,
    next: Option<Callable>,
    failed: Option<String>,
}

#[derive(Default)]
struct List {
    indexes: HashMap<String, u64>,
    items: HashMap<String, Callable>,
}

/// Something registered with the host, so a failed run's can be forgotten.
enum Made {
    Kept(u64),
    Signal(u64),
    Memo(u64),
    List(u64),
    Item(u64, String),
}

/// A redirect (a status from 300 to 399, with its `location` and the cookies it sets, `name: value`
/// lines), which a page's render met in a server function's call, and answers with instead.
pub struct Redirect {
    pub status: u16,
    pub headers: String,
}

/// What rendering a page comes to: the document, or the redirect a call it made was answered with.
pub enum Rendered {
    Page(String),
    Redirect(Redirect),
}

#[derive(Default)]
struct Render {
    next_id: u64,
    kept: HashMap<u64, Callable>,
    signals: HashMap<u64, Callable>,
    memos: HashMap<u64, Memo>,
    lists: HashMap<u64, List>,
    made: Vec<Made>,
    frames: Vec<Frame>,
    /// Server functions' answers: name, input, answer (JSON).
    recorded: Vec<[String; 3]>,
    /// The flash a plain form's post came back with, if the page read it (`Server.flash!`).
    flash: Option<String>,
    /// The title the last `<Title>` rendered said, if one did (`Host.title!`): the page's `<head>`'s.
    title: Option<String>,
    /// The first redirect a server function's call was answered with as the page rendered (its
    /// middleware sending the visitor elsewhere): the page's answer instead.
    redirect: Option<Redirect>,
}

impl Render {
    fn id(&mut self) -> u64 {
        self.next_id += 1;
        self.next_id
    }

    /// Forgets what was registered since `mark`, unreleased: a failed run's, whose memory the
    /// guard freed.
    fn forget_since(&mut self, mark: usize) {
        for made in self.made.drain(mark..) {
            match made {
                Made::Kept(id) => drop(self.kept.remove(&id)),
                Made::Signal(id) => drop(self.signals.remove(&id)),
                Made::Memo(id) => drop(self.memos.remove(&id)),
                Made::List(id) => drop(self.lists.remove(&id)),
                Made::Item(list, key) => {
                    if let Some(list) = self.lists.get_mut(&list) {
                        list.items.remove(&key);
                    }
                }
            }
        }
    }

    /// Releases every box still held.
    fn release_all(self) {
        let boxes = self.kept.into_values().chain(self.signals.into_values());
        let memos = self.memos.into_values().flat_map(|memo| [Some(memo.runner), memo.value, memo.next].into_iter().flatten());
        let items = self.lists.into_values().flat_map(|list| list.items.into_values());
        for callable in boxes.chain(memos).chain(items) {
            roc::release(callable);
        }
    }
}

thread_local! {
    static RENDER: RefCell<Option<Render>> = const { RefCell::new(None) };
}

/// Runs `with` on the render this thread is doing, if any. The borrow ends before it returns:
/// nothing may call into Roc, or fail, while it lasts.
fn with<T>(with: impl FnOnce(&mut Render) -> T) -> Option<T> {
    RENDER.with(|slot| slot.borrow_mut().as_mut().map(with))
}

/// Why a hole didn't answer.
enum Stop {
    /// `fail!`, or a failed memo read: the nearest `<Errored>` shows it.
    Failed(String),
    /// Roc crashed, or the markup made no sense: the render ends.
    Crashed(String),
}

// ---- Rendering ----

/// The script that starts the browser's side of a page: it hydrates the document.
const START: &str = r#"<script type="module" data-rocx src="/rocx/start.js"></script>"#;

/// A page of components, rendered for the request the call answers (`hosted::asked`): the
/// document, `<!doctype html>` first (unless the page's markup begins with it), the answers its
/// server functions gave and the script that starts the browser's side just before `</body>`. Its
/// box is run at the root (`Page::mount`), its markup walked, and everything the render made
/// released, the page among it. A crash, or a failure no `<Errored>` catches, is the render's. A
/// server function's call that its middleware answered with a redirect (a signed-out visitor sent
/// to sign in) makes the page that redirect, caught or not, as SolidStart answers a redirect
/// thrown while it renders.
pub fn render_page(page: roc::Page) -> Result<Rendered, Crash> {
    begin(Render::default());
    let root = Scope::default();
    let walked = page.rendering(|| {
        guarded(Frame { scope: root.clone(), problem: None, memo: None }, || page.mount())
            .and_then(|json| parse(&json))
            .and_then(|markup| html(&markup, &root))
    });
    let mut render = end();
    let answers = std::mem::take(&mut render.recorded);
    let flash = render.flash.take();
    let title = render.title.take();
    let redirect = render.redirect.take();
    render.release_all();
    roc::drop_page(page);
    match (walked, redirect) {
        (Err(Stop::Crashed(why)), _) => Err(Crash(why)),
        (_, Some(redirect)) => Ok(Rendered::Redirect(redirect)),
        (Ok(markup), None) => Ok(Rendered::Page(document(&titled(&markup, title.as_deref()), &answers, flash.as_deref()))),
        (Err(Stop::Failed(why)), None) => Err(Crash(format!("{why} (with no <Errored> around it)"))),
    }
}

/// The markup with a `<Title>`'s title first in its `<head>` (web/runtime.js's `titled`): a
/// `<title data-rocx>` before the `<head>`'s first `<title>`, or before `</head>`; as it was with no
/// title, or no `<head>`. The host's own element, which hydration passes over, so the layout's
/// `<head>` hydrates as it rendered.
fn titled(markup: &str, title: Option<&str>) -> String {
    let (Some(title), Some(end)) = (title, markup.find("</head>")) else { return markup.to_string() };
    let own = markup[..end].match_indices("<title").find(|(at, _)| matches!(markup.as_bytes().get(at + 6), Some(b'>' | b' ' | b'\t' | b'\n' | b'\r' | b'\x0c')));
    let at = own.map(|(at, _)| at).unwrap_or(end);
    format!("{}<title data-rocx>{}</title>{}", &markup[..at], title.replace('&', "&amp;").replace('<', "&lt;"), &markup[at..])
}

/// The rendered markup as the document the browser gets: the flash the page read (if it did) and
/// the answers in scripts for the browser to read, and the bootstrap, before `</body>`.
fn document(markup: &str, answers: &[[String; 3]], flash: Option<&str>) -> String {
    let begun = markup.trim_start().get(..9).is_some_and(|start| start.eq_ignore_ascii_case("<!doctype"));
    let doctype = if begun { "" } else { "<!doctype html>" };
    let scripts = format!("{}{}{START}", flash.map(flash_script).unwrap_or_default(), answers_script(answers));
    match markup.rfind("</body>") {
        Some(at) => format!("{doctype}{}{scripts}{}", &markup[..at], &markup[at..]),
        None => format!("{doctype}{markup}{scripts}"),
    }
}

fn begin(render: Render) {
    RENDER.with(|slot| *slot.borrow_mut() = Some(render));
}

fn end() -> Render {
    RENDER.with(|slot| slot.borrow_mut().take()).unwrap_or_default()
}

/// Runs a call into Roc as the computation `frame` describes: its answer, or why it stopped.
fn guarded(frame: Frame, call: impl FnOnce() -> Result<String, Crash>) -> Result<String, Stop> {
    let mark = with(|render| {
        render.frames.push(frame);
        render.made.len()
    })
    .unwrap_or(0);
    let result = call();
    let failure = roc::take_failure();
    with(|render| render.frames.pop());
    match result {
        Ok(json) => Ok(json),
        Err(Crash(crashed)) => {
            with(|render| render.forget_since(mark));
            Err(match failure {
                Some(why) => Stop::Failed(why),
                None => Stop::Crashed(crashed),
            })
        }
    }
}

/// Runs a kept computation once.
fn once(id: &Value, scope: &Scope, problem: Option<String>) -> Result<String, Stop> {
    let id = id.as_u64().ok_or_else(|| Stop::Crashed("rocx: a hole without an id".into()))?;
    let Some(Some(callable)) = with(|render| render.kept.get(&id).copied()) else {
        return Err(Stop::Crashed(format!("rocx: no computation {id} is kept")));
    };
    guarded(Frame { scope: scope.clone(), problem, memo: None }, || roc::run(callable))
}

fn parse(json: &str) -> Result<Value, Stop> {
    serde_json::from_str(json).map_err(|error| Stop::Crashed(format!("rocx: the markup isn't JSON: {error}")))
}

const VOID: &[&str] = &["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"];

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// A JSON value as JS's `String(value)` would print it (a hole's text is a string; anything else
/// is printed as it is).
fn shown(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

/// JS's truthiness, for what a condition or a flag answers.
fn truthy(value: &Value) -> bool {
    match value {
        Value::Bool(yes) => *yes,
        Value::Null => false,
        Value::Number(number) => number.as_f64().is_some_and(|n| n != 0.0),
        Value::String(text) => !text.is_empty(),
        _ => true,
    }
}

fn children(node: &Value, scope: &Scope) -> Result<String, Stop> {
    let mut out = String::new();
    for child in node.get("c").and_then(Value::as_array).into_iter().flatten() {
        out.push_str(&html(child, scope)?);
    }
    Ok(out)
}

/// A node of the markup's JSON as HTML, every hole run once, with the comments hydration finds
/// holes by: web/runtime.js's `html`.
fn html(node: &Value, scope: &Scope) -> Result<String, Stop> {
    let kind = node.get("t").and_then(Value::as_str).unwrap_or("");
    let field = |name: &str| node.get(name).unwrap_or(&Value::Null);
    match kind {
        "s" => Ok(escape(field("v").as_str().unwrap_or(""))),
        // A <script>'s or <style>'s text, as rocx wrote it from the .rocx file: never data.
        "raw" => Ok(field("v").as_str().unwrap_or("").to_string()),
        "doctype" => Ok("<!doctype html>".to_string()),
        "x" => {
            let text = parse(&once(field("r"), scope, None)?)?;
            Ok(marked(scope, "x", &escape(&shown(&text))))
        }
        "h" | "l" => {
            let label = if kind == "h" { "html" } else { "list" };
            let parsed = parse(&once(field("r"), scope, None)?)?;
            let nodes = match parsed {
                Value::Array(nodes) => nodes,
                single => vec![single],
            };
            let mut inner = String::new();
            for child in &nodes {
                inner.push_str(&html(child, scope)?);
            }
            Ok(marked(scope, label, &inner))
        }
        "f" => children(node, scope),
        // On the server nothing waits: what is inside renders.
        "loading" => Ok(marked(scope, "loading", &children(node, scope)?)),
        "show" => {
            let holds = truthy(&parse(&once(field("r"), scope, None)?)?);
            let shown = if !holds {
                html(field("fallback"), scope)?
            } else if node.get("with").is_some() {
                html(&parse(&once(field("with"), scope, None)?)?, scope)?
            } else {
                children(node, scope)?
            };
            Ok(marked(scope, "show", &shown))
        }
        "for" => {
            let list = field("id").as_u64().unwrap_or(0);
            let entries = parse(&once(field("r"), scope, None)?)?;
            let mut rows = String::new();
            let mut count = 0;
            for (index, entry) in entries.as_array().into_iter().flatten().enumerate() {
                let key = entry.get("k").and_then(Value::as_str).unwrap_or("").to_string();
                with(|render| render.lists.entry(list).or_default().indexes.insert(key, index as u64));
                let row = parse(&once(entry.get("r").unwrap_or(&Value::Null), scope, None)?)?;
                rows.push_str(&marked(scope, "row", &html(&row, scope)?));
                count += 1;
            }
            if count == 0 {
                rows = marked(scope, "fallback", &html(field("fallback"), scope)?);
            }
            Ok(marked(scope, "for", &rows))
        }
        "errored" => match children(node, scope) {
            Ok(inner) => Ok(marked(scope, "errored", &inner)),
            Err(Stop::Failed(problem)) => {
                let fallback = parse(&once(field("r"), scope, Some(problem))?)?;
                let shown = html(&fallback, scope)?;
                Ok(if scope.rcdata || scope.region { shown } else { format!("<!--errored:failed-->{shown}<!--/errored-->") })
            }
            Err(crashed) => Err(crashed),
        },
        "c" => html(&parse(&once(field("r"), scope, None)?)?, scope),
        // Rendered here only: static markup, in its markers (one inside another is its part).
        "nh" => {
            if scope.region || scope.rcdata {
                return children(node, scope);
            }
            let inner = Scope { region: true, ..scope.clone() };
            Ok(format!("<!--nohydration-->{}<!--/nohydration-->", children(node, &inner)?))
        }
        "ctx" => {
            let mut inner = scope.clone();
            let name = field("n").as_str().unwrap_or("").to_string();
            inner.contexts.insert(name, field("v").as_u64().unwrap_or(0));
            children(node, &inner)
        }
        "e" => {
            let tag = field("tag").as_str().unwrap_or("");
            let mut classes: Vec<String> = Vec::new();
            let mut attributes: Vec<String> = Vec::new();
            let mut styles: Vec<String> = Vec::new();
            for attribute in field("a").as_array().into_iter().flatten() {
                let part = |index: usize| attribute.get(index).unwrap_or(&Value::Null);
                let name = part(1).as_str().unwrap_or("");
                match part(0).as_str().unwrap_or("") {
                    "on" | "onk" | "frame" if scope.region => return Err(Stop::Crashed(in_region(tag, name))),
                    "v" if name == "class" => classes.push(shown(part(2))),
                    "v" if name == "style" => styles.push(shown(part(2))),
                    "v" => attributes.push(format!("{name}=\"{}\"", escape(&shown(part(2))))),
                    "o" => {
                        let value = shown(part(2));
                        if !value.is_empty() {
                            attributes.push(format!("{name}=\"{}\"", escape(&value)));
                        }
                    }
                    "ci" => {
                        if truthy(part(2)) {
                            classes.push(name.to_string());
                        }
                    }
                    "oo" => {
                        let value = shown(&parse(&once(part(2), scope, None)?)?);
                        if !value.is_empty() {
                            attributes.push(format!("{name}=\"{}\"", escape(&value)));
                        }
                    }
                    "sv" => {
                        let value = shown(part(2));
                        if !value.is_empty() {
                            styles.push(format!("{name}: {value}"));
                        }
                    }
                    "so" => {
                        let value = shown(&parse(&once(part(2), scope, None)?)?);
                        if !value.is_empty() {
                            styles.push(format!("{name}: {value}"));
                        }
                    }
                    "f" => {
                        if truthy(part(2)) {
                            attributes.push(name.to_string());
                        }
                    }
                    "vo" => {
                        let value = parse(&once(part(2), scope, None)?)?;
                        attributes.push(format!("{name}=\"{}\"", escape(&shown(&value))));
                    }
                    "fo" => {
                        if truthy(&parse(&once(part(2), scope, None)?)?) {
                            attributes.push(name.to_string());
                        }
                    }
                    "co" => {
                        if truthy(&parse(&once(part(2), scope, None)?)?) {
                            classes.push(name.to_string());
                        }
                    }
                    _ => {}
                }
            }
            if !classes.is_empty() {
                attributes.insert(0, format!("class=\"{}\"", escape(&classes.join(" "))));
            }
            if !styles.is_empty() {
                attributes.push(format!("style=\"{}\"", escape(&styles.join("; "))));
            }
            let open = format!("<{tag}{}>", attributes.iter().map(|attribute| format!(" {attribute}")).collect::<String>());
            let inner = if RCDATA.contains(&tag) { Scope { rcdata: true, ..scope.clone() } } else { scope.clone() };
            Ok(if VOID.contains(&tag) { open } else { format!("{open}{}</{tag}>", children(node, &inner)?) })
        }
        other => Err(Stop::Crashed(format!("rocx: unknown node {other}"))),
    }
}

/// Why a handler inside a `<NoHydration>` is refused (web/runtime.js's `inRegion`): the browser never
/// hydrates what is there, so it would never run.
fn in_region(tag: &str, event: &str) -> String {
    format!("rocx: <{tag} on:{event}> is inside <NoHydration>, which the browser never hydrates, so its handler would never run: render what has it outside <NoHydration>")
}

/// The flash a page read, as a script for the browser (web/runtime.js's `flashScript`): the
/// cookie's JSON as a JSON string, with nothing in it that could end the script.
fn flash_script(flash: &str) -> String {
    let json = serde_json::to_string(flash).unwrap_or_else(|_| "\"\"".into());
    format!("<script type=\"application/json\" class=\"rocx-flash\">{}</script>", json.replace('<', "\\u003c"))
}

/// The answers as a script for the page: JSON, with nothing in it that could end the script.
fn answers_script(answers: &[[String; 3]]) -> String {
    let json = serde_json::to_string(answers).unwrap_or_else(|_| "[]".into());
    format!("<script type=\"application/json\" class=\"rocx-answers\">{}</script>", json.replace('<', "\\u003c"))
}

// ---- What Roc asks of the host while it renders ----

fn taken(text: RocStr) -> String {
    let copy = text.as_str().to_owned();
    unsafe { text.decref(&roc::host()) };
    copy
}

fn given(text: &str) -> RocStr {
    RocStr::from_str(text, &roc::host())
}

const OUTSIDE: &str = "a signals effect outside a server render: components render in a page";

/// Registers a box under a new id, in `table`.
fn register(callable: Callable, made: fn(u64) -> Made) -> u64 {
    let registered = with(|render| {
        let id = render.id();
        match made(id) {
            Made::Signal(_) => render.signals.insert(id, callable),
            _ => render.kept.insert(id, callable),
        };
        render.made.push(made(id));
        id
    });
    match registered {
        Some(id) => id,
        None => {
            roc::release(callable);
            roc::fail(OUTSIDE.into())
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_keep(callable: Callable) -> u64 {
    register(callable, Made::Kept)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_new(value: Callable) -> u64 {
    register(value, Made::Signal)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_get(id: u64) -> Callable {
    match with(|render| render.signals.get(&id).copied()).flatten() {
        Some(value) => roc::retain(value),
        None => roc::fail("rocx: a signal was read after the part that made it went away".into()),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_signal_set(_id: u64, value: Callable) {
    roc::release(value);
    roc::fail("a signal is written in a handler, not while computing".into())
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_new(runner: Callable) -> u64 {
    let made = with(|render| {
        let id = render.id();
        render.memos.insert(id, Memo { runner, value: None, next: None, failed: None });
        render.made.push(Made::Memo(id));
        (id, render.frames.last().map(|frame| frame.scope.clone()).unwrap_or_default())
    });
    let Some((id, scope)) = made else {
        roc::release(runner);
        roc::fail(OUTSIDE.into())
    };
    // Computed now: on the server nothing waits.
    let computed = guarded(Frame { scope, problem: None, memo: Some(id) }, || roc::run(runner));
    let crashed = with(|render| {
        let memo = render.memos.get_mut(&id)?;
        match computed {
            Ok(_) => {
                memo.value = memo.next.take();
                None
            }
            // What the failed run made (its value among it) was freed with it.
            Err(Stop::Failed(why)) => {
                memo.next = None;
                memo.failed = Some(why);
                None
            }
            Err(Stop::Crashed(why)) => {
                memo.next = None;
                Some(why)
            }
        }
    })
    .flatten();
    if let Some(why) = crashed {
        roc::crash_outward(why)
    }
    id
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_done(value: Callable) {
    let replaced = with(|render| {
        let id = render.frames.last()?.memo?;
        let memo = render.memos.get_mut(&id)?;
        Some(memo.next.replace(value))
    })
    .flatten();
    match replaced {
        Some(previous) => {
            if let Some(previous) = previous {
                roc::release(previous);
            }
        }
        None => {
            roc::release(value);
            roc::fail("rocx: a memo's value outside its computation".into())
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_memo_get(id: u64) -> Callable {
    enum Read {
        Value(Callable),
        Failed(String),
        Missing,
    }
    let read = with(|render| match render.memos.get(&id) {
        Some(Memo { failed: Some(why), .. }) => Read::Failed(why.clone()),
        Some(Memo { value: Some(value), .. }) => Read::Value(*value),
        _ => Read::Missing,
    });
    match read {
        Some(Read::Value(value)) => roc::retain(value),
        Some(Read::Failed(why)) => roc::fail(why),
        _ => roc::fail("rocx: a memo was read before its value was in".into()),
    }
}

/// On the server nothing is computed again: a refresh is for the browser.
#[unsafe(no_mangle)]
pub extern "C" fn roc_refresh(probe: Callable) {
    roc::release(probe);
}

// A host effect that fails jumps out of its own frame too: what it holds that needs dropping is
// dropped first (`fail` takes the message by value).

/// A server function called while the server renders (`Server.local`): its route answers it, in
/// the app's `respond!`, in-process, as it answers the browser's `POST /rocx/call/<name>`. Its 200
/// answer is the call's; any other answer fails the caller with its status and text, which the
/// nearest `<Errored>` shows.
#[unsafe(no_mangle)]
pub extern "C" fn roc_call(name: RocStr, input: RocStr) -> RocStr {
    let (name, input) = (taken(name), taken(input));
    let answered = call_route(&name, &input);
    drop((name, input));
    match answered {
        Ok(answer) => given(&answer),
        Err(message) => roc::fail(message),
    }
}

/// The answer the app's `respond!` gives `POST /rocx/call/<name>` with `input`: the request the
/// running call answers made into the browser's call (its headers, cookies among them, and the
/// context the server started with; `origin` this host, JSON sent, anything accepted). The page's
/// render is set aside meanwhile: the call is a request of its own, and records nothing in it.
fn call_route(name: &str, input: &str) -> Result<String, String> {
    let Some(page) = hosted::asked() else {
        return Err(format!("{name} is called while the server answers no request"));
    };
    let mut headers: Vec<String> = page
        .headers
        .lines()
        .filter(|line| {
            let header = line.split_once(':').map_or(*line, |(header, _)| header).trim().to_ascii_lowercase();
            !matches!(header.as_str(), "accept" | "content-type" | "content-length" | "transfer-encoding" | "origin")
        })
        .map(str::to_string)
        .collect();
    let host = page.headers.lines().find_map(|line| line.split_once(": ").filter(|(header, _)| header.eq_ignore_ascii_case("host")).map(|(_, value)| value.to_string()));
    if let Some(host) = host {
        headers.push(format!("origin: http://{host}"));
    }
    headers.push("accept: */*".into());
    headers.push("content-type: application/json".into());
    let call = Asked::new("POST", format!("/rocx/call/{name}"), headers.join("\n"), Bytes::copy_from_slice(input.as_bytes()), page.started.clone(), page.dev);
    let render = RENDER.with(|slot| slot.borrow_mut().take());
    let answered = hosted::call_asking(call.clone(), || roc::respond(&call.method, &call.target, &call.headers, &call.body, &call.started));
    RENDER.with(|slot| *slot.borrow_mut() = render);
    match answered {
        Ok(answer) => {
            // Its middleware sent the visitor elsewhere: the page goes there too (the first such).
            if (300..400).contains(&answer.status) {
                let kept: Vec<&str> = answer
                    .headers
                    .lines()
                    .filter(|line| line.split_once(':').is_some_and(|(header, _)| matches!(header.trim().to_ascii_lowercase().as_str(), "location" | "set-cookie")))
                    .collect();
                if kept.iter().any(|line| line.to_ascii_lowercase().starts_with("location")) {
                    let redirect = Redirect { status: answer.status, headers: kept.join("\n") };
                    with(|render| {
                        render.redirect.get_or_insert(redirect);
                    });
                }
            }
            let (streams, page, forwards) = (answer.feed.is_some(), answer.page.is_some(), answer.forward.is_some());
            if let Some(feed) = answer.feed {
                roc::drop_feed(feed);
            }
            if let Some(page) = answer.page {
                roc::drop_page(page);
            }
            let text = match answer.bytes {
                Some(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
                None => answer.body,
            };
            match answer.status {
                200 if streams => Err(format!("{name} answered with a stream of events, not an answer")),
                200 if page => Err(format!("{name} answered with a page, not an answer")),
                200 if forwards => Err(format!("{name} answered with a body from elsewhere, not an answer")),
                200 => Ok(text),
                status => Err(format!("{status}: {text}")),
            }
        }
        Err(Crash(crashed)) => {
            crate::logging::error("rocx server: Roc crashed", &[("method", "POST".into()), ("target", format!("/rocx/call/{name}").into()), ("in_process", true.into()), ("error", crashed.as_str().into())]);
            Err(if page.dev { format!("500: Roc crashed: {crashed}") } else { "500: Something went wrong.".into() })
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_fail(why: RocStr) {
    roc::fail(taken(why))
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_event_value() -> RocStr {
    given("")
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_boundary() -> u64 {
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_problem() -> RocStr {
    let problem = with(|render| render.frames.last().and_then(|frame| frame.problem.clone())).flatten();
    given(&problem.unwrap_or_default())
}

/// A retry is a handler's: never on the server.
#[unsafe(no_mangle)]
pub extern "C" fn roc_retry(_id: u64) {}

#[unsafe(no_mangle)]
pub extern "C" fn roc_record(name: RocStr, input: RocStr, answer: RocStr) {
    let noted = [taken(name), taken(input), taken(answer)];
    // Called inside a <NoHydration>: the browser never calls it, so the page needn't carry it.
    with(|render| {
        if !render.frames.last().is_some_and(|frame| frame.scope.region) {
            render.recorded.push(noted)
        }
    });
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_for_new() -> u64 {
    let made = with(|render| {
        let id = render.id();
        render.lists.insert(id, List::default());
        render.made.push(Made::List(id));
        id
    });
    match made {
        Some(id) => id,
        None => roc::fail(OUTSIDE.into()),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_index(list: u64, key: RocStr) -> u64 {
    let key = taken(key);
    match with(|render| render.lists.get(&list).and_then(|list| list.indexes.get(&key).copied())).flatten() {
        Some(index) => index,
        None => {
            let message = format!("rocx: no row {key} in its list");
            drop(key);
            roc::fail(message)
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_set(list: u64, key: RocStr, value: Callable) {
    let key = taken(key);
    let replaced = with(|render| {
        let previous = render.lists.get_mut(&list)?.items.insert(key.clone(), value);
        render.made.push(Made::Item(list, key));
        Some(previous)
    })
    .flatten();
    match replaced {
        Some(Some(previous)) => roc::release(previous),
        Some(None) => {}
        None => {
            roc::release(value);
            roc::fail("rocx: a row of a list that isn't there".into())
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_row_get(list: u64, key: RocStr) -> Callable {
    let key = taken(key);
    match with(|render| render.lists.get(&list).and_then(|list| list.items.get(&key).copied())).flatten() {
        Some(value) => roc::retain(value),
        None => {
            let message = format!("rocx: no item for row {key}");
            drop(key);
            roc::fail(message)
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_value(value: Callable) -> u64 {
    register(value, Made::Kept)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_find(name: RocStr) -> u64 {
    let name = taken(name);
    with(|render| render.frames.last().and_then(|frame| frame.scope.contexts.get(&name).copied())).flatten().unwrap_or(0)
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_context_get(id: u64) -> Callable {
    match with(|render| render.kept.get(&id).copied()).flatten() {
        Some(value) => roc::retain(value),
        None => roc::fail("rocx: a context's value that isn't kept".into()),
    }
}

/// A request is a handler's, in the browser: never while the server renders.
#[unsafe(no_mangle)]
pub extern "C" fn roc_fetch(method: RocStr, url: RocStr, headers: RocStr, body: RocStr) -> RocStr {
    drop((taken(headers), taken(body)));
    let message = format!("{} {} is sent from the browser (a handler's); the server renders without it", taken(method), taken(url));
    roc::fail(message)
}

/// Listening is a handler's, in the browser: never while the server renders.
#[unsafe(no_mangle)]
pub extern "C" fn roc_listen(url: RocStr, handler: Callable) {
    drop(taken(url));
    roc::release(handler);
    roc::fail("events are listened to from the browser (a handler's); the server renders without them".into())
}

/// A timer is the browser's: rendering, the server starts none. Its handler is let go of, the
/// id is 0, and clearing it does nothing, so a component that starts one renders as it would.
#[unsafe(no_mangle)]
pub extern "C" fn roc_timeout(_ms: u64, handler: Callable) -> u64 {
    roc::release(handler);
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_interval(_ms: u64, handler: Callable) -> u64 {
    roc::release(handler);
    0
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_clear_timer(_id: u64) {}

/// A call of the page's own function (`Browser.call!`) is a handler's, in the browser: never while
/// the server renders.
#[unsafe(no_mangle)]
pub extern "C" fn roc_browser_call(name: RocStr, arg: RocStr) {
    let name = taken(name);
    drop(taken(arg));
    roc::fail(format!("Browser.call!(\"{name}\") is a handler's, in the browser; the server renders without it"))
}

// Effects and cleanups are the browser's: on the server none runs, as in Solid's, since nothing
// they would undo started. Their boxes are let go of.

#[unsafe(no_mangle)]
pub extern "C" fn roc_effect_new(effect: Callable) {
    roc::release(effect);
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_cleanup(cleanup: Callable) {
    roc::release(cleanup);
}

/// The flash Roc found in the request's cookie (`Server.flash!`): noted for the page being
/// rendered, which carries it to the browser, and given back.
#[unsafe(no_mangle)]
pub extern "C" fn roc_flash(found: RocStr) -> RocStr {
    let found = taken(found);
    if !found.is_empty() {
        with(|render| render.flash = Some(found.clone()));
    }
    given(&found)
}

/// The document's title, as a `<Title>` says it while the page renders: the last one rendered is
/// the page's (`titled`).
#[unsafe(no_mangle)]
pub extern "C" fn roc_title(title: RocStr) {
    let title = taken(title);
    with(|render| render.title = Some(title));
}

/// The runtime's form submissions are the browser's: none on the server.
#[unsafe(no_mangle)]
pub extern "C" fn roc_action(url: RocStr) {
    drop(taken(url));
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission(url: RocStr) -> RocStr {
    drop(taken(url));
    given("")
}

#[unsafe(no_mangle)]
pub extern "C" fn roc_submission_clear(url: RocStr) {
    drop(taken(url));
}
