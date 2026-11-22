## Footnotes, which packages/markdown doesn't parse yet (its README, "Limits"). A post writes them as
## GitHub does: `[^name]` where a note is referred to, and `[^name]: what it says` on a line of its
## own. `Footnotes.split` turns each reference into a link to its note (`[2](#fn-name)`), takes the
## notes' lines out of the body, and numbers the notes in the order the text first refers to them.
## The article draws those links as superscripts (its `link` hook) and the notes at its end. Fenced
## code and inline code are left alone, so a post can show the syntax itself.
Footnotes := [].{

	## A note: its name in the source, its number on the page, and what it says (one line of
	## Markdown).
	Note : { id : Str, number : U64, text : Str }

	## The body with references as links and the notes' lines gone, and the notes, numbered.
	split : Str -> { body : Str, notes : List(Footnotes.Note) }
	split = |source| {
		scanned = scan(source)
		linked = scanned.lines.fold(
			{ lines: [], order: [] },
			|so_far, line|
				if line.code {
					{ ..so_far, lines: so_far.lines.append(line.text) }
				} else {
					done = linked_line(line.text, so_far.order)
					{ lines: so_far.lines.append(done.text), order: done.order }
				},
		)
		notes = linked.order.map_with_index(
			|id, index| {
				text = scanned.defs.find_first(|def| def.id == id).map_ok(|def| def.text) ?? ""
				{ id, number: index + 1, text }
			},
		)
		{ body: Str.join_with(linked.lines, "\n"), notes }
	}

	## What is wrong with the source's notes, each a sentence: a reference to a note that isn't
	## there, a note given twice, a note nothing refers to, a note referred to twice (its back link
	## would have two places to go), or a name that isn't letters, digits and hyphens.
	problems : Str -> List(Str)
	problems = |source| {
		scanned = scan(source)
		refs = scanned.lines.join_map(|line| if (line.code) [] else references(line.text))
		defined = scanned.defs.map(|def| def.id)
		missing = refs.drop_if(|id| defined.contains(id)).map(|id| "[^${id}] refers to a note that isn't there")
		twice = duplicates(defined).map(|id| "[^${id}] is given twice")
		unused = defined.drop_if(|id| refs.contains(id)).map(|id| "[^${id}] is given but nothing refers to it")
		again = duplicates(refs).map(|id| "[^${id}] is referred to more than once")
		named = defined.concat(refs).drop_if(good_name).map(|id| "[^${id}]: a note's name is lowercase letters, digits and hyphens")
		unique(missing.concat(twice).concat(unused).concat(again).concat(named))
	}

	## A note's anchor on the page.
	anchor : Str -> Str
	anchor = |id| "fn-${id}"

	## Where a note's back link goes: its reference's anchor.
	back : Str -> Str
	back = |id| "fnref-${id}"
}

## The source's lines, each with whether it is inside fenced code, the notes' lines taken out.
scan : Str -> { lines : List({ text : Str, code : Bool }), defs : List({ id : Str, text : Str }) }
scan = |source| {
	found = source.split_on("\n").fold(
		{ fence: Bool.False, lines: [], defs: [] },
		|so_far, line| {
			lead = line.trim_start()
			if lead.starts_with("```") or lead.starts_with("~~~") {
				{ ..so_far, fence: !so_far.fence, lines: so_far.lines.append({ text: line, code: Bool.True }) }
			} else if so_far.fence {
				{ ..so_far, lines: so_far.lines.append({ text: line, code: Bool.True }) }
			} else {
				match definition(line) {
					Ok(def) => { ..so_far, defs: so_far.defs.append(def) }
					Err(NotOne) => { ..so_far, lines: so_far.lines.append({ text: line, code: Bool.False }) }
				}
			}
		},
	)
	{ lines: found.lines, defs: found.defs }
}

