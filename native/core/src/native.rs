//! The screen as native views, laid out, and what changed since the last flush as ops (D-063,
//! D-137).
//!
//! After each flush the engine's document is projected onto views (`project`), as CSS makes boxes
//! of the DOM: each element's styles are computed (css.rs), and its `display` says what it is. A
//! block (or a flex or grid item) is a view; one whose content is all inline (text, `span`,
//! `strong`, `a`…) is one text view, its text as styled runs (each run's colour, weight, size,
//! decoration and link), collapsed as its `white-space` says; inline content beside blocks gets an
//! anonymous text view, as CSS gives it an anonymous block. An inline box (`inline-block`,
//! `inline-flex`, an `<svg>`, an `<img>`, a field, a button) among text makes its block a line:
//! a flex row that wraps, standing in for CSS's line boxes. `display: contents` gives its
//! children to its parent; `::before` and `::after` with a `content` are runs or views of their
//! own. Fields and checkboxes are the platform's own; an `<svg>` is one view, drawn from the shapes
//! svg.rs makes of it. Absolutely positioned views are put in their containing block's view and
//! fixed ones on the screen's layer, above the scrolling page, as a browser paints them; siblings
//! are ordered by `z-index`.
//!
//! The projection is compared with the last one sent (`render`): what changed is sent (one batch),
//! then the views are laid out (layout.rs: Taffy, text measured by the platform), and their frames
//! are sent (a second batch):
//!
//! ```text
//! 1 CREATE   id:u64 kind:str tag:str      a view (kind: box, scroll, text, input, textarea, checkbox, image, svg, layer)
//! 2 SET      id:u64 key:str value:str     a property: text, runs, value, placeholder, disabled, svg, click, a style's (`style.padding`)
//! 3 CHILDREN id:u64 count:u32 ids:u64…    a view's children, in drawing order
//! 4 DESTROY  id:u64                       a view that is gone
//! 5 ROOT     id:u64                       the screen's root view (the page, which scrolls)
//! 6 TITLE    text:str                     the screen's title (`<Title>`)
//! 7 FRAME    id:u64 x:f32 y:f32 w:f32 h:f32   where a view is in its parent, and its size (dp)
//! 8 EXTENT   id:u64 w:f32 h:f32           the size of what a scrolling view holds (the page's too)
//! ```
//!
//! Numbers are little-endian; a string is its UTF-8 length (u32) and its bytes. The Kotlin
//! applier (native/android) walks a batch in one JNI call.

use crate::css::{self, Computed, Pseudo, State};
use crate::dom::{Dom, Kind, NodeId};
use crate::engine::{self, Engine};
use crate::layout::{self, Content, Role};
use crate::svg;
use crate::values::{self, Ctx, Length};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::hash::{Hash, Hasher};
use std::rc::Rc;

/// The bits a view that isn't an element's has: anonymous text, an anonymous line, an element's
/// `::before` and `::after`, the screen's layer for fixed views. The low bits are the node it
/// starts at (or the element it belongs to).
const ANON: u64 = 1 << 40;
const LINE: u64 = 1 << 41;
const BEFORE: u64 = 1 << 42;
const AFTER: u64 = 1 << 43;
const MARKER: u64 = 1 << 44;
/// The screen's layer: what is `position: fixed`, over the scrolling page.
pub const LAYER: u64 = 1 << 45;
const LOW: u64 = (1 << 40) - 1;

#[derive(Clone, PartialEq, Debug)]
pub struct View {
    pub kind: &'static str,
    pub tag: String,
    pub props: BTreeMap<String, String>,
    /// Its children as drawn: in-flow ones, then the absolutely positioned ones whose containing
    /// block it is, ordered by `z-index`.
    pub children: Vec<u64>,
    /// Its children as laid out (Taffy's): as the document has them, positioned ones too.
    pub flow: Vec<u64>,
    pub style: taffy::Style,
    pub content: Content,
    /// What waits for its frame: its transform (a translation can be a share of its size).
    pub transform: Option<values::Transform>,
    pub origin: (Length, Length),
    /// How it is ordered among its siblings: `z-index`, and whether it is positioned.
    pub z: (i32, bool),
    /// Its `order` in a flex or grid box.
    pub order: i32,
}

impl View {
    fn new(kind: &'static str, tag: &str) -> View {
        View {
            kind,
            tag: tag.to_string(),
            props: BTreeMap::new(),
            children: Vec::new(),
            flow: Vec::new(),
            style: taffy::Style::default(),
            content: Content::None,
            transform: None,
            origin: (Length::Percent(50.0), Length::Percent(50.0)),
            z: (0, false),
            order: 0,
        }
    }
}

thread_local! {
    static SHOWN: RefCell<Option<Shown>> = const { RefCell::new(None) };
    static TREE: RefCell<layout::Tree> = RefCell::new(layout::Tree::default());
    static SCREEN: RefCell<Screen> = const { RefCell::new(Screen { width: 412.0, height: 915.0, dark: false }) };
    /// The element the phone's focus is on (`:focus`), and the one being pressed (`:active`).
    static FOCUS: RefCell<(Option<NodeId>, Option<NodeId>)> = const { RefCell::new((None, None)) };
}

struct Shown {
    root: u64,
    views: HashMap<u64, View>,
    title: Option<String>,
    frames: HashMap<u64, ([f32; 4], [f32; 2])>,
    transforms: HashMap<u64, String>,
    insets: HashMap<u64, String>,
}

/// The screen's size in dp, as the phone says it (`viewport`), and its colour scheme.
#[derive(Clone, Copy, Debug)]
struct Screen {
    width: f32,
    height: f32,
    dark: bool,
}

/// The screen's size changed (the activity's first layout, a rotation): media queries and
/// viewport units follow, and everything is laid out again.
pub fn set_viewport(width: f32, height: f32) -> bool {
    SCREEN.with(|screen| {
        let mut screen = screen.borrow_mut();
        let changed = (screen.width - width).abs() > 0.5 || (screen.height - height).abs() > 0.5;
        screen.width = width;
        screen.height = height;
        changed
    })
}

/// What the phone said happened to a view: its focus (`:focus`), a press (`:active`).
pub fn note(node: NodeId, event: &str) {
    FOCUS.with(|focus| {
        let mut focus = focus.borrow_mut();
        match event {
            "focus" => focus.0 = Some(node),
            "blur" if focus.0 == Some(node) => focus.0 = None,
            "pointerdown" => focus.1 = Some(node),
            "pointerup" | "pointercancel" | "click" => focus.1 = None,
            _ => {}
        }
    });
}

fn native_id(node: NodeId) -> u64 {
    node as u64 + 1
}

/// The engine's node a native view shows (an anonymous one: the node it starts at; a pseudo-element:
/// its element).
pub fn node_of(id: u64) -> Option<NodeId> {
    let low = id & LOW;
    if low == 0 {
        return None;
    }
    Some((low - 1) as NodeId)
}

/// The screen is sent again, whole, on the next render (a new activity).
pub fn forget_shown() {
    SHOWN.with(|shown| *shown.borrow_mut() = None);
    TREE.with(|tree| *tree.borrow_mut() = layout::Tree::default());
}

/// An element of the engine's document, as selectors see it.
#[derive(Clone, Copy)]
struct El<'a> {
    dom: &'a Dom,
    node: NodeId,
    values: &'a crate::fx::HashMap<NodeId, String>,
    focus: (Option<NodeId>, Option<NodeId>),
}

impl<'a> El<'a> {
    fn at(&self, node: NodeId) -> El<'a> {
        El { node, ..*self }
    }
}

impl<'a> css::Elem<'a> for El<'a> {
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
        let mut at = self.dom.previous_sibling(self.node);
        while let Some(node) = at {
            if self.dom.tag(node).is_some() {
                return Some(self.at(node));
            }
            at = self.dom.previous_sibling(node);
        }
        None
    }
    fn next(self) -> Option<Self> {
        let mut at = self.dom.next_sibling(self.node);
        while let Some(node) = at {
            if self.dom.tag(node).is_some() {
                return Some(self.at(node));
            }
            at = self.dom.next_sibling(node);
        }
        None
    }
    fn first_child(self) -> Option<Self> {
        let mut at = self.dom.first_child(self.node);
        while let Some(node) = at {
            if self.dom.tag(node).is_some() {
                return Some(self.at(node));
            }
            at = self.dom.next_sibling(node);
        }
        None
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
            State::Focus => self.focus.0 == Some(self.node),
            State::Active => self.focus.1.is_some_and(|pressed| {
                let mut at = Some(pressed);
                while let Some(node) = at {
                    if node == self.node {
                        return true;
                    }
                    at = self.dom.nodes[node].parent;
                }
                false
            }),
            State::Checked => self.values.get(&self.node).map(|now| now == "true").unwrap_or_else(|| self.dom.attr(self.node, "checked").is_some()),
            State::Blank => self.values.get(&self.node).map(String::as_str).or_else(|| self.dom.attr(self.node, "value")).unwrap_or("").is_empty(),
        }
    }
    fn is(self, other: Self) -> bool {
        self.node == other.node
    }
}

