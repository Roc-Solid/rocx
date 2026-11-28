//! Navigation on a phone (D-138): D-040's, as web/runtime.js does it, with a history of the app's
//! own in place of the browser's. Each function says which of runtime.js's it follows.
//!
//! - **Where the app is** (`Router.location!`) is a source: what reads it in markup or a memo runs
//!   again when it changes (the generated `Root`'s route memo, a layout's header), and a level that
//!   read it once (a component's body) is made anew (`read_once`, `remake_root`).
//! - **A navigation fetches the page's document** (`accept: text/html`, `x-rocx-navigate: 1`), as the
//!   browser's does, so the server runs the page's middleware: a guard's redirect (to `/login`) or a
//!   sign-in's (home) is followed by the HTTP client, and where it ended is where the app goes. Only
//!   what the document seeds is read of it, not its HTML: the answers its reads got (`rocx-answers`)
//!   and its flash (`rocx-flash`), so the new page's first frame asks the server for nothing.
//! - **The query alone changing** is made in place (`in_place`): no document, the reads whose URL
//!   changed ask their endpoints.
//! - **History**: an entry a navigation (its target and the scroll it was left at); Android's back
//!   goes to the one before (`back`), restoring its scroll; at the first, the app closes.
//! - **Leaving** (`Router.use_before_leave!`): its listeners are asked before each navigation and
//!   back, and may stop it (`Leave.prevent!`), or let it go later (`Leave.retry!`).
//! - **Elsewhere**: a link or `navigate!` to another site, a `mailto:`/`tel:` link, one with a
//!   `target`, or a document that isn't one of the app's pages opens in the system's browser
//!   (`Platform::open`).

use crate::engine::{self, Asked};
use crate::fx::HashMap;
use crate::http::Answered;
use crate::json::{self, Value};
use crate::url::Url;
use crate::{Level, log};
use std::collections::VecDeque;

/// One of the app's pages, as the route table has it: its path's segments, a `[param]` one `None`.
#[derive(Clone, Debug)]
pub struct Page {
    pub parts: Vec<Option<String>>,
}

/// An entry of the app's history: where it was (a target: path and query), and how far down the
/// screen was scrolled when it was left.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub target: String,
    pub hash: Option<String>,
    pub scroll: (f32, f32),
}

/// How a navigation goes (runtime.js's `navigate`'s options).
#[derive(Clone, Debug, Default)]
pub struct Options {
    pub replace: bool,
    pub scroll: bool,
    /// Back: the history entry it goes to.
    pub pop: Option<usize>,
    /// A `Leave.retry!(force)`'s: the leave listeners aren't asked.
    pub force: bool,
    /// Asked already (back, after its listeners let it go).
    pub asked: bool,
    /// A submission's answer bringing a page (D-119): kept where it is if it's the same.
    pub refresh: bool,
}

/// A document asked for by a form the runtime doesn't send (the browser posts it itself and loads
/// what comes back): its method, body and content type.
#[derive(Clone, Debug)]
pub struct Form {
    pub method: String,
    pub body: String,
    pub content_type: String,
}

/// What follows a navigation a submission's redirect started, once its page is in
/// (`sendSubmission`'s `finish`): the submission done, the reads the navigation kept read again.
#[derive(Clone, Debug)]
pub struct After {
    pub key: String,
    pub entry: u64,
    pub plain: bool,
    pub keys: Option<Vec<String>>,
    pub before: Vec<u64>,
}

/// The navigation on its way: its id (one overtaken is let go of when its answer comes), where it
/// goes, how, and what follows it.
struct Navigation {
    id: u64,
    url: Url,
    options: Options,
    after: Option<After>,
    first: bool,
    /// A form's post (its answer, if not a page of the app's, isn't for the system's browser).
    posted: bool,
    started: std::time::Instant,
}

/// A leave its listeners were asked about (`mayLeave`), kept a while for `Leave.retry!`.
#[derive(Clone)]
struct Leave {
    id: u64,
    url: Url,
    replace: bool,
    scroll: bool,
    delta: i64,
    prevented: bool,
}

/// A `use_before_leave!` listener: its box, and what it runs in; gone with its owner.
pub struct Listener {
    pub id: u64,
    pub runner: u64,
    pub scope: engine::Scope,
    pub owner: Option<u64>,
}

