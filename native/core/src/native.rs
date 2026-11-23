//! The screen as native views, and what changed since the last flush as one batch of ops.
//!
//! After each flush the engine's document is projected onto views (`project`): an element is a
//! view; one whose content is all inline (text, `span`, `strong`, `a`…) is one text view, its text
//! collapsed as CSS's `white-space: normal` does; inline content beside blocks gets an anonymous
//! text view, as CSS gives it an anonymous block; `button`, `input` and `textarea` are the
//! platform's own. `head`, `style`, `script` and the like are nothing. The projection is compared
//! with the last one sent (`render`), and the batch says only what changed:
//!
//! ```text
//! 1 CREATE   id:u64 kind:str tag:str      a view (kind: box, text, button, input, textarea, checkbox, image)
//! 2 SET      id:u64 key:str value:str     a property: text, value, placeholder, disabled, a style's (`style.padding`)
//! 3 CHILDREN id:u64 count:u32 ids:u64…    a view's children, in order
//! 4 DESTROY  id:u64                       a view that is gone
//! 5 ROOT     id:u64                       the screen's root view
//! 6 TITLE    text:str                     the screen's title (`<Title>`)
//! ```
//!
//! Numbers are little-endian; a string is its UTF-8 length (u32) and its bytes. The Kotlin
//! applier (native/android) walks a batch in one JNI call.

use crate::css;
use crate::dom::{Dom, Kind, NodeId};
use crate::engine::{self, Engine};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};

/// The bit an anonymous text view's id has (its first node's id beside it).
const ANON: u64 = 1 << 40;

#[derive(Clone, PartialEq, Debug)]
pub struct View {
    pub kind: &'static str,
    pub tag: String,
    pub props: BTreeMap<String, String>,
    pub children: Vec<u64>,
}

thread_local! {
    static SHOWN: RefCell<Option<Shown>> = const { RefCell::new(None) };
}

struct Shown {
    root: u64,
    views: HashMap<u64, View>,
    title: Option<String>,
}

/// Elements that are nothing on a screen.
const HIDDEN: [&str; 10] = ["head", "style", "script", "title", "meta", "link", "template", "noscript", "base", "rocx-none"];

/// Elements that sit in a line of text (CSS's inline elements, but form controls and images,
/// which are views of their own here).
const INLINE: [&str; 26] = ["a", "abbr", "b", "bdi", "bdo", "br", "cite", "code", "data", "dfn", "em", "i", "kbd", "label", "mark", "q", "s", "samp", "small", "span", "strong", "sub", "sup", "time", "u", "var"];

fn native_id(node: NodeId) -> u64 {
    node as u64 + 1
}

/// The engine's node a native view shows (an anonymous text view: the element it is in).
pub fn node_of(id: u64) -> Option<NodeId> {
    if id == 0 {
        return None;
    }
    if id & ANON != 0 {
        let first = ((id & !ANON) - 1) as NodeId;
        return engine::with(|engine| engine.dom.nodes.get(first).and_then(|node| node.parent));
    }
    Some((id - 1) as NodeId)
}

/// The screen is sent again, whole, on the next render (a new activity).
pub fn forget_shown() {
    SHOWN.with(|shown| *shown.borrow_mut() = None);
}

/// The views the screen shows now (`project`), as the engine's document says.
pub fn project(engine: &mut Engine) -> (u64, HashMap<u64, View>) {
    let sheet = css::Sheet::of(&stylesheet(&engine.dom));
    for warning in sheet.warnings() {
        engine.warn_once(&warning, &format!("rocx native: {warning}"));
    }
    let mut views = HashMap::new();
    let root = engine.dom.root;
    let mut projection = Projection { engine, sheet: &sheet, views: &mut views };
    let styles = css::Computed::root();
    let id = projection.block(root, &styles).unwrap_or(native_id(root));
    (id, views)
}

/// Every `<style>`'s text in the document, in order.
fn stylesheet(dom: &Dom) -> String {
    let mut out = String::new();
    let mut stack = vec![dom.root];
    while let Some(node) = stack.pop() {
        if dom.tag(node) == Some("style") {
            for &child in &dom.nodes[node].children {
                out.push_str(dom.text_of(child));
                out.push('\n');
            }
            continue;
        }
        for &child in dom.nodes[node].children.iter().rev() {
            stack.push(child);
        }
    }
    out
}

