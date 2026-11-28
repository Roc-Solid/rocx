//! The screen as native views, and what changed since the last flush as one batch of ops.
//!
//! After each flush the engine's document is projected onto views (`project`): an element is a
//! view; one whose content is all inline (text, `span`, `strong`, `a`…) is one text view, its text
//! collapsed as CSS's `white-space: normal` does; inline content beside blocks gets an anonymous
//! text view, as CSS gives it an anonymous block; `button`, `input` and `textarea` are the
//! platform's own; an `<svg>` is one view, drawn from the shapes svg.rs makes of it (its `svg`
//! property, JSON). `head`, `style`, `script` and the like are nothing. The projection is compared
//! with the last one sent (`render`), and the batch says only what changed:
//!
//! ```text
//! 1 CREATE   id:u64 kind:str tag:str      a view (kind: box, text, button, input, textarea, checkbox, image, svg)
//! 2 SET      id:u64 key:str value:str     a property: text, value, placeholder, disabled, svg, a style's (`style.padding`)
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
use crate::svg;
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

/// The views the screen shows now (`project`), as the engine's document says; and whether a
/// stylesheet a `<link>` names is still on its way.
pub fn project(engine: &mut Engine) -> (u64, HashMap<u64, View>, bool) {
    let (text, loading) = stylesheet(engine);
    let sheet = css::Sheet::of(&text);
    for warning in sheet.warnings() {
        engine.warn_once(&warning, &format!("rocx native: {warning}"));
    }
    let mut views = HashMap::new();
    let root = engine.dom.root;
    let mut projection = Projection { engine, sheet: &sheet, views: &mut views };
    let styles = css::Computed::root();
    let id = projection.block(root, &styles).unwrap_or(native_id(root));
    canvas(&mut views, id);
    (id, views, loading)
}

