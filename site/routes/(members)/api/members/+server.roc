import pf.Server
import pf.Endpoint

## GET /api/members, as JSON: who you are, behind the same middleware as the page (/members): its
## group's.
get! : { request : Server.Request, params : {}, context : { facts : Str, member : Str } } => Try({ member : Str }, Endpoint.Refusal)
get! = |{ context, .. }| Ok({ member: context.member })
