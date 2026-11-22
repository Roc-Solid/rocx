import markdown.Block
import markdown.Collection
import markdown.Md
import intl.Date
import Authors
import Footnotes
import I18n
import Listing
import Post
import Rules
import Generated/Paths
import "content/en/how-this-journal-is-made.md" as en_how_this_journal_is_made : Str
import "content/en/json-by-hand.md" as en_json_by_hand : Str
import "content/en/night-trains.md" as en_night_trains : Str
import "content/en/pocket-notebook.md" as en_pocket_notebook : Str
import "content/en/rain-sounds.md" as en_rain_sounds : Str
import "content/en/reading-a-tide-table.md" as en_reading_a_tide_table : Str
import "content/en/slow-bread.md" as en_slow_bread : Str
import "content/en/small-shell-scripts.md" as en_small_shell_scripts : Str
import "content/en/truing-a-wheel.md" as en_truing_a_wheel : Str
import "content/en/winter-garden.md" as en_winter_garden : Str
import "content/pl/json-by-hand.md" as pl_json_by_hand : Str
import "content/pl/niedziela-z-pierogami.md" as pl_niedziela_z_pierogami : Str
import "content/pl/night-trains.md" as pl_night_trains : Str
import "content/pl/pocket-notebook.md" as pl_pocket_notebook : Str
import "content/pl/reading-a-tide-table.md" as pl_reading_a_tide_table : Str
import "content/pl/slow-bread.md" as pl_slow_bread : Str
import "content/pl/small-shell-scripts.md" as pl_small_shell_scripts : Str
import "content/pl/truing-a-wheel.md" as pl_truing_a_wheel : Str
import "content/pl/winter-garden.md" as pl_winter_garden : Str

