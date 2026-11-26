import pf.Server
import pf.Endpoint

## GET /members, for JSON: who is asking, behind the same middleware as the page (its directory's,
## routes/members/+middleware.roc), which reads it.
get! : { request : Server.Request, params : {}, context : { started : Str, member : Str } } => Try(Str, Endpoint.Refusal)
get! = |{ context, .. }| Ok("Welcome, ${context.member}")
