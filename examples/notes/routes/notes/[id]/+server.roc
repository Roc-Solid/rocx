import pf.Server
import pf.Endpoint
import ../../../Middlewares
import ../../../Note
import ../../../Notebook
import ../../../Pages

middleware = Middlewares.signed_in

## GET /notes/<id>: one of your notes, for its page and its editor. Another person's is a 404, as one
## that isn't there.
get! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me } => Try(Pages.Opened, Endpoint.Refusal)
get! = |{ params, context, .. }| {
	note = Notebook.read!(context, params.id)?
	Ok({ email: context.person.email, note })
}

## POST /notes/<id>, from the note's buttons (`action`): `pin`, `unpin`, `archive`, `restore`, or
## `delete` (an archived note only: archiving first means a slip loses nothing), which goes on to the
## notebook. The note, as it is now.
post! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me, body : { action : Str } } => Try(Note.Full, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	match body.action {
		"pin" => Notebook.pin!(context, params.id, Bool.True)
		"unpin" => Notebook.pin!(context, params.id, Bool.False)
		"archive" => Notebook.archive!(context, params.id, Bool.True)
		"restore" => Notebook.archive!(context, params.id, Bool.False)
		"delete" => {
			note = Notebook.read!(context, params.id)?
			if note.archived {
				Notebook.delete!(context, params.id)?
				Err(Answer(Server.redirect("/?archived=true")))
			} else {
				Err(Conflict("Archive a note before deleting it."))
			}
		}
		_ => Err(BadRequest("Pin, unpin, archive, restore or delete: not ${body.action}."))
	}
