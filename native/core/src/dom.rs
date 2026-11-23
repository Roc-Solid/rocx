//! The engine's own document: what `web/runtime.js` builds in the browser's DOM, built here instead
//! (elements, text, the comments that mark a hole's range, fragments), so the engine can follow the
//! browser's step by step. The phone never sees it: `native.rs` turns it into native views after
//! each flush.

pub type NodeId = usize;

#[derive(Debug)]
pub enum Kind {
    Element { tag: String, attrs: Vec<(String, String)>, styles: Vec<(String, String)> },
    Text(String),
    /// A range's marker (`<!--x-->`), which only the engine sees.
    Comment,
    /// A detached list of nodes, which moves its children where it is put (`DocumentFragment`).
    Fragment,
}

#[derive(Debug)]
pub struct Node {
    pub kind: Kind,
    pub parent: Option<NodeId>,
    pub children: Vec<NodeId>,
}

/// The nodes between two comments: what a markup or list hole, a <Show>, a <For>, a row or a
/// boundary shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Range {
    pub start: NodeId,
    pub end: NodeId,
}

pub struct Dom {
    pub nodes: Vec<Node>,
    /// What the app's markup goes in: the screen.
    pub root: NodeId,
}

impl Dom {
    pub fn new() -> Dom {
        let mut dom = Dom { nodes: Vec::new(), root: 0 };
        dom.root = dom.element("rocx-root");
        dom
    }

    fn add(&mut self, kind: Kind) -> NodeId {
        self.nodes.push(Node { kind, parent: None, children: Vec::new() });
        self.nodes.len() - 1
    }

    pub fn element(&mut self, tag: &str) -> NodeId {
        self.add(Kind::Element { tag: tag.to_string(), attrs: Vec::new(), styles: Vec::new() })
    }

    pub fn text(&mut self, data: &str) -> NodeId {
        self.add(Kind::Text(data.to_string()))
    }

    pub fn comment(&mut self) -> NodeId {
        self.add(Kind::Comment)
    }

    pub fn fragment(&mut self) -> NodeId {
        self.add(Kind::Fragment)
    }

    pub fn is_fragment(&self, node: NodeId) -> bool {
        matches!(self.nodes[node].kind, Kind::Fragment)
    }

    pub fn tag(&self, node: NodeId) -> Option<&str> {
        match &self.nodes[node].kind {
            Kind::Element { tag, .. } => Some(tag),
            _ => None,
        }
    }

    /// Takes a node out of its parent, if it has one.
    pub fn detach(&mut self, node: NodeId) {
        if let Some(parent) = self.nodes[node].parent.take() {
            let children = &mut self.nodes[parent].children;
            if let Some(at) = children.iter().position(|&child| child == node) {
                children.remove(at);
            }
        }
    }

    /// Puts `node` in `parent` before `before` (last with none). A fragment moves its children
    /// there, and is left empty.
    pub fn insert_before(&mut self, parent: NodeId, node: NodeId, before: Option<NodeId>) {
        if self.is_fragment(node) {
            let moved = std::mem::take(&mut self.nodes[node].children);
            for child in moved {
                self.nodes[child].parent = None;
                self.insert_before(parent, child, before);
            }
            return;
        }
        self.detach(node);
        let at = match before {
            Some(before) => self.nodes[parent].children.iter().position(|&child| child == before).unwrap_or(self.nodes[parent].children.len()),
            None => self.nodes[parent].children.len(),
        };
        self.nodes[parent].children.insert(at, node);
        self.nodes[node].parent = Some(parent);
    }

    pub fn append(&mut self, parent: NodeId, node: NodeId) {
        self.insert_before(parent, node, None);
    }

    pub fn next_sibling(&self, node: NodeId) -> Option<NodeId> {
        let parent = self.nodes[node].parent?;
        let children = &self.nodes[parent].children;
        let at = children.iter().position(|&child| child == node)?;
        children.get(at + 1).copied()
    }

    /// A range of its own, in a fragment (`makeRange`): the fragment, to put it where it goes.
    pub fn make_range(&mut self) -> (Range, NodeId) {
        let fragment = self.fragment();
        let (start, end) = (self.comment(), self.comment());
        self.append(fragment, start);
        self.append(fragment, end);
        (Range { start, end }, fragment)
    }

