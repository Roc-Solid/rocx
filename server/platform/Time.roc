import Host

Time := [].{

	## Milliseconds since the Unix epoch.
	now_millis! : {} => U64
	now_millis! = |{}| Host.now_millis!({})
}