struct Projection<'a> {
    engine: &'a mut Engine,
    sheet: &'a css::Sheet,
    views: &'a mut HashMap<u64, View>,
}

impl Projection<'_> {
    fn dom(&self) -> &Dom {
        &self.engine.dom
    }

    /// The ancestors' tags and classes, nearest first, for the style sheet's selectors.
    fn path(&self, node: NodeId) -> Vec<css::Element> {
        let mut out = Vec::new();
        let mut at = Some(node);
        while let Some(node) = at {
            if let Kind::Element { tag, .. } = &self.dom().nodes[node].kind {
                out.push(css::Element { tag: tag.clone(), id: self.dom().attr(node, "id").unwrap_or("").to_string(), classes: self.dom().attr(node, "class").unwrap_or("").split_whitespace().map(str::to_string).collect() });
            }
            at = self.dom().nodes[node].parent;
        }
        out
    }

    /// An element's view, its children's too; none for one that shows nothing.
    fn block(&mut self, node: NodeId, inherited: &css::Computed) -> Option<u64> {
        let tag = self.dom().tag(node)?.to_string();
        if HIDDEN.contains(&tag.as_str()) {
            return None;
        }
        let path = self.path(node);
        let inline_style = self.inline_style(node);
        let styles = self.sheet.compute(&path, inherited, &inline_style);
        if styles.hidden() {
            return None;
        }
        let id = native_id(node);
        let mut props = styles.props();
        let attr = |name: &str| self.engine.dom.attr(node, name).map(str::to_string);
        let disabled = attr("disabled").is_some();
        let (kind, children) = match tag.as_str() {
            "input" => {
                let kind = attr("type").unwrap_or_default().to_ascii_lowercase();
                if kind == "checkbox" || kind == "radio" {
                    props.insert("checked".into(), flag(attr("checked").is_some()));
                    ("checkbox", Vec::new())
                } else if kind == "hidden" {
                    return None;
                } else {
                    props.insert("value".into(), self.engine.values.get(&node).cloned().or_else(|| attr("value")).unwrap_or_default());
                    props.insert("placeholder".into(), attr("placeholder").unwrap_or_default());
                    props.insert("type".into(), kind);
                    ("input", Vec::new())
                }
            }
            "textarea" => {
                let value = self.engine.values.get(&node).cloned().unwrap_or_else(|| self.inline_text(node));
                props.insert("value".into(), value);
                props.insert("placeholder".into(), attr("placeholder").unwrap_or_default());
                ("textarea", Vec::new())
            }
            "button" => {
                props.insert("text".into(), collapse(&self.inline_text(node)));
                ("button", Vec::new())
            }
            "img" => {
                props.insert("alt".into(), attr("alt").unwrap_or_default());
                ("image", Vec::new())
            }
            _ if self.inline_only(node) => {
                props.insert("text".into(), collapse(&self.inline_text(node)));
                ("text", Vec::new())
            }
            _ => ("box", self.flow(node, &styles)),
        };
        if disabled {
            props.insert("disabled".into(), "true".into());
        }
        self.views.insert(id, View { kind, tag, props, children });
        Some(id)
    }

    fn inline_style(&self, node: NodeId) -> Vec<(String, String)> {
        match &self.dom().nodes[node].kind {
            Kind::Element { styles, .. } => styles.clone(),
            _ => Vec::new(),
        }
    }

    /// A box's children: elements that are blocks, and runs of inline content between them as
    /// anonymous text views.
    fn flow(&mut self, node: NodeId, styles: &css::Computed) -> Vec<u64> {
        let mut out = Vec::new();
        let mut run: Vec<NodeId> = Vec::new();
        let children = self.dom().nodes[node].children.clone();
        for child in children {
            let inline = match &self.dom().nodes[child].kind {
                Kind::Text(_) => true,
                Kind::Element { tag, .. } => INLINE.contains(&tag.as_str()) && self.inline_only(child),
                _ => continue,
            };
            if inline {
                run.push(child);
                continue;
            }
            self.anonymous(&mut run, styles, &mut out);
            if let Some(view) = self.block(child, styles) {
                out.push(view);
            }
        }
        self.anonymous(&mut run, styles, &mut out);
        out
    }

    fn anonymous(&mut self, run: &mut Vec<NodeId>, styles: &css::Computed, out: &mut Vec<u64>) {
        if run.is_empty() {
            return;
        }
        let nodes = std::mem::take(run);
        let text: String = nodes.iter().map(|&node| self.inline_text(node)).collect();
        let text = collapse(&text);
        if text.is_empty() {
            return;
        }
        let id = ANON | native_id(nodes[0]);
        let mut props = styles.text_props();
        props.insert("text".into(), text);
        self.views.insert(id, View { kind: "text", tag: "anon".into(), props, children: Vec::new() });
        out.push(id);
    }

    /// Whether all an element holds is inline (text and inline elements, all the way down).
    fn inline_only(&self, node: NodeId) -> bool {
        self.dom().nodes[node].children.iter().all(|&child| match &self.dom().nodes[child].kind {
            Kind::Text(_) | Kind::Comment | Kind::Fragment => true,
            Kind::Element { tag, .. } => HIDDEN.contains(&tag.as_str()) || (INLINE.contains(&tag.as_str()) && self.inline_only(child)),
        })
    }

    /// The text inline content says (`textContent`, a `<br>` a line break).
    fn inline_text(&self, node: NodeId) -> String {
        match &self.dom().nodes[node].kind {
            Kind::Text(text) => text.clone(),
            Kind::Element { tag, .. } if tag == "br" => "\u{2028}".into(),
            Kind::Element { tag, .. } if HIDDEN.contains(&tag.as_str()) => String::new(),
            _ => self.dom().nodes[node].children.iter().map(|&child| self.inline_text(child)).collect(),
        }
    }
}

