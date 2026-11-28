//! Layout (D-137): the projected views laid out by Taffy (block, flex, grid, absolute and fixed
//! positioning), as CSS lays out the browser's boxes. A view's computed CSS becomes Taffy's
//! `Style` (`style`); the tree mirrors the views and is kept between flushes, so only what changed
//! (a style, its children, a text) is laid out again, Taffy's caches keeping the rest. Text is
//! measured by the phone (`Platform::measure`: Android's StaticLayout), through Taffy's measure
//! function, its answers cached here; replaced elements (`<svg>`, `<img>`, fields) have their
//! intrinsic sizes. The result is each view's frame: where it is in its parent view (an absolute
//! one: in its containing block; a fixed one: on the screen) and its size, in CSS px (dp).

use crate::css::Computed;
use crate::values::{self, Length};
use crate::fx::HashMap;
use taffy::prelude::*;
use taffy::{
    AlignContent, AlignItems, BoxSizing, CacheTree, CalcHandle, DetailedLayoutInfo, GridPlacement, GridTemplateArea, GridTemplateAreas, GridTemplateComponent, LayoutInput, LayoutOutput, Overflow, Point, Position, RunMode,
};

/// How a leaf's content is sized.
#[derive(Clone, Debug, PartialEq)]
pub enum Content {
    /// A box: its children say.
    None,
    /// Text, measured by the phone: its version (one more each time its runs or look change), and
    /// what the Mac's rough measure needs.
    Text { version: u64, chars: Vec<usize>, font_size: f32, line_height: f32, nowrap: bool },
    /// A replaced element's own size (`<svg>`'s attributes, a field's), its ratio when it keeps one.
    Fixed { width: f32, height: f32 },
    /// A field's own size (D-139: an `<input>`'s, a `<textarea>`'s rows): kept as it is when one side
    /// is given, where an image's keeps its ratio.
    Field { width: f32, height: f32 },
}

/// What the phone measures a text with: a width to wrap at (none: on one line), or its narrowest
/// (each word on a line of its own).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Width {
    AtMost(f32),
    MaxContent,
    MinContent,
}

/// Who measures text (the platform's half).
pub trait Measurer {
    fn measure(&mut self, id: u64, content: &Content, width: Width) -> (f32, f32);
}

/// A rough measure, for the Mac and tests: each character as wide as half the font size, words
/// wrapped greedily.
pub fn rough_measure(content: &Content, width: Width) -> (f32, f32) {
    let Content::Text { chars, font_size, line_height, nowrap, .. } = content else { return (0.0, 0.0) };
    let advance = font_size * 0.5;
    let lines: Vec<usize> = chars.clone();
    let words_widest = lines.iter().copied().max().unwrap_or(0) as f32 * advance;
    let total: f32 = lines.iter().map(|w| *w as f32 * advance).sum::<f32>() + lines.len().saturating_sub(1) as f32 * advance;
    let (w, rows) = match width {
        Width::MaxContent => (total, 1),
        Width::MinContent if !nowrap => (words_widest, lines.len().max(1)),
        Width::MinContent => (total, 1),
        Width::AtMost(_) if *nowrap => (total, 1),
        Width::AtMost(most) => {
            let mut rows = 1;
            let mut line = 0.0f32;
            let mut widest = 0.0f32;
            for word in &lines {
                let word = *word as f32 * advance;
                let next = if line == 0.0 { word } else { line + advance + word };
                if next > most && line > 0.0 {
                    rows += 1;
                    widest = widest.max(line);
                    line = word;
                } else {
                    line = next;
                }
            }
            (widest.max(line).min(most.max(words_widest)), rows)
        }
    };
    (w.ceil(), (rows as f32 * line_height).ceil())
}

struct Node {
    view: u64,
    style: Style,
    children: Vec<usize>,
    parent: Option<usize>,
    content: Content,
    measured: Vec<(u64, Width, (f32, f32))>,
    cache: taffy::Cache,
    unrounded: Layout,
    final_layout: Layout,
    hoisted: Vec<NodeId>,
    detailed: DetailedLayoutInfo,
}

/// The tree Taffy lays out: one node a view, kept between flushes.
#[derive(Default)]
pub struct Tree {
    nodes: Vec<Node>,
    free: Vec<usize>,
    by_view: HashMap<u64, usize>,
}

/// What a view's node should be now.
pub struct Want<'a> {
    pub style: &'a Style,
    pub children: &'a [u64],
    pub content: &'a Content,
}

impl Tree {
    fn node(&self, id: NodeId) -> &Node {
        &self.nodes[usize::from(id)]
    }

    fn node_mut(&mut self, id: NodeId) -> &mut Node {
        &mut self.nodes[usize::from(id)]
    }

    /// A node's cache cleared, and its ancestors' (what they measured of it is stale).
    fn dirty(&mut self, at: usize) {
        let mut at = Some(at);
        while let Some(node) = at {
            self.nodes[node].cache.clear();
            at = self.nodes[node].parent;
        }
    }

