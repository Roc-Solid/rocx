import Host

## What happens while the app waits: the one place it waits, so a loop of `next!` is the app.
Events := [].{
	Event : [
		## Files changed, each an absolute path (`Watch.dir!`).
		Changed(List(Str)),

		## A child ended: its exit code (128 plus the signal's number when one ended it).
		Exited(U64, I32),

		## This program was sent a signal.
		Signal([Hangup, Interrupt, Terminate]),

		## The time given ran out.
		Timeout,
	]

	## The next event, or `Timeout` after `ms` milliseconds (0: wait for as long as it takes).
	next! : U64 => Event
	next! = |ms| {
		got = Host.next!(ms)
		match got.kind {
			1 => Changed(got.paths)
			2 => Exited(got.child, got.code)
			3 =>
				Signal(
					match got.code {
						1 => Hangup
						2 => Interrupt
						_ => Terminate
					},
				)
			_ => Timeout
		}
	}
}