## `[^name]: what it says`, at the start of a line.
definition : Str -> Try({ id : Str, text : Str }, [NotOne])
definition = |line|
	if line.starts_with("[^") {
		match line.drop_prefix("[^").split_first("]:") {
			Ok({ before, after }) if !before.is_empty() and !before.contains("]") => Ok({ id: before, text: after.trim() })
			_ => Err(NotOne)
		}
	} else {
		Err(NotOne)
	}

## The names a line refers to, in order (inline code skipped).
references : Str -> List(Str)
references = |line| linked_line(line, []).seen

## A line with each `[^name]` made a link to its note, numbered by `order` (the names met so far,
## to which new ones are added), and the names this line referred to.
linked_line : Str, List(Str) -> { text : Str, order : List(Str), seen : List(Str) }
linked_line = |line, order| {
	bytes = line.to_utf8()
	var $out = []
	var $order = order
	var $seen = []
	var $code = Bool.False
	var $i = 0
	while $i < bytes.len() {
		byte = bytes.get($i) ?? 0
		if byte == '`' {
			$code = !$code
			$out = $out.append(byte)
			$i = $i + 1
		} else if !$code and byte == '[' and bytes.get($i + 1) == Ok('^') {
			match close_of(bytes, $i + 2) {
				Ok(end) => {
					id = Str.from_utf8_lossy(bytes.sublist({ start: $i + 2, len: end - $i - 2 }))
					number =
						match $order.find_first_index(|known| known == id) {
							Ok(index) => index + 1
							Err(_) => {
								$order = $order.append(id)
								$order.len()
							}
						}
					$seen = $seen.append(id)
					$out = $out.concat("[${number.to_str()}](#${Footnotes.anchor(id)})".to_utf8())
					$i = end + 1
				}
				Err(NotClosed) => {
					$out = $out.append(byte)
					$i = $i + 1
				}
			}
		} else {
			$out = $out.append(byte)
			$i = $i + 1
		}
	}
	{ text: Str.from_utf8_lossy($out), order: $order, seen: $seen }
}

## Where the `]` closing a reference's name is: a name has no spaces and isn't empty.
close_of : List(U8), U64 -> Try(U64, [NotClosed])
close_of = |bytes, start| {
	var $j = start
	while $j < bytes.len() {
		byte = bytes.get($j) ?? 0
		if byte == ']' {
			return if ($j > start) Ok($j) else Err(NotClosed)
		}
		if byte == ' ' or byte == '[' {
			return Err(NotClosed)
		}
		$j = $j + 1
	}
	Err(NotClosed)
}

good_name : Str -> Bool
good_name = |id| !id.is_empty() and id.to_utf8().all(|b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '-')

duplicates : List(Str) -> List(Str)
duplicates = |names| unique(names.keep_if(|name| names.count_if(|other| other == name) > 1))

unique : List(Str) -> List(Str)
unique = |names| names.fold([], |kept, name| if (kept.contains(name)) kept else kept.append(name))

sample : Str
sample = "A loaf[^time] keeps[^salt].\n\n```\nno [^code] here\n```\n\nAnd `[^inline]` stays.\n\n[^salt]: About 2% of the flour.\n[^time]: Two days, mostly waiting."

expect Footnotes.split(sample).body == "A loaf[1](#fn-time) keeps[2](#fn-salt).\n\n```\nno [^code] here\n```\n\nAnd `[^inline]` stays.\n"
expect Footnotes.split(sample).notes == [{ id: "time", number: 1, text: "Two days, mostly waiting." }, { id: "salt", number: 2, text: "About 2% of the flour." }]
expect Footnotes.problems(sample) == []
expect Footnotes.problems("One[^a] and two[^b].\n\n[^a]: A.\n[^c]: C.") == ["[^b] refers to a note that isn't there", "[^c] is given but nothing refers to it"]
expect Footnotes.problems("One[^a], again[^a].\n\n[^a]: A.") == ["[^a] is referred to more than once"]
expect Footnotes.problems("One[^A].\n\n[^A]: A.") == ["[^A]: a note's name is lowercase letters, digits and hyphens"]
expect Footnotes.split("No notes, but a [link](https://example.com) and [brackets].").notes == []
