import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../../Accounts

## GET /api/sign-in/code: whom the sign-in waiting in this browser for its code is for (their
## address); 410 when none waits (it waited over ten minutes, or there was none).
get! : { request : Server.Request, params : {}, context : {} } => Try({ email : Str }, Endpoint.Refusal)
get! = |{ request, .. }|
	match Auth.waiting!(request) {
		Ok(waiting) =>
			match Accounts.user!(waiting.user) {
				Ok(Found(user)) => Ok({ email: user.email })
				_ => Err(Status(410, "Sign in again."))
			}
		Err(SignedOut) => Err(Status(410, "No sign-in is waiting for a code here. Sign in again."))
	}
