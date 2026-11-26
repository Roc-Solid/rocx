import pf.Server
import pf.Endpoint
import ../../Middlewares
import ../../Store
import ../../TaskForm
import ../../Generated/Paths

## What POST / is sent: a new list's name, read and checked by `TaskForm.new_list` (D-093). One
## that doesn't pass is refused with its issues (422) before `post!` runs.
post_body = TaskForm.new_list

## POST /api, from the front page's "New list" form: a list, and on to it (a redirect of the
## handler's own, which the runtime follows too); or the name's issues (422), shown under it.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : Str } => Try(Server.Response, Endpoint.Refusal)
post! = |{ body, .. }| {
	id = Store.add_list!(body).map_err!(Store.refusal!)?
	Ok(Server.redirect(Paths.lists_id({ id: id })))
}
