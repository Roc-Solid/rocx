import pf.Server
import pf.Endpoint
import ../../../Accounts
import ../../../Middlewares

## GET /api: who is signed in (their address; "" when nobody is).
get! : { request : Server.Request, params : {}, context : Middlewares.Visitor } => Try({ email : Str }, Endpoint.Refusal)
get! = |{ context, .. }|
	match context.signed {
		SignedIn(session) =>
			match Accounts.user!(session.user) {
				Ok(Found(user)) => Ok({ email: user.email })
				_ => Ok({ email: "" })
			}
		SignedOut => Ok({ email: "" })
	}
