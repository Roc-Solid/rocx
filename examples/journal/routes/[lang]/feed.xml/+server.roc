import pf.Server
import ../../../I18n
import ../../../Posts
import ../../../Site
import ../../../Xml
import ../../../Authors

## `/en/feed.xml` and `/pl/feed.xml` (a route's directory may name a file): each language's Atom
## feed, every post with its whole text. A language the journal isn't written in has none.
respond! : { request : Server.Request, params : { lang : Str }, context : c } => Server.Response
respond! = |{ request, params, .. }| {
	lang = params.lang
	if !I18n.known(lang) {
		Server.refused(404, "No feed for ${lang}: the journal is written in ${Str.join_with(I18n.langs, " and ")}.")
	} else if request.method != "GET" and request.method != "HEAD" {
		Server.response(405, [{ name: "allow", value: "GET, HEAD" }], "")
	} else {
		origin = Site.origin!(request)
		items = Posts.in_lang(lang).map(
			|entry| {
				post = entry.post
				{ title: post.title, url: "${origin}${Posts.url(entry)}", date: post.date, author: Authors.name_of(post.author), tags: post.tags, summary: post.summary, html: Posts.html(entry) }
			},
		)
		feed = Xml.atom({ lang, title: "Journal", subtitle: I18n.t(lang, "site.tagline"), self: "${origin}/${lang}/feed.xml", home: "${origin}/${lang}", items })
		Server.response(200, [{ name: "content-type", value: "application/atom+xml; charset=utf-8" }], feed)
	}
}
