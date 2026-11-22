import Chars
import Inline

## The second of Markdown's two passes: a paragraph's (or a heading's, or a cell's) text as
## inlines. One scan from left to right finds code spans, autolinks, raw HTML, entities, escapes
## and line breaks, and notes each run of `*`, `_` or `~` and each `[` or `![`. A `]` makes a link
## or an image of what follows its `[` when a destination or a known reference follows; then the
## runs pair up into emphasis as CommonMark's delimiter algorithm pairs them. Last, bare
## `https://…` and `www.…` become links (GitHub's extension). `[^label]` is a footnote's reference
## when `notes` has its label (GitHub's), and text otherwise. Not exposed: `Md.parse`.
InlineParser := [].{
	parse : Str, List({ label : Str, url : Str, title : Str }), List(Str) -> List(Inline)
	parse = |source, refs, notes| {
		bytes = source.to_utf8()
		var $items = []
		var $brackets = []
		var $i = 0
		while $i < bytes.len() {
			b = Chars.at(bytes, $i)
			if b == '\n' {
				$items = line_break($items)
				$i = Chars.until(bytes, $i + 1, |c| !Chars.is_space_or_tab(c))
			} else if b == '\\' {
				next = Chars.at(bytes, $i + 1)
				if next == '\n' {
					$items = $items.append(Node(Break))
					$i = Chars.until(bytes, $i + 2, |c| !Chars.is_space_or_tab(c))
				} else if Chars.is_punct(next) {
					$items = text($items, Chars.slice(bytes, $i + 1, $i + 2))
					$i = $i + 2
				} else {
					$items = text($items, "\\")
					$i = $i + 1
				}
			} else if b == '`' {
				found = code_span(bytes, $i)
				$items = $items.append(found.item)
				$i = found.end
			} else if b == '*' or b == '_' or b == '~' {
				end = Chars.until(bytes, $i, |c| c != b)
				count = end - $i
				before = Chars.class_before(bytes, $i)
				after = Chars.class_at(bytes, end)
				left = after != Space and (after != Punct or before == Space or before == Punct)
				right = before != Space and (before != Punct or after == Space or after == Punct)
				opens = if (b == '_') left and (!right or before == Punct) else left
				closes = if (b == '_') right and (!left or after == Punct) else right
				$items =
					if b == '~' and count > 2 {
						text($items, Chars.slice(bytes, $i, end))
					} else {
						$items.append(Delim({ ch: b, count, orig: count, open: opens, close: closes }))
					}
				$i = end
			} else if b == '!' and Chars.at(bytes, $i + 1) == '[' {
				$brackets = $brackets.append($items.len())
				$items = $items.append(Bracket({ image: Bool.True, active: Bool.True, at: $i + 2 }))
				$i = $i + 2
			} else if b == '[' {
				match Chars.note_label(bytes, $i) {
					Ok(found) if notes.contains(found.label) => {
						# Numbered once the whole document is read (`Md.parse`).
						$items = $items.append(Node(Footnote({ label: found.label, number: 0, nth: 0 })))
						$i = found.end
					}
					_ => {
						$brackets = $brackets.append($items.len())
						$items = $items.append(Bracket({ image: Bool.False, active: Bool.True, at: $i + 1 }))
						$i = $i + 1
					}
				}
			} else if b == ']' {
				closed = close_bracket(bytes, $i, $items, $brackets, refs)
				$items = closed.items
				$brackets = closed.brackets
				$i = closed.end
			} else if b == '<' {
				match autolink(bytes, $i) {
					Ok(link) => {
						$items = $items.append(Node(Link({ url: link.url, title: "", content: [Text(link.text)] })))
						$i = link.end
					}
					Err(_) =>
						match Chars.raw_html(bytes, $i) {
							Ok(end) => {
								$items = $items.append(Node(Raw(Chars.slice(bytes, $i, end))))
								$i = end
							}
							Err(_) => {
								$items = text($items, "<")
								$i = $i + 1
							}
						}
				}
			} else if b == '&' {
				match Chars.entity(bytes, $i) {
					Ok(found) => {
						$items = text($items, Str.from_utf8_lossy(found.text))
						$i = found.end
					}
					Err(_) => {
						$items = text($items, "&")
						$i = $i + 1
					}
				}
			} else {
				end = Chars.until(bytes, $i + 1, is_special)
				$items = text($items, Chars.slice(bytes, $i, end))
				$i = end
			}
		}
		bare_links(emphasis($items))
	}
}