/// The screen's background, as CSS paints the canvas: the `html` element's, or, with none, the
/// `body`'s, under the whole screen (the root view, which fills it), not only under what the body
/// holds.
fn canvas(views: &mut HashMap<u64, View>, root: u64) {
    let child = |views: &HashMap<u64, View>, of: u64, tag: &str| views.get(&of).and_then(|view| view.children.iter().copied().find(|child| views.get(child).is_some_and(|child| child.tag == tag)));
    let html = if views.get(&root).is_some_and(|view| view.tag == "html") { Some(root) } else { child(views, root, "html") };
    let Some(html) = html else { return };
    let background = |id: Option<u64>| id.and_then(|id| views.get(&id)).and_then(|view| view.props.get("style.background")).cloned();
    let Some(paint) = background(Some(html)).or_else(|| background(child(views, html, "body"))) else { return };
    if let Some(view) = views.get_mut(&root) {
        view.props.entry("style.background".into()).or_insert(paint);
    }
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
            _ => {}
        }
        let at = stack.len();
        stack.extend(engine.dom.children(node));
        stack[at..].reverse();
    }
    (out, loading)
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
                out.push(css::Element { tag: tag.to_string(), id: self.dom().attr(node, "id").unwrap_or("").to_string(), classes: self.dom().attr(node, "class").unwrap_or("").split_whitespace().map(str::to_string).collect() });
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
                    // A tap's state until the app sets it (`engine::dispatch`).
                    let checked = self.engine.values.get(&node).map(|now| now == "true").unwrap_or_else(|| attr("checked").is_some());
                    props.insert("checked".into(), flag(checked));
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
            "svg" => {
                let drawing = self.svg(node, &styles);
                // Its size: the CSS's, else its attributes' (one given, the other from its viewBox's
                // shape); with neither, the applier fills the width, the height from the viewBox.
                let ratio = drawing.view_box.map(|[_, _, w, h]| h / w);
                let size = |name: &str| self.engine.dom.attr(node, name).map(str::to_string).and_then(|value| css::length(&value, 16.0, 16.0).or_else(|| value.trim().parse::<f32>().ok()).map(|n| format!("{n:.1}")).or_else(|| css::percentage(&value).map(|p| format!("{p:.2}%"))));
                let (width, height) = (size("width"), size("height"));
                let number = |size: &Option<String>| size.as_ref().filter(|size| !size.ends_with('%')).and_then(|size| size.parse::<f32>().ok());
                let height = height.or_else(|| Some(format!("{:.1}", number(&width)? * ratio?)));
                let width = width.or_else(|| Some(format!("{:.1}", number(&height)? / ratio?)));
                for (key, value) in [("style.width", width), ("style.height", height)] {
                    if let Some(value) = value {
                        props.entry(key.into()).or_insert(value);
                    }
                }
                props.insert("svg".into(), drawing.json());
                ("svg", Vec::new())
            }
            _ if self.inline_only(node) && self.has_inline(node) => {
                props.insert("text".into(), collapse(&self.inline_text(node)));
                ("text", Vec::new())
            }
            _ => ("box", self.flow(node, &styles)),
        };
        if disabled {
            props.insert("disabled".into(), "true".into());
        }
        // A tap (D-138): on a link or on what has a click handler, the view that is one sends
        // `click` there; text that holds some has a tappable run for each (`links`).
        if !matches!(kind, "button" | "input" | "textarea" | "checkbox") {
            if let Some(target) = self.tap_target(node, false) {
                props.insert("tap".into(), native_id(target).to_string());
            } else if kind == "text"
                && let Some(text) = props.get("text").cloned()
            {
                let links = self.link_runs(&[node], &text);
                if !links.is_empty() {
                    props.insert("links".into(), links);
                }
            }
        }
        self.views.insert(id, View { kind, tag, props, children });
        Some(id)
    }

    /// The links (and elements with click handlers) in inline content, as runs of its text, `text`
    /// (collapsed): `start:end:id` each (UTF-16 offsets, as Android's text has them), `,` between,
    /// found in order. The applier makes each run tappable, sending `click` to its element.
    fn link_runs(&self, nodes: &[NodeId], text: &str) -> String {
        let mut found = Vec::new();
        let mut stack: Vec<NodeId> = nodes.iter().rev().copied().collect();
        while let Some(at) = stack.pop() {
            if self.dom().tag(at).is_some() && self.tap_target(at, false).is_some() {
                found.push(at);
                continue;
            }
            let end = stack.len();
            stack.extend(self.dom().children(at));
            stack[end..].reverse();
        }
        let mut runs = Vec::new();
        let mut from = 0;
        for element in found {
            let said = collapse(&self.inline_text(element));
            let said = said.trim();
            if said.is_empty() {
                continue;
            }
            let Some(at) = text[from..].find(said) else { continue };
            let (start, end) = (from + at, from + at + said.len());
            runs.push(format!("{}:{}:{}", text[..start].encode_utf16().count(), text[..end].encode_utf16().count(), native_id(element)));
            from = end;
        }
        runs.join(",")
    }

    /// What a tap on `node`'s view is a tap on: itself, if it is a link (`<a href>`) or has a click
    /// handler; else, for text (`inside`), the first such element in it.
    fn tap_target(&self, node: NodeId, inside: bool) -> Option<NodeId> {
        let taps = |at: NodeId| (self.dom().tag(at) == Some("a") && self.dom().attr(at, "href").is_some()) || self.engine.listens(at, "click");
        if taps(node) {
            return Some(node);
        }
        if !inside {
            return None;
        }
        let mut stack: Vec<NodeId> = self.dom().children(node).collect();
        stack.reverse();
        while let Some(at) = stack.pop() {
            if taps(at) {
                return Some(at);
            }
            let at_end = stack.len();
            stack.extend(self.dom().children(at));
            stack[at_end..].reverse();
        }
        None
    }

    /// An `<svg>`'s shapes, its CSS resolved (svg.rs).
    fn svg(&mut self, node: NodeId, styles: &css::Computed) -> svg::Drawing {
        let mut drawing = svg::Drawing::default();
        drawing.view_box = self.dom().attr(node, "viewBox").and_then(svg::view_box);
        let mut style = svg::Style::initial(styles.colour(), styles.font_size());
        self.paint(node, styles, &mut style);
        self.svg_children(node, svg::Matrix::IDENTITY, &style, styles, &mut drawing);
        drawing
    }

    /// An SVG element's paint: its presentation attributes, then its CSS (rules, then `style`).
    fn paint(&mut self, node: NodeId, styles: &css::Computed, style: &mut svg::Style) {
        const PAINT: [&str; 14] = ["color", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-dasharray", "stroke-dashoffset", "fill-opacity", "stroke-opacity", "font-size", "font-weight", "text-anchor", "opacity"];
        let mut warned = Vec::new();
        for from_css in [false, true] {
            for name in PAINT {
                let value = if from_css { styles.get(name).map(str::to_string) } else { self.dom().attr(node, name).map(str::to_string) };
                let Some(value) = value else { continue };
                if value.trim_start().starts_with("url(") {
                    warned.push(format!("SVG paint `{name}: {value}` (gradients and patterns) isn't on phones yet: drawn as none"));
                    style.set(name, "none", css::colour);
                } else if name == "opacity" {
                    // A group's opacity, multiplied into what it holds.
                    if let Some(opacity) = svg::opacity(&value) {
                        style.opacity *= opacity;
                    }
                } else {
                    style.set(name, &value, css::colour);
                }
            }
        }
        for warning in warned {
            self.engine.warn_once(&warning, &format!("rocx native: {warning}"));
        }
    }

    fn svg_children(&mut self, node: NodeId, matrix: svg::Matrix, style: &svg::Style, styles: &css::Computed, drawing: &mut svg::Drawing) {
        let children: Vec<NodeId> = self.dom().children(node).collect();
        for child in children {
            let Some(tag) = self.dom().tag(child).map(str::to_string) else { continue };
            if matches!(tag.as_str(), "title" | "desc" | "metadata" | "style") {
                continue;
            }
            let path = self.path(child);
            let inline_style = self.inline_style(child);
            let computed = self.sheet.compute(&path, styles, &inline_style);
            if computed.hidden() {
                continue;
            }
            let mut own = style.clone();
            own.color = computed.colour();
            self.paint(child, &computed, &mut own);
            let attr = |name: &str| self.dom().attr(child, name).map(str::to_string);
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
                "rect" => svg::rect(at("x"), at("y"), at("width"), at("height"), number("rx"), number("ry")),
                "circle" => svg::ellipse(at("cx"), at("cy"), at("r"), at("r")),
                "ellipse" => svg::ellipse(at("cx"), at("cy"), at("rx"), at("ry")),
                "line" => svg::line(at("x1"), at("y1"), at("x2"), at("y2")),
                "polyline" => svg::poly(&attr("points").unwrap_or_default(), false),
                "polygon" => svg::poly(&attr("points").unwrap_or_default(), true),
                "text" => {
                    let text = self.inline_text(child);
                    let text = match computed.get("text-transform") {
                        Some("uppercase") => text.to_uppercase(),
                        Some("lowercase") => text.to_lowercase(),
                        _ => text,
                    };
                    own.tabular = computed.get("font-variant-numeric").is_some_and(|numeric| numeric.contains("tabular-nums"));
                    drawing.text(&text, at("x"), at("y"), matrix, &own);
                    continue;
                }
                other => {
                    let warning = format!("SVG <{other}> isn't on phones yet: left out");
                    self.engine.warn_once(&warning, &format!("rocx native: {warning}"));
                    continue;
                }
            };
            // `pathLength`: the length a dash pattern is measured in, the applier scales it.
            drawing.shape(&d, matrix, &own, number("pathLength"));
        }
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
        let children: Vec<NodeId> = self.dom().children(node).collect();
        for child in children {
            let inline = match &self.dom().nodes[child].kind {
                Kind::Text(_) => true,
                Kind::Element { tag, .. } => INLINE.contains(&&**tag) && self.inline_only(child),
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
        // A tappable run for each link in it (D-138).
        let links = self.link_runs(&nodes, &text);
        props.insert("text".into(), text);
        if !links.is_empty() {
            props.insert("links".into(), links);
        }
        self.views.insert(id, View { kind: "text", tag: "anon".into(), props, children: Vec::new() });
        out.push(id);
    }

    /// Whether all an element holds is inline (text and inline elements, all the way down).
    fn inline_only(&self, node: NodeId) -> bool {
        self.dom().children(node).all(|child| match &self.dom().nodes[child].kind {
            Kind::Text(_) | Kind::Comment | Kind::Fragment => true,
            Kind::Element { tag, .. } => HIDDEN.contains(&&**tag) || (INLINE.contains(&&**tag) && self.inline_only(child)),
        })
    }

    /// Whether an element holds any text or inline element (one with nothing in it but a hole's
    /// markers, an emptied list, stays a box).
    fn has_inline(&self, node: NodeId) -> bool {
        self.dom().children(node).any(|child| matches!(self.dom().nodes[child].kind, Kind::Text(_) | Kind::Element { .. }))
    }

    /// The text inline content says (`textContent`, a `<br>` a line break).
    fn inline_text(&self, node: NodeId) -> String {
        match &self.dom().nodes[node].kind {
            Kind::Text(text) => text.clone(),
            Kind::Element { tag, .. } if &**tag == "br" => "\u{2028}".into(),
            Kind::Element { tag, .. } if HIDDEN.contains(&&**tag) => String::new(),
            _ => self.dom().children(node).map(|child| self.inline_text(child)).collect(),
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
    let (root, views, title, loading) = engine::with(|engine| {
        let (root, views, loading) = project(engine);
        (root, views, engine.title.clone(), loading)
    });
    SHOWN.with(|shown| {
        let mut shown = shown.borrow_mut();
        // Nothing shown yet and a stylesheet still on its way: the first frame waits for it, as a
        // browser's does for one in the <head> (no flash of unstyled views). One that fails, or one
        // a later frame names, doesn't hold the screen.
        if shown.is_none() && loading {
            return Vec::new();
        }
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
