import pf.Server
import pf.Endpoint
import ../../../Entry
import ../../../Joining
import ../../../Visitor

## What POST /api/join is sent: a room's code and a name, read and checked by `Joining.form` (D-093).
## What doesn't pass is refused with the issues at their fields (the code, or the name), 422.
post_body = Joining.form

## POST /api/join, from the front page's form (`code`, `name`): on to the room's page as one of its
## players. Without the runtime, the form posts, and comes back with a refusal's issues.
post! : { request : Server.Request, params : {}, context : Visitor.Context, body : Joining.Made } => Try({}, Endpoint.Refusal)
post! = |{ context, body, .. }| Entry.join!(context, body.code, body.name)
