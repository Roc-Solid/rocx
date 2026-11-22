import pf.Server
import pf.Endpoint
import forms.Issues
import ../../Draft
import ../../Generated/Paths
import ../../Sets
import ../../Visitor

## POST /sets, from the editor (`title`, `blurb`, `questions`): the new set, written, and on to the
## host's page, where it is first; or a 422 with the issues at their fields, the same the editor
## shows as it is typed.
post! : { request : Server.Request, params : {}, context : Visitor.Context, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ request, .. }|
	match Draft.form.parse_body(Server.text_of(request)) {
		Ok(made) =>
			match Sets.create!(made) {
				Ok(id) => Err(Answer(Server.redirect("${Paths.host}?made=${id.to_str()}")))
				Err(_) => Err(Status(503, "The set couldn't be saved. Try again."))
			}
		Err(issues) => Err(Issues.refusal(issues))
	}