#[derive(Default)]
pub struct Nav {
    /// The route table's pages (`Router.app!`), and whether it was given.
    pub pages: Vec<Page>,
    pub has_table: bool,
    pub history: Vec<Entry>,
    pub index: usize,
    navigation: Option<Navigation>,
    /// How many navigations were committed (a submission's redirect is followed only if none was
    /// since it was sent).
    pub navigations: u64,
    pub routing: bool,
    /// The answers the document being committed carries, by `METHOD url\nbody`.
    pub answers: HashMap<String, String>,
    /// The flash the page came with (`Server.flash!`'s JSON), and what read it.
    pub flash: String,
    pub flash_readers: Vec<u64>,
    /// Levels that read the location once (`readOnce`), and whether the root did.
    pub once_levels: Vec<u64>,
    pub root_once: bool,
    left_from: Option<String>,
    refreshing: bool,
    /// What a submission's navigation read again from its document (`refreshKept`).
    refreshed: Option<Vec<u64>>,
    pub listeners: Vec<Listener>,
    leaves: VecDeque<Leave>,
    leave_asked: Option<u64>,
    /// Where the screen goes once this flush's views are applied (`Platform::scroll_to`).
    pub scroll_to: Option<(f32, f32)>,
    /// The `aria-current` the host set on each link it marks (`mark_links`).
    pub marked: HashMap<usize, Option<String>>,
    pub started: bool,
}

/// How many leaves are kept for a `Leave.retry!` (runtime.js's `LEAVES`).
const LEAVES: usize = 16;

// ---- Where the app is ----

/// A path and query as `Router.location!` gives it: a trailing slash dropped, no hash
/// (`Runtime.target`).
pub fn target(of: &str) -> String {
    let of = of.split('#').next().unwrap_or("");
    let (path, query) = match of.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (of, None),
    };
    let trimmed = if path.len() > 1 { path.trim_end_matches('/') } else { path };
    let trimmed = if trimmed.is_empty() { "/" } else { trimmed };
    match query {
        Some(query) => format!("{trimmed}?{query}"),
        None => trimmed.to_string(),
    }
}

/// The segments of a path, decoded; none for one that can't be.
fn segments(path: &str) -> Option<Vec<String>> {
    path.split('/').filter(|part| !part.is_empty()).map(decode).collect()
}

