import pf.Server
import pf.Endpoint
import ../../../../../Middlewares
import ../../../../../Note
import ../../../../../Notebook

middleware = Middlewares.api

## A note's tags, all of them (`[]` for none): read the note first to keep the ones it has.
put! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me, body : { tags : List(Str) } } => Try(Note.Full, Endpoint.Refusal)
put! = |{ params, context, body, .. }| Notebook.tag!(context, params.id, body.tags)
