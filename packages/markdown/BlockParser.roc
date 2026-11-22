import Block
import Chars
import Inline

## The first of Markdown's two passes: the document's blocks, line by line, as CommonMark has
## them. Each line goes through the containers that are open (block quotes, lists and their
## items), then may open new ones, and what is left goes to a paragraph, a code block, an HTML
## block or a table. A paragraph's text is kept as one `Text` until the second pass parses its
## inlines, once every reference definition (`[label]: /url`) is known. A footnote's definition
## (`[^label]: …`, GitHub's) is a container, as a list's item is: its lines after the first
## indented four columns (or a paragraph's lazy continuation), and it goes to `notes`, not to the
## document, which shows the notes last. Not exposed: `Md.parse`.
BlockParser := [].{
	Ref : { label : Str, url : Str, title : Str }

	## A footnote's definition: its label (lower case, as references match it) and its blocks.
	Note : { label : Str, blocks : List(Block) }

	## The blocks, their paragraphs' and headings' text not parsed yet, the references, and the
	## footnotes' definitions, in the order they were written.
	parse : Str -> { blocks : List(Block), refs : List(BlockParser.Ref), notes : List(BlockParser.Note) }
	parse = |source| {
		var $state = { stack: [{ kind: Document, children: [] }], leaf: NoLeaf, refs: [], notes: [], line: 0 }
		for line in lines_of(source) {
			$state = process_line({ ..$state, line: $state.line + 1 }, line)
		}
		done = close_all($state)
		children = match done.stack.first() {
			Ok(document) => document.children
			Err(_) => []
		}
		{ blocks: blocks_of(children), refs: done.refs, notes: done.notes }
	}

	## A reference definition at `i`: `[label]: destination "title"`, on its own lines.
	ref_def : List(U8), U64 -> Try({ ref : BlockParser.Ref, end : U64 }, [NoRef])
	ref_def = |bytes, i| {
		start = Chars.until(bytes, i, |b| b != ' ')
		if Chars.at(bytes, start) != '[' or start > i + 3 {
			return Err(NoRef)
		}
		var $j = start + 1
		var $closed = Bool.False
		while !$closed and $j < bytes.len() {
			b = Chars.at(bytes, $j)
			if b == '\\' and Chars.is_punct(Chars.at(bytes, $j + 1)) {
				$j = $j + 2
			} else if b == '[' {
				return Err(NoRef)
			} else if b == ']' {
				$closed = Bool.True
			} else {
				$j = $j + 1
			}
		}
		label = Chars.slice(bytes, start + 1, $j)
		if !$closed or Chars.at(bytes, $j + 1) != ':' or Chars.trim(label).is_empty() or $j - start > 1000 {
			return Err(NoRef)
		}
		target = Chars.space_line(bytes, $j + 2)
		found = Chars.destination(bytes, target).map_err(|_| NoRef)?
		# A title, on the same line or the next, then nothing else on its line.
		spaced = Chars.space_line(bytes, found.end)
		titled =
			if spaced > found.end {
				match Chars.title(bytes, spaced) {
					Ok(title) => {
						line_end = Chars.until(bytes, title.end, |b| !Chars.is_space_or_tab(b))
						if (line_end >= bytes.len() or Chars.at(bytes, line_end) == '\n') Ok({ title: title.title, end: line_end + 1 }) else Err(NoTitle)
					}
					Err(_) => Err(NoTitle)
				}
			} else {
				Err(NoTitle)
			}
		match titled {
			Ok(title) => Ok({ ref: { label: Chars.label_key(label), url: found.url, title: title.title }, end: title.end })
			Err(_) => {
				line_end = Chars.until(bytes, found.end, |b| !Chars.is_space_or_tab(b))
				if line_end >= bytes.len() or Chars.at(bytes, line_end) == '\n' {
					Ok({ ref: { label: Chars.label_key(label), url: found.url, title: "" }, end: line_end + 1 })
				} else {
					Err(NoRef)
				}
			}
		}
	}
}

## What is open: the document, a block quote, a list, or one of its items, and what it holds so far.
Kind : [Document, Quote, Listing({ ordered : Bool, mark : U8, start : U64 }), Item({ width : U64, line : U64 }), Note(Str)]

Open : { kind : Kind, children : List(Child) }

## A container's finished part: a block; a blank line, which says whether a list is loose; a list,
## and whether it ended with a blank line; or a list's item.
Child := [Done(Block), Blank, Nested(Block, Bool), ItemDone(List(Child))]

## The block lines are going to, at the top: the one being built, if any.
Leaf : [
	NoLeaf,
	Para(List(Str)),
	Fenced({ mark : U8, len : U64, indent : U64, info : Str, lines : List(Str) }),
	Indented(List(Str)),
	HtmlLeaf({ end : [Contains(List(Str)), BlankLine], lines : List(Str) }),
	TableLeaf({ align : List([Default, Left, Center, Right]), head : List(Str), rows : List(List(Str)) }),
]

State : { stack : List(Open), leaf : Leaf, refs : List(BlockParser.Ref), notes : List(BlockParser.Note), line : U64 }

## A line, as far as the containers have read it: the byte at `pos` is at column `col` (a tab goes to
## the next multiple of 4), and when `partial`, the tab there is partly read.
Cursor : { bytes : List(U8), pos : U64, col : U64, partial : Bool }