    /// The tree brought to what the views are now: nodes made for new views, let go of for gone
    /// ones, styles, children and contents changed where they did (and those nodes dirtied).
    pub fn sync<'a>(&mut self, root: u64, views: impl Iterator<Item = (u64, Want<'a>)>) {
        let mut seen: HashMap<u64, ()> = HashMap::default();
        let mut wanted: Vec<(usize, Vec<u64>)> = Vec::new();
        for (view, want) in views {
            seen.insert(view, ());
            let at = match self.by_view.get(&view) {
                Some(&at) => at,
                None => {
                    let node = Node {
                        view,
                        style: want.style.clone(),
                        children: Vec::new(),
                        parent: None,
                        content: want.content.clone(),
                        measured: Vec::new(),
                        cache: taffy::Cache::new(),
                        unrounded: Layout::with_order(0),
                        final_layout: Layout::with_order(0),
                        hoisted: Vec::new(),
                        detailed: DetailedLayoutInfo::None,
                    };
                    let at = match self.free.pop() {
                        Some(at) => {
                            self.nodes[at] = node;
                            at
                        }
                        None => {
                            self.nodes.push(node);
                            self.nodes.len() - 1
                        }
                    };
                    self.by_view.insert(view, at);
                    at
                }
            };
            if self.nodes[at].style != *want.style {
                self.nodes[at].style = want.style.clone();
                self.dirty(at);
            }
            if self.nodes[at].content != *want.content {
                self.nodes[at].content = want.content.clone();
                self.nodes[at].measured.clear();
                self.dirty(at);
            }
            wanted.push((at, want.children.to_vec()));
        }
        // Gone views' nodes let go of.
        let gone: Vec<u64> = self.by_view.keys().filter(|view| !seen.contains_key(view)).copied().collect();
        for view in gone {
            if let Some(at) = self.by_view.remove(&view) {
                if let Some(parent) = self.nodes[at].parent {
                    self.dirty(parent);
                }
                self.nodes[at].children.clear();
                self.nodes[at].parent = None;
                self.nodes[at].hoisted.clear();
                self.free.push(at);
            }
        }
        for (at, children) in wanted {
            let ids: Vec<usize> = children.iter().filter_map(|child| self.by_view.get(child).copied()).collect();
            if self.nodes[at].children != ids {
                for &old in &self.nodes[at].children.clone() {
                    if self.nodes[old].parent == Some(at) {
                        self.nodes[old].parent = None;
                    }
                }
                for &child in &ids {
                    self.nodes[child].parent = Some(at);
                }
                self.nodes[at].children = ids;
                self.dirty(at);
            } else {
                for &child in &ids {
                    self.nodes[child].parent = Some(at);
                }
            }
        }
        let _ = root;
    }

    /// Lays the tree out from `root` on a screen of `width` by `height`, with `measurer` for text.
    pub fn compute(&mut self, root: u64, width: f32, height: f32, measurer: &mut dyn Measurer) {
        let Some(&at) = self.by_view.get(&root) else { return };
        let mut view = View { tree: self, measurer };
        taffy::compute_root_layout(&mut view, NodeId::from(at), Size { width: AvailableSpace::Definite(width), height: AvailableSpace::Definite(height) });
        taffy::round_layout(&mut view, NodeId::from(at));
    }

    /// A view's frame: `x y w h` in its parent (or containing block), and the size of what it holds
    /// (its scrolling content).
    pub fn frame(&self, view: u64) -> Option<([f32; 4], [f32; 2])> {
        let node = &self.nodes[*self.by_view.get(&view)?];
        let layout = &node.final_layout;
        let overflow = layout.scrollable_overflow_rect;
        let content = [(layout.border.left + overflow.right().abs()).max(layout.size.width), (layout.border.top + overflow.bottom().abs()).max(layout.size.height)];
        Some(([layout.location.x, layout.location.y, layout.size.width, layout.size.height], content))
    }

    /// Where a view's content box is in it: its border and padding, `top right bottom left`.
    pub fn inset(&self, view: u64) -> Option<[f32; 4]> {
        let layout = &self.nodes[*self.by_view.get(&view)?].final_layout;
        Some([layout.border.top + layout.padding.top, layout.border.right + layout.padding.right, layout.border.bottom + layout.padding.bottom, layout.border.left + layout.padding.left])
    }

    /// A view's border widths, `top right bottom left`.
    pub fn border(&self, view: u64) -> Option<[f32; 4]> {
        let layout = &self.nodes[*self.by_view.get(&view)?].final_layout;
        Some([layout.border.top, layout.border.right, layout.border.bottom, layout.border.left])
    }

    /// How many nodes it has (for tests and the log).
    pub fn len(&self) -> usize {
        self.by_view.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_view.is_empty()
    }
}

struct View<'t> {
    tree: &'t mut Tree,
    measurer: &'t mut dyn Measurer,
}

