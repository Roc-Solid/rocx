import pf.Server
import pf.Endpoint
import pf.Log
import auth.Auth
import ../../../../../../Middlewares

## POST /api/account/two-factor/confirm: the code the authenticator app shows turns two-factor
## sign-in on. The answer is the user's ten recovery codes, which the page shows this once.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { code : Str } } => Try({ recovery_codes : List(Str) }, Endpoint.Refusal)
post! = |{ context, body, .. }|
	match Auth.two_factor_confirm!(context.user.id, body.code) {
		Ok(codes) => Ok({ recovery_codes: codes })
		Err(WrongCode) => Err(BadRequest("That isn't the code your app shows. Enter the newest one."))
		Err(NotStarted) => Err(Conflict("Set it up again: that key has gone."))
		Err(AlreadyOn) => Err(Conflict("Two-factor sign-in is on already."))
		Err(DbErr(why)) | Err(BadRow(why)) => {
			Log.error!("account: two-factor sign-in couldn't be turned on", { error: why })
			Err(Status(503, "It couldn't be turned on just now. Try again in a minute."))
		}
	}