/// The views the screen shows now (`project`), as the engine's document says; and whether a
/// stylesheet a `<link>` names is still on its way.
pub fn project(engine: &mut Engine) -> (u64, HashMap<u64, View>, bool) {
    let (text, loading) = stylesheet(engine);
    let screen = SCREEN.with(|screen| *screen.borrow());
    let sheet = css::Sheet::of(&text, css::Media { width: screen.width, height: screen.height, dark: screen.dark });
    for warning in sheet.warnings() {
        engine.warn_once(warning, &format!("rocx native: {warning}"));
    }
    let focus = FOCUS.with(|focus| *focus.borrow());
    let values = engine.values.clone();
    let mut views = HashMap::new();
    let mut warnings = Vec::new();
    let root = {
        let dom = &engine.dom;
        let html = dom.children(dom.root).find(|&child| dom.tag(child) == Some("html"));
        let mut projection = Projection { engine: &*engine, dom, sheet: &sheet, views: &mut views, values: &values, focus, warnings: &mut warnings, parents: HashMap::new() };
        let ctx = Ctx { em: 16.0, rem: 16.0, vw: screen.width, vh: screen.height };
        let top = Computed::root(ctx);
        let root = match html {
            Some(html) => projection.root(html, &top),
            None => projection.root(dom.root, &top),
        };
        projection.paint_tree(root);
        root
    };
    for warning in warnings {
        engine.warn_once(&warning, &format!("rocx native: {warning}"));
    }
    (root, views, loading)
}

/// Every `<style>`'s text in the document, and every stylesheet a `<link rel="stylesheet">` names
/// (the app's own is a file since D-040: `Styles.href`), in order; and whether one of those is
/// still on its way (`Engine::sheet` asks the server for it).
fn stylesheet(engine: &mut Engine) -> (String, bool) {
    let mut out = String::new();
    let mut loading = false;
    let mut stack = vec![engine.dom.root];
    while let Some(node) = stack.pop() {
        let dom = &engine.dom;
        match dom.tag(node) {
            Some("style") => {
                for child in dom.children(node) {
                    out.push_str(dom.text_of(child));
                    out.push('\n');
                }
                continue;
            }
            Some("link") if dom.attr(node, "rel").is_some_and(|rel| rel.split_whitespace().any(|each| each.eq_ignore_ascii_case("stylesheet"))) => {
                if let Some(href) = dom.attr(node, "href").map(str::to_string) {
                    match engine.sheet(&href) {
                        engine::Sheet::Loaded(text) => {
                            out.push_str(&text);
                            out.push('\n');
                        }
                        engine::Sheet::Loading => loading = true,
                        engine::Sheet::Failed => {}
                    }
                }
                continue;
            }
            Some("svg") => continue,
            _ => {}
        }
        let at = stack.len();
        stack.extend(engine.dom.children(node));
        stack[at..].reverse();
    }
    (out, loading)
}

/// Tags whose element is replaced by what the phone shows (an inline box of its own).
const REPLACED: [&str; 12] = ["img", "svg", "input", "textarea", "select", "button", "video", "canvas", "iframe", "progress", "meter", "audio"];

/// A piece of a line's inline content: text, with the style of the inline element it is in.
#[derive(Clone)]
struct Piece {
    /// The node it starts at (its id, for an anonymous view made of it).
    key: u64,
    text: String,
    style: Rc<Computed>,
    /// The element a tap on it goes to (a link, or one listening for clicks).
    link: Option<u64>,
    /// `text-decoration` of it and the inline elements it is in.
    decoration: Option<String>,
}

/// What a child is to its parent's layout.
enum Item {
    Pieces(Vec<Piece>),
    /// A box in the flow: a block (true), or an inline box (false).
    Box(u64, bool),
    /// A box out of the flow (absolute, fixed).
    Out(u64),
}

struct Projection<'a> {
    engine: &'a Engine,
    dom: &'a Dom,
    sheet: &'a css::Sheet,
    views: &'a mut HashMap<u64, View>,
    values: &'a crate::fx::HashMap<NodeId, String>,
    focus: (Option<NodeId>, Option<NodeId>),
    warnings: &'a mut Vec<String>,
    /// Each view's layout parent.
    parents: HashMap<u64, u64>,
}

