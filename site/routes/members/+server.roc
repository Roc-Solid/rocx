import pf.Server
import pf.Endpoint
import ../../Middlewares

## GET /members, as JSON: who you are, behind the same middleware as the page.
middleware = Middlewares.member

get! : { request : Server.Request, params : {}, context : { facts : Str, member : Str } } => Try({ member : Str }, Endpoint.Refusal)
get! = |{ context, .. }| Ok({ member: context.member })
