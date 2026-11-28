import markdown.Block
import markdown.Collection
import markdown.Md
import intl.Date
import Authors
import I18n
import Listing
import Post
import Rules
import Generated/Paths
import Generated/Content/En
import Generated/Content/Pl

## The journal's posts: the Markdown files in `content/en/` and `content/pl/`, read when the app is
## built, a collection of `Post`s (packages/markdown's `Collection`). A file whose frontmatter is
## wrong, or that breaks a content rule (`Rules.roc`), fails the build with every problem named.
## Only the server reads them: pages show them inside `<NoHydration>`, so none of this (nor the
## Markdown parser) is in the browser's wasm.
##
## rocx finds each folder's files (D-042) and writes a module for each,
## `Generated/Content/En` and `Generated/Content/Pl`, every file imported as text: a new post is a
## new file, and nothing else. The frontmatter's type is the journal's own `Post`, shared by both
## folders, so the modules give the files (`En.files`) and this module reads them.
Posts := [].{

	## A post, read: where it is, its frontmatter, its body parsed (its footnotes' notes last), its
	## day, and how long it is.
	Entry : { lang : Str, slug : Str, post : Post, doc : List(Block), day : Date, words : U64, minutes : U64 }

	## How many posts a page of the index lists.
	per_page : U64
	per_page = 4

	## Every file of the collection, with its language: the folder it is in.
	files : List({ lang : Str, path : Str, source : Str })
	files = En.files.map(|file| { lang: "en", path: file.path, source: file.source }).concat(Pl.files.map(|file| { lang: "pl", path: file.path, source: file.source }))

	## Every post, each language's newest first. Read when the app is built: a crash here is a
	## build that fails, saying why.
	all : List(Posts.Entry)
	all = {
		read = Posts.files.map(
			|file|
				match Collection.entry(file.path, file.source) {
					Ok(entry) => { lang: file.lang, slug: entry.id, post: entry.data, body: entry.body, doc: entry.doc }
					Err(failed) => crash "content/${file.lang}/${Collection.describe(failed)}"
				},
		)
		drafts = read.map(|each| { lang: each.lang, slug: each.slug, post: each.post, body: each.body })
		problems = drafts.join_map(Rules.check).concat(Rules.across(drafts))
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

	## The post's body as HTML text, its notes at the end (as GitHub writes them): for the feed and
	## the JSON API, which readers render themselves. (Pages render the same document as the
	## platform's markup.)
	html : Posts.Entry -> Str
	html = |entry| Md.to_html_with(entry.doc, { ids: Bool.True })
}

## A post read: its day and its length (its body parsed already, by the collection).
entry_of : { lang : Str, slug : Str, post : Post, body : Str, doc : List(Block) } -> Posts.Entry
entry_of = |{ lang, slug, post, doc, .. }| {
	day = Date.parse_iso(post.date) ?? Date.ymd(1970, 1, 1)
	{ lang, slug, post, doc, day, words: Md.words(doc), minutes: U64.max(Md.reading_minutes(doc), 1) }
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
