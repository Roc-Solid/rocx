import pf.Server
import pf.Endpoint
import ../../../../../../Middlewares
import ../../../../../../Note
import ../../../../../../Notebook

## POST /api/notes/<id>/edit, from the editor (`title`, `body`, `tags` as typed): the note saved,
## and on to it.
post! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me, body : { title : Str, body : Str, tags : Str } } => Try(Server.Response, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	tags = Note.tags_in(body.tags).map_err(|why| BadRequest(why))?
	saved = Notebook.update!(context, params.id, { title: body.title, body: body.body, tags })?
	Ok(Server.redirect("/notes/${saved.id}"))
}
