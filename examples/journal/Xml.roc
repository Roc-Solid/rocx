## The journal's machine-readable documents: an Atom feed for each language and the sitemap, with
## its hreflang alternates. Plain Roc that writes XML text from what it is given; the routes
## (`routes/[lang]/feed/+server.roc`, `routes/sitemap/+server.roc`) give it the posts and the
## site's origin, since feeds and sitemaps want whole URLs.
Xml := [].{

	## An entry of a feed.
	Item : { title : Str, url : Str, date : Str, author : Str, tags : List(Str), summary : Str, html : Str }

	## An Atom feed (RFC 4287): `self` is its own URL, `home` the page it is the feed of.
	atom : { lang : Str, title : Str, subtitle : Str, self : Str, home : Str, items : List(Xml.Item) } -> Str
	atom = |{ lang, title, subtitle, self, home, items }| {
		updated = items.first().map_ok(|item| item.date) ?? "2026-01-01"
		entries = items.map(
			|item| {
				categories = Str.join_with(item.tags.map(|tag| "<category term=\"${Xml.escape(tag)}\"/>"), "")
				"<entry><title>${Xml.escape(item.title)}</title><link rel=\"alternate\" type=\"text/html\" href=\"${Xml.escape(item.url)}\"/><id>${Xml.escape(item.url)}</id><published>${stamp(item.date)}</published><updated>${stamp(item.date)}</updated><author><name>${Xml.escape(item.author)}</name></author>${categories}<summary>${Xml.escape(item.summary)}</summary><content type=\"html\">${Xml.escape(item.html)}</content></entry>"
			},
		)
		Str.join_with(
			[
				"<?xml version=\"1.0\" encoding=\"utf-8\"?>",
				"<feed xmlns=\"http://www.w3.org/2005/Atom\" xml:lang=\"${Xml.escape(lang)}\" xml:base=\"${Xml.escape(home)}\">",
				"<title>${Xml.escape(title)}</title><subtitle>${Xml.escape(subtitle)}</subtitle>",
				"<link rel=\"self\" type=\"application/atom+xml\" href=\"${Xml.escape(self)}\"/><link rel=\"alternate\" type=\"text/html\" href=\"${Xml.escape(home)}\"/>",
				"<id>${Xml.escape(home)}</id><updated>${stamp(updated)}</updated>",
			]
				.concat(entries)
				.append("</feed>"),
			"\n",
		)
	}

	## A page of the sitemap: its URL, when it last changed (`""`: not said), and the same page in
	## each language (`hreflang`, with `x-default` the reader's own pick).
	Page : { url : Str, modified : Str, alternates : List({ lang : Str, url : Str }) }

	## The sitemap (sitemaps.org), each page with its translations as `xhtml:link` alternates, as
	## search engines read them.
	sitemap : List(Xml.Page) -> Str
	sitemap = |pages| {
		urls = pages.map(
			|page| {
				modified = if (page.modified.is_empty()) "" else "<lastmod>${Xml.escape(page.modified)}</lastmod>"
				links = Str.join_with(page.alternates.map(|other| "<xhtml:link rel=\"alternate\" hreflang=\"${Xml.escape(other.lang)}\" href=\"${Xml.escape(other.url)}\"/>"), "")
				"<url><loc>${Xml.escape(page.url)}</loc>${modified}${links}</url>"
			},
		)
		Str.join_with(
			["<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\" xmlns:xhtml=\"http://www.w3.org/1999/xhtml\">"]
				.concat(urls)
				.append("</urlset>"),
			"\n",
		)
	}

	## Text as XML writes it inside an element or a quoted attribute.
	escape : Str -> Str
	escape = |text| text.replace_each("&", "&amp;").replace_each("<", "&lt;").replace_each(">", "&gt;").replace_each("\"", "&quot;").replace_each("'", "&apos;")
}

## A day as Atom's dates are written: midnight, UTC.
stamp : Str -> Str
stamp = |day| "${day}T00:00:00Z"

expect Xml.escape("Bread & <butter> \"now\"") == "Bread &amp; &lt;butter&gt; &quot;now&quot;"
expect Xml.atom({ lang: "en", title: "J", subtitle: "S", self: "https://example.com/en/feed.xml", home: "https://example.com/en", items: [] }).contains("<updated>2026-01-01T00:00:00Z</updated>")
expect Xml.atom({ lang: "en", title: "J", subtitle: "S", self: "s", home: "h", items: [{ title: "A & B", url: "u", date: "2026-02-08", author: "Iris", tags: ["bread"], summary: "x", html: "<p>Hi</p>" }] }).contains("<title>A &amp; B</title>")
expect Xml.sitemap([{ url: "https://example.com/en", modified: "", alternates: [{ lang: "pl", url: "https://example.com/pl" }] }]).contains("<url><loc>https://example.com/en</loc><xhtml:link rel=\"alternate\" hreflang=\"pl\" href=\"https://example.com/pl\"/></url>")