impl<'a> Projection<'a> {
    fn el(&self, node: NodeId) -> El<'a> {
        El { dom: self.dom, node, values: self.values, focus: self.focus }
    }

    fn inline_style(&self, node: NodeId) -> &'a [(String, String)] {
        match &self.dom.nodes[node].kind {
            Kind::Element { styles, .. } => styles,
            _ => &[],
        }
    }

    fn compute(&self, node: NodeId, parent: &Computed) -> Computed {
        self.sheet.compute(self.el(node), parent, self.inline_style(node), None)
    }

    fn warn(&mut self, said: String) {
        if !self.warnings.contains(&said) {
            self.warnings.push(said);
        }
    }

    /// The root element's view (the page), its canvas colour on it.
    fn root(&mut self, node: NodeId, top: &Computed) -> u64 {
        let computed = self.compute(node, top);
        let id = self.element(node, Rc::new(computed), true).unwrap_or(native_id(node));
        // The canvas: the root element's background, or else the body's, under the whole screen.
        let background = |views: &HashMap<u64, View>, id: u64| views.get(&id).and_then(|view| view.props.get("style.background")).cloned();
        let body = self.views.get(&id).and_then(|view| view.flow.iter().copied().find(|child| self.views.get(child).is_some_and(|child| child.tag == "body")));
        let canvas = background(self.views, id).or_else(|| body.and_then(|body| background(self.views, body)));
        if let Some(view) = self.views.get_mut(&id) {
            view.props.insert("canvas".into(), canvas.unwrap_or_else(|| "#ffffffff".into()));
            view.props.remove("style.background");
        }
        id
    }

    /// Whether a box of this display holds its children as items (flex, grid).
    fn items_of(display: &str) -> bool {
        layout::lays_out_items(display)
    }

    /// An element's view (and its children's); none for one that shows nothing. `block` says it is
    /// a block-level box (a flex or grid item, or a block), so a text view of it fills its line.
    fn element(&mut self, node: NodeId, computed: Rc<Computed>, block: bool) -> Option<u64> {
        let tag = self.dom.tag(node)?.to_string();
        if computed.hidden() {
            return None;
        }
        let id = native_id(node);
        let attr = |name: &str| self.dom.attr(node, name).map(str::to_string);
        let mut view = View::new("box", &tag);
        let display = computed.display().to_string();
        let mut role = Role::Element;
        match tag.as_str() {
            "input" => {
                let kind = attr("type").unwrap_or_default().to_ascii_lowercase();
                if kind == "checkbox" || kind == "radio" {
                    view.kind = "checkbox";
                    // A tap's state until the app sets it (`engine::dispatch`, D-138).
                    let checked = self.engine.values.get(&node).map(|now| now == "true").unwrap_or_else(|| attr("checked").is_some());
                    view.props.insert("checked".into(), flag(checked));
                    view.props.insert("type".into(), kind);
                    view.content = Content::Fixed { width: 13.0, height: 13.0 };
                } else if kind == "hidden" {
                    return None;
                } else {
                    view.kind = "input";
                    view.props.insert("value".into(), self.values.get(&node).cloned().or_else(|| attr("value")).unwrap_or_default());
                    view.props.insert("placeholder".into(), attr("placeholder").unwrap_or_default());
                    view.props.insert("type".into(), kind);
                    self.placeholder(node, &computed, &mut view);
                    // A field's line is the font's own (`normal`), whatever its line-height, as a
                    // browser's is.
                    view.content = Content::Fixed { width: computed.font_size * 10.0, height: (computed.font_size * 1.2).ceil() };
                }
            }
            "textarea" => {
                view.kind = "textarea";
                let value = self.values.get(&node).cloned().unwrap_or_else(|| self.text_content(node));
                view.props.insert("value".into(), value);
                view.props.insert("placeholder".into(), attr("placeholder").unwrap_or_default());
                self.placeholder(node, &computed, &mut view);
                let rows = attr("rows").and_then(|rows| rows.parse::<f32>().ok()).unwrap_or(2.0);
                let line = computed.line_height().unwrap_or(computed.font_size * 1.2);
                view.content = Content::Fixed { width: computed.font_size * 10.0, height: (line * rows).ceil() };
            }
            "img" => {
                view.kind = "image";
                view.props.insert("alt".into(), attr("alt").unwrap_or_default());
                if let Some(src) = attr("src") {
                    view.props.insert("src".into(), src);
                }
                let size = |name: &str| attr(name).and_then(|value| value.trim().trim_end_matches("px").parse::<f32>().ok());
                view.content = Content::Fixed { width: size("width").unwrap_or(0.0), height: size("height").unwrap_or(0.0) };
            }
            "svg" => {
                view.kind = "svg";
                let drawing = self.svg(node, &computed);
                let ratio = drawing.view_box.map(|[_, _, w, h]| if w > 0.0 { h / w } else { 0.0 });
                let size = |name: &str| attr(name).and_then(|value| css::length(&value, computed.font_size, 16.0).or_else(|| value.trim().parse::<f32>().ok()));
                let (width, height) = (size("width"), size("height"));
                let (width, height) = match (width, height, ratio) {
                    (Some(w), Some(h), _) => (w, h),
                    (Some(w), None, Some(r)) => (w, w * r),
                    (None, Some(h), Some(r)) if r > 0.0 => (h / r, h),
                    (Some(w), None, None) => (w, 150.0),
                    (None, Some(h), None) => (300.0, h),
                    _ => (300.0, ratio.map(|r| 300.0 * r).unwrap_or(150.0)),
                };
                view.content = Content::Fixed { width, height };
                view.props.insert("svg".into(), drawing.json());
            }
            _ => {}
        }
        if view.kind == "box" {
            // A box: what it holds makes it a text view, a line of inline boxes, or a box of blocks.
            let items = self.items(node, &computed, Self::items_of(&display));
            let only_text = items.iter().all(|item| matches!(item, Item::Pieces(_)));
            let pieces: Vec<Piece> = items.iter().filter_map(|item| if let Item::Pieces(pieces) = item { Some(pieces.clone()) } else { None }).flatten().collect();
            if only_text && !Self::items_of(&display) && has_text(&pieces, &computed) {
                view.kind = "text";
                self.text_view(&mut view, &pieces, &computed, true, true);
            } else if only_text && Self::items_of(&display) && has_text(&pieces, &computed) {
                // A flex or grid box of text alone: its text is one anonymous item.
                let anon = self.anonymous_text(&pieces, &computed, true, true);
                view.flow = anon.into_iter().collect();
            } else {
                let has_block = items.iter().any(|item| matches!(item, Item::Box(_, true)));
                let has_inline_box = items.iter().any(|item| matches!(item, Item::Box(_, false)));
                if Self::items_of(&display) {
                    view.flow = self.as_items(items, &computed);
                    // `order` (Taffy has none): the items laid out, and drawn, in its order.
                    view.flow.sort_by_key(|child| self.views.get(child).map(|child| child.order).unwrap_or(0));
                } else if !has_block && has_inline_box {
                    role = Role::Line;
                    view.flow = self.line(items, &computed);
                } else {
                    view.flow = self.blocks(items, &computed);
                }
                if is_scroller(&computed) {
                    // Its scroll told to the host (`scroll` events) when something listens.
                    if self.engine.listens(node, "scroll") || self.engine.listens(node, "viewport") {
                        view.props.insert("watch".into(), "true".into());
                    }
                    view.kind = match (scrolls(computed.get("overflow-x")), scrolls(computed.get("overflow-y"))) {
                        (true, true) => "scrollxy",
                        (true, false) => "scrollx",
                        _ => "scrolly",
                    };
                }
            }
        }
        if self.clickable(node, &tag) {
            view.props.insert("click".into(), "true".into());
        }
        if attr("disabled").is_some() {
            view.props.insert("disabled".into(), "true".into());
        }
        let _ = block;
        view.style = layout::style(&computed, role, computed.get("text-align"));
        // Replaced elements: a percentage size of theirs adds nothing to their container's
        // intrinsic size (CSS sizing's compressible rule), as a browser's.
        match view.kind {
            "svg" | "image" => view.style.item_is_replaced = true,
            "input" | "textarea" | "checkbox" => view.style.item_is_compressible_replaced = true,
            _ => {}
        }
        if view.kind == "svg"
            && view.style.aspect_ratio.is_none()
            && let Content::Fixed { width, height } = view.content
            && width > 0.0
            && height > 0.0
        {
            view.style.aspect_ratio = Some(width / height);
        }
        self.paint(&mut view, &computed);
        view.order = computed.get("order").and_then(|order| order.trim().parse().ok()).unwrap_or(0);
        if matches!(view.kind, "input" | "textarea") {
            view.props.extend(text_props(&computed));
        }
        for child in view.flow.clone() {
            self.parents.insert(child, id);
        }
        self.views.insert(id, view);
        Some(id)
    }

    /// A field's hint colour, from `::placeholder`.
    fn placeholder(&mut self, node: NodeId, computed: &Computed, view: &mut View) {
        let hint = self.sheet.compute(self.el(node), computed, &[], Some(Pseudo::Placeholder));
        if hint.get("color").is_some() {
            view.props.insert("style.hint".into(), values::argb(hint.color));
        }
    }

    /// Whether a tap on the element goes to it: a link, a button, a label, a summary, or an
    /// element with a click handler.
    fn clickable(&self, node: NodeId, tag: &str) -> bool {
        matches!(tag, "button" | "label" | "summary" | "select") || (tag == "a" && self.dom.attr(node, "href").is_some()) || self.engine.listens(node, "click") || self.dom.attr(node, "role").is_some_and(|role| matches!(role, "button" | "link" | "tab" | "menuitem" | "option" | "checkbox" | "switch"))
    }

    /// An element's children as its layout sees them: runs of inline content, boxes in the flow
    /// (blocks, or inline boxes), and boxes out of it; `::before` first and `::after` last.
    /// `items`: the element lays its children out as items (flex, grid), each its own box.
    fn items(&mut self, node: NodeId, computed: &Rc<Computed>, items: bool) -> Vec<Item> {
        let mut out: Vec<Item> = Vec::new();
        let mut pieces: Vec<Piece> = Vec::new();
        if computed.is("display", "list-item") {
            self.marker(node, computed, &mut pieces);
        }
        self.pseudo(node, computed, Pseudo::Before, items, &mut pieces, &mut out);
        self.children_items(node, computed, items, &mut pieces, &mut out);
        self.pseudo(node, computed, Pseudo::After, items, &mut pieces, &mut out);
        if !pieces.is_empty() {
            out.push(Item::Pieces(pieces));
        }
        out
    }

    fn children_items(&mut self, node: NodeId, computed: &Rc<Computed>, items: bool, pieces: &mut Vec<Piece>, out: &mut Vec<Item>) {
        let children: Vec<NodeId> = self.dom.children(node).collect();
        for child in children {
            match &self.dom.nodes[child].kind {
                Kind::Text(text) => {
                    pieces.push(Piece { key: native_id(child), text: text.clone(), style: computed.clone(), link: None, decoration: None });
                    continue;
                }
                Kind::Element { .. } => {}
                Kind::Fragment => {
                    self.children_items(child, computed, items, pieces, out);
                    continue;
                }
                Kind::Comment => continue,
            }
            let tag = self.dom.tag(child).unwrap_or("").to_string();
            if tag == "br" {
                pieces.push(Piece { key: native_id(child), text: "\u{2028}".into(), style: computed.clone(), link: None, decoration: None });
                continue;
            }
            let child_computed = Rc::new(self.compute(child, computed));
            let display = child_computed.display().to_string();
            if display == "none" {
                continue;
            }
            if display == "contents" {
                self.children_items(child, &child_computed, items, pieces, out);
                continue;
            }
            let positioned = matches!(child_computed.get("position"), Some("absolute" | "fixed"));
            let replaced = REPLACED.contains(&tag.as_str());
            let block_level = items || positioned || !display.starts_with("inline");
            let atomic = !block_level && (replaced || display != "inline");
            if !block_level && !atomic {
                // Inline: its content joins the line, unless it holds boxes (then it is one itself).
                match self.inline(child, &child_computed) {
                    Some(inline_pieces) => {
                        pieces.extend(inline_pieces);
                        continue;
                    }
                    None => {
                        let holds_blocks = self.holds_blocks(child, &child_computed);
                        if !pieces.is_empty() {
                            out.push(Item::Pieces(std::mem::take(pieces)));
                        }
                        if let Some(id) = self.element(child, child_computed, holds_blocks) {
                            out.push(Item::Box(id, holds_blocks));
                        }
                        continue;
                    }
                }
            }
            if !pieces.is_empty() {
                out.push(Item::Pieces(std::mem::take(pieces)));
            }
            if let Some(id) = self.element(child, child_computed.clone(), block_level) {
                out.push(if positioned { Item::Out(id) } else { Item::Box(id, block_level) });
                if let Some(view) = self.views.get_mut(&id) {
                    view.z = z_of(&child_computed);
                }
            }
        }
    }

    /// An inline element's content as pieces, when it is all inline (text, inline elements); none
    /// when it holds a box.
    fn inline(&mut self, node: NodeId, computed: &Rc<Computed>) -> Option<Vec<Piece>> {
        let mut out = Vec::new();
        let link = self.clickable(node, self.dom.tag(node).unwrap_or("")).then(|| native_id(node));
        let decoration = computed.get("text-decoration-line").filter(|line| *line != "none").map(|line| format!("{line} {}", values::argb(computed.colour_of("text-decoration-color").unwrap_or(computed.color))));
        let before = self.pseudo_text(node, computed, Pseudo::Before);
        if let Some(piece) = before {
            out.push(piece);
        }
        if !self.inline_children(node, computed, &mut out) {
            return None;
        }
        if let Some(piece) = self.pseudo_text(node, computed, Pseudo::After) {
            out.push(piece);
        }
        for piece in &mut out {
            if piece.link.is_none() {
                piece.link = link;
            }
            if piece.decoration.is_none() {
                piece.decoration = decoration.clone();
            }
        }
        Some(out)
    }

    fn inline_children(&mut self, node: NodeId, computed: &Rc<Computed>, out: &mut Vec<Piece>) -> bool {
        let children: Vec<NodeId> = self.dom.children(node).collect();
        for child in children {
            match &self.dom.nodes[child].kind {
                Kind::Text(text) => out.push(Piece { key: native_id(child), text: text.clone(), style: computed.clone(), link: None, decoration: None }),
                Kind::Fragment => {
                    if !self.inline_children(child, computed, out) {
                        return false;
                    }
                }
                Kind::Comment => {}
                Kind::Element { tag, .. } => {
                    if &**tag == "br" {
                        out.push(Piece { key: native_id(child), text: "\u{2028}".into(), style: computed.clone(), link: None, decoration: None });
                        continue;
                    }
                    let tag = tag.to_string();
                    let child_computed = Rc::new(self.compute(child, computed));
                    let display = child_computed.display();
                    if display == "none" {
                        continue;
                    }
                    if display == "contents" {
                        if !self.inline_children(child, &child_computed, out) {
                            return false;
                        }
                        continue;
                    }
                    if display != "inline" || REPLACED.contains(&tag.as_str()) || matches!(child_computed.get("position"), Some("absolute" | "fixed")) {
                        return false;
                    }
                    match self.inline(child, &child_computed) {
                        Some(pieces) => out.extend(pieces),
                        None => return false,
                    }
                }
            }
        }
        true
    }

    /// Whether an element holds a block-level box (an inline one that does is a block, here).
    fn holds_blocks(&self, node: NodeId, computed: &Computed) -> bool {
        self.dom.children(node).any(|child| match &self.dom.nodes[child].kind {
            Kind::Element { tag, .. } => {
                let c = self.compute(child, computed);
                let display = c.display();
                if display == "none" {
                    return false;
                }
                if display == "contents" {
                    return self.holds_blocks(child, &c);
                }
                !display.starts_with("inline") && !REPLACED.contains(&&**tag) && !matches!(c.get("position"), Some("absolute" | "fixed"))
            }
            Kind::Fragment => self.holds_blocks(child, computed),
            _ => false,
        })
    }

    /// A list item's marker, as text at the start of its line (`list-style-type`).
    fn marker(&mut self, node: NodeId, computed: &Rc<Computed>, pieces: &mut Vec<Piece>) {
        let kind = computed.get("list-style-type").unwrap_or("disc").to_string();
        let text = match kind.as_str() {
            "none" => return,
            "disc" => "• ".to_string(),
            "circle" => "◦ ".to_string(),
            "square" => "▪ ".to_string(),
            quoted if quoted.starts_with('"') || quoted.starts_with('\'') => quoted.trim_matches(|c| c == '"' || c == '\'').to_string(),
            _ => {
                let el = self.el(node);
                let mut index = 1;
                let mut at = css::Elem::prev(el);
                while let Some(prev) = at {
                    if css::Elem::tag(prev) == "li" {
                        index += 1;
                    }
                    at = css::Elem::prev(prev);
                }
                format!("{index}. ")
            }
        };
        let style = Rc::new(self.sheet.compute(self.el(node), computed, &[], Some(Pseudo::Marker)));
        pieces.push(Piece { key: MARKER | native_id(node), text, style, link: None, decoration: None });
    }

    /// A `::before` or `::after` with text and nothing else, as a piece of the line.
    fn pseudo_text(&mut self, node: NodeId, computed: &Rc<Computed>, which: Pseudo) -> Option<Piece> {
        let style = self.sheet.compute(self.el(node), computed, &[], Some(which));
        let text = content(style.get("content")?, self.el(node))?;
        if style.display() != "inline" || matches!(style.get("position"), Some("absolute" | "fixed")) || text.is_empty() {
            return None;
        }
        let bit = if which == Pseudo::Before { BEFORE } else { AFTER };
        Some(Piece { key: bit | native_id(node), text, style: Rc::new(style), link: None, decoration: None })
    }

    /// An element's `::before` or `::after`: a piece of its line (text, inline), or a view of its
    /// own (a box: positioned, a block, or shaped by its CSS).
    fn pseudo(&mut self, node: NodeId, computed: &Rc<Computed>, which: Pseudo, items: bool, pieces: &mut Vec<Piece>, out: &mut Vec<Item>) {
        let style = self.sheet.compute(self.el(node), computed, &[], Some(which));
        let Some(text) = style.get("content").and_then(|value| content(value, self.el(node))) else { return };
        if style.hidden() {
            return;
        }
        let bit = if which == Pseudo::Before { BEFORE } else { AFTER };
        let id = bit | native_id(node);
        let positioned = matches!(style.get("position"), Some("absolute" | "fixed"));
        let display = style.display().to_string();
        if !positioned && !items && display == "inline" && !text.is_empty() {
            pieces.push(Piece { key: id, text, style: Rc::new(style), link: None, decoration: None });
            return;
        }
        let mut view = View::new("box", if which == Pseudo::Before { "::before" } else { "::after" });
        let style = Rc::new(style);
        if !text.is_empty() {
            view.kind = "text";
            let piece = Piece { key: id, text, style: style.clone(), link: None, decoration: None };
            self.text_view(&mut view, &[piece], &style, true, true);
        }
        view.style = layout::style(&style, Role::Element, style.get("text-align"));
        self.paint(&mut view, &style);
        view.z = z_of(&style);
        self.views.insert(id, view);
        if !pieces.is_empty() {
            out.push(Item::Pieces(std::mem::take(pieces)));
        }
        let block = items || positioned || !display.starts_with("inline");
        out.push(if positioned { Item::Out(id) } else { Item::Box(id, block) });
    }

    /// A flex or grid box's children: each box an item, each run of text one anonymous item.
    fn as_items(&mut self, items: Vec<Item>, computed: &Rc<Computed>) -> Vec<u64> {
        let mut out = Vec::new();
        for item in items {
            match item {
                Item::Pieces(pieces) => {
                    if has_text(&pieces, computed) {
                        out.extend(self.anonymous_text(&pieces, computed, true, true));
                    }
                }
                Item::Box(id, _) | Item::Out(id) => out.push(id),
            }
        }
        out
    }

    /// A line of inline boxes and text, its own children (the element is the line).
    fn line(&mut self, items: Vec<Item>, computed: &Rc<Computed>) -> Vec<u64> {
        let count = items.len();
        let mut out = Vec::new();
        for (at, item) in items.into_iter().enumerate() {
            match item {
                Item::Pieces(pieces) => {
                    if has_text(&pieces, computed) {
                        out.extend(self.anonymous_text(&pieces, computed, at == 0, at + 1 == count));
                    }
                }
                Item::Box(id, _) | Item::Out(id) => out.push(id),
            }
        }
        out
    }

    /// A block box's children: blocks as they are, the inline content between them in anonymous
    /// boxes (text, or a line when it holds inline boxes).
    fn blocks(&mut self, items: Vec<Item>, computed: &Rc<Computed>) -> Vec<u64> {
        let mut out = Vec::new();
        let mut run: Vec<Item> = Vec::new();
        for item in items {
            match item {
                Item::Box(id, true) => {
                    self.flush_run(&mut run, computed, &mut out);
                    out.push(id);
                }
                Item::Out(id) => out.push(id),
                other => run.push(other),
            }
        }
        self.flush_run(&mut run, computed, &mut out);
        out
    }

    fn flush_run(&mut self, run: &mut Vec<Item>, computed: &Rc<Computed>, out: &mut Vec<u64>) {
        if run.is_empty() {
            return;
        }
        let items = std::mem::take(run);
        if items.iter().any(|item| matches!(item, Item::Box(_, false))) {
            let key = match &items[0] {
                Item::Pieces(pieces) => pieces.first().map(|p| p.key).unwrap_or(0),
                Item::Box(id, _) | Item::Out(id) => *id,
            };
            let id = LINE | (key & LOW) | (key & (BEFORE | AFTER | MARKER));
            let children = self.line(items, computed);
            let mut view = View::new("box", "anon");
            view.style = layout::style(computed, Role::AnonymousLine, computed.get("text-align"));
            for &child in &children {
                self.parents.insert(child, id);
            }
            view.flow = children;
            self.views.insert(id, view);
            out.push(id);
        } else {
            let pieces: Vec<Piece> = items.into_iter().filter_map(|item| if let Item::Pieces(p) = item { Some(p) } else { None }).flatten().collect();
            if has_text(&pieces, computed) {
                out.extend(self.anonymous_text(&pieces, computed, true, true));
            }
        }
    }

    /// Text beside boxes: an anonymous text view of its own.
    fn anonymous_text(&mut self, pieces: &[Piece], computed: &Rc<Computed>, first: bool, last: bool) -> Option<u64> {
        let key = pieces.first()?.key;
        let id = ANON | key;
        let mut view = View::new("text", "anon");
        if !self.text_view(&mut view, pieces, computed, first, last) {
            return None;
        }
        view.style = layout::style(computed, Role::Anonymous, None);
        self.views.insert(id, view);
        Some(id)
    }

    /// A text view's properties (its text, its runs, its look) and what layout measures; false
    /// when it shows nothing.
    fn text_view(&mut self, view: &mut View, pieces: &[Piece], computed: &Computed, first: bool, last: bool) -> bool {
        let white_space = computed.get("white-space").unwrap_or("normal").to_string();
        let (collapse_spaces, keep_breaks) = match white_space.as_str() {
            "pre" | "pre-wrap" | "break-spaces" => (false, true),
            "pre-line" => (true, true),
            _ => (true, false),
        };
        // The runs: each piece's text, transformed, whitespace collapsed across them.
        let mut runs: Vec<(String, &Piece)> = Vec::new();
        let mut space = !first;
        let mut started = false;
        for piece in pieces {
            let transformed = transform_text(&piece.text, piece.style.get("text-transform"));
            let mut text = String::with_capacity(transformed.len());
            for ch in transformed.chars() {
                if ch == '\u{2028}' {
                    text.push('\n');
                    space = false;
                    started = true;
                    continue;
                }
                if collapse_spaces && (ch == ' ' || ch == '\t' || (ch == '\n' && !keep_breaks) || ch == '\r') {
                    space = true;
                    continue;
                }
                if space && started {
                    text.push(' ');
                } else if space && !first && !started && runs.iter().all(|(t, _)| t.is_empty()) {
                    text.push(' ');
                }
                space = false;
                started = true;
                text.push(ch);
            }
            runs.push((text, piece));
        }
        if space && !last && started {
            if let Some((text, _)) = runs.last_mut() {
                text.push(' ');
            }
        }
        let text: String = runs.iter().map(|(text, _)| text.as_str()).collect();
        if text.trim().is_empty() && !text.contains('\n') {
            return false;
        }
        // Runs whose look differs from the view's, as JSON for the applier.
        let base = text_style(computed);
        let mut json = String::from("[");
        let mut styled = false;
        let mut offset = 0;
        for (run_text, piece) in &runs {
            if run_text.is_empty() {
                continue;
            }
            let own = text_style(&piece.style);
            let mut fields = Vec::new();
            for (key, value) in &own {
                if base.get(key) != Some(value) {
                    fields.push(format!("\"{}\":\"{}\"", key, escape(value)));
                }
            }
            // An inline element's background (the block's own is the view's paint).
            if !std::ptr::eq(&*piece.style, computed)
                && let Some(background) = piece.style.colour_of("background-color").filter(|c| c >> 24 != 0)
            {
                fields.push(format!("\"bg\":\"{}\"", values::argb(background)));
            }
            if let Some(decoration) = &piece.decoration {
                fields.push(format!("\"deco\":\"{decoration}\""));
            }
            if let Some(link) = piece.link {
                fields.push(format!("\"k\":{link}"));
            }
            let length = run_text.encode_utf16().count();
            if !fields.is_empty() {
                styled = true;
                if json.len() > 1 {
                    json.push(',');
                }
                json.push_str(&format!("{{\"s\":{offset},\"e\":{},{}}}", offset + length, fields.join(",")));
            }
            offset += length;
        }
        json.push(']');
        view.props.insert("text".into(), text.clone());
        if styled {
            view.props.insert("runs".into(), json);
        }
        for (key, value) in text_props(computed) {
            view.props.insert(key, value);
        }
        if let Some(decoration) = computed.get("text-decoration-line").filter(|line| *line != "none") {
            view.props.insert("style.decoration".into(), format!("{decoration} {}", values::argb(computed.colour_of("text-decoration-color").unwrap_or(computed.color))));
        }
        let nowrap = matches!(white_space.as_str(), "nowrap" | "pre");
        if nowrap {
            view.props.insert("style.nowrap".into(), "true".into());
        }
        if !collapse_spaces || keep_breaks {
            view.props.insert("style.pre".into(), white_space.clone());
        }
        let clips = !matches!(computed.get("overflow-x").unwrap_or("visible"), "visible");
        if clips && computed.is("text-overflow", "ellipsis") {
            view.props.insert("style.ellipsis".into(), "true".into());
        }
        if let Some(lines) = computed.get("-webkit-line-clamp").and_then(|n| n.parse::<u32>().ok()) {
            view.props.insert("style.maxLines".into(), lines.to_string());
            view.props.insert("style.ellipsis".into(), "true".into());
        }
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        for (key, value) in &view.props {
            if key == "text" || key == "runs" || key.starts_with("style.font") || matches!(key.as_str(), "style.lineHeight" | "style.lineScale" | "style.letterSpacing" | "style.nowrap" | "style.pre" | "style.maxLines" | "style.tabular") {
                key.hash(&mut hasher);
                value.hash(&mut hasher);
            }
        }
        let words: Vec<usize> = text.split_whitespace().map(|word| word.chars().count()).collect();
        view.content = Content::Text { version: hasher.finish(), chars: words, font_size: computed.font_size, line_height: computed.line_height().unwrap_or(computed.font_size * 1.2), nowrap };
        true
    }

    /// The paint of a view: its background, borders, corners, shadow, opacity, visibility, outline,
    /// clipping, transform; position: sticky's offset.
    fn paint(&mut self, view: &mut View, c: &Computed) {
        let props = &mut view.props;
        if let Some(background) = c.colour_of("background-color").filter(|color| color >> 24 != 0) {
            props.insert("style.background".into(), values::argb(background));
        }
        if let Some(image) = c.get("background-image").filter(|image| *image != "none") {
            // Each layer's gradient, the bottom one first (CSS lists the top one first).
            let mut layers = Vec::new();
            for layer in values::split(image, Some(',')).into_iter().rev() {
                match values::gradient(&layer, c.color, c.ctx) {
                    Some(gradient) => layers.push(gradient),
                    None if layer.starts_with("url(") => {}
                    None => self.warnings.push(format!("CSS background-image `{}` isn't on phones yet: ignored", layer.chars().take(40).collect::<String>())),
                }
            }
            if !layers.is_empty() {
                props.insert("style.gradient".into(), layers.join(" | "));
            }
        }
        let sides = ["top", "right", "bottom", "left"];
        let widths: Vec<f32> = sides.iter().map(|side| layout::border_width(c, side)).collect();
        if widths.iter().any(|w| *w > 0.0) {
            let colours: Vec<String> = sides.iter().map(|side| values::argb(c.colour_of(&format!("border-{side}-color")).unwrap_or(c.color))).collect();
            props.insert("style.border".into(), format!("{} {} {} {} {}", widths[0], widths[1], widths[2], widths[3], colours.join(" ")));
            let dashed = sides.iter().find_map(|side| c.get(&format!("border-{side}-style")).filter(|s| matches!(*s, "dashed" | "dotted")));
            if let Some(dashed) = dashed {
                props.insert("style.borderStyle".into(), dashed.to_string());
            }
        }
        let corners: Vec<String> = ["top-left", "top-right", "bottom-right", "bottom-left"]
            .iter()
            .map(|corner| match c.get(&format!("border-{corner}-radius")).map(|value| values::split(value, None).first().cloned().unwrap_or_default()) {
                Some(value) if value.ends_with('%') => value,
                Some(value) => values::px(&value, c.ctx).map(|px| format!("{px}")).unwrap_or_else(|| "0".into()),
                None => "0".into(),
            })
            .collect();
        if corners.iter().any(|corner| corner != "0") {
            props.insert("style.radius".into(), corners.join(" "));
        }
        if let Some(shadow) = c.get("box-shadow").and_then(|shadow| values::shadow(shadow, c.color, c.ctx)) {
            props.insert("style.shadow".into(), shadow);
        }
        if let Some(ring) = c.get("box-shadow").and_then(|shadow| values::inset_shadow(shadow, c.color, c.ctx)) {
            props.insert("style.ring".into(), ring);
        }
        if let Some(opacity) = c.get("opacity").and_then(|o| if let Some(p) = o.strip_suffix('%') { p.trim().parse::<f32>().ok().map(|p| p / 100.0) } else { values::number(o) }).filter(|o| *o < 1.0) {
            props.insert("style.opacity".into(), format!("{}", opacity.max(0.0)));
        }
        // Clipped away whole (`clip-path: inset(50%)`, `clip: rect(0 0 0 0)`: a visually hidden
        // element's) shows nothing.
        let clipped_away = c.get("clip-path").is_some_and(|path| path.replace(' ', "").starts_with("inset(50%")) || c.get("clip").is_some_and(|clip| clip.replace([' ', ','], "") == "rect(0000)" || clip.replace(' ', "") == "rect(0,0,0,0)");
        if c.is("visibility", "hidden") || c.is("visibility", "collapse") || clipped_away {
            props.insert("style.visibility".into(), "hidden".into());
        }
        if c.get("outline-style").is_some_and(|style| style != "none") {
            let width = match c.get("outline-width").unwrap_or("medium") {
                "thin" => 1.0,
                "medium" => 3.0,
                "thick" => 5.0,
                _ => c.px("outline-width", 0.0).unwrap_or(3.0),
            };
            if width > 0.0 {
                let offset = c.px("outline-offset", 0.0).unwrap_or(0.0);
                props.insert("style.outline".into(), format!("{width} {offset} {}", values::argb(c.colour_of("outline-color").unwrap_or(c.color))));
            }
        }
        let clips = |axis: &str| matches!(c.get(axis).unwrap_or("visible"), "hidden" | "clip" | "auto" | "scroll" | "overlay");
        if clips("overflow-x") || clips("overflow-y") {
            props.insert("style.clip".into(), "true".into());
        }
        if c.is("position", "sticky") {
            let offset = c.px("top", 0.0).map(|top| format!("top {top}")).or_else(|| c.px("bottom", 0.0).map(|bottom| format!("bottom {bottom}")));
            if let Some(offset) = offset {
                props.insert("style.sticky".into(), offset);
            }
        }
        if c.is("pointer-events", "none") {
            props.insert("style.untouchable".into(), "true".into());
        }
        let transform = values::transform(c.get("transform"), c.get("translate"), c.get("scale"), c.get("rotate"), c.ctx);
        if !transform.is_identity() {
            view.transform = Some(transform);
            let origin = values::split(c.get("transform-origin").unwrap_or("50% 50%"), None);
            let axis = |word: Option<&String>, _horizontal: bool| -> Length {
                match word.map(|w| w.as_str()) {
                    Some("left") | Some("top") => Length::Percent(0.0),
                    Some("right") | Some("bottom") => Length::Percent(100.0),
                    Some("center") | None => Length::Percent(50.0),
                    Some(other) => values::length(other, c.ctx).unwrap_or(Length::Percent(50.0)),
                }
            };
            let (first, second) = (origin.first(), origin.get(1));
            // `top left` and `left top` are one origin.
            let swapped = first.is_some_and(|w| w == "top" || w == "bottom") || second.is_some_and(|w| w == "left" || w == "right");
            view.origin = if swapped { (axis(second, true), axis(first, false)) } else { (axis(first, true), axis(second, false)) };
        }
    }

    /// The drawing tree: each view's children as they are drawn. A positioned (absolute) view goes
    /// to its containing block's view (the nearest positioned one above it, or the page), a fixed
    /// one to the screen's layer; siblings are ordered by `z-index`, positioned ones over the rest.
    fn paint_tree(&mut self, root: u64) {
        let mut hoisted: HashMap<u64, Vec<u64>> = HashMap::new();
        let mut layer: Vec<u64> = Vec::new();
        let ids: Vec<u64> = self.views.keys().copied().collect();
        for &id in &ids {
            let position = self.views[&id].style.position;
            if !position.is_out_of_flow() {
                continue;
            }
            if position == taffy::Position::Fixed {
                layer.push(id);
                continue;
            }
            let mut at = self.parents.get(&id).copied();
            let mut block = root;
            while let Some(up) = at {
                if self.views.get(&up).is_some_and(|view| view.style.position != taffy::Position::Static) {
                    block = up;
                    break;
                }
                at = self.parents.get(&up).copied();
            }
            hoisted.entry(block).or_default().push(id);
        }
        for &id in &ids {
            let view = &self.views[&id];
            let mut children: Vec<u64> = view.flow.iter().copied().filter(|child| self.views.get(child).is_some_and(|child| !child.style.position.is_out_of_flow())).collect();
            if let Some(more) = hoisted.get(&id) {
                let mut more = more.clone();
                more.sort();
                children.extend(more);
            }
            self.order(&mut children);
            self.views.get_mut(&id).expect("a view").children = children;
        }
        layer.sort();
        self.order(&mut layer);
        let mut screen = View::new("layer", "layer");
        screen.children = layer;
        self.views.insert(LAYER, screen);
    }

    /// Siblings in drawing order: negative `z-index` first, then the rest as they come, then
    /// positioned ones, then positive `z-index`.
    fn order(&self, children: &mut [u64]) {
        children.sort_by_key(|child| {
            let (z, positioned) = self.views.get(child).map(|view| view.z).unwrap_or((0, false));
            if z < 0 {
                (0, z)
            } else if z > 0 {
                (3, z)
            } else if positioned {
                (2, 0)
            } else {
                (1, 0)
            }
        });
    }

    /// An `<svg>`'s shapes, its CSS resolved (svg.rs).
    fn svg(&mut self, node: NodeId, styles: &Computed) -> svg::Drawing {
        let mut drawing = svg::Drawing::default();
        drawing.view_box = self.dom.attr(node, "viewBox").and_then(svg::view_box);
        let mut style = svg::Style::initial(styles.colour(), styles.font_size());
        self.svg_paint(node, styles, &mut style);
        self.svg_children(node, svg::Matrix::IDENTITY, &style, styles, &mut drawing);
        drawing
    }

    /// An SVG element's paint: its presentation attributes, then its CSS (rules, then `style`).
    fn svg_paint(&mut self, node: NodeId, styles: &Computed, style: &mut svg::Style) {
        const PAINT: [&str; 14] = ["color", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-dasharray", "stroke-dashoffset", "fill-opacity", "stroke-opacity", "font-size", "font-weight", "text-anchor", "opacity"];
        let mut warned = Vec::new();
        for from_css in [false, true] {
            for name in PAINT {
                let value = if from_css { styles.get(name).map(str::to_string) } else { self.dom.attr(node, name).map(str::to_string) };
                let Some(value) = value else { continue };
                if value.trim_start().starts_with("url(") {
                    warned.push(format!("SVG paint `{name}: {value}` (gradients and patterns) isn't on phones yet: drawn as none"));
                    style.set(name, "none", css::colour);
                } else if name == "opacity" {
                    if let Some(opacity) = svg::opacity(&value) {
                        style.opacity *= opacity;
                    }
                } else if name == "color" {
                    continue;
                } else {
                    let current = styles.color;
                    style.set(name, &value, |value| values::colour(value, current).map(values::argb));
                }
            }
        }
        for warning in warned {
            self.warn(warning);
        }
    }

    fn svg_children(&mut self, node: NodeId, matrix: svg::Matrix, style: &svg::Style, styles: &Computed, drawing: &mut svg::Drawing) {
        let children: Vec<NodeId> = self.dom.children(node).collect();
        for child in children {
            let Some(tag) = self.dom.tag(child).map(str::to_string) else { continue };
            if matches!(tag.as_str(), "title" | "desc" | "metadata" | "style" | "defs") {
                continue;
            }
            let computed = self.compute(child, styles);
            if computed.hidden() {
                continue;
            }
            let mut own = style.clone();
            own.color = computed.colour();
            self.svg_paint(child, &computed, &mut own);
            let attr = |name: &str| self.dom.attr(child, name).map(str::to_string);
            let number = |name: &str| attr(name).and_then(|value| svg::numbers(&value).first().copied());
            let at = |name: &str| number(name).unwrap_or(0.0);
            let matrix = match attr("transform") {
                Some(transform) => matrix.then(svg::transform(&transform)),
                None => matrix,
            };
            let d = match tag.as_str() {
                "g" | "a" | "svg" | "switch" => {
                    let matrix = if tag == "svg" { matrix.then(svg::transform(&format!("translate({} {})", at("x"), at("y")))) } else { matrix };
                    self.svg_children(child, matrix, &own, &computed, drawing);
                    continue;
                }
                "path" => svg::path_data(&attr("d").unwrap_or_default()),
                "rect" => svg::rect(at("x"), at("y"), at("width"), at("height"), number("rx").or_else(|| computed.get("rx").and_then(|rx| css::length(rx, 16.0, 16.0))), number("ry")),
                "circle" => svg::ellipse(at("cx"), at("cy"), at("r"), at("r")),
                "ellipse" => svg::ellipse(at("cx"), at("cy"), at("rx"), at("ry")),
                "line" => svg::line(at("x1"), at("y1"), at("x2"), at("y2")),
                "polyline" => svg::poly(&attr("points").unwrap_or_default(), false),
                "polygon" => svg::poly(&attr("points").unwrap_or_default(), true),
                "text" => {
                    let text = self.text_content(child);
                    let text = transform_text(&text, computed.get("text-transform"));
                    own.tabular = computed.get("font-variant-numeric").is_some_and(|numeric| numeric.contains("tabular-nums"));
                    drawing.text(&text, at("x"), at("y"), matrix, &own);
                    continue;
                }
                other => {
                    self.warn(format!("SVG <{other}> isn't on phones yet: left out"));
                    continue;
                }
            };
            drawing.shape(&d, matrix, &own, number("pathLength"));
        }
    }

    /// The text an element holds (`textContent`).
    fn text_content(&self, node: NodeId) -> String {
        match &self.dom.nodes[node].kind {
            Kind::Text(text) => text.clone(),
            _ => self.dom.children(node).map(|child| self.text_content(child)).collect(),
        }
    }
}

