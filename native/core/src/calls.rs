//! A phone's halves of the page functions apps commonly register for `Browser.call!` (D-138), done
//! on the engine's document with the names and arguments those functions take in a browser, so an
//! app's call works on a phone with no script of its own:
//!
//! - `focus { selector }`: the element the selector finds first takes the focus (a field, its
//!   keyboard up);
//! - `click { selector }`: a click on it, as `element.click()` (its handlers, a link's navigation, a
//!   form's button's submission);
//! - `reveal { selector }`: scrolled into view if it is out of it (`scrollIntoView({ block:
//!   "nearest" })`);
//! - `go { url }`: a navigation to a path of the app's, as a link's;
//! - `replace_query { drop }`: the field taken out of the history entry's query
//!   (`history.replaceState`): back and forward come to it without, and the page stays as it is.
//!
//! A platform's own handler by the name comes first (`Platform::call`); any other name is logged as
//! one with no native half. Selectors: compounds of a tag, `#id`, `.class`es and `[attribute]`,
//! `[attribute=value]` (quoted or not), joined by spaces (descendants).

use crate::dom::{Dom, NodeId};
use crate::engine;
use crate::json::{self, Value};

/// A call by one of the names above, done; false for any other name (or an argument it can't read).
pub fn call(name: &str, arg: &str) -> bool {
    let arg = json::parse(arg).unwrap_or(Value::Null);
    let field = |key: &str| arg.get(key).and_then(Value::as_str).map(str::to_string);
    match name {
        "go" => {
            let Some(url) = field("url").filter(|url| url.starts_with('/') && !url.starts_with("//")) else { return false };
            crate::nav::navigate(&url, crate::nav::Options { scroll: true, ..Default::default() });
            true
        }
        "replace_query" => {
            let Some(drop) = field("drop") else { return false };
            engine::with(|engine| {
                let index = engine.nav.index;
                if let Some(entry) = engine.nav.history.get_mut(index) {
                    entry.target = without(&entry.target, &drop);
                }
            });
            true
        }
        "focus" | "click" | "reveal" => {
            let Some(selector) = field("selector") else { return false };
            let Some(found) = engine::with(|engine| first(&engine.dom, &selector)) else { return true };
            match name {
                "click" => {
                    engine::dispatch(found, "click", "");
                }
                // The element's view, or the nearest above it that has one (inline content is part of
                // its block's text).
                _ => {
                    let views = engine::with(|engine| {
                        let mut chain = Vec::new();
                        let mut at = Some(found);
                        while let Some(node) = at {
                            chain.push(node as u64 + 1);
                            at = engine.dom.nodes.get(node).and_then(|each| each.parent);
                        }
                        chain
                    });
                    if name == "focus" {
                        crate::focus(&views);
                    } else {
                        crate::reveal(&views);
                    }
                }
            }
            true
        }
        _ => false,
    }
}

/// A target (`/path?a=1&b=2`) without the query's field `drop`.
fn without(target: &str, drop: &str) -> String {
    let Some((path, query)) = target.split_once('?') else { return target.to_string() };
    let kept: Vec<&str> = query.split('&').filter(|pair| !pair.is_empty() && pair.split('=').next() != Some(drop)).collect();
    if kept.is_empty() { path.to_string() } else { format!("{path}?{}", kept.join("&")) }
}

/// One compound of a selector: a tag, an id, classes, and attributes (with a value, or any).
#[derive(Default, Debug, PartialEq)]
struct Compound {
    tag: Option<String>,
    id: Option<String>,
    classes: Vec<String>,
    attributes: Vec<(String, Option<String>)>,
}

fn parse(selector: &str) -> Option<Vec<Compound>> {
    let mut out = Vec::new();
    for part in split_outside_brackets(selector) {
        let mut compound = Compound::default();
        let mut rest = part.as_str();
        let tag_end = rest.find(['#', '.', '[']).unwrap_or(rest.len());
        if tag_end > 0 {
            let tag = &rest[..tag_end];
            if tag != "*" {
                compound.tag = Some(tag.to_ascii_lowercase());
            }
        }
        rest = &rest[tag_end..];
        while !rest.is_empty() {
            let kind = rest.chars().next()?;
            rest = &rest[1..];
            if kind == '[' {
                let end = rest.find(']')?;
                let inside = &rest[..end];
                rest = &rest[end + 1..];
                let (name, value) = match inside.split_once('=') {
                    Some((name, value)) => (name.trim(), Some(value.trim().trim_matches(['\'', '"']).to_string())),
                    None => (inside.trim(), None),
                };
                compound.attributes.push((name.to_string(), value));
                continue;
            }
            let end = rest.find(['#', '.', '[']).unwrap_or(rest.len());
            let word = rest[..end].to_string();
            rest = &rest[end..];
            match kind {
                '#' => compound.id = Some(word),
                '.' => compound.classes.push(word),
                _ => return None,
            }
        }
        out.push(compound);
    }
    (!out.is_empty()).then_some(out)
}

