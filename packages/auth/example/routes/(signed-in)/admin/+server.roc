import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../Accounts
import ../../../Middlewares

## GET /admin: for admins (`ADMIN_EMAILS`, as who really signed in) with two-factor sign-in on; an
## admin without it is told to turn it on (403), anyone else refused. Who must have it is the
## app's to say: the package only answers whether it is on (`Auth.two_factor!`).
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ admin : Str }, Endpoint.Refusal)
get! = |{ context, .. }|
	if !Accounts.admin!(context.real_user) {
		Err(Forbidden)
	} else {
		match Auth.two_factor!(context.real_user) {
			Ok(On(_)) => Ok({ admin: context.real_user })
			Ok(_) => Err(Status(403, "Turn on two-factor sign-in first, at /two-factor."))
			Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(503, why))
		}
	}