fn z_of(c: &Computed) -> (i32, bool) {
    let positioned = !matches!(c.get("position").unwrap_or("static"), "static");
    let z = c.get("z-index").and_then(|z| z.trim().parse::<i32>().ok()).filter(|_| positioned || c.get("z-index").is_some()).unwrap_or(0);
    (z, positioned)
}

fn scrolls(value: Option<&str>) -> bool {
    matches!(value.unwrap_or("visible"), "auto" | "scroll" | "overlay")
}

/// Whether a box scrolls what it holds (`overflow: auto` or `scroll` on an axis).
fn is_scroller(c: &Computed) -> bool {
    scrolls(c.get("overflow-x")) || scrolls(c.get("overflow-y"))
}

/// Whether pieces show anything (whitespace alone doesn't, but under `white-space: pre`).
fn has_text(pieces: &[Piece], computed: &Computed) -> bool {
    let pre = matches!(computed.get("white-space"), Some("pre" | "pre-wrap" | "break-spaces"));
    pieces.iter().any(|piece| if pre { !piece.text.is_empty() } else { !piece.text.trim().is_empty() || piece.text.contains('\u{2028}') })
}

/// `content`'s text: strings, `attr(x)`, joined; none for `none`, `normal` and what isn't text.
fn content(value: &str, element: El) -> Option<String> {
    let value = value.trim();
    if matches!(value, "none" | "normal") {
        return None;
    }
    let mut out = String::new();
    for part in values::split(value, None) {
        if part == "/" {
            break;
        }
        if let Some(text) = part.strip_prefix('"').and_then(|p| p.strip_suffix('"')).or_else(|| part.strip_prefix('\'').and_then(|p| p.strip_suffix('\''))) {
            out.push_str(&unescape(text));
        } else if let Some(name) = part.strip_prefix("attr(").and_then(|p| p.strip_suffix(')')) {
            out.push_str(css::Elem::attr(element, name.trim()).unwrap_or(""));
        } else if part.starts_with("counter") || part.starts_with("url(") || part.contains("quote") {
            continue;
        } else {
            return None;
        }
    }
    Some(out)
}

