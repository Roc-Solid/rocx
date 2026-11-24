import pf.Env
import pf.Kv
import pf.Random
import pf.Server
import crypto.Hex
import crypto.Hmac

## Who may use the admin: whoever knows `ADMIN_PASSWORD`. Signing in gives the browser a random
## token in a cookie (`uptime_admin`, HttpOnly, 12 hours) whose session is kept in `Kv`, so a
## restart signs everyone out. Without `ADMIN_PASSWORD` set, nobody can sign in.
##
## Wrong passwords are counted for all clients together, not each client's address (which the
## server does give: `request.peer`): ten tries a minute in all, then the form says to wait.
Session := [].{

	## The cookie a session's token is kept in.
	cookie : Str
	cookie = "uptime_admin"

	## How long a session lasts: 12 hours.
	ttl_ms : U64
	ttl_ms = 12 * 60 * 60 * 1000

	## Signs in with `password`: the new session's token, for the cookie.
	sign_in! : Str => Try(Str, [Wrong, Closed, TooMany])
	sign_in! = |password| {
		tries = Kv.increment!("uptime:sign-in-tries", 1, { ttl_ms: 60_000 }) ?? 0
		match Env.var!("ADMIN_PASSWORD") {
			Err(NotFound) => Err(Closed)
			Ok("") => Err(Closed)
			Ok(_) if tries > 10 => Err(TooMany)
			Ok(wanted) =>
				if Hmac.equal(wanted.to_utf8(), password.to_utf8()) {
					token = Hex.encode(Random.bytes!(24))
					Kv.set!("uptime:session:${token}", {}, { ttl_ms: Session.ttl_ms })
					Ok(token)
				} else {
					Err(Wrong)
				}
		}
	}

	## Whether `request` carries a session's token.
	signed_in! : Server.Request => Bool
	signed_in! = |request|
		match Server.cookie(request, Session.cookie) {
			Ok(token) => {
				found : Try({}, [NotFound, BadValue(Str)])
				found = if (token.is_empty()) Err(NotFound) else Kv.get!("uptime:session:${token}")
				found.is_ok()
			}
			Err(Missing) => Bool.False
		}

	## Ends the session `request` carries.
	sign_out! : Server.Request => {}
	sign_out! = |request|
		match Server.cookie(request, Session.cookie) {
			Ok(token) => Kv.delete!("uptime:session:${token}")
			Err(Missing) => {}
		}
}
