//! The CSS a phone does (D-063's §6.2, D-137): the stylesheets the page carries (its `<style>`s and
//! the `<link rel="stylesheet">`s it names: rocx's scoped `Generated/Styles` and an app's own),
//! after a phone user-agent stylesheet (`UA`, close to the HTML spec's defaults), parsed on the
//! phone, matched against each element and cascaded into its computed values (`Computed`), which
//! layout.rs turns into Taffy's styles and native.rs into the views' properties.
//!
//! Selectors: type, class, id, `*`, attributes (`[x]`, `=`, `~=`, `|=`, `^=`, `$=`, `*=`, ` i`), the
//! four combinators, `:not()`, `:is()`, `:where()`, `:has()`, `:root`, `:empty`, the `-child` and
//! `-of-type` ones (`:nth-child(An+B of S)` too), `:disabled`/`:enabled`, `:checked`, `:focus`,
//! `:focus-visible`, `:focus-within` (the native focus), `:active` (a pressed view), `:link`,
//! `:open`, `:placeholder-shown`; `:hover` matches nothing, as on a phone. Pseudo-elements:
//! `::before` and `::after` (their `content` as text), `::placeholder` (a field's hint colour), and
//! `::marker`; the others drop their rule. `@media` (width, height, orientation, colour scheme,
//! reduced motion, hover and pointer as a phone's), `@supports`, `@layer` (its rules in place) and
//! `@container` (against the nearest size container's width as last laid out) are read;
//! `@keyframes` and `@font-face` are warned of.
//!
//! What a phone can't do (yet) only warns, once, and is ignored: the user's answer to D-063's
//! question 1. The design parses the CSS at build time instead; parsing on the phone stays for now.

use crate::values::{self, Argb, Ctx};
use crate::fx::HashMap;
use std::rc::Rc;

