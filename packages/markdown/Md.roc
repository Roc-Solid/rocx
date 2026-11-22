import Block
import BlockParser
import Chars
import Inline
import InlineParser

## Markdown: CommonMark, and GitHub's tables, strikethrough, task lists, bare links and footnotes.
## `Md.parse` makes a document a list of `Block`s, which an app can walk (`Md.headings` is a table of
## contents) and render: `Md.to_html` as HTML text, `<Markdown>` as the platform's `Html`.
##
## Safe by default: raw HTML in the source is shown as text, and a link or an image whose URL could
## run script (`javascript:`) points nowhere. A renderer can be told the source is trusted.
Md := [].{

	## How a renderer writes HTML: what it does with raw HTML in the source (`Escape`, shown as
	## text; `Drop`, left out; `Trusted`, written as it is, and URLs not checked either), and
	## whether headings get their `id`s.
	Options := { raw : [Escape, Drop, Trusted] ?? Escape, ids : Bool ?? Bool.False }

	## A document's blocks. Each heading's `id` comes from its text (`Md.slug`), numbered when an
	## earlier heading has it already (`intro`, `intro-1`). Footnotes (`[^salt]` in the text,
	## `[^salt]: …` on a line of its own) are numbered in the order the text first refers to them,
	## and their notes are the document's last block (`Footnotes`); a note nothing refers to is left
	## out, and a reference to no note is text, as GitHub has them.
	parse : Str -> List(Block)
	parse = |source| {
		found = BlockParser.parse(source)
		labels = found.notes.map(|note| note.label)
		inline = |block| inlines_of(block, found.refs, labels)
		done = numbered(found.blocks.map(inline), found.notes.map(|note| { label: note.label, blocks: note.blocks.map(inline) }))
		blocks = with_ids(done.blocks, []).blocks
		if (done.notes.is_empty()) blocks else blocks.append(Footnotes(done.notes))
	}

	## The document's footnotes, in order: what its `Footnotes` block holds (none without one).
	footnotes : List(Block) -> List(Block.Note)
	footnotes = |blocks|
		match blocks.last() {
			Ok(Footnotes(notes)) => notes
			_ => []
		}

	## A note's anchor on the page: `fn-salt`.
	footnote_id : Str -> Str
	footnote_id = |label| "fn-${label}"

	## A reference's anchor, which its note links back to: `fnref-salt`, and `fnref-salt-2` for the
	## second reference to the same note.
	footnote_ref_id : Str, U64 -> Str
	footnote_ref_id = |label, nth| if (nth <= 1) "fnref-${label}" else "fnref-${label}-${nth.to_str()}"

	## What is wrong with a source's footnotes, each a sentence: a reference to a note that isn't
	## there (which shows as text), a note given twice (the first is kept), and a note nothing refers
	## to (which isn't shown). For a build's or a test's checks of what writers write.
	footnote_problems : Str -> List(Str)
	footnote_problems = |source| {
		defined = BlockParser.parse(source).notes.map(|note| note.label)
		doc = Md.parse(source)
		used = Md.footnotes(doc).map(|note| note.label)
		missing = inline_lists(doc).join_map(text_runs).join_map(unresolved).map(|label| "[^${label}] refers to a note that isn't there")
		twice = defined.keep_if(|label| defined.count_if(|other| other == label) > 1).map(|label| "[^${label}] is given twice")
		unused = defined.drop_if(|label| used.contains(label)).map(|label| "[^${label}] is a note nothing refers to")
		missing.concat(twice).concat(unused).fold([], |kept, problem| if (kept.contains(problem)) kept else kept.append(problem))
	}

	## The document as HTML, CommonMark's way, raw HTML escaped.
	to_html : List(Block) -> Str
	to_html = |blocks| Md.to_html_with(blocks, {})

	## The document as HTML, as `options` say.
	to_html_with : List(Block), Md.Options -> Str
	to_html_with = |blocks, options| {
		chosen = { raw: options.raw, ids: options.ids }
		render_blocks("", blocks, chosen, Bool.False)
	}

	## The headings, in order, with their levels, ids and text: a table of contents.
	headings : List(Block) -> List({ level : U64, id : Str, text : Str })
	headings = |blocks|
		blocks.join_map(
			|block|
				match block {
					Heading(heading) => [{ level: heading.level, id: heading.id, text: Inline.plain(heading.content) }]
					Quote(inner) => Md.headings(inner)
					Unordered(list) => list.items.join_map(|item| Md.headings(item.blocks))
					Ordered(list) => list.items.join_map(|item| Md.headings(item.blocks))
					_ => []
				},
		)

	## An anchor's name from a heading's text, as GitHub makes it: lower case, punctuation gone,
	## spaces hyphens. `"Hello, World!"` is `"hello-world"`.
	slug : Str -> Str
	slug = |text| {
		kept = text.with_ascii_lowercased().to_utf8().keep_if(|b| Chars.is_alnum(b) or b == ' ' or b == '-' or b == '_' or b >= 0x80)
		Str.from_utf8_lossy(Chars.trim(Str.from_utf8_lossy(kept)).to_utf8().map(|b| if (b == ' ') '-' else b))
	}

	## How many words the document has, its code included.
	words : List(Block) -> U64
	words = |blocks| Block.plain(blocks).to_utf8().split_if(Chars.is_whitespace).count_if(|word| !word.is_empty())

	## Minutes to read it, at 200 words a minute, rounded up: at least 1 for any words at all.
	reading_minutes : List(Block) -> U64
	reading_minutes = |blocks| (Md.words(blocks) + 199) // 200

	## Whether a link may point at `url`: one relative to the page, or whose scheme is http,
	## https, mailto or tel, as the platform's `Html` has it. Tabs and line breaks, which browsers
	## ignore in a URL (`java\nscript:` runs), don't hide a scheme.
	safe_url : Str -> Bool
	safe_url = |url| {
		compact = Str.from_utf8_lossy(url.to_utf8().keep_if(|byte| byte > ' ')).with_ascii_lowercased()
		match compact.split_first(":") {
			Err(NotFound) => Bool.True
			Ok({ before, after: _ }) =>
				if before.contains("/") or before.contains("?") or before.contains("#") {
					Bool.True
				} else {
					["http", "https", "mailto", "tel"].contains(before)
				}
		}
	}

	## A URL as an `href` has it: characters a URL can't hold (a space, `ä`, `\`) percent-encoded,
	## `%20` left as it is.
	href : Str -> Str
	href = |url| {
		var $out = []
		for b in url.to_utf8() {
			$out =
				if Chars.is_alnum(b) or "-_.+!*'(),%#@?=;:/&$~".to_utf8().contains(b) {
					$out.append(b)
				} else {
					$out.concat(['%', hex(b // 16), hex(b % 16)])
				}
		}
		Str.from_utf8_lossy($out)
	}

	## Text as HTML: `&`, `<`, `>` and `"` as entities.
	escape : Str -> Str
	escape = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;")
}

hex : U8 -> U8
hex = |digit| if (digit < 10) '0' + digit else 'A' + digit - 10

## The second pass: each paragraph's, heading's and cell's text as inlines; `labels` are the
## footnotes' that are defined.
inlines_of : Block, List({ label : Str, url : Str, title : Str }), List(Str) -> Block
inlines_of = |block, refs, labels| {
	parse = |content|
		match content {
			[Text(raw)] => InlineParser.parse(raw, refs, labels)
			_ => content
		}
	item = |it| { ..it, blocks: it.blocks.map(|inner| inlines_of(inner, refs, labels)) }
	match block {
		Paragraph(content) => Paragraph(parse(content))
		Heading(heading) => Heading({ ..heading, content: parse(heading.content) })
		Quote(inner) => Quote(inner.map(|b| inlines_of(b, refs, labels)))
		Unordered(list) => Unordered({ ..list, items: list.items.map(item) })
		Ordered(list) => Ordered({ ..list, items: list.items.map(item) })
		Table(table) => Table({ ..table, head: table.head.map(parse), rows: table.rows.map(|row| row.map(parse)) })
		_ => block
	}
}

## The references numbered in the order the text first makes them (each with which reference to
## its note it is), and the notes they refer to, in that order, the first definition of a label
## kept. A note may refer to another: the notes are numbered after the text, in their order.
numbered : List(Block), List(BlockParser.Note) -> { blocks : List(Block), notes : List(Block.Note) }
numbered = |blocks, defs| {
	main = number_blocks(blocks, [])
	var $seen = main.seen
	var $notes = []
	var $i = 0
	while $i < $seen.len() {
		label = $seen.get($i).map_ok(|each| each.label) ?? ""
		given = defs.find_first(|def| def.label == label).map_ok(|def| def.blocks) ?? []
		inner = number_blocks(given, $seen)
		$seen = inner.seen
		$notes = $notes.append({ label, number: $i + 1, refs: 0, blocks: inner.blocks })
		$i = $i + 1
	}
	seen = $seen
	{ blocks: main.blocks, notes: $notes.map(|note| { ..note, refs: seen.find_first(|each| each.label == note.label).map_ok(|each| each.count) ?? 1 }) }
}

## The labels referred to so far, in order, each with how often.
Seen : List({ label : Str, count : U64 })

number_blocks : List(Block), Seen -> { blocks : List(Block), seen : Seen }
number_blocks = |blocks, seen|
	blocks.fold(
		{ blocks: [], seen },
		|so_far, block| {
			done = number_block(block, so_far.seen)
			{ blocks: so_far.blocks.append(done.block), seen: done.seen }
		},
	)

number_block : Block, Seen -> { block : Block, seen : Seen }
number_block = |block, seen| {
	items = |list_items|
		list_items.fold(
			{ items: [], seen },
			|so_far, it| {
				done = number_blocks(it.blocks, so_far.seen)
				{ items: so_far.items.append({ ..it, blocks: done.blocks }), seen: done.seen }
			},
		)
	cells = |row, start|
		row.fold(
			{ cells: [], seen: start },
			|so_far, content| {
				done = number_inlines(content, so_far.seen)
				{ cells: so_far.cells.append(done.inlines), seen: done.seen }
			},
		)
	match block {
		Paragraph(content) => {
			done = number_inlines(content, seen)
			{ block: Paragraph(done.inlines), seen: done.seen }
		}
		Heading(heading) => {
			done = number_inlines(heading.content, seen)
			{ block: Heading({ ..heading, content: done.inlines }), seen: done.seen }
		}
		Quote(inner) => {
			done = number_blocks(inner, seen)
			{ block: Quote(done.blocks), seen: done.seen }
		}
		Unordered(list) => {
			done = items(list.items)
			{ block: Unordered({ ..list, items: done.items }), seen: done.seen }
		}
		Ordered(list) => {
			done = items(list.items)
			{ block: Ordered({ ..list, items: done.items }), seen: done.seen }
		}
		Table(table) => {
			head = cells(table.head, seen)
			rows = table.rows.fold(
				{ rows: [], seen: head.seen },
				|so_far, row| {
					done = cells(row, so_far.seen)
					{ rows: so_far.rows.append(done.cells), seen: done.seen }
				},
			)
			{ block: Table({ ..table, head: head.cells, rows: rows.rows }), seen: rows.seen }
		}
		_ => { block, seen }
	}
}

number_inlines : List(Inline), Seen -> { inlines : List(Inline), seen : Seen }
number_inlines = |inlines, seen|
	inlines.fold(
		{ inlines: [], seen },
		|so_far, inline| {
			inner = |content, wrap| {
				done = number_inlines(content, so_far.seen)
				{ inlines: so_far.inlines.append(wrap(done.inlines)), seen: done.seen }
			}
			match inline {
				Footnote(note) =>
					match so_far.seen.find_first_index(|each| each.label == note.label) {
						Ok(index) => {
							count = (so_far.seen.get(index).map_ok(|each| each.count) ?? 0) + 1
							{ inlines: so_far.inlines.append(Footnote({ label: note.label, number: index + 1, nth: count })), seen: so_far.seen.set(index, { label: note.label, count }) ?? so_far.seen }
						}
						Err(_) => { inlines: so_far.inlines.append(Footnote({ label: note.label, number: so_far.seen.len() + 1, nth: 1 })), seen: so_far.seen.append({ label: note.label, count: 1 }) }
					}
				Emph(content) => inner(content, |done| Emph(done))
				Strong(content) => inner(content, |done| Strong(done))
				Strike(content) => inner(content, |done| Strike(done))
				Link(link) => inner(link.content, |done| Link({ ..link, content: done }))
				_ => { inlines: so_far.inlines.append(inline), seen: so_far.seen }
			}
		},
	)

## Every list of inlines in the blocks: paragraphs', headings' and cells'.
inline_lists : List(Block) -> List(List(Inline))
inline_lists = |blocks|
	blocks.join_map(
		|block|
			match block {
				Paragraph(content) => [content]
				Heading(heading) => [heading.content]
				Quote(inner) => inline_lists(inner)
				Unordered(list) => list.items.join_map(|it| inline_lists(it.blocks))
				Ordered(list) => list.items.join_map(|it| inline_lists(it.blocks))
				Table(table) => table.head.concat(table.rows.join())
				Footnotes(notes) => notes.join_map(|note| inline_lists(note.blocks))
				_ => []
			},
	)

## The text of each run of `Text` side by side (what the inline pass left as text), nested ones too.
text_runs : List(Inline) -> List(Str)
text_runs = |inlines| {
	folded = inlines.fold(
		{ runs: [], current: "" },
		|so_far, inline| {
			ended = if (so_far.current.is_empty()) so_far.runs else so_far.runs.append(so_far.current)
			match inline {
				Text(text) => { ..so_far, current: so_far.current.concat(text) }
				Emph(content) | Strong(content) | Strike(content) => { runs: ended.concat(text_runs(content)), current: "" }
				Link(link) => { runs: ended.concat(text_runs(link.content)), current: "" }
				_ => { runs: ended, current: "" }
			}
		},
	)
	if (folded.current.is_empty()) folded.runs else folded.runs.append(folded.current)
}

## The labels of the `[^label]`s in a text: references the inline pass left as text, to no note.
unresolved : Str -> List(Str)
unresolved = |text| {
	bytes = text.to_utf8()
	var $found = []
	var $i = 0
	while $i < bytes.len() {
		match Chars.note_label(bytes, $i) {
			Ok(note) => {
				$found = $found.append(note.label)
				$i = note.end
			}
			Err(_) => {
				$i = $i + 1
			}
		}
	}
	$found
}

## Each heading's id, unique in the document: its slug, or the slug numbered.
with_ids : List(Block), List(Str) -> { blocks : List(Block), seen : List(Str) }
with_ids = |blocks, seen|
	blocks.fold(
		{ blocks: [], seen },
		|state, block| {
			done = with_id(block, state.seen)
			{ blocks: state.blocks.append(done.block), seen: done.seen }
		},
	)

with_id : Block, List(Str) -> { block : Block, seen : List(Str) }
with_id = |block, seen| {
	items = |list_items|
		list_items.fold(
			{ items: [], seen },
			|state, it| {
				done = with_ids(it.blocks, state.seen)
				{ items: state.items.append({ ..it, blocks: done.blocks }), seen: done.seen }
			},
		)
	match block {
		Heading(heading) => {
			base = Md.slug(Inline.plain(heading.content))
			named = if (base.is_empty()) "section" else base
			var $id = named
			var $n = 1
			while seen.contains($id) {
				$id = "${named}-${U64.to_str($n)}"
				$n = $n + 1
			}
			{ block: Heading({ ..heading, id: $id }), seen: seen.append($id) }
		}
		Quote(inner) => {
			done = with_ids(inner, seen)
			{ block: Quote(done.blocks), seen: done.seen }
		}
		Unordered(list) => {
			done = items(list.items)
			{ block: Unordered({ ..list, items: done.items }), seen: done.seen }
		}
		Ordered(list) => {
			done = items(list.items)
			{ block: Ordered({ ..list, items: done.items }), seen: done.seen }
		}
		_ => { block, seen }
	}
}

Chosen : { raw : [Escape, Drop, Trusted], ids : Bool }

## A line ending, unless the output is empty or ends with one.
cr : Str -> Str
cr = |out| if (out.is_empty() or out.ends_with("\n")) out else out.concat("\n")

render_blocks : Str, List(Block), Chosen, Bool -> Str
render_blocks = |start, blocks, options, tight| blocks.fold(start, |out, block| render_block(out, block, options, tight))

render_block : Str, Block, Chosen, Bool -> Str
render_block = |out, block, options, tight|
	match block {
		Paragraph(content) => if (tight) out.concat(render_inlines(content, options)) else "${cr(out)}<p>${render_inlines(content, options)}</p>\n"
		Heading(heading) => {
			level = heading.level.to_str()
			id = if (options.ids and !heading.id.is_empty()) " id=\"${Md.escape(heading.id)}\"" else ""
			"${cr(out)}<h${level}${id}>${render_inlines(heading.content, options)}</h${level}>\n"
		}
		Code(code) => {
			class = if (code.lang.is_empty()) "" else " class=\"language-${Md.escape(code.lang)}\""
			"${cr(out)}<pre><code${class}>${Md.escape(code.text)}</code></pre>\n"
		}
		Quote(inner) => "${cr(render_blocks("${cr(out)}<blockquote>\n", inner, options, Bool.False))}</blockquote>\n"
		Unordered(list) => "${render_items("${cr(out)}<ul>\n", list.items, options, list.tight)}</ul>\n"
		Ordered(list) => {
			start = if (list.start == 1) "" else " start=\"${list.start.to_str()}\""
			"${render_items("${cr(out)}<ol${start}>\n", list.items, options, list.tight)}</ol>\n"
		}
		Table(table) => {
			cell = |tag, align, content| {
				aligned = match align {
					Left => " align=\"left\""
					Center => " align=\"center\""
					Right => " align=\"right\""
					Default => ""
				}
				"<${tag}${aligned}>${render_inlines(content, options)}</${tag}>\n"
			}
			row = |tag, cells| "<tr>\n${Str.join_with(cells.map_with_index(|content, i| cell(tag, table.align.get(i) ?? Default, content)), "")}</tr>\n"
			body = if (table.rows.is_empty()) "" else "<tbody>\n${Str.join_with(table.rows.map(|cells| row("td", cells)), "")}</tbody>\n"
			"${cr(out)}<table>\n<thead>\n${row("th", table.head)}</thead>\n${body}</table>\n"
		}
		Raw(html) =>
			match options.raw {
				Trusted => "${cr(out)}${html}\n"
				Escape => "${cr(out)}<p>${Md.escape(html)}</p>\n"
				Drop => out
			}
		Rule => "${cr(out)}<hr />\n"
		Footnotes(notes) => {
			items = notes.map(
				|note| {
					backs = Str.join_with(List.repeat(0, note.refs).map_with_index(|_, i| backref(note, i + 1)), " ")
					inside =
						match note.blocks.last() {
							Ok(Paragraph(content)) => "${cr(render_blocks("", note.blocks.drop_last(1), options, Bool.False))}<p>${render_inlines(content, options)} ${backs}</p>\n"
							_ => "${cr(render_blocks("", note.blocks, options, Bool.False))}<p>${backs}</p>\n"
						}
					"<li id=\"${Md.escape(Md.footnote_id(note.label))}\">\n${inside.drop_prefix("\n")}</li>\n"
				},
			)
			"${cr(out)}<section class=\"footnotes\" data-footnotes>\n<ol>\n${Str.join_with(items, "")}</ol>\n</section>\n"
		}
	}

## The link from a note back to its `nth` reference, as cmark-gfm writes it.
backref : Block.Note, U64 -> Str
backref = |note, nth| {
	idx = if (nth <= 1) note.number.to_str() else "${note.number.to_str()}-${nth.to_str()}"
	mark = if (nth <= 1) "↩" else "↩<sup class=\"footnote-ref\">${nth.to_str()}</sup>"
	"<a href=\"#${Md.escape(Md.footnote_ref_id(note.label, nth))}\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"${idx}\" aria-label=\"Back to reference ${idx}\">${mark}</a>"
}

render_items : Str, List(Block.Item), Chosen, Bool -> Str
render_items = |start, items, options, tight|
	items.fold(
		start,
		|out, item| {
			box = match item.task {
				None => ""
				Open => "<input disabled=\"\" type=\"checkbox\"> "
				Done => "<input checked=\"\" disabled=\"\" type=\"checkbox\"> "
			}
			"${render_blocks("${cr(out)}<li>${box}", item.blocks, options, tight)}</li>\n"
		},
	)

render_inlines : List(Inline), Chosen -> Str
render_inlines = |inlines, options|
	inlines.fold(
		"",
		|out, inline|
			out.concat(
				match inline {
					Text(content) => Md.escape(content)
					Code(code) => "<code>${Md.escape(code)}</code>"
					Emph(inner) => "<em>${render_inlines(inner, options)}</em>"
					Strong(inner) => "<strong>${render_inlines(inner, options)}</strong>"
					Strike(inner) => "<del>${render_inlines(inner, options)}</del>"
					Link(link) => {
						title = if (link.title.is_empty()) "" else " title=\"${Md.escape(link.title)}\""
						"<a href=\"${url_attr(link.url, options)}\"${title}>${render_inlines(link.content, options)}</a>"
					}
					Image(image) => {
						title = if (image.title.is_empty()) "" else " title=\"${Md.escape(image.title)}\""
						"<img src=\"${url_attr(image.url, options)}\" alt=\"${Md.escape(image.alt)}\"${title} />"
					}
					Raw(html) =>
						match options.raw {
							Trusted => html
							Escape => Md.escape(html)
							Drop => ""
						}
					Footnote(note) => "<sup class=\"footnote-ref\"><a href=\"#${Md.escape(Md.footnote_id(note.label))}\" id=\"${Md.escape(Md.footnote_ref_id(note.label, note.nth))}\" data-footnote-ref>${note.number.to_str()}</a></sup>"
					Break => "<br />\n"
					SoftBreak => "\n"
				},
			),
	)

url_attr : Str, Chosen -> Str
url_attr = |url, options|
	if options.raw != Trusted and !Md.safe_url(url) {
		unsafe_url
	} else {
		Md.href(url).replace_each("&", "&amp;").replace_each("'", "&#x27;")
	}

## Where a link whose URL could run script points instead, as the platform's `Html` has it.
unsafe_url : Str
unsafe_url = "about:invalid#rocx-unsafe-url"

html : Str -> Str
html = |source| Md.to_html(Md.parse(source))

expect html("# Hello *world*\n\nA [link](https://example.com \"Ex\") and `code`.") == "<h1>Hello <em>world</em></h1>\n<p>A <a href=\"https://example.com\" title=\"Ex\">link</a> and <code>code</code>.</p>\n"
expect html("- a\n- b\n\n1. x\n\n2. y") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<ol>\n<li>\n<p>x</p>\n</li>\n<li>\n<p>y</p>\n</li>\n</ol>\n"
expect html("<b>hi</b> there\n\n<div>\nblock\n</div>") == "<p>&lt;b&gt;hi&lt;/b&gt; there</p>\n<p>&lt;div&gt;\nblock\n&lt;/div&gt;</p>\n"
expect Md.to_html_with(Md.parse("<b>hi</b>\n\n<div>x</div>"), { raw: Drop }) == "<p>hi</p>\n"
expect Md.to_html_with(Md.parse("<b>hi</b>"), { raw: Trusted }) == "<p><b>hi</b></p>\n"
expect html("[x](javascript:alert(1)) [y](<JAVA\tSCRIPT:z>) ![i](data:x) [ok](/a?b=1&c=2)") == "<p><a href=\"about:invalid#rocx-unsafe-url\">x</a> <a href=\"about:invalid#rocx-unsafe-url\">y</a> <img src=\"about:invalid#rocx-unsafe-url\" alt=\"i\" /> <a href=\"/a?b=1&amp;c=2\">ok</a></p>\n"
expect html("- [ ] a\n- [x] b") == "<ul>\n<li><input disabled=\"\" type=\"checkbox\"> a</li>\n<li><input checked=\"\" disabled=\"\" type=\"checkbox\"> b</li>\n</ul>\n"
expect html("| a | b |\n| :- | -: |\n| 1 | 2 |") == "<table>\n<thead>\n<tr>\n<th align=\"left\">a</th>\n<th align=\"right\">b</th>\n</tr>\n</thead>\n<tbody>\n<tr>\n<td align=\"left\">1</td>\n<td align=\"right\">2</td>\n</tr>\n</tbody>\n</table>\n"
expect Md.to_html_with(Md.parse("# Intro\n## Intro\n# Hello, World!"), { ids: Bool.True }) == "<h1 id=\"intro\">Intro</h1>\n<h2 id=\"intro-1\">Intro</h2>\n<h1 id=\"hello-world\">Hello, World!</h1>\n"
expect Md.headings(Md.parse("# A\n\n> ## B\n\n- ### C")) == [{ level: 1, id: "a", text: "A" }, { level: 2, id: "b", text: "B" }, { level: 3, id: "c", text: "C" }]
expect Md.slug("Hello, World! It's 2026") == "hello-world-its-2026"
expect Md.words(Md.parse("# Two words\n\nand *three more* here")) == 6
expect Md.reading_minutes(Md.parse("word")) == 1 and Md.reading_minutes([]) == 0
expect Md.href("a b/ä\\[x]") == "a%20b/%C3%A4%5C%5Bx%5D"
expect html("Bread[^salt] keeps[^time].\n\n[^time]: Two days.\n[^salt]: About *2%*.\n[^unused]: Never shown.") == "<p>Bread<sup class=\"footnote-ref\"><a href=\"#fn-salt\" id=\"fnref-salt\" data-footnote-ref>1</a></sup> keeps<sup class=\"footnote-ref\"><a href=\"#fn-time\" id=\"fnref-time\" data-footnote-ref>2</a></sup>.</p>\n<section class=\"footnotes\" data-footnotes>\n<ol>\n<li id=\"fn-salt\">\n<p>About <em>2%</em>. <a href=\"#fnref-salt\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a></p>\n</li>\n<li id=\"fn-time\">\n<p>Two days. <a href=\"#fnref-time\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"2\" aria-label=\"Back to reference 2\">↩</a></p>\n</li>\n</ol>\n</section>\n"
expect html("One[^a], two[^a].\n\n[^a]: Note.") == "<p>One<sup class=\"footnote-ref\"><a href=\"#fn-a\" id=\"fnref-a\" data-footnote-ref>1</a></sup>, two<sup class=\"footnote-ref\"><a href=\"#fn-a\" id=\"fnref-a-2\" data-footnote-ref>1</a></sup>.</p>\n<section class=\"footnotes\" data-footnotes>\n<ol>\n<li id=\"fn-a\">\n<p>Note. <a href=\"#fnref-a\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a> <a href=\"#fnref-a-2\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1-2\" aria-label=\"Back to reference 1-2\">↩<sup class=\"footnote-ref\">2</sup></a></p>\n</li>\n</ol>\n</section>\n"
expect html("No note[^x] here.") == "<p>No note[^x] here.</p>\n"
expect Md.footnotes(Md.parse("A[^b] and C[^a].\n\n[^a]: First given.\n[^b]: Second given.")).map(|note| (note.label, note.number, note.refs)) == [("b", 1, 1), ("a", 2, 1)]
expect Md.footnotes(Md.parse("Text[^a].\n\n[^a]: Refers on[^b].\n[^b]: The last.")).map(|note| note.label) == ["a", "b"]
expect Md.headings(Md.parse("## Why[^a]\n\n[^a]: Because.")) == [{ level: 2, id: "why", text: "Why" }]
expect Md.footnote_problems("A[^a], B[^b], `[^c]` code.\n\n[^a]: A.\n[^a]: Again.\n[^d]: D.") == ["[^b] refers to a note that isn't there", "[^a] is given twice", "[^d] is a note nothing refers to"]
expect Md.footnote_problems("A[^a].\n\n[^a]: A.") == []
expect Md.words(Md.parse("Two words[^a].\n\n[^a]: And three more.")) == 5
expect Md.safe_url("/a:b") and Md.safe_url("mailto:x@y.z") and !Md.safe_url(" javascript:x") and !Md.safe_url("vbscript:x")
