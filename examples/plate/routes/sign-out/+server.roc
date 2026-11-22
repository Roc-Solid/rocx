import pf.Server
import pf.Endpoint
import ../../Session

## POST /sign-out, from the goals page: the session ended, its cookie cleared, and on to signing in.
post! : { request : Server.Request, params : {}, context : {}, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ request, .. }| {
	Session.sign_out!(request)
	Err(Answer(Server.without_cookie(Server.redirect("/sign-in"), Session.cookie)))
}