## What the scan keeps: inlines made, a run of `*`, `_` or `~` (how many are left of it, how many
## it had, and whether it can open or close emphasis), and a `[` or `![` (and where its text starts).
Item : [
	Node(Inline),
	Delim({ ch : U8, count : U64, orig : U64, open : Bool, close : Bool }),
	Bracket({ image : Bool, active : Bool, at : U64 }),
]

is_special : U8 -> Bool
is_special = |b| b == '\n' or b == '\\' or b == '`' or b == '*' or b == '_' or b == '~' or b == '!' or b == '[' or b == ']' or b == '<' or b == '&'

## Text, joined to the text before it.
text : List(Item), Str -> List(Item)
text = |items, more|
	match items.last() {
		Ok(Node(Text(before))) => items.drop_last(1).append(Node(Text(before.concat(more))))
		_ => items.append(Node(Text(more)))
	}

## A line ending: a hard break after two or more spaces, a soft one otherwise; the spaces go.
line_break : List(Item) -> List(Item)
line_break = |items|
	match items.last() {
		Ok(Node(Text(before))) => {
			kept = Chars.trim_end(before)
			spaces = before.count_utf8_bytes() - kept.count_utf8_bytes()
			trimmed = if (kept.is_empty()) items.drop_last(1) else items.drop_last(1).append(Node(Text(kept)))
			trimmed.append(Node(if (spaces >= 2) Break else SoftBreak))
		}
		_ => items.append(Node(SoftBreak))
	}

## A code span: a run of backticks, to the next run as long. Its line endings are spaces, and one
## space at each end goes when both have one (so `` ` `` `` shows a backtick). No closing run: the
## backticks are text.
code_span : List(U8), U64 -> { item : Item, end : U64 }
code_span = |bytes, i| {
	open_end = Chars.until(bytes, i, |c| c != '`')
	count = open_end - i
	var $k = open_end
	while $k < bytes.len() {
		if Chars.at(bytes, $k) == '`' {
			run_end = Chars.until(bytes, $k, |c| c != '`')
			if run_end - $k == count {
				raw = Chars.slice(bytes, open_end, $k).replace_each("\n", " ")
				strip = raw.starts_with(" ") and raw.ends_with(" ") and !raw.to_utf8().all(|c| c == ' ')
				content = if (strip) Chars.slice(raw.to_utf8(), 1, raw.count_utf8_bytes() - 1) else raw
				return { item: Node(Code(content)), end: run_end }
			}
			$k = run_end
		} else {
			$k = $k + 1
		}
	}
	{ item: Node(Text(Chars.slice(bytes, i, open_end))), end: open_end }
}

## `<https://example.com>` or `<someone@example.com>`.
autolink : List(U8), U64 -> Try({ url : Str, text : Str, end : U64 }, [NoAutolink])
autolink = |bytes, i| {
	scheme_end = Chars.until(bytes, i + 1, |c| !(Chars.is_alnum(c) or c == '+' or c == '.' or c == '-'))
	scheme_len = scheme_end - i - 1
	if Chars.is_letter(Chars.at(bytes, i + 1)) and scheme_len >= 2 and scheme_len <= 32 and Chars.at(bytes, scheme_end) == ':' {
		end = Chars.until(bytes, scheme_end + 1, |c| c == '>' or c <= ' ' or c == '<')
		if Chars.at(bytes, end) == '>' {
			uri = Chars.slice(bytes, i + 1, end)
			return Ok({ url: uri, text: uri, end: end + 1 })
		}
	}
	local_end = Chars.until(bytes, i + 1, |c| !(Chars.is_alnum(c) or ".!#$%&'*+/=?^_`{|}~-".to_utf8().contains(c)))
	if local_end == i + 1 or Chars.at(bytes, local_end) != '@' {
		return Err(NoAutolink)
	}
	var $j = local_end + 1
	var $labels = 0
	var $going = Bool.True
	while $going {
		label_end = Chars.until(bytes, $j, |c| !(Chars.is_alnum(c) or c == '-'))
		size = label_end - $j
		if size == 0 or size > 63 or Chars.at(bytes, $j) == '-' or Chars.at(bytes, label_end - 1) == '-' {
			return Err(NoAutolink)
		}
		$labels = $labels + 1
		if Chars.at(bytes, label_end) == '.' {
			$j = label_end + 1
		} else {
			$j = label_end
			$going = Bool.False
		}
	}
	if Chars.at(bytes, $j) == '>' {
		address = Chars.slice(bytes, i + 1, $j)
		Ok({ url: "mailto:${address}", text: address, end: $j + 1 })
	} else {
		Err(NoAutolink)
	}
}

