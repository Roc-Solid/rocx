import pf.Actor
import pf.Endpoint
import pf.Env
import pf.Log
import pf.Time
import presence.Room
import presence.Wire
import Codes
import Game
import Generated/Api

## One actor per room (D-021), keyed by the room's join code. It holds the room's state (a
## `Game.State`, kept in the database after each turn that changes it) and takes one turn at a time,
## whichever of its methods each is (D-066), so two players answering at once, the clock running
## out and the host pressing Next never trip over each other. There is no lock anywhere.
##
## The rules are `Game`'s, pure; this module only says when. Every method's turn goes through
## `turned!`: presence swept first, then what the method does, then the phase it left the room in
## looked at: if that changed, it cancels the timer the old phase had and sets one for the new
## phase's deadline (`me.after!`), which calls `close` or `advance` like any other caller. If the
## room changed, it publishes the room's view on the room's channel, which every host's screen and
## player's phone follows (`Api.channel_api_rooms_code`: an actor may import the app's contract, which
## imports no route file, D-037).
##
## Who is in the room is packages/presence's `Room`: each tab that subscribes to the channel joins
## (`opened`), each one that goes leaves (`closed`), the channel's beats keep tabs fresh (`beat`),
## and a player whose last tab has been gone for the grace is `Left`: shown as dropped, and not
## waited for. A crash in a turn is logged by the platform and the room carries on as it was.
##
## Server-only: it imports `Actor`, which only the server's platform has; only route files'
## `+server.roc` import it.
Rooms := [].{
	name = |{}| "room"
	initial = |_code| { game: Game.vacant, presence: Room.empty(Rooms.presence).save(), timer: 0 }

	## The type of the room's methods: the app's context (its `init!` makes `{}`), the room's code,
	## its state, and each method's input and reply.
	Method(input, reply) : Actor.Method(Rooms, {}, Str, Rooms.State, input, reply)

	## What the actor keeps: the game, who is here (presence's room, saved as JSON), and the timer
	## its phase's deadline is set on. A tab has one stream, and its hooks come in order (a stream
	## that reconnects is told gone before it opens again), so a tab joins and leaves as it is told.
	State : { game : Game.State, presence : Room.Saved(Wire.Meta({})), timer : U64 }

	## A game, for a vacant room: what `open` is given.
	Opening : { title : Str, questions : List(Game.Question), timing : Game.Timing, host : Str }

	## Opens the room for a game, if it is vacant; `Taken` if it isn't (`Entry` tries another code).
	open : Rooms.Method(Rooms.Opening, [Opened, Taken])
	open = Actor.method(
		"open",
		|turn|
			Rooms.turned!(
				turn,
				|state, _now|
					if state.game.phase == Vacant {
						{ title, questions, timing, host } = turn.input
						game = Game.open({ code: turn.me.key(), title, questions, timing, host })
						Log.info!("room opened", { code: game.code, title: game.title, questions: game.questions.len() })
						({ ..state, game }, Opened)
					} else {
						(state, Taken)
					},
			),
	)

	## A visitor joins as a player: their player id, or why they couldn't.
	join : Rooms.Method({ visitor : Str, name : Str }, [Joined(Str), Unjoined(Game.Unjoined)])
	join = Actor.method(
		"join",
		|turn|
			Rooms.turned!(
				turn,
				|state, _now|
					match Game.join(state.game, turn.input) {
						Ok((joined, id)) => ({ ..state, game: joined }, Joined(id))
						Err(why) => (state, Unjoined(why))
					},
			),
	)

	## How a visitor sees the room (`look!`).
	seat : Rooms.Method(Str, Game.Seat)
	seat = Actor.method("seat", |turn| Rooms.turned!(turn, |state, now| (state, Game.seat(state.game, turn.input, now))))

	## What a page said (`heard`): `Refused` with why, if its visitor may not say it.
	said : Rooms.Method({ visitor : Str, said : Game.Said }, [Heard, Refused(Str)])
	said = Actor.method("said", |turn| Rooms.turned!(turn, |state, now| Rooms.heard(state, turn.input.visitor, turn.input.said, now)))

	## A tab subscribed to the room's channel: in presence's room, a player's; and how its visitor
	## sees the room.
	opened : Rooms.Method({ visitor : Str, tab : Str }, Game.Seat)
	opened = Actor.method(
		"opened",
		|turn|
			Rooms.turned!(
				turn,
				|state, now| {
					{ visitor, tab } = turn.input
					joined = Rooms.tab_joined(state, visitor, tab, now)
					(joined, Game.seat(joined.game, visitor, now))
				},
			),
	)

	## A tab's channel beat: it is still here.
	beat : Rooms.Method({ visitor : Str, tab : Str }, {})
	beat = Actor.method(
		"beat",
		|turn|
			Rooms.turned!(
				turn,
				|state, now| {
					{ visitor, tab } = turn.input
					match Game.who(state.game, visitor) {
						Player(id) =>
							match Room.load(state.presence).heartbeat(id, tab, now) {
								Ok(beaten) => ({ ..state, presence: beaten.save() }, {})
								# Swept out while its laptop slept, and back: it joins again.
								Err(Unknown) => (Rooms.tab_joined(state, visitor, tab, now), {})
							}
						_ => (state, {})
					}
				},
			),
	)

	## A tab's subscription ended: a player whose last tab it was drops, once the grace is up.
	closed : Rooms.Method({ visitor : Str, tab : Str }, {})
	closed = Actor.method(
		"closed",
		|turn|
			Rooms.turned!(
				turn,
				|state, now| {
					{ visitor, tab } = turn.input
					match Game.who(state.game, visitor) {
						Player(id) => {
							(left, changes) = Room.load(state.presence).leave(id, tab, now)
							# The grace, then a sweep: if the tab isn't back by then, its player is gone.
							_sweep = turn.me.after!(Rooms.presence.grace + 50, Rooms.sweep, {})
							(Rooms.present({ ..state, presence: left.save() }, (left, changes)), {})
						}
						_ => (state, {})
					}
				},
			),
	)

	## The sweep a tab's leaving sets for when its grace is up: every turn sweeps first (`turned!`),
	## so this one has nothing more to do.
	sweep : Rooms.Method({}, {})
	sweep = Actor.method("sweep", |turn| Rooms.turned!(turn, |state, _now| (state, {})))

	## The question `input`'s time is up (its phase's timer, `timed!`). A function of `{}`: the
	## timer it sets names it.
	close : {} -> Rooms.Method(U64, {})
	close = |{}| Actor.method("close", |turn| Rooms.turned!(turn, |state, now| ({ ..state, game: Game.close(state.game, turn.input, now) }, {})))

	## The answer to question `input` has been shown long enough (its phase's timer, `timed!`).
	advance : {} -> Rooms.Method(U64, {})
	advance = |{}| Actor.method("advance", |turn| Rooms.turned!(turn, |state, now| ({ ..state, game: Game.advance(state.game, turn.input, now) }, {})))

	## Presence's settings: a tab unheard for two minutes is gone (the channel beats every 15 s),
	## and one that left is kept four seconds, in case it is only reconnecting.
	presence : Room.Settings
	presence = { timeout: 120_000, grace: 4_000 }

	## How long a question is open and its answer shown, from the environment (`QUIZ_QUESTION_MS`,
	## `QUIZ_REVEAL_MS`): 20 and 7 seconds unless they say. The tests make them short.
	timing! : {} => Game.Timing
	timing! = |{}| {
		read! = |variable, otherwise|
			match Env.var!(variable) {
				Ok(text) => U64.from_str(text.trim()) ?? otherwise
				Err(NotFound) => otherwise
			}
		{ question_ms: read!("QUIZ_QUESTION_MS", 20_000), reveal_ms: read!("QUIZ_REVEAL_MS", 7_000) }
	}

	## How `visitor` sees the room `code`; a room that isn't there, or doesn't answer, is `Vacant`.
	## Only the code as it is written (`BKRT`, not `bkrt`) names a room.
	look! : Str, Str => Game.Seat
	look! = |code, visitor|
		match Codes.parse(code) {
			Ok(parsed) if parsed == code =>
				match Rooms.seat.ask!(code, visitor) {
					Ok(found) => found
					Err(ActorErr(_)) => Game.seat(Game.vacant, visitor, 0)
				}
			# Not a code as written: no room to ask, and no actor woken for it.
			_ => Game.seat(Game.vacant, visitor, 0)
		}

	## Every method's turn: presence swept first (a tab whose grace ran out is gone before anything
	## else is decided), then what the method does (`handle!`: the room after, and the reply), then
	## the timer and the channel brought up to date.
	turned! : Actor.Turn(Rooms, context, Str, Rooms.State, input), (Rooms.State, U64 => (Rooms.State, reply)) => { state : Rooms.State, reply : reply }
	turned! = |{ me, state, .. }, handle!| {
		now = Time.now_millis!({})
		swept = Rooms.present(state, Room.load(state.presence).sweep(now))
		(handled, reply) = handle!(swept, now)
		timed = Rooms.timed!(me, state.game, handled, now)
		if timed.game.version != state.game.version {
			Endpoint.publish!(Api.channel_api_rooms_code({ code: me.key() }), Game.view(timed.game, now))
		}
		{ state: timed, reply }
	}

	## What a page said, if the one who said it may say it: the host runs the game, and players
	## answer. An answer that makes everyone's in closes the question at once.
	heard : Rooms.State, Str, Game.Said, U64 -> (Rooms.State, [Heard, Refused(Str)])
	heard = |state, visitor, words, now| {
		game = state.game
		host = Game.who(game, visitor) == Host
		match words {
			Start if host =>
				match Game.start(game, now) {
					Ok(started) => ({ ..state, game: started }, Heard)
					Err(NoPlayers) => (state, Refused("Wait for someone to join first."))
					Err(_) => (state, Refused("The game has started already."))
				}
			Next if host => ({ ..state, game: Game.skip(game, now) }, Heard)
			Again if host =>
				match Game.again(game) {
					Ok(again) => ({ ..state, game: again }, Heard)
					Err(NotFinished) => (state, Refused("The game isn't over yet."))
				}
			Pick({ index, choice }) =>
				match Game.pick(game, { visitor, index, choice, now }) {
					Ok(picked) =>
						if Game.all_in(picked) {
							({ ..state, game: Game.close(picked, index, now) }, Heard)
						} else {
							({ ..state, game: picked }, Heard)
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
	timed! : Actor.Me(Rooms, Str, Rooms.State), Game.State, Rooms.State, U64 => Rooms.State
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
							Close(index) => me.after!(wait, Rooms.close({}), index)
							Advance(index) => me.after!(wait, Rooms.advance({}), index)
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
			Ok(player) => Rooms.present(state, Room.load(state.presence).join({ key: player.id, tab, meta: Wire.meta(player.name, {}), now }))
			Err(_) => state
		}

	## Presence's room, after a change, kept; and each player it says came or went, here or not.
	present : Rooms.State, (Room(Wire.Meta({})), List(Room.Change(Wire.Meta({})))) -> Rooms.State
	present = |state, (kept, changes)| {
		game = changes.fold(
			state.game,
			|so_far, change|
				match change {
					Joined(here) => Game.here(so_far, here.key, Bool.True)
					Left(here) => Game.here(so_far, here.key, Bool.False)
					Changed(_) => so_far
				},
		)
		{ ..state, game, presence: kept.save() }
	}

}
