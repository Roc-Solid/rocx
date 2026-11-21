## A page's side of a typing indicator: when to tell others that it is typing. It pings when typing
## starts, and again at most every `every` milliseconds while it goes on, so those who hear it keep
## it typing (`Typing`, whose `ttl` should be twice `every`, or a little more); and it says when
## typing stops (the text sent, cleared, or the field left), if it had pinged.
##
## ```roc
## (typist, ping) = Typist.new(3000).typed(now)   # ping: Bool.True, the first key
## (typist, stop) = typist.done()                 # stop: Bool.True, it had pinged
## ```
Typist := { every : U64, sent : [Never, At(U64)] }.{

	## A typist that pings at most every `every` milliseconds.
	new : U64 -> Typist
	new = |every| { every, sent: Never }

	## A key was pressed at `now`: whether to ping (`Bool.True` when it hasn't within `every`).
	typed : Typist, U64 -> (Typist, Bool)
	typed = |typist, now|
		match typist.sent {
			At(at) if now < at + typist.every => (typist, Bool.False)
			_ => ({ ..typist, sent: At(now) }, Bool.True)
		}

	## Typing stopped: whether to say so (`Bool.True` when it had pinged, and those who heard it
	## still think it is typing).
	done : Typist -> (Typist, Bool)
	done = |typist|
		match typist.sent {
			Never => (typist, Bool.False)
			At(_) => ({ ..typist, sent: Never }, Bool.True)
		}

	## Whether it has pinged, and not stopped or rested since: those who heard it may think it is
	## typing.
	is_pinging : Typist -> Bool
	is_pinging = |typist|
		match typist.sent {
			Never => Bool.False
			At(_) => Bool.True
		}

	## The typist at `now`: once `every` has passed since its last ping with no key pressed, it
	## rests. The next key pings at once, as it would have; and a stop says nothing, since those who
	## heard the last ping let it run out by now, or soon (`Typing`'s `ttl`).
	rest : Typist, U64 -> Typist
	rest = |typist, now|
		match typist.sent {
			At(at) if now >= at + typist.every => { ..typist, sent: Never }
			_ => typist
		}
}

# A typist pings when typing starts, then at most every `every` while it goes on.
expect {
	(one, first) = Typist.new(3000).typed(1000)
	(two, second) = one.typed(2000)
	(three, third) = two.typed(4000)
	(four, stop) = three.done()
	(_, again) = four.done()
	first and !second and third and stop and !again
}

# Typing after a stop pings at once.
expect {
	(one, _) = Typist.new(3000).typed(1000)
	(two, _) = one.done()
	(_, ping) = two.typed(1500)
	ping
}

# Never pinged: nothing to stop.
expect {
	(_, stop) = Typist.new(3000).done()
	!stop
}

# Quiet for `every` after a ping: it rests, and its stop says nothing.
expect {
	(one, _) = Typist.new(3000).typed(1000)
	early = one.rest(3999)
	late = one.rest(4000)
	(_, stop) = late.done()
	early.is_pinging() and !late.is_pinging() and !stop
}
