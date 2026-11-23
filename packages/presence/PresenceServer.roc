import pf.Channel
import pf.Endpoint
import pf.Kv
import pf.Log
import pf.Time
import Mirror
import Room
import Wire

## A room's presence on the server: the hooks of a route's channel (D-020), whose URL is the room.
## Its check lets a member in (`Channel.allow`, with who they are: their key and metadata, from the
## middleware's context, never from the page), and these three are its hooks:
##
##     on_open! = PresenceServer.on_open!
##     on_close! = PresenceServer.on_close!
##     receive! = PresenceServer.receive!
##
## A tab joins as its subscription opens (and gets its key and tab, then who is here), and leaves
## when it ends: at once when its page dropped the room (`Dropped`: it went to another room), after
## the room's grace when its stream went (`Gone`: a reload or a reconnect comes back within it). The
## host tells a tab's hooks in order, an old subscription's end before a new one's start.
## A page says it is here every `Room.beat_every`, with its status (`Here`), so a tab whose page
## vanished without a word (a laptop shut, a network gone) is swept out 75 s after its last word,
## however long its connection lingers. Typing and cursors are said, and passed on, never kept.
##
## The room is kept in the server's memory (`Kv`, under `presence:<the channel's URL>`), as a
## `Room`: each change reads it, sweeps it, changes it and swaps it back (`Kv.swap!`), so two tabs
## joining at once both count, and nothing is written to Postgres. What changed is published on the
## channel, numbered; a page that misses a number asks for a snapshot again (`Endpoint.resync!`).
## A room nobody beats in for a quarter of an hour is forgotten; one made again numbers on from the
## time, so a page's copy sees the gap and asks again.
PresenceServer := [].{

	## A room's channel: who its members are, what they hear, and what they say.
	RoomChannel(c) : Endpoint(c, {}, Channel(Wire.Member, Wire.Event(Wire.Meta), Wire.Said))

	## A tab subscribed (or asked for a resync): it is in the room, with the member's metadata (the
	## status the member had, if they were here already), and it is sent its key and tab, then who is
	## here.
	on_open! : { who : Wire.Member, tab : Str, channel : PresenceServer.RoomChannel(c), .. } => List(Wire.Event(Wire.Meta))
	on_open! = |{ who, tab, channel, .. }| {
		room = changed!(
			channel,
			|before, now| {
				status =
					match before.members().find_first(|member| member.key == who.key) {
						Ok(member) => member.meta.status
						Err(_) => who.meta.status
					}
				before.join({ key: who.key, tab, meta: { ..who.meta, status }, now })
			},
		)
		[Welcome({ key: who.key, tab }), Presence(Mirror.snapshot(room))]
	}

	## A tab's subscription ended: it leaves at once if its page dropped the room (`Dropped`), else
	## after the room's grace (a page reloading or reconnecting doesn't flicker out and in).
	on_close! : { who : Wire.Member, tab : Str, why : Channel.Closed, channel : PresenceServer.RoomChannel(c), .. } => {}
	on_close! = |{ who, tab, why, channel, .. }| {
		_ = changed!(
			channel,
			|before, now|
				match why {
					Dropped => before.quit(who.key, tab, now)
					_ => before.leave(who.key, tab, now)
				},
		)
		{}
	}

	## What a page said: its tab is here, with its status (and back, if the room had swept it out);
	## its member is typing, or stopped; its cursor moved (latest wins); its pointer left.
	receive! : { who : Wire.Member, tab : Str, said : Wire.Said, channel : PresenceServer.RoomChannel(c), .. } => Try({}, Endpoint.Refusal)
	receive! = |{ who, tab, said, channel, .. }| {
		match said {
			Here({ status }) => {
				_ = changed!(channel, |before, now| before.join({ key: who.key, tab, meta: { ..who.meta, status }, now }))
				{}
			}
			Typing(typing) => Endpoint.publish!(channel, Typing({ key: who.key, typing }))
			Moved({ x, y }) => Endpoint.publish_latest!(channel, who.key, Moved({ key: who.key, x, y }))
			Away => Endpoint.publish!(channel, Away(who.key))
		}
		Ok({})
	}
}

## How many times a change reads the room again when another changed it first.
tries : U64
tries = 50

## How long a room is kept after its last change: a quarter of an hour.
keep_ms : U64
keep_ms = 900_000

## Where the room on `channel` is kept.
key_of : PresenceServer.RoomChannel(c) -> Str
key_of = |channel| "presence:${Endpoint.url_of(channel)}"

## The room kept, or a new one, numbering on from `now`.
stored! : Try(Str, [NotFound, BadValue(Str)]), U64 => Room(Wire.Meta)
stored! = |kept, now| {
	text = kept ?? ""
	parsed : Try(Room.Saved(Wire.Meta), [InvalidJson(Str)])
	parsed = Json.parse(text)
	match parsed {
		Ok(saved) => Room.load(saved)
		Err(_) => Room.load({ members: [], version: now, settings: Room.defaults })
	}
}

## The room on `channel`, swept, then changed by `step`, kept, and what changed published on the
## channel: the room as it is now.
changed! : PresenceServer.RoomChannel(c), (Room(Wire.Meta), U64 -> (Room(Wire.Meta), List(Room.Change(Wire.Meta)))) => Room(Wire.Meta)
changed! = |channel, step| {
	at = key_of(channel)
	var $left = tries
	var $last = Room.empty(Room.defaults)
	while $left > 0 {
		was : Try(Str, [NotFound, BadValue(Str)])
		was = Kv.get!(at)
		now = Time.now_millis!({})
		(swept, gone) = stored!(was, now).sweep(now)
		(after, said) = step(swept, now)
		next = Json.to_str(after.save())
		kept =
			match was {
				Ok(text) => Kv.swap!(at, text, next, { ttl_ms: keep_ms })
				Err(_) => Kv.add!(at, next, { ttl_ms: keep_ms }).map_err(|_| Changed)
			}
		if kept.is_ok() {
			for message in Mirror.deltas(after, gone.concat(said)) {
				event : Wire.Event(Wire.Meta)
				event = Presence(message)
				Endpoint.publish!(channel, event)
			}
			return after
		}
		$last = after
		$left = $left - 1
	}
	Log.warn!("presence: a room changed under each try", { room: at, tries })
	$last
}
