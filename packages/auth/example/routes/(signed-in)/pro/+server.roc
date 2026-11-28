import pf.Server
import pf.Endpoint
import ../../../Middlewares
import ../../../Policy

## GET /pro: for users who hold Pro now, whatever the reason (a gift, a trial): `Policy`'s
## `UsePro`, from the roles the middleware read. Anyone else is refused (403). Behind
## impersonation, the user acted as's: the routes see them.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ welcome : Str }, Endpoint.Refusal)
get! = |{ context, .. }| {
	Policy.need(context, UsePro)?
	Ok({ welcome: context.email })
}