## A block that may start on a line.
Start : [
	IndentedCode,
	QuoteStart,
	Atx(U64, Str),
	FenceStart({ mark : U8, len : U64, info : Str }),
	HtmlStart([Contains(List(Str)), BlankLine]),
	Setext(U64),
	TableStart(List([Default, Left, Center, Right])),
	RuleStart,
	ItemStart({ ordered : Bool, mark : U8, start : U64, width : U64, advance : U64 }),
	NoteStart({ label : Str, width : U64 }),
	NoStart,
]

## The source's lines, without their endings (`\n`, `\r\n` or `\r`). A NUL is U+FFFD.
lines_of : Str -> List(List(U8))
lines_of = |source| {
	raw = source.to_utf8()
	bytes = if (raw.contains(0)) raw.join_map(|b| if (b == 0) [0xEF, 0xBF, 0xBD] else [b]) else raw
	var $lines = []
	var $start = 0
	var $i = 0
	while $i < bytes.len() {
		b = Chars.at(bytes, $i)
		if b == '\n' or b == '\r' {
			$lines = $lines.append(bytes.sublist({ start: $start, len: $i - $start }))
			$i = if (b == '\r' and Chars.at(bytes, $i + 1) == '\n') $i + 2 else $i + 1
			$start = $i
		} else {
			$i = $i + 1
		}
	}
	if ($start < bytes.len()) $lines.append(bytes.sublist({ start: $start, len: bytes.len() - $start })) else $lines
}

process_line : State, List(U8) -> State
process_line = |state, bytes| {
	matched = match_containers(state, { bytes, pos: 0, col: 0, partial: Bool.False })
	if matched.count == state.stack.len() {
		match continue_leaf(state, matched.cur) {
			Consumed(done) => done
			Next(next) => starts(next, matched.cur, matched.count)
		}
	} else {
		starts(state, matched.cur, matched.count)
	}
}

## How many of the open containers the line continues (the document always), and the cursor past
## their markers: a block quote's `>`, a list item's indentation.
match_containers : State, Cursor -> { count : U64, cur : Cursor }
match_containers = |state, start| {
	var $cur = start
	var $count = 1
	var $going = Bool.True
	while $going and $count < state.stack.len() {
		ns = nonspace($cur)
		blank = Chars.blank_from($cur.bytes, ns.pos)
		kind = match state.stack.get($count) {
			Ok(open) => open.kind
			Err(_) => Document
		}
		next =
			match kind {
				Quote => if (ns.indent <= 3 and Chars.at($cur.bytes, ns.pos) == '>') Ok(after_quote_marker($cur, ns)) else Err(NoMatch)
				Item(item) =>
					if ns.indent >= item.width {
						Ok(advance_cols($cur, item.width))
					} else if blank and has_content(state, $count) {
						Ok(to_nonspace($cur, ns))
					} else {
						Err(NoMatch)
					}
				# A footnote holds its lines indented four columns, and blank lines.
				Note(_) =>
					if ns.indent >= 4 {
						Ok(advance_cols($cur, 4))
					} else if blank {
						Ok(to_nonspace($cur, ns))
					} else {
						Err(NoMatch)
					}
				_ => Ok($cur)
			}
		match next {
			Ok(cur) => {
				$cur = cur
				$count = $count + 1
			}
			Err(_) => {
				$going = Bool.False
			}
		}
	}
	{ count: $count, cur: $cur }
}

## Whether the item at `index` holds anything yet: a block, a container still open, or a leaf.
has_content : State, U64 -> Bool
has_content = |state, index| {
	children = match state.stack.get(index) {
		Ok(open) => open.children
		Err(_) => []
	}
	!children.is_empty() or index + 1 < state.stack.len() or !is_no_leaf(state.leaf)
}

## A line every container continued, given to a code block or an HTML block that takes it whole.
continue_leaf : State, Cursor -> [Consumed(State), Next(State)]
continue_leaf = |state, cur| {
	ns = nonspace(cur)
	blank = Chars.blank_from(cur.bytes, ns.pos)
	match state.leaf {
		Fenced(fence) =>
			if ns.indent <= 3 and closes_fence(cur.bytes, ns.pos, fence.mark, fence.len) {
				Consumed(close_leaf(state))
			} else {
				Consumed({ ..state, leaf: Fenced({ ..fence, lines: fence.lines.append(rest(advance_cols(cur, U64.min(ns.indent, fence.indent)))) }) })
			}
		Indented(lines) =>
			if ns.indent >= 4 {
				Consumed({ ..state, leaf: Indented(lines.append(rest(advance_cols(cur, 4)))) })
			} else if blank {
				Consumed({ ..state, leaf: Indented(lines.append(rest(advance_cols(cur, ns.indent)))) })
			} else {
				Next(state)
			}
		HtmlLeaf(html) =>
			if html.end == BlankLine and blank {
				Next(close_leaf(state))
			} else {
				line = rest(cur)
				next = { ..state, leaf: HtmlLeaf({ ..html, lines: html.lines.append(line) }) }
				Consumed(if (ends_html(html.end, line)) close_leaf(next) else next)
			}
		_ => Next(state)
	}
}

