import intl.Date
import markdown.Block
import markdown.Md
import Authors
import I18n
import Post

## The content rules: what a post must be beyond what its frontmatter's type says. `Posts.all` checks
## every post when the app is built and crashes on any problem, so a wrong post fails the build
## (`roc check` and `rocx build` say which file and why), and an expect keeps the list empty for
## `roc test`.
Rules := [].{

	## A post as the rules see it: where it is, its frontmatter, and its body as written.
	Draft : { lang : Str, slug : Str, post : Post, body : Str }

	## What is wrong with one post, each a sentence that starts with its file.
	check : Rules.Draft -> List(Str)
	check = |{ lang, slug, post, body }| {
		file = "content/${lang}/${slug}.md"
		doc = Md.parse(body)
		found = [
			if (I18n.known(lang)) [] else ["${lang} isn't one of the journal's languages (${Str.join_with(I18n.langs, ", ")})"],
			if (Rules.is_slug(slug)) [] else ["its file name isn't a slug (lowercase letters, digits and single hyphens): ${slug}"],
			Rules.of_title(post.title),
			Rules.of_date(post.date),
			if (Authors.find(post.author).is_ok()) [] else ["author: no writer is called \"${post.author}\" (Authors.roc)"],
			Rules.of_tags(post.tags),
			Rules.of_summary(post.summary),
			Rules.of_cover(post.cover, post.cover_alt),
			Rules.of_body(doc),
			Md.footnote_problems(body),
		]
		found.join_map(|problems| problems).map(|problem| "${file}: ${problem}")
	}

	## What is wrong across posts: a translation (a file of the same name in another language's
	## folder) by another writer than the default language's post.
	across : List(Rules.Draft) -> List(Str)
	across = |drafts|
		drafts.join_map(
			|draft|
				drafts
					.keep_if(|other| draft.lang == I18n.default and other.slug == draft.slug and other.lang != draft.lang and other.post.author != draft.post.author)
					.map(|other| "content/${other.lang}/${other.slug}.md: a translation of content/${draft.lang}/${draft.slug}.md by another writer (${other.post.author}, not ${draft.post.author})"),
		)

	## Lowercase letters and digits in words joined by single hyphens: `slow-bread`, `wheel-2`.
	is_slug : Str -> Bool
	is_slug = |text| {
		bytes = text.to_utf8()
		good = |b| (b >= 'a' and b <= 'z') or (b >= '0' and b <= '9') or b == '-'
		!bytes.is_empty() and bytes.all(good) and !text.starts_with("-") and !text.ends_with("-") and !text.contains("--")
	}

	## A title, and not a paragraph.
	of_title : Str -> List(Str)
	of_title = |text|
		if text.trim().is_empty() {
			["title: it is empty"]
		} else if text.count_utf8_bytes() > 120 {
			["title: keep it under 120 bytes (it is ${text.count_utf8_bytes().to_str()})"]
		} else {
			[]
		}

	## A real day, written `2026-02-08`.
	of_date : Str -> List(Str)
	of_date = |text|
		match Date.parse_iso(text) {
			Ok(_) => []
			Err(BadDate(_)) => ["date: \"${text}\" isn't a day written YYYY-MM-DD"]
		}

	## One to five tags, each a slug, none twice.
	of_tags : List(Str) -> List(Str)
	of_tags = |given|
		if given.is_empty() {
			["tags: give at least one"]
		} else if given.len() > 5 {
			["tags: five at most (there are ${given.len().to_str()})"]
		} else {
			bad = given.drop_if(Rules.is_slug).map(|tag| "tags: \"${tag}\" isn't a slug (lowercase letters, digits and single hyphens)")
			twice = given.keep_if(|tag| given.count_if(|other| other == tag) > 1).map(|tag| "tags: \"${tag}\" is given twice")
			bad.concat(twice.fold([], |kept, line| if (kept.contains(line)) kept else kept.append(line)))
		}

	## A summary: a line or two, as lists show it.
	of_summary : Str -> List(Str)
	of_summary = |text|
		if text.trim().is_empty() {
			["summary: it is empty"]
		} else if text.count_utf8_bytes() > 240 {
			["summary: keep it under 240 bytes, a line or two in a list (it is ${text.count_utf8_bytes().to_str()})"]
		} else {
			[]
		}

	## A cover is one of the journal's images, and says what it shows (for those who can't see it).
	of_cover : Str, Str -> List(Str)
	of_cover = |path, alt|
		if path.is_empty() {
			if (alt.is_empty()) [] else ["cover_alt: there is no cover to describe"]
		} else if !path.starts_with("/images/") {
			["cover: \"${path}\" isn't in /images/ (static/images/)"]
		} else if alt.trim().is_empty() {
			["cover_alt: say what the cover shows, for readers who can't see it"]
		} else {
			[]
		}

	## Some words, and headings from level 2 down: the title is the page's one `<h1>`.
	of_body : List(Block) -> List(Str)
	of_body = |doc| {
		empty = if (Md.words(doc) == 0) ["the body has no words"] else []
		tops = Md.headings(doc).keep_if(|heading| heading.level == 1).map(|heading| "\"# ${heading.text}\" is a top-level heading: start at ## (the title is the page's heading)")
		empty.concat(tops)
	}
}

