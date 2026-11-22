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

	## Text added at a note's end (`append_to_note`), which mustn't be empty. Postgres adds it, a
	## blank line before it, in one statement (`Store.append!`).
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

	## A search box's text read: `#tag` narrows the search to notes with that tag, and the rest are
	## the words to find (`"deploy #work"`: notes tagged work that mention deploying).
	query_of : Str -> Note.Query
	query_of = |text| {
		parts = text.split_on(" ").map(|part| part.trim()).keep_if(|part| !part.is_empty())
		tags = parts.keep_if(|part| part.starts_with("#")).keep_oks(Note.tag_of)
		words = Str.join_with(parts.drop_if(|part| part.starts_with("#")), " ")
		{ words, tags }
	}

	## What Postgres puts around a word a search matched in a snippet (`ts_headline`'s `StartSel`
	## and `StopSel`): characters of Unicode's private use area, which no note has, so the marks
	## can't be confused with what was written.
	start_mark : Str
	start_mark = "\u(E000)"

	stop_mark : Str
	stop_mark = "\u(E001)"

	## A snippet as Postgres gives it, the matches between the marks, as pieces: the page shows each
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