fn flag(on: bool) -> String {
    if on { "true".into() } else { "false".into() }
}

/// Whitespace as CSS's `white-space: normal` shows it: each run one space, none at the ends; a
/// `<br>`'s break kept.
fn collapse(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    for char in text.chars() {
        if char.is_ascii_whitespace() {
            space = true;
            continue;
        }
        if char == '\u{2028}' {
            out.push('\n');
            space = false;
            continue;
        }
        if space && !out.is_empty() && !out.ends_with('\n') {
            out.push(' ');
        }
        space = false;
        out.push(char);
    }
    out
}

/// The ops that bring the screen from what was sent last to what the document says now.
pub fn render() -> Vec<u8> {
    let (root, views, title) = engine::with(|engine| {
        let (root, views) = project(engine);
        (root, views, engine.title.clone())
    });
    SHOWN.with(|shown| {
        let mut shown = shown.borrow_mut();
        let mut ops = Ops::default();
        let empty = HashMap::new();
        let (old_root, old, old_title) = match shown.as_ref() {
            Some(last) => (Some(last.root), &last.views, last.title.clone()),
            None => (None, &empty, None),
        };
        // A view whose kind changed is made again.
        let mut ids: Vec<&u64> = views.keys().collect();
        ids.sort();
        for &id in &ids {
            let view = &views[id];
            if let Some(was) = old.get(id)
                && was.kind != view.kind
            {
                ops.destroy(*id);
            }
        }
        // Every view made first, then their properties, then their children: a box's children
        // may be newer than it.
        let was = |id: &u64, view: &View| old.get(id).filter(|was| was.kind == view.kind);
        for &id in &ids {
            if was(id, &views[id]).is_none() {
                ops.create(*id, views[id].kind, &views[id].tag);
            }
        }
        for &id in &ids {
            let view = &views[id];
            let was = was(id, view);
            for (key, value) in &view.props {
                if was.and_then(|was| was.props.get(key)) != Some(value) {
                    ops.set(*id, key, value);
                }
            }
            if let Some(was) = was {
                for key in was.props.keys() {
                    if !view.props.contains_key(key) {
                        ops.set(*id, key, "");
                    }
                }
            }
        }
        for &id in &ids {
            let view = &views[id];
            let was = was(id, view);
            if was.map(|was| &was.children) != Some(&view.children) && (view.kind == "box" || was.is_some_and(|was| !was.children.is_empty())) {
                ops.children(*id, &view.children);
            }
        }
        let mut gone: Vec<&u64> = old.keys().filter(|id| !views.contains_key(id)).collect();
        gone.sort();
        for &id in gone {
            ops.destroy(id);
        }
        if old_root != Some(root) {
            ops.root(root);
        }
        if title != old_title
            && let Some(title) = &title
        {
            ops.title(title);
        }
        *shown = Some(Shown { root, views, title });
        ops.bytes
    })
}

