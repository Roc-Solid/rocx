import pf.Server
import pf.Endpoint
import ../../Account
import ../../Middlewares
import ../../Pages
import ../../Store
import ../../Token

middleware = Middlewares.signed_in

## GET /settings: your personal access tokens (never the tokens themselves), and the MCP server's
## address, for connecting a client.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try(Pages.Settings, Endpoint.Refusal)
get! = |{ context, .. }|
	match Store.tokens!(context.person.id) {
		Ok(tokens) => Ok({ email: context.person.email, mcp: "${Account.origin!({})}/mcp", tokens })
		Err(problem) => Err(Store.refused!(problem))
	}

## POST /settings, from its form (`name`, and `access`: `read` or `write`): a new personal access
## token. The token itself is in this answer, and nowhere else, ever: only its SHA-256 is kept.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { name : Str, access : Str } } => Try(Token.Made, Endpoint.Refusal)
post! = |{ context, body, .. }|
	match Token.name_of(body.name) {
		Err(why) => Err(BadRequest(why))
		Ok(name) =>
			if body.access != "read" and body.access != "write" {
				Err(BadRequest("A token may read, or read and write."))
			} else {
				match Account.make_token!(context.person.id, { name, read_only: body.access == "read" }) {
					Ok(made) => Ok(made)
					Err(problem) => Err(Store.refused!(problem))
				}
			}
	}