## New blocks starting on the line, as many as it opens (`> - # Hi` opens three), then the rest.
starts : State, Cursor, U64 -> State
starts = |state, cur, matched| {
	var $state = state
	var $cur = cur
	var $matched = matched
	var $opened = Bool.False
	var $going = Bool.True
	while $going {
		ns = nonspace($cur)
		match detect($state, $cur, $matched) {
			IndentedCode => return { ..make_room(close_unmatched($state, $matched)), leaf: Indented([rest(advance_cols($cur, 4))]) }
			QuoteStart => {
				$state = push(make_room(close_unmatched($state, $matched)), Quote)
				$cur = after_quote_marker($cur, ns)
				$matched = $state.stack.len()
				$opened = Bool.True
			}
			Atx(level, text) => return add_block(close_unmatched($state, $matched), Done(Heading({ level, id: "", content: [Text(text)] })))
			FenceStart(fence) => return { ..make_room(close_unmatched($state, $matched)), leaf: Fenced({ mark: fence.mark, len: fence.len, indent: ns.indent, info: fence.info, lines: [] }) }
			HtmlStart(end) => {
				line = rest($cur)
				opened = { ..make_room(close_unmatched($state, $matched)), leaf: HtmlLeaf({ end, lines: [line] }) }
				return if (ends_html(end, line)) close_leaf(opened) else opened
			}
			Setext(level) => {
				lines = match $state.leaf {
					Para(para) => para
					_ => []
				}
				found = paragraph(lines)
				cleared = { ..$state, leaf: NoLeaf, refs: $state.refs.concat(found.refs) }
				if !found.text.is_empty() {
					return append_child(cleared, Done(Heading({ level, id: "", content: [Text(found.text)] })))
				}
				# Only reference definitions: no paragraph to underline, so the line is something else.
				$state = cleared
			}
			TableStart(align) => {
				lines = match $state.leaf {
					Para(para) => para
					_ => []
				}
				head = cells(lines.last() ?? "")
				before = lines.drop_last(1)
				closed = if (before.is_empty()) { ..$state, leaf: NoLeaf } else close_leaf({ ..$state, leaf: Para(before) })
				return { ..closed, leaf: TableLeaf({ align, head, rows: [] }) }
			}
			RuleStart => return add_block(close_unmatched($state, $matched), Done(Rule))
			ItemStart(item) => {
				$state = push_item(close_unmatched($state, $matched), item)
				$cur = advance_cols($cur, item.advance)
				$matched = $state.stack.len()
				$opened = Bool.True
			}
			NoteStart(note) => {
				$state = push(make_room(close_unmatched($state, $matched)), Note(note.label))
				$cur = advance_cols(to_nonspace($cur, ns), note.width)
				$matched = $state.stack.len()
				$opened = Bool.True
			}
			NoStart => {
				$going = Bool.False
			}
		}
	}
	finish_line($state, $cur, $matched, $opened)
}

## Which block starts where the cursor is, if one does.
detect : State, Cursor, U64 -> Start
detect = |state, cur, matched| {
	ns = nonspace(cur)
	bytes = cur.bytes
	c = Chars.at(bytes, ns.pos)
	blank = Chars.blank_from(bytes, ns.pos)
	para = is_para(state.leaf)
	# A paragraph every container continued: what starts now interrupts it, which some blocks can't.
	interrupts = para and matched == state.stack.len()
	if ns.indent >= 4 {
		return if (!para and !blank) IndentedCode else NoStart
	}
	if c == '>' {
		return QuoteStart
	}
	match atx(bytes, ns.pos) {
		Ok(heading) => return Atx(heading.level, heading.text)
		Err(_) => {}
	}
	match fence_open(bytes, ns.pos) {
		Ok(fence) => return FenceStart(fence)
		Err(_) => {}
	}
	match html_start(bytes, ns.pos) {
		Ok(html) if !(html.kind == 7 and interrupts) => return HtmlStart(html.end)
		_ => {}
	}
	# A footnote's definition, `[^label]:`, which may interrupt a paragraph (a note written on the
	# line after the text that refers to it).
	match Chars.note_label(bytes, ns.pos) {
		Ok(found) if Chars.at(bytes, found.end) == ':' => return NoteStart({ label: found.label, width: found.end + 1 - ns.pos })
		_ => {}
	}
	if interrupts {
		match setext(bytes, ns.pos) {
			Ok(level) => return Setext(level)
			Err(_) => {}
		}
		match table_start(state.leaf, bytes, ns.pos) {
			Ok(align) => return TableStart(align)
			Err(_) => {}
		}
	}
	if thematic(bytes, ns.pos) {
		return RuleStart
	}
	match list_marker(cur, ns, interrupts) {
		Ok(item) => ItemStart(item)
		Err(_) => NoStart
	}
}