/// CSS's string escapes (`\2022` is •).
fn unescape(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        let mut hex = String::new();
        while hex.len() < 6 && chars.peek().is_some_and(|c| c.is_ascii_hexdigit()) {
            hex.push(chars.next().unwrap_or('0'));
        }
        if hex.is_empty() {
            if let Some(next) = chars.next() {
                out.push(next);
            }
        } else {
            if chars.peek() == Some(&' ') {
                chars.next();
            }
            if let Some(c) = u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                out.push(c);
            }
        }
    }
    out
}

fn transform_text(text: &str, transform: Option<&str>) -> String {
    match transform {
        Some("uppercase") => text.to_uppercase(),
        Some("lowercase") => text.to_lowercase(),
        Some("capitalize") => {
            let mut out = String::with_capacity(text.len());
            let mut start = true;
            for c in text.chars() {
                if start && c.is_alphabetic() {
                    out.extend(c.to_uppercase());
                    start = false;
                } else {
                    out.push(c);
                    if c.is_whitespace() {
                        start = true;
                    } else if c.is_alphabetic() {
                        start = false;
                    }
                }
            }
            out
        }
        _ => text.to_string(),
    }
}

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// The font family a phone has for a CSS list: `mono`, `serif` or `sans`.
fn family(list: Option<&str>) -> &'static str {
    let Some(list) = list else { return "sans" };
    for name in list.split(',') {
        let name = name.trim().trim_matches(|c| c == '"' || c == '\'').to_ascii_lowercase();
        if name.contains("mono") || name.contains("menlo") || name.contains("consolas") || name.contains("courier") || name == "sf mono" {
            return "mono";
        }
        if name == "serif" || name == "ui-serif" || name.contains("georgia") || name.contains("times") {
            return "serif";
        }
        if name.contains("sans") || name.contains("system") || name.contains("rounded") || name.contains("roboto") || name.contains("helvetica") || name.contains("arial") || name.contains("inter") || name == "-apple-system" {
            return "sans";
        }
    }
    "sans"
}

