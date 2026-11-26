import pf.Server
import pf.Endpoint
import ../../../Generated/Api
import ../../../Generated/ApiShoutServer
import ../../../Generated/ApiShoutWordServer

## GET /api/calls, for JSON: what the shout endpoints answered, asked as anything over HTTP would
## ask them (`Endpoint.respond!`), and as the app asks them, a function run here and now
## (`Endpoint.run!`). The page at /calls reads it as it renders (`Endpoint.get!`): the page's data,
## at the page's path under /api.
get! : { request : Server.Request, params : {}, context : { facts : Str } } => Try({ asked : List({ method : Str, path : Str, body : Str, status : U16, answer : Str }), shouted : Str }, Endpoint.Refusal)
get! = |{ request, context, .. }| {
	answered = |(method, path, body, answer)| { method, path, body, status: answer.status, answer: Server.body_text(answer) }
	posted = |body| Server.from_http("POST", "/api/shout", "content-type: application/json", body.to_utf8())
	asked = [
		("GET", "/api/shout/rocx", "", Endpoint.respond!(shout_word("rocx"), Server.from_host("/api/shout/rocx", ""), context)),
		("POST", "/api/shout", "\"hi\"", Endpoint.respond!(shout, posted("\"hi\""), context)),
		("POST", "/api/shout", "\"\"", Endpoint.respond!(shout, posted("\"\""), context)),
		("POST", "/api/shout", "{}", Endpoint.respond!(shout, posted("{}"), context)),
	]
	shouted =
		match Endpoint.run!(shout_word("rocx"), request, context, {}) {
			Ok(word) => "${word.shouted}, ${word.bytes.to_str()} bytes"
			Err(_) => "(no answer)"
		}
	Ok({ asked: asked.map(answered), shouted })
}

## The shout endpoints, each Api's contract bound to its handler, as `Generated/Handlers` binds
## them (`Endpoint.bind`): this file can't import Handlers, which imports it.
shout = Endpoint.bind(Api.post_api_shout({}), |request, context, body| ApiShoutServer.post!({ request, params: {}, context, body }))

shout_word = |word| Endpoint.bind(Api.get_api_shout_word({ word: word }), |request, context, {}| ApiShoutWordServer.get!({ request, params: { word }, context }))