/// The phone's user-agent stylesheet: what a browser shows unstyled HTML with (the HTML spec's
/// rendering section, trimmed to what a phone's views show).
const UA: &str = "
html, body, address, blockquote, center, dialog, div, figure, figcaption, footer, form, header, hr,
legend, listing, main, p, plaintext, pre, search, xmp, article, aside, h1, h2, h3, h4, h5, h6, hgroup,
nav, section, dir, dd, dl, dt, menu, ol, ul, fieldset, details, summary, optgroup { display: block; }
li { display: list-item; }
head, link, meta, script, style, template, title, base, noscript, datalist, area, param, source, track, [hidden], dialog:not([open]) { display: none; }
table { display: table; } caption { display: table-caption; } thead { display: table-header-group; }
tbody { display: table-row-group; } tfoot { display: table-footer-group; } tr { display: table-row; }
td, th { display: table-cell; padding: 1px; } th { font-weight: 700; text-align: center; }
html { font-size: 16px; color: #000; font-family: sans-serif; line-height: normal; }
body { margin: 8px; }
h1 { font-size: 2em; font-weight: 700; margin: 0.67em 0; }
h2 { font-size: 1.5em; font-weight: 700; margin: 0.83em 0; }
h3 { font-size: 1.17em; font-weight: 700; margin: 1em 0; }
h4 { font-weight: 700; margin: 1.33em 0; }
h5 { font-size: 0.83em; font-weight: 700; margin: 1.67em 0; }
h6 { font-size: 0.67em; font-weight: 700; margin: 2.33em 0; }
p, dl, blockquote, figure, pre, listing, xmp, plaintext { margin: 1em 0; }
figure, blockquote { margin-left: 40px; margin-right: 40px; }
ul, ol, menu, dir { margin: 1em 0; padding-left: 40px; }
ul, menu, dir { list-style-type: disc; } ol { list-style-type: decimal; }
ul ul, ol ul, ul ol, ol ol { margin-top: 0; margin-bottom: 0; }
ul ul, ol ul { list-style-type: circle; }
dd { margin-left: 40px; }
pre, listing, xmp, plaintext { white-space: pre; font-family: monospace; }
code, kbd, samp, tt { font-family: monospace; }
strong, b { font-weight: bolder; }
em, i, cite, var, dfn, address { font-style: italic; }
small { font-size: smaller; } big { font-size: larger; }
sub, sup { font-size: smaller; }
u, ins { text-decoration: underline; }
s, strike, del { text-decoration: line-through; }
a:link { color: #0000ee; text-decoration: underline; }
mark { background-color: yellow; color: black; }
hr { color: gray; border-style: inset; border-width: 1px; margin: 0.5em auto; overflow: hidden; }
button, input, select, textarea { font-size: 13.333px; font-family: sans-serif; margin: 0; color: #000; letter-spacing: normal; text-transform: none; text-indent: 0; text-align: start; }
button, select { display: inline-block; padding: 1px 6px; border: 2px outset #767676; border-radius: 3px; background-color: #efefef; text-align: center; }
input, textarea { display: inline-block; padding: 1px 2px; border: 2px inset #767676; background-color: #fff; }
input[type=checkbox], input[type=radio] { margin: 3px 3px 3px 4px; padding: 0; border: none; background: none; }
input[type=hidden] { display: none; }
textarea { white-space: pre-wrap; }
img, svg, video, canvas, iframe, embed, object { display: inline; }
fieldset { margin: 0 2px; padding: 0.35em 0.75em 0.625em; border: 2px groove #c0c0c0; }
legend { padding: 0 2px; }
summary { display: block; }
details:not([open]) > :not(summary:first-of-type) { display: none; }
option, optgroup, datalist { display: none; }
dialog { position: absolute; left: 0; right: 0; margin: auto; border: solid; padding: 1em; background: white; color: black; }
";

/// What a selector can ask of an element (native.rs's, over the engine's document).
pub trait Elem<'a>: Copy + 'a {
    fn tag(self) -> &'a str;
    fn attr(self, name: &str) -> Option<&'a str>;
    /// The parent element (none above the document's root element).
    fn parent(self) -> Option<Self>;
    fn prev(self) -> Option<Self>;
    fn next(self) -> Option<Self>;
    fn first_child(self) -> Option<Self>;
    /// No element children and no text.
    fn is_empty(self) -> bool;
    fn state(self, state: State) -> bool;
    /// Whether two handles are one element.
    fn is(self, other: Self) -> bool;
    /// Its content box's width, if it is a size container (`container-type`) whose layout is known.
    fn container_width(self) -> Option<f32> {
        None
    }
    fn has_class(self, class: &str) -> bool {
        self.attr("class").is_some_and(|classes| classes.split_ascii_whitespace().any(|each| each == class))
    }
}

/// What an element is now, which the phone knows and its attributes don't say.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Focus,
    Active,
    Checked,
    /// A field with nothing typed in it.
    Blank,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Pseudo {
    Before,
    After,
    Placeholder,
    Marker,
}

#[derive(Clone, Debug)]
enum AttrOp {
    Exists,
    Equals(String),
    Includes(String),
    Dash(String),
    Prefix(String),
    Suffix(String),
    Contains(String),
}

#[derive(Clone, Debug)]
struct AttrSel {
    name: String,
    op: AttrOp,
    insensitive: bool,
}

#[derive(Clone, Debug)]
enum Class {
    Root,
    Empty,
    Not(Vec<Complex>),
    Is(Vec<Complex>),
    Has(Vec<(Combinator, Complex)>),
    /// `:nth-child(a n + b of S)` and its kin: from the end, of the same type.
    Nth { a: i32, b: i32, last: bool, of_type: bool, of: Option<Vec<Complex>> },
    Only { of_type: bool },
    Disabled,
    Enabled,
    Checked,
    Focus,
    FocusVisible,
    FocusWithin,
    Active,
    Link,
    Open,
    PlaceholderShown,
    Required,
    Optional,
    ReadOnly,
    ReadWrite,
    Always,
    Never,
}

#[derive(Clone, Debug, Default)]
struct Compound {
    tag: Option<String>,
    id: Option<String>,
    classes: Vec<String>,
    attrs: Vec<AttrSel>,
    pseudos: Vec<Class>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Combinator {
    Descendant,
    Child,
    Next,
    Later,
}

/// A complex selector, its rightmost compound first, each with the combinator to the one left of it.
#[derive(Clone, Debug)]
struct Complex {
    parts: Vec<(Compound, Combinator)>,
}

#[derive(Clone, Debug)]
struct Selector {
    complex: Complex,
    specificity: (u32, u32, u32),
    pseudo: Option<Pseudo>,
}

#[derive(Clone, Debug)]
pub struct Declaration {
    pub name: String,
    pub value: String,
    pub important: bool,
}

#[derive(Clone, Debug)]
struct Rule {
    selector: Selector,
    declarations: Rc<Vec<Declaration>>,
    order: usize,
    /// The `@container` query it is in: evaluated against the nearest container above the element
    /// (its width as last laid out), or the screen before that is known.
    container: Option<Rc<String>>,
}

/// What `@media` asks about: the screen.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Media {
    pub width: f32,
    pub height: f32,
    pub dark: bool,
}

impl Default for Media {
    fn default() -> Media {
        Media { width: 412.0, height: 915.0, dark: false }
    }
}

pub struct Sheet {
    rules: Vec<Rule>,
    by_id: HashMap<String, Vec<usize>>,
    by_class: HashMap<String, Vec<usize>>,
    by_tag: HashMap<String, Vec<usize>>,
    others: Vec<usize>,
    /// Rules for `::before`, `::after`, `::placeholder` and `::marker`.
    pseudos: Vec<usize>,
    warnings: Vec<String>,
    media: Media,
    /// Compounds with a `:has()` left of a rule's subject (`.list:has(.on) .card`): an element
    /// matching one makes what is in it depend on its descendants (`has_context`).
    has_contexts: Vec<Compound>,
    /// While parsing: the `@container` query the rules being read are in.
    container: Option<Rc<String>>,
}

thread_local! {
    /// The sheets parsed last (a few: a rotation's two screens), each by its text and screen.
    static CACHE: std::cell::RefCell<Vec<(String, Media, Rc<Sheet>)>> = const { std::cell::RefCell::new(Vec::new()) };
}

impl Sheet {
    /// The UA stylesheet, then the page's `css`, for a screen: parsed once for each text and screen.
    pub fn of(css: &str, media: Media) -> Rc<Sheet> {
        CACHE.with(|cache| {
            if let Some((_, _, sheet)) = cache.borrow().iter().find(|(text, seen, _)| *seen == media && text == css) {
                return sheet.clone();
            }
            let mut sheet = Sheet { rules: Vec::new(), by_id: HashMap::default(), by_class: HashMap::default(), by_tag: HashMap::default(), others: Vec::new(), pseudos: Vec::new(), warnings: Vec::new(), media, has_contexts: Vec::new(), container: None };
            sheet.parse(UA, false);
            sheet.parse(css, true);
            sheet.index();
            let sheet = Rc::new(sheet);
            let mut cache = cache.borrow_mut();
            if cache.len() >= 3 {
                cache.remove(0);
            }
            cache.push((css.to_string(), media, sheet.clone()));
            sheet
        })
    }

    pub fn warnings(&self) -> &[String] {
        &self.warnings
    }

    fn warn(&mut self, said: String) {
        if !self.warnings.contains(&said) {
            self.warnings.push(said);
        }
    }

    /// Whether a rule's `@container` query holds for an element: against its nearest container's
    /// width (`Elem::container_width`), or the screen's when none is known.
    fn container_holds<'a, E: Elem<'a>>(&self, rule: &Rule, element: E) -> bool {
        let Some(query) = &rule.container else { return true };
        let mut at = element.parent();
        while let Some(up) = at {
            if let Some(width) = up.container_width() {
                return media_applies(query, Media { width, ..self.media });
            }
            at = up.parent();
        }
        media_applies(query, self.media)
    }

    /// Whether an element matches a compound with a `:has()` left of a rule's subject: what it holds
    /// then depends on its descendants, so a phone projects all of it again when one changes.
    pub fn has_context<'a, E: Elem<'a>>(&self, element: E) -> bool {
        self.has_contexts.iter().any(|compound| Matcher.compound(compound, element))
    }

    /// Each rule filed under its subject's id, else a class, else its tag (a browser's rule hash).
    fn index(&mut self) {
        for rule in &self.rules {
            for (compound, _) in rule.selector.complex.parts.iter().skip(1) {
                if compound.pseudos.iter().any(|pseudo| matches!(pseudo, Class::Has(_))) {
                    self.has_contexts.push(compound.clone());
                }
            }
        }
        for (at, rule) in self.rules.iter().enumerate() {
            if rule.selector.pseudo.is_some() {
                self.pseudos.push(at);
                continue;
            }
            let subject = &rule.selector.complex.parts[0].0;
            if let Some(id) = &subject.id {
                self.by_id.entry(id.clone()).or_default().push(at);
            } else if let Some(class) = subject.classes.first() {
                self.by_class.entry(class.clone()).or_default().push(at);
            } else if let Some(tag) = &subject.tag {
                self.by_tag.entry(tag.clone()).or_default().push(at);
            } else {
                self.others.push(at);
            }
        }
    }

    fn parse(&mut self, css: &str, page: bool) {
        let text = strip_comments(css);
        let bytes = text.as_bytes();
        let mut at = 0;
        while at < bytes.len() {
            while at < bytes.len() && (bytes[at] as char).is_whitespace() {
                at += 1;
            }
            if at >= bytes.len() {
                break;
            }
            // A prelude runs to its block's `{`, or, for an at-rule, to a `;` (`@import …;`).
            let Some((end, open)) = prelude_end(&text, at) else { break };
            let prelude = text[at..end].trim().to_string();
            if !open {
                at = end + 1;
                if page && let Some(rule) = prelude.strip_prefix('@') {
                    let name = rule.split_whitespace().next().unwrap_or(rule);
                    if !matches!(name, "charset" | "layer" | "namespace") {
                        self.warn(format!("CSS @{name} isn't on phones yet: ignored"));
                    }
                }
                continue;
            }
            let close = matching(&text, end);
            let body = &text[end + 1..close.min(text.len())];
            at = close + 1;
            if let Some(rule) = prelude.strip_prefix('@') {
                let name = rule.split(|c: char| c.is_whitespace() || c == '(').next().unwrap_or(rule).to_ascii_lowercase();
                let condition = rule[name.len()..].trim();
                match name.as_str() {
                    "media" => {
                        if media_applies(condition, self.media) {
                            self.parse(body, page);
                        }
                    }
                    "container" => {
                        // Its rules hold where their element's nearest container answers the query
                        // (`compute`), the screen standing in before a layout has said its width.
                        let query = condition.trim_start_matches(|c: char| c.is_alphanumeric() || c == '-' || c == '_').trim().to_string();
                        let outer = self.container.replace(Rc::new(query));
                        self.parse(body, page);
                        self.container = outer;
                    }
                    "supports" => {
                        if supports(condition) {
                            self.parse(body, page);
                        }
                    }
                    "layer" | "scope" | "starting-style" if name == "layer" => self.parse(body, page),
                    "font-face" | "keyframes" | "-webkit-keyframes" | "page" | "property" | "counter-style" | "view-transition" | "starting-style" | "scope" | "font-feature-values" => {
                        if page && name != "view-transition" && name != "property" {
                            self.warn(format!("CSS @{name} isn't on phones yet: ignored"));
                        }
                    }
                    other => {
                        if page {
                            self.warn(format!("CSS @{other} isn't on phones yet: ignored"));
                        }
                    }
                }
                continue;
            }
            let declarations = Rc::new(declarations(body));
            for selector in values::split(&prelude, Some(',')) {
                match parse_selector(&selector) {
                    Ok(Some(selector)) => {
                        let order = self.rules.len();
                        self.rules.push(Rule { selector, declarations: declarations.clone(), order, container: self.container.clone() });
                    }
                    Ok(None) => {}
                    Err(why) => {
                        if page {
                            self.warn(format!("CSS selector `{}` isn't on phones yet ({why}): its rule is ignored", one_line(&selector)));
                        }
                    }
                }
            }
            if page {
                for declaration in declarations.iter() {
                    let name = declaration.name.as_str();
                    if !name.starts_with("--") && !KNOWN.contains(&name) && !QUIET.contains(&name) && !name.starts_with("-webkit-") && !name.starts_with("-moz-") {
                        self.warn(format!("CSS `{name}` isn't on phones yet: ignored"));
                    }
                }
            }
        }
    }

    /// The computed values of an element (or of its `pseudo`-element), given its parent's, with its
    /// own `style` attribute's after its rules.
    pub fn compute<'a, E: Elem<'a>>(&self, element: E, parent: &Computed, inline: &[(String, String)], pseudo: Option<Pseudo>) -> Computed {
        let mut matched: Vec<&Rule> = Vec::new();
        let state = Matcher;
        match pseudo {
            Some(wanted) => {
                for &at in &self.pseudos {
                    let rule = &self.rules[at];
                    if rule.selector.pseudo == Some(wanted) && state.complex(&rule.selector.complex, element) && self.container_holds(rule, element) {
                        matched.push(rule);
                    }
                }
            }
            None => {
                let mut candidates: Vec<usize> = Vec::new();
                if let Some(id) = element.attr("id")
                    && let Some(rules) = self.by_id.get(id)
                {
                    candidates.extend(rules);
                }
                if let Some(classes) = element.attr("class") {
                    for class in classes.split_ascii_whitespace() {
                        if let Some(rules) = self.by_class.get(class) {
                            candidates.extend(rules);
                        }
                    }
                }
                if let Some(rules) = self.by_tag.get(element.tag()) {
                    candidates.extend(rules);
                }
                candidates.extend(&self.others);
                candidates.sort_unstable();
                candidates.dedup();
                for at in candidates {
                    let rule = &self.rules[at];
                    if state.complex(&rule.selector.complex, element) && self.container_holds(rule, element) {
                        matched.push(rule);
                    }
                }
            }
        }
        matched.sort_by_key(|rule| (rule.selector.specificity, rule.order));
        let mut ordered: Vec<(&str, &str)> = Vec::new();
        for rule in &matched {
            for declaration in rule.declarations.iter().filter(|d| !d.important) {
                ordered.push((&declaration.name, &declaration.value));
            }
        }
        for (name, value) in inline {
            ordered.push((name, value));
        }
        for rule in &matched {
            for declaration in rule.declarations.iter().filter(|d| d.important) {
                ordered.push((&declaration.name, &declaration.value));
            }
        }
        Computed::cascade(parent, &ordered)
    }
}

/// The properties the phone does. SVG's paint properties are an `<svg>`'s shapes' (svg.rs).
const KNOWN: &[&str] = &[
    "display", "position", "top", "right", "bottom", "left", "inset", "z-index", "float", "clear",
    "width", "height", "min-width", "max-width", "min-height", "max-height", "aspect-ratio", "box-sizing",
    "margin", "margin-top", "margin-right", "margin-bottom", "margin-left", "margin-block", "margin-inline", "margin-block-start", "margin-block-end", "margin-inline-start", "margin-inline-end",
    "padding", "padding-top", "padding-right", "padding-bottom", "padding-left", "padding-block", "padding-inline", "padding-block-start", "padding-block-end", "padding-inline-start", "padding-inline-end",
    "inset-block", "inset-inline", "inset-block-start", "inset-block-end", "inset-inline-start", "inset-inline-end", "block-size", "inline-size", "min-block-size", "min-inline-size", "max-block-size", "max-inline-size",
    "border", "border-width", "border-style", "border-color", "border-top", "border-right", "border-bottom", "border-left", "border-block", "border-inline", "border-block-start", "border-block-end", "border-inline-start", "border-inline-end",
    "border-top-width", "border-right-width", "border-bottom-width", "border-left-width", "border-top-color", "border-right-color", "border-bottom-color", "border-left-color", "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
    "border-radius", "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius", "border-bottom-left-radius", "border-start-start-radius", "border-start-end-radius", "border-end-start-radius", "border-end-end-radius",
    "outline", "outline-width", "outline-style", "outline-color", "outline-offset",
    "flex", "flex-direction", "flex-wrap", "flex-flow", "flex-grow", "flex-shrink", "flex-basis", "order",
    "gap", "row-gap", "column-gap", "grid-gap", "grid-row-gap", "grid-column-gap",
    "align-items", "align-self", "align-content", "justify-content", "justify-items", "justify-self", "place-items", "place-content", "place-self",
    "grid", "grid-template", "grid-template-columns", "grid-template-rows", "grid-template-areas", "grid-auto-columns", "grid-auto-rows", "grid-auto-flow", "grid-area", "grid-row", "grid-column", "grid-row-start", "grid-row-end", "grid-column-start", "grid-column-end",
    "overflow", "overflow-x", "overflow-y", "overflow-wrap", "word-wrap", "word-break", "text-overflow", "line-clamp", "-webkit-line-clamp", "-webkit-box-orient",
    "color", "background", "background-color", "background-image", "opacity", "visibility", "box-shadow", "transform", "translate", "scale", "rotate", "transform-origin",
    "font", "font-family", "font-size", "font-weight", "font-style", "font-variant-numeric", "line-height", "letter-spacing", "word-spacing", "text-align", "text-transform", "text-decoration", "text-decoration-line", "text-decoration-color", "text-decoration-style", "text-decoration-thickness", "text-underline-offset",
    "white-space", "white-space-collapse", "text-wrap", "text-wrap-mode", "text-indent", "vertical-align", "list-style", "list-style-type", "list-style-position", "content", "pointer-events", "object-fit", "object-position", "hyphens",
    "clip", "clip-path",
    "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-dasharray", "stroke-dashoffset", "fill-opacity", "stroke-opacity", "text-anchor", "rx", "ry", "r",
];

/// Properties a phone has no use for, or does its own way: not warned of.
const QUIET: &[&str] = &[
    "cursor", "user-select", "pointer-events", "animation", "animation-name", "animation-duration", "animation-timing-function", "animation-delay", "animation-iteration-count", "animation-direction", "animation-fill-mode", "animation-play-state", "transition-behavior", "transition", "transition-property", "transition-duration", "transition-timing-function", "transition-delay", "will-change", "touch-action", "appearance", "resize",
    "scrollbar-width", "scrollbar-color", "scrollbar-gutter", "scroll-behavior", "scroll-snap-type", "scroll-snap-align", "scroll-margin", "scroll-padding", "scroll-margin-top", "scroll-padding-top", "overscroll-behavior", "overscroll-behavior-x", "overscroll-behavior-y",
    "caret-color", "accent-color", "color-scheme", "tab-size", "text-rendering", "font-smoothing", "font-synthesis", "font-kerning", "font-optical-sizing", "font-feature-settings", "font-variation-settings", "text-size-adjust", "forced-color-adjust", "print-color-adjust",
    "contain", "content-visibility", "contain-intrinsic-size", "isolation", "container", "container-type", "container-name", "view-transition-name", "view-transition-class", "speak", "quotes", "counter-reset", "counter-increment",
    "transform-box", "backface-visibility", "vector-effect", "paint-order", "overflow-clip-margin", "box-decoration-break", "perspective", "image-rendering", "text-underline-position", "text-decoration-skip-ink", "interpolate-size", "field-sizing", "anchor-name", "position-anchor",
];

fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn strip_comments(css: &str) -> String {
    let mut out = String::with_capacity(css.len());
    let mut rest = css;
    while let Some(start) = rest.find("/*") {
        out.push_str(&rest[..start]);
        rest = match rest[start + 2..].find("*/") {
            Some(end) => &rest[start + 2 + end + 2..],
            None => "",
        };
    }
    out.push_str(rest);
    out
}

/// Where a prelude starting at `at` ends: its `{` (true), or a `;` before any (false).
fn prelude_end(text: &str, at: usize) -> Option<(usize, bool)> {
    let mut quote: Option<char> = None;
    let mut depth = 0;
    for (offset, c) in text[at..].char_indices() {
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            continue;
        }
        match c {
            '"' | '\'' => quote = Some(c),
            '(' | '[' => depth += 1,
            ')' | ']' => depth -= 1,
            '{' if depth <= 0 => return Some((at + offset, true)),
            ';' if depth <= 0 => return Some((at + offset, false)),
            _ => {}
        }
    }
    None
}

/// Where the `}` that closes the `{` at `open` is.
fn matching(text: &str, open: usize) -> usize {
    let mut depth = 0;
    let mut quote: Option<char> = None;
    for (at, c) in text[open..].char_indices() {
        if let Some(q) = quote {
            if c == q {
                quote = None;
            }
            continue;
        }
        match c {
            '"' | '\'' => quote = Some(c),
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return open + at;
                }
            }
            _ => {}
        }
    }
    text.len()
}

/// Whether a `@media` (or `@container`) query holds on this screen. A list holds when one of its
/// queries does; `not` and `only` are read.
pub fn media_applies(query: &str, media: Media) -> bool {
    let query = query.to_ascii_lowercase();
    values::split(&query, Some(',')).iter().any(|one| {
        let one = one.trim();
        let (negated, one) = match one.strip_prefix("not ") {
            Some(rest) => (true, rest),
            None => (false, one.strip_prefix("only ").unwrap_or(one)),
        };
        let holds = one.split(" and ").all(|part| feature(part.trim(), media));
        holds != negated
    })
}

fn feature(part: &str, media: Media) -> bool {
    let part = part.trim();
    if matches!(part, "screen" | "all" | "") {
        return true;
    }
    if matches!(part, "print" | "speech") {
        return false;
    }
    if let Some(inner) = part.strip_prefix("not ") {
        return !feature(inner, media);
    }
    let inner = part.trim_start_matches('(').trim_end_matches(')').trim();
    let ctx = Ctx { vw: media.width, vh: media.height, ..Ctx::default() };
    // Ranges: `(width <= 600px)`, `(400px < width)`.
    for op in ["<=", ">=", "<", ">"] {
        if let Some((left, right)) = inner.split_once(op) {
            let (left, right) = (left.trim(), right.trim());
            let size = |name: &str| match name {
                "width" => Some(media.width),
                "height" => Some(media.height),
                _ => None,
            };
            let (have, given, flipped) = match (size(left), size(right)) {
                (Some(have), None) => (have, values::px(right, ctx), false),
                (None, Some(have)) => (have, values::px(left, ctx), true),
                _ => return false,
            };
            let Some(given) = given else { return false };
            let op = if flipped { match op { "<=" => ">=", ">=" => "<=", "<" => ">", _ => "<" } } else { op };
            return match op {
                "<=" => have <= given,
                ">=" => have >= given,
                "<" => have < given,
                _ => have > given,
            };
        }
    }
    let Some((name, value)) = inner.split_once(':') else {
        return matches!(inner, "color" | "hover" | "pointer" | "any-pointer" | "orientation" | "width" | "height");
    };
    let (name, value) = (name.trim(), value.trim());
    let length = values::px(value, ctx);
    match name {
        "max-width" => length.is_some_and(|n| media.width <= n),
        "min-width" => length.is_some_and(|n| media.width >= n),
        "max-height" => length.is_some_and(|n| media.height <= n),
        "min-height" => length.is_some_and(|n| media.height >= n),
        "orientation" => (value == "portrait") == (media.height >= media.width),
        "prefers-color-scheme" => (value == "dark") == media.dark,
        "prefers-reduced-motion" | "prefers-contrast" | "forced-colors" | "inverted-colors" => matches!(value, "no-preference" | "none"),
        "hover" | "any-hover" => value == "none",
        "pointer" | "any-pointer" => value == "coarse",
        "display-mode" => value == "standalone",
        _ => false,
    }
}

/// Whether `@supports` holds: a property this phone does (`(display: grid)`), `selector(…)`, and
/// `not`, `and`, `or`.
fn supports(condition: &str) -> bool {
    let condition = condition.trim();
    if let Some(rest) = condition.strip_prefix("not ") {
        return !supports(rest);
    }
    let parts = values::split(condition, None);
    if parts.iter().any(|part| part == "or") {
        return parts.iter().filter(|part| *part != "or").any(|part| supports(part));
    }
    if parts.iter().any(|part| part == "and") {
        return parts.iter().filter(|part| *part != "and").all(|part| supports(part));
    }
    let inner = condition.trim_start_matches('(').trim_end_matches(')').trim();
    if inner.starts_with("selector") {
        return true;
    }
    match inner.split_once(':') {
        Some((name, value)) => {
            let (name, value) = (name.trim(), value.trim());
            KNOWN.contains(&name) && !value.contains("base-select") && !value.starts_with("anchor")
        }
        None => supports(inner.trim_start_matches('(').trim_end_matches(')')),
    }
}

fn declarations(body: &str) -> Vec<Declaration> {
    values::split(body, Some(';'))
        .into_iter()
        .filter_map(|declaration| {
            let (name, value) = declaration.split_once(':')?;
            let name = name.trim();
            let name = if name.starts_with("--") { name.to_string() } else { name.to_ascii_lowercase() };
            let mut value = value.trim().to_string();
            let mut important = false;
            if let Some(at) = value.to_ascii_lowercase().rfind("!important") {
                value.truncate(at);
                value = value.trim().to_string();
                important = true;
            }
            if name.is_empty() || (value.is_empty() && !name.starts_with("--")) || name.contains('{') {
                return None;
            }
            Some(Declaration { name, value, important })
        })
        .collect()
}

// ---- Selectors ----

struct Reader<'t> {
    chars: Vec<char>,
    at: usize,
    _text: &'t str,
}

impl Reader<'_> {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }
    fn skip_space(&mut self) -> bool {
        let start = self.at;
        while self.peek().is_some_and(char::is_whitespace) {
            self.at += 1;
        }
        self.at > start
    }
    fn ident(&mut self) -> String {
        let mut out = String::new();
        while let Some(c) = self.peek() {
            if c.is_alphanumeric() || c == '-' || c == '_' || !c.is_ascii() {
                out.push(c);
                self.at += 1;
            } else if c == '\\' {
                self.at += 1;
                if let Some(escaped) = self.peek() {
                    out.push(escaped);
                    self.at += 1;
                }
            } else {
                break;
            }
        }
        out
    }
    /// What is in the parentheses here (the `(` already read), to the matching `)`.
    fn group(&mut self) -> Result<String, String> {
        let mut depth = 1;
        let mut out = String::new();
        let mut quote: Option<char> = None;
        while let Some(c) = self.peek() {
            self.at += 1;
            if let Some(q) = quote {
                if c == q {
                    quote = None;
                }
                out.push(c);
                continue;
            }
            match c {
                '"' | '\'' => quote = Some(c),
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        return Ok(out);
                    }
                }
                _ => {}
            }
            out.push(c);
        }
        Err("an unclosed parenthesis".into())
    }
}

