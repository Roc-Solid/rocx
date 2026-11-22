import pf.Server
import pf.Endpoint
import forms.Issues
import ../../Entry
import ../../Joining
import ../../Visitor

## POST /join, from the front page's form (`code`, `name`): on to the room's page as one of its
## players, or a 422 with the issues at their fields (the code, or the name). Without the runtime,
## the form posts, and comes back with them.
post! : { request : Server.Request, params : {}, context : Visitor.Context, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ request, context, .. }|
	match Joining.form.parse_body(Server.text_of(request)) {
		Ok({ code, name }) => Entry.join!(context, code, name)
		Err(issues) => Err(Issues.refusal(issues))
	}
