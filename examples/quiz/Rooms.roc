import pf.Actor
import pf.Channel
import pf.Endpoint
import pf.Env
import pf.Log
import pf.Time
import presence.Room
import presence.Wire
import Codes
import Game

## One actor per room (D-021), keyed by the room's join code. It holds the room's state (a
## `Game.State`, kept in Postgres after each turn that changes it) and takes one message at a
## time, so two players answering at once, the clock running out and the host pressing Next never
## trip over each other. There is no lock anywhere.
##
## The rules are `Game`'s, pure; this module only says when. After every turn it looks at the
## phase it left the room in: if that changed, it cancels the timer the old phase had and sets one
## for the new phase's deadline (`Actor.after!`), whose message (`Close`, `Advance`) comes back to
## it like any other. If the room changed, it publishes the room's view on the room's channel,
## which every host's screen and player's phone follows.
##
## Who is in the room is packages/presence's `Room`: each tab that subscribes to the channel joins
## (`Opened`), each one that goes leaves (`Closed`), the channel's beats keep tabs fresh (`Beat`),
## and a player whose last tab has been gone for the grace is `Left`: shown as dropped, and not
## waited for. A crash in a turn is logged by the platform and the room carries on as it was.
##
## Server-only: it imports `Actor`, which only the server's platform has; only route files'
## `+server.roc` import it.
Rooms := [].{
	kind : Actor.Kind(Rooms.State, Rooms.Message, Rooms.Reply)
	kind = Actor.define({
		name: "room",
		initial: |_code| { game: Game.vacant, presence: Room.empty(Rooms.presence).save(), timer: 0 },
		receive!: |me, state, message| Rooms.turn!(me, state, message),
	})

	## What the actor keeps: the game, who is here (presence's room, saved as JSON), and the timer
	## its phase's deadline is set on. A tab has one stream, and its hooks come in order (a stream
	## that reconnects is told gone before it opens again), so a tab joins and leaves as it is told.
	State : { game : Game.State, presence : Room.Saved(Wire.Meta), timer : U64 }

	## What a room is told or asked. Everything a visitor does names them by their visitor id, and
	## the room decides who that is (`Game.who`): the host, a player, or anyone.
	Message : [
		Open({ title : Str, questions : List(Game.Question), timing : Game.Timing, host : Str }),
		Join({ visitor : Str, name : Str }),
		Look(Str),
		Said({ visitor : Str, said : Game.Said }),
		Opened({ visitor : Str, tab : Str }),
		Beat({ visitor : Str, tab : Str }),
		Closed({ visitor : Str, tab : Str }),
		Sweep,
		Close(U64),
		Advance(U64),
	]

	## What the room answers: done; a visitor's seat (what `Look` and `Opened` get); a player's id
	## (`Join`), or why they couldn't join; or why not.
	Reply : [Done, Seat(Game.Seat), Joined(Str), Unjoined(Game.Unjoined), Refused(Str)]

	## Presence's settings: a tab unheard for two minutes is gone (the channel beats every 15 s),
	## and one that left is kept four seconds, in case it is only reconnecting.
	presence : Room.Settings
	presence = { timeout: 120_000, grace: 4_000 }

	## The room's channel (`routes/rooms/[code]/+server.roc`), to publish on. Named by its URL:
	## the route file imports this module, so this module can't import `Generated/Api`, which
	## imports the route file (Roc has no import cycles).
	channel : Str -> Endpoint(c, {}, Channel(Str, Game.View, Game.Said))
	channel = |code| Endpoint.remote("CHANNEL", "/rooms/${code}")

	## How long a question is open and its answer shown, from the environment (`QUIZ_QUESTION_MS`,
	## `QUIZ_REVEAL_MS`): 20 and 7 seconds unless they say. The tests make them short.
	timing! : {} => Game.Timing
	timing! = |{}| {
		read! = |name, otherwise|
			match Env.var!(name) {
				Ok(text) => U64.from_str(text.trim()) ?? otherwise
				Err(NotFound) => otherwise
			}
		{ question_ms: read!("QUIZ_QUESTION_MS", 20_000), reveal_ms: read!("QUIZ_REVEAL_MS", 7_000) }
	}

	## Tells the room `code` something, waiting for nothing.
	tell! : Str, Rooms.Message => {}
	tell! = |code, message| Actor.tell!(Rooms.kind, code, message)

	## Asks the room `code` something, and gives what it answered; a room that couldn't answer
	## (it crashed, and the platform logged why) is `Refused`.
	ask! : Str, Rooms.Message => Rooms.Reply
	ask! = |code, message|
		match Actor.ask!(Rooms.kind, code, message) {
			Ok(reply) => reply
			Err(ActorErr(why)) => Refused(why)
		}

	## How `visitor` sees the room `code`; a room that isn't there is `Vacant`. Only the code as it
	## is written (`BKRT`, not `bkrt`) names a room.
	look! : Str, Str => Game.Seat
	look! = |code, visitor|
		match Codes.parse(code) {
			Ok(parsed) if parsed == code =>
				match Rooms.ask!(code, Look(visitor)) {
					Seat(seat) => seat
					_ => Game.seat(Game.vacant, visitor, 0)
				}
			# Not a code as written: no room to ask, and no actor woken for it.
			_ => Game.seat(Game.vacant, visitor, 0)
		}

	## One turn: the message handled, then the timer and the channel brought up to date.
	turn! : Actor.Me(Rooms.Message), Rooms.State, Rooms.Message => { state : Rooms.State, reply : Rooms.Reply }
	turn! = |me, state, message| {
		now = Time.now_millis!({})
		code = Actor.key_of(me)
		# Presence first: a tab whose grace ran out is gone before anything else is decided.
		swept = Rooms.present(state, Room.load(state.presence).sweep(now))
		(handled, reply) = Rooms.handle!(me, swept, message, now)
		timed = Rooms.timed!(me, state.game, handled, now)
		if timed.game.version != state.game.version {
			Endpoint.publish!(Rooms.channel(code), Game.view(timed.game, now))
		}
		{ state: timed, reply }
	}

	## What a message does to the room.
	handle! : Actor.Me(Rooms.Message), Rooms.State, Rooms.Message, U64 => (Rooms.State, Rooms.Reply)
	handle! = |me, state, message, now| {
		game = state.game
		match message {
			Open(opening) =>
				if game.phase == Vacant {
					opened = Game.open({ code: Actor.key_of(me), title: opening.title, questions: opening.questions, timing: opening.timing, host: opening.host })
					Log.info!("room opened", { code: opened.code, title: opened.title, questions: opened.questions.len() })
					({ ..state, game: opened }, Done)
				} else {
					(state, Refused("taken"))
				}
			Join(joining) =>
				match Game.join(game, joining) {
					Ok((joined, id)) => ({ ..state, game: joined }, Joined(id))
					Err(why) => (state, Unjoined(why))
				}
			Look(visitor) => (state, Seat(Game.seat(game, visitor, now)))
			Said({ visitor, said }) => Rooms.heard(state, visitor, said, now)
			Opened({ visitor, tab }) => {
				opened = Rooms.tab_joined(state, visitor, tab, now)
				(opened, Seat(Game.seat(opened.game, visitor, now)))
			}
			Beat({ visitor, tab }) =>
				match Game.who(game, visitor) {
					Player(id) =>
						match Room.load(state.presence).heartbeat(id, tab, now) {
							Ok(beaten) => ({ ..state, presence: beaten.save() }, Done)
							# Swept out while its laptop slept, and back: it joins again.
							Err(Unknown) => (Rooms.tab_joined(state, visitor, tab, now), Done)
						}
					_ => (state, Done)
				}
			Closed({ visitor, tab }) =>
				match Game.who(game, visitor) {
					Player(id) => {
						(left, changes) = Room.load(state.presence).leave(id, tab, now)
						# The grace, then a sweep: if the tab isn't back by then, its player is gone.
						_sweep = Actor.after!(me, Rooms.presence.grace + 50, Sweep)
						(Rooms.present({ ..state, presence: left.save() }, (left, changes)), Done)
					}
					_ => (state, Done)
				}
			# The sweep has run already, at the start of the turn.
			Sweep => (state, Done)
			Close(index) => ({ ..state, game: Game.close(game, index, now) }, Done)
			Advance(index) => ({ ..state, game: Game.advance(game, index, now) }, Done)
		}
	}

	## What a page said, if the one who said it may say it: the host runs the game, and players
	## answer. An answer that makes everyone's in closes the question at once.
	heard : Rooms.State, Str, Game.Said, U64 -> (Rooms.State, Rooms.Reply)
	heard = |state, visitor, words, now| {
		game = state.game
		host = Game.who(game, visitor) == Host
		match words {
			Start if host =>
				match Game.start(game, now) {
					Ok(started) => ({ ..state, game: started }, Done)
					Err(NoPlayers) => (state, Refused("Wait for someone to join first."))
					Err(_) => (state, Refused("The game has started already."))
				}
			Next if host => ({ ..state, game: Game.skip(game, now) }, Done)
			Again if host =>
				match Game.again(game) {
					Ok(again) => ({ ..state, game: again }, Done)
					Err(NotFinished) => (state, Refused("The game isn't over yet."))
				}
			Pick({ index, choice }) =>
				match Game.pick(game, { visitor, index, choice, now }) {
					Ok(picked) =>
						if Game.all_in(picked) {
							({ ..state, game: Game.close(picked, index, now) }, Done)
						} else {
							({ ..state, game: picked }, Done)
						}
					Err(TooLate) => (state, Refused("Time was up."))
					Err(Picked) => (state, Refused("You've answered this one."))
					Err(_) => (state, Refused("That question isn't open."))
				}
			_ => (state, Refused("Only the host can do that."))
		}
	}

	## The room's timer, kept with its phase: a new phase cancels the old one's timer, and sets
	## its own for its deadline (`Game.deadline`), if it has one.
	timed! : Actor.Me(Rooms.Message), Game.State, Rooms.State, U64 => Rooms.State
	timed! = |me, before, state, now|
		if state.game.phase == before.phase {
			state
		} else {
			if state.timer != 0 {
				Actor.cancel!(state.timer)
			}
			match Game.deadline(state.game) {
				Ok({ at, then }) => {
					wait = at - U64.min(at, now)
					timer =
						match then {
							Close(index) => Actor.after!(me, wait, Close(index))
							Advance(index) => Actor.after!(me, wait, Advance(index))
						}
					{ ..state, timer }
				}
				Err(NoDeadline) => { ..state, timer: 0 }
			}
		}

	## `visitor`'s tab `tab` joins presence's room, if they are a player.
	tab_joined : Rooms.State, Str, Str, U64 -> Rooms.State
	tab_joined = |state, visitor, tab, now|
		match state.game.players.find_first(|player| player.visitor == visitor) {
			Ok(player) => Rooms.present(state, Room.load(state.presence).join({ key: player.id, tab, meta: { name: player.name, image: "", color: "", status: "" }, now }))
			Err(_) => state
		}

	## Presence's room, after a change, kept; and each player it says came or went, here or not.
	present : Rooms.State, (Room(Wire.Meta), List(Room.Change(Wire.Meta))) -> Rooms.State
	present = |state, (room, changes)| {
		game = changes.fold(
			state.game,
			|so_far, change|
				match change {
					Joined(here) => Game.here(so_far, here.key, Bool.True)
					Left(here) => Game.here(so_far, here.key, Bool.False)
					Changed(_) => so_far
				},
		)
		{ ..state, game, presence: room.save() }
	}

}
