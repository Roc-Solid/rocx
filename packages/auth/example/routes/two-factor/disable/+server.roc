import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../Middlewares

middleware = Middlewares.signed_in

## POST /two-factor/disable: a code the authenticator app shows now, or a recovery code, turns
## two-factor sign-in off.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { code : Str } } => Try({}, Endpoint.Refusal)
post! = |{ context, body, .. }|
	if context.user != context.real_user {
		Err(Forbidden)
	} else {
		match Auth.two_factor_disable!(context.user, body.code) {
			Ok({}) => Ok({})
			Err(WrongCode) => Err(BadRequest("That code didn't work."))
			Err(NotOn) => Err(Conflict("Two-factor sign-in isn't on."))
			Err(TooManyTries) => Err(Status(429, "Too many wrong codes in a row. Wait a quarter of an hour."))
			Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
		}
	}