/// A selector's compounds, split at the spaces outside `[…]`.
fn split_outside_brackets(selector: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut now = String::new();
    let mut depth = 0;
    for char in selector.trim().chars() {
        match char {
            '[' => depth += 1,
            ']' => depth -= 1,
            _ => {}
        }
        if char.is_whitespace() && depth == 0 {
            if !now.is_empty() {
                parts.push(std::mem::take(&mut now));
            }
        } else {
            now.push(char);
        }
    }
    if !now.is_empty() {
        parts.push(now);
    }
    parts
}

fn matches(dom: &Dom, node: NodeId, compound: &Compound) -> bool {
    let Some(tag) = dom.tag(node) else { return false };
    if compound.tag.as_deref().is_some_and(|wanted| wanted != tag) {
        return false;
    }
    if compound.id.as_deref().is_some_and(|wanted| dom.attr(node, "id") != Some(wanted)) {
        return false;
    }
    if !compound.classes.iter().all(|class| dom.has_class(node, class)) {
        return false;
    }
    compound.attributes.iter().all(|(name, value)| match value {
        Some(value) => dom.attr(node, name) == Some(value.as_str()),
        None => dom.attr(node, name).is_some(),
    })
}

/// Whether `node` matches the selector's last compound, and each before it an element above it
/// (descendant combinators), as `querySelector` matches.
fn matches_all(dom: &Dom, node: NodeId, compounds: &[Compound]) -> bool {
    let Some((last, before)) = compounds.split_last() else { return false };
    if !matches(dom, node, last) {
        return false;
    }
    let mut at = dom.nodes.get(node).and_then(|each| each.parent);
    let mut wanted = before.len();
    while wanted > 0 {
        let Some(node) = at else { return false };
        if matches(dom, node, &before[wanted - 1]) {
            wanted -= 1;
        }
        at = dom.nodes.get(node).and_then(|each| each.parent);
    }
    true
}

/// The first element in the document, in its order, that the selector finds (`querySelector`).
fn first(dom: &Dom, selector: &str) -> Option<NodeId> {
    let compounds = parse(selector)?;
    let mut stack = vec![dom.root];
    while let Some(node) = stack.pop() {
        if matches_all(dom, node, &compounds) && dom.connected(node) {
            return Some(node);
        }
        let end = stack.len();
        stack.extend(dom.children(node));
        stack[end..].reverse();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selectors_are_read() {
        let parsed = parse(".palette-list [data-active]").unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].classes, vec!["palette-list"]);
        assert_eq!(parsed[1].attributes, vec![("data-active".to_string(), None)]);
        let chip = parse(".chip[data-post='p 7']").unwrap();
        assert_eq!(chip[0].attributes, vec![("data-post".to_string(), Some("p 7".to_string()))]);
        assert_eq!(parse("#palette-query").unwrap()[0].id.as_deref(), Some("palette-query"));
        assert_eq!(parse(".timeline timeline-wheel").unwrap()[1].tag.as_deref(), Some("timeline-wheel"));
    }

    #[test]
    fn elements_are_found_as_query_selector_finds_them() {
        let mut dom = Dom::new();
        let list = dom.element("ul");
        dom.set_attr(list, "class", "palette-list");
        let one = dom.element("li");
        let two = dom.element("li");
        dom.set_attr(two, "data-active", "");
        dom.append(list, one);
        dom.append(list, two);
        let root = dom.root;
        dom.append(root, list);
        assert_eq!(first(&dom, ".palette-list [data-active]"), Some(two));
        assert_eq!(first(&dom, "ul li"), Some(one));
        assert_eq!(first(&dom, ".other [data-active]"), None);
    }

    #[test]
    fn a_query_field_is_dropped() {
        assert_eq!(without("/?deleted=p1", "deleted"), "/");
        assert_eq!(without("/posts/7?from=x&accepted=1", "accepted"), "/posts/7?from=x");
        assert_eq!(without("/calendar", "accepted"), "/calendar");
    }
}