impl View<'_> {
    fn child_layout(&mut self, node_id: NodeId, inputs: LayoutInput, block_ctx: Option<&mut taffy::BlockContext<'_>>) -> LayoutOutput {
        if inputs.run_mode == RunMode::PerformHiddenLayout {
            self.tree.node_mut(node_id).final_layout = Layout::with_order(0);
            return taffy::compute_hidden_layout(self, node_id);
        }
        // A flex or grid box with an `aspect-ratio` whose width its parent gave it: its height from
        // the ratio (Taffy's flex and grid don't apply it to a size given from outside; its block does).
        let mut inputs = inputs;
        {
            let style = &self.tree.node(node_id).style;
            if let Some(ratio) = style.aspect_ratio.filter(|r| *r > 0.0)
                && matches!(style.display, Display::Flex | Display::Grid)
                && style.size.height == Dimension::auto()
            {
                if let (Some(width), None) = (inputs.known_dimensions.width, inputs.known_dimensions.height) {
                    inputs.known_dimensions.height = Some(width / ratio);
                }
            }
        }
        // A flex box sized by what it holds (a flex item, an inline box) is as wide as that, but no
        // wider than its room unless its narrowest is: CSS's fit-content, where Taffy's takes the
        // widest (its items' bases on one line) and spills over.
        let style = &self.tree.node(node_id).style;
        if style.display == Display::Flex
            && inputs.known_dimensions.width.is_none()
            && style.size.width == Dimension::auto()
            && inputs.run_mode != RunMode::PerformHiddenLayout
            && let AvailableSpace::Definite(room) = inputs.available_space.width
        {
            let first = self.cached(node_id, inputs, block_ctx);
            if first.size.width <= room + 0.5 {
                return first;
            }
            let narrowest = LayoutInput { run_mode: RunMode::ComputeSize, axis: taffy::RequestedAxis::Horizontal, available_space: Size { width: AvailableSpace::MinContent, height: inputs.available_space.height }, ..inputs };
            let least = self.cached(node_id, narrowest, None).size.width;
            let fitted = LayoutInput { known_dimensions: Size { width: Some(room.max(least)), height: inputs.known_dimensions.height }, ..inputs };
            return self.cached(node_id, fitted, None);
        }
        self.cached(node_id, inputs, block_ctx)
    }

    fn cached(&mut self, node_id: NodeId, inputs: LayoutInput, block_ctx: Option<&mut taffy::BlockContext<'_>>) -> LayoutOutput {
        taffy::compute_cached_layout(self, node_id, inputs, |view, node_id, inputs| {
            let display = view.tree.node(node_id).style.display;
            let has_children = !view.tree.node(node_id).children.is_empty();
            let mut output = match (display, has_children) {
                (Display::None, _) => taffy::compute_hidden_layout(view, node_id),
                (Display::Block, true) => taffy::compute_block_layout(view, node_id, inputs, block_ctx),
                (Display::FlowRoot, true) => taffy::compute_block_layout(view, node_id, inputs, None),
                (Display::Flex, true) => taffy::compute_flexbox_layout(view, node_id, inputs),
                (Display::Grid, true) => taffy::compute_grid_layout(view, node_id, inputs),
                (_, false) => view.leaf(node_id, inputs),
            };
            if inputs.run_mode == RunMode::PerformLayout {
                taffy::compute_oof_layout(view, node_id, &mut output);
            }
            output
        })
    }

    fn leaf(&mut self, node_id: NodeId, inputs: LayoutInput) -> LayoutOutput {
        let at = usize::from(node_id);
        let tree = &mut *self.tree;
        let measurer = &mut *self.measurer;
        let node = &mut tree.nodes[at];
        let (view, content) = (node.view, node.content.clone());
        let measured = &mut node.measured;
        let style = &node.style;
        taffy::compute_leaf_layout(inputs, style, |handle: CalcHandle, basis| values::calc_value(handle.to_bits(), basis), |known, available| {
            if let (Some(width), Some(height)) = (known.width, known.height) {
                return Size { width, height };
            }
            match &content {
                Content::None => Size { width: known.width.unwrap_or(0.0), height: known.height.unwrap_or(0.0) },
                // Its own size (a ratio it keeps is its style's `aspect_ratio`, which Taffy applies).
                Content::Fixed { width, height } => Size { width: known.width.unwrap_or(*width), height: known.height.unwrap_or(*height) },
                Content::Field { width, height } => Size { width: known.width.unwrap_or(*width), height: known.height.unwrap_or(*height) },
                Content::Text { version, .. } => {
                    let width = match known.width {
                        Some(w) => Width::AtMost(w),
                        None => match available.width {
                            AvailableSpace::Definite(w) => Width::AtMost(w),
                            AvailableSpace::MinContent => Width::MinContent,
                            AvailableSpace::MaxContent => Width::MaxContent,
                        },
                    };
                    let width = match width {
                        Width::AtMost(w) => Width::AtMost((w.max(0.0) * 4.0).round() / 4.0),
                        other => other,
                    };
                    let found = measured.iter().find(|(v, w, _)| v == version && *w == width).map(|(_, _, size)| *size);
                    let (w, h) = match found {
                        Some(size) => size,
                        None => {
                            let size = measurer.measure(view, &content, width);
                            if measured.len() > 8 {
                                measured.remove(0);
                            }
                            measured.push((*version, width, size));
                            size
                        }
                    };
                    // Whole dp, up: the layout rounds edges to whole dp, and a text a hair wider than
                    // its frame would wrap.
                    Size { width: known.width.unwrap_or(w.ceil()), height: known.height.unwrap_or(h.ceil()) }
                }
            }
        })
    }
}

struct Children<'a>(std::slice::Iter<'a, usize>);

impl Iterator for Children<'_> {
    type Item = NodeId;
    fn next(&mut self) -> Option<NodeId> {
        self.0.next().map(|&at| NodeId::from(at))
    }
}

impl taffy::TraversePartialTree for View<'_> {
    type ChildIter<'a>
        = Children<'a>
    where
        Self: 'a;

    fn child_ids(&self, node_id: NodeId) -> Self::ChildIter<'_> {
        Children(self.tree.node(node_id).children.iter())
    }

    fn child_count(&self, node_id: NodeId) -> usize {
        self.tree.node(node_id).children.len()
    }

    fn get_child_id(&self, node_id: NodeId, index: usize) -> NodeId {
        NodeId::from(self.tree.node(node_id).children[index])
    }
}

impl taffy::TraverseTree for View<'_> {}

impl taffy::LayoutPartialTree for View<'_> {
    type CustomIdent = String;
    type CoreContainerStyle<'a>
        = &'a Style
    where
        Self: 'a;

    fn get_core_container_style(&self, node_id: NodeId) -> Self::CoreContainerStyle<'_> {
        &self.tree.node(node_id).style
    }

    fn set_unrounded_layout(&mut self, node_id: NodeId, layout: &Layout) {
        self.tree.node_mut(node_id).unrounded = *layout;
    }

    fn resolve_calc_value(&self, val: CalcHandle, basis: f32) -> f32 {
        values::calc_value(val.to_bits(), basis)
    }

    fn compute_child_layout(&mut self, node_id: NodeId, inputs: LayoutInput) -> LayoutOutput {
        self.child_layout(node_id, inputs, None)
    }
}

impl taffy::LayoutContainingBlock for View<'_> {
    type OofItemStyle<'a>
        = &'a Style
    where
        Self: 'a;

    fn get_oof_item_style(&self, node_id: NodeId) -> Self::OofItemStyle<'_> {
        &self.tree.node(node_id).style
    }

    fn clear_hoisted_children(&mut self, node_id: NodeId) {
        self.tree.node_mut(node_id).hoisted.clear();
    }

    fn add_hoisted_children(&mut self, node_id: NodeId, hoisted: &[NodeId]) {
        self.tree.node_mut(node_id).hoisted.extend_from_slice(hoisted);
    }

    fn get_detailed_layout_info(&self, node_id: NodeId) -> &DetailedLayoutInfo {
        &self.tree.node(node_id).detailed
    }
}

impl CacheTree for View<'_> {
    fn cache_get(&self, node_id: NodeId, input: &LayoutInput) -> Option<LayoutOutput> {
        self.tree.node(node_id).cache.get(input)
    }

    fn cache_store(&mut self, node_id: NodeId, input: &LayoutInput, output: LayoutOutput) {
        self.tree.node_mut(node_id).cache.store(input, output)
    }

    fn cache_clear(&mut self, node_id: NodeId) {
        self.tree.node_mut(node_id).cache.clear();
    }
}