## What is left of the line once no more blocks start: a paragraph's next line (lazily, even
## when its containers didn't continue), a table's row, a blank line, or a new paragraph.
finish_line : State, Cursor, U64, Bool -> State
finish_line = |state, cur, matched, opened| {
	ns = nonspace(cur)
	blank = Chars.blank_from(cur.bytes, ns.pos)
	text = Chars.slice(cur.bytes, ns.pos, cur.bytes.len())
	if !blank and !opened and matched < state.stack.len() and is_para(state.leaf) {
		match state.leaf {
			Para(lines) => return { ..state, leaf: Para(lines.append(text)) }
			_ => {}
		}
	}
	closed = close_unmatched(state, matched)
	if blank {
		ended = match closed.leaf {
			Para(_) => close_leaf(closed)
			TableLeaf(_) => close_leaf(closed)
			_ => closed
		}
		blank_line(ended)
	} else {
		match closed.leaf {
			Para(lines) => { ..closed, leaf: Para(lines.append(text)) }
			TableLeaf(table) => { ..closed, leaf: TableLeaf({ ..table, rows: table.rows.append(cells(text)) }) }
			_ => { ..make_room(closed), leaf: Para([text]) }
		}
	}
}

## A blank line, noted where it falls: it makes a list loose. An item that started on this line
## with nothing in it notes none.
blank_line : State -> State
blank_line = |state|
	match state.stack.last() {
		Ok(top) =>
			match top.kind {
				Item(item) if item.line == state.line and top.children.is_empty() => state
				Listing(_) =>
					match top.children.last() {
						Ok(ItemDone(kids)) => {
							children = top.children.drop_last(1).append(ItemDone(kids.append(Blank)))
							{ ..state, stack: state.stack.drop_last(1).append({ ..top, children }) }
						}
						_ => state
					}
				_ => append_child(state, Blank)
			}
		Err(_) => state
	}

## The leaf closed, and any list at the top: what comes next isn't an item, so a list can't hold it.
make_room : State -> State
make_room = |state| {
	var $state = close_leaf(state)
	while is_listing($state) {
		$state = close_top($state)
	}
	$state
}

add_block : State, Child -> State
add_block = |state, child| append_child(make_room(state), child)

push : State, Kind -> State
push = |state, kind| { ..state, stack: state.stack.append({ kind, children: [] }) }

## A list item, in the list at the top if it is one of the same kind (`-` after `-`, `1.` after
## `1.`), or in a new list.
push_item : State, { ordered : Bool, mark : U8, start : U64, width : U64, advance : U64 } -> State
push_item = |state, item| {
	closed = close_leaf(state)
	same = match closed.stack.last() {
		Ok(top) =>
			match top.kind {
				Listing(list) => list.ordered == item.ordered and list.mark == item.mark
				_ => Bool.False
			}
		Err(_) => Bool.False
	}
	listed = if (same) closed else push(make_room(closed), Listing({ ordered: item.ordered, mark: item.mark, start: item.start }))
	push(listed, Item({ width: item.width, line: state.line }))
}

close_unmatched : State, U64 -> State
close_unmatched = |state, matched| {
	var $state = state
	while $state.stack.len() > matched and $state.stack.len() > 1 {
		$state = close_top($state)
	}
	$state
}

close_all : State -> State
close_all = |state| close_leaf(close_unmatched(state, 1))

## The container at the top closed, and given to the one below it.
close_top : State -> State
close_top = |state| {
	closed = close_leaf(state)
	match closed.stack.last() {
		Ok(top) => {
			below = { ..closed, stack: closed.stack.drop_last(1) }
			match top.kind {
				Quote => append_child(below, Done(Quote(blocks_of(top.children))))
				Item(_) => append_child(below, ItemDone(top.children))
				Listing(list) => append_child(below, listing(list, top.children))
				Note(label) => { ..below, notes: below.notes.append({ label, blocks: blocks_of(top.children) }) }
				Document => closed
			}
		}
		Err(_) => closed
	}
}

append_child : State, Child -> State
append_child = |state, child|
	match state.stack.last() {
		Ok(top) => { ..state, stack: state.stack.drop_last(1).append({ ..top, children: top.children.append(child) }) }
		Err(_) => state
	}

## The leaf at the top, finished and given to its container.
close_leaf : State -> State
close_leaf = |state| {
	cleared = { ..state, leaf: NoLeaf }
	match state.leaf {
		NoLeaf => state
		Para(lines) => {
			found = paragraph(lines)
			with_refs = { ..cleared, refs: cleared.refs.concat(found.refs) }
			if (found.text.is_empty()) with_refs else append_child(with_refs, Done(Paragraph([Text(found.text)])))
		}
		Fenced(fence) => {
			info = Chars.unescape(fence.info)
			lang = match info.split_first(" ") {
				Ok({ before, after: _ }) => before
				Err(_) => info
			}
			append_child(cleared, Done(Code({ lang: lang.split_on("\t").first() ?? lang, info, text: code_text(fence.lines) })))
		}
		Indented(lines) => {
			var $kept = lines
			while ($kept.last() ?? "x").trim().is_empty() and !$kept.is_empty() {
				$kept = $kept.drop_last(1)
			}
			append_child(cleared, Done(Code({ lang: "", info: "", text: code_text($kept) })))
		}
		HtmlLeaf(html) => append_child(cleared, Done(Raw(Str.join_with(html.lines, "\n"))))
		TableLeaf(table) => {
			count = table.align.len()
			fit = |row| {
				kept = row.take_first(count)
				kept.concat(List.repeat("", count - kept.len())).map(|cell| [Text(cell)])
			}
			append_child(cleared, Done(Table({ align: table.align, head: fit(table.head), rows: table.rows.map(fit) })))
		}
	}
}

