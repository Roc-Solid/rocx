import pf.Server
import pf.Endpoint
import ../../../Session

## POST /admin/sign-in: the admin password. Right, and the browser gets a session's cookie and goes
## on to `next` (a path of this site; the admin's page otherwise). Wrong, and it goes back to the
## form with the problem in the address (`?problem=wrong`), never in a flash: a flash keeps what the
## form sent, and this form sends a password (README, "What it asked of the platform").
post! : { request : Server.Request, params : {}, context : {}, body : { password : Str, next : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| {
	back = if (body.next.starts_with("/") and !body.next.starts_with("//")) body.next else "/admin"
	again = |problem| Err(Answer(Server.redirect("/admin/sign-in?problem=${problem}&next=${Server.encode_segment(back)}")))
	match Session.sign_in!(body.password) {
		Ok(token) => {
			cookie = { ..Server.cookie_defaults, max_age_s: Session.ttl_ms // 1000 }
			Err(Answer(Server.set_cookie(Server.redirect(back), Session.cookie, token, cookie)))
		}
		Err(Wrong) => again("wrong")
		Err(Closed) => again("closed")
		Err(TooMany) => again("too-many")
	}
}