#[derive(Default)]
struct Ops {
    bytes: Vec<u8>,
}

impl Ops {
    fn id(&mut self, id: u64) {
        self.bytes.extend_from_slice(&id.to_le_bytes());
    }
    fn text(&mut self, text: &str) {
        self.bytes.extend_from_slice(&(text.len() as u32).to_le_bytes());
        self.bytes.extend_from_slice(text.as_bytes());
    }
    fn create(&mut self, id: u64, kind: &str, tag: &str) {
        self.bytes.push(1);
        self.id(id);
        self.text(kind);
        self.text(tag);
    }
    fn set(&mut self, id: u64, key: &str, value: &str) {
        self.bytes.push(2);
        self.id(id);
        self.text(key);
        self.text(value);
    }
    fn children(&mut self, id: u64, children: &[u64]) {
        self.bytes.push(3);
        self.id(id);
        self.bytes.extend_from_slice(&(children.len() as u32).to_le_bytes());
        for &child in children {
            self.id(child);
        }
    }
    fn destroy(&mut self, id: u64) {
        self.bytes.push(4);
        self.id(id);
    }
    fn root(&mut self, id: u64) {
        self.bytes.push(5);
        self.id(id);
    }
    fn title(&mut self, title: &str) {
        self.bytes.push(6);
        self.text(title);
    }
}

/// A batch of ops, as text, one a line (the Mac runner's and the tests').
pub fn describe(ops: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut at = 0;
    let id = |at: &mut usize| {
        let value = u64::from_le_bytes(ops[*at..*at + 8].try_into().unwrap_or_default());
        *at += 8;
        value
    };
    let text = |at: &mut usize| {
        let len = u32::from_le_bytes(ops[*at..*at + 4].try_into().unwrap_or_default()) as usize;
        *at += 4;
        let value = String::from_utf8_lossy(&ops[*at..*at + len]).into_owned();
        *at += len;
        value
    };
    while at < ops.len() {
        let op = ops[at];
        at += 1;
        match op {
            1 => {
                let (view, kind, tag) = (id(&mut at), text(&mut at), text(&mut at));
                out.push(format!("create {view} {kind} <{tag}>"));
            }
            2 => {
                let (view, key, value) = (id(&mut at), text(&mut at), text(&mut at));
                out.push(format!("set {view} {key}={value:?}"));
            }
            3 => {
                let view = id(&mut at);
                let count = u32::from_le_bytes(ops[at..at + 4].try_into().unwrap_or_default()) as usize;
                at += 4;
                let children: Vec<String> = (0..count).map(|_| id(&mut at).to_string()).collect();
                out.push(format!("children {view} [{}]", children.join(", ")));
            }
            4 => out.push(format!("destroy {}", id(&mut at))),
            5 => out.push(format!("root {}", id(&mut at))),
            6 => out.push(format!("title {:?}", text(&mut at))),
            other => {
                out.push(format!("? op {other}"));
                break;
            }
        }
    }
    out
}

/// The screen as an outline (the Mac runner's): each view, its kind, its text or value.
pub fn outline() -> String {
    SHOWN.with(|shown| {
        let shown = shown.borrow();
        let Some(shown) = shown.as_ref() else { return String::new() };
        let mut out = String::new();
        fn walk(views: &HashMap<u64, View>, id: u64, depth: usize, out: &mut String) {
            let Some(view) = views.get(&id) else { return };
            let said = view.props.get("text").or_else(|| view.props.get("value")).map(|text| format!(" {text:?}")).unwrap_or_default();
            out.push_str(&format!("{}{} <{}> #{id}{said}\n", "  ".repeat(depth), view.kind, view.tag));
            for &child in &view.children {
                walk(views, child, depth + 1, out);
            }
        }
        walk(&shown.views, shown.root, 0, &mut out);
        out
    })
}

/// The views shown now, by id (the Mac runner's, to find one to tap).
pub fn shown_views() -> HashMap<u64, View> {
    SHOWN.with(|shown| shown.borrow().as_ref().map(|shown| shown.views.clone()).unwrap_or_default())
}