/// A selector, or none for one the phone never shows (`::view-transition-old`, `::selection`), or
/// why it can't.
fn parse_selector(text: &str) -> Result<Option<Selector>, String> {
    let mut specificity = (0, 0, 0);
    let mut pseudo = None;
    let complex = match parse_complex(text, &mut specificity, Some(&mut pseudo)) {
        Ok(complex) => complex,
        Err(why) if why == "-" => return Ok(None),
        Err(why) => return Err(why),
    };
    Ok(Some(Selector { complex, specificity, pseudo }))
}

fn parse_list(text: &str, specificity: &mut (u32, u32, u32), most: bool) -> Result<Vec<Complex>, String> {
    let mut best = (0, 0, 0);
    let mut out = Vec::new();
    for part in values::split(text, Some(',')) {
        let mut own = (0, 0, 0);
        out.push(parse_complex(&part, &mut own, None)?);
        if own > best {
            best = own;
        }
    }
    if most {
        specificity.0 += best.0;
        specificity.1 += best.1;
        specificity.2 += best.2;
    }
    Ok(out)
}

fn parse_complex(text: &str, specificity: &mut (u32, u32, u32), mut pseudo: Option<&mut Option<Pseudo>>) -> Result<Complex, String> {
    let mut reader = Reader { chars: text.trim().chars().collect(), at: 0, _text: text };
    let mut compounds: Vec<(Compound, Combinator)> = Vec::new();
    let mut combinator = Combinator::Descendant;
    loop {
        reader.skip_space();
        if reader.peek().is_none() {
            break;
        }
        if let Some(c @ ('>' | '+' | '~')) = reader.peek() {
            reader.at += 1;
            combinator = match c {
                '>' => Combinator::Child,
                '+' => Combinator::Next,
                _ => Combinator::Later,
            };
            continue;
        }
        let compound = parse_compound(&mut reader, specificity, pseudo.as_deref_mut())?;
        compounds.push((compound, combinator));
        combinator = Combinator::Descendant;
        let spaced = reader.skip_space();
        if spaced {
            combinator = Combinator::Descendant;
        }
    }
    if compounds.is_empty() {
        return Err("empty".into());
    }
    // Rightmost first, each with the combinator joining it to the one left of it.
    let mut parts = Vec::new();
    for at in (0..compounds.len()).rev() {
        let joined = if at > 0 { compounds[at].1 } else { Combinator::Descendant };
        parts.push((compounds[at].0.clone(), joined));
    }
    Ok(Complex { parts })
}

