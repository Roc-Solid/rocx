import pf.Server
import pf.Endpoint
import ../../../Draft
import ../../../Generated/Paths
import ../../../Sets
import ../../../Visitor

## What POST /api/sets is sent: a set, read and checked by `Draft.form` (D-093), its questions parsed
## from their text. What doesn't pass is refused with the issues at their fields (422), the same the
## editor shows as it is typed.
post_body = Draft.form

## POST /api/sets, from the editor (`title`, `blurb`, `questions`): the new set, written, and on to the
## host's page, where it is first.
post! : { request : Server.Request, params : {}, context : Visitor.Context, body : Draft.Made } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	match Sets.create!(body) {
		Ok(id) => Err(Answer(Server.redirect("${Paths.host}?made=${id.to_str()}")))
		Err(_) => Err(Status(503, "The set couldn't be saved. Try again."))
	}
