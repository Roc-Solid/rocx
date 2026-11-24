import pf.Actor
import pf.Server
import pf.Endpoint
import pf.Channel
import ../../../Game
import ../../../Rooms
import ../../../Visitor

## GET /rooms/:code: the room as the visitor asking sees it (`Game.Seat`): its view, who they are
## in it, and what they picked for the question being asked. A code with no room is a view whose
## stage is `Vacant`, not a 404: the room's pages say so in their own words.
get! : { request : Server.Request, params : { code : Str }, context : Visitor.Context } => Try(Game.Seat, Endpoint.Refusal)
get! = |{ params, context, .. }| Ok(Rooms.look!(params.code, context.visitor))

## The room's channel (D-020): every view the room's actor publishes (`Rooms.turned!`), to the host's
## screen and every player's phone. Anyone may follow a room that is there; who they are is their
## visitor id, which the hooks hand to the actor. The host asks again every beat (15 s), which
## tells the room the tab is still there.
channel! : { request : Server.Request, params : { code : Str }, context : Visitor.Context } => Try(Channel(Str, Game.View, Game.Said), Endpoint.Refusal)
channel! = |{ request, params, context }|
	match Rooms.look!(params.code, context.visitor).view.stage {
		Vacant => Err(NotFound)
		_ => {
			if Endpoint.channel_asked(request) == "check" {
				Rooms.beat.tell!(params.code, { visitor: context.visitor, tab: Server.header(request, "x-rocx-tab") ?? "" })
			}
			Ok(Channel.allow(context.visitor))
		}
	}

## A tab subscribed (and each time it reconnects): it is in the room (a player's, for presence),
## and its first message is the room as it is now.
on_open! = |{ params, who, tab, .. }|
	match Rooms.opened.ask!(params.code, { visitor: who, tab }) {
		Ok(seat) => [seat.view]
		Err(ActorErr(_)) => []
	}

## A tab's subscription ended: a player whose last tab it was drops, once the grace is up.
on_close! = |{ params, who, tab, .. }| Rooms.closed.tell!(params.code, { visitor: who, tab })

## What a page says: the host's Start, Next and Again, a player's answer. The room decides if they
## may; a refusal is a 409 with why.
receive! = |{ params, who, said, .. }|
	match Rooms.said.ask!(params.code, { visitor: who, said }) {
		Ok(Heard) => Ok({})
		Ok(Refused(why)) => Err(Conflict(why))
		Err(ActorErr(why)) => Err(Conflict(why))
	}
