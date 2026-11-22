import Host

## The time: the clock of the machine the server runs on. The web platform has a `Time` too, with
## `now_millis!` and `now_nanos!` (the browser's clock), so a component's handler reads it on both;
## a component reads neither while rendering, as the page would then differ between the server and
## the browser.
Time := [].{

	## Milliseconds since the Unix epoch.
	now_millis! : {} => U64
	now_millis! = |{}| Host.now_millis!({})

	## Nanoseconds since the Unix epoch, for timing what takes less than a millisecond (a query) and
	## for OpenTelemetry's timestamps. Its clock doesn't go back while the server runs, so the
	## difference of two readings is never negative:
	##
	## ```roc
	## started = Time.now_nanos!({})
	## rows = Db.all!(query, [])?
	## took = Time.now_nanos!({}) - started
	## ```
	now_nanos! : {} => U64
	now_nanos! = |{}| Host.now_nanos!({})

	## Waits `ms` milliseconds: the call that waits (a request, a job; a job's time limit ends the
	## wait) pauses, and holds no thread (D-027), so the server goes on answering others. For a
	## retry's pause, or an endpoint that is slow on purpose (a demo's latency).
	sleep! : U64 => {}
	sleep! = |ms| Host.sleep!(ms)
}
