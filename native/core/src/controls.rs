//! What a browser does when a page's controls are used, done on the engine's document for a phone
//! (D-139), where runtime.js leaves it to the browser:
//!
//! - **Activation** (`activation`): a tap's default action, found as the HTML spec finds it, from
//!   the element tapped up: a `<summary>` toggles its `<details>`' `open` (and fires `toggle`); a
//!   `<label>` passes the tap to its control (a checkbox or radio toggled, a file input's picker
//!   opened, a field focused); a file input opens the system's picker. Interactive content (a link,
//!   a button, a field) inside a label or a summary is its own.
//! - **Picked files** (`picked`): what the system's picker gave a file input, copied into the app's
//!   cache by the phone, each as `Html.File`s are in a browser (`{ name, type, size, url }`, its
//!   `url` a `file://` one the phone reads, where the browser's is a `blob:`); sent with a form with
//!   files (`multipart/form-data`) and with an action whose arg names one (D-054).
//! - **A field's value** as a form sends it: what was typed or tapped, else its markup's (a
//!   `<select>`'s chosen `<option>`, a `<textarea>`'s text).
//! - **Constraint validation** (`invalid`): a form isn't sent while a field it holds is `required`
//!   and empty (or an `email` field doesn't hold an address); the first is focused, its message
//!   shown beside it (`invalid` on its view), as a browser's bubble.
//! - **Bodies with files** (`multipart`, `expand`): a form's fields and files as
//!   `multipart/form-data`, each file a token in the body's text until the HTTP client's thread reads
//!   it, so a submission's body stays text (sent again as it was by `retry!`).

use crate::dom::{Dom, Kind, NodeId};
use crate::fx::HashMap as Values;
use std::cell::RefCell;
use std::collections::HashMap;

/// A tap's default action.
#[derive(Debug, PartialEq)]
pub enum Activation {
    /// A `<details>`' `open` toggled (its `<summary>` tapped).
    Toggle(NodeId),
    /// A label's control: a checkbox or radio toggled, a field focused, a file input's picker.
    Label(NodeId),
    /// A file input's picker opened.
    Pick(NodeId),
}

/// What a tap on `path`'s first node (the path from it up) does by default, if it is one of the
/// activations above (a link's and a submit button's are the engine's own).
pub fn activation(dom: &Dom, path: &[NodeId]) -> Option<Activation> {
    for (at, &node) in path.iter().enumerate() {
        let Some(tag) = dom.tag(node) else { continue };
        match tag {
            "input" if is_type(dom, node, "file") => return Some(Activation::Pick(node)),
            // Interactive content is its own (a checkbox's tap its view's, a field's focus).
            "input" | "select" | "textarea" | "button" | "video" => return None,
            "a" if dom.attr(node, "href").is_some() => return None,
            "summary" => {
                if let Some(details) = parent_element(dom, node).filter(|&parent| dom.tag(parent) == Some("details"))
                    && first_summary(dom, details) == Some(node)
                {
                    return Some(Activation::Toggle(details));
                }
            }
            "label" => {
                // A tap on the label's own control is the control's (it is in `path` before the label).
                return control_of(dom, node).filter(|control| !path[..at].contains(control)).map(Activation::Label);
            }
            _ => {}
        }
    }
    None
}

fn is_type(dom: &Dom, node: NodeId, kind: &str) -> bool {
    dom.attr(node, "type").is_some_and(|each| each.eq_ignore_ascii_case(kind))
}

fn parent_element(dom: &Dom, node: NodeId) -> Option<NodeId> {
    let mut at = dom.nodes.get(node)?.parent;
    while let Some(up) = at {
        if dom.tag(up).is_some() {
            return Some(up);
        }
        at = dom.nodes.get(up)?.parent;
    }
    None
}

/// Elements under `node` (fragments looked through), in document order.
fn descendants(dom: &Dom, node: NodeId) -> Vec<NodeId> {
    let mut out = Vec::new();
    let mut stack: Vec<NodeId> = dom.children(node).collect();
    stack.reverse();
    while let Some(at) = stack.pop() {
        if dom.tag(at).is_some() {
            out.push(at);
        }
        let at_children: Vec<NodeId> = dom.children(at).collect();
        stack.extend(at_children.into_iter().rev());
    }
    out
}

/// A `<details>`' first `<summary>` child (fragments looked through).
pub fn first_summary(dom: &Dom, details: NodeId) -> Option<NodeId> {
    let mut stack: Vec<NodeId> = dom.children(details).collect();
    stack.reverse();
    while let Some(at) = stack.pop() {
        match &dom.nodes[at].kind {
            Kind::Element { .. } if dom.tag(at) == Some("summary") => return Some(at),
            Kind::Element { .. } => {}
            Kind::Fragment => {
                let inner: Vec<NodeId> = dom.children(at).collect();
                stack.extend(inner.into_iter().rev());
            }
            _ => {}
        }
    }
    None
}

