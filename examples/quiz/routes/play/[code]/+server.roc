import pf.Server
import pf.Endpoint
import forms.Issues
import ../../../Codes
import ../../../Entry
import ../../../Joining
import ../../../Visitor

## POST /play/:code, from a room's own page (`name`): into the room as one of its players.
post! : { request : Server.Request, params : { code : Str }, context : Visitor.Context, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ request, params, context, .. }|
	match (Codes.parse(params.code), Joining.named.parse_body(Server.text_of(request))) {
		(Ok(code), Ok({ name })) => Entry.join!(context, code, name)
		(Err(BadCode), _) => Err(NotFound)
		(_, Err(issues)) => Err(Issues.refusal(issues))
	}