good : Post
good = { title: "Notes on slow bread", date: "2026-02-08", author: "iris-vale", tags: ["bread", "kitchen"], summary: "Two days, almost no work.", cover: "", cover_alt: "" }

checked : Post -> List(Str)
checked = |post| Rules.check({ lang: "en", slug: "slow-bread", post, body: "## Why\n\nBecause." })

expect checked(good) == []
expect checked({ ..good, date: "2026-02-30" }) == ["content/en/slow-bread.md: date: \"2026-02-30\" isn't a day written YYYY-MM-DD"]
expect checked({ ..good, author: "nobody" }) == ["content/en/slow-bread.md: author: no writer is called \"nobody\" (Authors.roc)"]
expect checked({ ..good, tags: ["Bread", "kitchen", "kitchen"] }) == ["content/en/slow-bread.md: tags: \"Bread\" isn't a slug (lowercase letters, digits and single hyphens)", "content/en/slow-bread.md: tags: \"kitchen\" is given twice"]
expect checked({ ..good, tags: [] }) == ["content/en/slow-bread.md: tags: give at least one"]
expect checked({ ..good, cover: "/images/bread.svg" }) == ["content/en/slow-bread.md: cover_alt: say what the cover shows, for readers who can't see it"]
expect checked({ ..good, cover: "https://example.com/bread.jpg", cover_alt: "A loaf" }) == ["content/en/slow-bread.md: cover: \"https://example.com/bread.jpg\" isn't in /images/ (static/images/)"]
expect checked({ ..good, summary: "" }) == ["content/en/slow-bread.md: summary: it is empty"]
expect Rules.check({ lang: "en", slug: "slow-bread", post: good, body: "# Big\n\nWords." }) == ["content/en/slow-bread.md: \"# Big\" is a top-level heading: start at ## (the title is the page's heading)"]
expect Rules.check({ lang: "de", slug: "Slow_Bread", post: good, body: "Words[^a]." }) == ["content/de/Slow_Bread.md: de isn't one of the journal's languages (en, pl)", "content/de/Slow_Bread.md: its file name isn't a slug (lowercase letters, digits and single hyphens): Slow_Bread", "content/de/Slow_Bread.md: [^a] refers to a note that isn't there"]
expect Rules.is_slug("night-trains") and !Rules.is_slug("night--trains") and !Rules.is_slug("-night") and !Rules.is_slug("")
expect Rules.across([{ lang: "en", slug: "a", post: good, body: "" }, { lang: "pl", slug: "a", post: { ..good, author: "theo-marsh" }, body: "" }]) == ["content/pl/a.md: a translation of content/en/a.md by another writer (theo-marsh, not iris-vale)"]
