import pf.Env
import pf.Kv
import pf.Server
import auth.Auth
import crypto.Hmac

## Who may use the admin: whoever knows `ADMIN_PASSWORD`. The password is checked here; the session
## it starts is packages/auth's (`Auth.sign_in!`, the plugin main.roc lists): a random token in a
## cookie (`uptime_admin`, HttpOnly, 12 hours, kept going while the admin uses it), its hash in the
## database (`auth_sessions`), so a restart signs nobody out. Without `ADMIN_PASSWORD` set, nobody
## can sign in.
##
## Wrong passwords are counted for all clients together, not each client's address (which the
## server does give: `request.peer`): ten tries a minute in all, then the form says to wait.
Session := [].{

	## The admin's id in the sessions' table: there is one admin, and no table of users.
	admin : Str
	admin = "admin"

	## Signs in with `password`, going on to `then` (a path of this site, else `/admin`): the answer
	## that does, with the new session's cookie.
	sign_in! : Str, Str => Try(Server.Response, [Wrong, Closed, TooMany, DbErr(Str)])
	sign_in! = |password, then| {
		tries = Kv.increment!("uptime:sign-in-tries", 1, { ttl_ms: 60_000 }) ?? 0
		match Env.var!("ADMIN_PASSWORD") {
			Err(NotFound) => Err(Closed)
			Ok("") => Err(Closed)
			Ok(_) if tries > 10 => Err(TooMany)
			Ok(wanted) =>
				if Hmac.equal(wanted.to_utf8(), password.to_utf8()) {
					Auth.sign_in!(Server.redirect(Auth.path!(then)), Session.admin)
				} else {
					Err(Wrong)
				}
		}
	}
}
