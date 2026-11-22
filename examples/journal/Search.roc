import pf.Server
import Listing

## Search as you type, over titles and tags. Plain Roc, so the server renders a search's results
## (`/en/search?q=bread`, a plain form: no JavaScript needed) and the browser's island filters the
## same way on every key. Case and Polish letters' marks don't matter: `zolw` finds `żółw`.
Search := [].{

	## A text folded for comparing: lowercase, and each letter with a mark as the letter without it.
	fold : Str -> Str
	fold = |text| Str.join_with(chars(text).map(fold_char), "")

	## The query's words, folded.
	words : Str -> List(Str)
	words = |query| Search.fold(query).split_on(" ").map(|word| word.trim()).drop_if(|word| word.is_empty())

	## Whether a post has every word: in its title, or as the start of one of its tags.
	matches : List(Str), Listing.Summary -> Bool
	matches = |wanted, found| {
		title = Search.fold(found.title)
		tags = found.tags.map(Search.fold)
		wanted.all(|word| title.contains(word) or tags.any(|tag| tag.starts_with(word)))
	}

	## The posts with every word of the query, those with all of them in the title first, each
	## group in the order given (newest first). With no words: every post.
	results : Str, List(Listing.Summary) -> List(Listing.Summary)
	results = |query, posts| {
		wanted = Search.words(query)
		found = posts.keep_if(|each| Search.matches(wanted, each))
		in_title = |each| wanted.all(|word| Search.fold(each.title).contains(word))
		found.keep_if(in_title).concat(found.drop_if(in_title))
	}

	## The search a page's query string asks for: its `q`, decoded (`q=night+trains` is
	## `night trains`).
	query_of : Str -> Str
	query_of = |query|
		query
			.split_on("&")
			.keep_if(|pair| pair.starts_with("q="))
			.first()
			.map_ok(|pair| Server.decode_segment(pair.drop_prefix("q=").replace_each("+", " ")))
			?? ""

	## A title in pieces, each marked when it is part of a word of the query, for `<mark>`.
	pieces : Str, Str -> List({ text : Str, hit : Bool })
	pieces = |title, query| {
		letters = chars(title)
		folded = letters.map(fold_char)
		marks = Search.words(query).fold(
			letters.map(|_| Bool.False),
			|marked, word| {
				wanted = chars(word)
				size = wanted.len()
				starts = folded.map_with_index(|_, index| index).keep_if(|index| folded.sublist({ start: index, len: size }) == wanted)
				marked.map_with_index(|hit, index| hit or starts.any(|start| index >= start and index < start + size))
			},
		)
		letters.map_with_index(|letter, index| { text: letter, hit: marks.get(index) ?? Bool.False }).fold(
			[],
			|so_far, piece|
				match so_far.last() {
					Ok(last) if last.hit == piece.hit => so_far.drop_last(1).append({ text: "${last.text}${piece.text}", hit: last.hit })
					_ => so_far.append(piece)
				},
		)
	}
}

## A text's characters (its code points), each as a string.
chars : Str -> List(Str)
chars = |text| {
	bytes = text.to_utf8()
	var $out = []
	var $i = 0
	while $i < bytes.len() {
		lead = bytes.get($i) ?? 0
		size = if (lead < 0x80) 1 else if (lead < 0xE0) 2 else if (lead < 0xF0) 3 else 4
		$out = $out.append(Str.from_utf8_lossy(bytes.sublist({ start: $i, len: size })))
		$i = $i + size
	}
	$out
}

## One character folded: ASCII lowercased, and the marked letters of Polish (and a few of its
## neighbours') as plain ones.
fold_char : Str -> Str
fold_char = |char|
	match char {
		"ą" | "Ą" | "á" | "Á" | "ä" | "Ä" | "à" | "À" => "a"
		"ć" | "Ć" | "č" | "Č" | "ç" | "Ç" => "c"
		"ę" | "Ę" | "é" | "É" | "è" | "È" | "ě" | "Ě" => "e"
		"ł" | "Ł" => "l"
		"ń" | "Ń" | "ñ" | "Ñ" => "n"
		"ó" | "Ó" | "ö" | "Ö" | "ô" | "Ô" => "o"
		"ś" | "Ś" | "š" | "Š" => "s"
		"ź" | "Ź" | "ż" | "Ż" | "ž" | "Ž" => "z"
		"ü" | "Ü" | "ú" | "Ú" => "u"
		_ => char.with_ascii_lowercased()
	}

listed : Str, List(Str) -> Listing.Summary
listed = |title, tags| { lang: "pl", slug: "x", url: "/pl/posts/x", title, date: "2026-01-01", author: "iris-vale", author_name: "Iris Vale", tags, summary: "", cover: "", minutes: 1, translations: [] }

expect Search.fold("Żółw ŁAPIE ćmę") == "zolw lapie cme"
expect Search.matches(Search.words("zolw"), listed("Żółw w ogrodzie", []))
expect Search.matches(Search.words("ogr ZÓŁW"), listed("Żółw w ogrodzie", []))
expect !Search.matches(Search.words("kot"), listed("Żółw w ogrodzie", ["ogrod"]))
expect Search.matches(Search.words("ogr"), listed("Notatki", ["ogrod", "pory-roku"]))
expect Search.results("bread", [listed("A loaf", ["bread"]), listed("Bread at dawn", []), listed("Tides", [])]).map(|found| found.title) == ["Bread at dawn", "A loaf"]
expect Search.results("", [listed("A", []), listed("B", [])]).len() == 2
expect Search.query_of("lang=pl&q=night+trains%21") == "night trains!"
expect Search.query_of("") == ""
expect Search.pieces("Ogród zimą", "ogrod") == [{ text: "Ogród", hit: Bool.True }, { text: " zimą", hit: Bool.False }]
expect Search.pieces("Night trains, again", "train") == [{ text: "Night ", hit: Bool.False }, { text: "train", hit: Bool.True }, { text: "s, again", hit: Bool.False }]