fn parse_compound(reader: &mut Reader, specificity: &mut (u32, u32, u32), mut pseudo: Option<&mut Option<Pseudo>>) -> Result<Compound, String> {
    let mut compound = Compound::default();
    if reader.peek() == Some('*') {
        reader.at += 1;
    } else if reader.peek().is_some_and(|c| c.is_alphabetic() || c == '_' || c == '-') {
        let tag = reader.ident().to_ascii_lowercase();
        compound.tag = Some(tag);
        specificity.2 += 1;
    }
    loop {
        match reader.peek() {
            Some('.') => {
                reader.at += 1;
                compound.classes.push(reader.ident());
                specificity.1 += 1;
            }
            Some('#') => {
                reader.at += 1;
                compound.id = Some(reader.ident());
                specificity.0 += 1;
            }
            Some('[') => {
                reader.at += 1;
                let mut inner = String::new();
                let mut quote: Option<char> = None;
                while let Some(c) = reader.peek() {
                    reader.at += 1;
                    if let Some(q) = quote {
                        if c == q {
                            quote = None;
                        }
                        inner.push(c);
                        continue;
                    }
                    if c == '"' || c == '\'' {
                        quote = Some(c);
                    } else if c == ']' {
                        break;
                    }
                    inner.push(c);
                }
                compound.attrs.push(parse_attr(&inner)?);
                specificity.1 += 1;
            }
            Some(':') => {
                reader.at += 1;
                let element = reader.peek() == Some(':');
                if element {
                    reader.at += 1;
                }
                let name = reader.ident().to_ascii_lowercase();
                let args = if reader.peek() == Some('(') {
                    reader.at += 1;
                    Some(reader.group()?)
                } else {
                    None
                };
                let is_element = element || matches!(name.as_str(), "before" | "after" | "first-line" | "first-letter");
                if is_element {
                    let found = match name.as_str() {
                        "before" => Pseudo::Before,
                        "after" => Pseudo::After,
                        "placeholder" => Pseudo::Placeholder,
                        "marker" => Pseudo::Marker,
                        _ => return Err("-".into()),
                    };
                    match pseudo.as_deref_mut() {
                        Some(slot) if slot.is_none() => *slot = Some(found),
                        _ => return Err(format!("::{name} here")),
                    }
                    specificity.2 += 1;
                    continue;
                }
                compound.pseudos.push(parse_class(&name, args, specificity)?);
            }
            _ => break,
        }
    }
    Ok(compound)
}

fn parse_attr(inner: &str) -> Result<AttrSel, String> {
    let inner = inner.trim();
    let ops = ["~=", "|=", "^=", "$=", "*=", "="];
    for op in ops {
        if let Some((name, value)) = inner.split_once(op) {
            let value = value.trim();
            let (value, insensitive) = match value.strip_suffix(" i").or_else(|| value.strip_suffix(" I")) {
                Some(rest) => (rest.trim(), true),
                None => (value.strip_suffix(" s").unwrap_or(value).trim(), false),
            };
            let value = value.trim_matches(|c| c == '"' || c == '\'').to_string();
            let value = if insensitive { value.to_ascii_lowercase() } else { value };
            let name = name.trim().to_ascii_lowercase();
            let op = match op {
                "~=" => AttrOp::Includes(value),
                "|=" => AttrOp::Dash(value),
                "^=" => AttrOp::Prefix(value),
                "$=" => AttrOp::Suffix(value),
                "*=" => AttrOp::Contains(value),
                _ => AttrOp::Equals(value),
            };
            return Ok(AttrSel { name, op, insensitive });
        }
    }
    Ok(AttrSel { name: inner.to_ascii_lowercase(), op: AttrOp::Exists, insensitive: false })
}

/// `An+B` (`odd`, `even`, `3`, `-n+3`, `2n`).
fn an_b(text: &str) -> Option<(i32, i32)> {
    let text: String = text.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_ascii_lowercase();
    match text.as_str() {
        "odd" => return Some((2, 1)),
        "even" => return Some((2, 0)),
        _ => {}
    }
    match text.split_once('n') {
        Some((a, b)) => {
            let a = match a {
                "" | "+" => 1,
                "-" => -1,
                a => a.parse().ok()?,
            };
            let b = if b.is_empty() { 0 } else { b.parse().ok()? };
            Some((a, b))
        }
        None => Some((0, text.parse().ok()?)),
    }
}

fn parse_class(name: &str, args: Option<String>, specificity: &mut (u32, u32, u32)) -> Result<Class, String> {
    let class = match (name, args) {
        ("where", Some(args)) => return Ok(Class::Is(parse_list(&args, specificity, false)?)),
        ("is" | "matches" | "any" | "-webkit-any", Some(args)) => return Ok(Class::Is(parse_list(&args, specificity, true)?)),
        ("not", Some(args)) => return Ok(Class::Not(parse_list(&args, specificity, true)?)),
        ("has", Some(args)) => {
            let mut best = (0, 0, 0);
            let mut relative = Vec::new();
            for part in values::split(&args, Some(',')) {
                let part = part.trim();
                let (combinator, rest) = match part.chars().next() {
                    Some('>') => (Combinator::Child, &part[1..]),
                    Some('+') => (Combinator::Next, &part[1..]),
                    Some('~') => (Combinator::Later, &part[1..]),
                    _ => (Combinator::Descendant, part),
                };
                let mut own = (0, 0, 0);
                relative.push((combinator, parse_complex(rest, &mut own, None)?));
                best = best.max(own);
            }
            specificity.0 += best.0;
            specificity.1 += best.1;
            specificity.2 += best.2;
            return Ok(Class::Has(relative));
        }
        ("nth-child" | "nth-last-child" | "nth-of-type" | "nth-last-of-type", Some(args)) => {
            let (formula, of) = match args.split_once(" of ") {
                Some((formula, of)) => (formula.to_string(), Some(parse_list(of, specificity, true)?)),
                None => (args.clone(), None),
            };
            let (a, b) = an_b(&formula).ok_or_else(|| format!(":{name}({args})"))?;
            Class::Nth { a, b, last: name.contains("last"), of_type: name.ends_with("of-type"), of }
        }
        ("first-child", None) => Class::Nth { a: 0, b: 1, last: false, of_type: false, of: None },
        ("last-child", None) => Class::Nth { a: 0, b: 1, last: true, of_type: false, of: None },
        ("first-of-type", None) => Class::Nth { a: 0, b: 1, last: false, of_type: true, of: None },
        ("last-of-type", None) => Class::Nth { a: 0, b: 1, last: true, of_type: true, of: None },
        ("only-child", None) => Class::Only { of_type: false },
        ("only-of-type", None) => Class::Only { of_type: true },
        ("root" | "scope", None) => Class::Root,
        ("empty", None) => Class::Empty,
        ("disabled", None) => Class::Disabled,
        ("enabled", None) => Class::Enabled,
        ("checked", None) => Class::Checked,
        ("focus", None) => Class::Focus,
        ("focus-visible", None) => Class::FocusVisible,
        ("focus-within", None) => Class::FocusWithin,
        ("active", None) => Class::Active,
        ("link" | "any-link", None) => Class::Link,
        ("open", None) => Class::Open,
        ("placeholder-shown", None) => Class::PlaceholderShown,
        ("required", None) => Class::Required,
        ("optional", None) => Class::Optional,
        ("read-only", None) => Class::ReadOnly,
        ("read-write", None) => Class::ReadWrite,
        // What a phone always is, or never is.
        ("defined" | "valid" | "in-range" | "lang" | "dir" | "ltr", _) => Class::Always,
        ("hover" | "visited" | "target" | "target-within" | "invalid" | "user-invalid" | "out-of-range" | "autofill" | "-webkit-autofill" | "modal" | "fullscreen" | "popover-open" | "indeterminate" | "default" | "picture-in-picture" | "playing" | "paused" | "current" | "past" | "future", _) => Class::Never,
        (other, _) => return Err(format!(":{other}")),
    };
    specificity.1 += 1;
    Ok(class)
}

// ---- Matching ----

struct Matcher;

impl Matcher {
    fn complex<'a, E: Elem<'a>>(&self, complex: &Complex, element: E) -> bool {
        self.from(&complex.parts, element, &|_| true)
    }

