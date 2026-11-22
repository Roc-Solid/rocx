import pf.Db
import pf.Env
import pf.Kv
import pf.Random
import pf.Server
import pf.Time
import crypto.Hex
import crypto.Hmac
import crypto.Sha256

## Who may use the diary. Without `PLATE_PASSWORD` set it is open, as an app on your own machine
## is. With it, signing in with that password gives the browser a random token in a cookie
## (`plate_session`, HttpOnly, 90 days), whose SHA-256 is kept in the database (`sessions`), so a
## phone stays signed in across restarts and the table alone signs nobody in.
##
## The server doesn't pass each client's tries apart, so ten wrong passwords a minute are allowed
## in all, then the form says to wait.
Session := [].{

	## The cookie a session's token is kept in.
	cookie : Str
	cookie = "plate_session"

	## How long a session lasts: 90 days.
	days : U64
	days = 90

	## Whether the diary needs no sign-in: `PLATE_PASSWORD` isn't set.
	open! : {} => Bool
	open! = |{}|
		match Env.var!("PLATE_PASSWORD") {
			Ok(password) => password.is_empty()
			Err(NotFound) => Bool.True
		}

	## Signs in with `password`: the new session's token, for the cookie.
	sign_in! : Str => Try(Str, [Wrong, Open, TooMany, DbErr(Str)])
	sign_in! = |password| {
		tries = Kv.increment!("plate:sign-in-tries", 1, { ttl_ms: 60_000 }) ?? 0
		match Env.var!("PLATE_PASSWORD") {
			Err(NotFound) => Err(Open)
			Ok("") => Err(Open)
			Ok(_) if tries > 10 => Err(TooMany)
			Ok(wanted) =>
				if Hmac.equal(wanted.to_utf8(), password.to_utf8()) {
					token = Hex.encode(Random.bytes!(24))
					now = Time.now_millis!({}).to_i64_wrap()
					_ = Db.run!("delete from sessions where expires_at < $1", [Int(now)])?
					_ = Db.run!(
						"insert into sessions (token_hash, expires_at) values ($1, $2)",
						[Text(hashed(token)), Int(now + Session.days.to_i64_wrap() * 86_400_000)],
					)?
					Ok(token)
				} else {
					Err(Wrong)
				}
		}
	}

	## Whether `request` carries a session's token that hasn't run out.
	signed_in! : Server.Request => Bool
	signed_in! = |request|
		match Server.cookie(request, Session.cookie) {
			Ok(token) if !token.is_empty() => {
				found : Try(List({ token_hash : Str }), [DbErr(Str), BadRow(Str)])
				found = Db.all!("select token_hash from sessions where token_hash = $1 and expires_at > $2", [Text(hashed(token)), Int(Time.now_millis!({}).to_i64_wrap())])
				match found {
					Ok(rows) => !rows.is_empty()
					Err(_) => Bool.False
				}
			}
			_ => Bool.False
		}

	## Ends the session `request` carries.
	sign_out! : Server.Request => {}
	sign_out! = |request|
		match Server.cookie(request, Session.cookie) {
			Ok(token) => {
				_ = Db.run!("delete from sessions where token_hash = $1", [Text(hashed(token))])
				{}
			}
			Err(Missing) => {}
		}

	## The answer, with the session's cookie set: for 90 days, out of scripts' reach.
	keep : Server.Response, Str -> Server.Response
	keep = |answer, token| Server.set_cookie(answer, Session.cookie, token, { ..Server.cookie_defaults, max_age_s: Session.days * 86_400 })
}

hashed : Str -> Str
hashed = |token| Sha256.hex(Sha256.hash(token.to_utf8()))
