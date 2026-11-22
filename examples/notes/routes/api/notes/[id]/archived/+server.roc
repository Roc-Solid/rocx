import pf.Server
import pf.Endpoint
import ../../../../../Middlewares
import ../../../../../Note
import ../../../../../Notebook

middleware = Middlewares.api

## A note archived (`true`: out of the list, kept, still found by search), or brought back.
put! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me, body : { archived : Bool } } => Try(Note.Full, Endpoint.Refusal)
put! = |{ params, context, body, .. }| Notebook.archive!(context, params.id, body.archived)
