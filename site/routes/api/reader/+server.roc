import pf.Server
import pf.Endpoint

## GET /api/reader: who is reading, as a session would say on the server (here, always Ada). The
## bag demo reads it as the page renders, and the page carries the answer.
get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
get! = |_| Ok("Ada")
