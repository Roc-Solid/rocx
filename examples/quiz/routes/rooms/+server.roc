import pf.Server
import pf.Endpoint
import ../../Entry
import ../../Visitor

## POST /rooms, from a set on the host's page (`set`, its id): a new room for it, and on to its
## screen.
post! : { request : Server.Request, params : {}, context : Visitor.Context, body : { set : Str } } => Try({}, Endpoint.Refusal)
post! = |{ context, body, .. }| Entry.open!(context, body.set)