    /// The nodes strictly between a range's comments.
    pub fn inside(&self, range: Range) -> Vec<NodeId> {
        let mut out = Vec::new();
        let mut at = self.next_sibling(range.start);
        while let Some(node) = at {
            if node == range.end {
                break;
            }
            out.push(node);
            at = self.next_sibling(node);
        }
        out
    }

    /// What a range shows, replaced with `content` (a node or a fragment), as `replaceRange`.
    pub fn replace_range(&mut self, range: Range, content: NodeId) {
        for node in self.inside(range) {
            self.detach(node);
        }
        match self.nodes[range.end].parent {
            Some(parent) => self.insert_before(parent, content, Some(range.end)),
            None => {}
        }
    }

    /// A range and what it shows, moved into a fragment (`collectRange`).
    pub fn collect_range(&mut self, range: Range) -> NodeId {
        let fragment = self.fragment();
        let mut nodes = vec![range.start];
        nodes.extend(self.inside(range));
        nodes.push(range.end);
        for node in nodes {
            self.append(fragment, node);
        }
        fragment
    }

    /// A range and what it shows, taken off the page (`removeRange`).
    pub fn remove_range(&mut self, range: Range) {
        let mut nodes = vec![range.start];
        nodes.extend(self.inside(range));
        nodes.push(range.end);
        for node in nodes {
            self.detach(node);
        }
    }

    pub fn set_text(&mut self, node: NodeId, data: &str) {
        if let Kind::Text(text) = &mut self.nodes[node].kind {
            text.clear();
            text.push_str(data);
        }
    }

    pub fn text_of(&self, node: NodeId) -> &str {
        match &self.nodes[node].kind {
            Kind::Text(text) => text,
            _ => "",
        }
    }

    pub fn attr(&self, node: NodeId, name: &str) -> Option<&str> {
        match &self.nodes[node].kind {
            Kind::Element { attrs, .. } => attrs.iter().find(|(named, _)| named == name).map(|(_, value)| value.as_str()),
            _ => None,
        }
    }

    pub fn set_attr(&mut self, node: NodeId, name: &str, value: &str) {
        if let Kind::Element { attrs, .. } = &mut self.nodes[node].kind {
            match attrs.iter_mut().find(|(named, _)| named == name) {
                Some(entry) => entry.1 = value.to_string(),
                None => attrs.push((name.to_string(), value.to_string())),
            }
        }
    }

    pub fn remove_attr(&mut self, node: NodeId, name: &str) {
        if let Kind::Element { attrs, .. } = &mut self.nodes[node].kind {
            attrs.retain(|(named, _)| named != name);
        }
    }

    pub fn has_class(&self, node: NodeId, name: &str) -> bool {
        self.attr(node, "class").is_some_and(|classes| classes.split_whitespace().any(|class| class == name))
    }

    pub fn toggle_class(&mut self, node: NodeId, name: &str, on: bool) {
        let mut classes: Vec<String> = self.attr(node, "class").unwrap_or("").split_whitespace().map(str::to_string).collect();
        let has = classes.iter().any(|class| class == name);
        if on && !has {
            classes.push(name.to_string());
        } else if !on && has {
            classes.retain(|class| class != name);
        } else {
            return;
        }
        self.set_attr(node, "class", &classes.join(" "));
    }

    pub fn style(&self, node: NodeId, name: &str) -> &str {
        match &self.nodes[node].kind {
            Kind::Element { styles, .. } => styles.iter().find(|(named, _)| named == name).map(|(_, value)| value.as_str()).unwrap_or(""),
            _ => "",
        }
    }

    pub fn set_style(&mut self, node: NodeId, name: &str, value: &str) {
        if let Kind::Element { styles, .. } = &mut self.nodes[node].kind {
            styles.retain(|(named, _)| named != name);
            if !value.is_empty() {
                styles.push((name.to_string(), value.to_string()));
            }
        }
    }

    /// Whether `node` is on the screen: inside the root.
    pub fn connected(&self, node: NodeId) -> bool {
        let mut at = Some(node);
        while let Some(node) = at {
            if node == self.root {
                return true;
            }
            at = self.nodes[node].parent;
        }
        false
    }
}
