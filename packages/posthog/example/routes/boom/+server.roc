import pf.Server
import pf.Endpoint

## GET /boom: a 500, which the middleware reports.
get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
get! = |_input| Err(Status(500, "the ledger is locked by job 42"))
