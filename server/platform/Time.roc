import Host

## The time: the clock of the machine the server runs on.
Time := [].{

	## Milliseconds since the Unix epoch.
	now_millis! : {} => U64
	now_millis! = |{}| Host.now_millis!({})
}
