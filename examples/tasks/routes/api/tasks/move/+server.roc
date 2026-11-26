import pf.Server
import pf.Endpoint
import ../../../../Middlewares
import ../../../../Store
import ../../../../Tasks

## POST /api/tasks/move: a task to another place on its list (`to`, from 0, counted without it).
## A row's up and down buttons post here as a form; a row dropped on another sends the same
## record as an action (`use_action!`). The id is in the body, not the path: the page lists the
## submissions to one URL, every move on the list together.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : Tasks.Move } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }| Store.move!(body).map_err!(Store.refusal!)
