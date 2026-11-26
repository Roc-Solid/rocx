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

/// A node, linked to its parent, its first and last child and its siblings: a child is put in,
/// taken out or moved in constant time, as the DOM's are, however many its parent has (a table of
/// 10,000 rows).
#[derive(Debug)]
pub struct Node {
    pub kind: Kind,
    pub parent: Option<NodeId>,
    first: Option<NodeId>,
    last: Option<NodeId>,
    prev: Option<NodeId>,
    next: Option<NodeId>,
    /// Let go of (`free`): its id is used again once the next render is over (`recycle`).
    gone: bool,
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
    /// In a browser (wasm32, spike/wasm-engine): every change since the last flush, as ops for the
    /// page's JavaScript to make on its own DOM (`web.rs`):
    ///
    /// ```text
    /// 1 ELEMENT id tag   2 TEXT id data   3 COMMENT id   4 FRAGMENT id
    /// 5 INSERT parent node before (u32::MAX: last)   6 DETACH node   7 SET_TEXT node data
    /// 8 ATTR node name value   9 REMOVE_ATTR node name   10 STYLE node name value ("": none)
    /// ```
    ///
    /// Ids are u32 little-endian; a string is its length in UTF-16 units (u32), its UTF-8 bytes in
    /// `texts`, in the ops' order, for the page to decode at once. 11 FREE node: the node is gone
    /// for good (its id may name another node in a later batch).
    pub ops: Vec<u8>,
    pub texts: Vec<u8>,
    /// Nodes let go of since the last render, and the ids free to use again.
    freed: Vec<NodeId>,
    spare: Vec<NodeId>,
    /// While set (`quietly`), changes make no ops: what a CLONE op makes on the page at once.
    quiet: bool,
    /// The templates the page has been sent (TEMPLATE ops), by id.
    sent: Vec<bool>,
}

impl Dom {
    pub fn new() -> Dom {
        let mut dom = Dom { nodes: Vec::new(), root: 0, ops: Vec::new(), texts: Vec::new(), freed: Vec::new(), spare: Vec::new(), quiet: false, sent: Vec::new() };
        dom.root = dom.element("rocx-root");
        dom
    }

    fn add(&mut self, kind: Kind) -> NodeId {
        let node = Node { kind: Kind::Comment, parent: None, first: None, last: None, prev: None, next: None, gone: false };
        let id = match self.spare.pop() {
            Some(id) => {
                self.nodes[id] = node;
                id
            }
            None => {
                self.nodes.push(node);
                self.nodes.len() - 1
            }
        };
        if cfg!(target_arch = "wasm32") {
            let id = id as u32;
            match &kind {
                Kind::Element { tag, .. } => self.op(1, &[id], &[tag]),
                Kind::Text(data) => self.op(2, &[id], &[data]),
                Kind::Comment => self.op(3, &[id], &[]),
                Kind::Fragment => self.op(4, &[id], &[]),
            }
        }
        self.nodes[id].kind = kind;
        id
    }

    /// A range's nodes and everything inside them, taken off the page and let go of for good (a
    /// list's row gone, its computations disposed): the nodes it held; their ids are used again
    /// after the next render, so a render never sees an id name two nodes.
    pub fn free_range(&mut self, range: Range) -> Vec<NodeId> {
        let mut nodes = vec![range.start];
        nodes.extend(self.inside(range));
        nodes.push(range.end);
        for &node in &nodes {
            self.detach(node);
        }
        self.let_go(nodes)
    }

    /// Detached nodes and everything inside them let go of for good (`free_range`).
    pub fn let_go(&mut self, mut nodes: Vec<NodeId>) -> Vec<NodeId> {
        let mut gone = Vec::new();
        while let Some(node) = nodes.pop() {
            if self.nodes[node].gone {
                continue;
            }
            nodes.extend(self.children(node));
            self.nodes[node].gone = true;
            self.nodes[node].parent = None;
            self.nodes[node].first = None;
            self.nodes[node].last = None;
            self.nodes[node].prev = None;
            self.nodes[node].next = None;
            self.nodes[node].kind = Kind::Comment;
            self.op(11, &[node as u32], &[]);
            self.freed.push(node);
            gone.push(node);
        }
        gone
    }

    /// Runs `f` with no ops made: the page makes what it changes another way (a CLONE op).
    pub fn quietly<R>(&mut self, f: impl FnOnce(&mut Dom) -> R) -> R {
        let was = std::mem::replace(&mut self.quiet, true);
        let answer = f(self);
        self.quiet = was;
        answer
    }

    /// Whether the page has template `id` (a TEMPLATE op), saying it has from now on.
    pub fn template_sent(&mut self, id: usize) -> bool {
        if self.sent.len() <= id {
            self.sent.resize(id + 1, false);
        }
        std::mem::replace(&mut self.sent[id], true)
    }

    /// 12 TEMPLATE id html: a template's skeleton, as markup, for the page to copy.
    pub fn template_op(&mut self, id: usize, html: &str) {
        self.op(12, &[id as u32], &[html]);
    }

    /// 13 CLONE template count ids…: a copy of a template's skeleton, its nodes (in document order,
    /// its root first) these, made quietly here.
    pub fn clone_op(&mut self, template: usize, nodes: &[NodeId]) {
        if !cfg!(target_arch = "wasm32") || self.quiet {
            return;
        }
        self.ops.push(13);
        self.ops.extend_from_slice(&(template as u32).to_le_bytes());
        self.ops.extend_from_slice(&(nodes.len() as u32).to_le_bytes());
        for &node in nodes {
            self.ops.extend_from_slice(&(node as u32).to_le_bytes());
        }
    }