code_text : List(Str) -> Str
code_text = |lines| if (lines.is_empty()) "" else Str.join_with(lines, "\n").concat("\n")

## A paragraph's lines: the reference definitions at its start, and its text after them.
paragraph : List(Str) -> { refs : List(BlockParser.Ref), text : Str }
paragraph = |lines| {
	bytes = Str.join_with(lines, "\n").to_utf8()
	var $i = 0
	var $refs = []
	var $going = Chars.at(bytes, 0) == '['
	while $going {
		match BlockParser.ref_def(bytes, $i) {
			Ok(found) => {
				$refs = $refs.append(found.ref)
				$i = found.end
			}
			Err(_) => {
				$going = Bool.False
			}
		}
	}
	{ refs: $refs, text: Chars.trim_end(Chars.slice(bytes, U64.min($i, bytes.len()), bytes.len())) }
}

## A list, finished: tight unless a blank line falls between its items or between two blocks of
## one; and whether it ends with a blank line, which may make the list it is in loose.
listing : { ordered : Bool, mark : U8, start : U64 }, List(Child) -> Child
listing = |list, children| {
	items = children.keep_oks(
		|child|
			match child {
				ItemDone(kids) => Ok(kids)
				_ => Err(NotItem)
			},
	)
	tight = is_tight(items)
	ends = match items.last() {
		Ok(kids) => ends_blank(kids)
		Err(_) => Bool.False
	}
	made = items.map(item_of)
	Nested(if (list.ordered) Ordered({ start: list.start, tight, items: made }) else Unordered({ tight, items: made }), ends)
}

ends_blank : List(Child) -> Bool
ends_blank = |kids|
	match kids.last() {
		Ok(Blank) => Bool.True
		Ok(Nested(_, ends)) => ends
		_ => Bool.False
	}

is_tight : List(List(Child)) -> Bool
is_tight = |items| {
	last = if (items.is_empty()) 0 else items.len() - 1
	var $k = 0
	for kids in items {
		more_items = $k < last
		if more_items and ends_blank_direct(kids) {
			return Bool.False
		}
		var $j = 0
		for child in kids {
			followed = kids.drop_first($j + 1).any(|kid| !is_blank(kid))
			blank_after = match kids.get($j + 1) {
				Ok(Blank) => Bool.True
				_ => Bool.False
			}
			ends = match child {
				Blank => Bool.False
				Nested(_, nested_ends) => blank_after or nested_ends
				_ => blank_after
			}
			if (more_items or followed) and ends {
				return Bool.False
			}
			$j = $j + 1
		}
		$k = $k + 1
	}
	Bool.True
}

ends_blank_direct : List(Child) -> Bool
ends_blank_direct = |kids|
	match kids.last() {
		Ok(Blank) => Bool.True
		_ => Bool.False
	}

is_blank : Child -> Bool
is_blank = |child|
	match child {
		Blank => Bool.True
		_ => Bool.False
	}

## An item's blocks, and its box: a paragraph starting `[ ] ` or `[x] ` makes it a task.
item_of : List(Child) -> Block.Item
item_of = |kids| {
	blocks = blocks_of(kids)
	match blocks {
		[Paragraph([Text(text)]), .. as others] =>
			match task(text) {
				Ok((box, after)) => { task: box, blocks: if (after.is_empty()) others else [Paragraph([Text(after)])].concat(others) }
				Err(_) => { task: None, blocks }
			}
		_ => { task: None, blocks }
	}
}

task : Str -> Try(([None, Open, Done], Str), [NotTask])
task = |text| {
	bytes = text.to_utf8()
	mark = Chars.at(bytes, 1)
	if Chars.at(bytes, 0) == '[' and Chars.at(bytes, 2) == ']' and (mark == ' ' or mark == 'x' or mark == 'X') and Chars.is_whitespace(Chars.at(bytes, 3)) {
		Ok((if (mark == ' ') Open else Done, Chars.slice(bytes, Chars.until(bytes, 3, |b| !Chars.is_whitespace(b)), bytes.len())))
	} else {
		Err(NotTask)
	}
}

blocks_of : List(Child) -> List(Block)
blocks_of = |children|
	children.keep_oks(
		|child|
			match child {
				Done(block) => Ok(block)
				Nested(block, _) => Ok(block)
				_ => Err(NotBlock)
			},
	)

is_para : Leaf -> Bool
is_para = |leaf|
	match leaf {
		Para(_) => Bool.True
		_ => Bool.False
	}

is_no_leaf : Leaf -> Bool
is_no_leaf = |leaf|
	match leaf {
		NoLeaf => Bool.True
		_ => Bool.False
	}

is_listing : State -> Bool
is_listing = |state|
	match state.stack.last() {
		Ok(top) =>
			match top.kind {
				Listing(_) => Bool.True
				_ => Bool.False
			}
		Err(_) => Bool.False
	}

# The cursor.

## Where the first character that isn't a space or a tab is, and how many columns away.
nonspace : Cursor -> { pos : U64, col : U64, indent : U64 }
nonspace = |cur| {
	var $pos = cur.pos
	var $col = cur.col
	var $going = Bool.True
	while $going {
		b = Chars.at(cur.bytes, $pos)
		if b == ' ' {
			$pos = $pos + 1
			$col = $col + 1
		} else if b == '\t' {
			$pos = $pos + 1
			$col = $col + (4 - $col % 4)
		} else {
			$going = Bool.False
		}
	}
	{ pos: $pos, col: $col, indent: $col - cur.col }
}