    /// Whether `parts` (rightmost first) match with `element` as the rightmost, and the leftmost
    /// matched element passes `anchored` (`:has()`'s relation to its anchor; always, otherwise).
    fn from<'a, E: Elem<'a>>(&self, parts: &[(Compound, Combinator)], element: E, anchored: &dyn Fn(E) -> bool) -> bool {
        let Some(((compound, combinator), rest)) = parts.split_first() else { return true };
        if !self.compound(compound, element) {
            return false;
        }
        if rest.is_empty() {
            return anchored(element);
        }
        match combinator {
            Combinator::Child => element.parent().is_some_and(|parent| self.from(rest, parent, anchored)),
            Combinator::Descendant => {
                let mut at = element.parent();
                while let Some(up) = at {
                    if self.from(rest, up, anchored) {
                        return true;
                    }
                    at = up.parent();
                }
                false
            }
            Combinator::Next => element.prev().is_some_and(|prev| self.from(rest, prev, anchored)),
            Combinator::Later => {
                let mut at = element.prev();
                while let Some(prev) = at {
                    if self.from(rest, prev, anchored) {
                        return true;
                    }
                    at = prev.prev();
                }
                false
            }
        }
    }

    fn compound<'a, E: Elem<'a>>(&self, compound: &Compound, element: E) -> bool {
        if let Some(tag) = &compound.tag
            && !element.tag().eq_ignore_ascii_case(tag)
        {
            return false;
        }
        if let Some(id) = &compound.id
            && element.attr("id") != Some(id.as_str())
        {
            return false;
        }
        if !compound.classes.iter().all(|class| element.has_class(class)) {
            return false;
        }
        if !compound.attrs.iter().all(|attr| attr_matches(attr, element)) {
            return false;
        }
        compound.pseudos.iter().all(|pseudo| self.class(pseudo, element))
    }

    fn class<'a, E: Elem<'a>>(&self, class: &Class, element: E) -> bool {
        let tag = element.tag();
        let form = matches!(tag, "button" | "input" | "select" | "textarea" | "optgroup" | "option" | "fieldset");
        match class {
            Class::Root => element.parent().is_none(),
            Class::Empty => element.is_empty(),
            Class::Not(list) => !list.iter().any(|complex| self.complex(complex, element)),
            Class::Is(list) => list.iter().any(|complex| self.complex(complex, element)),
            Class::Has(list) => list.iter().any(|(combinator, complex)| self.has(*combinator, complex, element)),
            Class::Nth { a, b, last, of_type, of } => {
                let counts = |other: E| (!*of_type || other.tag() == tag) && of.as_ref().is_none_or(|list| list.iter().any(|complex| self.complex(complex, other)));
                if !counts(element) {
                    return false;
                }
                let mut index = 1;
                let mut at = if *last { element.next() } else { element.prev() };
                while let Some(other) = at {
                    if counts(other) {
                        index += 1;
                    }
                    at = if *last { other.next() } else { other.prev() };
                }
                if *a == 0 {
                    index == *b
                } else {
                    let n = index - b;
                    n % a == 0 && n / a >= 0
                }
            }
            Class::Only { of_type } => {
                let same = |other: E| !*of_type || other.tag() == tag;
                let mut at = element.prev();
                while let Some(other) = at {
                    if same(other) {
                        return false;
                    }
                    at = other.prev();
                }
                let mut at = element.next();
                while let Some(other) = at {
                    if same(other) {
                        return false;
                    }
                    at = other.next();
                }
                true
            }
            Class::Disabled => form && disabled(element),
            Class::Enabled => form && !disabled(element),
            Class::Checked => (tag == "input" && element.state(State::Checked)) || (tag == "option" && element.attr("selected").is_some()),
            Class::Focus | Class::FocusVisible => element.state(State::Focus),
            Class::FocusWithin => {
                if element.state(State::Focus) {
                    return true;
                }
                descendants(element).any(|each| each.state(State::Focus))
            }
            Class::Active => element.state(State::Active),
            Class::Link => matches!(tag, "a" | "area") && element.attr("href").is_some(),
            Class::Open => matches!(tag, "details" | "dialog") && element.attr("open").is_some(),
            Class::PlaceholderShown => matches!(tag, "input" | "textarea") && element.attr("placeholder").is_some() && element.state(State::Blank),
            Class::Required => form && element.attr("required").is_some(),
            Class::Optional => form && element.attr("required").is_none(),
            Class::ReadOnly => !(matches!(tag, "input" | "textarea") && element.attr("readonly").is_none() && !disabled(element)),
            Class::ReadWrite => matches!(tag, "input" | "textarea") && element.attr("readonly").is_none() && !disabled(element),
            Class::Always => true,
            Class::Never => false,
        }
    }

    /// `:has()`: an element related to `anchor` by `combinator` that `complex` matches.
    fn has<'a, E: Elem<'a>>(&self, combinator: Combinator, complex: &Complex, anchor: E) -> bool {
        let anchored = |leftmost: E| -> bool {
            match combinator {
                Combinator::Child => leftmost.parent().is_some_and(|parent| parent.is(anchor)),
                Combinator::Descendant => {
                    let mut at = leftmost.parent();
                    while let Some(up) = at {
                        if up.is(anchor) {
                            return true;
                        }
                        at = up.parent();
                    }
                    false
                }
                Combinator::Next => leftmost.prev().is_some_and(|prev| prev.is(anchor)),
                Combinator::Later => {
                    let mut at = leftmost.prev();
                    while let Some(prev) = at {
                        if prev.is(anchor) {
                            return true;
                        }
                        at = prev.prev();
                    }
                    false
                }
            }
        };
        match combinator {
            Combinator::Child | Combinator::Descendant => descendants(anchor).any(|each| self.from(&complex.parts, each, &anchored)),
            Combinator::Next | Combinator::Later => {
                let mut at = anchor.next();
                while let Some(sibling) = at {
                    if self.from(&complex.parts, sibling, &anchored) || descendants(sibling).any(|each| self.from(&complex.parts, each, &anchored)) {
                        return true;
                    }
                    at = sibling.next();
                }
                false
            }
        }
    }
}

fn descendants<'a, E: Elem<'a>>(element: E) -> impl Iterator<Item = E> {
    let mut stack: Vec<E> = element.first_child().into_iter().collect();
    std::iter::from_fn(move || {
        let next = stack.pop()?;
        if let Some(sibling) = next.next() {
            stack.push(sibling);
        }
        if let Some(child) = next.first_child() {
            stack.push(child);
        }
        Some(next)
    })
}

fn disabled<'a, E: Elem<'a>>(element: E) -> bool {
    if element.attr("disabled").is_some() {
        return true;
    }
    let mut at = element.parent();
    while let Some(up) = at {
        if up.tag() == "fieldset" && up.attr("disabled").is_some() {
            return true;
        }
        at = up.parent();
    }
    false
}

fn attr_matches<'a, E: Elem<'a>>(sel: &AttrSel, element: E) -> bool {
    let Some(value) = element.attr(&sel.name) else { return false };
    let owned;
    let value = if sel.insensitive {
        owned = value.to_ascii_lowercase();
        owned.as_str()
    } else {
        value
    };
    match &sel.op {
        AttrOp::Exists => true,
        AttrOp::Equals(want) => value == want,
        AttrOp::Includes(want) => value.split_ascii_whitespace().any(|each| each == want),
        AttrOp::Dash(want) => value == want || value.strip_prefix(want.as_str()).is_some_and(|rest| rest.starts_with('-')),
        AttrOp::Prefix(want) => !want.is_empty() && value.starts_with(want.as_str()),
        AttrOp::Suffix(want) => !want.is_empty() && value.ends_with(want.as_str()),
        AttrOp::Contains(want) => !want.is_empty() && value.contains(want.as_str()),
    }
}

// ---- Computed values ----

/// An element's computed values: its longhands (after `var()`s, shorthands and inheritance), its
/// font size and colour, and the custom properties in scope.
#[derive(Clone, Debug)]
pub struct Computed {
    values: HashMap<String, String>,
    custom: Rc<HashMap<String, String>>,
    pub font_size: f32,
    pub color: Argb,
    pub ctx: Ctx,
}

/// What a child inherits (besides `font-size` and `color`, worked out on their own).
const INHERITED: &[&str] = &[
    "font-family", "font-weight", "font-style", "font-variant-numeric", "line-height", "letter-spacing", "word-spacing", "text-align", "text-transform", "text-indent",
    "white-space", "visibility", "overflow-wrap", "word-break", "hyphens", "list-style-type", "list-style-position", "cursor", "pointer-events", "direction", "text-wrap", "-webkit-text-fill-color", "-webkit-line-clamp-inherited",
];

impl PartialEq for Computed {
    /// The same values (what an element's children inherit and its selectors' context gives it).
    fn eq(&self, other: &Computed) -> bool {
        self.font_size == other.font_size && self.color == other.color && self.ctx == other.ctx && self.values == other.values && (Rc::ptr_eq(&self.custom, &other.custom) || self.custom == other.custom)
    }
}

impl Computed {
    /// The values above the root element: the screen's (`rem` and the viewport for lengths).
    pub fn root(ctx: Ctx) -> Computed {
        Computed { values: HashMap::default(), custom: Rc::new(HashMap::default()), font_size: 16.0, color: 0xff000000, ctx: Ctx { em: 16.0, ..ctx } }
    }

