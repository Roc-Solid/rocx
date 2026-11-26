import pf.Server
import pf.Endpoint
import ../../../Generated/Api
import ../../../Generated/ApiShoutServer
import ../../../Generated/ApiShoutWordServer

## GET /api/calls, for JSON: what the shout endpoints answered, asked as anything over HTTP would
## ask them (`Endpoint.respond!`), and as the app's own code asks them (`Endpoint.send!`, which the
## server answers in-process, through the endpoint's route and its middleware, D-103). The page at
## /calls reads it as it renders (`Endpoint.read!`): the page's data, at the page's path under /api.
get! : { request : Server.Request, params : {}, context : { facts : Str } } => Try({ asked : List({ method : Str, path : Str, body : Str, status : U16, answer : Str }), shouted : Str }, Endpoint.Refusal)
get! = |{ context, .. }| {
	answered = |(method, path, body, answer)| { method, path, body, status: answer.status, answer: Server.body_text(answer) }
	posted = |body| Server.from_http("POST", "/api/shout", "content-type: application/json", body.to_utf8())
	asked = [
		("GET", "/api/shout/rocx", "", Endpoint.respond!(shout_word("rocx"), Server.from_host("/api/shout/rocx", ""), context)),
		("POST", "/api/shout", "\"hi\"", Endpoint.respond!(shout, posted("\"hi\""), context)),
		("POST", "/api/shout", "\"\"", Endpoint.respond!(shout, posted("\"\""), context)),
		("POST", "/api/shout", "{}", Endpoint.respond!(shout, posted("{}"), context)),
	]
	shouted =
		match Api.get_api_shout_word({ word: "rocx" }).send!({}) {
			Ok(word) => "${word.shouted}, ${word.bytes.to_str()} bytes"
			Err(_) => "(no answer)"
		}
	Ok({ asked: asked.map(answered), shouted })
}

## The shout endpoints, each Api's contract bound to its handler, as `Generated/Handlers` binds
## them (`Endpoint.bind`): this file can't import Handlers, which imports it.
shout = Endpoint.bind(Api.post_api_shout({}), |request, context, body| ApiShoutServer.post!({ request, params: {}, context, body }))

shout_word = |word| Endpoint.bind(Api.get_api_shout_word({ word: word }), |request, context, {}| ApiShoutWordServer.get!({ request, params: { word }, context }))
