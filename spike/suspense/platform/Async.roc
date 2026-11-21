import Host

## Async values, read as plain values.
Async := [].{
	read! : Str => Str
	read! = |key| Host.async_read!(key)

	## Starts getting it, so reads don't wait for one another (Solid's memos start when made).
	start! : Str => {}
	start! = |key| Host.async_start!(key)
}
