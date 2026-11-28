import pf.Env
import pf.Kv
import pf.Server
import auth.Auth
import crypto.Hmac

## Who may use the diary. Without `PLATE_PASSWORD` set it is open, as an app on your own machine
## is. With it, the password is checked here, and the session it starts is packages/auth's
## (`Auth.sign_in!`, the plugin main.roc lists): a random token in a cookie (`plate_session`,
## HttpOnly, 90 days, kept going while the diary is used), whose SHA-256 is kept in the
## database (`auth_sessions`), so a phone stays signed in across restarts and the table alone
## signs nobody in.
##
## Wrong passwords are counted for all clients together, not each client's address (which the
## server does give: `request.peer`): ten tries a minute in all, then the form says to wait.
Session := [].{

	## The diary's one user, as the sessions' table names them: there are no accounts.
	me : Str
	me = "me"

	## Whether the diary needs no sign-in: `PLATE_PASSWORD` isn't set.
	open! : {} => Bool
	open! = |{}|
		match Env.var!("PLATE_PASSWORD") {
			Ok(password) => password.is_empty()
			Err(NotFound) => Bool.True
		}

	## Signs in with `password`, going on to `then` (a path of this site, else `/`): the answer that
	## does, with the new session's cookie.
	sign_in! : Str, Str => Try(Server.Response, [Wrong, Open, TooMany, DbErr(Str)])
	sign_in! = |password, then| {
		tries = Kv.increment!("plate:sign-in-tries", 1, { ttl_ms: 60_000 }) ?? 0
		match Env.var!("PLATE_PASSWORD") {
			Err(NotFound) => Err(Open)
			Ok("") => Err(Open)
			Ok(_) if tries > 10 => Err(TooMany)
			Ok(wanted) =>
				if Hmac.equal(wanted.to_utf8(), password.to_utf8()) {
					Auth.sign_in!(Server.redirect(Auth.path!(then)), Session.me)
				} else {
					Err(Wrong)
				}
		}
	}
}