to_nonspace : Cursor, { pos : U64, col : U64, indent : U64 } -> Cursor
to_nonspace = |cur, ns| { ..cur, pos: ns.pos, col: ns.col, partial: Bool.False }

## The cursor `count` columns on; a tab it stops inside is partly read.
advance_cols : Cursor, U64 -> Cursor
advance_cols = |cur, count| {
	var $cur = cur
	var $left = count
	while $left > 0 and $cur.pos < $cur.bytes.len() {
		if Chars.at($cur.bytes, $cur.pos) == '\t' {
			width = 4 - $cur.col % 4
			if width > $left {
				$cur = { ..$cur, col: $cur.col + $left, partial: Bool.True }
				$left = 0
			} else {
				$cur = { ..$cur, col: $cur.col + width, pos: $cur.pos + 1, partial: Bool.False }
				$left = $left - width
			}
		} else {
			$cur = { ..$cur, col: $cur.col + 1, pos: $cur.pos + 1, partial: Bool.False }
			$left = $left - 1
		}
	}
	$cur
}

## Past a block quote's `>` and the one space (or column of a tab) after it.
after_quote_marker : Cursor, { pos : U64, col : U64, indent : U64 } -> Cursor
after_quote_marker = |cur, ns| {
	past = advance_cols(to_nonspace(cur, ns), 1)
	if (Chars.is_space_or_tab(Chars.at(past.bytes, past.pos))) advance_cols(past, 1) else past
}

## The rest of the line, a partly read tab as the spaces left of it.
rest : Cursor -> Str
rest = |cur|
	if cur.partial {
		Str.repeat(" ", 4 - cur.col % 4).concat(Chars.slice(cur.bytes, cur.pos + 1, cur.bytes.len()))
	} else {
		Chars.slice(cur.bytes, cur.pos, cur.bytes.len())
	}

# The blocks a line can start.

## `# Title`: up to six `#`, then a space; a closing run of `#` goes.
atx : List(U8), U64 -> Try({ level : U64, text : Str }, [NoHeading])
atx = |bytes, pos| {
	after = Chars.until(bytes, pos, |b| b != '#')
	level = after - pos
	if level < 1 or level > 6 or !(after >= bytes.len() or Chars.is_space_or_tab(Chars.at(bytes, after))) {
		return Err(NoHeading)
	}
	content = Chars.trim(Chars.slice(bytes, after, bytes.len())).to_utf8()
	var $end = content.len()
	while $end > 0 and Chars.at(content, $end - 1) == '#' {
		$end = $end - 1
	}
	text =
		if $end == 0 {
			""
		} else if Chars.is_space_or_tab(Chars.at(content, $end - 1)) {
			Chars.trim(Chars.slice(content, 0, $end))
		} else {
			Str.from_utf8_lossy(content)
		}
	Ok({ level, text })
}

## ```` ``` ```` or `~~~` (three or more), and an info string; a backtick fence's has no backtick.
fence_open : List(U8), U64 -> Try({ mark : U8, len : U64, info : Str }, [NoFence])
fence_open = |bytes, pos| {
	mark = Chars.at(bytes, pos)
	if mark != '`' and mark != '~' {
		return Err(NoFence)
	}
	end = Chars.until(bytes, pos, |b| b != mark)
	info = Chars.trim(Chars.slice(bytes, end, bytes.len()))
	if end - pos < 3 or (mark == '`' and info.contains("`")) {
		Err(NoFence)
	} else {
		Ok({ mark, len: end - pos, info })
	}
}

closes_fence : List(U8), U64, U8, U64 -> Bool
closes_fence = |bytes, pos, mark, len| {
	end = Chars.until(bytes, pos, |b| b != mark)
	end - pos >= len and Chars.blank_from(bytes, end)
}

## `===` (a first-level heading) or `---` (a second) under a paragraph.
setext : List(U8), U64 -> Try(U64, [NoSetext])
setext = |bytes, pos| {
	mark = Chars.at(bytes, pos)
	if mark != '=' and mark != '-' {
		return Err(NoSetext)
	}
	if (Chars.blank_from(bytes, Chars.until(bytes, pos, |b| b != mark))) Ok(if (mark == '=') 1 else 2) else Err(NoSetext)
}

## Three or more `*`, `-` or `_`, spaces between them allowed.
thematic : List(U8), U64 -> Bool
thematic = |bytes, pos| {
	mark = Chars.at(bytes, pos)
	if mark != '*' and mark != '-' and mark != '_' {
		return Bool.False
	}
	var $count = 0
	var $i = pos
	while $i < bytes.len() {
		b = Chars.at(bytes, $i)
		if b == mark {
			$count = $count + 1
		} else if !Chars.is_whitespace(b) {
			return Bool.False
		}
		$i = $i + 1
	}
	$count >= 3
}

