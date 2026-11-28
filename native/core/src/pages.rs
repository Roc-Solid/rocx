//! An app's page-wide phone halves (D-141): what its page scripts that aren't an element's do in a
//! browser (a cookie set on every page, a menu closed by a tap elsewhere, a question asked before a
//! form is sent), for a phone, which runs no page scripts. D-139's element halves are told of the
//! events on their element; a page half sees the page's: Android's are Kotlin in the app's
//! `android/` folder (`object Confirm : PageHalf()`, native/android's `Pages.kt`), and the engine
//! asks the platform (`Platform::page`) at the points a script's listeners on `window` run:
//!
//! - `before`: an event on its way to its target, before the page's handlers, as a capturing
//!   listener on `window` sees it: the halves may stop it (`preventDefault` and
//!   `stopImmediatePropagation`), or hold it (a question asked first): a held event is sent on later
//!   (`resume`), as if no half had stopped it: the page's handlers, then its default action;
//! - `after`: once the page's handlers had it, before its default action (a bubbling listener on
//!   `window`);
//! - `navigated`: after each navigation, the first page's mount too.
//!
//! Only the events the app's halves name are asked about (`ask("page-events")`): an app with none
//! costs nothing. The shell's own questions (a tap anywhere, Android's back, the app's start) don't
//! pass through here. What the halves ask of the page (`ask`): where it is, its cookies as a script
//! sees them (`document.cookie`), its elements by selector (`querySelectorAll`, `closest`,
//! `matches`, `contains`), and an attribute set (a `<details>`' `open`, whose `toggle` follows).

use crate::css::{self, Elem, State};
use crate::dom::{Dom, Kind, NodeId};
use crate::engine;
use crate::fx::HashMap;
use std::cell::RefCell;

/// What the halves did with an event on its way (`before`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Said {
    Go,
    Stopped,
    /// Stopped until a half sends it on (`resume`) or lets it go (`drop`).
    Held,
}

/// A held event, as it was on its way.
struct Held {
    event: String,
    target: NodeId,
    value: String,
    submitter: Option<NodeId>,
}

#[derive(Default)]
struct Pages {
    /// The events the app's halves see; none: the app has none.
    wanted: Vec<String>,
    held: HashMap<u64, Held>,
    tokens: u64,
    /// The next event asked about is a held one sent on: the halves had it already.
    resuming: bool,
    /// The button a `submit` being dispatched was sent by (`submitter`).
    submitter: Option<NodeId>,
    /// The navigation the halves were last told of (the engine's count of them).
    told: Option<u64>,
}

thread_local! {
    static PAGES: RefCell<Pages> = RefCell::default();
}

fn wants(event: &str) -> bool {
    PAGES.with(|pages| pages.borrow().wanted.iter().any(|each| each == event))
}

/// An event on its way to `target` (the engine's `dispatch`, before the page's handlers).
pub(crate) fn before(event: &str, target: NodeId, value: &str) -> Said {
    if !wants(event) {
        return Said::Go;
    }
    let (resuming, submitter, token) = PAGES.with(|pages| {
        let mut pages = pages.borrow_mut();
        pages.tokens += 1;
        (std::mem::take(&mut pages.resuming), if event == "submit" { pages.submitter } else { None }, pages.tokens)
    });
    if resuming {
        return Said::Go;
    }
    let submitter_id = submitter.map(|node| node as u64 + 1).unwrap_or(0);
    match crate::page_hook("before", event, target as u64 + 1, value, submitter_id, token) {
        0 => Said::Go,
        2 => {
            PAGES.with(|pages| pages.borrow_mut().held.insert(token, Held { event: event.to_string(), target, value: value.to_string(), submitter }));
            Said::Held
        }
        _ => Said::Stopped,
    }
}

/// An event after the page's handlers had it, before its default action.
pub(crate) fn after(event: &str, target: NodeId, value: &str) {
    if !wants(event) {
        return;
    }
    let submitter = if event == "submit" { PAGES.with(|pages| pages.borrow().submitter) } else { None };
    crate::page_hook("after", event, target as u64 + 1, value, submitter.map(|node| node as u64 + 1).unwrap_or(0), 0);
}

/// `f` (a form's `submit` dispatched) with the button that sent it known to the halves.
pub(crate) fn with_submitter<R>(submitter: Option<NodeId>, f: impl FnOnce() -> R) -> R {
    let before = PAGES.with(|pages| std::mem::replace(&mut pages.borrow_mut().submitter, submitter));
    let out = f();
    PAGES.with(|pages| pages.borrow_mut().submitter = before);
    out
}

