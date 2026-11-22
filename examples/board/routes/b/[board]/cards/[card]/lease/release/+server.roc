import pf.Server
import pf.Endpoint
import ../../../../../../../Lease
import ../../../../../../../Middlewares
import ../../../../../../../News

middleware = Middlewares.member

## POST /b/<board>/cards/<card>/lease/release, `{ token }`: the lease let go (the card was closed),
## if it was yours. A take that opening sent before, still on its way, takes nothing (`Lease`).
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : { token : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	if Lease.release!(params.card, context.me, body.token) {
		News.tell!(params.board, context.me, "")
		Ok("released")
	} else {
		Ok("not yours")
	}