impl taffy::LayoutBlockContainer for View<'_> {
    type BlockContainerStyle<'a>
        = &'a Style
    where
        Self: 'a;
    type BlockItemStyle<'a>
        = &'a Style
    where
        Self: 'a;

    fn get_block_container_style(&self, node_id: NodeId) -> Self::BlockContainerStyle<'_> {
        &self.tree.node(node_id).style
    }

    fn get_block_child_style(&self, child_node_id: NodeId) -> Self::BlockItemStyle<'_> {
        &self.tree.node(child_node_id).style
    }

    fn compute_block_child_layout(&mut self, node_id: NodeId, inputs: LayoutInput, block_ctx: Option<&mut taffy::BlockContext<'_>>) -> LayoutOutput {
        self.child_layout(node_id, inputs, block_ctx)
    }
}

impl taffy::LayoutFlexboxContainer for View<'_> {
    type FlexboxContainerStyle<'a>
        = &'a Style
    where
        Self: 'a;
    type FlexboxItemStyle<'a>
        = &'a Style
    where
        Self: 'a;

    fn get_flexbox_container_style(&self, node_id: NodeId) -> Self::FlexboxContainerStyle<'_> {
        &self.tree.node(node_id).style
    }

    fn get_flexbox_child_style(&self, child_node_id: NodeId) -> Self::FlexboxItemStyle<'_> {
        &self.tree.node(child_node_id).style
    }
}

impl taffy::LayoutGridContainer for View<'_> {
    type GridContainerStyle<'a>
        = &'a Style
    where
        Self: 'a;
    type GridItemStyle<'a>
        = &'a Style
    where
        Self: 'a;

    fn get_grid_container_style(&self, node_id: NodeId) -> Self::GridContainerStyle<'_> {
        &self.tree.node(node_id).style
    }

    fn get_grid_child_style(&self, child_node_id: NodeId) -> Self::GridItemStyle<'_> {
        &self.tree.node(child_node_id).style
    }

    fn set_detailed_grid_info(&mut self, node_id: NodeId, info: taffy::DetailedGridInfo) {
        self.tree.node_mut(node_id).detailed = DetailedLayoutInfo::Grid(Box::new(info));
    }
}

impl taffy::RoundTree for View<'_> {
    fn get_unrounded_layout(&self, node_id: NodeId) -> Layout {
        self.tree.node(node_id).unrounded
    }

    fn set_final_layout(&mut self, node_id: NodeId, layout: &Layout) {
        self.tree.node_mut(node_id).final_layout = *layout;
    }

    fn is_out_of_flow(&self, node_id: NodeId) -> bool {
        let style = &self.tree.node(node_id).style;
        style.position.is_out_of_flow() && style.display != Display::None
    }

    fn hoisted_child_count(&self, node_id: NodeId) -> usize {
        self.tree.node(node_id).hoisted.len()
    }

    fn get_hoisted_child_id(&self, node_id: NodeId, index: usize) -> NodeId {
        self.tree.node(node_id).hoisted[index]
    }
}

// ---- CSS to Taffy ----

/// How a view lays out what it holds, besides what its CSS says.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Role {
    /// An element as its CSS has it.
    Element,
    /// An element whose content is inline boxes in a line (an inline-block among text): a flex row
    /// that wraps, standing in for CSS's line boxes.
    Line,
    /// An anonymous box: text beside blocks, or a line of inline boxes beside blocks.
    Anonymous,
    /// An anonymous line of inline boxes.
    AnonymousLine,
}

fn lp(length: &Length) -> LengthPercentage {
    match length {
        Length::Px(px) => LengthPercentage::length(*px),
        Length::Percent(p) => LengthPercentage::percent(p / 100.0),
        Length::Calc(calc) => LengthPercentage::calc(CalcHandle::from_bits(values::calc_handle(calc))),
        _ => LengthPercentage::length(0.0),
    }
}

fn lpa(length: &Length) -> LengthPercentageAuto {
    match length {
        Length::Px(px) => LengthPercentageAuto::length(*px),
        Length::Percent(p) => LengthPercentageAuto::percent(p / 100.0),
        Length::Calc(calc) => LengthPercentageAuto::calc(CalcHandle::from_bits(values::calc_handle(calc))),
        _ => LengthPercentageAuto::auto(),
    }
}

fn dimension(length: &Length) -> Dimension {
    match length {
        Length::Px(px) => Dimension::length(*px),
        Length::Percent(p) => Dimension::percent(p / 100.0),
        Length::Calc(calc) => Dimension::calc(CalcHandle::from_bits(values::calc_handle(calc))),
        Length::Keyword(word) => match word.as_str() {
            "min-content" => Dimension::min_content(),
            "max-content" => Dimension::max_content(),
            "fit-content" => Dimension::fit_content(),
            _ => Dimension::auto(),
        },
        Length::Auto => Dimension::auto(),
    }
}

/// A border side's width: none unless it has a style that draws.
pub fn border_width(c: &Computed, side: &str) -> f32 {
    let style = c.get(&format!("border-{side}-style")).unwrap_or("none");
    if matches!(style, "none" | "hidden") {
        return 0.0;
    }
    match c.get(&format!("border-{side}-width")).unwrap_or("medium") {
        "thin" => 1.0,
        "medium" => 3.0,
        "thick" => 5.0,
        _ => c.px(&format!("border-{side}-width"), 0.0).unwrap_or(3.0).max(0.0),
    }
}

fn align_items(value: Option<&str>) -> Option<AlignItems> {
    let value = value?.trim().to_ascii_lowercase();
    let value = value.replace("first baseline", "baseline").replace("last baseline", "baseline").replace("left", "start").replace("right", "end").replace("anchor-center", "center");
    if value == "legacy" || value.starts_with("legacy ") {
        return None;
    }
    value.parse::<AlignItems>().ok()
}

fn align_content(value: Option<&str>) -> Option<AlignContent> {
    let value = value?.trim().to_ascii_lowercase();
    let value = value.replace("left", "start").replace("right", "end").replace("first baseline", "start").replace("last baseline", "end").replace("baseline", "start");
    value.parse::<AlignContent>().ok()
}

