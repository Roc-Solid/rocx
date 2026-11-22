import pf.Server
import pf.Endpoint
import ../../../Session

## POST /admin/sign-out: ends the session, and goes back to the status page.
post! : { request : Server.Request, params : {}, context : {}, body : {} } => Try(Str, Endpoint.Refusal)
post! = |{ request, .. }| {
	Session.sign_out!(request)
	Err(Answer(Server.clear_cookie(Server.redirect("/"), Session.cookie, Server.cookie_defaults)))
}