## `-`, `+` or `*`, or up to nine digits and `.` or `)`, then a space (or the line's end). The
## item's content starts after the spaces that follow (one, if there are five or more).
list_marker : Cursor, { pos : U64, col : U64, indent : U64 }, Bool -> Try({ ordered : Bool, mark : U8, start : U64, width : U64, advance : U64 }, [NoItem])
list_marker = |cur, ns, interrupts| {
	bytes = cur.bytes
	c = Chars.at(bytes, ns.pos)
	digits_end = Chars.until(bytes, ns.pos, |b| !Chars.is_digit(b))
	delimiter = Chars.at(bytes, digits_end)
	marked =
		if c == '-' or c == '+' or c == '*' {
			Ok({ ordered: Bool.False, mark: c, start: 0, end: ns.pos + 1 })
		} else if digits_end > ns.pos and digits_end - ns.pos <= 9 and (delimiter == '.' or delimiter == ')') {
			Ok({ ordered: Bool.True, mark: delimiter, start: U64.from_str(Chars.slice(bytes, ns.pos, digits_end)) ?? 0, end: digits_end + 1 })
		} else {
			Err(NoItem)
		}
	marker = marked?
	after = Chars.at(bytes, marker.end)
	if !(marker.end >= bytes.len() or Chars.is_space_or_tab(after)) {
		return Err(NoItem)
	}
	blank_after = Chars.blank_from(bytes, marker.end)
	if interrupts and (blank_after or (marker.ordered and marker.start != 1)) {
		return Err(NoItem)
	}
	marker_width = marker.end - ns.pos
	spaces = nonspace({ bytes, pos: marker.end, col: ns.col + marker_width, partial: Bool.False }).indent
	padding = if (blank_after or spaces >= 5 or spaces == 0) 1 else spaces
	taken = if (blank_after) U64.min(spaces, 1) else padding
	Ok({ ordered: marker.ordered, mark: marker.mark, start: marker.start, width: ns.indent + marker_width + padding, advance: ns.indent + marker_width + taken })
}

## An HTML block's start, its kind (1 to 7, as CommonMark numbers them), and what ends it.
html_start : List(U8), U64 -> Try({ kind : U64, end : [Contains(List(Str)), BlankLine] }, [NoHtml])
html_start = |bytes, pos| {
	if Chars.at(bytes, pos) != '<' {
		return Err(NoHtml)
	}
	closing = Chars.at(bytes, pos + 1) == '/'
	name_at = if (closing) pos + 2 else pos + 1
	name = Chars.tag_name(bytes, name_at)
	after = Chars.at(bytes, name_at + name.count_utf8_bytes())
	ends_name = Chars.is_whitespace(after) or after == '>' or name_at + name.count_utf8_bytes() >= bytes.len()
	if !closing and ends_name and ["script", "pre", "style", "textarea"].contains(name) {
		Ok({ kind: 1, end: Contains(["</script>", "</pre>", "</style>", "</textarea>"]) })
	} else if Chars.slice(bytes, pos, pos + 4) == "<!--" {
		Ok({ kind: 2, end: Contains(["-->"]) })
	} else if Chars.at(bytes, pos + 1) == '?' {
		Ok({ kind: 3, end: Contains(["?>"]) })
	} else if Chars.slice(bytes, pos, pos + 9) == "<![CDATA[" {
		Ok({ kind: 5, end: Contains(["]]>"]) })
	} else if Chars.at(bytes, pos + 1) == '!' and Chars.is_letter(Chars.at(bytes, pos + 2)) {
		Ok({ kind: 4, end: Contains([">"]) })
	} else if block_tags.contains(name) and (ends_name or (after == '/' and Chars.at(bytes, name_at + name.count_utf8_bytes() + 1) == '>')) {
		Ok({ kind: 6, end: BlankLine })
	} else {
		tag_end = if (closing) Chars.close_tag(bytes, pos) else Chars.open_tag(bytes, pos)
		match tag_end {
			Ok(end) if Chars.blank_from(bytes, end) and !["script", "pre", "style", "textarea"].contains(name) => Ok({ kind: 7, end: BlankLine })
			_ => Err(NoHtml)
		}
	}
}

ends_html : [Contains(List(Str)), BlankLine], Str -> Bool
ends_html = |end, line|
	match end {
		Contains(needles) => {
			lower = line.with_ascii_lowercased()
			needles.any(|needle| lower.contains(needle))
		}
		BlankLine => Bool.False
	}

block_tags : List(Str)
block_tags = ["address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul"]

## A table's delimiter row (`| --- | :-: |`) under a paragraph's last line with as many cells.
table_start : Leaf, List(U8), U64 -> Try(List([Default, Left, Center, Right]), [NoTable])
table_start = |leaf, bytes, pos| {
	head = match leaf {
		Para(lines) => lines.last() ?? ""
		_ => ""
	}
	row = Chars.trim(Chars.slice(bytes, pos, bytes.len()))
	if head.is_empty() or !row.contains("|") {
		return Err(NoTable)
	}
	parts = cells(row)
	align = parts.map_try(
		|cell| {
			cell_bytes = cell.to_utf8()
			left = cell.starts_with(":")
			right = cell.ends_with(":")
			inner = cell_bytes.drop_first(if (left) 1 else 0).drop_last(if (right) 1 else 0)
			if inner.is_empty() or !inner.all(|b| b == '-') {
				Err(NoTable)
			} else if left and right {
				Ok(Center)
			} else if left {
				Ok(Left)
			} else if right {
				Ok(Right)
			} else {
				Ok(Default)
			}
		},
	)?
	if (cells(head).len() == align.len()) Ok(align) else Err(NoTable)
}

