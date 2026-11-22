import Score

## The rules of a game of Pinwheel, as plain values: a room opens in its lobby, players join it, the
## host starts it, and then each question is asked (`Asking`) and its answer shown (`Revealing`),
## until the last one's reveal gives way to the podium (`Finished`).
##
## Nothing here has an effect: the time is given (`now`, the server's milliseconds), so the room's
## actor (`Rooms.roc`) decides when, and these functions decide what. The `expect`s at the end play
## games with a clock they choose.
Game := [].{

	## A question as a set has it: its prompt, two to four choices, and which one is right.
	Question : { prompt : Str, choices : List(Str), answer : U64 }

	## How long a question is open for, and how long its answer stays up before the next one: the
	## server's settings (`Rooms.timing!`), kept in the room so a game keeps its pace.
	Timing : { question_ms : U64, reveal_ms : U64 }

	## A player: a short public id (`p3`), the visitor whose cookie they joined with (secret: it
	## never leaves the server), the name they chose, their score, and whether a tab of theirs is
	## in the room now (`here`; presence says, `Rooms.roc`).
	Player : { id : Str, visitor : Str, name : Str, score : U64, here : Bool }

	## An answer: who gave it, which choice, and how many milliseconds after the question opened.
	Pick : { player : Str, choice : U64, elapsed : U64 }

	## Where a room is. `Vacant` is a code with no room behind it (yet, or any more).
	Phase : [Vacant, Lobby, Asking({ index : U64, opened : U64 }), Revealing({ index : U64, at : U64 }), Finished]

	## A whole room: what the actor keeps, as JSON, between its turns. `version` goes up with every
	## change, so a page can tell a newer view from an older one.
	State : { code : Str, title : Str, questions : List(Game.Question), timing : Game.Timing, host : Str, players : List(Game.Player), phase : Game.Phase, picks : List(Game.Pick), version : U64 }

	## What a page says on the room's channel: the host's Start, Next and Again, and a player's
	## answer to question `index`.
	Said : [Start, Next, Again, Pick({ index : U64, choice : U64 })]

	## Why someone can't join a room: there is none with that code, its game is over, no name was
	## given, someone in it has that name, or it is full.
	Unjoined : [Vacant, Over, NoName, NameTaken, Full]

	## Who is looking at a room: its host, one of its players (by public id), or anyone else.
	Who : [Host, Player(Str), Watcher]

	## A player, as everyone may see them: no visitor, and whether they have answered the question
	## being asked (or the one just revealed).
	Face : { id : Str, name : Str, score : U64, here : Bool, answered : Bool }

	## A question being asked, as everyone sees it: no answer in it. `left_ms` is how long it has
	## left as the view was made, which a page counts down from.
	Asking : { index : U64, prompt : Str, choices : List(Str), left_ms : U64, limit_ms : U64, answered : U64 }

	## A question's answer, shown: the right choice, how many took each, and what each player who
	## answered earned (`choice` is theirs). `left_ms` is how long until the next question (or the
	## podium, after the `last`).
	Revealing : { index : U64, prompt : Str, choices : List(Str), answer : U64, tallies : List(U64), gains : List({ id : Str, choice : U64, gained : U64 }), left_ms : U64, last : Bool }

	## The room as everyone sees it: what its channel publishes (`routes/rooms/[code]/+server.roc`).
	View : { code : Str, title : Str, total : U64, version : U64, players : List(Game.Face), stage : [Vacant, Lobby, Asking(Game.Asking), Revealing(Game.Revealing), Finished] }

	## The room as one visitor sees it: the view, who they are in it, and, for a player, what they
	## picked for the question being asked (which nobody else sees until the reveal).
	Seat : { view : Game.View, who : Game.Who, picked : [Nothing, Picked(U64)] }

	## No room.
	vacant : Game.State
	vacant = { code: "", title: "", questions: [], timing: { question_ms: 0, reveal_ms: 0 }, host: "", players: [], phase: Vacant, picks: [], version: 0 }

	## The most players a room takes.
	capacity : U64
	capacity = 60

	## The longest name a player may take, in characters.
	longest_name : U64
	longest_name = 16

	## A room, opened by `host` (a visitor) with a set's questions: in its lobby, with no one in it.
	open : { code : Str, title : Str, questions : List(Game.Question), timing : Game.Timing, host : Str } -> Game.State
	open = |{ code, title, questions, timing, host }| { code, title, questions, timing, host, players: [], phase: Lobby, picks: [], version: 1 }

	## `visitor` joins as `name`, and gets their player's id. One who has joined already gets the
	## same id back (a phone that reloaded, or came back), whatever name they type. Anyone may join
	## until the podium: a latecomer starts from nothing.
	join : Game.State, { visitor : Str, name : Str } -> Try((Game.State, Str), Game.Unjoined)
	join = |state, { visitor, name }| {
		cleaned = Game.clean_name(name)
		match state.phase {
			Vacant => Err(Vacant)
			Finished => Err(Over)
			_ =>
				match state.players.find_first(|player| player.visitor == visitor) {
					Ok(player) => Ok((state, player.id))
					Err(_) =>
						if cleaned.is_empty() {
							Err(NoName)
						} else if state.players.any(|player| player.name.with_ascii_lowercased() == cleaned.with_ascii_lowercased()) {
							Err(NameTaken)
						} else if state.players.len() >= Game.capacity {
							Err(Full)
						} else {
							id = "p${(state.players.len() + 1).to_str()}"
							player = { id, visitor, name: cleaned, score: 0, here: Bool.False }
							Ok((Game.changed({ ..state, players: state.players.append(player) }), id))
						}
				}
		}
	}

	## A name as a player is shown by: its spaces collapsed, and at most `longest_name` characters.
	clean_name : Str -> Str
	clean_name = |name| {
		words = name.split_on(" ").map(|word| word.trim()).keep_if(|word| !word.is_empty())
		Game.take_chars(Str.join_with(words, " "), Game.longest_name).trim()
	}

	## The first `count` characters of `text` (code points, so a name never ends mid-letter).
	take_chars : Str, U64 -> Str
	take_chars = |text, count| {
		var $kept = []
		var $chars = 0
		for byte in text.to_utf8() {
			# A byte that starts a character (not 10xxxxxx) counts one.
			starts = byte < 0x80 or byte >= 0xC0
			if starts {
				$chars = $chars + 1
			}
			if $chars <= count {
				$kept = $kept.append(byte)
			}
		}
		Str.from_utf8_lossy($kept)
	}

	## The host starts the game: the first question is asked, from `now`.
	start : Game.State, U64 -> Try(Game.State, [NotInLobby, NoPlayers, NoQuestions])
	start = |state, now|
		match state.phase {
			Lobby =>
				if state.players.is_empty() {
					Err(NoPlayers)
				} else if state.questions.is_empty() {
					Err(NoQuestions)
				} else {
					Ok(Game.changed({ ..state, phase: Asking({ index: 0, opened: now }), picks: [] }))
				}
			_ => Err(NotInLobby)
		}

	## How late an answer may reach the server and still count: the network's share of the time,
	## as the room's timer closes the question at the deadline (an answer after that is refused).
	grace_ms : U64
	grace_ms = 300

	## `visitor` answers question `index` with `choice`, at `now`. Only while that question is
	## asked, only a player, once each, and only a choice it has.
	pick : Game.State, { visitor : Str, index : U64, choice : U64, now : U64 } -> Try(Game.State, [NotAsking, NotPlaying, Picked, NoSuchChoice, TooLate])
	pick = |state, { visitor, index, choice, now }|
		match state.phase {
			Asking(asking) if asking.index == index =>
				match state.players.find_first(|player| player.visitor == visitor) {
					Err(_) => Err(NotPlaying)
					Ok(player) => {
						elapsed = now - U64.min(asking.opened, now)
						choices = Game.question_at(state, index).choices.len()
						if state.picks.any(|each| each.player == player.id) {
							Err(Picked)
						} else if choice >= choices {
							Err(NoSuchChoice)
						} else if elapsed > state.timing.question_ms + Game.grace_ms {
							Err(TooLate)
						} else {
							Ok(Game.changed({ ..state, picks: state.picks.append({ player: player.id, choice, elapsed }) }))
						}
					}
				}
			_ => Err(NotAsking)
		}

	## Whether everyone in the room has answered the question being asked: the room needn't wait
	## for the clock. A player whose tabs have all gone isn't waited for.
	all_in : Game.State -> Bool
	all_in = |state|
		match state.phase {
			Asking(_) => {
				waiting = state.players.keep_if(|player| player.here)
				!waiting.is_empty() and waiting.all(|player| state.picks.any(|each| each.player == player.id))
			}
			_ => Bool.False
		}

	## Question `index` closes at `now`: its answer is revealed, and each player who picked it right
	## earns their points. A question already closed (the timer and the last answer racing) stays
	## as it is.
	close : Game.State, U64, U64 -> Game.State
	close = |state, index, now|
		match state.phase {
			Asking(asking) if asking.index == index => {
				earned = Game.gains(state, index)
				players = state.players.map(
					|player|
						match earned.find_first(|gain| gain.id == player.id) {
							Ok(gain) => { ..player, score: player.score + gain.gained }
							Err(_) => player
						},
				)
				Game.changed({ ..state, players, phase: Revealing({ index, at: now }) })
			}
			_ => state
		}

	## What each pick for question `index` earned.
	gains : Game.State, U64 -> List({ id : Str, choice : U64, gained : U64 })
	gains = |state, index| {
		question = Game.question_at(state, index)
		state.picks.map(
			|each| {
				right = each.choice == question.answer
				{ id: each.player, choice: each.choice, gained: Score.points({ right, elapsed: each.elapsed, limit: state.timing.question_ms }) }
			},
		)
	}

	## After question `index`'s reveal, at `now`: the next question, or the podium after the last.
	## A reveal already moved on stays as it is.
	advance : Game.State, U64, U64 -> Game.State
	advance = |state, index, now|
		match state.phase {
			Revealing(revealing) if revealing.index == index =>
				if index + 1 < state.questions.len() {
					Game.changed({ ..state, phase: Asking({ index: index + 1, opened: now }), picks: [] })
				} else {
					Game.changed({ ..state, phase: Finished, picks: [] })
				}
			_ => state
		}

	## The host's Next, at `now`: a question being asked closes now; a reveal moves on now.
	skip : Game.State, U64 -> Game.State
	skip = |state, now|
		match state.phase {
			Asking(asking) => Game.close(state, asking.index, now)
			Revealing(revealing) => Game.advance(state, revealing.index, now)
			_ => state
		}

	## The host plays the set again with the same room: back to the lobby, every score nothing.
	again : Game.State -> Try(Game.State, [NotFinished])
	again = |state|
		match state.phase {
			Finished => Ok(Game.changed({ ..state, phase: Lobby, picks: [], players: state.players.map(|player| { ..player, score: 0 }) }))
			_ => Err(NotFinished)
		}

	## Player `id` is in the room now, or no longer (their last tab went).
	here : Game.State, Str, Bool -> Game.State
	here = |state, id, is_here|
		if state.players.any(|player| player.id == id and player.here != is_here) {
			Game.changed({ ..state, players: state.players.map(|player| if (player.id == id) { ..player, here: is_here } else player) })
		} else {
			state
		}

	## Who `visitor` is in the room.
	who : Game.State, Str -> Game.Who
	who = |state, visitor|
		if !visitor.is_empty() and visitor == state.host {
			Host
		} else {
			match state.players.find_first(|player| !visitor.is_empty() and player.visitor == visitor) {
				Ok(player) => Player(player.id)
				Err(_) => Watcher
			}
		}

	## When the phase the room is in ends by itself, if it does: the deadline its timer is set for.
	deadline : Game.State -> Try({ at : U64, then : [Close(U64), Advance(U64)] }, [NoDeadline])
	deadline = |state|
		match state.phase {
			Asking(asking) => Ok({ at: asking.opened + state.timing.question_ms, then: Close(asking.index) })
			Revealing(revealing) => Ok({ at: revealing.at + state.timing.reveal_ms, then: Advance(revealing.index) })
			_ => Err(NoDeadline)
		}

	## The room as everyone sees it, at `now`.
	view : Game.State, U64 -> Game.View
	view = |state, now| {
		answered = |id| state.picks.any(|each| each.player == id)
		players = state.players.map(|player| { id: player.id, name: player.name, score: player.score, here: player.here, answered: answered(player.id) })
		left = |at| at - U64.min(at, now)
		stage =
			match state.phase {
				Vacant => Vacant
				Lobby => Lobby
				Asking(asking) => {
					question = Game.question_at(state, asking.index)
					Asking({
						index: asking.index,
						prompt: question.prompt,
						choices: question.choices,
						left_ms: left(asking.opened + state.timing.question_ms),
						limit_ms: state.timing.question_ms,
						answered: state.picks.len(),
					})
				}
				Revealing(revealing) => {
					question = Game.question_at(state, revealing.index)
					tallies = question.choices.map_with_index(|_, at| state.picks.count_if(|each| each.choice == at))
					Revealing({
						index: revealing.index,
						prompt: question.prompt,
						choices: question.choices,
						answer: question.answer,
						tallies,
						gains: Game.gains(state, revealing.index),
						left_ms: left(revealing.at + state.timing.reveal_ms),
						last: revealing.index + 1 >= state.questions.len(),
					})
				}
				Finished => Finished
			}
		{ code: state.code, title: state.title, total: state.questions.len(), version: state.version, players, stage }
	}

	## The room as `visitor` sees it, at `now`.
	seat : Game.State, Str, U64 -> Game.Seat
	seat = |state, visitor, now| {
		seen_as = Game.who(state, visitor)
		picked =
			match (seen_as, state.phase) {
				(Player(id), Asking(_)) =>
					match state.picks.find_first(|each| each.player == id) {
						Ok(each) => Picked(each.choice)
						Err(_) => Nothing
					}
				_ => Nothing
			}
		{ view: Game.view(state, now), who: seen_as, picked }
	}

	## Question `index`, or an empty one past the end (never asked: phases only name questions the
	## set has).
	question_at : Game.State, U64 -> Game.Question
	question_at = |state, index| state.questions.get(index) ?? { prompt: "", choices: [], answer: 0 }

	## The state, one version on.
	changed : Game.State -> Game.State
	changed = |state| { ..state, version: state.version + 1 }
}

