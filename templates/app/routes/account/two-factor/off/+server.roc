import pf.Server
import pf.Endpoint
import pf.Log
import auth.Auth
import ../../../../Middlewares

middleware = Middlewares.signed_in

## POST /account/two-factor/off: a code the authenticator app shows now, or a recovery code, turns
## two-factor sign-in off.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { code : Str } } => Try({}, Endpoint.Refusal)
post! = |{ context, body, .. }|
	match Auth.two_factor_disable!(context.user.id, body.code) {
		Ok({}) => Ok({})
		Err(WrongCode) => Err(BadRequest("That code didn't work: enter the one your app shows now, or a recovery code."))
		Err(NotOn) => Err(Conflict("Two-factor sign-in is off already."))
		Err(TooManyTries) => Err(Status(429, "Too many wrong codes in a row. Wait a quarter of an hour, then try again."))
		Err(DbErr(why)) | Err(BadRow(why)) => {
			Log.error!("account: two-factor sign-in couldn't be turned off", { error: why })
			Err(Status(503, "It couldn't be turned off just now. Try again in a minute."))
		}
	}
