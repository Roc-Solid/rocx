import pf.Server
import pf.Endpoint
import ../../../Push

## GET /push/key: the server's VAPID public key, for the page to subscribe with.
get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
get! = |_| {
	key = Push.public_key!({})
	if key.is_empty() {
		Err(Status(503, "the server has no VAPID_PUBLIC_KEY"))
	} else {
		Ok(key)
	}
}
