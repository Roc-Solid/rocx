import pf.Server
import pf.Endpoint
import ../../../Accounts
import ../../../Middlewares

## Anyone may ask: signed out, the answer is "".
## GET /api/me: who is signed in, for the layout's bar: their address, or "" for nobody.
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