## A `]`: with a `[` open, a link (or an image) if a destination or a known reference follows,
## its text what came after the `[`; then the `[`s before it can't make links (no links in links;
## an image may hold one).
## Otherwise the `[` and the `]` are text.
close_bracket : List(U8), U64, List(Item), List(U64), List({ label : Str, url : Str, title : Str }) -> { items : List(Item), brackets : List(U64), end : U64 }
close_bracket = |bytes, i, items, brackets, refs| {
	literal = |found_items, open| { items: text(found_items, "]"), brackets: open, end: i + 1 }
	match brackets.last() {
		Err(_) => literal(items, brackets)
		Ok(index) => {
			opener = match items.get(index) {
				Ok(Bracket(bracket)) => bracket
				_ => { image: Bool.False, active: Bool.False, at: i }
			}
			below = brackets.drop_last(1)
			as_text = items.set(index, Node(Text(if (opener.image) "![" else "["))) ?? items
			if !opener.active {
				literal(as_text, below)
			} else {
				match link_after(bytes, i + 1, Chars.slice(bytes, opener.at, i), refs) {
					Ok(link) => {
						inner = emphasis(items.drop_first(index + 1))
						node = if (opener.image) Image({ url: link.url, title: link.title, alt: Inline.plain(inner) }) else Link({ url: link.url, title: link.title, content: inner })
						made = items.take_first(index).append(Node(node))
						kept =
							if opener.image {
								made
							} else {
								below.fold(
									made,
									|list, at|
										match list.get(at) {
											Ok(Bracket(bracket)) if !bracket.image => list.set(at, Bracket({ ..bracket, active: Bool.False })) ?? list
											_ => list
										},
								)
							}
						{ items: kept, brackets: below, end: link.end }
					}
					Err(_) => literal(as_text, below)
				}
			}
		}
	}
}

## What follows a link's text: `(destination "title")`, `[label]`, `[]`, or nothing (the text is
## the label).
link_after : List(U8), U64, Str, List({ label : Str, url : Str, title : Str }) -> Try({ url : Str, title : Str, end : U64 }, [NoLink])
link_after = |bytes, p, link_text, refs| {
	if Chars.at(bytes, p) == '(' {
		match inline_destination(bytes, p + 1) {
			Ok(link) => return Ok(link)
			Err(_) => {}
		}
	}
	lookup = |label, end|
		match refs.find_first(|ref| ref.label == Chars.label_key(label)) {
			Ok(ref) => Ok({ url: ref.url, title: ref.title, end })
			Err(_) => Err(NoLink)
		}
	if Chars.at(bytes, p) == '[' {
		var $j = p + 1
		var $valid = Bool.True
		var $going = Bool.True
		while $going and $j < bytes.len() {
			b = Chars.at(bytes, $j)
			if b == '\\' and Chars.is_punct(Chars.at(bytes, $j + 1)) {
				$j = $j + 2
			} else if b == '[' {
				$valid = Bool.False
				$going = Bool.False
			} else if b == ']' {
				$going = Bool.False
			} else {
				$j = $j + 1
			}
		}
		if $valid and Chars.at(bytes, $j) == ']' and $j - p <= 1000 {
			label = Chars.slice(bytes, p + 1, $j)
			return if (Chars.trim(label).is_empty()) lookup(link_text, $j + 1) else lookup(label, $j + 1)
		}
	}
	lookup(link_text, p)
}

