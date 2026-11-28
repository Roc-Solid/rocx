## An avatar stack's arithmetic: who is shown and how many more (`split`), a face's initials when it
## has no picture (`initials`), a colour of its own when the app gives none (`color`: the same key,
## the same colour, on every page), a status as a word (`status_word`), and what a screen reader hears
## (`said`, `names`, `label`).
Stack := [].{

	## A face's status: here (`Online`, no dot), away from the screen (`Away`: a hidden tab, an orange
	## dot and the face dimmed), not to be disturbed (`Busy`: a red dot), or not here (`Offline`: the
	## face greyed, for a stack of those who belong somewhere, one who dropped among them).
	Status : [Online, Away, Busy, Offline]

	## A face in the stack: whose (`key`), their name, their picture's URL (or `""`: their initials),
	## their colour (or `""`: one from their key), and their status.
	Face : { key : Str, name : Str, image : Str, color : Str, status : Stack.Status }

	## A status as a word, in lower case: its class (`status-away`) and what a screen reader hears
	## after a name (`Bo (away)`).
	status_word : Stack.Status -> Str
	status_word = |status|
		match status {
			Online => "online"
			Away => "away"
			Busy => "busy"
			Offline => "offline"
		}

	## What a screen reader hears for a face: its name, and its status unless it is `Online`
	## (`"Bo (away)"`).
	said : Stack.Face -> Str
	said = |face| if (face.status == Online) face.name else "${face.name} (${Stack.status_word(face.status)})"

	## Who to show, and how many more: all of `faces` when `max` or fewer, or else the first
	## `max - 1` and `+N` for the rest (the `+N` takes the last place).
	split : List(Stack.Face), U64 -> { shown : List(Stack.Face), more : U64 }
	split = |faces, max|
		if faces.len() <= max {
			{ shown: faces, more: 0 }
		} else {
			room = if (max > 0) max - 1 else 0
			{ shown: faces.take_first(room), more: faces.len() - room }
		}

	## Up to two letters for a name: the first letters of its first and last words, capitalised
	## (`"Ada Lovelace"` is `"AL"`, `"bo"` is `"B"`, `"Émile Zola"` is `"ÉZ"`); `"?"` for no name.
	initials : Str -> Str
	initials = |name| {
		words = name.split_on(" ").drop_if(|word| word.is_empty())
		firsts =
			match (words.first(), words.last()) {
				(Ok(first), Ok(last)) if words.len() > 1 => first_letter(first).concat(first_letter(last))
				(Ok(first), _) => first_letter(first)
				_ => ""
			}
		if (firsts.is_empty()) "?" else firsts.with_ascii_uppercased()
	}

	## A face's colour: its own, or the palette's for its key.
	color_of : Stack.Face -> Str
	color_of = |face| if (face.color.is_empty()) Stack.color(face.key) else face.color

	## A colour for `key`, from the palette: always the same one for the same key.
	color : Str -> Str
	color = |key| {
		index = hash(key).to_u64() % palette.len()
		palette.get(index) ?? "#4f6bed"
	}

	## Names as one phrase, at most `max` of them before "others": `"Ann"`, `"Ann and Bo"`,
	## `"Ann, Bo and Cy"`, `"Ann, Bo and 2 others"`.
	names : List(Str), U64 -> Str
	names = |all, max| {
		count = all.len()
		if count == 0 {
			""
		} else if count == 1 {
			all.first() ?? ""
		} else if count <= max {
			"${Str.join_with(all.take_first(count - 1), ", ")} and ${all.last() ?? ""}"
		} else {
			shown = all.take_first(if (max > 1) max - 1 else 1)
			rest = count - shown.len()
			"${Str.join_with(shown, ", ")} and ${rest.to_str()} ${if (rest == 1) "other" else "others"}"
		}
	}

	## What a screen reader hears for a stack: who is here, `"Ann, Bo and 2 others are here"`.
	label : List(Stack.Face) -> Str
	label = |faces|
		match faces {
			[] => "No one is here"
			[only] => "${only.name} is here"
			_ => "${Stack.names(faces.map(|face| face.name), 3)} are here"
		}
}

## Eight colours that white initials read on (each 4.5:1 or more).
palette : List(Str)
palette = ["#b4235a", "#a2410f", "#7a5b00", "#2c7a2c", "#0e7470", "#1f62b8", "#5b46c9", "#8e3aa8"]

## The first letter (code point) of `word`.
first_letter : Str -> Str
first_letter = |word| {
	bytes = word.to_utf8()
	lead = bytes.first() ?? 0
	size =
		if lead < 0x80 {
			1
		} else if lead < 0xE0 {
			2
		} else if lead < 0xF0 {
			3
		} else {
			4
		}
	Str.from_utf8(bytes.take_first(size)) ?? ""
}

## FNV-1a, 32 bits: a key's colour, spread over the palette.
hash : Str -> U32
hash = |text| text.to_utf8().fold(2166136261, |at, byte| at.bitwise_xor(byte.to_u32()).times_wrap(16777619))

face : Str, Str -> Stack.Face
face = |key, name| { key, name, image: "", color: "", status: Online }

expect Stack.split([face("a", "Ann"), face("b", "Bo")], 4) == { shown: [face("a", "Ann"), face("b", "Bo")], more: 0 }
expect Stack.split([face("a", "Ann"), face("b", "Bo"), face("c", "Cy"), face("d", "Di")], 4).more == 0
expect Stack.split([face("a", "Ann"), face("b", "Bo"), face("c", "Cy"), face("d", "Di"), face("e", "Ed")], 4) == { shown: [face("a", "Ann"), face("b", "Bo"), face("c", "Cy")], more: 2 }
expect Stack.split([face("a", "Ann"), face("b", "Bo")], 0) == { shown: [], more: 2 }

expect Stack.initials("Ada Lovelace") == "AL"
expect Stack.initials("ada byron lovelace") == "AL"
expect Stack.initials("bo") == "B"
expect Stack.initials("  Cy  ") == "C"
expect Stack.initials("") == "?"
expect Stack.initials("Émile Zola") == "ÉZ"

expect Stack.color("ann") == Stack.color("ann")
expect palette.contains(Stack.color("ann")) and palette.contains(Stack.color(""))
expect Stack.color_of({ ..face("a", "Ann"), color: "#123456" }) == "#123456"
# Different keys spread over the palette.
expect ["a", "b", "c", "d", "e", "f", "g", "h"].map(Stack.color).fold([], |seen, color| if (seen.contains(color)) seen else seen.append(color)).len() >= 4

expect Stack.names([], 3) == ""
expect Stack.names(["Ann"], 3) == "Ann"
expect Stack.names(["Ann", "Bo"], 3) == "Ann and Bo"
expect Stack.names(["Ann", "Bo", "Cy"], 3) == "Ann, Bo and Cy"
expect Stack.names(["Ann", "Bo", "Cy", "Di"], 3) == "Ann, Bo and 2 others"
expect Stack.names(["Ann", "Bo", "Cy"], 1) == "Ann and 2 others"
expect Stack.names(["Ann", "Bo"], 1) == "Ann and 1 other"

expect Stack.status_word(Away) == "away" and Stack.status_word(Offline) == "offline"
expect Stack.said(face("a", "Ann")) == "Ann"
expect Stack.said({ ..face("b", "Bo"), status: Busy }) == "Bo (busy)"

expect Stack.label([]) == "No one is here"
expect Stack.label([face("a", "Ann")]) == "Ann is here"
expect Stack.label([face("a", "Ann"), face("b", "Bo")]) == "Ann and Bo are here"