# ---- A game, played with a clock the expects choose ----

questions : List(Game.Question)
questions = [
	{ prompt: "Which planet has the most moons?", choices: ["Mars", "Saturn", "Venus", "Mercury"], answer: 1 },
	{ prompt: "How many legs has a spider?", choices: ["Six", "Eight"], answer: 1 },
]

opened : Game.State
opened = Game.open({ code: "BKRT", title: "Odds and ends", questions, timing: { question_ms: 10_000, reveal_ms: 4_000 }, host: "h" })

## The room with Ada, Bo and Cy in it, each here.
three : Game.State
three = {
	with_ada = (Game.join(opened, { visitor: "va", name: "Ada" }) ?? (opened, "")).0
	with_bo = (Game.join(with_ada, { visitor: "vb", name: "  Bo  " }) ?? (with_ada, "")).0
	with_cy = (Game.join(with_bo, { visitor: "vc", name: "Cy" }) ?? (with_bo, "")).0
	["p1", "p2", "p3"].fold(with_cy, |state, id| Game.here(state, id, Bool.True))
}

## `state`, or `opened` if it is an error: for expects whose step must succeed.
must : Try(Game.State, _) -> Game.State
must = |tried| tried ?? opened

# Joining: an id each, a name cleaned, the same id again for the same visitor.
expect three.players.map(|player| (player.id, player.name)) == [("p1", "Ada"), ("p2", "Bo"), ("p3", "Cy")]
expect Game.join(three, { visitor: "va", name: "Someone else" }).map_ok(|(_, id)| id) == Ok("p1")
expect Game.join(three, { visitor: "vd", name: "ada" }).map_ok(|(_, id)| id) == Err(NameTaken)
expect Game.join(three, { visitor: "vd", name: "   " }).map_ok(|(_, id)| id) == Err(NoName)
expect Game.join(Game.vacant, { visitor: "vd", name: "Di" }).map_ok(|(_, id)| id) == Err(Vacant)
expect Game.clean_name("  Ada   Lovelace ") == "Ada Lovelace"
expect Game.clean_name("Wolfeschlegelsteinhausen") == "Wolfeschlegelste"
expect Game.clean_name("Zoë Żółwińska-Long") == "Zoë Żółwińska-Lo"