    fn cascade(parent: &Computed, ordered: &[(&str, &str)]) -> Computed {
        let mut custom = parent.custom.clone();
        for (name, value) in ordered {
            if name.starts_with("--") {
                Rc::make_mut(&mut custom).insert(name.to_string(), value.trim().to_string());
            }
        }
        let mut values: HashMap<String, String> = HashMap::default();
        for name in INHERITED {
            if let Some(value) = parent.values.get(*name) {
                values.insert(name.to_string(), value.clone());
            }
        }
        let mut longhands = Vec::new();
        for (name, value) in ordered {
            if name.starts_with("--") {
                continue;
            }
            let value = if value.contains("var(") { resolve_vars(value, &custom, 0) } else { value.to_string() };
            let value = value.trim();
            if value.is_empty() {
                continue;
            }
            longhands.clear();
            expand(name, value, &mut longhands);
            for (long, value) in longhands.drain(..) {
                match value.to_ascii_lowercase().as_str() {
                    "inherit" => match parent.values.get(&long) {
                        Some(inherited) => {
                            values.insert(long, inherited.clone());
                        }
                        None => {
                            values.remove(&long);
                        }
                    },
                    "initial" | "revert" | "revert-layer" => {
                        values.remove(&long);
                    }
                    "unset" => {
                        if !INHERITED.contains(&long.as_str()) {
                            values.remove(&long);
                        }
                    }
                    _ => {
                        values.insert(long, value);
                    }
                }
            }
        }
        // The font size, then lengths in em resolve against it.
        let font_size = match values.get("font-size") {
            Some(size) => font_size(size, parent.font_size, parent.ctx),
            None => parent.font_size,
        };
        let ctx = Ctx { em: font_size, ..parent.ctx };
        let color = match values.get("color").map(String::as_str) {
            Some("inherit") | None => parent.color,
            Some(color) => values::colour(color, parent.color).unwrap_or(parent.color),
        };
        // What inherits as a length (`1.5em` in px), worked out where it is declared.
        for name in ["line-height", "letter-spacing", "word-spacing", "text-indent"] {
            if let Some(value) = values.get(name)
                && !parent.values.get(name).is_some_and(|inherited| inherited == value)
            {
                let resolved = match values::number(value) {
                    Some(_) if name == "line-height" => continue,
                    _ => match values::length(value, ctx) {
                        Some(values::Length::Px(px)) => format!("{px}px"),
                        Some(values::Length::Percent(p)) if name == "line-height" => format!("{}px", p * font_size / 100.0),
                        _ => continue,
                    },
                };
                values.insert(name.to_string(), resolved);
            }
        }
        if let Some(weight) = values.get("font-weight").cloned() {
            let parent_weight = parent.weight();
            let weight = match weight.as_str() {
                "normal" => 400,
                "bold" => 700,
                "bolder" => if parent_weight < 350 { 400 } else if parent_weight < 550 { 700 } else { 900 },
                "lighter" => if parent_weight < 550 { 100 } else if parent_weight < 750 { 400 } else { 700 },
                other => other.parse::<f32>().map(|w| w as i32).unwrap_or(parent_weight),
            };
            values.insert("font-weight".into(), weight.to_string());
        }
        Computed { values, custom, font_size, color, ctx }
    }

    /// A property's computed value (for one CSS inherits, its parent's when it sets none).
    pub fn get(&self, name: &str) -> Option<&str> {
        self.values.get(name).map(String::as_str)
    }

    pub fn is(&self, name: &str, value: &str) -> bool {
        self.get(name).is_some_and(|have| have.eq_ignore_ascii_case(value))
    }

    pub fn font_size(&self) -> f32 {
        self.font_size
    }

    /// The text's colour, as Android's `#AARRGGBB` (`currentColor` in an `<svg>`).
    pub fn colour(&self) -> String {
        values::argb(self.color)
    }

    pub fn weight(&self) -> i32 {
        self.get("font-weight").and_then(|w| w.parse().ok()).unwrap_or(400)
    }

    pub fn display(&self) -> &str {
        self.get("display").unwrap_or("inline")
    }

    pub fn hidden(&self) -> bool {
        self.is("display", "none")
    }

    /// A length property in px, a percentage of `basis`.
    pub fn px(&self, name: &str, basis: f32) -> Option<f32> {
        values::length(self.get(name)?, self.ctx)?.px(basis)
    }

    pub fn length(&self, name: &str) -> Option<values::Length> {
        values::length(self.get(name)?, self.ctx)
    }

    /// A colour property (`currentColor` the element's colour).
    pub fn colour_of(&self, name: &str) -> Option<Argb> {
        values::colour(self.get(name)?, self.color)
    }

    /// `line-height` in px (`normal`: none, the font's own).
    pub fn line_height(&self) -> Option<f32> {
        let value = self.get("line-height")?;
        if value == "normal" {
            return None;
        }
        if let Some(number) = values::number(value) {
            return Some(number * self.font_size);
        }
        values::px(value, self.ctx)
    }

    /// The custom properties in scope (for an `<svg>`'s own resolution).
    pub fn custom(&self, name: &str) -> Option<&str> {
        self.custom.get(name).map(String::as_str)
    }
}

/// `font-size`: a length, a percentage or `em` of the parent's, or a keyword.
fn font_size(value: &str, parent: f32, ctx: Ctx) -> f32 {
    let keyword = match value.trim() {
        "xx-small" => Some(9.0),
        "x-small" => Some(10.0),
        "small" => Some(13.0),
        "medium" => Some(16.0),
        "large" => Some(18.0),
        "x-large" => Some(24.0),
        "xx-large" => Some(32.0),
        "xxx-large" => Some(48.0),
        "smaller" => Some(parent / 1.2),
        "larger" => Some(parent * 1.2),
        _ => None,
    };
    if let Some(size) = keyword {
        return size;
    }
    match values::length(value, Ctx { em: parent, ..ctx }) {
        Some(values::Length::Px(px)) => px.max(0.0),
        Some(values::Length::Percent(p)) => parent * p / 100.0,
        Some(values::Length::Calc(calc)) => calc.eval(parent),
        _ => parent,
    }
}

/// `var(--name, fallback)`s, replaced with their values (theirs too, a few deep).
pub fn resolve_vars(value: &str, custom: &HashMap<String, String>, depth: u32) -> String {
    if depth > 8 {
        return String::new();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(start) = rest.find("var(") {
        out.push_str(&rest[..start]);
        let open = start + 3;
        let end = matching_paren(rest, open);
        let inner = &rest[open + 1..end.min(rest.len())];
        let (name, fallback) = match inner.find(',') {
            Some(at) => (inner[..at].trim(), Some(inner[at + 1..].trim())),
            None => (inner.trim(), None),
        };
        let replacement = match custom.get(name).filter(|value| !value.is_empty()) {
            Some(value) => resolve_vars(value, custom, depth + 1),
            None => fallback.map(|fallback| resolve_vars(fallback, custom, depth + 1)).unwrap_or_default(),
        };
        out.push_str(&replacement);
        rest = &rest[(end + 1).min(rest.len())..];
    }
    out.push_str(rest);
    out
}

fn matching_paren(text: &str, open: usize) -> usize {
    let mut depth = 0;
    for (at, char) in text[open..].char_indices() {
        match char {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return open + at;
                }
            }
            _ => {}
        }
    }
    text.len()
}

const SIDES: [&str; 4] = ["top", "right", "bottom", "left"];

