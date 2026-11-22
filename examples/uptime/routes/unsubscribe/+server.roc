import pf.Server
import pf.Endpoint
import ../../Store

## POST /unsubscribe, from the page an alert's link opens: the subscriber whose `token` it is stops
## getting alerts. Their address, to say so.
post! : { request : Server.Request, params : {}, context : {}, body : { token : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match Store.unsubscribe!(body.token) {
		Ok(email) => Ok(email)
		Err(NotFound) => Err(BadRequest("This link has been used already, or it isn't whole."))
		Err(problem) => Err(Store.refused!(problem))
	}
