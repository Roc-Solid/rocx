import pf.Server
import pf.Endpoint
import forms.Issues
import ../../../../Middlewares
import ../../../../Store
import ../../../../Tasks
import ../../../../TaskForm
import ../../../../Generated/Paths

## GET /api/tasks/:id, for JSON: the task, the list it is on, and the team.
get! : { request : Server.Request, params : { id : Str }, context : Middlewares.Context } => Try(Tasks.Detail, Endpoint.Refusal)
get! = |{ params, .. }| {
	found = Store.task!(params.id).map_err!(Store.refusal!)?
	people = Store.people!({}).map_err!(Store.refusal!)?
	Ok({ task: found.task, list: found.list, people })
}

## What POST /api/tasks/:id is sent: the task as its page's form says, read and checked by
## `TaskForm.editing` (D-093). A box left unticked ("done", which a browser doesn't send at all) is
## the form's to judge.
post_body = TaskForm.editing

## POST /api/tasks/:id, from the task's page: the task as its form says, then back to its list (a
## redirect of the handler's own, which the runtime follows too). What doesn't pass the form is
## refused with each field's issues (422) before this runs, and the page shows them under its fields.
post! : { request : Server.Request, params : { id : Str }, context : Middlewares.Context, body : TaskForm.Editing } => Try(Server.Response, Endpoint.Refusal)
post! = |{ params, body, .. }| {
	known =
		match body.assignee {
			Ok(person) => Store.is_person!(person).map_err!(Store.refusal!)?
			Err(Missing) => Bool.True
		}
	if known {
		Store.save!(params.id, body).map_err!(Store.refusal!)?
		found = Store.task!(params.id).map_err!(Store.refusal!)?
		Ok(Server.redirect(Paths.lists_id({ id: found.list.id })))
	} else {
		Err(Issues.refusal([{ field: "assignee", code: Custom("unknown", "Choose someone on the team"), message: "Choose someone on the team" }]))
	}
}