/// A shorthand's longhands (a longhand is itself), as `top right bottom left` give four sides.
fn expand(name: &str, value: &str, out: &mut Vec<(String, String)>) {
    let parts = || values::split(value, None);
    let four = |parts: Vec<String>| -> [String; 4] {
        match parts.len() {
            0 => [String::new(), String::new(), String::new(), String::new()],
            1 => [parts[0].clone(), parts[0].clone(), parts[0].clone(), parts[0].clone()],
            2 => [parts[0].clone(), parts[1].clone(), parts[0].clone(), parts[1].clone()],
            3 => [parts[0].clone(), parts[1].clone(), parts[2].clone(), parts[1].clone()],
            _ => [parts[0].clone(), parts[1].clone(), parts[2].clone(), parts[3].clone()],
        }
    };
    let global = matches!(value.to_ascii_lowercase().as_str(), "inherit" | "initial" | "unset" | "revert" | "revert-layer");
    match name {
        "margin" | "padding" => {
            for (side, part) in SIDES.iter().zip(if global { four(vec![value.to_string()]) } else { four(parts()) }) {
                out.push((format!("{name}-{side}"), part));
            }
        }
        "inset" => {
            for (side, part) in SIDES.iter().zip(four(parts())) {
                out.push((side.to_string(), part));
            }
        }
        "margin-block" | "padding-block" | "margin-inline" | "padding-inline" | "inset-block" | "inset-inline" => {
            let base = name.split('-').next().unwrap_or(name);
            let p = parts();
            let (a, b) = (p.first().cloned().unwrap_or_default(), p.get(1).or(p.first()).cloned().unwrap_or_default());
            let (first, second) = if name.ends_with("block") { ("top", "bottom") } else { ("left", "right") };
            let long = |side: &str| if base == "inset" { side.to_string() } else { format!("{base}-{side}") };
            out.push((long(first), a));
            out.push((long(second), b));
        }
        _ if logical(name).is_some() => out.push((logical(name).unwrap_or_default(), value.to_string())),
        "border" | "border-top" | "border-right" | "border-bottom" | "border-left" | "border-block" | "border-inline" | "border-block-start" | "border-block-end" | "border-inline-start" | "border-inline-end" => {
            let sides: Vec<&str> = match name {
                "border" => SIDES.to_vec(),
                "border-block" => vec!["top", "bottom"],
                "border-inline" => vec!["left", "right"],
                "border-block-start" => vec!["top"],
                "border-block-end" => vec!["bottom"],
                "border-inline-start" => vec!["left"],
                "border-inline-end" => vec!["right"],
                other => vec![other.trim_start_matches("border-")],
            };
            let (mut width, mut style, mut color) = ("medium".to_string(), "none".to_string(), "currentColor".to_string());
            if global {
                width = value.to_string();
                style = value.to_string();
                color = value.to_string();
            } else {
                for part in parts() {
                    let lower = part.to_ascii_lowercase();
                    if BORDER_STYLES.contains(&lower.as_str()) {
                        style = lower;
                    } else if values::length(&part, Ctx::default()).is_some() || matches!(lower.as_str(), "thin" | "medium" | "thick") {
                        width = part;
                    } else {
                        color = part;
                    }
                }
            }
            for side in sides {
                out.push((format!("border-{side}-width"), width.clone()));
                out.push((format!("border-{side}-style"), style.clone()));
                out.push((format!("border-{side}-color"), color.clone()));
            }
        }
        "border-width" | "border-style" | "border-color" => {
            let what = name.trim_start_matches("border-");
            for (side, part) in SIDES.iter().zip(if global { four(vec![value.to_string()]) } else { four(parts()) }) {
                out.push((format!("border-{side}-{what}"), part));
            }
        }
        "border-radius" => {
            let first = value.split('/').next().unwrap_or(value);
            let corners = four(values::split(first, None));
            for (corner, part) in ["top-left", "top-right", "bottom-right", "bottom-left"].iter().zip(corners) {
                out.push((format!("border-{corner}-radius"), part));
            }
        }
        "border-start-start-radius" => out.push(("border-top-left-radius".into(), value.into())),
        "border-start-end-radius" => out.push(("border-top-right-radius".into(), value.into())),
        "border-end-start-radius" => out.push(("border-bottom-left-radius".into(), value.into())),
        "border-end-end-radius" => out.push(("border-bottom-right-radius".into(), value.into())),
        "outline" => {
            let (mut width, mut style, mut color) = ("medium".to_string(), "none".to_string(), "currentColor".to_string());
            for part in parts() {
                let lower = part.to_ascii_lowercase();
                if BORDER_STYLES.contains(&lower.as_str()) || lower == "auto" {
                    style = lower;
                } else if values::length(&part, Ctx::default()).is_some() || matches!(lower.as_str(), "thin" | "medium" | "thick") {
                    width = part;
                } else {
                    color = part;
                }
            }
            out.push(("outline-width".into(), width));
            out.push(("outline-style".into(), style));
            out.push(("outline-color".into(), color));
        }
        "background" => {
            if global {
                out.push(("background-color".into(), value.into()));
                out.push(("background-image".into(), value.into()));
                return;
            }
            let layers = values::split(value, Some(','));
            let mut images: Vec<String> = Vec::new();
            let mut color = "transparent".to_string();
            for (at, layer) in layers.iter().enumerate() {
                for part in values::split(layer, None) {
                    let lower = part.to_ascii_lowercase();
                    if lower.contains("gradient(") || lower.starts_with("url(") {
                        images.push(part.clone());
                    } else if at == layers.len() - 1 && values::colour(&part, 0).is_some() {
                        color = part.clone();
                    }
                }
            }
            let image = if images.is_empty() { "none".to_string() } else { images.join(", ") };
            out.push(("background-color".into(), color));
            out.push(("background-image".into(), image));
        }
        "font" => {
            if global || matches!(value, "caption" | "icon" | "menu" | "message-box" | "small-caption" | "status-bar") {
                for long in ["font-style", "font-weight", "font-size", "line-height", "font-family"] {
                    out.push((long.into(), if global { value.into() } else { "initial".into() }));
                }
                return;
            }
            let parts = parts();
            let mut style = "normal".to_string();
            let mut weight = "normal".to_string();
            let mut at = 0;
            while at < parts.len() {
                let lower = parts[at].to_ascii_lowercase();
                match lower.as_str() {
                    "italic" | "oblique" => style = lower,
                    "bold" | "bolder" | "lighter" => weight = lower,
                    "normal" | "small-caps" | "condensed" | "expanded" => {}
                    n if n.parse::<f32>().is_ok() => weight = lower,
                    _ => break,
                }
                at += 1;
            }
            let Some(size) = parts.get(at) else { return };
            let (size, line_height) = match size.split_once('/') {
                Some((size, line)) if !line.is_empty() => (size.to_string(), Some(line.to_string())),
                Some((size, _)) => (size.to_string(), parts.get(at + 1).cloned()),
                None => {
                    if parts.get(at + 1).is_some_and(|next| next.starts_with('/')) {
                        let line = parts[at + 1].trim_start_matches('/').to_string();
                        let line = if line.is_empty() { parts.get(at + 2).cloned().unwrap_or_default() } else { line };
                        at += 1;
                        (size.clone(), Some(line))
                    } else {
                        (size.clone(), None)
                    }
                }
            };
            let family_start = parts.iter().position(|part| part == &size || part.starts_with(&format!("{size}/"))).map(|p| p + 1).unwrap_or(at + 1);
            let family: Vec<String> = parts[family_start..].iter().filter(|part| !part.starts_with('/') && Some(*part) != line_height.as_ref()).cloned().collect();
            out.push(("font-style".into(), style));
            out.push(("font-weight".into(), weight));
            out.push(("font-size".into(), size));
            out.push(("line-height".into(), line_height.unwrap_or_else(|| "normal".into())));
            if !family.is_empty() {
                out.push(("font-family".into(), family.join(" ")));
            }
        }
        "flex" => {
            let p = parts();
            let (grow, shrink, basis) = match p.iter().map(|s| s.to_ascii_lowercase()).collect::<Vec<_>>().as_slice() {
                [none] if none == "none" => ("0".into(), "0".into(), "auto".into()),
                [auto] if auto == "auto" => ("1".into(), "1".into(), "auto".into()),
                [g] if g.parse::<f32>().is_ok() => (g.clone(), "1".to_string(), "0%".to_string()),
                [b] => ("1".into(), "1".into(), b.clone()),
                [g, s] if s.parse::<f32>().is_ok() => (g.clone(), s.clone(), "0%".into()),
                [g, b] => (g.clone(), "1".into(), b.clone()),
                [g, s, b, ..] => (g.clone(), s.clone(), b.clone()),
                [] => return,
            };
            out.push(("flex-grow".into(), grow));
            out.push(("flex-shrink".into(), shrink));
            out.push(("flex-basis".into(), basis));
        }
        "flex-flow" => {
            for part in parts() {
                if part.contains("wrap") {
                    out.push(("flex-wrap".into(), part));
                } else {
                    out.push(("flex-direction".into(), part));
                }
            }
        }
        "gap" | "grid-gap" => {
            let p = parts();
            let row = p.first().cloned().unwrap_or_default();
            out.push(("row-gap".into(), row.clone()));
            out.push(("column-gap".into(), p.get(1).cloned().unwrap_or(row)));
        }
        "grid-row-gap" => out.push(("row-gap".into(), value.into())),
        "grid-column-gap" => out.push(("column-gap".into(), value.into())),
        "place-items" | "place-content" | "place-self" => {
            let what = name.trim_start_matches("place-");
            let p = parts();
            // `place-content: safe center` keeps its two words together.
            let (align, justify) = if p.len() >= 2 && matches!(p[0].as_str(), "safe" | "unsafe" | "first" | "last") {
                (format!("{} {}", p[0], p[1]), p.get(2).cloned().unwrap_or_else(|| format!("{} {}", p[0], p[1])))
            } else {
                (p.first().cloned().unwrap_or_default(), p.get(1).or(p.first()).cloned().unwrap_or_default())
            };
            out.push((format!("align-{what}"), align));
            out.push((format!("justify-{what}"), justify));
        }
        "grid-area" => {
            let p: Vec<String> = values::split(value, Some('/'));
            let get = |at: usize, fallback: &str| p.get(at).cloned().unwrap_or_else(|| if fallback.starts_with('-') || fallback.parse::<i32>().is_ok() || fallback.contains("span") || fallback == "auto" { "auto".into() } else { fallback.into() });
            let row_start = p.first().cloned().unwrap_or_else(|| "auto".into());
            let col_start = get(1, &row_start);
            let row_end = get(2, &row_start);
            let col_end = get(3, &col_start);
            out.push(("grid-row-start".into(), row_start));
            out.push(("grid-column-start".into(), col_start));
            out.push(("grid-row-end".into(), row_end));
            out.push(("grid-column-end".into(), col_end));
        }
        "grid-row" | "grid-column" => {
            let p: Vec<String> = values::split(value, Some('/'));
            let start = p.first().cloned().unwrap_or_else(|| "auto".into());
            let ident = !start.contains("span") && start.parse::<i32>().is_err() && start != "auto";
            let end = p.get(1).cloned().unwrap_or_else(|| if ident { start.clone() } else { "auto".into() });
            out.push((format!("{name}-start"), start));
            out.push((format!("{name}-end"), end));
        }
        "grid-template" | "grid" => {
            if value.trim() == "none" {
                out.push(("grid-template-rows".into(), "none".into()));
                out.push(("grid-template-columns".into(), "none".into()));
                out.push(("grid-template-areas".into(), "none".into()));
                return;
            }
            let (rows, columns) = match value.split_once('/') {
                Some((rows, columns)) => (rows.trim().to_string(), Some(columns.trim().to_string())),
                None => (value.trim().to_string(), None),
            };
            if rows.contains('"') || rows.contains('\'') {
                // `"a a" auto "b c" 1fr / 1fr 2fr`: the strings are the areas, what follows each its row's size.
                let mut areas = Vec::new();
                let mut sizes = Vec::new();
                for part in values::split(&rows, None) {
                    if part.starts_with('"') || part.starts_with('\'') {
                        areas.push(part);
                        sizes.push("auto".to_string());
                    } else if let Some(last) = sizes.last_mut() {
                        *last = part;
                    }
                }
                out.push(("grid-template-areas".into(), areas.join(" ")));
                out.push(("grid-template-rows".into(), sizes.join(" ")));
            } else {
                out.push(("grid-template-rows".into(), rows));
            }
            if let Some(columns) = columns {
                out.push(("grid-template-columns".into(), columns));
            }
        }
        "overflow" => {
            let p = parts();
            let x = p.first().cloned().unwrap_or_default();
            out.push(("overflow-x".into(), x.clone()));
            out.push(("overflow-y".into(), p.get(1).cloned().unwrap_or(x)));
        }
        "list-style" => {
            for part in parts() {
                let lower = part.to_ascii_lowercase();
                if lower == "inside" || lower == "outside" {
                    out.push(("list-style-position".into(), lower));
                } else if !lower.starts_with("url(") {
                    out.push(("list-style-type".into(), part));
                }
            }
        }
        "text-decoration" => {
            let mut lines = Vec::new();
            for part in parts() {
                let lower = part.to_ascii_lowercase();
                match lower.as_str() {
                    "underline" | "overline" | "line-through" | "none" => lines.push(lower),
                    "solid" | "double" | "dotted" | "dashed" | "wavy" => out.push(("text-decoration-style".into(), lower)),
                    _ if values::colour(&part, 0).is_some() || lower == "currentcolor" => out.push(("text-decoration-color".into(), part)),
                    _ => {}
                }
            }
            out.push(("text-decoration-line".into(), if lines.is_empty() { "none".into() } else { lines.join(" ") }));
        }
        "word-wrap" => out.push(("overflow-wrap".into(), value.into())),
        "line-clamp" => out.push(("-webkit-line-clamp".into(), value.into())),
        "white-space" => out.push(("white-space".into(), value.into())),
        "text-wrap" | "text-wrap-mode" => {
            if value.contains("nowrap") {
                out.push(("white-space".into(), "nowrap".into()));
            }
        }
        _ => out.push((name.to_string(), value.to_string())),
    }
}

const BORDER_STYLES: [&str; 10] = ["none", "hidden", "dotted", "dashed", "solid", "double", "groove", "ridge", "inset", "outset"];

/// A logical property's physical one (horizontal, left to right).
fn logical(name: &str) -> Option<String> {
    let map = |rest: &str| -> Option<&str> {
        Some(match rest {
            "block-start" => "top",
            "block-end" => "bottom",
            "inline-start" => "left",
            "inline-end" => "right",
            _ => return None,
        })
    };
    for base in ["margin", "padding", "inset"] {
        if let Some(rest) = name.strip_prefix(&format!("{base}-")) {
            let side = map(rest)?;
            return Some(if base == "inset" { side.to_string() } else { format!("{base}-{side}") });
        }
    }
    Some(match name {
        "block-size" => "height".into(),
        "inline-size" => "width".into(),
        "min-block-size" => "min-height".into(),
        "min-inline-size" => "min-width".into(),
        "max-block-size" => "max-height".into(),
        "max-inline-size" => "max-width".into(),
        _ => return None,
    })
}