/// A label's control: the element its `for` names, else the first labelable element inside it.
pub fn control_of(dom: &Dom, label: NodeId) -> Option<NodeId> {
    let labelable = |node: NodeId| match dom.tag(node) {
        Some("input") => !is_type(dom, node, "hidden"),
        Some("select" | "textarea" | "button" | "meter" | "output" | "progress") => true,
        _ => false,
    };
    if let Some(id) = dom.attr(label, "for") {
        let root = document_root(dom, label);
        return descendants(dom, root).into_iter().find(|&node| dom.attr(node, "id") == Some(id)).filter(|&node| labelable(node));
    }
    descendants(dom, label).into_iter().find(|&node| labelable(node))
}

fn document_root(dom: &Dom, node: NodeId) -> NodeId {
    let mut at = node;
    while let Some(up) = dom.nodes.get(at).and_then(|each| each.parent) {
        at = up;
    }
    at
}

// ---- Values ----

/// An `<option>`'s value: its `value`, else its text, its whitespace collapsed.
pub fn option_value(dom: &Dom, option: NodeId) -> String {
    match dom.attr(option, "value") {
        Some(value) => value.to_string(),
        None => text_of(dom, option).split_whitespace().collect::<Vec<_>>().join(" "),
    }
}

/// An element's text (`textContent`).
pub fn text_of(dom: &Dom, node: NodeId) -> String {
    match &dom.nodes[node].kind {
        Kind::Text(text) => text.clone(),
        _ => dom.children(node).map(|child| text_of(dom, child)).collect(),
    }
}

/// A `<select>`'s options (in `<optgroup>`s too), in order.
pub fn options_of(dom: &Dom, select: NodeId) -> Vec<NodeId> {
    descendants(dom, select).into_iter().filter(|&node| dom.tag(node) == Some("option")).collect()
}

/// What a field holds now, as a form sends it: what was typed or chosen (`values`), else its
/// markup's: a `<select>`'s last `selected` option, else its first that isn't disabled; a
/// `<textarea>`'s text; an `<input>`'s `value`.
pub fn value_of(dom: &Dom, values: &Values<NodeId, String>, node: NodeId) -> String {
    if let Some(now) = values.get(&node) {
        return now.clone();
    }
    match dom.tag(node) {
        Some("select") => {
            let options = options_of(dom, node);
            let chosen = options.iter().rev().find(|&&option| dom.attr(option, "selected").is_some()).or_else(|| options.iter().find(|&&option| dom.attr(option, "disabled").is_none()));
            chosen.map(|&option| option_value(dom, option)).unwrap_or_default()
        }
        Some("textarea") => text_of(dom, node),
        _ => dom.attr(node, "value").unwrap_or("").to_string(),
    }
}

// ---- Picked files ----

/// A file the system's picker gave a file input, in the app's cache.
#[derive(Clone, Debug, PartialEq)]
pub struct Picked {
    pub name: String,
    pub kind: String,
    pub size: u64,
    pub path: String,
}

impl Picked {
    /// Its URL, as a handler is given it (`Html.File`'s `url`).
    pub fn url(&self) -> String {
        format!("file://{}", self.path.split('/').map(|part| part.replace('%', "%25").replace(' ', "%20").replace('#', "%23").replace('?', "%3F")).collect::<Vec<_>>().join("/"))
    }
}

thread_local! {
    static PICKED: RefCell<HashMap<NodeId, Vec<Picked>>> = RefCell::new(HashMap::new());
    /// Fields a form wasn't sent for, and why (shown beside them until they change).
    static INVALID: RefCell<HashMap<NodeId, String>> = RefCell::new(HashMap::new());
}

/// The phone's list of picked files (`[{"name","type","size","path"}]`) for a file input: kept as
/// what it holds, and the files as a handler is given them (`[{"name","type","size","url"}]`).
pub fn picked(node: NodeId, json: &str) -> String {
    let files: Vec<Picked> = crate::json::parse(json)
        .and_then(|value| value.as_array().map(|items| items.to_vec()))
        .unwrap_or_default()
        .iter()
        .filter_map(|item| {
            let text = |key: &str| item.get(key).and_then(crate::json::Value::as_str).map(str::to_string);
            Some(Picked { name: text("name").unwrap_or_default(), kind: text("type").unwrap_or_default(), size: item.get("size").and_then(crate::json::Value::as_u64).unwrap_or(0), path: text("path")? })
        })
        .collect();
    let out = files_json(&files);
    PICKED.with(|picked| picked.borrow_mut().insert(node, files));
    out
}

