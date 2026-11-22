import pf.Server
import pf.Endpoint
import ../../../../../Middlewares
import ../../../../../Note
import ../../../../../Notebook

middleware = Middlewares.api

## Text added at the end of a note, after a blank line (a journal, a running list). Two at once
## each add theirs. The note, as it is now.
post! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me, body : { text : Str } } => Try(Note.Full, Endpoint.Refusal)
post! = |{ params, context, body, .. }| Notebook.append!(context, params.id, body.text)