// ---- Compatibility for svg.rs and the projection ----

/// A length in dp (CSS px): px, rem, em (of `em`), pt, and 0.
pub(crate) fn length(value: &str, em: f32, rem: f32) -> Option<f32> {
    values::px(value, Ctx { em, rem, ..Ctx::default() })
}

/// A colour as Android's `#AARRGGBB`.
pub(crate) fn colour(value: &str) -> Option<String> {
    values::colour(value, 0xff000000).map(values::argb)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A document for the tests: elements in a flat arena.
    struct Doc {
        nodes: Vec<(String, Vec<(String, String)>, Option<usize>, Vec<usize>)>,
        focus: Option<usize>,
    }

    #[derive(Clone, Copy)]
    struct El<'a>(&'a Doc, usize);

    impl<'a> Elem<'a> for El<'a> {
        fn tag(self) -> &'a str {
            &self.0.nodes[self.1].0
        }
        fn attr(self, name: &str) -> Option<&'a str> {
            self.0.nodes[self.1].1.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
        }
        fn parent(self) -> Option<Self> {
            self.0.nodes[self.1].2.map(|p| El(self.0, p))
        }
        fn prev(self) -> Option<Self> {
            let siblings = &self.0.nodes[self.0.nodes[self.1].2?].3;
            let at = siblings.iter().position(|&s| s == self.1)?;
            at.checked_sub(1).map(|p| El(self.0, siblings[p]))
        }
        fn next(self) -> Option<Self> {
            let siblings = &self.0.nodes[self.0.nodes[self.1].2?].3;
            let at = siblings.iter().position(|&s| s == self.1)?;
            siblings.get(at + 1).map(|&n| El(self.0, n))
        }
        fn first_child(self) -> Option<Self> {
            self.0.nodes[self.1].3.first().map(|&c| El(self.0, c))
        }
        fn is_empty(self) -> bool {
            self.0.nodes[self.1].3.is_empty()
        }
        fn state(self, state: State) -> bool {
            state == State::Focus && self.0.focus == Some(self.1)
        }
        fn is(self, other: Self) -> bool {
            self.1 == other.1
        }
    }

    impl Doc {
        fn new() -> Doc {
            Doc { nodes: vec![("html".into(), vec![], None, vec![])], focus: None }
        }
        fn add(&mut self, parent: usize, tag: &str, attrs: &[(&str, &str)]) -> usize {
            let id = self.nodes.len();
            self.nodes.push((tag.into(), attrs.iter().map(|(n, v)| (n.to_string(), v.to_string())).collect(), Some(parent), vec![]));
            self.nodes[parent].3.push(id);
            id
        }
    }

    fn color_of(sheet: &Sheet, el: El) -> Option<String> {
        sheet.compute(el, &Computed::root(Ctx::default()), &[], None).get("color").map(str::to_string)
    }

    #[test]
    fn scoped_selectors_match() {
        let sheet = Sheet::of(".controls.rx-1 button:where(.rx-1) { color: #ff0000; } .controls.rx-1 .primary:where(.rx-1) { color: #00ff00; }", Media::default());
        assert!(sheet.warnings().is_empty(), "{:?}", sheet.warnings());
        let mut doc = Doc::new();
        let body = doc.add(0, "body", &[]);
        let div = doc.add(body, "div", &[("class", "controls rx-1")]);
        let button = doc.add(div, "button", &[("class", "primary rx-1")]);
        let other = doc.add(body, "button", &[("class", "primary")]);
        assert_eq!(color_of(&sheet, El(&doc, button)).as_deref(), Some("#00ff00"), "a class beats a tag, :where() adding nothing");
        assert_eq!(color_of(&sheet, El(&doc, other)).as_deref(), Some("#000"), "another component's button isn't in the scope: the UA's colour");
    }

    #[test]
    fn combinators_and_pseudo_classes() {
        let css = "li + li { color: red; } li ~ .last { color: blue; } li:first-child { color: green; } li:nth-child(2n+3) { font-size: 20px; }
            li:not(.last):last-child { color: pink; } ul:has(> .last) { color: teal; } [data-x] { color: navy; } a[href^='/'] { color: olive; }
            input:focus-visible { color: lime; } p:empty { color: gray; } li:nth-last-child(1) { font-weight: 700; } [aria-current=\"page\" i] { color: maroon; }";
        let sheet = Sheet::of(css, Media::default());
        assert!(sheet.warnings().is_empty(), "{:?}", sheet.warnings());
        let mut doc = Doc::new();
        let body = doc.add(0, "body", &[]);
        let ul = doc.add(body, "ul", &[]);
        let a = doc.add(ul, "li", &[]);
        let b = doc.add(ul, "li", &[]);
        let c = doc.add(ul, "li", &[("class", "last")]);
        let x = doc.add(body, "div", &[("data-x", "")]);
        let link = doc.add(body, "a", &[("href", "/day/3"), ("aria-current", "PAGE")]);
        let field = doc.add(body, "input", &[]);
        let empty = doc.add(body, "p", &[]);
        let el = |n| El(&doc, n);
        assert_eq!(color_of(&sheet, el(a)).as_deref(), Some("green"));
        assert_eq!(color_of(&sheet, el(b)).as_deref(), Some("red"));
        assert_eq!(color_of(&sheet, el(c)).as_deref(), Some("blue"));
        assert_eq!(color_of(&sheet, el(ul)).as_deref(), Some("teal"));
        assert_eq!(color_of(&sheet, el(x)).as_deref(), Some("navy"));
        assert_eq!(color_of(&sheet, el(link)).as_deref(), Some("olive"), "a[href^] outweighs [aria-current]");
        assert_eq!(color_of(&sheet, el(field)).as_deref(), Some("#000"), "the UA's");
        assert_eq!(color_of(&sheet, el(empty)).as_deref(), Some("gray"));
        let root = Computed::root(Ctx::default());
        assert_eq!(sheet.compute(el(c), &root, &[], None).font_size, 20.0, ":nth-child(2n+3) is the third");
        assert_eq!(sheet.compute(el(c), &root, &[], None).get("font-weight"), Some("700"));
        let mut focused = doc;
        focused.focus = Some(field);
        assert_eq!(color_of(&sheet, El(&focused, field)).as_deref(), Some("lime"));
    }

    #[test]
    fn cascade_shorthands_vars_and_inheritance() {
        let css = ":root { --gap: 12px; --accent: #0af; } .card { padding: var(--gap) 4px; padding-left: 0; margin: 0 auto; border: 1px solid var(--accent); font: italic 700 1.25rem/1.5 system-ui; }
            .card { color: var(--missing, rgb(1 2 3)); } .inner { font-size: 2em; line-height: inherit; } .x { color: red !important; } .x { color: blue; }";
        let sheet = Sheet::of(css, Media::default());
        let mut doc = Doc::new();
        let body = doc.add(0, "body", &[]);
        let card = doc.add(body, "div", &[("class", "card")]);
        let inner = doc.add(card, "span", &[("class", "inner x")]);
        let root = sheet.compute(El(&doc, 0), &Computed::root(Ctx::default()), &[], None);
        let body_c = sheet.compute(El(&doc, body), &root, &[], None);
        let card_c = sheet.compute(El(&doc, card), &body_c, &[], None);
        assert_eq!(card_c.get("padding-top"), Some("12px"));
        assert_eq!(card_c.get("padding-right"), Some("4px"));
        assert_eq!(card_c.get("padding-left"), Some("0"));
        assert_eq!(card_c.get("margin-left"), Some("auto"));
        assert_eq!(card_c.get("border-top-color"), Some("#0af"));
        assert_eq!(card_c.get("border-left-width"), Some("1px"));
        assert_eq!(card_c.font_size, 20.0);
        assert_eq!(card_c.get("font-weight"), Some("700"));
        assert_eq!(card_c.get("font-style"), Some("italic"));
        assert_eq!(card_c.line_height(), Some(30.0));
        assert_eq!(card_c.color, 0xff010203);
        let inner_c = sheet.compute(El(&doc, inner), &card_c, &[], None);
        assert_eq!(inner_c.font_size, 40.0);
        assert_eq!(inner_c.line_height(), Some(60.0), "a number inherits as a number");
        assert_eq!(inner_c.get("font-style"), Some("italic"), "inherited");
        assert_eq!(inner_c.get("padding-top"), None, "not inherited");
        assert_eq!(inner_c.color, 0xffff0000, "!important beats a later rule");
    }

    #[test]
    fn media_and_pseudo_elements() {
        let css = "@media (max-width: 600px) { .a { color: red; } } @media (min-width: 761px) and (max-width: 1000px) { .a { color: blue; } }
            @media (width <= 500px) { .b { color: green; } } @supports (display: grid) { .c { color: navy; } } @layer base { .d { color: teal; } }
            .a::before { content: '★'; color: gold; } .a:hover { color: black; } ::view-transition-old(root) { animation: none; }";
        let sheet = Sheet::of(css, Media { width: 412.0, height: 915.0, dark: false });
        assert!(sheet.warnings().is_empty(), "{:?}", sheet.warnings());
        let mut doc = Doc::new();
        let body = doc.add(0, "body", &[]);
        let a = doc.add(body, "div", &[("class", "a b c d")]);
        let root = Computed::root(Ctx::default());
        let computed = sheet.compute(El(&doc, a), &root, &[], None);
        assert_eq!(computed.get("color"), Some("teal"), "the last rule that applies");
        let before = sheet.compute(El(&doc, a), &computed, &[], Some(Pseudo::Before));
        assert_eq!(before.get("content"), Some("'★'"));
        assert_eq!(before.get("color"), Some("gold"));
        let wide = Sheet::of(css, Media { width: 800.0, height: 600.0, dark: false });
        let mut doc2 = Doc::new();
        let body2 = doc2.add(0, "body", &[]);
        let only_a = doc2.add(body2, "div", &[("class", "a")]);
        assert_eq!(color_of(&wide, El(&doc2, only_a)).as_deref(), Some("blue"));
    }

    #[test]
    fn unknown_selectors_warn() {
        let sheet = Sheet::of("a:frobnicate { color: red; } .x { frobnicate: 1; }", Media::default());
        assert_eq!(sheet.warnings().len(), 2, "{:?}", sheet.warnings());
    }
}
