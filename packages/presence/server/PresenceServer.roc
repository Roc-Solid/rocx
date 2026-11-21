import pf.Actor
import pf.Events
import pf.Live
import pf.Random
import pf.Time
import presence.Mirror
import presence.Room
import presence.Wire

## A room's presence on the server, with what the platform has today. The room is an actor (`Actor`:
## one message at a time, so two tabs joining at once both count), its state a `Room`; what changes
## is published on the room's topic (`Live`) by the actor, as it changes, so the changes go out in
## the order they were numbered; each page's stream listens to the topic and sends them on. A
## page's stream is its tab in the room: it joins when the stream opens, and leaves when its page
## goes. A page beats with `join!` every `Room.beat_every` (15 s), so a tab whose page vanished
## without a word (a laptop shut, a network gone) is swept out 75 s after its last beat. (Its stream
## doesn't count as a beat: with the network gone, a stream's end may never reach the server.)
##
## Who a member is (their key and metadata) is the server's say: the endpoint and the server
## functions read it from the middleware's context, never from what a page sends.
##
## Server-only: it imports `Actor` and `Live`, which only the server's platform has. See
## PROPOSALS.md, "Server-only modules in packages".
PresenceServer := [].{

	## The kind of actor that keeps a room: the defaults (`Room.defaults`); every ask sweeps first, so a
	## room someone joins is never stale. What changes is published as it changes, in the actor's
	## turn; a snapshot is the reply. (`rocx build` lists it in the app's `program.actors`.)
	kind : {} -> Actor.Kind(Room.Saved(Wire.Meta), PresenceServer.Ask, List(Mirror.Message(Wire.Meta)))
	kind = |{}|
		Actor.define({
			name: "presence",
			initial: |_| Room.empty(Room.defaults).save(),
			receive!: |_me, saved, { room, ask }| {
				now = Time.now_millis!({})
				(swept, gone) = Room.load(saved).sweep(now)
				(next, changes) =
					match ask {
						Signal(signal) => {
							(signalled, said) = swept.signal(signal, now)
							(signalled, gone.concat(said))
						}
						_ => (swept, gone)
					}
				for message in Mirror.deltas(next, changes) {
					event : Wire.Event(Wire.Meta)
					event = Presence(message)
					Live.publish!(Wire.topic(room), Json.to_str(event))
				}
				reply =
					match ask {
						Snapshot => [Mirror.snapshot(next)]
						_ => []
					}
				{ state: next.save(), reply }
			},
		})

	## What a room's actor is asked: a signal (a join, a beat, a leave, new metadata), a sweep, or
	## who is here; and the room's name, which its topic is named for.
	Ask : { room : Str, ask : [Signal(Room.Signal(Wire.Meta)), Sweep, Snapshot] }

	## The room called `room`, and its streams, told `signal`.
	tell! : Str, Room.Signal(Wire.Meta) => Try({}, [ActorErr(Str)])
	tell! = |room, signal| {
		_ = Actor.ask!(PresenceServer.kind({}), room, { room, ask: Signal(signal) })?
		Ok({})
	}

	## `key`'s tab `tab` is in `room` with `meta`, from now: what a page's beat says (a tab the room
	## had swept out joins again).
	join! : Str, { key : Str, tab : Str, meta : Wire.Meta } => Try({}, [ActorErr(Str)])
	join! = |room, me| PresenceServer.tell!(room, Join(me))

	## `key`'s metadata in `room` is now `meta`: their status, say.
	update! : Str, Str, Wire.Meta => Try({}, [ActorErr(Str)])
	update! = |room, key, meta| PresenceServer.tell!(room, Update({ key, meta }))

	## `key` is typing in `room`, or stopped.
	typing! : Str, Str, Bool => {}
	typing! = |room, key, typing| Live.publish!(Wire.topic(room), Json.to_str(Typing({ key, typing })))

	## `key`'s cursor in `room` moved to (`x`, `y`): shares of the area, from 0 to 1.
	moved! : Str, Str, { x : Dec, y : Dec } => {}
	moved! = |room, key, { x, y }| Live.publish!(Wire.topic(room), Json.to_str(Moved({ key, x, y })))

	## `key`'s pointer left the area in `room`.
	away! : Str, Str => {}
	away! = |room, key| Live.publish!(Wire.topic(room), Json.to_str(Away(key)))

	## A page's stream (an endpoint's `events!`): this tab is in `room` as `key`, with `meta`, until
	## its page goes. It sends the page its key and a tab id of its own (`Welcome`), who is here (a
	## snapshot, then each change), who is typing, and others' cursors. Between events, it sweeps the
	## room every `Room.beat_every`. However it ends, its tab leaves.
	stream : Str, { key : Str, meta : Wire.Meta } -> Events(Wire.Event(Wire.Meta))
	stream = |room, { key, meta }|
		Events.stream(
			|{ send!, .. }| {
				tab = hex(Random.bytes!(8))
				# Listening first: what changes after the snapshot is heard, and what changed before it
				# is older than it, which the page's copy (`Mirror`) leaves out.
				Live.listen!(Wire.topic(room))
				send!(Welcome({ key, tab }))?
				_ = PresenceServer.join!(room, { key, tab, meta })
				snapshot = Actor.ask!(PresenceServer.kind({}), room, { room, ask: Snapshot }) ?? []
				var $open = Bool.True
				for message in snapshot {
					$open = $open and send!(Presence(message)).is_ok()
				}
				while $open {
					$open =
						match Live.next!(Room.beat_every(Room.defaults)) {
							Heard(heard) =>
								match Json.parse(heard.message) {
									Ok(event) => send!(event).is_ok()
									Err(InvalidJson(_)) => Bool.True
								}
							Quiet => {
								_ = Actor.ask!(PresenceServer.kind({}), room, { room, ask: Sweep })
								Bool.True
							}
							Gone => Bool.False
						}
				}
				_ = PresenceServer.tell!(room, Leave({ key, tab }))
				Ok({})
			},
		)
}

## Bytes in lowercase hex: a tab's id, from random ones.
hex : List(U8) -> Str
hex = |bytes| {
	digits = "0123456789abcdef".to_utf8()
	var $out = []
	for byte in bytes {
		$out = $out.append(digits.get((byte // 16).to_u64()) ?? '0').append(digits.get((byte % 16).to_u64()) ?? '0')
	}
	Str.from_utf8_lossy($out)
}
