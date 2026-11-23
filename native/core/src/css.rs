//! The CSS a phone does (D-063's §6.2), for the spike: the stylesheet the page carries (its
//! `<style>`s: rocx's scoped `Generated/Styles`), after a phone user-agent stylesheet (`UA`, a
//! trimmed copy of the HTML spec's), matched against each element and resolved into the views'
//! properties (`style.padding`, `style.color`…), which the Kotlin applier sets.
//!
//! Selectors: type, class, id, `*`, `:root`, `:global(…)`, descendant and child combinators. Other
//! pseudo-classes and attribute selectors drop their rule. Properties: `display` (none, flex as a
//! row or a column, the rest as a column), `flex-direction`, `gap`, `padding`, `margin`,
//! `color`, `background(-color)` (a colour), `font-size`, `font-weight`, `font-style`,
//! `text-align`, `text-transform`, `border-radius`, `border` (width and colour), `width`,
//! `height`, `opacity`, `align-items`, `justify-content`, custom properties and `var()`. Lengths
//! in px, rem, em and pt. `@media` with widths and `prefers-color-scheme`.
//!
//! What a phone can't do (yet) only warns, once, and is ignored: the user's answer to D-063's
//! question 1. The design parses the CSS at build time instead; this is the spike's.

use std::collections::HashMap;