# Who is who.
expect Game.who(three, "h") == Host and Game.who(three, "vb") == Player("p2") and Game.who(three, "stranger") == Watcher and Game.who(three, "") == Watcher

# Starting: only from the lobby, only with players.
expect Game.start(opened, 0) == Err(NoPlayers)
expect must(Game.start(three, 1_000)).phase == Asking({ index: 0, opened: 1_000 })
expect Game.start(must(Game.start(three, 1_000)), 2_000) == Err(NotInLobby)

# Picking: once, a choice the question has, while it is asked, before its time is up.
asked : Game.State
asked = must(Game.start(three, 1_000))

expect Game.pick(asked, { visitor: "va", index: 0, choice: 1, now: 3_000 }).is_ok()
expect Game.pick(must(Game.pick(asked, { visitor: "va", index: 0, choice: 1, now: 3_000 })), { visitor: "va", index: 0, choice: 2, now: 3_500 }) == Err(Picked)
expect Game.pick(asked, { visitor: "va", index: 0, choice: 4, now: 3_000 }) == Err(NoSuchChoice)
expect Game.pick(asked, { visitor: "va", index: 1, choice: 0, now: 3_000 }) == Err(NotAsking)
expect Game.pick(asked, { visitor: "h", index: 0, choice: 0, now: 3_000 }) == Err(NotPlaying)
expect Game.pick(asked, { visitor: "va", index: 0, choice: 1, now: 11_200 }).is_ok()
expect Game.pick(asked, { visitor: "va", index: 0, choice: 1, now: 11_400 }) == Err(TooLate)
expect Game.pick(three, { visitor: "va", index: 0, choice: 1, now: 3_000 }) == Err(NotAsking)

