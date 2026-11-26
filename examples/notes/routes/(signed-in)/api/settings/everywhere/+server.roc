import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../../../Middlewares
import ../../../../../Store

## POST /api/settings/everywhere: signed out on every browser, this one too (packages/auth's
## `Auth.sign_out_everywhere!` ends every session of yours), and on to signing in again. Tokens
## stay: revoke those one by one.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try(Server.Response, Endpoint.Refusal)
post! = |{ request, context, .. }|
	match Auth.sign_out_everywhere!(context.person.id) {
		Ok(_) => Ok(Auth.sign_out!(request, Server.redirect("/sign-in")))
		Err(DbErr(why)) => Err(Store.refused!(DbErr(why)))
	}
