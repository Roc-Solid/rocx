import pf.Server
import pf.Endpoint

## GET /things/<id>, for JSON: a thing; one that isn't there, 404; a shelf that is down, 503.
get! : { request : Server.Request, params : { id : Str }, context : { started : Str } } => Try(Str, Endpoint.Refusal)
get! = |{ params, .. }|
	match params.id {
		"gone" => Err(NotFound)
		"down" => Err(Status(503, "the shelf is down"))
		id => Ok("Thing ${id}")
	}
