import pf.Server
import pf.Endpoint
import ../../../../../Board
import ../../../../../Middlewares
import ../../../../../PresenceServer

middleware = Middlewares.member

## POST /b/<board>/presence/status (`card`: the id of the card this page has open, or `""`): every
## page on the board shows who has which card open.
post! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member, body : { card : Str } } => Try({}, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	card = if (I64.from_str(body.card).is_ok()) body.card else ""
	_ = PresenceServer.update!(params.board, context.me.id, { name: context.me.name, image: "", color: context.me.color, status: Board.status_of(card) })
	Ok({})
}
