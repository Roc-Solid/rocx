import pf.Server
import pf.Endpoint
import push.Subscription
import ../../../Push

## POST /push/subscribe: keeps the subscription the page posted. This app has no accounts, so the
## owner is "" (a visitor); an app with them gives its user's id.
post! : { request : Server.Request, params : {}, context : c, body : Subscription.Body } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	match Push.subscribe!(body, "") {
		Ok({}) => Ok({})
		Err(Invalid(why)) => Err(BadRequest(why))
		Err(DbErr(why)) => Err(Status(500, why))
	}
