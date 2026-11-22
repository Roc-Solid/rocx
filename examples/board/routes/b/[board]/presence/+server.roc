import pf.Server
import pf.Endpoint
import pf.Events
import presence.Wire
import ../../../../Middlewares
import ../../../../PresenceServer

middleware = Middlewares.member

## GET /b/<board>/presence: who is on the board, as events (packages/presence): this tab is in the
## board's room, as the person the middleware says, until its page goes. Each change to who is here,
## and to which card each has open (their `status`), comes as it happens.
events! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member } => Try(Events(Wire.Event(Wire.Meta)), Endpoint.Refusal)
events! = |{ params, context, .. }| Ok(PresenceServer.stream(params.board, { key: context.me.id, meta: { name: context.me.name, image: "", color: context.me.color, status: "" } }))
