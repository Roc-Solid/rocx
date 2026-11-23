import pf.Server
import pf.Endpoint

## POST /api/echo: what was typed, said back louder, and how many characters it has; nothing typed
## is refused (422).
post! : { request : Server.Request, params : {}, context : c, body : { text : Str } } => Try({ shout : Str, length : U64 }, Endpoint.Refusal)
post! = |{ body, .. }|
	if Str.is_empty(body.text) {
		Err(Status(422, "Type something first"))
	} else {
		Ok({ shout: body.text.with_ascii_uppercased(), length: body.text.to_utf8().len() })
	}
