import pf.Server
import pf.Endpoint
import auth.Auth
import ../../Middlewares

## Signed-in requests only, and the person's own: while an admin impersonates someone, these
## refuse (403), as only the person may change how they sign in.
middleware = Middlewares.signed_in

## GET /two-factor: whether the user's two-factor sign-in is on (`state`: off, pending or on), how
## many unused recovery codes they have, and while it waits for its first code, the secret again
## (`secret`, "" otherwise), for a page shown again.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ state : Str, recovery_codes : U64, secret : Str }, Endpoint.Refusal)
get! = |{ context, .. }|
	match Auth.two_factor!(context.user) {
		Ok(Off) => Ok({ state: "off", recovery_codes: 0, secret: "" })
		Ok(Pending) =>
			match Auth.two_factor_pending!(context.user, context.email) {
				Ok(pending) => Ok({ state: "pending", recovery_codes: 0, secret: pending.secret })
				Err(NotPending) => Ok({ state: "off", recovery_codes: 0, secret: "" })
				Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
			}
		Ok(On({ recovery_codes, .. })) => Ok({ state: "on", recovery_codes: recovery_codes, secret: "" })
		Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
	}

## POST /two-factor: starts turning it on: a new secret, for the authenticator app (the
## `otpauth://` URI, as a QR code, or the secret typed in), which `/two-factor/confirm` turns on
## with its first code.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({ secret : Str, uri : Str }, Endpoint.Refusal)
post! = |{ context, .. }|
	if context.user != context.real_user {
		Err(Forbidden)
	} else {
		match Auth.two_factor_start!(context.user, context.email) {
			Ok(started) => Ok(started)
			Err(AlreadyOn) => Err(Conflict("Two-factor sign-in is on already."))
			Err(NotOffered) => Err(NotFound)
			Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
		}
	}
