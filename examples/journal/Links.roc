import I18n
import Posts
import Generated/Paths

## Where a page is in the journal's other languages: what the language switcher links to, and the
## `hreflang` alternates of each page's `<head>` and of the sitemap. A post's translation is the
## post of the same name in the other language; a page with no translation (an English-only post,
## a tag only one language uses) is the other language's nearest page instead: its tags, or its
## latest writing. Server-only: it reads the posts.
Links := [].{

	## The page at `path` in `lang`, or the nearest page `lang` has.
	in_lang : Str, Str -> Str
	in_lang = |path, lang| {
		parts = path.drop_prefix("/").drop_suffix("/").split_on("/")
		home = Paths.lang({ lang: lang })
		match parts {
			[_, "page", number] =>
				match U64.from_str(number) {
					Ok(page) if page >= 1 and page <= Posts.pages(lang) => Paths.lang_page_number({ lang, number })
					_ => home
				}
			[_, "posts", slug] => if (Posts.find(lang, slug).is_ok()) Paths.lang_posts_slug({ lang, slug }) else home
			[_, "tags"] => Paths.lang_tags({ lang: lang })
			[_, "tags", tag] => if (Posts.tagged(lang, tag).is_empty()) Paths.lang_tags({ lang: lang }) else Paths.lang_tags_tag({ lang, tag })
			[_, "authors", author] => if (Posts.by(lang, author).is_empty()) home else Paths.lang_authors_author({ lang, author })
			[_, "search"] => Paths.lang_search({ lang: lang })
			_ => home
		}
	}

	## The page at `path` in each of the journal's languages, its own included: one link a
	## language, as the switcher and `hreflang` list them.
	alternates : Str -> List({ lang : Str, url : Str, same : Bool })
	alternates = |path| {
		here = I18n.of_path(path)
		I18n.langs.map(
			|lang| {
				url = if (lang == here) path else Links.in_lang(path, lang)
				{ lang, url, same: lang == here or Links.in_lang(url, here) == path }
			},
		)
	}

	## What the page at `path` is about, for its `<meta name="description">`: a post's summary,
	## else the journal's.
	description : Str -> Str
	description = |path| {
		lang = I18n.of_path(path)
		match path.drop_prefix("/").split_on("/") {
			[_, "posts", slug] => Posts.find(lang, slug).map_ok(|entry| entry.post.summary) ?? I18n.t(lang, "site.description")
			_ => I18n.t(lang, "site.description")
		}
	}
}

expect Links.in_lang("/en/posts/winter-garden", "pl") == "/pl/posts/winter-garden"
expect Links.in_lang("/en/posts/no-such-post", "pl") == "/pl"
expect Links.in_lang("/en/tags/no-such-tag", "pl") == "/pl/tags"
expect Links.in_lang("/en/page/99", "pl") == "/pl"
expect Links.in_lang("/en/search", "pl") == "/pl/search"
expect Links.alternates("/en/posts/winter-garden").map(|link| link.url) == ["/en/posts/winter-garden", "/pl/posts/winter-garden"]
