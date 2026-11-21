import Stack

## Who is typing. A page that types sends a ping when it starts, and again every few seconds while
## it goes on, and says when it stops (`Typist`). Those who hear it keep each typist until a ping's `ttl` runs out
## (`started`, `who`): a page that closed mid-word, or lost its network, stops showing as typing on
## its own, with no message to say so.
Typing := { typing : List({ key : Str, until : U64 }), ttl : U64 }.{

	## No one typing; a ping lasts `ttl` milliseconds (twice a sender's `every`, or a little more).
	new : U64 -> Typing
	new = |ttl| { typing: [], ttl }

	## `key` started typing at `now`, or is still typing: they are typing for `ttl` more.
	started : Typing, Str, U64 -> Typing
	started = |typing, key, now|
		if typing.typing.any(|typist| typist.key == key) {
			{ ..typing, typing: typing.typing.map(|typist| if (typist.key == key) { key, until: now + typing.ttl } else typist) }
		} else {
			{ ..typing, typing: typing.typing.append({ key, until: now + typing.ttl }) }
		}

	## `key` stopped typing (sent it, cleared it, or left).
	stopped : Typing, Str -> Typing
	stopped = |typing, key| { ..typing, typing: typing.typing.drop_if(|typist| typist.key == key) }

	## Who is typing at `now`, in the order they started.
	who : Typing, U64 -> List(Str)
	who = |typing, now| typing.typing.keep_if(|typist| now < typist.until).map(|typist| typist.key)

	## The typists at `now`, without those whose ping ran out.
	sweep : Typing, U64 -> Typing
	sweep = |typing, now| { ..typing, typing: typing.typing.keep_if(|typist| now < typist.until) }

	## When the next ping runs out (`Err(Empty)` when no one is typing): when a page should look again.
	deadline : Typing -> Try(U64, [Empty])
	deadline = |typing| typing.typing.map(|typist| typist.until).min().map_err(|_| Empty)

	## What a page says, in English, for the names of who is typing: `""`, `"Ann is typing…"`,
	## `"Ann and Bo are typing…"`, `"Ann, Bo and 2 others are typing…"`.
	sentence : List(Str) -> Str
	sentence = |names|
		match names {
			[] => ""
			[one] => "${one} is typing…"
			_ => "${Stack.names(names, 3)} are typing…"
		}
}

expect {
	typing = Typing.new(6000).started("ann", 1000).started("bo", 2000)
	typing.who(2000) == ["ann", "bo"] and typing.who(7000) == ["bo"] and typing.who(8000) == []
}

# Another ping keeps a typist typing, in their place.
expect {
	typing = Typing.new(6000).started("ann", 1000).started("bo", 2000).started("ann", 5000)
	typing.who(7500) == ["ann", "bo"] and typing.who(9000) == ["ann"]
}

expect Typing.new(6000).started("ann", 1000).stopped("ann").who(1000) == []

expect {
	typing = Typing.new(6000).started("ann", 1000).started("bo", 3000)
	typing.deadline() == Ok(7000) and typing.sweep(7000).deadline() == Ok(9000) and typing.sweep(9000).deadline() == Err(Empty)
}

expect Typing.sentence([]) == ""
expect Typing.sentence(["Ann"]) == "Ann is typing…"
expect Typing.sentence(["Ann", "Bo"]) == "Ann and Bo are typing…"
expect Typing.sentence(["Ann", "Bo", "Cy", "Di"]) == "Ann, Bo and 2 others are typing…"
