import Hash
import RateLimit

## A rate limit's clients, by key (an address, a user, a route), each with what the limit keeps
## for it, in a bounded space: what the server keeps between requests. Each hit drops the clients
## whose state is back where a new client's starts (`RateLimit.idle`: forgetting them changes
## nothing), and past `room` clients, the one seen longest ago (which forgets its count: it is
## let off, rather than another refused).
##
##     { decision, tally } = Tally.hit(tally, RateLimit.per_minute(5), "203.0.113.7", now, 10000)
##
## The server keeps a limit's clients in several tallies (`Tally.shard(key, count)`), so a hit
## reads and writes a few hundred of them, not all.
Tally := { entries : List({ key : Str, state : RateLimit.State }) }.{

	## No clients.
	empty : Tally
	empty = { entries: [] }

	## One more request from the client `key` at `now`: what the limit says, and the tally after
	## it, with at most `room` clients.
	hit : Tally, RateLimit, Str, U64, U64 -> { decision : RateLimit.Decision, tally : Tally }
	hit = |tally, policy, key, now, room| {
		kept =
			match tally.entries.find_first(|each| each.key == key) {
				Ok(found) => found.state
				Err(_) => policy.fresh(now)
			}
		{ decision, state } = policy.check(kept, now)
		others = tally.entries.keep_if(|each| each.key != key and !RateLimit.idle(policy, each.state, now))
		# Most recently seen last, so the one seen longest ago is first.
		entries = if (RateLimit.idle(policy, state, now)) others else others.append({ key, state })
		over = U64.minus_saturated(entries.len(), room)
		{ decision, tally: { entries: entries.drop_first(over) } }
	}

	## How many clients it keeps.
	len : Tally -> U64
	len = |tally| tally.entries.len()

	## Whether it keeps `key`.
	keeps : Tally, Str -> Bool
	keeps = |tally, key| tally.entries.any(|each| each.key == key)

	## As text, to keep it as a string (JSON).
	to_str : Tally -> Str
	to_str = |tally| Json.to_str(tally.entries)

	## From `to_str`'s text: empty, from text that isn't one (nothing kept yet).
	from_str : Str -> Tally
	from_str = |text| {
		parsed : Try(List({ key : Str, state : RateLimit.State }), [InvalidJson(Str)])
		parsed = Json.parse(text)
		match parsed {
			Ok(entries) => { entries: entries }
			Err(_) => Tally.empty
		}
	}

	## Which of `count` tallies keeps `key`: the same one each time.
	shard : Str, U64 -> U64
	shard = |key, count| Hash.bucket(key, count)
}

## Hits at the given times, each for its key: whether each was allowed, and the tally after.
hits : RateLimit, List((Str, U64)), U64 -> { allowed : List(Bool), tally : Tally }
hits = |policy, requests, room| {
	var $tally = Tally.empty
	var $allowed = []
	for (key, now) in requests {
		{ decision, tally } = Tally.hit($tally, policy, key, now, room)
		$tally = tally
		$allowed = $allowed.append(decision.allowed)
	}
	{ allowed: $allowed, tally: $tally }
}

limit = RateLimit.per_minute(2)

# Each key has its own limit.
expect hits(limit, [("a", 0), ("a", 0), ("a", 0), ("b", 0), ("b", 0)], 100).allowed == [Bool.True, Bool.True, Bool.False, Bool.True, Bool.True]
# A key whose bucket is full again (one token back each 30 s) is dropped: nothing about it is
# worth keeping.
expect {
	after = hits(limit, [("a", 0), ("b", 29999)], 100).tally
	after.keeps("a") and after.keeps("b")
}
expect {
	after = hits(limit, [("a", 0), ("b", 30000)], 100).tally
	!after.keeps("a") and after.keeps("b") and after.len() == 1
}
# Past its room, the key seen longest ago goes, and starts again.
expect {
	ran = hits(limit, [("a", 0), ("a", 0), ("b", 1), ("c", 2), ("a", 3)], 2)
	ran.allowed == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True] and !ran.tally.keeps("b") and ran.tally.keeps("c") and ran.tally.keeps("a")
}
# Within its room, nobody is let off.
expect hits(limit, [("a", 0), ("a", 0), ("b", 1), ("a", 3)], 2).allowed == [Bool.True, Bool.True, Bool.True, Bool.False]
# Seeing a key again moves it last: the one seen longest ago is the one that goes.
expect {
	ran = hits(limit, [("a", 0), ("b", 1), ("a", 2), ("c", 3)], 2)
	ran.tally.keeps("a") and !ran.tally.keeps("b")
}
# A limit of 0 keeps nothing: a new client's state is already where it would be.
expect hits(RateLimit.per_minute(0), [("a", 0), ("a", 1)], 10).tally.len() == 0
# A sliding window's tally too.
expect hits(RateLimit.per_second(2).sliding(), [("a", 0), ("a", 10), ("a", 20), ("b", 20)], 10).allowed == [Bool.True, Bool.True, Bool.False, Bool.True]
expect hits(RateLimit.per_second(2).sliding(), [("a", 0), ("b", 2000)], 10).tally.len() == 1

# As text and back, the same; text that isn't a tally is an empty one.
expect {
	tally = hits(limit, [("a", 0), ("b \"quoted\"\n", 5)], 10).tally
	back = Tally.from_str(tally.to_str())
	back.len() == 2 and back.keeps("b \"quoted\"\n") and back.to_str() == tally.to_str()
}
expect Tally.from_str("").len() == 0
expect Tally.from_str("{nonsense").len() == 0

expect Tally.shard("203.0.113.7", 16) == Tally.shard("203.0.113.7", 16)
expect Tally.shard("203.0.113.7", 16) < 16