    /// `old` replaced by `node` (a fragment: its children) where it is, and taken off the page: 14
    /// REPLACE old node.
    pub fn replace(&mut self, old: NodeId, node: NodeId) {
        let Some(parent) = self.nodes[old].parent else { return };
        self.op(14, &[old as u32, node as u32], &[]);
        self.quietly(|dom| {
            dom.insert_before(parent, node, Some(old));
            dom.unlink(old);
        });
    }

    /// The render after nodes were let go of is over: their ids may be used again.
    pub fn recycle(&mut self) {
        self.spare.append(&mut self.freed);
    }

    /// An op for the browser's DOM (`ops`): its code, its ids, its strings.
    fn op(&mut self, code: u8, ids: &[u32], texts: &[&str]) {
        if !cfg!(target_arch = "wasm32") || self.quiet {
            return;
        }
        self.ops.push(code);
        for id in ids {
            self.ops.extend_from_slice(&id.to_le_bytes());
        }
        for text in texts {
            let units = if text.is_ascii() { text.len() } else { text.encode_utf16().count() };
            self.ops.extend_from_slice(&(units as u32).to_le_bytes());
            self.texts.extend_from_slice(text.as_bytes());
        }
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
        if self.nodes[node].parent.is_some() {
            self.op(6, &[node as u32], &[]);
        }
        self.unlink(node);
    }

    /// The same, said to no one: the node is put somewhere else at once (`insert_before`).
    fn unlink(&mut self, node: NodeId) {
        let Some(parent) = self.nodes[node].parent.take() else { return };
        let (prev, next) = (self.nodes[node].prev.take(), self.nodes[node].next.take());
        match prev {
            Some(prev) => self.nodes[prev].next = next,
            None => self.nodes[parent].first = next,
        }
        match next {
            Some(next) => self.nodes[next].prev = prev,
            None => self.nodes[parent].last = prev,
        }
    }

    /// A node's children, first to last.
    pub fn children(&self, node: NodeId) -> Children<'_> {
        Children { dom: self, at: self.nodes[node].first }
    }

    pub fn first_child(&self, node: NodeId) -> Option<NodeId> {
        self.nodes[node].first
    }

    pub fn last_child(&self, node: NodeId) -> Option<NodeId> {
        self.nodes[node].last
    }

    pub fn previous_sibling(&self, node: NodeId) -> Option<NodeId> {
        self.nodes[node].prev
    }

    /// Puts comments around `node`, where it is: a range that holds it (a D-070 hole whose text
    /// turned into markup).
    pub fn wrap_in_range(&mut self, node: NodeId) -> Range {
        let (start, end) = (self.comment(), self.comment());
        if let Some(parent) = self.nodes[node].parent {
            let after = self.next_sibling(node);
            self.insert_before(parent, start, Some(node));
            self.insert_before(parent, end, after);
        }
        Range { start, end }
    }

    /// Puts `node` in `parent` before `before` (last with none). A fragment moves its children
    /// there, and is left empty.
    pub fn insert_before(&mut self, parent: NodeId, node: NodeId, before: Option<NodeId>) {
        if self.is_fragment(node) {
            while let Some(child) = self.nodes[node].first {
                self.unlink(child);
                self.insert_before(parent, child, before);
            }
            return;
        }
        self.unlink(node);
        // A `before` that isn't `parent`'s child puts the node last, as it always has here.
        let before = before.filter(|&before| self.nodes[before].parent == Some(parent));
        self.op(5, &[parent as u32, node as u32, before.map_or(u32::MAX, |before| before as u32)], &[]);
        let prev = match before {
            Some(before) => self.nodes[before].prev,
            None => self.nodes[parent].last,
        };
        self.nodes[node].parent = Some(parent);
        self.nodes[node].prev = prev;
        self.nodes[node].next = before;
        match prev {
            Some(prev) => self.nodes[prev].next = Some(node),
            None => self.nodes[parent].first = Some(node),
        }
        match before {
            Some(before) => self.nodes[before].prev = Some(node),
            None => self.nodes[parent].last = Some(node),
        }
    }

    pub fn append(&mut self, parent: NodeId, node: NodeId) {
        self.insert_before(parent, node, None);
    }

    pub fn next_sibling(&self, node: NodeId) -> Option<NodeId> {
        self.nodes[node].next
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

    /// A range and what it shows, moved before `before` in `parent`, node by node.
    pub fn move_range(&mut self, range: Range, parent: NodeId, before: Option<NodeId>) {
        let mut at = Some(range.start);
        while let Some(node) = at {
            let next = self.nodes[node].next;
            self.insert_before(parent, node, before);
            if node == range.end {
                break;
            }
            at = next;
        }
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
        self.op(7, &[node as u32], &[data]);
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
        self.op(8, &[node as u32], &[name, value]);
        if let Kind::Element { attrs, .. } = &mut self.nodes[node].kind {
            match attrs.iter_mut().find(|(named, _)| named == name) {
                Some(entry) => entry.1 = value.to_string(),
                None => attrs.push((name.to_string(), value.to_string())),
            }
        }
    }

    pub fn remove_attr(&mut self, node: NodeId, name: &str) {
        self.op(9, &[node as u32], &[name]);
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
        self.op(10, &[node as u32], &[name, value]);
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

/// A node's children, first to last (`Dom::children`).
pub struct Children<'a> {
    dom: &'a Dom,
    at: Option<NodeId>,
}

impl Iterator for Children<'_> {
    type Item = NodeId;

    fn next(&mut self) -> Option<NodeId> {
        let node = self.at?;
        self.at = self.dom.nodes[node].next;
        Some(node)
    }
}
