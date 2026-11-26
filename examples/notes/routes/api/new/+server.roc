import pf.Server
import pf.Endpoint
import ../../../Middlewares
import ../../../Note
import ../../../Notebook
import ../../../Pages

middleware = Middlewares.signed_in

## GET /api/new: who is writing, for the page's bar.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try(Pages.Blank, Endpoint.Refusal)
get! = |{ context, .. }| Ok({ email: context.person.email })

## POST /api/new, from its form (`title`, `body`, `tags` as typed: `work, ideas`): the note written,
## and on to it.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { title : Str, body : Str, tags : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ context, body, .. }| {
	tags = Note.tags_in(body.tags).map_err(|why| BadRequest(why))?
	made = Notebook.create!(context, { title: body.title, body: body.body, tags })?
	Err(Answer(Server.redirect("/notes/${made.id}")))
}