/// Units Taffy's own parser doesn't read (`rem`, `em`, `vw`…), made px in a value (a grid's tracks).
fn plain_units(value: &str, c: &Computed) -> String {
    let mut out = String::with_capacity(value.len());
    let mut word = String::new();
    let flush = |word: &mut String, out: &mut String| {
        if word.is_empty() {
            return;
        }
        let keep = word.ends_with("px") || word.ends_with('%') || word.ends_with("fr") || word.parse::<f32>().is_ok() || !word.starts_with(|ch: char| ch.is_ascii_digit() || ch == '.' || ch == '-');
        if word.parse::<f32>().is_ok_and(|n| n == 0.0) {
            // A bare 0 is 0px (Taffy's parser wants the unit).
            out.push_str("0px");
        } else if keep {
            out.push_str(word);
        } else {
            match values::px(word, c.ctx) {
                Some(px) => out.push_str(&format!("{px}px")),
                None => out.push_str(word),
            }
        }
        word.clear();
    };
    let mut depth = 0;
    let mut calc = String::new();
    let chars: Vec<char> = value.chars().collect();
    let mut at = 0;
    while at < chars.len() {
        let ch = chars[at];
        // A calc() with no percentage in it: its value in px.
        if depth == 0 && value[value.char_indices().nth(at).map(|(i, _)| i).unwrap_or(0)..].starts_with("calc(") {
            flush(&mut word, &mut out);
            depth = 0;
            calc.clear();
            while at < chars.len() {
                let ch = chars[at];
                calc.push(ch);
                if ch == '(' {
                    depth += 1;
                } else if ch == ')' {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                at += 1;
            }
            at += 1;
            match values::px(&calc, c.ctx) {
                Some(px) => out.push_str(&format!("{px}px")),
                None => out.push_str(&calc),
            }
            continue;
        }
        if ch.is_alphanumeric() || ch == '.' || ch == '-' || ch == '%' || ch == '_' {
            word.push(ch);
        } else {
            flush(&mut word, &mut out);
            out.push(ch);
        }
        at += 1;
    }
    flush(&mut word, &mut out);
    out
}

fn grid_tracks(value: &str, c: &Computed) -> Option<(Vec<GridTemplateComponent<String>>, Vec<Vec<String>>)> {
    if value.trim() == "none" {
        return Some((Vec::new(), Vec::new()));
    }
    let plain = plain_units(value, c);
    let parsed: taffy::GridTemplateTracks<String, GridTemplateComponent<String>> = match plain.parse() {
        Ok(parsed) => parsed,
        Err(_) => {
            warn_once(format!("CSS grid tracks `{value}` aren't on phones yet: one column"));
            return None;
        }
    };
    let names = if parsed.line_names.iter().all(|names| names.is_empty()) { Vec::new() } else { parsed.line_names };
    Some((parsed.tracks, names))
}

thread_local! {
    static WARNED: std::cell::RefCell<std::collections::HashSet<String>> = std::cell::RefCell::new(std::collections::HashSet::new());
}

/// Says something about layout once.
fn warn_once(said: String) {
    if WARNED.with(|warned| warned.borrow_mut().insert(said.clone())) {
        crate::log(crate::Level::Warn, &format!("rocx native: {said}"));
    }
}

fn grid_areas(value: &str) -> Option<GridTemplateAreas<String>> {
    if value.trim() == "none" {
        return None;
    }
    let rows: Vec<Vec<String>> = values::split(value, None).iter().map(|row| row.trim_matches(|c| c == '"' || c == '\'').split_whitespace().map(str::to_string).collect()).collect();
    let row_count = rows.len() as u16;
    let column_count = rows.iter().map(Vec::len).max().unwrap_or(0) as u16;
    let mut areas: Vec<GridTemplateArea<String>> = Vec::new();
    for (r, row) in rows.iter().enumerate() {
        for (col, name) in row.iter().enumerate() {
            if name.chars().all(|c| c == '.') {
                continue;
            }
            let (r, col) = (r as u16 + 1, col as u16 + 1);
            match areas.iter_mut().find(|area| area.name == *name) {
                Some(area) => {
                    area.row_start = area.row_start.min(r);
                    area.row_end = area.row_end.max(r + 1);
                    area.column_start = area.column_start.min(col);
                    area.column_end = area.column_end.max(col + 1);
                }
                None => areas.push(GridTemplateArea { name: name.clone(), row_start: r, row_end: r + 1, column_start: col, column_end: col + 1 }),
            }
        }
    }
    Some(GridTemplateAreas { areas: areas.into_iter().collect(), row_count, column_count })
}

fn placement(value: Option<&str>) -> GridPlacement<String> {
    value.and_then(|value| value.trim().parse::<GridPlacement<String>>().ok()).unwrap_or(GridPlacement::Auto)
}

/// Whether a `display` is a flex or grid container's (whose children are its items, blockified).
pub fn lays_out_items(display: &str) -> bool {
    matches!(display, "flex" | "inline-flex" | "grid" | "inline-grid" | "table-row" | "-webkit-box" | "-webkit-inline-box")
}

/// The Taffy style of a view, from its computed CSS (an anonymous view's is its parent's, for its
/// inherited text, and lays itself out plainly), given its parent's `display`.
pub fn style(c: &Computed, role: Role, text_align: Option<&str>) -> Style {
    let mut style = Style { position: Position::Static, ..Style::default() };
    if matches!(role, Role::Anonymous | Role::AnonymousLine) {
        style.display = if role == Role::AnonymousLine { Display::Flex } else { Display::Block };
        if role == Role::AnonymousLine {
            line(&mut style, text_align);
        }
        return style;
    }
    let display = c.display();
    style.display = match display {
        "none" => Display::None,
        "flex" | "inline-flex" | "table-row" | "-webkit-box" | "-webkit-inline-box" => Display::Flex,
        "grid" | "inline-grid" => Display::Grid,
        "flow-root" => Display::FlowRoot,
        _ => Display::Block,
    };
    if display == "table-row" {
        style.align_items = AlignItems::STRETCH;
    }
    if display == "table-cell" {
        style.flex_grow = 1.0;
        style.flex_basis = Dimension::length(0.0);
    }
    if display == "-webkit-box" || display == "-webkit-inline-box" {
        // The old flexbox, as `-webkit-line-clamp` asks for: a block holding its text.
        style.display = Display::Block;
    }
    style.position = match c.get("position").unwrap_or("static") {
        "relative" | "sticky" => Position::Relative,
        "absolute" => Position::Absolute,
        "fixed" => Position::Fixed,
        _ => Position::Static,
    };
    style.box_sizing = if c.is("box-sizing", "border-box") { BoxSizing::BorderBox } else { BoxSizing::ContentBox };
    let get = |name: &str| c.length(name);
    if matches!(style.position, Position::Relative | Position::Absolute | Position::Fixed) && !c.is("position", "sticky") {
        style.inset = taffy::Rect {
            left: get("left").map(|l| lpa(&l)).unwrap_or(LengthPercentageAuto::auto()),
            right: get("right").map(|l| lpa(&l)).unwrap_or(LengthPercentageAuto::auto()),
            top: get("top").map(|l| lpa(&l)).unwrap_or(LengthPercentageAuto::auto()),
            bottom: get("bottom").map(|l| lpa(&l)).unwrap_or(LengthPercentageAuto::auto()),
        };
    }
    style.size = Size { width: get("width").map(|l| dimension(&l)).unwrap_or(Dimension::auto()), height: get("height").map(|l| dimension(&l)).unwrap_or(Dimension::auto()) };
    let bound = |name: &str| match get(name) {
        Some(Length::Keyword(_)) | Some(Length::Auto) | None => LengthPercentageAuto::auto(),
        Some(length) => lpa(&length),
    };
    style.min_size = Size { width: bound("min-width"), height: bound("min-height") };
    style.max_size = Size { width: bound("max-width"), height: bound("max-height") };
    if let Some(ratio) = c.get("aspect-ratio") {
        let ratio = ratio.replace("auto", "");
        let ratio = match ratio.split_once('/') {
            Some((w, h)) => values::number(w).zip(values::number(h)).filter(|(_, h)| *h > 0.0).map(|(w, h)| w / h),
            None => values::number(&ratio),
        };
        style.aspect_ratio = ratio.filter(|r| *r > 0.0);
    }
    let side = |prefix: &str, name: &str| get(&format!("{prefix}-{name}"));
    style.margin = taffy::Rect {
        left: side("margin", "left").map(|l| lpa(&l)).unwrap_or(LengthPercentageAuto::length(0.0)),
        right: side("margin", "right").map(|l| lpa(&l)).unwrap_or(LengthPercentageAuto::length(0.0)),
        top: side("margin", "top").map(|l| lpa(&l)).unwrap_or(LengthPercentageAuto::length(0.0)),
        bottom: side("margin", "bottom").map(|l| lpa(&l)).unwrap_or(LengthPercentageAuto::length(0.0)),
    };
    let pad = |name: &str| side("padding", name).map(|l| lp(&l)).unwrap_or(LengthPercentage::length(0.0));
    style.padding = taffy::Rect { left: pad("left"), right: pad("right"), top: pad("top"), bottom: pad("bottom") };
    style.border = taffy::Rect {
        left: LengthPercentage::length(border_width(c, "left")),
        right: LengthPercentage::length(border_width(c, "right")),
        top: LengthPercentage::length(border_width(c, "top")),
        bottom: LengthPercentage::length(border_width(c, "bottom")),
    };
    let overflow = |value: Option<&str>| match value.unwrap_or("visible") {
        "hidden" => Overflow::Hidden,
        "clip" => Overflow::Clip,
        "scroll" | "auto" | "overlay" => Overflow::Scroll,
        _ => Overflow::Visible,
    };
    style.overflow = Point { x: overflow(c.get("overflow-x")), y: overflow(c.get("overflow-y")) };
    style.scrollbar_width = 0.0;
    // Flex.
    style.flex_direction = match c.get("flex-direction").unwrap_or("row") {
        "column" => FlexDirection::Column,
        "column-reverse" => FlexDirection::ColumnReverse,
        "row-reverse" => FlexDirection::RowReverse,
        _ => FlexDirection::Row,
    };
    style.flex_wrap = match c.get("flex-wrap").unwrap_or("nowrap") {
        "wrap" => FlexWrap::Wrap,
        "wrap-reverse" => FlexWrap::WrapReverse,
        _ => FlexWrap::NoWrap,
    };
    if display != "table-cell" {
        style.flex_grow = c.get("flex-grow").and_then(values::number).unwrap_or(0.0).max(0.0);
        style.flex_basis = match get("flex-basis") {
            Some(Length::Keyword(word)) if word == "content" => Dimension::auto(),
            Some(length) => dimension(&length),
            None => Dimension::auto(),
        };
    }
    style.flex_shrink = c.get("flex-shrink").and_then(values::number).unwrap_or(1.0).max(0.0);
    if let Some(align) = align_items(c.get("align-items")) {
        style.align_items = align;
    }
    style.align_self = align_items(c.get("align-self"));
    if let Some(justify) = align_items(c.get("justify-items")) {
        style.justify_items = justify;
    }
    style.justify_self = align_items(c.get("justify-self"));
    if let Some(align) = align_content(c.get("align-content")) {
        style.align_content = align;
    }
    if let Some(justify) = align_content(c.get("justify-content")) {
        style.justify_content = justify;
    }
    let gap = |name: &str| match c.get(name) {
        Some("normal") | None => LengthPercentage::length(0.0),
        Some(_) => get(name).map(|l| lp(&l)).unwrap_or(LengthPercentage::length(0.0)),
    };
    style.gap = Size { width: gap("column-gap"), height: gap("row-gap") };
    // Grid.
    if style.display == Display::Grid {
        if let Some((tracks, names)) = c.get("grid-template-columns").and_then(|v| grid_tracks(v, c)) {
            style.grid_template_columns = tracks;
            style.grid_template_column_names = names;
        }
        if let Some((tracks, names)) = c.get("grid-template-rows").and_then(|v| grid_tracks(v, c)) {
            style.grid_template_rows = tracks;
            style.grid_template_row_names = names;
        }
        if let Some(areas) = c.get("grid-template-areas").and_then(grid_areas) {
            style.grid_template_areas = Some(areas);
        }
        let auto = |name: &str| c.get(name).and_then(|value| plain_units(value, c).parse::<taffy::GridAutoTracks>().ok()).map(|tracks| tracks.0);
        if let Some(tracks) = auto("grid-auto-columns") {
            style.grid_auto_columns = tracks;
        }
        if let Some(tracks) = auto("grid-auto-rows") {
            style.grid_auto_rows = tracks;
        }
        if let Some(flow) = c.get("grid-auto-flow").and_then(|v| v.parse::<taffy::GridAutoFlow>().ok()) {
            style.grid_auto_flow = flow;
        }
    }
    style.grid_row = taffy::Line { start: placement(c.get("grid-row-start")), end: placement(c.get("grid-row-end")) };
    style.grid_column = taffy::Line { start: placement(c.get("grid-column-start")), end: placement(c.get("grid-column-end")) };
    if role == Role::Line {
        style.display = Display::Flex;
        line(&mut style, text_align);
    }
    style
}

/// A line of inline boxes, as a flex row that wraps: across as `text-align` says, centred up and down.
fn line(style: &mut Style, text_align: Option<&str>) {
    style.flex_direction = FlexDirection::Row;
    style.flex_wrap = FlexWrap::Wrap;
    style.align_items = AlignItems::CENTER;
    style.align_content = AlignContent::START;
    style.justify_content = match text_align.unwrap_or("start") {
        "center" | "-webkit-center" => AlignContent::CENTER,
        "right" | "end" | "-webkit-right" => AlignContent::END,
        _ => AlignContent::START,
    };
    style.gap = Size { width: LengthPercentage::length(0.0), height: LengthPercentage::length(0.0) };
}

#[cfg(test)]
pub(crate) mod tests_support {
    use super::*;
    pub struct Rough2;
    impl Measurer for Rough2 {
        fn measure(&mut self, _id: u64, content: &Content, width: Width) -> (f32, f32) {
            rough_measure(content, width)
        }
    }
    pub fn computed(css: &str) -> Computed {
        super::tests::computed(css)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::css::{Media, Sheet};

    struct Rough;
    impl Measurer for Rough {
        fn measure(&mut self, _id: u64, content: &Content, width: Width) -> (f32, f32) {
            rough_measure(content, width)
        }
    }

    pub(crate) fn computed(css: &str) -> Computed {
        // A one-rule sheet over a lone element (`.x`).
        #[derive(Clone, Copy)]
        struct One;
        impl<'a> crate::css::Elem<'a> for One {
            fn tag(self) -> &'a str {
                "div"
            }
            fn attr(self, name: &str) -> Option<&'a str> {
                (name == "class").then_some("x")
            }
            fn parent(self) -> Option<Self> {
                None
            }
            fn prev(self) -> Option<Self> {
                None
            }
            fn next(self) -> Option<Self> {
                None
            }
            fn first_child(self) -> Option<Self> {
                None
            }
            fn is_empty(self) -> bool {
                true
            }
            fn state(self, _: crate::css::State) -> bool {
                false
            }
            fn is(self, _: Self) -> bool {
                true
            }
        }
        let sheet = Sheet::of(&format!(".x {{ {css} }}"), Media::default());
        sheet.compute(One, &Computed::root(values::Ctx::default()), &[], None)
    }

    #[test]
    fn css_maps_to_taffy() {
        let c = computed("display: flex; flex-direction: column; gap: 8px 4px; padding: 1rem 2px; margin: 0 auto; width: calc(100% - 2rem); max-width: 30rem; position: relative; top: 4px; box-sizing: border-box; flex: 1; align-items: center; justify-content: space-between; border: 2px solid red; overflow: hidden auto;");
        let s = style(&c, Role::Element, None);
        assert_eq!(s.display, Display::Flex);
        assert_eq!(s.flex_direction, FlexDirection::Column);
        assert_eq!(s.gap.height, LengthPercentage::length(8.0));
        assert_eq!(s.gap.width, LengthPercentage::length(4.0));
        assert_eq!(s.padding.top, LengthPercentage::length(16.0));
        assert_eq!(s.margin.left, LengthPercentageAuto::auto());
        assert_eq!(s.max_size.width, LengthPercentageAuto::length(480.0));
        assert_eq!(s.position, Position::Relative);
        assert_eq!(s.inset.top, LengthPercentageAuto::length(4.0));
        assert_eq!(s.box_sizing, BoxSizing::BorderBox);
        assert_eq!(s.flex_grow, 1.0);
        assert_eq!(s.flex_basis, Dimension::percent(0.0));
        assert_eq!(s.align_items, AlignItems::CENTER);
        assert_eq!(s.justify_content, AlignContent::SPACE_BETWEEN);
        assert_eq!(s.border.left, LengthPercentage::length(2.0));
        assert_eq!(s.overflow, Point { x: Overflow::Hidden, y: Overflow::Scroll });
        let g = style(&computed("display: grid; grid-template-columns: repeat(auto-fill, minmax(12rem, 1fr)); grid-template-areas: 'a a' 'b c'; grid-area: b;"), Role::Element, None);
        assert_eq!(g.display, Display::Grid);
        assert_eq!(g.grid_template_columns.len(), 1);
        assert!(g.grid_template_columns[0].is_auto_repetition());
        let two = style(&computed("display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)) [end];"), Role::Element, None);
        assert_eq!(two.grid_template_columns.len(), 1, "minmax(0, …): a bare 0 read");
        let areas = g.grid_template_areas.as_ref().expect("areas");
        assert_eq!((areas.row_count, areas.column_count), (2, 2));
        assert_eq!(areas.areas[0].column_end, 3);
    }

    fn frames(tree: &Tree, ids: &[u64]) -> Vec<[f32; 4]> {
        ids.iter().map(|id| tree.frame(*id).unwrap().0).collect()
    }

    #[test]
    fn block_flex_grid_and_absolute() {
        let mut tree = Tree::default();
        let root_style = style(&computed("display: block; padding: 10px; position: relative;"), Role::Element, None);
        let row = style(&computed("display: flex; gap: 10px;"), Role::Element, None);
        let item = style(&computed("flex: 1; height: 20px;"), Role::Element, None);
        let grid = style(&computed("display: grid; grid-template-columns: 1fr 2fr; gap: 6px;"), Role::Element, None);
        let cell = style(&computed("height: 10px;"), Role::Element, None);
        let badge = style(&computed("position: absolute; top: 0; right: 0; width: 8px; height: 8px;"), Role::Element, None);
        let text = Content::Text { version: 1, chars: vec![5, 5, 5, 5], font_size: 16.0, line_height: 20.0, nowrap: false };
        let plain = style(&computed("display: block;"), Role::Element, None);
        let none = Content::None;
        let wants: Vec<(u64, Want)> = vec![
            (1, Want { style: &root_style, children: &[2, 5, 8, 9], content: &none }),
            (2, Want { style: &row, children: &[3, 4], content: &none }),
            (3, Want { style: &item, children: &[], content: &none }),
            (4, Want { style: &item, children: &[], content: &none }),
            (5, Want { style: &grid, children: &[6, 7], content: &none }),
            (6, Want { style: &cell, children: &[], content: &none }),
            (7, Want { style: &cell, children: &[], content: &none }),
            (8, Want { style: &badge, children: &[], content: &none }),
            (9, Want { style: &plain, children: &[], content: &text }),
        ];
        tree.sync(1, wants.into_iter());
        tree.compute(1, 200.0, 400.0, &mut Rough);
        let f = frames(&tree, &[1, 2, 3, 4, 5, 6, 7, 8, 9]);
        assert_eq!(f[0], [0.0, 0.0, 200.0, 20.0 + 20.0 + 10.0 + 40.0]);
        assert_eq!(f[1], [10.0, 10.0, 180.0, 20.0]);
        assert_eq!(f[2], [0.0, 0.0, 85.0, 20.0]);
        assert_eq!(f[3], [95.0, 0.0, 85.0, 20.0]);
        assert_eq!(f[5], [0.0, 0.0, 58.0, 10.0]);
        assert_eq!(f[6], [64.0, 0.0, 116.0, 10.0]);
        assert_eq!(f[7], [192.0, 0.0, 8.0, 8.0], "absolute: in its containing block, its top right corner");
        assert_eq!(f[8], [10.0, 40.0, 180.0, 40.0], "four five-letter words at 8 px a letter wrap onto two lines of 180");
    }

    #[test]
    fn a_field_and_its_button_share_a_wrapping_row() {
        let mut tree = Tree::default();
        let row = style(&computed("display: flex; flex-wrap: wrap; align-items: flex-end; gap: 12px; width: 372px;"), Role::Element, None);
        let grow = style(&computed("flex: 1 1 240px;"), Role::Element, None);
        let mut input = style(&computed("display: inline-block; box-sizing: border-box; padding: 10px 12px; border: 1.5px solid red; width: 100%;"), Role::Element, None);
        input.item_is_compressible_replaced = true;
        let button = style(&computed("display: inline-flex; padding: 0 18px; height: 40px;"), Role::Element, None);
        let label = style(&computed("display: block;"), Role::Element, None);
        let (field, none, text) = (Content::Fixed { width: 160.0, height: 17.0 }, Content::None, Content::Fixed { width: 70.0, height: 20.0 });
        let wants: Vec<(u64, Want)> = vec![
            (1, Want { style: &row, children: &[2, 4], content: &none }),
            (2, Want { style: &grow, children: &[3], content: &none }),
            (3, Want { style: &input, children: &[], content: &field }),
            (4, Want { style: &button, children: &[5], content: &none }),
            (5, Want { style: &label, children: &[], content: &text }),
        ];
        tree.sync(1, wants.into_iter());
        tree.compute(1, 412.0, 800.0, &mut Rough);
        assert_eq!(frames(&tree, &[2, 3, 4, 5]), vec![[0.0, 0.0, 254.0, 40.0], [0.0, 0.0, 254.0, 40.0], [266.0, 0.0, 106.0, 40.0], [18.0, 0.0, 70.0, 40.0]]);
    }

    #[test]
    fn a_flex_item_that_holds_a_long_text_fits_its_room() {
        let mut tree = Tree::default();
        let column = style(&computed("display: flex; flex-direction: column; align-items: flex-start; width: 372px;"), Role::Element, None);
        let alert = style(&computed("display: flex; gap: 8px; padding: 10px 12px;"), Role::Element, None);
        let icon = style(&computed("width: 19px; height: 19px; flex: none;"), Role::Element, None);
        let block = style(&computed("display: block;"), Role::Element, None);
        let text = Content::Text { version: 1, chars: vec![9, 5, 5, 4, 2, 4, 8, 4, 3, 2, 5], font_size: 16.0, line_height: 20.0, nowrap: false };
        let none = Content::None;
        let wants: Vec<(u64, Want)> = vec![
            (1, Want { style: &column, children: &[2], content: &none }),
            (2, Want { style: &alert, children: &[3, 4], content: &none }),
            (3, Want { style: &icon, children: &[], content: &none }),
            (4, Want { style: &block, children: &[], content: &text }),
        ];
        tree.sync(1, wants.into_iter());
        tree.compute(1, 412.0, 800.0, &mut Rough);
        let f = frames(&tree, &[2, 4]);
        assert_eq!(f[0][2], 372.0, "no wider than the column");
        assert_eq!(f[1][2], 372.0 - 24.0 - 19.0 - 8.0, "its text wraps in what is left");
        assert_eq!(f[1][3], 40.0, "on two lines");
    }

    #[test]
    fn aspect_ratio_holds_for_grids_too() {
        let mut tree = Tree::default();
        let root = style(&computed("display: block; width: 180px;"), Role::Element, None);
        let grid = style(&computed("display: grid; aspect-ratio: 9 / 13; place-items: center;"), Role::Element, None);
        let block = style(&computed("display: block; aspect-ratio: 9 / 13;"), Role::Element, None);
        let play = style(&computed("width: 52px; height: 52px;"), Role::Element, None);
        let none = Content::None;
        let wants: Vec<(u64, Want)> = vec![
            (1, Want { style: &root, children: &[2, 4], content: &none }),
            (2, Want { style: &grid, children: &[3], content: &none }),
            (3, Want { style: &play, children: &[], content: &none }),
            (4, Want { style: &block, children: &[], content: &none }),
        ];
        tree.sync(1, wants.into_iter());
        tree.compute(1, 400.0, 800.0, &mut Rough);
        assert_eq!(frames(&tree, &[2, 3, 4]), vec![[0.0, 0.0, 180.0, 260.0], [64.0, 104.0, 52.0, 52.0], [0.0, 260.0, 180.0, 260.0]]);
    }
}