/// After a flush (`pump`): the halves told of a navigation the app made since they last were.
pub(crate) fn after_flush() {
    if PAGES.with(|pages| pages.borrow().wanted.is_empty() && pages.borrow().told.is_some()) {
        return;
    }
    let Some((count, path)) = engine::with(|engine| engine.nav.started.then(|| (engine.nav.navigations, engine.path.clone()))) else { return };
    let new = PAGES.with(|pages| {
        let mut pages = pages.borrow_mut();
        let new = pages.told != Some(count);
        pages.told = Some(count);
        new
    });
    if new {
        crate::page_hook("navigated", "", 0, &path, 0, 0);
    }
}

/// What a half asked to be done later, on the main thread's next pump (`Message::Page`).
pub enum Work {
    /// A held event sent on.
    Resume(u64),
    /// A `<details>`' `toggle`, its `open` set by a half.
    Toggle(NodeId),
}

pub(crate) fn work(work: Work) {
    match work {
        Work::Resume(token) => {
            let Some(held) = PAGES.with(|pages| pages.borrow_mut().held.remove(&token)) else { return };
            let alive = engine::with(|engine| held.target < engine.dom.nodes.len() && engine.dom.connected(held.target) && engine.dom.tag(held.target).is_some());
            if !alive {
                crate::log(crate::Level::Warn, &format!("rocx native: a held {} wasn't sent on: its element is gone", held.event));
                return;
            }
            if held.event == "submit" {
                PAGES.with(|pages| pages.borrow_mut().resuming = true);
                engine::submit_held(held.target, held.submitter);
            } else {
                PAGES.with(|pages| pages.borrow_mut().resuming = true);
                engine::dispatch(held.target, &held.event, &held.value);
            }
            // Whatever happened, the next event is the halves' again.
            PAGES.with(|pages| pages.borrow_mut().resuming = false);
        }
        Work::Toggle(node) => {
            if engine::with(|engine| node < engine.dom.nodes.len() && engine.dom.tag(node) == Some("details")) {
                engine::dispatch(node, "toggle", "");
            }
        }
    }
}

/// What a page half asks of the page (`crate::ask`), on the main thread; None for a question that
/// isn't one of these.
pub(crate) fn ask(what: &str, arg: &str) -> Option<String> {
    let now = || std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_millis() as u64).unwrap_or(0);
    Some(match what {
        // The events the app's halves see (names apart by spaces).
        "page-events" => {
            PAGES.with(|pages| pages.borrow_mut().wanted = arg.split_whitespace().map(str::to_string).collect());
            String::new()
        }
        // Where the app is (`location.pathname + location.search`), "" before its first page.
        "path" => {
            if engine::started() {
                engine::with(|engine| if engine.nav.started { engine.path.clone() } else { String::new() })
            } else {
                String::new()
            }
        }
        // `document.cookie` for a page at a URL.
        "cookie.read" => crate::cookies::for_script(arg, now()),
        // `document.cookie = line` (`<url>\n<line>`).
        "cookie.write" => {
            if let Some((url, line)) = arg.split_once('\n') {
                crate::cookies::from_script(url, line, now());
            }
            String::new()
        }
        // `querySelectorAll` (the elements' ids, a line each, in the document's order).
        "query" => {
            let Some(query) = css::Query::parse(arg) else { return Some(String::new()) };
            if !engine::started() {
                return Some(String::new());
            }
            engine::with(|engine| all(&engine.dom, &engine.values, &query).iter().map(|node| (node + 1).to_string()).collect::<Vec<_>>().join("\n"))
        }
        // `element.closest(selector)` (`<id>\n<selector>`): its id, or "".
        "closest" => node_and(arg, |dom, values, node, selector| {
            let query = css::Query::parse(selector)?;
            closest(dom, values, node, &query).map(|found| (found + 1).to_string())
        }),
        // `element.matches(selector)`: "1" or "".
        "matches" => node_and(arg, |dom, values, node, selector| {
            let query = css::Query::parse(selector)?;
            query.matches(Page { dom, values, node }).then(|| "1".to_string())
        }),
        // `a.contains(b)` (`<a>\n<b>`): "1" or "".
        "contains" => node_and(arg, |dom, _, node, other| {
            let other = other.parse::<u64>().ok().and_then(crate::native::node_of)?;
            contains(dom, node, other).then(|| "1".to_string())
        }),
        // `setAttribute` (`<id>\n<name>\n=<value>`) or `removeAttribute` (`<id>\n<name>`); a
        // `<details>`' `open` changed fires its `toggle` next.
        "set" => {
            let mut parts = arg.splitn(3, '\n');
            let (Some(id), Some(name)) = (parts.next(), parts.next()) else { return Some(String::new()) };
            let value = parts.next().and_then(|value| value.strip_prefix('='));
            let Some(node) = id.parse::<u64>().ok().and_then(crate::native::node_of) else { return Some(String::new()) };
            if !engine::started() {
                return Some(String::new());
            }
            let toggled = engine::with(|engine| {
                if node >= engine.dom.nodes.len() || engine.dom.tag(node).is_none() {
                    return false;
                }
                let was = engine.dom.attr(node, name).map(str::to_string);
                match value {
                    Some(value) => engine.dom.set_attr(node, name, value),
                    None => engine.dom.remove_attr(node, name),
                }
                engine.dom.tag(node) == Some("details") && name == "open" && was.is_some() != value.is_some()
            });
            if toggled {
                crate::post(crate::Message::Page(crate::generation(), Work::Toggle(node)));
            } else {
                crate::wake();
            }
            String::new()
        }
        // A held event sent on, or let go of (`<token>`).
        "resume" => {
            if let Ok(token) = arg.parse::<u64>() {
                crate::post(crate::Message::Page(crate::generation(), Work::Resume(token)));
            }
            String::new()
        }
        "drop" => {
            if let Ok(token) = arg.parse::<u64>() {
                PAGES.with(|pages| pages.borrow_mut().held.remove(&token));
            }
            String::new()
        }
        _ => return None,
    })
}