/// A text's look, as runs compare it: size, colour, weight, italic, family, spacing.
fn text_style(c: &Computed) -> BTreeMap<&'static str, String> {
    let mut out = BTreeMap::new();
    out.insert("size", format!("{:.2}", c.font_size));
    out.insert("color", values::argb(c.color));
    out.insert("weight", c.weight().to_string());
    if matches!(c.get("font-style"), Some("italic" | "oblique")) {
        out.insert("italic", "true".into());
    }
    out.insert("family", family(c.get("font-family")).to_string());
    if let Some(spacing) = c.get("letter-spacing").filter(|s| *s != "normal").and_then(|s| values::px(s, c.ctx)) {
        out.insert("spacing", format!("{spacing:.2}"));
    }
    if c.get("font-variant-numeric").is_some_and(|numeric| numeric.contains("tabular-nums")) {
        out.insert("tabular", "true".into());
    }
    out
}

/// The text's properties, for any view with text.
fn text_props(c: &Computed) -> BTreeMap<String, String> {
    let mut props = BTreeMap::new();
    props.insert("style.fontSize".into(), format!("{:.2}", c.font_size));
    props.insert("style.color".into(), values::argb(c.color));
    props.insert("style.fontWeight".into(), c.weight().to_string());
    if matches!(c.get("font-style"), Some("italic" | "oblique")) {
        props.insert("style.italic".into(), "true".into());
    }
    props.insert("style.fontFamily".into(), family(c.get("font-family")).into());
    // A unitless line-height scales with each run's size (a big run's line is taller); a length
    // is every line's.
    match c.get("line-height").filter(|line| *line != "normal").and_then(values::number) {
        Some(scale) => {
            props.insert("style.lineScale".into(), format!("{scale:.3}"));
        }
        None => {
            if let Some(line) = c.line_height() {
                props.insert("style.lineHeight".into(), format!("{line:.2}"));
            }
        }
    }
    if let Some(spacing) = c.get("letter-spacing").filter(|s| *s != "normal").and_then(|s| values::px(s, c.ctx)) {
        props.insert("style.letterSpacing".into(), format!("{spacing:.2}"));
    }
    if let Some(align) = c.get("text-align").filter(|a| !matches!(*a, "start" | "left" | "-webkit-auto")) {
        props.insert("style.textAlign".into(), align.to_string());
    }
    if c.get("font-variant-numeric").is_some_and(|numeric| numeric.contains("tabular-nums")) {
        props.insert("style.tabular".into(), "true".into());
    }
    props
}