## `destination "title")` after a link's `(`, spaces and a line ending allowed between them.
inline_destination : List(U8), U64 -> Try({ url : Str, title : Str, end : U64 }, [NoLink])
inline_destination = |bytes, start| {
	q = skip_space(bytes, start)
	if Chars.at(bytes, q) == ')' {
		return Ok({ url: "", title: "", end: q + 1 })
	}
	dest = Chars.destination(bytes, q).map_err(|_| NoLink)?
	r = skip_space(bytes, dest.end)
	if Chars.at(bytes, r) == ')' {
		Ok({ url: dest.url, title: "", end: r + 1 })
	} else if r > dest.end {
		found = Chars.title(bytes, r).map_err(|_| NoLink)?
		s = skip_space(bytes, found.end)
		if (Chars.at(bytes, s) == ')') Ok({ url: dest.url, title: found.title, end: s + 1 }) else Err(NoLink)
	} else {
		Err(NoLink)
	}
}

skip_space : List(U8), U64 -> U64
skip_space = |bytes, i| Chars.until(bytes, i, |b| !Chars.is_whitespace(b))

## The runs of `*`, `_` and `~` paired into emphasis, strong emphasis and strikethrough: each run
## that can close, from the left, with the nearest run before it of the same character that can
## open (not when one of them could do both and their lengths add up to a multiple of three,
## unless both are). Two of each when both have two; `~` pairs only with a run as long.
emphasis : List(Item) -> List(Inline)
emphasis = |input| {
	var $items = input
	var $c = 0
	while $c < $items.len() {
		match $items.get($c) {
			Ok(Delim(closer)) if closer.close and closer.count > 0 =>
				match opener_for($items, $c, closer) {
					Ok((o, opener)) => {
						used = if (closer.ch == '~') closer.count else if (closer.count >= 2 and opener.count >= 2) 2 else 1
						inner = to_inlines($items.sublist({ start: o + 1, len: $c - o - 1 }))
						node = if (closer.ch == '~') Strike(inner) else if (used == 2) Strong(inner) else Emph(inner)
						left = $items.take_first(o).concat(if (opener.count > used) [Delim({ ..opener, count: opener.count - used })] else [])
						right = (if (closer.count > used) [Delim({ ..closer, count: closer.count - used })] else []).concat($items.drop_first($c + 1))
						$items = left.append(Node(node)).concat(right)
						$c = left.len() + 1
					}
					Err(_) => {
						$c = $c + 1
					}
				}
			_ => {
				$c = $c + 1
			}
		}
	}
	to_inlines($items)
}

opener_for : List(Item), U64, { ch : U8, count : U64, orig : U64, open : Bool, close : Bool } -> Try((U64, { ch : U8, count : U64, orig : U64, open : Bool, close : Bool }), [NoOpener])
opener_for = |items, c, closer| {
	var $k = c
	while $k > 0 {
		$k = $k - 1
		match items.get($k) {
			Ok(Delim(opener)) if opener.ch == closer.ch and opener.open and opener.count > 0 => {
				odd = (opener.close or closer.open) and (opener.orig + closer.orig) % 3 == 0 and !(opener.orig % 3 == 0 and closer.orig % 3 == 0)
				fits = if (closer.ch == '~') opener.count == closer.count else !odd
				if fits {
					return Ok(($k, opener))
				}
			}
			_ => {}
		}
	}
	Err(NoOpener)
}

## What is left as inlines: runs and brackets that paired with nothing are text.
to_inlines : List(Item) -> List(Inline)
to_inlines = |items|
	items.fold(
		[],
		|out, item| {
			inline = match item {
				Node(node) => node
				Delim(run) => Text(Str.repeat(Chars.slice([run.ch], 0, 1), run.count))
				Bracket(bracket) => Text(if (bracket.image) "![" else "[")
			}
			match (out.last(), inline) {
				(Ok(Text(before)), Text(more)) => out.drop_last(1).append(Text(before.concat(more)))
				_ => out.append(inline)
			}
		},
	)

## Bare `https://…`, `http://…`, `ftp://…`, `www.…` and email addresses in text as links, as
## GitHub has them: a link ends at a space or a `<`, and not with punctuation (`.`, `,`, `?`…), a
## `)` it doesn't open, or what looks like an entity (`&hl;`).
bare_links : List(Inline) -> List(Inline)
bare_links = |inlines|
	inlines.join_map(
		|inline|
			match inline {
				Text(content) => linked(content)
				Emph(inner) => [Emph(bare_links(inner))]
				Strong(inner) => [Strong(bare_links(inner))]
				Strike(inner) => [Strike(bare_links(inner))]
				_ => [inline]
			},
	)