/// Files as handlers are given them: `Html.File`'s JSON.
pub fn files_json(files: &[Picked]) -> String {
    let items: Vec<String> = files.iter().map(|file| format!("{{\"name\":{},\"type\":{},\"size\":{},\"url\":{}}}", quote(&file.name), quote(&file.kind), file.size, quote(&file.url()))).collect();
    format!("[{}]", items.join(","))
}

/// What a file input holds.
pub fn files_of(node: NodeId) -> Vec<Picked> {
    PICKED.with(|picked| picked.borrow().get(&node).cloned().unwrap_or_default())
}

/// A picked file by the URL a handler was given (`fileOf`).
pub fn file_of(url: &str) -> Option<Picked> {
    PICKED.with(|picked| picked.borrow().values().flatten().find(|file| file.url() == url).cloned())
}

/// A file input's files forgotten (its form emptied, it gone).
pub fn forget_files(node: NodeId) {
    PICKED.with(|picked| picked.borrow_mut().remove(&node));
}

fn quote(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// ---- Constraint validation ----

/// The first field in `form` that keeps it from being sent, and why: `required` and empty (a
/// checkbox unticked, a radio group with none ticked), or an `email` field that isn't an address.
/// None when the form (or its button) has `novalidate`.
pub fn invalid(dom: &Dom, values: &Values<NodeId, String>, form: NodeId, submitter: Option<NodeId>) -> Option<(NodeId, String)> {
    if dom.attr(form, "novalidate").is_some() || submitter.is_some_and(|button| dom.attr(button, "formnovalidate").is_some()) {
        return None;
    }
    for node in descendants(dom, form) {
        let tag = dom.tag(node).unwrap_or("");
        if !matches!(tag, "input" | "select" | "textarea") || dom.attr(node, "disabled").is_some() || dom.attr(node, "readonly").is_some() {
            continue;
        }
        let kind = dom.attr(node, "type").unwrap_or("text").to_ascii_lowercase();
        if matches!(kind.as_str(), "hidden" | "submit" | "button" | "reset" | "image") {
            continue;
        }
        let required = dom.attr(node, "required").is_some();
        let checked = |at: NodeId| values.get(&at).map(|now| now == "true").unwrap_or_else(|| dom.attr(at, "checked").is_some());
        match kind.as_str() {
            "checkbox" if required && !checked(node) => return Some((node, "Tick this box to go on.".into())),
            "radio" if required => {
                let name = dom.attr(node, "name");
                let group: Vec<NodeId> = descendants(dom, form).into_iter().filter(|&other| dom.tag(other) == Some("input") && is_type(dom, other, "radio") && dom.attr(other, "name") == name).collect();
                if !group.iter().any(|&other| checked(other)) {
                    return Some((node, "Choose one of these options.".into()));
                }
            }
            "checkbox" | "radio" => {}
            "file" if required && files_of(node).is_empty() => return Some((node, "Choose a file.".into())),
            "file" => {}
            _ => {
                let value = value_of(dom, values, node);
                if required && value.trim().is_empty() {
                    let said = if tag == "select" { "Choose an item in the list." } else { "Fill in this field." };
                    return Some((node, said.into()));
                }
                if kind == "email" && !value.is_empty() && !is_email(&value) {
                    return Some((node, format!("Enter an email address: \"{value}\" isn't one.")));
                }
            }
        }
    }
    None
}

/// An address as a browser's `type="email"` checks one: something, an `@`, a domain of labels.
pub fn is_email(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else { return false };
    !local.is_empty() && !local.contains(char::is_whitespace) && !domain.is_empty() && domain.split('.').all(|label| !label.is_empty() && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
}

/// A field's message beside it (`invalid`), until it changes.
pub fn set_invalid(node: NodeId, said: Option<String>) {
    INVALID.with(|invalid| match said {
        Some(said) => invalid.borrow_mut().insert(node, said),
        None => invalid.borrow_mut().remove(&node),
    });
}

pub fn invalid_message(node: NodeId) -> Option<String> {
    INVALID.with(|invalid| invalid.borrow().get(&node).cloned())
}

// ---- Bodies with files ----

/// A part of a form's body: a field's text, or a file.
pub enum Part {
    Text(String),
    File(Picked),
}

/// Where a file's bytes go in a body's text, read when it is sent (`expand`).
const FILE: char = '\u{0}';

/// Fields and files as `multipart/form-data`: its content type (with its boundary) and its body,
/// a file's bytes a token in it until the request's thread reads them (`expand`).
pub fn multipart(parts: &[(String, Part)], boundary: &str) -> (String, String) {
    let mut body = String::new();
    for (name, part) in parts {
        body.push_str(&format!("--{boundary}\r\n"));
        match part {
            Part::Text(text) => body.push_str(&format!("content-disposition: form-data; name=\"{}\"\r\n\r\n{text}\r\n", escape_name(name))),
            Part::File(file) => {
                let kind = if file.kind.is_empty() { "application/octet-stream" } else { &file.kind };
                body.push_str(&format!("content-disposition: form-data; name=\"{}\"; filename=\"{}\"\r\ncontent-type: {kind}\r\n\r\n{FILE}{}{FILE}\r\n", escape_name(name), escape_name(&file.name), file.path));
            }
        }
    }
    body.push_str(&format!("--{boundary}--\r\n"));
    (format!("multipart/form-data; boundary={boundary}"), body)
}

/// A boundary that no part holds (`----rocx` and a number from the clock).
pub fn boundary() -> String {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|since| since.as_nanos()).unwrap_or(0);
    format!("----rocx{nanos:x}")
}

/// A field's name in a part's header, as browsers write it (quotes and line breaks escaped).
fn escape_name(name: &str) -> String {
    name.replace('"', "%22").replace('\r', "%0D").replace('\n', "%0A")
}

/// A body's bytes: a multipart body's file tokens replaced by the files' bytes (read now, on the
/// request's thread); any other body as it is.
pub fn expand(content_type: Option<&str>, body: &str) -> Result<Vec<u8>, String> {
    if !content_type.is_some_and(|kind| kind.to_ascii_lowercase().starts_with("multipart/form-data")) || !body.contains(FILE) {
        return Ok(body.as_bytes().to_vec());
    }
    let mut out = Vec::with_capacity(body.len());
    let mut rest = body;
    while let Some(start) = rest.find(FILE) {
        out.extend_from_slice(rest[..start].as_bytes());
        let after = &rest[start + 1..];
        let end = after.find(FILE).ok_or("a file's place in a form's body isn't closed")?;
        let path = &after[..end];
        let bytes = std::fs::read(path).map_err(|why| format!("the file {path} can't be read: {why}"))?;
        out.extend_from_slice(&bytes);
        rest = &after[end + 1..];
    }
    out.extend_from_slice(rest.as_bytes());
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc() -> Dom {
        Dom::new()
    }

    fn add(dom: &mut Dom, parent: NodeId, tag: &str, attrs: &[(&str, &str)]) -> NodeId {
        let node = dom.element(tag);
        for (name, value) in attrs {
            dom.set_attr(node, name, value);
        }
        dom.append(parent, node);
        node
    }

    fn path(dom: &Dom, node: NodeId) -> Vec<NodeId> {
        let mut out = vec![node];
        let mut at = node;
        while let Some(up) = dom.nodes[at].parent {
            out.push(up);
            at = up;
        }
        out
    }

    #[test]
    fn a_summary_toggles_its_details() {
        let mut dom = doc();
        let root = dom.root;
        let details = add(&mut dom, root, "details", &[]);
        let summary = add(&mut dom, details, "summary", &[]);
        let icon = add(&mut dom, summary, "span", &[]);
        let link = add(&mut dom, summary, "a", &[("href", "/x")]);
        let second = add(&mut dom, details, "summary", &[]);
        assert_eq!(activation(&dom, &path(&dom, icon)), Some(Activation::Toggle(details)));
        assert_eq!(activation(&dom, &path(&dom, link)), None, "a link in a summary is its own");
        assert_eq!(activation(&dom, &path(&dom, second)), None, "only the first summary toggles");
    }

    #[test]
    fn a_label_passes_the_tap_to_its_control() {
        let mut dom = doc();
        let root = dom.root;
        let label = add(&mut dom, root, "label", &[]);
        let text = dom.text("When");
        dom.append(label, text);
        let radio = add(&mut dom, label, "input", &[("type", "radio")]);
        assert_eq!(activation(&dom, &path(&dom, label)), Some(Activation::Label(radio)));
        assert_eq!(activation(&dom, &path(&dom, radio)), None, "the control's own tap is its");
        let field = add(&mut dom, root, "input", &[("id", "email")]);
        let other = add(&mut dom, root, "label", &[("for", "email")]);
        assert_eq!(activation(&dom, &path(&dom, other)), Some(Activation::Label(field)));
        let drop = add(&mut dom, root, "label", &[]);
        let file = add(&mut dom, drop, "input", &[("type", "file")]);
        let inside = add(&mut dom, drop, "span", &[]);
        assert_eq!(activation(&dom, &path(&dom, inside)), Some(Activation::Label(file)));
        assert_eq!(activation(&dom, &path(&dom, file)), Some(Activation::Pick(file)));
    }

    #[test]
    fn a_select_holds_its_chosen_option() {
        let mut dom = doc();
        let mut values = Values::default();
        let root = dom.root;
        let select = add(&mut dom, root, "select", &[]);
        let group = add(&mut dom, select, "optgroup", &[]);
        add(&mut dom, group, "option", &[("disabled", ""), ("value", "")]);
        let second = add(&mut dom, group, "option", &[]);
        let text = dom.text("  Public \n video ");
        dom.append(second, text);
        assert_eq!(value_of(&dom, &values, select), "Public video", "the first that isn't disabled, its text");
        add(&mut dom, select, "option", &[("value", "private"), ("selected", "")]);
        assert_eq!(value_of(&dom, &values, select), "private");
        values.insert(select, "unlisted".into());
        assert_eq!(value_of(&dom, &values, select), "unlisted", "what was chosen");
        let area = add(&mut dom, root, "textarea", &[]);
        let words = dom.text("kept words");
        dom.append(area, words);
        assert_eq!(value_of(&dom, &values, area), "kept words");
    }

    #[test]
    fn required_fields_keep_a_form_back() {
        let mut dom = doc();
        let mut values = Values::default();
        let root = dom.root;
        let form = add(&mut dom, root, "form", &[]);
        let email = add(&mut dom, form, "input", &[("type", "email"), ("required", "")]);
        let terms = add(&mut dom, form, "input", &[("type", "checkbox"), ("required", "")]);
        assert_eq!(invalid(&dom, &values, form, None).map(|(node, _)| node), Some(email));
        values.insert(email, "someone".into());
        assert!(invalid(&dom, &values, form, None).is_some_and(|(node, said)| node == email && said.contains("email address")));
        values.insert(email, "someone@acme.example".into());
        assert_eq!(invalid(&dom, &values, form, None).map(|(node, _)| node), Some(terms));
        values.insert(terms, "true".into());
        assert_eq!(invalid(&dom, &values, form, None), None);
        values.insert(email, String::new());
        dom.set_attr(form, "novalidate", "");
        assert_eq!(invalid(&dom, &values, form, None), None);
        assert!(is_email("a.b+c@mail.acme.example") && !is_email("a@") && !is_email("@acme.example") && !is_email("a b@acme.example"));
    }

    #[test]
    fn a_form_with_files_is_multipart() {
        let dir = std::env::temp_dir().join(format!("rocx-controls-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("photo.jpg");
        std::fs::write(&path, [0xff, 0xd8, 0x00, 0x01]).unwrap();
        let file = Picked { name: "my \"photo\".jpg".into(), kind: "image/jpeg".into(), size: 4, path: path.to_string_lossy().into_owned() };
        let (kind, body) = multipart(&[("caption".into(), Part::Text("Hello".into())), ("image".into(), Part::File(file))], "XYZ");
        assert_eq!(kind, "multipart/form-data; boundary=XYZ");
        let bytes = expand(Some(&kind), &body).unwrap();
        let mut want = b"--XYZ\r\ncontent-disposition: form-data; name=\"caption\"\r\n\r\nHello\r\n--XYZ\r\ncontent-disposition: form-data; name=\"image\"; filename=\"my %22photo%22.jpg\"\r\ncontent-type: image/jpeg\r\n\r\n".to_vec();
        want.extend_from_slice(&[0xff, 0xd8, 0x00, 0x01]);
        want.extend_from_slice(b"\r\n--XYZ--\r\n");
        assert_eq!(bytes, want);
        assert_eq!(expand(Some("application/x-www-form-urlencoded"), "a=1").unwrap(), b"a=1");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn picked_files_are_given_as_a_browser_gives_them() {
        let given = picked(7, r#"[{"name":"a b.png","type":"image/png","size":12,"path":"/data/cache/rocx-picked/1/a b.png"}]"#);
        assert_eq!(given, r#"[{"name":"a b.png","type":"image/png","size":12,"url":"file:///data/cache/rocx-picked/1/a%20b.png"}]"#);
        assert_eq!(file_of("file:///data/cache/rocx-picked/1/a%20b.png").map(|file| file.size), Some(12));
        assert_eq!(files_of(7).len(), 1);
        forget_files(7);
        assert!(files_of(7).is_empty());
    }
}
