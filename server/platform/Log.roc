import Host

## The server's log: a line each, on stderr.
Log := [].{
	line! : Str => {}
	line! = |text| Host.log!(text)
}
