import pf.Server
import pf.Endpoint
import ../../../Codes
import ../../../Entry
import ../../../Joining
import ../../../Visitor

## What POST /play/:code is sent: the name to play under, read and checked by `Joining.named`
## (D-093).
post_body = Joining.named

## POST /play/:code, from a room's own page (`name`): into the room as one of its players. A code
## is written as people type it (`bk-rt` is BKRT), so the path's is read here, not by its type.
post! : { request : Server.Request, params : { code : Str }, context : Visitor.Context, body : { name : Str } } => Try({}, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	match Codes.parse(params.code) {
		Ok(code) => Entry.join!(context, code, body.name)
		Err(BadCode) => Err(NotFound)
	}
