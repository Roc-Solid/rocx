import Host

## The time, in the browser: the clock of the machine the page is open on, under the server
## platform's names and types (`Time.now_millis!({})`), so a component's handler reads it on both.
##
## Read it in a handler, an effect's apply or a timer's tick, never while rendering (a component's
## body, a hole, a memo): the server rendered the page at another moment, so markup made from the
## time would differ from what the server sent, and hydration would refuse it. And the server's
## clock is the one to trust with what matters (a deadline, a date that decides what a page shows):
## a phone's clock may be wrong, and its timers drift and stall while it sleeps. A countdown, say,
## counts to a deadline the server gave, with this clock:
##
## ```roc
## deadline = Time.now_millis!({}) + left_ms # in an effect's apply, from what the server said
## left = deadline - U64.min(deadline, Time.now_millis!({})) # in each tick
## ```
##
## The server's `Time.sleep!` isn't here: in the browser, `set_timeout!` waits.
Time := [].{

	## Milliseconds since the Unix epoch (`Date.now()`).
	now_millis! : {} => U64
	now_millis! = |{}| Host.now_millis!({})

	## Nanoseconds since the Unix epoch, on a clock that doesn't go back while the page is open
	## (`performance.timeOrigin + performance.now()`), for timing what takes less than a millisecond:
	## the difference of two readings is never negative. Browsers round it, to a few microseconds or
	## more.
	now_nanos! : {} => U64
	now_nanos! = |{}| Host.now_nanos!({})
}
