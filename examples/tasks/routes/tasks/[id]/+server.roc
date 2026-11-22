import pf.Server
import pf.Endpoint
import forms.Issues
import ../../../Middlewares
import ../../../Store
import ../../../Tasks
import ../../../TaskForm
import ../../../Generated/Paths

## GET /tasks/:id, for JSON: the task, the list it is on, and the team.
get! : { request : Server.Request, params : { id : Str }, context : Middlewares.Context } => Try(Tasks.Detail, Endpoint.Refusal)
get! = |{ params, .. }| {
	found = Store.task!(params.id).map_err(Store.refusal)?
	people = Store.people!({}).map_err(Store.refusal)?
	Ok({ task: found.task, list: found.list, people })
}

## POST /tasks/:id, from the task's page: the task as its form says, then back to its list (a
## redirect of the handler's own, which the runtime follows too). What doesn't read is refused
## with each field's issues (422), which the page shows under its fields. `body` is `{}`: the form
## reads the body itself, so a box left unticked ("done", which a browser doesn't send at all) is
## the form's to judge, not a 400.
post! : { request : Server.Request, params : { id : Str }, context : Middlewares.Context, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ request, params, .. }|
	match TaskForm.editing.parse_body(Server.text_of(request)) {
		Ok(task) => {
			known =
				match task.assignee {
					Ok(person) => Store.is_person!(person).map_err(Store.refusal)?
					Err(Missing) => Bool.True
				}
			if known {
				Store.save!(params.id, task).map_err(Store.refusal)?
				found = Store.task!(params.id).map_err(Store.refusal)?
				Err(Answer(Server.redirect(Paths.lists_id({ id: found.list.id }))))
			} else {
				Err(Issues.refusal([{ field: "assignee", code: Custom("unknown", "Choose someone on the team"), message: "Choose someone on the team" }]))
			}
		}
		Err(issues) => Err(Issues.refusal(issues))
	}
