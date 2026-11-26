import pf.Server
import pf.Endpoint
import ../../../../Middlewares

## Who a token (or the session) is: its person's address, and whether it may only read. A quick way
## to try a token: `curl -H "Authorization: Bearer acme_pat_…" http://localhost:18160/api/me`.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ email : Str, read_only : Bool }, Endpoint.Refusal)
get! = |{ context, .. }| Ok({ email: context.person.email, read_only: context.read_only })
