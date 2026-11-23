import pf.Server
import pf.Endpoint
import pf.Channel
import presence.PresenceServer
import presence.Wire
import ../../../../Middlewares

middleware = Middlewares.member

## /b/<board>/presence: who is on the board (packages/presence), as a channel (D-020). A tab is in
## the board's room while it subscribes, as the person the middleware says; its status is the card
## it has open (`Board.status_of`), which every tile shows. The room's hooks are the package's.
channel! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member } => Try(Channel(Wire.Member({}), Wire.Event(Wire.Meta({})), Wire.Said), Endpoint.Refusal)
channel! = |{ context, .. }| Ok(Channel.allow({ key: context.me.id, meta: { name: context.me.name, image: "", color: context.me.color, status: "", data: {} } }))

on_open! = PresenceServer.on_open!

on_close! = PresenceServer.on_close!

receive! = PresenceServer.receive!
