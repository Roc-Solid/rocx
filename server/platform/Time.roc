import Host

## The time: the clock of the machine the server runs on.
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
}
