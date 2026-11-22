## A note, and the rules for what one may hold. Plain Roc with no effects, so the server checks every
## write with these, whoever sent it (a page, a script, an AI client), the editor says the same as you
## type, and the `expect`s at the end hold them.
Note := [].{

	## A note whole: what its page, `GET /api/notes/<id>` and MCP's `read_note` give. Ids are text,
	## as JSON APIs' usually are; dates are ISO 8601, in UTC.
	Full : { id : Str, title : Str, body : Str, tags : List(Str), pinned : Bool, archived : Bool, created : Str, updated : Str }

	## A note in a list: the start of its words or, in a search's results, the parts of it that matched.
	Summary : { id : Str, title : Str, snippet : List(Note.Piece), tags : List(Str), pinned : Bool, archived : Bool, updated : Str }

	## A piece of a snippet: a word a search matched (`hit`), or the words around it.
	Piece : { text : Str, hit : Bool }

	## A tag, and how many of someone's notes have it.
	Tagged : { name : Str, count : U64 }

	## What a search asked for: its words, and the tags it is narrowed to (`#work` in the box).
	Query : { words : Str, tags : List(Str) }

	## A title: what is left of `given` with the spaces around it gone, 1 to 200 characters.
	title_of : Str -> Try(Str, Str)
	title_of = |given| {
		title = given.trim()
		if title.is_empty() {
			Err("A note needs a title.")
		} else if title.count_utf8_bytes() > 200 {
			Err("A title is 200 characters at most.")
		} else {
			Ok(title)
		}
	}

	## A body: any Markdown, up to 100,000 bytes, its line breaks made `\n`.
	body_of : Str -> Try(Str, Str)
	body_of = |given| {
		body = given.replace_each("\r\n", "\n").trim_end()
		if (body.count_utf8_bytes() > 100_000) Err("A note is 100,000 characters at most.") else Ok(body)
	}

	## Text added at a note's end (`append_to_note`), which mustn't be empty: a blank line before it
	## (`Note.appended`), in one transaction (`Store.append!`).
	addition_of : Str -> Try(Str, Str)
	addition_of = |given| {
		text = given.replace_each("\r\n", "\n").trim()
		if (text.is_empty()) Err("There is nothing to add.") else Ok(text)
	}

	## A tag: lower case letters, digits and `-`, 1 to 32 of them; a `#` before it, and the spaces
	## around it, are left out (`"#Work "` is `work`).
	tag_of : Str -> Try(Str, Str)
	tag_of = |given| {
		tag = given.trim().drop_prefix("#").with_ascii_lowercased()
		if tag.is_empty() {
			Err("A tag can't be empty.")
		} else if tag.count_utf8_bytes() > 32 {
			Err("A tag is 32 characters at most: ${tag}")
		} else if tag.to_utf8().all(|byte| (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-') {
			Ok(tag)
		} else {
			Err("A tag is letters, digits and dashes: ${tag}")
		}
	}

	## Tags as a list of them, each as `tag_of` reads it, each once, at most 12.
	tags_of : List(Str) -> Try(List(Str), Str)
	tags_of = |given| {
		read = given.keep_if(|each| !each.trim().is_empty()).map_try(Note.tag_of)?
		tags = read.fold([], |kept, tag| if (kept.contains(tag)) kept else kept.append(tag))
		if (tags.len() > 12) Err("A note has 12 tags at most.") else Ok(tags)
	}

	## Tags as a form's field has them: separated by commas or spaces (`"work, ideas #roc"`).
	tags_in : Str -> Try(List(Str), Str)
	tags_in = |field| Note.tags_of(field.replace_each(",", " ").split_on(" "))

	## Tags as a form's field shows them again.
	tags_text : List(Str) -> Str
	tags_text = |tags| Str.join_with(tags, ", ")

	## `body` with `text` at its end, a blank line between them, or `text` alone when the body has
	## nothing but spaces: what appending to a note makes of it.
	appended : Str, Str -> Str
	appended = |body, text| {
		kept = body.trim_end()
		if (kept.trim().is_empty()) text else "${kept}\n\n${text}"
	}

	## What a body reads as, its Markdown's marks left out: a link or an image is its text, the mark
	## at a line's start (a heading's `#`s, `>`, a list's `-`, `*`, `+` or `1.`, and a task's
	## `[ ]` after it) goes, so do a code fence's marks and its language and every `*`, `_`, `` ` ``
	## and `~`, and each run of spaces and line breaks is one space. What a list shows of a note, and
	## what a search quotes from it: `Store` writes it with the body, and searches it.
	plain : Str -> Str
	plain = |body| {
		bytes = fenceless(line_marks_gone(unlinked(body.to_utf8()))).drop_if(|byte| byte == '*' or byte == '_' or byte == '`' or byte == '~')
		Str.from_utf8_lossy(one_spaced(bytes))
	}

	## A search box's text read: `#tag` narrows the search to notes with that tag, and the rest are
	## the words to find (`"deploy #work"`: notes tagged work that mention deploying).
	query_of : Str -> Note.Query
	query_of = |text| {
		parts = text.split_on(" ").map(|part| part.trim()).keep_if(|part| !part.is_empty())
		tags = parts.keep_if(|part| part.starts_with("#")).keep_oks(Note.tag_of)
		words = Str.join_with(parts.drop_if(|part| part.starts_with("#")), " ")
		{ words, tags }
	}

	## What the search puts around a word it matched in a snippet (SQLite's `snippet()`): characters
	## of Unicode's private use area, which no note has, so the marks
	## can't be confused with what was written.
	start_mark : Str
	start_mark = "\u(E000)"

	stop_mark : Str
	stop_mark = "\u(E001)"

	## A snippet as the search gives it, the matches between the marks, as pieces: the page shows each
	## hit in a `<mark>`, as text, so nothing in a note is ever read as markup.
	pieces : Str -> List(Note.Piece)
	pieces = |marked|
		marked
			.split_on(Note.start_mark)
			.map_with_index(
				|part, index|
					if index == 0 {
						[{ text: part, hit: Bool.False }]
					} else {
						match part.split_first(Note.stop_mark) {
							Ok({ before, after }) => [{ text: before, hit: Bool.True }, { text: after, hit: Bool.False }]
							Err(NotFound) => [{ text: part, hit: Bool.True }]
						}
					},
			)
			.join()
			.keep_if(|piece| !piece.text.is_empty())

	## A note as Markdown, its title a heading and its tags under it: what an AI client reads as the
	## resource `notes://note/<id>`.
	markdown : Note.Full -> Str
	markdown = |note| {
		tags = if (note.tags.is_empty()) "" else "\n\nTags: ${Str.join_with(note.tags.map(|tag| "#${tag}"), " ")}"
		state = if (note.archived) "\n\n(archived)" else ""
		"# ${note.title}${tags}${state}\n\n${note.body}\n"
	}

	## The day an ISO date names, as people write it: `"2026-11-22T09:30:00Z"` is `22 Nov 2026`.
	day : Str -> Str
	day = |iso| {
		months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
		match iso.split_on("T").first().map_ok(|date| date.split_on("-")) {
			Ok([year, month, date]) =>
				match (U64.from_str(month), U64.from_str(date)) {
					(Ok(m), Ok(d)) if m >= 1 and m <= 12 => "${d.to_str()} ${months.get(m - 1) ?? ""} ${year}"
					_ => iso
				}
			_ => iso
		}
	}
}

## Whether `byte` is a space as a regular expression's `\s` is: a space, a tab, a line break.
is_space : U8 -> Bool
is_space = |byte| byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 11 or byte == 12

## Each link and image (`[text](address)`, `![text](address)`) as its text alone.
unlinked : List(U8) -> List(U8)
unlinked = |bytes| {
	var $out = List.with_capacity(bytes.len())
	var $at = 0
	while $at < bytes.len() {
		byte = bytes.get($at) ?? 0
		start = if (byte == '!' and bytes.get($at + 1) == Ok('[')) $at + 1 else $at
		match link_at(bytes, start) {
			Ok({ text, after }) => {
				$out = $out.concat(text)
				$at = after
			}
			Err(NoLink) => {
				$out = $out.append(byte)
				$at = $at + 1
			}
		}
	}
	$out
}

## The link at `at` (its `[`): its text, and where it ends.
link_at : List(U8), U64 -> Try({ text : List(U8), after : U64 }, [NoLink])
link_at = |bytes, at|
	if bytes.get(at) != Ok('[') {
		Err(NoLink)
	} else {
		close = next_at(bytes, at + 1, ']')
		if bytes.get(close + 1) != Ok('(') {
			Err(NoLink)
		} else {
			end = next_at(bytes, close + 2, ')')
			if (end >= bytes.len()) Err(NoLink) else Ok({ text: bytes.sublist({ start: at + 1, len: close - at - 1 }), after: end + 1 })
		}
	}

## Where the first `wanted` from `from` on is, or the end.
next_at : List(U8), U64, U8 -> U64
next_at = |bytes, from, wanted| {
	var $at = from
	while $at < bytes.len() and bytes.get($at) != Ok(wanted) {
		$at = $at + 1
	}
	$at
}

## The mark at the start of each line gone, with the spaces around it: up to three spaces, then
## `#` to `######`, `>`, `-`, `*`, `+` or a number and `.`, then a space or more, then a task's
## `[ ]` (or `[x]`) and its spaces, if there is one.
line_marks_gone : List(U8) -> List(U8)
line_marks_gone = |bytes| {
	var $out = List.with_capacity(bytes.len())
	var $at = 0
	while $at < bytes.len() {
		starts_line = $at == 0 or bytes.get($at - 1) == Ok('\n')
		match (if (starts_line) line_mark_at(bytes, $at) else Err(NoMark)) {
			Ok(after) => {
				$at = after
			}
			Err(NoMark) => {
				$out = $out.append(bytes.get($at) ?? 0)
				$at = $at + 1
			}
		}
	}
	$out
}

## Where the mark at the start of a line, at `at`, ends.
line_mark_at : List(U8), U64 -> Try(U64, [NoMark])
line_mark_at = |bytes, at| {
	indent = spaces_at(bytes, at, 3)
	marked = at + indent
	hashes = run_at(bytes, marked, |byte| byte == '#')
	digits = run_at(bytes, marked, |byte| byte >= '0' and byte <= '9')
	first = bytes.get(marked) ?? 0
	mark =
		if hashes >= 1 and hashes <= 6 {
			Ok(marked + hashes)
		} else if first == '>' or first == '-' or first == '*' or first == '+' {
			Ok(marked + 1)
		} else if digits >= 1 and bytes.get(marked + digits) == Ok('.') {
			Ok(marked + digits + 1)
		} else {
			Err(NoMark)
		}
	after_mark = mark?
	gap = run_at(bytes, after_mark, is_space)
	if gap == 0 {
		Err(NoMark)
	} else {
		after_gap = after_mark + gap
		boxed = bytes.get(after_gap) == Ok('[') and (bytes.get(after_gap + 1) == Ok(' ') or bytes.get(after_gap + 1) == Ok('x') or bytes.get(after_gap + 1) == Ok('X')) and bytes.get(after_gap + 2) == Ok(']')
		box_gap = if (boxed) run_at(bytes, after_gap + 3, is_space) else 0
		if (boxed and box_gap > 0) Ok(after_gap + 3 + box_gap) else Ok(after_gap)
	}
}

## How many spaces there are at `at`, up to `most`.
spaces_at : List(U8), U64, U64 -> U64
spaces_at = |bytes, at, most| U64.min(run_at(bytes, at, is_space), most)

## How many bytes in a row from `at` are ones `keep` says yes to.
run_at : List(U8), U64, (U8 -> Bool) -> U64
run_at = |bytes, at, keep| {
	var $count = 0
	while bytes.get(at + $count).map_ok(keep) == Ok(Bool.True) {
		$count = $count + 1
	}
	$count
}

## Each code fence's marks gone, with the language after them (`````sh`).
fenceless : List(U8) -> List(U8)
fenceless = |bytes| {
	var $out = List.with_capacity(bytes.len())
	var $at = 0
	while $at < bytes.len() {
		if bytes.get($at) == Ok('`') and bytes.get($at + 1) == Ok('`') and bytes.get($at + 2) == Ok('`') {
			$at = $at + 3 + run_at(bytes, $at + 3, |byte| (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-')
		} else {
			$out = $out.append(bytes.get($at) ?? 0)
			$at = $at + 1
		}
	}
	$out
}

## Each run of spaces and line breaks one space, and none at either end.
one_spaced : List(U8) -> List(U8)
one_spaced = |bytes| {
	var $out = List.with_capacity(bytes.len())
	var $gap = Bool.False
	for byte in bytes {
		if is_space(byte) {
			$gap = Bool.True
		} else {
			if $gap and !$out.is_empty() {
				$out = $out.append(' ')
			} else {
				{}
			}
			$gap = Bool.False
			$out = $out.append(byte)
		}
	}
	$out
}

expect Note.title_of("  Groceries ") == Ok("Groceries")
expect Note.title_of("   ").is_err()
expect Note.title_of(Str.repeat("a", 201)).is_err()
expect Note.body_of("one\r\ntwo\n\n") == Ok("one\ntwo")
expect Note.body_of(Str.repeat("a", 100_001)).is_err()
expect Note.addition_of("  \n ").is_err()
expect Note.tag_of("#Work ") == Ok("work")
expect Note.tag_of("road-trip") == Ok("road-trip")
expect Note.tag_of("two words").is_err()
expect Note.tag_of("émoji").is_err()
expect Note.tags_in("Work, ideas #roc work") == Ok(["work", "ideas", "roc"])
expect Note.tags_in("") == Ok([])
expect Note.tags_of(List.repeat("x", 3).map_with_index(|_, index| "t${index.to_str()}")) == Ok(["t0", "t1", "t2"])
expect Note.tags_of(List.repeat("x", 13).map_with_index(|_, index| "t${index.to_str()}")).is_err()
expect Note.query_of("  deploy #Work  checklist ") == { words: "deploy checklist", tags: ["work"] }
expect Note.query_of("#a #b") == { words: "", tags: ["a", "b"] }
expect
	Note.pieces("a \u(E000)roc\u(E001) and \u(E000)notes\u(E001)")
		== [{ text: "a ", hit: Bool.False }, { text: "roc", hit: Bool.True }, { text: " and ", hit: Bool.False }, { text: "notes", hit: Bool.True }]
expect Note.pieces("no match here") == [{ text: "no match here", hit: Bool.False }]
expect Note.day("2026-11-22T09:30:00Z") == "22 Nov 2026"
expect Note.day("2026-01-05") == "5 Jan 2026"
expect Note.day("soon") == "soon"
expect Note.plain("## Packing\n\nBring the **orange** kite, and spare line.\n\n- [ ] Check the wind") == "Packing Bring the orange kite, and spare line. Check the wind"
expect Note.plain("- [x] Book the cabin\n  2. Ask [the library](https://library.example.com/winter), see ![a map](map.png)") == "Book the cabin Ask the library, see a map"
expect Note.plain("```sh\nsay \"$n\"; sleep 1\n```\n\nSwap `say` for snake_case") == "say \"$n\"; sleep 1 Swap say for snakecase"
expect Note.plain("####### seven\n    - indented\n> quoted\n[not a link] (x)") == "####### seven - indented quoted [not a link] (x)"
expect Note.plain("") == ""
expect Note.appended("- Try rye flour", "- Ask about the oven") == "- Try rye flour\n\n- Ask about the oven"
expect Note.appended(" \n ", "First") == "First"