linked : Str -> List(Inline)
linked = |content| {
	if !(content.contains("://") or content.contains("www.") or content.contains("@")) {
		return [Text(content)]
	}
	bytes = content.to_utf8()
	var $out = []
	var $from = 0
	var $i = 0
	while $i < bytes.len() {
		boundary = $i == 0 or Chars.is_whitespace(Chars.at(bytes, $i - 1)) or "*_~(".to_utf8().contains(Chars.at(bytes, $i - 1))
		found =
			if boundary {
				match bare_link(bytes, $i) {
					Ok(link) => Ok(link)
					Err(_) => bare_email(bytes, $i)
				}
			} else {
				Err(NoLink)
			}
		match found {
			Ok(link) => {
				$out = (if ($i > $from) $out.append(Text(Chars.slice(bytes, $from, $i))) else $out).append(Link({ url: link.url, title: "", content: [Text(link.text)] }))
				$i = link.end
				$from = link.end
			}
			Err(_) => {
				$i = $i + 1
			}
		}
	}
	if ($from < bytes.len()) $out.append(Text(Chars.slice(bytes, $from, bytes.len()))) else $out
}

bare_link : List(U8), U64 -> Try({ url : Str, text : Str, end : U64 }, [NoLink])
bare_link = |bytes, i| {
	start_text = Chars.slice(bytes, i, i + 8)
	prefix =
		if start_text.starts_with("https://") {
			Ok({ len: 8, scheme: "" })
		} else if start_text.starts_with("http://") {
			Ok({ len: 7, scheme: "" })
		} else if start_text.starts_with("ftp://") {
			Ok({ len: 6, scheme: "" })
		} else if start_text.starts_with("www.") {
			Ok({ len: 0, scheme: "http://" })
		} else {
			Err(NoLink)
		}
	found = prefix?
	from = i + found.len
	var $end = Chars.until(bytes, from, |c| Chars.is_whitespace(c) or c == '<')
	var $trimming = Bool.True
	while $trimming and $end > from {
		last = Chars.at(bytes, $end - 1)
		span = bytes.sublist({ start: i, len: $end - i })
		if "?!.,:*_~'\"".to_utf8().contains(last) {
			$end = $end - 1
		} else if last == ')' and span.count_if(|c| c == ')') > span.count_if(|c| c == '(') {
			$end = $end - 1
		} else if last == ';' {
			# `&name;` at the end looks like an entity: it isn't the link's.
			match entity_start(bytes, from, $end - 1) {
				Ok(at) => {
					$end = at
				}
				Err(_) => {
					$trimming = Bool.False
				}
			}
		} else {
			$trimming = Bool.False
		}
	}
	domain_end = Chars.until(bytes, from, |c| c == '/' or c == '?' or c == '#' or c == ':')
	if !valid_domain(Chars.slice(bytes, from, U64.min(domain_end, $end))) {
		return Err(NoLink)
	}
	shown = Chars.slice(bytes, i, $end)
	Ok({ url: "${found.scheme}${shown}", text: shown, end: $end })
}

## Where the `&` of an entity-like `&name;` ending at `semicolon` is.
entity_start : List(U8), U64, U64 -> Try(U64, [NoEntity])
entity_start = |bytes, from, semicolon| {
	var $j = semicolon
	while $j > from and Chars.is_alnum(Chars.at(bytes, $j - 1)) {
		$j = $j - 1
	}
	if ($j < semicolon and $j > from and Chars.at(bytes, $j - 1) == '&') Ok($j - 1) else Err(NoEntity)
}

## Segments of letters, digits, `_` and `-` between dots, at least one dot, and no `_` in the last
## two segments.
valid_domain : Str -> Bool
valid_domain = |domain| {
	segments = domain.split_on(".")
	last_two = segments.take_last(2)
	segments.len() >= 2 and segments.all(|segment| !segment.is_empty() and segment.to_utf8().all(|c| Chars.is_alnum(c) or c == '-' or c == '_' or c >= 0x80)) and !last_two.any(|segment| segment.contains("_"))
}

