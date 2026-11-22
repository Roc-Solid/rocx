import pf.Server
import pf.Endpoint
import forms.Issues
import ../../../Middlewares
import ../../../Store
import ../../../Tasks
import ../../../TaskForm

## GET /lists/:id, for JSON: the list, its tasks in their order, the team, who you are, and today.
## The page at this path reads it as it renders (a browser's GET of it is the page), and again
## after every change it sends.
get! : { request : Server.Request, params : { id : Str }, context : Middlewares.Context } => Try(Tasks.Sheet, Endpoint.Refusal)
get! = |{ params, context, .. }| {
	list = Store.list!(params.id).map_err(Store.refusal)?
	tasks = Store.tasks!(params.id).map_err(Store.refusal)?
	people = Store.people!({}).map_err(Store.refusal)?
	today = Store.today!({}).map_err(Store.refusal)?
	Ok({ id: list.id, name: list.name, tasks, people, me: context.me, today })
}

## POST /lists/:id, from the form under the list (`components/AddTask.rocx`): a new task, last on
## the list; its id. `body` is what the form posted, field by field, as strings: the page shows it
## in the list while it is on its way (`use_submissions!`). `TaskForm.adding` reads the form again,
## checked, into a title, a day and a person, or refuses it with each field's issues (422).
post! : { request : Server.Request, params : { id : Str }, context : Middlewares.Context, body : Tasks.Adding } => Try(Str, Endpoint.Refusal)
post! = |{ request, params, .. }|
	match TaskForm.adding.parse_body(Server.text_of(request)) {
		Ok(task) => {
			# Who it is for is checked here, against the team in the database: a form can't know.
			known =
				match task.assignee {
					Ok(person) => Store.is_person!(person).map_err(Store.refusal)?
					Err(Missing) => Bool.True
				}
			if known {
				Store.add!(params.id, task).map_err(Store.refusal)
			} else {
				Err(Issues.refusal([{ field: "assignee", code: Custom("unknown", "Choose someone on the team"), message: "Choose someone on the team" }]))
			}
		}
		Err(issues) => Err(Issues.refusal(issues))
	}
