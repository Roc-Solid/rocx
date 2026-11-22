import pf.Server
import pf.Endpoint
import ../../../../Middlewares
import ../../../../Note
import ../../../../Notebook

middleware = Middlewares.api

## One of your notes, whole: its Markdown, tags, and whether it is pinned or archived.
get! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me } => Try(Note.Full, Endpoint.Refusal)
get! = |{ params, context, .. }| Notebook.read!(context, params.id)

## A note's title, body and tags, all replaced.
put! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me, body : { title : Str, body : Str, tags : List(Str) } } => Try(Note.Full, Endpoint.Refusal)
put! = |{ params, context, body, .. }| Notebook.update!(context, params.id, body)

## A note deleted, for good.
delete! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me } => Try({ deleted : Str }, Endpoint.Refusal)
delete! = |{ params, context, .. }| Notebook.delete!(context, params.id).map_ok(|{}| { deleted: params.id })
