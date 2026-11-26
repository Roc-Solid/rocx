import pf.Server
import pf.Endpoint
import pf.Log
import pf.Time
import auth.Auth
import ../../../../Accounts
import ../../../../Middlewares

## Signed-in requests only: the account page's reads and posts are the user's own. (The page, at
## /account, names the same middleware.)
## GET /api/account: the signed-in user's address, their sessions (a browser each), the newest first
## (whether it is this browser's, and when it started), and their two-factor sign-in: its `state`,
## `off`, `pending` (set up, waiting for the app's first code: the key, and the URI its QR code
## holds) or `on` (with the recovery codes left).
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ email : Str, sessions : List({ id : Str, current : Bool, started : Str }), two_factor : { state : Str, secret : Str, uri : Str, recovery_codes : U64 } }, Endpoint.Refusal)
get! = |{ context, .. }|
	match (Auth.sessions!(context.user.id), two_factor!(context.user)) {
		(Ok(sessions), Ok(two_factor)) => {
			now = Time.now_millis!({}).to_i64_wrap()
			Ok({ email: context.user.email, sessions: sessions.map(|session| { id: session.id, current: session.id == context.session, started: Accounts.ago(now, session.created_ms) }), two_factor: two_factor })
		}
		(Err(DbErr(why)), _) | (Err(BadRow(why)), _) | (_, Err(DbErr(why))) | (_, Err(BadRow(why))) => {
			Log.error!("account: it couldn't be read", { error: why })
			Err(Status(503, "Your account couldn't be read just now. Try again in a minute."))
		}
	}

## `user`'s two-factor sign-in, for the page.
two_factor! : Accounts.User => Try({ state : Str, secret : Str, uri : Str, recovery_codes : U64 }, [DbErr(Str), BadRow(Str)])
two_factor! = |user|
	match Auth.two_factor!(user.id)? {
		On({ recovery_codes, .. }) => Ok({ state: "on", secret: "", uri: "", recovery_codes: recovery_codes })
		Pending =>
			match Auth.two_factor_pending!(user.id, user.email) {
				Ok(pending) => Ok({ state: "pending", secret: pending.secret, uri: pending.uri, recovery_codes: 0 })
				Err(NotPending) => Ok({ state: "off", secret: "", uri: "", recovery_codes: 0 })
				Err(DbErr(why)) => Err(DbErr(why))
				Err(BadRow(why)) => Err(BadRow(why))
			}
		Off => Ok({ state: "off", secret: "", uri: "", recovery_codes: 0 })
	}

## POST /api/account, from the account page's "Sign out everywhere" form: signed out everywhere,
## this browser too, and on to the sign-in page.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ request, context, .. }|
	match Auth.sign_out_everywhere!(context.user.id) {
		Ok(_) => Err(Answer(Auth.sign_out!(request, Server.redirect("/sign-in"))))
		Err(DbErr(why)) => {
			Log.error!("account: sessions couldn't be ended", { error: why })
			Err(Status(503, "You couldn't be signed out just now. Try again in a minute."))
		}
	}