/// A question about an element (`<id>\n<rest>`): `f`'s answer, "" when there is none.
fn node_and(arg: &str, f: impl FnOnce(&Dom, &HashMap<NodeId, String>, NodeId, &str) -> Option<String>) -> String {
    let Some((id, rest)) = arg.split_once('\n') else { return String::new() };
    let Some(node) = id.parse::<u64>().ok().and_then(crate::native::node_of) else { return String::new() };
    if !engine::started() {
        return String::new();
    }
    engine::with(|engine| {
        if node >= engine.dom.nodes.len() || engine.dom.tag(node).is_none() {
            return String::new();
        }
        f(&engine.dom, &engine.values, node, rest).unwrap_or_default()
    })
}

/// An element of the document, as a half's selectors see it (`:checked` as the phone has it; no
/// focus or press).
#[derive(Clone, Copy)]
struct Page<'a> {
    dom: &'a Dom,
    values: &'a HashMap<NodeId, String>,
    node: NodeId,
}

impl<'a> Page<'a> {
    fn at(&self, node: NodeId) -> Page<'a> {
        Page { node, ..*self }
    }

    fn element(&self, mut at: Option<NodeId>, step: impl Fn(NodeId) -> Option<NodeId>) -> Option<Page<'a>> {
        while let Some(node) = at {
            if self.dom.tag(node).is_some() {
                return Some(self.at(node));
            }
            at = step(node);
        }
        None
    }
}

impl<'a> Elem<'a> for Page<'a> {
    fn tag(self) -> &'a str {
        self.dom.tag(self.node).unwrap_or("")
    }
    fn attr(self, name: &str) -> Option<&'a str> {
        self.dom.attr(self.node, name)
    }
    fn parent(self) -> Option<Self> {
        let mut at = self.dom.nodes[self.node].parent;
        while let Some(up) = at {
            if up == self.dom.root {
                return None;
            }
            if self.dom.tag(up).is_some() {
                return Some(self.at(up));
            }
            at = self.dom.nodes[up].parent;
        }
        None
    }
    fn prev(self) -> Option<Self> {
        self.element(self.dom.previous_sibling(self.node), |node| self.dom.previous_sibling(node))
    }
    fn next(self) -> Option<Self> {
        self.element(self.dom.next_sibling(self.node), |node| self.dom.next_sibling(node))
    }
    fn first_child(self) -> Option<Self> {
        self.element(self.dom.first_child(self.node), |node| self.dom.next_sibling(node))
    }
    fn is_empty(self) -> bool {
        self.dom.children(self.node).all(|child| match &self.dom.nodes[child].kind {
            Kind::Element { .. } => false,
            Kind::Text(text) => text.is_empty(),
            _ => true,
        })
    }
    fn state(self, state: State) -> bool {
        match state {
            State::Checked => self.values.get(&self.node).map(|now| now == "true").unwrap_or_else(|| self.dom.attr(self.node, "checked").is_some()),
            State::Blank => self.values.get(&self.node).map(String::as_str).or_else(|| self.dom.attr(self.node, "value")).unwrap_or("").is_empty(),
            State::Focus | State::Active => false,
        }
    }
    fn is(self, other: Self) -> bool {
        self.node == other.node
    }
}