# Nobody sees an answer before its reveal, and a page counts down from what is left.
expect
	match Game.view(asked, 4_000).stage {
		Asking(asking) => asking == { index: 0, prompt: "Which planet has the most moons?", choices: ["Mars", "Saturn", "Venus", "Mercury"], left_ms: 7_000, limit_ms: 10_000, answered: 0 }
		_ => Bool.False
	}

# Everyone in: the room needn't wait. One who dropped isn't waited for.
all_picked : Game.State
all_picked = [("va", 1, 2_000), ("vb", 0, 6_000), ("vc", 1, 11_000)].fold(asked, |state, (visitor, choice, now)| must(Game.pick(state, { visitor, index: 0, choice, now })))

expect Game.all_in(all_picked)
expect !Game.all_in(must(Game.pick(asked, { visitor: "va", index: 0, choice: 1, now: 2_000 })))
expect Game.all_in(Game.here(must(Game.pick(must(Game.pick(asked, { visitor: "va", index: 0, choice: 1, now: 2_000 })), { visitor: "vb", index: 0, choice: 1, now: 2_000 })), "p3", Bool.False))

# The reveal: points for the right answers, by speed; the tallies; what each earned.
revealed : Game.State
revealed = Game.close(all_picked, 0, 11_500)

expect revealed.players.map(|player| (player.name, player.score)) == [("Ada", 950), ("Bo", 0), ("Cy", 500)]
expect
	match Game.view(revealed, 12_500).stage {
		Revealing(revealing) => {
			shown = { answer: revealing.answer, tallies: revealing.tallies, gains: revealing.gains, left_ms: revealing.left_ms, last: revealing.last }
			shown == { answer: 1, tallies: [1, 2, 0, 0], gains: [{ id: "p1", choice: 1, gained: 950 }, { id: "p2", choice: 0, gained: 0 }, { id: "p3", choice: 1, gained: 500 }], left_ms: 3_000, last: Bool.False }
		}
		_ => Bool.False
	}

