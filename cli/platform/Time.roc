import Host

Time := [].{

	## Milliseconds on a steady clock: for how long something took.
	now_ms! : {} => U64
	now_ms! = |{}| Host.now_ms!({})

	## Nanoseconds since the epoch, on the system's clock: to compare with a file's modification time
	## (`File.modified!`).
	now_ns! : {} => U64
	now_ns! = |{}| Host.now_ns!({})

	## Waits so many milliseconds. A program that also watches waits with `Events.next!` instead,
	## which a change, a child or a signal ends early.
	sleep! : U64 => {}
	sleep! = |ms| Host.sleep!(ms)
}
