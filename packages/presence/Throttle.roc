## A sender's rate limit that keeps the latest value: at most one send every `every` milliseconds,
## the first at once, and the last one never lost. A cursor that moves 120 times a second is sent
## 20 times a second (`every: 50`): each move in between replaces the one held, and the one held
## goes when its time comes (`flush`, from a timer the caller sets for `Hold(due)`), so the cursor
## ends where the pointer stopped.
##
## ```roc
## (throttle, Send(first)) = Throttle.new(50).push(first, 1000)  # sent now
## (throttle, Hold(1050)) = throttle.push(second, 1010)            # held, due at 1050
## (throttle, Hold(1050)) = throttle.push(third, 1020)             # held in its place
## (throttle, Send(third)) = throttle.flush(1050)                  # the latest, on time
## ```
Throttle(a) := { every : U64, sent : [Never, At(U64)], held : [Nothing, Held(a)] }.{

	## A throttle that sends at most once every `every` milliseconds.
	new : U64 -> Throttle(a)
	new = |every| { every, sent: Never, held: Nothing }

	## `value`, at `now`: `Send` it now, when nothing was sent within `every`; or `Hold` it, in place
	## of any held before, until `due`, when `flush` sends it.
	push : Throttle(a), a, U64 -> (Throttle(a), [Send(a), Hold(U64)])
	push = |throttle, value, now|
		match throttle.due() {
			Ok(at) if now < at => ({ ..throttle, held: Held(value) }, Hold(at))
			_ => ({ ..throttle, sent: At(now), held: Nothing }, Send(value))
		}

	## What is held, at `now`: `Send` it, once it is due; `Wait` until `due`, if it isn't yet (a
	## timer that fired early); `Idle` when nothing is held.
	flush : Throttle(a), U64 -> (Throttle(a), [Send(a), Wait(U64), Idle])
	flush = |throttle, now|
		match throttle.held {
			Nothing => (throttle, Idle)
			Held(value) =>
				match throttle.due() {
					Ok(at) if now < at => (throttle, Wait(at))
					_ => ({ ..throttle, sent: At(now), held: Nothing }, Send(value))
				}
		}

	## Forgets what is held: the pointer left the area, and its last place is no news.
	drop : Throttle(a) -> Throttle(a)
	drop = |throttle| { ..throttle, held: Nothing }

	## Whether a value is held, waiting for its time.
	is_holding : Throttle(a) -> Bool
	is_holding = |throttle|
		match throttle.held {
			Nothing => Bool.False
			Held(_) => Bool.True
		}

	## When the next send may go: `every` after the last, or `Err(Never)` when none has gone.
	due : Throttle(a) -> Try(U64, [Never])
	due = |throttle|
		match throttle.sent {
			Never => Err(Never)
			At(at) => Ok(at + throttle.every)
		}
}

sent : (Throttle(Str), [Send(Str), Hold(U64)]) -> Str
sent = |(_, said)|
	match said {
		Send(value) => value
		Hold(due) => "hold ${due.to_str()}"
	}

flushed : (Throttle(Str), [Send(Str), Wait(U64), Idle]) -> Str
flushed = |(_, said)|
	match said {
		Send(value) => value
		Wait(due) => "wait ${due.to_str()}"
		Idle => "idle"
	}

# The first goes at once; the next within `every` is held, and replaced by a later one.
expect {
	(one, first) = Throttle.new(50).push("a", 1000)
	(two, second) = one.push("b", 1010)
	(three, third) = two.push("c", 1020)
	first == Send("a") and second == Hold(1050) and third == Hold(1050) and three.is_holding()
}

# The one held goes when it is due, and not before.
expect {
	(one, _) = Throttle.new(50).push("a", 1000)
	(two, _) = one.push("b", 1010)
	flushed(two.flush(1049)) == "wait 1050" and flushed(two.flush(1050)) == "b"
}

# After a flush, the next is held for `every` from the flush.
expect {
	(one, _) = Throttle.new(50).push("a", 1000)
	(two, _) = one.push("b", 1010)
	(three, _) = two.flush(1050)
	sent(three.push("c", 1060)) == "hold 1100" and flushed(three.flush(2000)) == "idle"
}

# Once `every` has passed, the next goes at once.
expect {
	(one, _) = Throttle.new(50).push("a", 1000)
	sent(one.push("b", 1050)) == "b"
}

# Dropped: nothing to flush.
expect {
	(one, _) = Throttle.new(50).push("a", 1000)
	(two, _) = one.push("b", 1010)
	flushed(two.drop().flush(2000)) == "idle"
}

# A move every 8 ms for half a second, sent at most every 50 ms: 9 as they come, and the last when
# it is due.
expect {
	var $throttle = Throttle.new(50)
	var $sent = []
	var $at = 1000
	while $at < 1500 {
		(next, said) = $throttle.push($at, $at)
		$throttle = next
		match said {
			Send(value) => {
				$sent = $sent.append(value)
			}
			Hold(_) => {}
		}
		$at = $at + 8
	}
	(_, last) = $throttle.flush(1600)
	all =
		match last {
			Send(value) => $sent.append(value)
			_ => $sent
		}
	all.len() == 10 and all.last() == Ok(1496)
}
