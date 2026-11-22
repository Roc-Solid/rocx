import pf.Server
import ../../I18n
import ../../Links
import ../../Posts
import ../../Site
import ../../Xml
import ../../Authors
import ../../Generated/Paths

## `/sitemap.xml` (the default middleware routes it here): every page of the journal in each
## language (the indexes and their pages, every post, tag and writer), each with its translations
## as `hreflang` alternates, so a search engine shows a reader the one in their language.
respond! : { request : Server.Request, params : {}, context : c } => Server.Response
respond! = |{ request, .. }| {
	origin = Site.origin!(request)
	page = |path, modified| {
		alternates = Links.alternates(path).keep_if(|other| other.same).map(|other| { lang: other.lang, url: "${origin}${other.url}" })
		{ url: "${origin}${path}", modified, alternates: if (alternates.len() > 1) alternates.append({ lang: "x-default", url: "${origin}${Links.in_lang(path, I18n.default)}" }) else [] }
	}
	pages = I18n.langs.join_map(
		|lang| {
			numbers = List.repeat(0, Posts.pages(lang)).map_with_index(|_, index| index + 1)
			indexes = numbers.map(|number| page(if (number == 1) Paths.lang({ lang: lang }) else Paths.lang_page_number({ lang, number: number.to_str() }), ""))
			posts = Posts.in_lang(lang).map(|entry| page(Posts.url(entry), entry.post.date))
			tags = [page(Paths.lang_tags({ lang: lang }), "")].concat(Posts.tags(lang).map(|found| page(Paths.lang_tags_tag({ lang, tag: found.tag }), "")))
			writers = Authors.all.keep_if(|author| !Posts.by(lang, author.id).is_empty()).map(|author| page(Paths.lang_authors_author({ lang, author: author.id }), ""))
			indexes.concat(posts).concat(tags).concat(writers)
		},
	)
	Server.response(200, [{ name: "content-type", value: "application/xml; charset=utf-8" }], Xml.sitemap(pages))
}
