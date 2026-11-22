import pf.Server
import pf.Endpoint
import ../../../../../Board
import ../../../../../Middlewares
import ../../../../../PresenceServer

middleware = Middlewares.member

## POST /b/<board>/presence/beat (`tab`, and `card`: the id of the card it has open, or `""`):
## this tab is still here (a tab the room swept out joins again). A page beats every 15 seconds; one
## that stops is swept out.
post! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member, body : { tab : Str, card : Str } } => Try({}, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	status = Board.status_of(if (I64.from_str(body.card).is_ok()) body.card else "")
	_ = PresenceServer.join!(params.board, { key: context.me.id, tab: body.tab, meta: { name: context.me.name, image: "", color: context.me.color, status } })
	Ok({})
}