/// Every element in the document the query matches, in the document's order.
fn all(dom: &Dom, values: &HashMap<NodeId, String>, query: &css::Query) -> Vec<NodeId> {
    let mut found = Vec::new();
    let mut stack = vec![dom.root];
    while let Some(node) = stack.pop() {
        if node != dom.root && dom.tag(node).is_some() && query.matches(Page { dom, values, node }) {
            found.push(node);
        }
        let end = stack.len();
        stack.extend(dom.children(node));
        stack[end..].reverse();
    }
    found
}

/// The element itself or the nearest above it that the query matches (`closest`).
fn closest(dom: &Dom, values: &HashMap<NodeId, String>, node: NodeId, query: &css::Query) -> Option<NodeId> {
    let mut at = Some(node);
    while let Some(each) = at {
        if each == dom.root {
            return None;
        }
        if dom.tag(each).is_some() && query.matches(Page { dom, values, node: each }) {
            return Some(each);
        }
        at = dom.nodes.get(each).and_then(|node| node.parent);
    }
    None
}

/// Whether `other` is `node` or inside it (`contains`).
fn contains(dom: &Dom, node: NodeId, other: NodeId) -> bool {
    let mut at = Some(other);
    while let Some(each) = at {
        if each == node {
            return true;
        }
        at = dom.nodes.get(each).and_then(|node| node.parent);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn add(dom: &mut Dom, parent: NodeId, tag: &str, attrs: &[(&str, &str)]) -> NodeId {
        let node = dom.element(tag);
        for (name, value) in attrs {
            dom.set_attr(node, name, value);
        }
        dom.append(parent, node);
        node
    }

    /// The header's menus: two `<details data-menu>`, one open, with a link and a form's button.
    fn menus() -> (Dom, [NodeId; 6]) {
        let mut dom = Dom::new();
        let root = dom.root;
        let body = add(&mut dom, root, "body", &[]);
        let header = add(&mut dom, body, "header", &[]);
        let account = add(&mut dom, header, "details", &[("class", "menu"), ("data-menu", ""), ("open", "")]);
        let summary = add(&mut dom, account, "summary", &[]);
        let picture = add(&mut dom, summary, "img", &[]);
        let items = add(&mut dom, account, "div", &[("class", "items end")]);
        let profile = add(&mut dom, items, "a", &[("href", "/profile")]);
        let form = add(&mut dom, items, "form", &[("method", "post")]);
        let sign_out = add(&mut dom, form, "button", &[]);
        let orgs = add(&mut dom, header, "details", &[("data-menu", "")]);
        add(&mut dom, orgs, "summary", &[]);
        let main = add(&mut dom, body, "main", &[]);
        (dom, [account, picture, profile, sign_out, orgs, main])
    }

    #[test]
    fn a_half_finds_the_page_as_its_script_does() {
        let (dom, [account, picture, profile, sign_out, orgs, main]) = menus();
        let values = HashMap::default();
        let open = css::Query::parse("details[data-menu][open]").unwrap();
        assert_eq!(all(&dom, &values, &open), vec![account], "querySelectorAll finds the open menu alone");
        let both = css::Query::parse("details[data-menu]").unwrap();
        assert_eq!(all(&dom, &values, &both), vec![account, orgs], "in the document's order");
        let chosen = css::Query::parse("details[data-menu] > :not(summary) :is(a, button)").unwrap();
        assert_eq!(closest(&dom, &values, profile, &chosen), Some(profile), "a link in the menu is a choice");
        assert_eq!(closest(&dom, &values, sign_out, &chosen), Some(sign_out), "so is a form's button in it");
        assert_eq!(closest(&dom, &values, picture, &chosen), None, "the summary's picture isn't");
        let menu = css::Query::parse("details[data-menu]").unwrap();
        assert_eq!(closest(&dom, &values, sign_out, &menu), Some(account));
        assert_eq!(closest(&dom, &values, main, &menu), None);
        assert!(contains(&dom, account, picture) && contains(&dom, account, account));
        assert!(!contains(&dom, account, main) && !contains(&dom, account, orgs));
    }

    #[test]
    fn a_selector_the_phone_cant_read_finds_nothing() {
        assert!(css::Query::parse("a::before").is_none());
        assert!(css::Query::parse("").is_none());
        assert!(css::Query::parse("form[data-confirm], button[data-confirm]").is_some());
    }
}
