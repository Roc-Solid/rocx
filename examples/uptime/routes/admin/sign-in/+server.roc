import pf.Server
import pf.Endpoint
import ../../../Session

## POST /admin/sign-in: the admin password. Right, and the browser gets a session's cookie and goes
## on to `next` (a path of this site; the admin's page otherwise). Wrong, and it is refused: a plain
## form goes back to the page with the refusal in its flash, which never holds the password (the
## platform keeps a flash on the server, and leaves a password field out of the page).
post! : { request : Server.Request, params : {}, context : {}, body : { password : Str, next : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }| {
	back = if (body.next.starts_with("/") and !body.next.starts_with("//")) body.next else "/admin"
	match Session.sign_in!(body.password) {
		Ok(token) => {
			cookie = { ..Server.cookie_defaults, max_age_s: Session.ttl_ms // 1000 }
			Err(Answer(Server.set_cookie(Server.redirect(back), Session.cookie, token, cookie)))
		}
		Err(Wrong) => Err(Status(401, "That isn't the admin password."))
		Err(Closed) => Err(Status(503, "Signing in is off: start the server with ADMIN_PASSWORD set."))
		Err(TooMany) => Err(Status(429, "Too many tries: wait a minute and try again."))
	}
}
