import pf.Server
import pf.Endpoint

## GET /api/items: behind the /api limit.
get! : { request : Server.Request, params : {}, context : c } => Try(List(Str), Endpoint.Refusal)
get! = |_| Ok(["a", "b"])
