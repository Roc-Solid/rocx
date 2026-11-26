import pf.Server
import pf.Endpoint
import pf.Channel
import presence.PresenceServer
import presence.Wire
import ../../../../../Board
import ../../../../../Middlewares

middleware = Middlewares.member

## /api/b/<board>/presence: who is on the board (packages/presence), as a channel (D-020). A tab is in
## the board's room while it subscribes, as the person the middleware says, in the colour they
## picked; its `data` is the card it has open (`Board.Viewing`, none to start), which its page says
## and every tile shows. The room's hooks are the package's.
channel! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member } => Try(Channel(Wire.Member(Board.Viewing), Wire.Event(Wire.Meta(Board.Viewing)), Wire.Said(Board.Viewing)), Endpoint.Refusal)
channel! = |{ context, .. }| Ok(Channel.allow({ key: context.me.id, meta: { ..Wire.meta(context.me.name, { card: "" }), color: context.me.color } }))

on_open! = PresenceServer.on_open!

on_close! = PresenceServer.on_close!

receive! = PresenceServer.receive!
