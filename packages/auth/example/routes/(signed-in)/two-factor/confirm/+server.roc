import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../../Middlewares

## POST /two-factor/confirm: the first code the authenticator app shows turns two-factor sign-in
## on, and gives the user's ten recovery codes, once.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { code : Str } } => Try({ recovery_codes : List(Str) }, Endpoint.Refusal)
post! = |{ context, body, .. }|
	if context.user != context.real_user {
		Err(Forbidden)
	} else {
		match Auth.two_factor_confirm!(context.user, body.code) {
			Ok(codes) => Ok({ recovery_codes: codes })
			Err(WrongCode) => Err(BadRequest("That isn't the code your app shows now."))
			Err(NotStarted) => Err(Conflict("Start turning two-factor sign-in on first."))
			Err(AlreadyOn) => Err(Conflict("Two-factor sign-in is on already."))
			Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
		}
	}
