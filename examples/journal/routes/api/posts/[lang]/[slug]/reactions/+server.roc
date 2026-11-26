import pf.Server
import pf.Endpoint
import ../../../../../../Middlewares
import ../../../../../../Posts
import ../../../../../../Reaction
import ../../../../../../Reactions

## A post's reactions: each kind's count, and the kinds this reader (their `reader` cookie) has
## given. 404 for a post the language doesn't have.
get! : { request : Server.Request, params : { lang : Str, slug : Str }, context : Middlewares.Context } => Try(Reaction.Tally, Endpoint.Refusal)
get! = |{ params, context, .. }|
	if Posts.find(params.lang, params.slug).is_ok() {
		Ok(Reactions.tally!(params.slug, context.reader))
	} else {
		Err(NotFound)
	}

## A reader's reaction, given (`{"kind":"clap","on":"true"}`) or taken back (`"on":"false"`), as
## JSON (the island's action) or a plain form (no JavaScript). The counts after it. Counted once
## per reader however often it is sent; a reader is known by the `reader` cookie their first page
## gave them, so a request without one is refused. 429 past the rate limit.
post! : { request : Server.Request, params : { lang : Str, slug : Str }, context : Middlewares.Context, body : Reaction.Toggle } => Try(Reaction.Tally, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	if Posts.find(params.lang, params.slug).is_err() {
		Err(NotFound)
	} else if !Reaction.known(body.kind) {
		Err(BadRequest("kind: one of ${Str.join_with(Reaction.kinds.map(|kind| kind.id), ", ")}, not ${body.kind}"))
	} else if Reaction.direction(body.on).is_err() {
		Err(BadRequest("on: \"true\" to give it or \"false\" to take it back, not ${body.on}"))
	} else if context.reader.is_empty() {
		Err(Status(403, "Open the post's page first: reactions are kept by the reader cookie it gives you."))
	} else {
		Ok(Reactions.toggle!(params.slug, context.reader, body))
	}
