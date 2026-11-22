import pf.Server
import pf.Endpoint
import ../../../I18n
import ../../../Listing
import ../../../Posts
import ../../../Search

## The journal's posts, newest first: `?lang=en` (or `pl`) for one language's, `&tag=bread` for a
## tag's, `&author=iris-vale` for a writer's, `&q=night` for a search of titles and tags. Each
## post as lists show it, with its URL and its translations'. The search island reads one
## language's, as its page renders.
get! : { request : Server.Request, params : {}, context : c } => Try(List(Listing.Summary), Endpoint.Refusal)
get! = |{ request, .. }| {
	asked = |name| request.query.split_on("&").keep_if(|pair| pair.starts_with("${name}=")).first().map_ok(|pair| Server.decode_segment(pair.drop_prefix("${name}=").replace_each("+", " "))) ?? ""
	lang = asked("lang")
	if !lang.is_empty() and !I18n.known(lang) {
		Err(BadRequest("lang: the journal is written in ${Str.join_with(I18n.langs, " and ")}, not ${lang}"))
	} else {
		tag = asked("tag")
		author = asked("author")
		chosen =
			Posts.all
				.keep_if(|entry| lang.is_empty() or entry.lang == lang)
				.keep_if(|entry| tag.is_empty() or entry.post.tags.contains(tag))
				.keep_if(|entry| author.is_empty() or entry.post.author == author)
				.map(Posts.summary)
		Ok(Search.results(asked("q"), chosen))
	}
}
