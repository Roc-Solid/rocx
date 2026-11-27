import pf.Server
import pf.Endpoint
import auth.Roles
import ../../../Accounts
import ../../../Middlewares

## GET /pro: for users who hold Pro now, whatever the reason (a gift, a trial); anyone else is
## refused (403). Behind impersonation, the user acted as's: the routes see them.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ welcome : Str }, Endpoint.Refusal)
get! = |{ context, .. }| {
	pro : Accounts.Role
	pro = Pro
	if (Roles.has!(context.user, pro)) Ok({ welcome: context.email }) else Err(Forbidden)
}
