import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../Accounts

## GET /sign-in/code: whom the sign-in waiting in this browser is for (their address), and how many
## more wrong codes it may have; 410 when none waits (it took over ten minutes, or there was none).
get! : { request : Server.Request, params : {}, context : {} } => Try({ email : Str, tries_left : U64 }, Endpoint.Refusal)
get! = |{ request, .. }|
	match Auth.waiting!(request) {
		Ok(waiting) =>
			match Accounts.user!(waiting.user) {
				Ok(Found(user)) => Ok({ email: user.email, tries_left: waiting.tries_left })
				_ => Err(Status(410, "Sign in again."))
			}
		Err(SignedOut) => Err(Status(410, "No sign-in is waiting for a code here. Sign in again."))
	}
