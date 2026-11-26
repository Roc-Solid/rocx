import pf.Server
import pf.Endpoint
import ../../../Middlewares

## GET /private: for signed-in requests only (`Auth.required_with`): whose it is.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ user : Str }, Endpoint.Refusal)
get! = |{ context, .. }| Ok({ user: context.user })