/// The phone's user-agent stylesheet: what a browser shows unstyled HTML with.
const UA: &str = "
html { font-size: 16px; color: #1b1b1f; }
body { margin: 8px; }
h1 { font-size: 2em; font-weight: 700; margin: 0.67em 0; }
h2 { font-size: 1.5em; font-weight: 700; margin: 0.83em 0; }
h3 { font-size: 1.17em; font-weight: 700; margin: 1em 0; }
h4 { font-weight: 700; margin: 1.33em 0; }
h5 { font-size: 0.83em; font-weight: 700; margin: 1.67em 0; }
h6 { font-size: 0.67em; font-weight: 700; margin: 2.33em 0; }
p, ul, ol, dl, figure, blockquote, pre { margin: 1em 0; }
ul, ol { padding-left: 40px; }
strong, b, th { font-weight: 700; }
em, i, cite { font-style: italic; }
small { font-size: 0.83em; }
code, kbd, samp, pre { font-family: monospace; }
a { color: #0b57d0; }
";

#[derive(Clone, Debug, Default)]
pub struct Element {
    pub tag: String,
    pub id: String,
    pub classes: Vec<String>,
}

#[derive(Clone, Debug)]
struct Compound {
    tag: Option<String>,
    id: Option<String>,
    classes: Vec<String>,
    root: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Combinator {
    Descendant,
    Child,
}

#[derive(Clone, Debug)]
struct Selector {
    /// The rightmost compound first, with the combinator to the next one left.
    parts: Vec<(Compound, Combinator)>,
    specificity: (u32, u32, u32),
}

#[derive(Clone, Debug)]
struct Rule {
    selector: Selector,
    declarations: Vec<(String, String)>,
    order: usize,
}

pub struct Sheet {
    rules: Vec<Rule>,
    warnings: Vec<String>,
}

thread_local! {
    static CACHE: std::cell::RefCell<Option<(String, std::rc::Rc<Sheet>)>> = const { std::cell::RefCell::new(None) };
}

impl Sheet {
    /// The UA stylesheet, then the page's `css`: parsed once for each text.
    pub fn of(css: &str) -> std::rc::Rc<Sheet> {
        CACHE.with(|cache| {
            if let Some((text, sheet)) = cache.borrow().as_ref()
                && text == css
            {
                return sheet.clone();
            }
            let mut sheet = Sheet { rules: Vec::new(), warnings: Vec::new() };
            sheet.parse(UA, false);
            sheet.parse(css, true);
            let sheet = std::rc::Rc::new(sheet);
            *cache.borrow_mut() = Some((css.to_string(), sheet.clone()));
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

    fn parse(&mut self, css: &str, page: bool) {
        let text = strip_comments(css);
        let mut at = 0;
        let bytes = text.as_bytes();
        while at < bytes.len() {
            let Some(open) = text[at..].find('{').map(|found| found + at) else { break };
            let prelude = text[at..open].trim().to_string();
            let close = matching(&text, open);
            let body = &text[open + 1..close.min(text.len())];
            at = close + 1;
            if let Some(rule) = prelude.strip_prefix('@') {
                if rule.starts_with("media") {
                    if media_applies(rule.trim_start_matches("media").trim()) {
                        self.parse(body, page);
                    }
                } else if page {
                    let name = rule.split_whitespace().next().unwrap_or(rule);
                    self.warn(format!("CSS @{name} isn't on phones yet: ignored"));
                }
                continue;
            }
            let declarations = declarations(body);
            for selector in prelude.split(',') {
                match parse_selector(selector.trim()) {
                    Ok(selector) => {
                        let order = self.rules.len();
                        self.rules.push(Rule { selector, declarations: declarations.clone(), order });
                    }
                    Err(why) => {
                        if page {
                            self.warn(format!("CSS selector `{}` isn't on phones yet ({why}): its rule is ignored", selector.trim()));
                        }
                    }
                }
            }
            if page {
                for (name, _) in &declarations {
                    if !name.starts_with("--") && !KNOWN.contains(&name.as_str()) {
                        self.warn(format!("CSS `{name}` isn't on phones yet: ignored"));
                    }
                }
            }
        }
    }

    /// The styles of the element at `path[0]` (its ancestors after it), given its parent's, with
    /// its own `style` attribute's last.
    pub fn compute(&self, path: &[Element], parent: &Computed, inline: &[(String, String)]) -> Computed {
        let mut matched: Vec<&Rule> = self.rules.iter().filter(|rule| matches(&rule.selector, path)).collect();
        matched.sort_by_key(|rule| (rule.selector.specificity, rule.order));
        let mut declared: HashMap<String, String> = HashMap::new();
        for rule in matched {
            for (name, value) in &rule.declarations {
                declared.insert(name.clone(), value.clone());
            }
        }
        for (name, value) in inline {
            declared.insert(name.clone(), value.clone());
        }
        Computed::from(parent, declared)
    }
}

/// The properties the phone does (`font-family` and `box-sizing` as the phone's own: its system
/// font, and borders inside a view's size).
const KNOWN: [&str; 34] = [
    "display", "flex-direction", "gap", "row-gap", "column-gap", "padding", "padding-top", "padding-right", "padding-bottom", "padding-left", "margin", "margin-top", "margin-right", "margin-bottom", "margin-left", "color", "background", "background-color", "font-size", "font-weight", "font-style",
    "text-align", "text-transform", "border-radius", "border", "border-width", "border-color", "width", "height", "opacity", "align-items", "justify-content", "font-family", "box-sizing",
];

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

/// Where the `}` that closes the `{` at `open` is.
fn matching(text: &str, open: usize) -> usize {
    let mut depth = 0;
    for (at, char) in text[open..].char_indices() {
        match char {
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

/// Whether a `@media` query holds on a phone (about 400 px wide, light).
fn media_applies(query: &str) -> bool {
    let query = query.to_ascii_lowercase();
    let width = 400.0;
    for part in query.split("and") {
        let part = part.trim().trim_start_matches("screen").trim().trim_matches(|c| c == '(' || c == ')');
        if part.is_empty() {
            continue;
        }
        let Some((name, value)) = part.split_once(':') else { continue };
        let value = value.trim();
        let number = value.trim_end_matches("px").parse::<f32>().ok().or_else(|| value.trim_end_matches("rem").trim_end_matches("em").parse::<f32>().ok().map(|n| n * 16.0));
        match (name.trim(), number) {
            ("max-width", Some(n)) if width > n => return false,
            ("min-width", Some(n)) if width < n => return false,
            ("prefers-color-scheme", _) if value == "dark" => return false,
            _ => {}
        }
    }
    true
}

fn declarations(body: &str) -> Vec<(String, String)> {
    body.split(';')
        .filter_map(|declaration| {
            let (name, value) = declaration.split_once(':')?;
            let value = value.trim().trim_end_matches("!important").trim();
            let name = name.trim().to_ascii_lowercase();
            if name.is_empty() || value.is_empty() {
                return None;
            }
            Some((name, value.to_string()))
        })
        .collect()
}

fn parse_selector(text: &str) -> Result<Selector, String> {
    let text = unwrap_global(text);
    let mut parts = Vec::new();
    let mut specificity = (0, 0, 0);
    let mut combinator = Combinator::Descendant;
    let spaced = text.replace('>', " > ");
    let mut tokens: Vec<&str> = spaced.split_whitespace().collect();
    tokens.reverse();
    let mut pending: Option<Compound> = None;
    for token in tokens {
        if token == ">" {
            combinator = Combinator::Child;
            continue;
        }
        if matches!(token, "+" | "~") {
            return Err("sibling combinators".into());
        }
        let compound = parse_compound(token, &mut specificity)?;
        if let Some(previous) = pending.take() {
            parts.push((previous, combinator));
        }
        combinator = Combinator::Descendant;
        pending = Some(compound);
    }
    if let Some(last) = pending {
        parts.push((last, Combinator::Descendant));
    }
    if parts.is_empty() {
        return Err("empty".into());
    }
    Ok(Selector { parts, specificity })
}

fn unwrap_global(text: &str) -> String {
    let mut out = text.to_string();
    while let Some(start) = out.find(":global(") {
        let inner_start = start + ":global(".len();
        let Some(end) = out[inner_start..].find(')').map(|end| end + inner_start) else { break };
        out = format!("{}{}{}", &out[..start], &out[inner_start..end], &out[end + 1..]);
    }
    out
}

fn parse_compound(token: &str, specificity: &mut (u32, u32, u32)) -> Result<Compound, String> {
    let mut compound = Compound { tag: None, id: None, classes: Vec::new(), root: false };
    let mut rest = token;
    let name_end = rest.find(['.', '#', ':', '[']).unwrap_or(rest.len());
    let tag = &rest[..name_end];
    if !tag.is_empty() && tag != "*" {
        compound.tag = Some(tag.to_ascii_lowercase());
        specificity.2 += 1;
    }
    rest = &rest[name_end..];
    while !rest.is_empty() {
        let kind = rest.as_bytes()[0];
        let end = rest[1..].find(['.', '#', ':', '[']).map(|end| end + 1).unwrap_or(rest.len());
        let name = &rest[1..end];
        match kind {
            b'.' => {
                compound.classes.push(name.to_string());
                specificity.1 += 1;
            }
            b'#' => {
                compound.id = Some(name.to_string());
                specificity.0 += 1;
            }
            b':' if name == "root" => {
                compound.root = true;
                specificity.1 += 1;
            }
            b':' => return Err(format!(":{name}")),
            _ => return Err("attribute selectors".into()),
        }
        rest = &rest[end..];
    }
    Ok(compound)
}

fn compound_matches(compound: &Compound, element: &Element, is_root: bool) -> bool {
    compound.tag.as_ref().is_none_or(|tag| *tag == element.tag)
        && compound.id.as_ref().is_none_or(|id| *id == element.id)
        && compound.classes.iter().all(|class| element.classes.contains(class))
        && (!compound.root || is_root)
}

fn matches(selector: &Selector, path: &[Element]) -> bool {
    let root_at = path.iter().rposition(|element| element.tag == "html");
    fn walk(parts: &[(Compound, Combinator)], path: &[Element], at: usize, root_at: Option<usize>) -> bool {
        let Some(((compound, combinator), rest)) = parts.split_first() else { return true };
        let Some(element) = path.get(at) else { return false };
        if !compound_matches(compound, element, Some(at) == root_at) {
            return false;
        }
        let Some(((next, _), _)) = rest.split_first() else { return true };
        let _ = next;
        match combinator {
            Combinator::Child => walk(rest, path, at + 1, root_at),
            Combinator::Descendant => (at + 1..path.len()).any(|up| walk(rest, path, up, root_at)),
        }
    }
    walk(&selector.parts, path, 0, root_at)
}

/// An element's styles, resolved: what it sets, what it inherits.
#[derive(Clone, Debug, Default)]
pub struct Computed {
    font_size: f32,
    values: HashMap<String, String>,
    custom: HashMap<String, String>,
}

/// What a child inherits.
const INHERITED: [&str; 7] = ["color", "font-weight", "font-style", "text-align", "text-transform", "line-height", "visibility"];

impl Computed {
    pub fn root() -> Computed {
        Computed { font_size: 16.0, ..Computed::default() }
    }

    fn from(parent: &Computed, mut declared: HashMap<String, String>) -> Computed {
        let mut custom = parent.custom.clone();
        for (name, value) in &declared {
            if name.starts_with("--") {
                custom.insert(name.clone(), value.clone());
            }
        }
        for value in declared.values_mut() {
            *value = resolve_vars(value, &custom);
        }
        let font_size = match declared.get("font-size") {
            Some(size) => length(size, parent.font_size, parent.font_size).unwrap_or(parent.font_size),
            None => parent.font_size,
        };
        let mut values = HashMap::new();
        for name in INHERITED {
            if let Some(value) = parent.values.get(name) {
                values.insert(name.to_string(), value.clone());
            }
        }
        for (name, value) in declared {
            if !name.starts_with("--") && value != "inherit" {
                values.insert(name, value);
            }
        }
        Computed { font_size, values, custom }
    }

    pub fn hidden(&self) -> bool {
        self.values.get("display").is_some_and(|display| display == "none") || self.values.get("visibility").is_some_and(|visibility| visibility == "hidden")
    }

    fn length(&self, name: &str) -> Option<f32> {
        self.values.get(name).and_then(|value| length(value, self.font_size, 16.0))
    }

    /// `margin` or `padding` and their sides, as `top right bottom left` in dp.
    fn sides(&self, name: &str) -> Option<String> {
        let mut sides = [0.0f32; 4];
        let mut any = false;
        if let Some(all) = self.values.get(name) {
            let parts: Vec<f32> = all.split_whitespace().map(|part| length(part, self.font_size, 16.0).unwrap_or(0.0)).collect();
            sides = match parts.as_slice() {
                [a] => [*a; 4],
                [a, b] => [*a, *b, *a, *b],
                [a, b, c] => [*a, *b, *c, *b],
                [a, b, c, d, ..] => [*a, *b, *c, *d],
                [] => sides,
            };
            any = true;
        }
        for (at, side) in ["top", "right", "bottom", "left"].iter().enumerate() {
            if let Some(value) = self.length(&format!("{name}-{side}")) {
                sides[at] = value;
                any = true;
            }
        }
        any.then(|| sides.iter().map(|side| format!("{side:.1}")).collect::<Vec<_>>().join(" "))
    }

    /// The text's properties, for any text view (an anonymous one has its block's).
    pub fn text_props(&self) -> std::collections::BTreeMap<String, String> {
        let mut props = std::collections::BTreeMap::new();
        props.insert("style.fontSize".into(), format!("{:.1}", self.font_size));
        if let Some(color) = self.values.get("color").and_then(|color| colour(color)) {
            props.insert("style.color".into(), color);
        }
        if let Some(weight) = self.values.get("font-weight") {
            let weight = match weight.as_str() {
                "bold" | "bolder" => "700".to_string(),
                "normal" | "lighter" => "400".to_string(),
                other => other.to_string(),
            };
            props.insert("style.fontWeight".into(), weight);
        }
        if self.values.get("font-style").is_some_and(|style| style == "italic" || style == "oblique") {
            props.insert("style.italic".into(), "true".into());
        }
        if let Some(align) = self.values.get("text-align") {
            props.insert("style.textAlign".into(), align.clone());
        }
        if let Some(transform) = self.values.get("text-transform") {
            props.insert("style.textTransform".into(), transform.clone());
        }
        props
    }

    /// Everything the view's style sets, as the applier's properties.
    pub fn props(&self) -> std::collections::BTreeMap<String, String> {
        let mut props = self.text_props();
        if let Some(padding) = self.sides("padding") {
            props.insert("style.padding".into(), padding);
        }
        if let Some(margin) = self.sides("margin") {
            props.insert("style.margin".into(), margin);
        }
        let background = self.values.get("background-color").or_else(|| self.values.get("background"));
        if let Some(color) = background.and_then(|background| colour(background)) {
            props.insert("style.background".into(), color);
        }
        if let Some(radius) = self.length("border-radius") {
            props.insert("style.radius".into(), format!("{radius:.1}"));
        }
        if let Some(border) = self.values.get("border") {
            let width = border.split_whitespace().find_map(|part| length(part, self.font_size, 16.0)).unwrap_or(1.0);
            let color = border.split_whitespace().find_map(colour).unwrap_or_else(|| "#ff000000".into());
            props.insert("style.border".into(), format!("{width:.1} {color}"));
        }
        let display = self.values.get("display").map(String::as_str).unwrap_or("block");
        let row = matches!(display, "flex" | "inline-flex") && !self.values.get("flex-direction").is_some_and(|direction| direction.starts_with("column"));
        props.insert("style.direction".into(), if row { "row".into() } else { "column".into() });
        let gap = self.length("gap").or_else(|| self.length(if row { "column-gap" } else { "row-gap" }));
        if let Some(gap) = gap.filter(|_| matches!(display, "flex" | "inline-flex" | "grid" | "inline-grid")) {
            props.insert("style.gap".into(), format!("{gap:.1}"));
        }
        for (css, prop) in [("width", "style.width"), ("height", "style.height")] {
            if let Some(size) = self.length(css) {
                props.insert(prop.into(), format!("{size:.1}"));
            }
        }
        if let Some(opacity) = self.values.get("opacity").and_then(|opacity| opacity.parse::<f32>().ok()) {
            props.insert("style.opacity".into(), format!("{opacity}"));
        }
        if let Some(align) = self.values.get("align-items") {
            props.insert("style.alignItems".into(), align.clone());
        }
        if let Some(justify) = self.values.get("justify-content") {
            props.insert("style.justify".into(), justify.clone());
        }
        props
    }
}

/// `var(--name, fallback)`s, replaced with their values.
fn resolve_vars(value: &str, custom: &HashMap<String, String>) -> String {
    let mut out = value.to_string();
    for _ in 0..8 {
        let Some(start) = out.find("var(") else { break };
        let end = matching_paren(&out, start + 3);
        let inner = &out[start + 4..end];
        let (name, fallback) = match inner.split_once(',') {
            Some((name, fallback)) => (name.trim(), Some(fallback.trim())),
            None => (inner.trim(), None),
        };
        let replacement = custom.get(name).cloned().or(fallback.map(str::to_string)).unwrap_or_default();
        out = format!("{}{}{}", &out[..start], replacement, &out[(end + 1).min(out.len())..]);
    }
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

/// A length in dp (CSS px): px, rem, em (of `em`), pt, and 0.
fn length(value: &str, em: f32, rem: f32) -> Option<f32> {
    let value = value.trim();
    if value == "0" {
        return Some(0.0);
    }
    let number = |suffix: &str| value.strip_suffix(suffix).and_then(|number| number.trim().parse::<f32>().ok());
    number("px").or_else(|| number("rem").map(|n| n * rem)).or_else(|| number("em").map(|n| n * em)).or_else(|| number("pt").map(|n| n * 4.0 / 3.0))
}

/// A colour as Android's `#AARRGGBB`.
fn colour(value: &str) -> Option<String> {
    let value = value.trim().to_ascii_lowercase();
    let named = match value.as_str() {
        "black" => Some("#000000"),
        "white" => Some("#ffffff"),
        "red" => Some("#ff0000"),
        "green" => Some("#008000"),
        "blue" => Some("#0000ff"),
        "gray" | "grey" => Some("#808080"),
        "transparent" => return Some("#00000000".into()),
        _ => None,
    };
    let value = named.map(str::to_string).unwrap_or(value);
    if let Some(hex) = value.strip_prefix('#') {
        let expand = |text: &str| text.chars().flat_map(|c| [c, c]).collect::<String>();
        let (rgb, alpha) = match hex.len() {
            3 => (expand(hex), "ff".to_string()),
            4 => (expand(&hex[..3]), expand(&hex[3..])),
            6 => (hex.to_string(), "ff".to_string()),
            8 => (hex[..6].to_string(), hex[6..].to_string()),
            _ => return None,
        };
        return Some(format!("#{alpha}{rgb}"));
    }
    if let Some(inner) = value.strip_prefix("rgba(").or_else(|| value.strip_prefix("rgb(")) {
        let parts: Vec<f32> = inner.trim_end_matches(')').split([',', ' ', '/']).filter(|part| !part.is_empty()).filter_map(|part| part.trim_end_matches('%').parse().ok()).collect();
        if parts.len() >= 3 {
            let alpha = parts.get(3).map(|alpha| if *alpha <= 1.0 { alpha * 255.0 } else { *alpha }).unwrap_or(255.0);
            return Some(format!("#{:02x}{:02x}{:02x}{:02x}", alpha as u8, parts[0] as u8, parts[1] as u8, parts[2] as u8));
        }
    }
    None
}