fn decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%' {
            let hex = std::str::from_utf8(bytes.get(at + 1..at + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            at += 3;
        } else {
            out.push(bytes[at]);
            at += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The route table's pages (`Runtime.routeTable`).
pub fn pages_of(table: &Value) -> Vec<Page> {
    table
        .get("pages")
        .and_then(Value::as_array)
        .map(|pages| {
            pages
                .iter()
                .filter_map(|page| page.get("path").and_then(Value::as_str))
                .map(|path| Page { parts: path.split('/').filter(|part| !part.is_empty()).map(|part| if part.starts_with('[') && part.ends_with(']') { None } else { Some(part.to_string()) }).collect() })
                .collect()
        })
        .unwrap_or_default()
}

/// Whether the app has a page at `path` (`routeOf`); with no route table, every path is one.
pub fn is_page(nav: &Nav, path: &str) -> bool {
    if !nav.has_table {
        return true;
    }
    let Some(segments) = segments(path) else { return false };
    nav.pages.iter().any(|page| page.parts.len() == segments.len() && page.parts.iter().zip(&segments).all(|(part, segment)| part.as_ref().is_none_or(|part| part == segment)))
}

/// Whether a link to `href` is where the app is (`"page"`), above it (`"true"`), or neither
/// (`linkMark`, D-086): its `aria-current`.
pub fn link_mark(href: &str, here: &str) -> Option<&'static str> {
    if !href.starts_with('/') || href.starts_with("//") {
        return None;
    }
    let wanted = target(href);
    let (path, query) = wanted.split_once('?').map(|(path, query)| (path.to_string(), query.to_string())).unwrap_or((wanted.clone(), String::new()));
    let (now, asked) = here.split_once('?').map(|(path, query)| (path.to_string(), query.to_string())).unwrap_or((here.to_string(), String::new()));
    if path == now {
        return (query.is_empty() || query == asked).then_some("page");
    }
    (query.is_empty() && path != "/" && now.starts_with(&format!("{path}/"))).then_some("true")
}

/// The app's URL now: its origin and the location.
fn here() -> Url {
    engine::with(|engine| Url::parse(&format!("{}{}", engine.origin.trim_end_matches('/'), engine.path)).unwrap_or_else(|| Url { origin: engine.origin.clone(), path: "/".into(), query: None, hash: None }))
}

fn origin() -> String {
    engine::with(|engine| Url::parse(&engine.origin).map(|url| url.origin).unwrap_or_else(|| engine.origin.clone()))
}

// ---- What a document seeds ----

/// The answers a page's document carries (`<script class="rocx-answers">`: `[[name, input,
/// answer]]`, by `name\ninput`) and its flash (`<script class="rocx-flash">`, a JSON string), read
/// from its text without parsing the rest of it (`seed`).
pub fn seeds(html: &str) -> (Vec<(String, String)>, Option<String>) {
    let script = |class: &str| -> Option<String> {
        let at = html.find(&format!("class=\"{class}\">"))?;
        let start = at + class.len() + 9;
        let end = html[start..].find("</script>")? + start;
        Some(html[start..end].to_string())
    };
    let answers = script("rocx-answers")
        .and_then(|text| json::parse(&text))
        .and_then(Value::into_array)
        .map(|list| {
            list.into_iter()
                .filter_map(|each| {
                    let each = each.into_array()?;
                    let (name, input, answer) = (each.first()?.as_str()?, each.get(1)?.as_str()?, each.get(2)?.as_str()?);
                    Some((format!("{name}\n{input}"), answer.to_string()))
                })
                .collect()
        })
        .unwrap_or_default();
    let flash = script("rocx-flash").and_then(|text| json::parse(&text)).and_then(|value| value.as_str().map(str::to_string));
    (answers, flash)
}

/// Whether an answer is one of the app's documents (`appDocument`): HTML, with rocx's start script.
/// Its build may be another than the app's (a server rebuilt since): the phone's code is what it
/// is, so that is only said.
fn app_document(answer: &Answered) -> bool {
    answer.header("content-type").is_some_and(|kind| kind.to_ascii_lowercase().starts_with("text/html")) && answer.body.contains("/rocx/start.js")
}

// ---- Starting ----

/// The app's first page (`start`): its document asked for, as a browser's first load asks for it,
/// and the app mounted once it is in, at where it ended (a guard's redirect followed), with what it
/// seeds. One that can't be had mounts the app at `path` all the same (its reads fail there, as they
/// would offline).
pub fn start(path: &str) {
    let url = Url::parse(&format!("{}{}", origin(), target(path))).unwrap_or_else(|| here());
    let id = engine::with(|engine| engine.next_id());
    engine::with(|engine| {
        engine.nav.navigation = Some(Navigation { id, url: url.clone(), options: Options::default(), after: None, first: true, posted: false, started: std::time::Instant::now() });
        engine.ask(Asked::Navigation(id), "GET", url.without_hash(), document_headers(), String::new());
    });
}

fn document_headers() -> Vec<(String, String)> {
    vec![("accept".into(), "text/html,application/xhtml+xml,*/*;q=0.8".into()), ("x-rocx-navigate".into(), "1".into())]
}

fn mount_first(answer: Option<Answered>, url: &Url) {
    let at = match &answer {
        Some(answer) if answer.redirected => Url::parse(&answer.url).filter(|ended| ended.origin == url.origin).unwrap_or_else(|| url.clone()),
        _ => url.clone(),
    };
    let target = target(&at.target());
    engine::with(|engine| {
        engine.path = target.clone();
        engine.nav.history = vec![Entry { target: target.clone(), hash: at.hash.clone(), scroll: (0.0, 0.0) }];
        engine.nav.index = 0;
        engine.nav.started = true;
        if let Some(answer) = &answer
            && app_document(answer)
        {
            let (answers, flash) = seeds(&answer.body);
            engine.nav.answers = answers.into_iter().collect();
            engine.nav.flash = flash.unwrap_or_default();
        }
    });
    engine::mount();
    engine::flush();
    engine::with(|engine| engine.nav.answers.clear());
}

// ---- Navigating ----

/// `Router.navigate!` (once the handler is done), a link, a GET form, a redirect: one of the app's
/// pages rendered in place from its document, anything else opened elsewhere (`navigate`).
pub fn navigate(to: &str, options: Options) {
    go(to, options, None, None);
}

/// A form the runtime doesn't send (one posting to a path no endpoint of the app's has, as the
/// browser posts it itself): its answer, followed, is the page the app goes to.
pub fn post(to: &str, form: Form) {
    go(to, Options { scroll: true, ..Options::default() }, Some(form), None);
}

/// A submission's redirect (`sendSubmission`): the page it goes to, then `after`.
pub fn follow(to: &str, after: After) {
    go(to, Options { scroll: true, refresh: true, ..Options::default() }, None, Some(after));
}

fn go(to: &str, options: Options, form: Option<Form>, after: Option<After>) {
    let base = here();
    let Some(url) = base.join(to) else {
        // `mailto:`, `tel:`, an app's scheme: the system's.
        open(to);
        finish_after(after);
        return;
    };
    if url.origin != base.origin {
        open(&url.href());
        finish_after(after);
        return;
    }
    // A place on this page (the hash alone changed): nothing to fetch.
    if form.is_none() && options.pop.is_none() && url.hash.is_some() && url.path == base.path && url.query == base.query {
        finish_after(after);
        return;
    }
    let mut options = options;
    if !options.force && !options.asked && !may_leave(&url, options.replace, options.scroll, 0) {
        finish_after(after);
        return;
    }
    // The page it is on, again: its entry replaced (a form's post pushes one, as a browser's does).
    if options.pop.is_none() && form.is_none() && url.without_hash() == base.without_hash() {
        options.replace = true;
    }
    if form.is_none() && in_place(&url, &options) {
        finish_after(after);
        return;
    }
    // Where it is scrolled to as it is left.
    if options.pop.is_none() {
        keep_scroll();
    }
    let id = engine::with(|engine| engine.next_id());
    let overtaken = engine::with(|engine| {
        let overtaken = engine.nav.navigation.take().and_then(|navigation| navigation.after);
        engine.nav.navigation = Some(Navigation { id, url: url.clone(), options, after, first: false, posted: form.is_some(), started: std::time::Instant::now() });
        let mut headers = document_headers();
        let (method, body) = match form {
            Some(form) => {
                headers.push(("content-type".into(), form.content_type));
                (form.method, form.body)
            }
            None => ("GET".to_string(), String::new()),
        };
        engine.ask(Asked::Navigation(id), &method, url.without_hash(), headers, body);
        overtaken
    });
    finish_after(overtaken);
    set_routing(true);
}

/// The query alone changed (`inPlace`): no document; the location committed, what read it runs
/// again (a read whose URL changed asks its endpoint), in one flush. Not when a level read the
/// location once, or something on the page failed: those are made anew from the page's document.
fn in_place(url: &Url, options: &Options) -> bool {
    let to = target(&url.target());
    let now = engine::with(|engine| engine.path.clone());
    engine::with(|engine| engine.nav.left_from = Some(now.clone()));
    if to == now || to.split('?').next() != now.split('?').next() {
        return false;
    }
    if reads_once() || !engine::failed_boundaries().is_empty() {
        return false;
    }
    let overtaken = engine::with(|engine| engine.nav.navigation.take().and_then(|navigation| navigation.after));
    finish_after(overtaken);
    set_routing(false);
    let started = std::time::Instant::now();
    if options.pop.is_none() {
        keep_scroll();
    }
    enter(url, options);
    engine::commit_location(&to);
    engine::flush();
    engine::with(|engine| engine.nav.navigations += 1);
    scrolled(options);
    log(Level::Info, &format!("rocx: navigated to {to} in place in {:.1} ms", started.elapsed().as_secs_f64() * 1000.0));
    true
}

/// The history entry a navigation lands on: back's (its index), the one it is on (replaced), or a
/// new one after it (those after it forgotten).
fn enter(url: &Url, options: &Options) {
    engine::with(|engine| {
        let nav = &mut engine.nav;
        let entry = Entry { target: target(&url.target()), hash: url.hash.clone(), scroll: (0.0, 0.0) };
        match options.pop {
            Some(at) if at < nav.history.len() => nav.index = at,
            _ if options.replace && !nav.history.is_empty() => {
                let at = nav.index.min(nav.history.len() - 1);
                nav.history[at] = entry;
            }
            _ => {
                nav.history.truncate(nav.index + 1);
                nav.history.push(entry);
                nav.index = nav.history.len() - 1;
            }
        }
    });
}

/// A navigation's document is in, or couldn't be had (`navigate`, after `pageFor`).
pub fn answered(id: u64, result: Result<Answered, String>) {
    let navigation = engine::with(|engine| {
        if engine.nav.navigation.as_ref().is_some_and(|navigation| navigation.id == id) { engine.nav.navigation.take() } else { None }
    });
    // Overtaken by a newer one, which finished what this one would have.
    let Some(navigation) = navigation else { return };
    if navigation.first {
        let answer = match result {
            Ok(answer) => Some(answer),
            Err(why) => {
                log(Level::Error, &format!("rocx: the app's first page couldn't be had: {why}"));
                None
            }
        };
        mount_first(answer, &navigation.url);
        log(Level::Info, &format!("rocx: the first page's document in and mounted in {:.1} ms", navigation.started.elapsed().as_secs_f64() * 1000.0));
        return;
    }
    let Navigation { url, options, after, started, posted, .. } = navigation;
    let answer = match result {
        Ok(answer) => answer,
        Err(why) => {
            // Offline, or the server down: the browser would show its error page. The app goes there
            // all the same, its reads failing where it shows them (its <Errored>).
            log(Level::Error, &format!("rocx: navigating to {}: {why}", url.target()));
            set_routing(false);
            if engine::with(|engine| is_page(&engine.nav, &url.path)) {
                enter(&url, &options);
                engine::with(|engine| engine.nav.navigations += 1);
                commit(None, &target(&url.target()), options.refresh);
                scrolled(&options);
            }
            finish_after(after);
            return;
        }
    };
    // Where it ended: a redirect's address, but one that only adds the trailing slash is the link's.
    let mut at = url.clone();
    if answer.redirected
        && let Some(ended) = Url::parse(&answer.url)
        && !(ended.origin == url.origin && ended.path == format!("{}/", url.path) && ended.query == url.query)
    {
        at = Url { hash: url.hash.clone(), ..ended };
    }
    let ours = at.origin == url.origin && engine::with(|engine| is_page(&engine.nav, &at.path));
    if !ours || !app_document(&answer) {
        set_routing(false);
        // Not one of the app's pages (another site's, a file, a page of a plugin's): the system's
        // browser has it, as the browser would load it.
        if at.origin != url.origin || (answer.status < 400 && !(posted && !answer.redirected)) {
            open(&at.href());
        } else {
            log(Level::Warn, &format!("rocx: {} answered {} with what isn't one of the app's pages", at.target(), answer.status));
        }
        finish_after(after);
        return;
    }
    let to = target(&at.target());
    // A submission's answer bringing back the page it is on (D-119): kept where it is, its scroll too.
    let stays = options.refresh && to == engine::with(|engine| engine.path.clone());
    enter(&at, &options);
    engine::with(|engine| engine.nav.navigations += 1);
    // A view transition, where the app asked for one (D-040 §5.3, D-142): the next render pictures
    // the page left before it changes.
    if !stays {
        crate::native::page_transition();
    }
    commit(Some(&answer.body), &to, options.refresh);
    if !stays {
        scrolled(&options);
    }
    log(Level::Info, &format!("rocx: navigated to {to} in {:.1} ms ({}{})", started.elapsed().as_secs_f64() * 1000.0, answer.status, if answer.redirected { ", redirected" } else { "" }));
    finish_after(after);
}

/// A fetched document made the page (`commit`): its answers and flash seeded, the location
/// committed, the root kept or made anew (`remake_root`), one flush, then what the navigation kept
/// reads again what the document answered otherwise (`refresh_kept`). The answers are let go of
/// after.
fn commit(document: Option<&str>, to: &str, refresh: bool) {
    let (answers, flash) = document.map(seeds).unwrap_or_default();
    let (flash_before, before) = engine::with(|engine| {
        let flash_before = std::mem::take(&mut engine.nav.flash);
        engine.nav.answers = answers.into_iter().collect();
        engine.nav.flash = flash.unwrap_or_default();
        engine.nav.refreshing = refresh;
        (flash_before, engine.readers_now())
    });
    set_routing(false);
    let same = engine::with(|engine| engine.path == to);
    if same {
        engine::schedule_location();
    }
    engine::commit_location(to);
    if remake_root(to) {
        engine::remake_root();
    }
    engine::flush();
    refresh_kept(&before, &flash_before);
    engine::with(|engine| {
        engine.nav.refreshing = false;
        engine.nav.answers.clear();
    });
}

/// Whether the root runs again, the whole app made anew (`remakeRoot`): when the root read the
/// location once, or the page on screen is navigated to again. Otherwise the levels that read it
/// once are made anew, and a boundary that showed its fallback is tried again once they are there.
fn remake_root(to: &str) -> bool {
    let (previous, root_once, refreshing) = engine::with(|engine| (engine.nav.left_from.take(), engine.nav.root_once, engine.nav.refreshing));
    let kept = !(root_once || (previous.as_deref() == Some(to) && !refreshing));
    if !kept {
        if root_once {
            made_anew("the root layout");
        }
        engine::with(|engine| {
            engine.nav.root_once = false;
            engine.nav.once_levels.clear();
        });
        return true;
    }
    let failed = engine::failed_boundaries();
    let levels = engine::with(|engine| std::mem::take(&mut engine.nav.once_levels));
    for level in levels {
        engine::remake_level(level);
    }
    if !failed.is_empty() {
        engine::flush();
        for boundary in failed {
            engine::retry_failed(boundary);
        }
    }
    false
}

fn made_anew(what: &str) {
    log(Level::Info, &format!("rocx: {what} was made anew: it read Router.location! once, in its body, and the location changed. Read it where it is used (in markup, or a memo) for it to be kept across navigations (D-040)"));
}

/// After a navigation's flush, the computations it kept read again what its document answered
/// otherwise (`refreshKept`), and what reads the flash runs again if another came.
fn refresh_kept(before: &[u64], flash_before: &str) {
    let mut refreshed = Vec::new();
    let mut again = false;
    for &computation in before {
        let Some(reads) = engine::reads_of(computation) else { continue };
        let all = engine::with(|engine| reads.iter().all(|(key, _)| engine.nav.answers.contains_key(key)));
        if reads.is_empty() || !all {
            continue;
        }
        refreshed.push(computation);
        let differ = engine::with(|engine| reads.iter().any(|(key, value)| engine.nav.answers.get(key) != value.as_ref()));
        if differ {
            engine::read_again(computation, reads.iter().map(|(key, _)| key.clone()).collect());
            again = true;
        }
    }
    let readers = engine::with(|engine| {
        let changed = engine.nav.flash != flash_before;
        if changed { engine.nav.flash_readers.clone() } else { Vec::new() }
    });
    for reader in readers {
        if engine::schedule_if_alive(reader) {
            again = true;
        }
    }
    engine::with(|engine| {
        let readers = std::mem::take(&mut engine.nav.flash_readers);
        engine.nav.flash_readers = readers.into_iter().filter(|&reader| engine::alive(engine, reader)).collect();
        engine.nav.refreshed = Some(refreshed);
    });
    if again {
        engine::flush();
    }
}

/// Whether a level that read the location once is still there, or the root read it so.
fn reads_once() -> bool {
    engine::with(|engine| engine.nav.root_once || engine.nav.once_levels.iter().any(|&level| engine::alive(engine, level)))
}

/// A read of the location that won't follow it (`readOnce`): noted on the level it is in, or on the
/// root.
pub fn read_once(engine: &mut engine::Engine, level: Option<u64>) {
    match level {
        Some(level) => {
            if !engine.nav.once_levels.contains(&level) {
                engine.nav.once_levels.push(level);
            }
        }
        None => engine.nav.root_once = true,
    }
}

/// A submission's redirect's continuation (`finish`), if the navigation it started has ended
/// (committed, failed, overtaken or opened elsewhere): the reads the page kept that its document
/// didn't answer read again from the server, then the submission is done.
fn finish_after(after: Option<After>) {
    let Some(after) = after else { return };
    let refreshed = engine::with(|engine| engine.nav.refreshed.take().unwrap_or_default());
    let rest: Vec<u64> = after.before.iter().copied().filter(|each| !refreshed.contains(each)).collect();
    engine::submission_redirected(&after.key, after.entry, after.plain, after.keys, rest);
}

// ---- Scrolling ----

/// Keeps where the screen is scrolled to, on the entry it is on (`keepScroll`).
fn keep_scroll() {
    let at = crate::scrolled();
    engine::with(|engine| {
        let index = engine.nav.index;
        if let Some(entry) = engine.nav.history.get_mut(index) {
            entry.scroll = at;
        }
    });
}

/// After a navigation (`scrolled`): back, to where the entry was; else, unless told not to, the top.
fn scrolled(options: &Options) {
    engine::with(|engine| {
        let nav = &mut engine.nav;
        if options.pop.is_some() {
            nav.scroll_to = Some(nav.history.get(nav.index).map(|entry| entry.scroll).unwrap_or((0.0, 0.0)));
        } else if options.scroll {
            nav.scroll_to = Some((0.0, 0.0));
        }
    });
}

// ---- Routing ----

fn set_routing(on: bool) {
    let changed = engine::with(|engine| {
        let changed = engine.nav.routing != on;
        engine.nav.routing = on;
        changed
    });
    if changed {
        engine::schedule_routing();
    }
}

// ---- Back ----

/// Android's back (the button, the gesture): the entry before, as the browser's back is, its leave
/// listeners asked first (`popped`). False at the first entry: the app closes.
pub fn back() -> bool {
    let (index, entry) = engine::with(|engine| (engine.nav.index, engine.nav.index.checked_sub(1).and_then(|at| engine.nav.history.get(at).cloned())));
    let Some(entry) = entry else { return false };
    let to = match &entry.hash {
        Some(hash) => format!("{}#{hash}", entry.target),
        None => entry.target.clone(),
    };
    let Some(url) = here().join(&to) else { return false };
    if !may_leave(&url, false, true, -1) {
        return true;
    }
    keep_scroll();
    go(&to, Options { pop: Some(index - 1), asked: true, scroll: true, ..Options::default() }, None, None);
    true
}

// ---- Leaving (Router.use_before_leave!) ----

/// Whether the app may leave for `url` (`mayLeave`): each listener run as a handler, in the order
/// they came, given the leave; one may stop it. With none, it may.
fn may_leave(url: &Url, replace: bool, scroll: bool, delta: i64) -> bool {
    let listeners: Vec<(u64, engine::Scope, Option<u64>)> = engine::with(|engine| engine.nav.listeners.iter().map(|listener| (listener.runner, listener.scope.clone(), listener.owner)).collect());
    if listeners.is_empty() {
        return true;
    }
    let id = engine::with(|engine| engine.next_id());
    let leave = Leave { id, url: url.clone(), replace, scroll, delta, prevented: false };
    let event = engine::with(|engine| {
        let (path, query) = engine.path.split_once('?').map(|(path, query)| (path.to_string(), query.to_string())).unwrap_or((engine.path.clone(), String::new()));
        engine.nav.leaves.push_back(leave.clone());
        while engine.nav.leaves.len() > LEAVES {
            engine.nav.leaves.pop_front();
        }
        (path, query)
    });
    let outer = engine::with(|engine| engine.nav.leave_asked.replace(id));
    for (runner, scope, owner) in listeners {
        let prevented = engine::with(|engine| engine.nav.leaves.iter().find(|each| each.id == id).is_some_and(|each| each.prevented));
        let text = [id.to_string(), target(&url.target()), event.0.clone(), event.1.clone(), (replace as u8).to_string(), (scroll as u8).to_string(), delta.to_string(), (prevented as u8).to_string()].join("\n");
        if engine::with(|engine| engine.has_kept(runner)) {
            engine::handle(runner, text, scope, owner, None, None);
        }
    }
    engine::with(|engine| engine.nav.leave_asked = outer);
    !engine::with(|engine| engine.nav.leaves.iter().find(|each| each.id == id).is_some_and(|each| each.prevented))
}

/// `Leave.prevent!(id)`: the leave being asked about, stopped.
pub fn prevent(id: u64) {
    engine::with(|engine| {
        if engine.nav.leave_asked == Some(id)
            && let Some(leave) = engine.nav.leaves.iter_mut().find(|each| each.id == id)
        {
            leave.prevented = true;
        }
    });
}

/// `Leave.retry!(id, force)`, once its handler is done (`retryLeave`): navigated to again, its
/// listeners asked again unless `force`; back goes back again.
pub fn retry(id: u64, force: bool) {
    let Some(leave) = engine::with(|engine| engine.nav.leaves.iter().find(|each| each.id == id).cloned()) else { return };
    if leave.delta < 0 {
        let index = engine::with(|engine| engine.nav.index);
        if index == 0 {
            return;
        }
        if force {
            keep_scroll();
            go(&leave.url.href(), Options { pop: Some(index - 1), asked: true, scroll: true, ..Options::default() }, None, None);
        } else {
            back();
        }
        return;
    }
    go(&leave.url.href(), Options { replace: leave.replace, scroll: leave.scroll, force, ..Options::default() }, None, None);
}

// ---- Links ----

/// A tap on a link (`clicked` and `linkOf`): its `href` navigated to, or, with a `target` (not
/// `_self`) or `download`, opened by the system; a link elsewhere opens elsewhere (`go`). Whether
/// it was a link.
pub fn tapped_link(href: &str, target_attr: Option<&str>, download: bool, replace: bool, noscroll: bool) {
    if download || target_attr.is_some_and(|wanted| !wanted.is_empty() && !wanted.eq_ignore_ascii_case("_self")) {
        match here().join(href) {
            Some(url) => open(&url.href()),
            None => open(href),
        }
        return;
    }
    navigate(href, Options { replace, scroll: !noscroll, ..Options::default() });
}

/// Opens `url` in the system's browser (or the app for `mailto:`, `tel:`): `Platform::open`.
fn open(url: &str) {
    if !crate::open(url) {
        log(Level::Warn, &format!("rocx: {url} is elsewhere, and this platform opens nothing: ignored"));
    }
}

/// Marks the links the host made (`markLink`, D-086): `aria-current` as where the app is says it,
/// on each `<a href>` whose `aria-current` isn't its own.
pub fn mark_links(engine: &mut engine::Engine) {
    let here = engine.path.clone();
    let mut found = Vec::new();
    let mut stack = vec![engine.dom.root];
    while let Some(node) = stack.pop() {
        if engine.dom.tag(node) == Some("a")
            && let Some(href) = engine.dom.attr(node, "href")
        {
            found.push((node, href.to_string()));
        }
        stack.extend(engine.dom.children(node));
    }
    let mut marked = HashMap::default();
    for (node, href) in found {
        let now = engine.dom.attr(node, "aria-current").map(str::to_string);
        // One the app wrote itself, or one this host didn't mark: its own.
        if now.is_some() && engine.nav.marked.get(&node) != Some(&now) {
            continue;
        }
        let mark = link_mark(&href, &here).map(str::to_string);
        if mark != now {
            match &mark {
                Some(mark) => engine.dom.set_attr(node, "aria-current", mark),
                None => engine.dom.remove_attr(node, "aria-current"),
            }
        }
        marked.insert(node, mark);
    }
    engine.nav.marked = marked;
}

/// The view id of the first link (`<a href>`) whose text has `text` in it (`native/mac`'s `link:`).
pub fn link_with_text(text: &str) -> Option<u64> {
    engine::with(|engine| {
        let mut stack = vec![engine.dom.root];
        while let Some(node) = stack.pop() {
            if engine.dom.tag(node) == Some("a") && engine.dom.attr(node, "href").is_some() && engine.dom.connected(node) {
                let mut words = String::new();
                let mut inside = vec![node];
                while let Some(at) = inside.pop() {
                    if engine.dom.tag(at).is_none() {
                        words.push_str(engine.dom.text_of(at));
                    }
                    let end = inside.len();
                    inside.extend(engine.dom.children(at));
                    inside[end..].reverse();
                }
                if words.split_whitespace().collect::<Vec<_>>().join(" ").contains(text) {
                    return Some(node as u64 + 1);
                }
            }
            let end = stack.len();
            stack.extend(engine.dom.children(node));
            stack[end..].reverse();
        }
        None
    })
}

/// Where the app is and its history, as a line (`native/mac`'s `where`).
pub fn describe() -> String {
    engine::with(|engine| {
        let entries: Vec<String> = engine.nav.history.iter().enumerate().map(|(at, entry)| if at == engine.nav.index { format!("[{}]", entry.target) } else { entry.target.clone() }).collect();
        format!("at {} (history: {}){}; {} answers kept", engine.path, entries.join(" "), if engine.nav.routing { ", routing" } else { "" }, engine.answers_kept())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_target_is_as_router_location_says() {
        assert_eq!(target("/posts/"), "/posts");
        assert_eq!(target("/"), "/");
        assert_eq!(target(""), "/");
        assert_eq!(target("/calendar/?from=2026-11-21#today"), "/calendar?from=2026-11-21");
        assert_eq!(target("/?from=x"), "/?from=x");
    }

    #[test]
    fn a_document_seeds_its_answers_and_flash() {
        let html = r#"<html><body><p>hi</p><script type="application/json" class="rocx-flash">"{\"status\":422}"</script><script type="application/json" class="rocx-answers">[["GET /api/viewer","","{\"status\":200,\"body\":\"{}\"}"],["GET /api/posts?from=x","","{\"status\":200,\"body\":\"[1]\"}"]]</script><script type="module" data-rocx src="/rocx/start.js"></script></body></html>"#;
        let (answers, flash) = seeds(html);
        assert_eq!(answers, vec![("GET /api/viewer\n".to_string(), "{\"status\":200,\"body\":\"{}\"}".to_string()), ("GET /api/posts?from=x\n".to_string(), "{\"status\":200,\"body\":\"[1]\"}".to_string())]);
        assert_eq!(flash.as_deref(), Some("{\"status\":422}"));
        assert_eq!(seeds("<html></html>"), (Vec::new(), None));
    }

    #[test]
    fn pages_are_matched_as_root_matches_them() {
        let table = json::parse(r#"{"pages":[{"path":"/"},{"path":"/posts/[id]"},{"path":"/posts/new"},{"path":"/login"}],"posts":["/logout"]}"#).unwrap();
        let nav = Nav { pages: pages_of(&table), has_table: true, ..Nav::default() };
        for (path, page) in [("/", true), ("/posts/7", true), ("/posts/new", true), ("/posts", false), ("/login", true), ("/logout", false), ("/posts/a%20b", true), ("/posts/%zz", false)] {
            assert_eq!(is_page(&nav, path), page, "{path}");
        }
        assert!(is_page(&Nav::default(), "/anything"), "no route table: every path");
    }

    #[test]
    fn links_are_marked_as_the_browser_marks_them() {
        assert_eq!(link_mark("/posts/7", "/posts/7"), Some("page"));
        assert_eq!(link_mark("/calendar", "/calendar?from=2026-11-21"), Some("page"));
        assert_eq!(link_mark("/calendar?from=x", "/calendar?from=y"), None);
        assert_eq!(link_mark("/posts", "/posts/7"), Some("true"));
        assert_eq!(link_mark("/", "/posts/7"), None);
        assert_eq!(link_mark("https://acme.example/", "/"), None);
    }
}
