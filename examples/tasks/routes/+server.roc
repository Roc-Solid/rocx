import pf.Server
import pf.Endpoint
import forms.Issues
import ../Middlewares
import ../Store
import ../TaskForm
import ../Generated/Paths

## POST /, from the front page's "New list" form: a list, and on to it (a redirect of the
## handler's own, which the runtime follows too); or the name's issues (422), shown under it.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ request, .. }|
	match TaskForm.new_list.parse_body(Server.text_of(request)) {
		Ok(name) => {
			id = Store.add_list!(name).map_err!(Store.refusal!)?
			Err(Answer(Server.redirect(Paths.lists_id({ id: id }))))
		}
		Err(issues) => Err(Issues.refusal(issues))
	}
