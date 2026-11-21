import pf.Server
import pf.Endpoint
import ../../../Push

## POST /push/unsubscribe: forgets the subscription at `endpoint`.
post! : { request : Server.Request, params : {}, context : c, body : { endpoint : Str } } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	match Push.unsubscribe!(body.endpoint, "") {
		Ok({}) => Ok({})
		Err(DbErr(why)) => Err(Status(500, why))
	}
