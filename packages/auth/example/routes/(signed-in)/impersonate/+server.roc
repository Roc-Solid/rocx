import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../Middlewares
import ../../../Policy

## POST /impersonate: an admin (`Policy`'s `Impersonate`: on `ADMIN_EMAILS`, as who really signed in) acts as the user with
## address `email` for half an hour (`Auth.impersonate!`); anyone else is refused (403).
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { email : Str } } => Try({ acting_as : Str }, Endpoint.Refusal)
post! = |{ request, context, body, .. }| {
	Policy.need(context, Impersonate)?
	match Auth.user_by_email!(body.email) {
		Ok(user) =>
			match Auth.impersonate!(request, user.id, 30 * 60 * 1000) {
				Ok({}) => Ok({ acting_as: user.email })
				Err(SignedOut) => Err(Unauthorized)
				Err(DbErr(why)) => Err(Status(503, why))
			}
		Err(NotFound) => Err(NotFound)
		Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
	}
}
