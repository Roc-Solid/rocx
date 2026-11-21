import pf.Server
import pf.Endpoint

## POST /api/shout: what it is sent, shouted. Nothing to shout is refused, with a 400.
post! : { request : Server.Request, params : {}, context : c, body : Str } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	if (body.trim().is_empty()) Err(BadRequest("say something to shout")) else Ok(body.with_ascii_uppercased())
