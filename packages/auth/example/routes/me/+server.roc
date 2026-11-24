import pf.Server
import pf.Endpoint
import auth.Auth
import ../../Accounts
import ../../Middlewares

middleware = Middlewares.anyone

## GET /me: whether the request is signed in, as whom (the user's id and address), and with what
## (the identities they have signed in with).
get! : { request : Server.Request, params : {}, context : Middlewares.Visitor } => Try({ signed_in : Bool, user : Str, email : Str, identities : List(Str) }, Endpoint.Refusal)
get! = |{ context, .. }|
	match context.signed {
		SignedIn(session) => {
			email =
				match Accounts.user!(session.user) {
					Ok(Found(user)) => user.email
					_ => ""
				}
			identities = (Auth.identities!(session.user) ?? []).map(|identity| "${identity.provider}:${identity.email}")
			Ok({ signed_in: Bool.True, user: session.user, email: email, identities: identities })
		}
		SignedOut => Ok({ signed_in: Bool.False, user: "", email: "", identities: [] })
	}
