import pf.Server
import pf.Endpoint
import markdown.Md
import ../../../../../Listing
import ../../../../../Posts

## One post, whole: as lists show it, and its body as HTML (its notes at the end), its table of
## contents and its length in words. 404 for a post the language doesn't have.
get! : { request : Server.Request, params : { lang : Str, slug : Str }, context : c } => Try({ post : Listing.Summary, html : Str, words : U64, toc : List({ level : U64, id : Str, text : Str }) }, Endpoint.Refusal)
get! = |{ params, .. }|
	match Posts.find(params.lang, params.slug) {
		Ok(entry) => Ok({ post: Posts.summary(entry), html: Posts.html(entry), words: entry.words, toc: Md.headings(entry.doc) })
		Err(NotFound) => Err(NotFound)
	}
