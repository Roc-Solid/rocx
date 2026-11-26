import pf.Server
import pf.Endpoint
import auth.Auth
import ../../../../Query

## Who `?token=` signs in, while the link is good: what its page asks you to confirm
## (`Auth.link_for!`, which doesn't use the link). Used or expired: 410. The page's button posts the
## token to packages/auth's /auth/link, which uses it.
get! : { request : Server.Request, params : {}, context : {} } => Try({ email : Str }, Endpoint.Refusal)
get! = |{ request, .. }|
	match Auth.link_for!(Query.value(request.query, "token")) {
		Ok(link) => Ok({ email: link.email })
		Err(Gone) => Err(Status(410, "This sign-in link has been used, or it has expired. Ask for another."))
	}
