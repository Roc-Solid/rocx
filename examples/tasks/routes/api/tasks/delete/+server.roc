import pf.Server
import pf.Endpoint
import ../../../../Middlewares
import ../../../../Store
import ../../../../Tasks
import ../../../../Generated/Paths

## POST /api/tasks/delete: a task gone; the list it was on. A row's delete button posts here, and
## so does the task's own page. A browser's plain form wants a page back: it is sent to the list
## (the task's page is gone with it). The runtime and scripts get the list's id as JSON.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : Tasks.Remove } => Try(Str, Endpoint.Refusal)
post! = |{ request, body, .. }| {
	list = Store.remove!(body.id).map_err!(Store.refusal!)?
	match Endpoint.posted_by(request) {
		PlainForm => Err(Answer(Server.redirect(if (list.is_empty()) Paths.root else Paths.lists_id({ id: list }))))
		Runtime | Other => Ok(list)
	}
}
