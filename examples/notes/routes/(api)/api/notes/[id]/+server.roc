import pf.Server
import pf.Endpoint
import ../../../../../Middlewares
import ../../../../../Note
import ../../../../../Notebook

## One of your notes, whole: its Markdown, tags, and whether it is pinned or archived. The note's
## page (`/notes/<id>`) and its editor read it too.
get! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me } => Try(Note.Full, Endpoint.Refusal)
get! = |{ params, context, .. }| Notebook.read!(context, params.id)

## A note's title, body and tags, all replaced.
put! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me, body : { title : Str, body : Str, tags : List(Str) } } => Try(Note.Full, Endpoint.Refusal)
put! = |{ params, context, body, .. }| Notebook.update!(context, params.id, body)

## POST /api/notes/<id>, from the note page's buttons (`action`): `pin`, `unpin`, `archive`,
## `restore`, or `delete` (an archived note only: archiving first means a slip loses nothing), which
## goes on to the notebook. The note, as it is now.
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

## A note deleted, for good.
delete! : { request : Server.Request, params : { id : Str }, context : Middlewares.Me } => Try({ deleted : Str }, Endpoint.Refusal)
delete! = |{ params, context, .. }| Notebook.delete!(context, params.id).map_ok(|{}| { deleted: params.id })
