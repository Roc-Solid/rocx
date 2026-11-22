import pf.Server
import pf.Endpoint

## GET /api/echo/:message: the message, said back. The echo demo reads it for each message as the
## page renders (`Endpoint.get!`), so the page carries every answer and picking asks nothing.
get! : { request : Server.Request, params : { message : Str }, context : c } => Try(Str, Endpoint.Refusal)
get! = |{ params, .. }| Ok("Echo: ${params.message}")
