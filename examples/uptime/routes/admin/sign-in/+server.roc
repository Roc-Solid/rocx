import pf.Server
import pf.Endpoint
import pf.Log
import ../../../Session

## POST /admin/sign-in: the admin password. Right, and the browser gets a session's cookie
## (packages/auth's) and goes on to `then` (a path of this site; the admin's page otherwise). Wrong,
## and it is refused: a plain form goes back to the page with the refusal in its flash, which never
## holds the password (the platform keeps a flash on the server, and leaves a password field out of
## the page).
post! : { request : Server.Request, params : {}, context : {}, body : { password : Str, then : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match Session.sign_in!(body.password, body.then) {
		Ok(answer) => Err(Answer(answer))
		Err(Wrong) => Err(Status(401, "That isn't the admin password."))
		Err(Closed) => Err(Status(503, "Signing in is off: start the server with ADMIN_PASSWORD set."))
		Err(TooMany) => Err(Status(429, "Too many tries: wait a minute and try again."))
		Err(DbErr(why)) => {
			Log.error!("uptime: a session couldn't be started", { error: why })
			Err(Status(503, "Signing in didn't work just now. Try again in a minute."))
		}
	}