## `someone@example.com`: letters, digits and `.-_+` before the `@`; after it, a domain with a dot,
## not ending with `-` or `_`.
bare_email : List(U8), U64 -> Try({ url : Str, text : Str, end : U64 }, [NoLink])
bare_email = |bytes, i| {
	at = Chars.until(bytes, i, |c| !(Chars.is_alnum(c) or c == '.' or c == '-' or c == '_' or c == '+'))
	if at == i or Chars.at(bytes, at) != '@' {
		return Err(NoLink)
	}
	var $end = Chars.until(bytes, at + 1, |c| !(Chars.is_alnum(c) or c == '.' or c == '-' or c == '_'))
	while $end > at + 1 and Chars.at(bytes, $end - 1) == '.' {
		$end = $end - 1
	}
	domain = Chars.slice(bytes, at + 1, $end)
	last = Chars.at(bytes, $end - 1)
	if !domain.contains(".") or last == '-' or last == '_' {
		Err(NoLink)
	} else {
		address = Chars.slice(bytes, i, $end)
		Ok({ url: "mailto:${address}", text: address, end: $end })
	}
}

shape : List(Inline) -> Str
shape = |inlines|
	Str.join_with(
		inlines.map(
			|inline|
				match inline {
					Text(content) => content
					Code(code) => "`${code}`"
					Emph(inner) => "<em>${shape(inner)}</em>"
					Strong(inner) => "<strong>${shape(inner)}</strong>"
					Strike(inner) => "<del>${shape(inner)}</del>"
					Link(link) => "<a ${link.url}${if (link.title.is_empty()) "" else " \"${link.title}\""}>${shape(link.content)}</a>"
					Image(image) => "<img ${image.url} ${image.alt}>"
					Raw(html) => "raw(${html})"
					Footnote(note) => "fn(${note.label})"
					Break => "<br>"
					SoftBreak => "\n"
				},
		),
		"",
	)

inlines : Str -> Str
inlines = |source| shape(InlineParser.parse(source, [{ label: "ref", url: "/r", title: "R" }], ["salt", "a"]))

expect inlines("*a* **b** _c_ __d__ ~~e~~") == "<em>a</em> <strong>b</strong> <em>c</em> <strong>d</strong> <del>e</del>"
expect inlines("*foo**bar**baz*") == "<em>foo<strong>bar</strong>baz</em>"
expect inlines("***strong emph***") == "<em><strong>strong emph</strong></em>"
expect inlines("foo*bar*") == "foo<em>bar</em>"
expect inlines("foo_bar_") == "foo_bar_"
expect inlines("*foo**bar*") == "<em>foo**bar</em>"
expect inlines("`a `` b` and ` `` `") == "`a `` b` and ````"
expect inlines("[link](/u \"T\") ![img](/i.png) [ref] [x][ref] [ref][]") == "<a /u \"T\">link</a> <img /i.png img> <a /r \"R\">ref</a> <a /r \"R\">x</a> <a /r \"R\">ref</a>"
expect inlines("[a [b](/x) c](/y)") == "[a <a /x>b</a> c](/y)"
expect inlines("<https://x.y/z> <a@b.co> <b>hi</b>") == "<a https://x.y/z>https://x.y/z</a> <a mailto:a@b.co>a@b.co</a> raw(<b>)hiraw(</b>)"
expect inlines("a  \nb\\\nc\nd") == "a<br>b<br>c\nd"
expect inlines("\\*not\\* &amp; &copy;") == "*not* & ©"
expect inlines("See www.example.com/a_b. And https://x.org/(y)) ok") == "See <a http://www.example.com/a_b>www.example.com/a_b</a>. And <a https://x.org/(y)>https://x.org/(y)</a>) ok"
expect inlines("[not a `link]`") == "[not a `link]`"
expect inlines("~one~ and ~~~three~~~") == "<del>one</del> and ~~~three~~~"
expect inlines("![a [b](/u)](/i)") == "<img /i a b>"
expect inlines("Bread[^salt] keeps[^A], and [^none] is text, `[^salt]` code.") == "Breadfn(salt) keepsfn(a), and [^none] is text, `[^salt]` code."
expect inlines("*a note[^salt]* in [a link[^a]](/u)") == "<em>a notefn(salt)</em> in <a /u>a linkfn(a)</a>"
