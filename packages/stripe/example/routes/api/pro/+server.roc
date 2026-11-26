import pf.Server
import pf.Endpoint
import ../../../Middlewares

middleware = Middlewares.subscribers

## GET /api/pro: for subscribers only (`Middlewares.subscribers`): whose page it is.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ email : Str }, Endpoint.Refusal)
get! = |{ context, .. }| Ok({ email: context.email })
