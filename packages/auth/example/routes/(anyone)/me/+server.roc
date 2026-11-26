import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../Accounts
import ../../../Middlewares

## GET /me: whether the request is signed in, as whom (the user's id and address), with what (the
## identities they have signed in with), and who really signed in (an admin impersonating them).
get! : { request : Server.Request, params : {}, context : Middlewares.Visitor } => Try({ signed_in : Bool, user : Str, email : Str, identities : List(Str), real_user : Str, impersonating : Bool }, Endpoint.Refusal)
get! = |{ context, .. }|
	match context.signed {
		SignedIn(session) => {
			email =
				match Accounts.user!(session.user) {
					Ok(Found(user)) => user.email
					_ => ""
				}
			identities = (Auth.identities!(session.user) ?? []).map(|identity| "${identity.provider}:${identity.email}")
			Ok({ signed_in: Bool.True, user: session.user, email: email, identities: identities, real_user: session.real_user, impersonating: Auth.impersonating(session) })
		}
		SignedOut => Ok({ signed_in: Bool.False, user: "", email: "", identities: [], real_user: "", impersonating: Bool.False })
	}
