import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../../Middlewares

## POST /two-factor/recovery-codes: ten new recovery codes in place of the old ones, given a code
## the authenticator app shows now (or a recovery code).
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { code : Str } } => Try({ recovery_codes : List(Str) }, Endpoint.Refusal)
post! = |{ context, body, .. }|
	if context.user != context.real_user {
		Err(Forbidden)
	} else {
		match Auth.two_factor_regenerate!(context.user, body.code) {
			Ok(codes) => Ok({ recovery_codes: codes })
			Err(WrongCode) => Err(BadRequest("That code didn't work."))
			Err(NotOn) => Err(Conflict("Two-factor sign-in isn't on."))
			Err(TooManyTries) => Err(Status(429, "Too many wrong codes in a row. Wait a quarter of an hour."))
			Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
		}
	}
