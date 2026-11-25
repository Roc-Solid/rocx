import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../Middlewares

middleware = Middlewares.signed_in

## POST /impersonate/stop: the session acts as whoever really signed in again.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({ user : Str }, Endpoint.Refusal)
post! = |{ request, context, .. }|
	match Auth.stop_impersonating!(request) {
		Ok({}) => Ok({ user: context.real_user })
		Err(SignedOut) => Err(Unauthorized)
		Err(DbErr(why)) => Err(Status(503, why))
	}
