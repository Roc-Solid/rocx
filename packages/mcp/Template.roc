import JsonValue
import Resource

## A family of resources an agent can read from the app, whose URIs a template matches
## (`notes://note/{id}`, RFC 6570's simple `{name}` expressions): reading one is given the values
## the template's names took (`id`) and the URI, and gives its contents, or `NotFound`.
##
##     note = Template.new("notes://note/{id}", "note", |values, uri, _|
##         match Notes.find!(values.get("id") ?? "") {
##             Ok(found) => Ok([Resource.contents(uri, "text/markdown", Text(found.body))])
##             Err(_) => Err(NotFound)
##         })
##         .described("A note, by its id")
Template(ctx) := {
	pattern : Str,
	name : Str,
	title : Str,
	description : Str,
	mime : Str,
	read : Dict(Str, Str), Str, ctx => Try(List(Resource.Contents), [NotFound, Failed(Str)]),
}.{

	## A family of resources: its URI template, its name, and what reading a URI it matches gives,
	## given the values the template's names took and the URI. `NotFound` when nothing is there.
	new : Str, Str, (Dict(Str, Str), Str, ctx => Try(List(Resource.Contents), [NotFound, Failed(Str)])) -> Template(ctx)
	new = |pattern, name, read!| { pattern: pattern, name: name, title: "", description: "", mime: "", read: read! }

	## The template, with a title for people.
	titled : Template(ctx), Str -> Template(ctx)
	titled = |family, title| { ..family, title: title }

	## The template, with what its resources are, for the model.
	described : Template(ctx), Str -> Template(ctx)
	described = |family, description| { ..family, description: description }

	## The template, with its resources' type (`text/markdown`).
	typed : Template(ctx), Str -> Template(ctx)
	typed = |family, mime| { ..family, mime: mime }

	## A template as `resources/templates/list` lists it.
	to_json : Template(ctx) -> JsonValue
	to_json = |family|
		JsonValue.object_of([
			("uriTemplate", Ok(String(family.pattern))),
			("name", Ok(String(family.name))),
			("title", JsonValue.text_unless_empty(family.title)),
			("description", JsonValue.text_unless_empty(family.description)),
			("mimeType", JsonValue.text_unless_empty(family.mime)),
		])

	## The values a URI gives a template's names, if it matches it: `notes://note/{id}` and
	## `notes://note/7` give `id` 7. A name takes at least one character, and up to the template's
	## next literal text (and never a `/`, unless it is the last thing in the template), so
	## `files://{dir}/{name}` matches `files://docs/a.md`, and `files://{path}` matches `files://docs/a.md`
	## too. Its value is percent-decoded.
	matching : Str, Str -> Try(Dict(Str, Str), [NoMatch])
	matching = |pattern, uri| {
		pieces = parts(pattern)
		found = match_parts(pieces, uri.to_utf8(), [])?
		Ok(Dict.from_list(found))
	}
}

## A template's pieces: literal text, and the names in braces.
parts : Str -> List([Literal(List(U8)), Name(Str)])
parts = |pattern| {
	var $pieces = []
	var $literal = []
	var $name = []
	var $in_name = Bool.False
	for byte in pattern.to_utf8() {
		if $in_name {
			if byte == '}' {
				$pieces = $pieces.append(Name(Str.from_utf8($name) ?? ""))
				$name = []
				$in_name = Bool.False
			} else {
				$name = $name.append(byte)
			}
		} else if byte == '{' {
			if !$literal.is_empty() {
				$pieces = $pieces.append(Literal($literal))
			}
			$literal = []
			$in_name = Bool.True
		} else {
			$literal = $literal.append(byte)
		}
	}
	if ($literal.is_empty()) $pieces else $pieces.append(Literal($literal))
}

match_parts : List([Literal(List(U8)), Name(Str)]), List(U8), List((Str, Str)) -> Try(List((Str, Str)), [NoMatch])
match_parts = |pieces, rest, found|
	match pieces.first() {
		Err(_) => if (rest.is_empty()) Ok(found) else Err(NoMatch)
		Ok(Literal(text)) =>
			if rest.starts_with(text) {
				match_parts(pieces.drop_first(1), rest.drop_first(text.len()), found)
			} else {
				Err(NoMatch)
			}
		Ok(Name(name)) => {
			after = pieces.drop_first(1)
			# How far the value goes: to the next literal's start, or, last, to the end.
			end =
				match after.first() {
					Ok(Literal(text)) => find_bytes(rest, text) ?? rest.len()
					_ => rest.len()
				}
			taken = rest.take_first(end)
			last = after.is_empty()
			if taken.is_empty() or (!last and taken.contains('/')) {
				Err(NoMatch)
			} else {
				match_parts(after, rest.drop_first(end), found.append((name, percent_decoded(taken))))
			}
		}
	}

## Where `needle` first starts in `bytes`.
find_bytes : List(U8), List(U8) -> Try(U64, [NotFound])
find_bytes = |bytes, needle| {
	var $at = 0
	while $at + needle.len() <= bytes.len() {
		if bytes.sublist({ start: $at, len: needle.len() }) == needle {
			return Ok($at)
		}
		$at = $at + 1
	}
	Err(NotFound)
}

## `%XX` as the byte it stands for; a `%` that isn't followed by two hex digits, as it is.
percent_decoded : List(U8) -> Str
percent_decoded = |bytes| {
	var $out = []
	var $at = 0
	while $at < bytes.len() {
		byte = bytes.get($at) ?? 0
		match (byte, hex(bytes.get($at + 1) ?? 0), hex(bytes.get($at + 2) ?? 0)) {
			('%', Ok(high), Ok(low)) => {
				$out = $out.append(high * 16 + low)
				$at = $at + 3
			}
			_ => {
				$out = $out.append(byte)
				$at = $at + 1
			}
		}
	}
	Str.from_utf8_lossy($out)
}

hex : U8 -> Try(U8, [NotHex])
hex = |byte|
	if byte >= '0' and byte <= '9' {
		Ok(byte - '0')
	} else if byte >= 'a' and byte <= 'f' {
		Ok(byte - 'a' + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok(byte - 'A' + 10)
	} else {
		Err(NotHex)
	}

expect Template.matching("notes://note/{id}", "notes://note/7").map_ok(|found| found.get("id")) == Ok(Ok("7"))
expect Template.matching("notes://note/{id}", "notes://note/").is_err()
expect Template.matching("notes://note/{id}", "notes://other/7").is_err()
expect Template.matching("notes://note/{id}/raw", "notes://note/7/raw").map_ok(|found| found.get("id")) == Ok(Ok("7"))
expect Template.matching("notes://note/{id}/raw", "notes://note/7/8/raw").is_err()
expect Template.matching("files://{dir}/{name}", "files://docs/a%20b.md").map_ok(|found| (found.get("dir"), found.get("name"))) == Ok((Ok("docs"), Ok("a b.md")))
expect Template.matching("files://{path}", "files://docs/a.md").map_ok(|found| found.get("path")) == Ok(Ok("docs/a.md"))
expect Template.matching("notes://index", "notes://index").map_ok(|found| found.len()) == Ok(0)
expect Template.matching("notes://index", "notes://index2").is_err()
