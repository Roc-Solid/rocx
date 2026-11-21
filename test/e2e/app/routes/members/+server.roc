import pf.Server
import pf.Endpoint
import ../../Middlewares

## GET /members, for JSON: who is asking, behind the same middleware as the page, which reads it.
middleware = Middlewares.member

get! : { request : Server.Request, params : {}, context : { started : Str, member : Str } } => Try(Str, Endpoint.Refusal)
get! = |{ context, .. }| Ok("Welcome, ${context.member}")
