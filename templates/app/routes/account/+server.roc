import pf.Server
import pf.Endpoint
import pf.Log
import pf.Time
import auth.Auth
import ../../Accounts
import ../../Middlewares

## Signed-in requests only: the page's reads and posts are the user's own.
middleware = Middlewares.signed_in

## GET /account: the signed-in user's address, and their sessions (a browser each), the newest
## first: whether it is this browser's, and when it started.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ email : Str, sessions : List({ id : Str, current : Bool, started : Str }) }, Endpoint.Refusal)
get! = |{ context, .. }|
	match Auth.sessions!(context.user.id) {
		Ok(sessions) => {
			now = Time.now_millis!({}).to_i64_wrap()
			Ok({ email: context.user.email, sessions: sessions.map(|session| { id: session.id, current: session.id == context.session, started: Accounts.ago(now, session.created_ms) }) })
		}
		Err(DbErr(why)) | Err(BadRow(why)) => {
			Log.error!("account: sessions couldn't be read", { error: why })
			Err(Status(503, "Your sessions couldn't be read just now. Try again in a minute."))
		}
	}

## POST /account: signed out everywhere, this browser too, and on to the sign-in page.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ request, context, .. }|
	match Auth.sign_out_everywhere!(context.user.id) {
		Ok(_) => Err(Answer(Auth.sign_out!(request, Server.redirect("/sign-in"))))
		Err(DbErr(why)) => {
			Log.error!("account: sessions couldn't be ended", { error: why })
			Err(Status(503, "You couldn't be signed out just now. Try again in a minute."))
		}
	}
