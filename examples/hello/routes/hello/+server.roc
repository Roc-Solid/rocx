import pf.Server
import pf.Endpoint

## GET /hello: a greeting, as JSON.
get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
get! = |_| Ok("Hello from the server")