## A table row's cells: split at each `|` that isn't escaped, the outer ones dropped, trimmed;
## `\|` in a cell is `|`.
cells : Str -> List(Str)
cells = |row| {
	bytes = Chars.trim(row).to_utf8()
	start = if (Chars.at(bytes, 0) == '|') 1 else 0
	var $parts = []
	var $from = start
	var $i = start
	while $i < bytes.len() {
		b = Chars.at(bytes, $i)
		if b == '\\' and Chars.at(bytes, $i + 1) == '|' {
			$i = $i + 2
		} else if b == '|' {
			$parts = $parts.append(Chars.slice(bytes, $from, $i))
			$from = $i + 1
			$i = $i + 1
		} else {
			$i = $i + 1
		}
	}
	last = Chars.slice(bytes, $from, bytes.len())
	all = if ($from < bytes.len() or (bytes.len() > 0 and Chars.at(bytes, bytes.len() - 1) != '|')) $parts.append(last) else $parts
	all.map(|cell| Chars.trim(cell).replace_each("\\|", "|"))
}

shape : List(Block) -> Str
shape = |blocks|
	Str.join_with(
		blocks.map(
			|block|
				match block {
					Paragraph(content) => "p(${Inline.plain(content)})"
					Heading(heading) => "h${heading.level.to_str()}(${Inline.plain(heading.content)})"
					Code(code) => "code[${code.lang}](${code.text})"
					Quote(inner) => "quote(${shape(inner)})"
					Unordered(list) => "ul${if (list.tight) "" else "!"}(${Str.join_with(list.items.map(item_shape), "|")})"
					Ordered(list) => "ol${list.start.to_str()}${if (list.tight) "" else "!"}(${Str.join_with(list.items.map(item_shape), "|")})"
					Table(table) => "table(${Str.join_with(table.head.map(Inline.plain), ",")};${Str.join_with(table.rows.map(|row| Str.join_with(row.map(Inline.plain), ",")), ";")})"
					Raw(html) => "html(${html})"
					Rule => "hr"
					Footnotes(notes) => "notes(${Str.join_with(notes.map(|note| shape(note.blocks)), "|")})"
				},
		),
		" ",
	)

item_shape : Block.Item -> Str
item_shape = |item| {
	box = match item.task {
		None => ""
		Open => "[ ]"
		Done => "[x]"
	}
	"${box}${shape(item.blocks)}"
}

blocks : Str -> Str
blocks = |source| shape(BlockParser.parse(source).blocks)

expect blocks("# Hi\n\nSome *text*\nmore\n\n---") == "h1(Hi) p(Some *text*\nmore) hr"
expect blocks("Title\n=====\n\nSub\n---") == "h1(Title) h2(Sub)"
expect blocks("```roc\nx = 1\n\n```\n    indented\n") == "code[roc](x = 1\n\n) code[](indented\n)"
expect blocks("> a\nlazy\n> > b") == "quote(p(a\nlazy) quote(p(b)))"
expect blocks("- a\n- b\n\n- c") == "ul!(p(a)|p(b)|p(c))"
expect blocks("1. a\n2. b\n   - c\n3) d") == "ol1(p(a)|p(b) ul(p(c))) ol3(p(d))"
expect blocks("- [ ] todo\n- [x] done\n- plain") == "ul([ ]p(todo)|[x]p(done)|p(plain))"
expect blocks("| a | b |\n|---|:-:|\n| 1 | 2 |\n| 3 |") == "table(a,b;1,2;3,)"
expect blocks("<div>\n*hi*\n</div>\n\nafter") == "html(<div>\n*hi*\n</div>) p(after)"
expect blocks("[a]: /url \"t\"\n\n[a]") == "p([a])"
expect BlockParser.parse("[a]: /url \"t\"\n[B]:\n  <x y>\n").refs == [{ label: "a", url: "/url", title: "t" }, { label: "b", url: "x y", title: "" }]
expect blocks("-\tfoo\n\n\tbar") == "ul!(p(foo) p(bar))"
expect blocks("- a\n  - b\n\n    c\n- d") == "ul(p(a) ul!(p(b) p(c))|p(d))"

notes : Str -> List(Str)
notes = |source| BlockParser.parse(source).notes.map(|note| "${note.label}:${shape(note.blocks)}")

expect blocks("Text[^a].\n\n[^a]: The note.") == "p(Text[^a].)"
expect notes("Text[^a].\n\n[^a]: The note.") == ["a:p(The note.)"]
expect notes("Text[^A].\n[^A]: Right after,\nlazily.\n\n    And a second paragraph.\n\nNot the note's.") == ["a:p(Right after,\nlazily.) p(And a second paragraph.)"]
expect blocks("Text[^A].\n[^A]: Right after,\nlazily.\n\n    And a second paragraph.\n\nNot the note's.") == "p(Text[^A].) p(Not the note's.)"
expect notes("[^1]: One.\n[^2]: Two.\n    - a list") == ["1:p(One.)", "2:p(Two.) ul(p(a list))"]
expect notes("[^no space]: x\n[^]: y\n[^x] no colon") == []
