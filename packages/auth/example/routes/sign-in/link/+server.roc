import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../Problem

## GET /sign-in/link?token=…: whom a mailed link signs in, while it is good, without using it (the
## page's button does, posting the token to /auth/link). Used or expired: 410.
get! : { request : Server.Request, params : {}, context : {} } => Try({ email : Str }, Endpoint.Refusal)
get! = |{ request, .. }|
	match Auth.link_for!(Problem.field(request.query, "token")) {
		Ok(link) => Ok({ email: link.email })
		Err(Gone) => Err(Status(410, "This sign-in link has been used, or it has expired. Ask for another."))
	}
