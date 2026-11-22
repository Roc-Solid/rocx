import pf.Server
import pf.Endpoint
import ../../../../Middlewares
import ../../../../Store
import ../../../../Tasks

## POST /api/tasks/toggle: a task done (`done=true`), or open again (`done=false`). Each row's box
## is a form that posts here. Without JavaScript the browser posts it, and goes back to the list
## (a 303, which `Endpoint.respond!` sends a plain form); with it, the runtime sends it with fetch,
## and the list shows the change before the answer is in.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : Tasks.Toggle } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }| Store.toggle!(body.id, body.done).map_err(Store.refusal)