fn flag(on: bool) -> String {
    if on { "true".into() } else { "false".into() }
}

/// The ops that bring the screen from what was sent last to what the document says now: the
/// views' changes, applied by `apply` at once, then their layout, whose frames are returned.
pub fn render() -> Vec<u8> {
    let (root, mut views, title, loading) = engine::with(|engine| {
        let (root, views, loading) = project(engine);
        (root, views, engine.title.clone(), loading)
    });
    let screen = SCREEN.with(|screen| *screen.borrow());
    let first = SHOWN.with(|shown| {
        let mut shown = shown.borrow_mut();
        // Nothing shown yet and a stylesheet still on its way: the first frame waits for it, as a
        // browser's does for one in the <head> (no flash of unstyled views). One that fails, or one
        // a later frame names, doesn't hold the screen.
        if shown.is_none() && loading {
            return None;
        }
        let mut ops = Ops::default();
        let empty = HashMap::new();
        let (old_root, old, old_title) = match shown.as_ref() {
            Some(last) => (Some(last.root), &last.views, last.title.clone()),
            None => (None, &empty, None),
        };
        let mut ids: Vec<&u64> = views.keys().collect();
        ids.sort();
        // A view whose kind changed is made again.
        for &id in &ids {
            if let Some(was) = old.get(id)
                && was.kind != views[id].kind
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
        // A view made again (its kind changed) is put back in its parent: the parent's children are
        // sent again though their ids are the same.
        let remade: std::collections::HashSet<u64> = ids.iter().filter(|id| old.get(id).is_some_and(|was| was.kind != views[id].kind)).map(|id| **id).collect();
        for &id in &ids {
            let view = &views[id];
            let was = was(id, view);
            let moved = !remade.is_empty() && view.children.iter().any(|child| remade.contains(child));
            if (moved || was.map(|was| &was.children) != Some(&view.children)) && (matches!(view.kind, "box" | "scrollx" | "scrolly" | "scrollxy" | "layer") || was.is_some_and(|was| !was.children.is_empty())) {
                ops.children(*id, &view.children);
            }
        }
        let mut gone: Vec<&u64> = old.keys().filter(|id| !views.contains_key(id)).collect();
        gone.sort();
        for &id in gone {
            ops.destroy(id);
        }
        if old_root != Some(root) || remade.contains(&root) {
            ops.root(root);
        }
        if title != old_title
            && let Some(title) = &title
        {
            ops.title(title);
        }
        // A view made again is sent its frame and transform again.
        let remade: Vec<u64> = views.iter().filter(|(id, view)| was(id, view).is_none()).map(|(id, _)| *id).collect();
        let (mut frames, mut transforms, mut insets) = match shown.take() {
            Some(last) => (last.frames, last.transforms, last.insets),
            None => (HashMap::new(), HashMap::new(), HashMap::new()),
        };
        for id in remade {
            frames.remove(&id);
            transforms.remove(&id);
            insets.remove(&id);
        }
        *shown = Some(Shown { root, views: HashMap::new(), title, frames, transforms, insets });
        Some(ops.bytes)
    });
    let Some(first) = first else { return Vec::new() };
    if !first.is_empty() {
        crate::apply_now(&first);
    }
    // The layout: the views' styles, children and texts given to Taffy, then laid out.
    let started = std::time::Instant::now();
    TREE.with(|tree| {
        let mut tree = tree.borrow_mut();
        tree.sync(root, views.iter().filter(|(id, _)| **id != LAYER).map(|(id, view)| (*id, layout::Want { style: &view.style, children: &view.flow, content: &view.content })));
        tree.compute(root, screen.width, screen.height, &mut crate::PlatformMeasurer);
    });
    let laid_out = started.elapsed();
    let mut ops = Ops::default();
    SHOWN.with(|shown| {
        let mut shown = shown.borrow_mut();
        let Some(shown) = shown.as_mut() else { return };
        TREE.with(|tree| {
            let tree = tree.borrow();
            let mut ids: Vec<u64> = views.keys().copied().collect();
            ids.sort();
            for id in ids {
                let frame = if id == LAYER { Some(([0.0, 0.0, screen.width, screen.height], [screen.width, screen.height])) } else { tree.frame(id) };
                let Some(frame) = frame else { continue };
                if shown.frames.get(&id) != Some(&frame) {
                    ops.frame(id, frame.0);
                    if views[&id].kind.starts_with("scroll") || id == root {
                        ops.extent(id, frame.1);
                    }
                    shown.frames.insert(id, frame);
                }
                let view = &views[&id];
                if matches!(view.kind, "text" | "input" | "textarea")
                    && let Some(inset) = tree.inset(id)
                {
                    let inset = format!("{} {} {} {}", inset[0], inset[1], inset[2], inset[3]);
                    if shown.insets.get(&id) != Some(&inset) {
                        ops.set(id, "style.inset", &inset);
                        shown.insets.insert(id, inset);
                    }
                }
                let transform = match &view.transform {
                    Some(transform) => {
                        let [tx, ty, sx, sy, rotate] = transform.resolve(frame.0[2], frame.0[3]);
                        let ox = view.origin.0.px(frame.0[2]).unwrap_or(frame.0[2] / 2.0);
                        let oy = view.origin.1.px(frame.0[3]).unwrap_or(frame.0[3] / 2.0);
                        format!("{tx} {ty} {sx} {sy} {rotate} {ox} {oy}")
                    }
                    None => String::new(),
                };
                if shown.transforms.get(&id).map(String::as_str).unwrap_or("") != transform {
                    ops.set(id, "style.transform", &transform);
                    if transform.is_empty() {
                        shown.transforms.remove(&id);
                    } else {
                        shown.transforms.insert(id, transform);
                    }
                }
            }
            shown.frames.retain(|id, _| views.contains_key(id));
            shown.insets.retain(|id, _| views.contains_key(id));
        });
        // `on:viewport`: an element's scroll and its padding box's size, as runtime.js tells it
        // (`scrollTop,scrollLeft,clientWidth,clientHeight`), when they changed.
        let listening: Vec<(u64, NodeId)> = engine::with(|engine| views.keys().filter(|id| **id & !LOW == 0).filter_map(|id| node_of(*id).map(|node| (*id, node))).filter(|(_, node)| engine.listens(*node, "viewport")).collect());
        if !listening.is_empty() {
            TREE.with(|tree| {
                let tree = tree.borrow();
                VIEWPORTS.with(|viewports| {
                    let mut viewports = viewports.borrow_mut();
                    for (id, node) in listening {
                        let Some((frame, _)) = shown.frames.get(&id) else { continue };
                        let border = tree.border(id).unwrap_or([0.0; 4]);
                        let (top, left) = SCROLLS.with(|scrolls| scrolls.borrow().get(&node).copied()).unwrap_or((0.0, 0.0));
                        let said = format!("{},{},{},{}", top.round(), left.round(), (frame[2] - border[1] - border[3]).round(), (frame[3] - border[0] - border[2]).round());
                        if viewports.0.get(&node) != Some(&said) {
                            viewports.0.insert(node, said.clone());
                            viewports.1.push((node, said));
                        }
                    }
                });
            });
        }
        for view in views.values_mut() {
            view.style = taffy::Style::default();
        }
        shown.views = std::mem::take(&mut views);
    });
    LAST_LAYOUT.with(|last| last.set(laid_out.as_secs_f64() * 1000.0));
    ops.bytes
}

thread_local! {
    static LAST_LAYOUT: std::cell::Cell<f64> = const { std::cell::Cell::new(0.0) };
    /// `on:viewport`'s: what each element was last told (`top,left,width,height`), and what it is
    /// to be told after this render.
    static VIEWPORTS: RefCell<(HashMap<NodeId, String>, Vec<(NodeId, String)>)> = RefCell::new((HashMap::new(), Vec::new()));
    /// How far each scrolling view is scrolled (its `scroll` events'), `top,left` in dp.
    static SCROLLS: RefCell<HashMap<NodeId, (f32, f32)>> = RefCell::new(HashMap::new());
}

/// A scrolling view's scroll (its `scroll` event's value, `top,left`).
pub fn scrolled(node: NodeId, value: &str) {
    let mut parts = value.split(',').map(|part| part.trim().parse::<f32>().unwrap_or(0.0));
    let (top, left) = (parts.next().unwrap_or(0.0), parts.next().unwrap_or(0.0));
    SCROLLS.with(|scrolls| scrolls.borrow_mut().insert(node, (top, left)));
}

/// What `on:viewport` handlers are to be told now (their element's scroll or size changed), taken.
pub fn viewports() -> Vec<(NodeId, String)> {
    VIEWPORTS.with(|viewports| std::mem::take(&mut viewports.borrow_mut().1))
}

/// How long the last layout took, in ms (the log's).
pub fn last_layout_ms() -> f64 {
    LAST_LAYOUT.with(|last| last.get())
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
    fn frame(&mut self, id: u64, frame: [f32; 4]) {
        self.bytes.push(7);
        self.id(id);
        for value in frame {
            self.bytes.extend_from_slice(&value.to_le_bytes());
        }
    }
    fn extent(&mut self, id: u64, size: [f32; 2]) {
        self.bytes.push(8);
        self.id(id);
        for value in size {
            self.bytes.extend_from_slice(&value.to_le_bytes());
        }
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
    let float = |at: &mut usize| {
        let value = f32::from_le_bytes(ops[*at..*at + 4].try_into().unwrap_or_default());
        *at += 4;
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
            7 => {
                let view = id(&mut at);
                let (x, y, w, h) = (float(&mut at), float(&mut at), float(&mut at), float(&mut at));
                out.push(format!("frame {view} {x} {y} {w} {h}"));
            }
            8 => {
                let view = id(&mut at);
                let (w, h) = (float(&mut at), float(&mut at));
                out.push(format!("extent {view} {w} {h}"));
            }
            other => {
                out.push(format!("? op {other}"));
                break;
            }
        }
    }
    out
}

/// The screen as an outline (the Mac runner's): each view, its kind, its frame, its text or value.
pub fn outline() -> String {
    SHOWN.with(|shown| {
        let shown = shown.borrow();
        let Some(shown) = shown.as_ref() else { return String::new() };
        let mut out = String::new();
        fn walk(shown: &Shown, id: u64, depth: usize, out: &mut String) {
            let Some(view) = shown.views.get(&id) else { return };
            let said = view.props.get("text").or_else(|| view.props.get("value")).map(|text| format!(" {text:?}")).unwrap_or_default();
            let frame = shown.frames.get(&id).map(|(f, _)| format!(" [{} {} {}x{}]", f[0], f[1], f[2], f[3])).unwrap_or_default();
            out.push_str(&format!("{}{} <{}> #{id}{frame}{said}\n", "  ".repeat(depth), view.kind, view.tag));
            for &child in &view.children {
                walk(shown, child, depth + 1, out);
            }
        }
        walk(shown, shown.root, 0, &mut out);
        if shown.views.get(&LAYER).is_some_and(|layer| !layer.children.is_empty()) {
            out.push_str("fixed:\n");
            walk(shown, LAYER, 1, &mut out);
        }
        out
    })
}

/// Every element's view as `tag class x y w h` (on the page, not in its parent), one a line in
/// drawing order: the Mac runner's `boxes`, to compare with a browser's boxes.
pub fn boxes() -> String {
    SHOWN.with(|shown| {
        let shown = shown.borrow();
        let Some(shown) = shown.as_ref() else { return String::new() };
        let mut out = String::new();
        fn walk(shown: &Shown, id: u64, at: (f32, f32), out: &mut String) {
            let Some(view) = shown.views.get(&id) else { return };
            let frame = shown.frames.get(&id).map(|(f, _)| *f).unwrap_or([0.0; 4]);
            let here = (at.0 + frame[0], at.1 + frame[1]);
            if id & !LOW == 0 {
                let class = engine::with(|engine| node_of(id).and_then(|node| engine.dom.attr(node, "class")).unwrap_or("").to_string());
                out.push_str(&format!("{}\t{}\t{}\t{}\t{}\t{}\t{}\n", view.tag, class, here.0, here.1, frame[2], frame[3], view.props.get("text").map(|t| t.chars().take(30).collect::<String>()).unwrap_or_default().replace('\n', " ")));
            }
            for &child in &view.children {
                walk(shown, child, here, out);
            }
        }
        walk(shown, shown.root, (0.0, 0.0), &mut out);
        out
    })
}

/// The views shown now, by id (the Mac runner's, to find one to tap).
pub fn shown_views() -> HashMap<u64, View> {
    SHOWN.with(|shown| shown.borrow().as_ref().map(|shown| shown.views.clone()).unwrap_or_default())
}

/// A view's frame as last sent (the Mac runner's and tests').
pub fn frame_of(id: u64) -> Option<[f32; 4]> {
    SHOWN.with(|shown| shown.borrow().as_ref().and_then(|shown| shown.frames.get(&id).map(|(frame, _)| *frame)))
}
