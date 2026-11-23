import Host

Stdin := [].{

	## Everything on stdin, to its end, as text (bytes that aren't UTF-8 replaced).
	read_to_end! : {} => Str
	read_to_end! = |{}| Host.stdin!({})
}
