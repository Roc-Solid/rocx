import pf.Server
import pf.Endpoint
import pf.Log
import auth.Auth
import ../../../../../Middlewares

## Signed-in requests only: it is the user's own.
## POST /api/account/two-factor: sets up two-factor sign-in: a new secret for an authenticator app,
## which the account page shows (as a QR code, and as a key to type in) until the app's first code
## turns it on (`confirm/`).
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ context, .. }|
	match Auth.two_factor_start!(context.user.id, context.user.email) {
		Ok(_) => Ok({})
		Err(AlreadyOn) => Err(Conflict("Two-factor sign-in is on already."))
		Err(NotOffered) => Err(NotFound)
		Err(DbErr(why)) | Err(BadRow(why)) => {
			Log.error!("account: two-factor sign-in couldn't be set up", { error: why })
			Err(Status(503, "It couldn't be set up just now. Try again in a minute."))
		}
	}