## The journal's posts: the Markdown files in `content/en/` and `content/pl/`, read when the app is
## built, a collection of `Post`s (packages/markdown's `Collection`). A file whose frontmatter is
## wrong, or that breaks a content rule (`Rules.roc`), fails the build with every problem named.
## Only the server reads them: pages show them inside `<NoHydration>`, so none of this (nor the
## Markdown parser) is in the browser's wasm.
##
## `rocx build` doesn't find a collection's files yet (packages/markdown's PROPOSALS.md), so each is
## imported as text above and listed in `files`: a new post is a file and two lines.
Posts := [].{

	## A post, read: where it is, its frontmatter, its body parsed (footnotes made links to its
	## notes), its notes, its day, and how long it is.
	Entry : { lang : Str, slug : Str, post : Post, doc : List(Block), notes : List(Footnotes.Note), day : Date, words : U64, minutes : U64 }

	## How many posts a page of the index lists.
	per_page : U64
	per_page = 4

	## Every file of the collection, with its language: the folder it is in.
	files : List({ lang : Str, path : Str, source : Str })
	files = [
		{ lang: "en", path: "how-this-journal-is-made.md", source: en_how_this_journal_is_made },
		{ lang: "en", path: "json-by-hand.md", source: en_json_by_hand },
		{ lang: "en", path: "night-trains.md", source: en_night_trains },
		{ lang: "en", path: "pocket-notebook.md", source: en_pocket_notebook },
		{ lang: "en", path: "rain-sounds.md", source: en_rain_sounds },
		{ lang: "en", path: "reading-a-tide-table.md", source: en_reading_a_tide_table },
		{ lang: "en", path: "slow-bread.md", source: en_slow_bread },
		{ lang: "en", path: "small-shell-scripts.md", source: en_small_shell_scripts },
		{ lang: "en", path: "truing-a-wheel.md", source: en_truing_a_wheel },
		{ lang: "en", path: "winter-garden.md", source: en_winter_garden },
		{ lang: "pl", path: "json-by-hand.md", source: pl_json_by_hand },
		{ lang: "pl", path: "niedziela-z-pierogami.md", source: pl_niedziela_z_pierogami },
		{ lang: "pl", path: "night-trains.md", source: pl_night_trains },
		{ lang: "pl", path: "pocket-notebook.md", source: pl_pocket_notebook },
		{ lang: "pl", path: "reading-a-tide-table.md", source: pl_reading_a_tide_table },
		{ lang: "pl", path: "slow-bread.md", source: pl_slow_bread },
		{ lang: "pl", path: "small-shell-scripts.md", source: pl_small_shell_scripts },
		{ lang: "pl", path: "truing-a-wheel.md", source: pl_truing_a_wheel },
		{ lang: "pl", path: "winter-garden.md", source: pl_winter_garden },
	]

	## Every post, each language's newest first. Read when the app is built: a crash here is a
	## build that fails, saying why.
	all : List(Posts.Entry)
	all = {
		read = Posts.files.map(
			|file|
				match Collection.entry(file.path, file.source) {
					Ok(entry) => { lang: file.lang, slug: entry.id, post: entry.data, body: entry.body }
					Err(failed) => crash "content/${file.lang}/${Collection.describe(failed)}"
				},
		)
		problems = read.join_map(Rules.check).concat(Rules.across(read))
		if !problems.is_empty() {
			crash "The journal's content has problems:\n${Str.join_with(problems, "\n")}"
		}
		read.map(entry_of).sort_with(newest_first)
	}

	## A language's posts, newest first.
	in_lang : Str -> List(Posts.Entry)
	in_lang = |lang| Posts.all.keep_if(|entry| entry.lang == lang)

	## The post at `/<lang>/posts/<slug>`.
	find : Str, Str -> Try(Posts.Entry, [NotFound])
	find = |lang, slug| Posts.all.find_first(|entry| entry.lang == lang and entry.slug == slug)

	## Whether any language has a post called `slug` (reactions are counted per slug, across
	## translations).
	has_slug : Str -> Bool
	has_slug = |slug| Posts.all.any(|entry| entry.slug == slug)

	## How many pages the language's index has: one at least, even with no posts.
	pages : Str -> U64
	pages = |lang| {
		count = Posts.in_lang(lang).len()
		U64.max((count + Posts.per_page - 1) // Posts.per_page, 1)
	}

	## Page `number` (from 1) of the language's index.
	page : Str, U64 -> List(Posts.Entry)
	page = |lang, number| Posts.in_lang(lang).drop_first((number - 1) * Posts.per_page).take_first(Posts.per_page)

	## The language's posts with this tag, newest first.
	tagged : Str, Str -> List(Posts.Entry)
	tagged = |lang, tag| Posts.in_lang(lang).keep_if(|entry| entry.post.tags.contains(tag))

	## The language's posts by this writer, newest first.
	by : Str, Str -> List(Posts.Entry)
	by = |lang, author| Posts.in_lang(lang).keep_if(|entry| entry.post.author == author)

	## The language's tags, the most used first, each with how many posts have it.
	tags : Str -> List({ tag : Str, count : U64 })
	tags = |lang| {
		posts = Posts.in_lang(lang)
		names = posts.join_map(|entry| entry.post.tags).fold([], |kept, tag| if (kept.contains(tag)) kept else kept.append(tag))
		counted = names.map(|tag| { tag, count: posts.count_if(|entry| entry.post.tags.contains(tag)) })
		counted.sort_with(|a, b| if (a.count > b.count) Before else if (a.count < b.count) After else Same)
	}

	## The same post in the journal's other languages: the files of the same name.
	translations : Posts.Entry -> List(Posts.Entry)
	translations = |entry| Posts.all.keep_if(|other| other.slug == entry.slug and other.lang != entry.lang)

	## The next post in its language, newer and older, if there is one.
	newer : Posts.Entry -> Try(Posts.Entry, [NotFound])
	newer = |entry| {
		posts = Posts.in_lang(entry.lang)
		match posts.find_first_index(|other| other.slug == entry.slug) {
			Ok(index) if index > 0 => posts.get(index - 1).map_err(|_| NotFound)
			_ => Err(NotFound)
		}
	}

	older : Posts.Entry -> Try(Posts.Entry, [NotFound])
	older = |entry| {
		posts = Posts.in_lang(entry.lang)
		match posts.find_first_index(|other| other.slug == entry.slug) {
			Ok(index) => posts.get(index + 1).map_err(|_| NotFound)
			Err(_) => Err(NotFound)
		}
	}

	## Its page.
	url : Posts.Entry -> Str
	url = |entry| Paths.lang_posts_slug({ lang: entry.lang, slug: entry.slug })

	## As lists and the JSON API show it.
	summary : Posts.Entry -> Listing.Summary
	summary = |entry| {
		post = entry.post
		{
			lang: entry.lang,
			slug: entry.slug,
			url: Posts.url(entry),
			title: post.title,
			date: post.date,
			author: post.author,
			author_name: Authors.name_of(post.author),
			tags: post.tags,
			summary: post.summary,
			cover: post.cover,
			minutes: entry.minutes,
			translations: Posts.translations(entry).map(|other| { lang: other.lang, url: Posts.url(other) }),
		}
	}

	## The post's body as HTML text, its notes after it: for the feed and the JSON API, which
	## readers render themselves. (Pages render the same document as the platform's markup.)
	html : Posts.Entry -> Str
	html = |entry| {
		body = Md.to_html_with(entry.doc, { ids: Bool.True })
		if entry.notes.is_empty() {
			body
		} else {
			items = entry.notes.map(|note| "<li id=\"${Footnotes.anchor(note.id)}\">${Md.to_html(Md.parse(note.text)).trim()} <a href=\"#${Footnotes.back(note.id)}\">↩</a></li>")
			"${body}<section class=\"footnotes\"><h2>${I18n.t(entry.lang, "post.notes")}</h2><ol>${Str.join_with(items, "")}</ol></section>"
		}
	}
}

## A post read: its body's notes split off and the rest parsed, its day, its length.
entry_of : Rules.Draft -> Posts.Entry
entry_of = |{ lang, slug, post, body }| {
	split = Footnotes.split(body)
	doc = Md.parse(split.body)
	day = Date.parse_iso(post.date) ?? Date.ymd(1970, 1, 1)
	{ lang, slug, post, doc, notes: split.notes, day, words: Md.words(doc), minutes: U64.max(Md.reading_minutes(doc), 1) }
}

newest_first : Posts.Entry, Posts.Entry -> [Before, Same, After]
newest_first = |a, b| {
	days = |entry| Date.to_days(entry.day)
	if (days(a) > days(b)) Before else if (days(a) < days(b)) After else Same
}

expect Posts.all.len() == Posts.files.len()
expect Posts.in_lang("en").all(|entry| entry.minutes >= 1)
expect Posts.pages("en") >= 1 and Posts.page("en", 1).len() <= Posts.per_page
expect Posts.page("en", Posts.pages("en") + 1).is_empty()
