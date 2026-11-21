import pf.Server
import pf.Endpoint
import ../../Middlewares

middleware = Middlewares.beta

## GET /beta: only for those with the new checkout on; 404 for anyone else.
get! : { request : Server.Request, params : {}, context : Middlewares.Context } => Try(Str, Endpoint.Refusal)
get! = |{ context, .. }| Ok("the new checkout, for ${context.user}")