# A question closes once: the timer after the last answer changes nothing.
expect Game.close(revealed, 0, 12_000) == revealed

# On to the next question, picks forgotten; after the last, the podium.
second : Game.State
second = Game.advance(revealed, 0, 15_500)

expect second.phase == Asking({ index: 1, opened: 15_500 }) and second.picks == []
expect Game.advance(second, 0, 16_000) == second
expect Game.advance(Game.close(second, 1, 25_500), 1, 29_500).phase == Finished

# The host's Next: closes a question early, then moves a reveal on early.
expect Game.skip(asked, 2_000).phase == Revealing({ index: 0, at: 2_000 })
expect Game.skip(Game.skip(asked, 2_000), 2_500).phase == Asking({ index: 1, opened: 2_500 })
expect Game.skip(three, 2_000) == three

# Again: the same players, from nothing.
expect {
	finished = Game.advance(Game.close(second, 1, 25_500), 1, 29_500)
	again = must(Game.again(finished))
	again.phase == Lobby and again.players.all(|player| player.score == 0) and again.players.len() == 3
}
expect Game.again(three) == Err(NotFinished)

# Only the player sees their own pick while the question is asked.
expect Game.seat(must(Game.pick(asked, { visitor: "va", index: 0, choice: 3, now: 2_000 })), "va", 2_000).picked == Picked(3)
expect Game.seat(must(Game.pick(asked, { visitor: "va", index: 0, choice: 3, now: 2_000 })), "vb", 2_000).picked == Nothing

# Every change is a new version; what changes nothing isn't.
expect three.version > opened.version and Game.here(three, "p1", Bool.True).version == three.version

# Deadlines: a question's at its limit, a reveal's after the reveal's time.
expect Game.deadline(asked) == Ok({ at: 11_000, then: Close(0) })
expect Game.deadline(revealed) == Ok({ at: 15_500, then: Advance(0) })
expect Game.deadline(three) == Err(NoDeadline)
