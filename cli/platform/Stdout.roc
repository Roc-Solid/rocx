import Host

## This program's standard output. Writing can't fail here (a closed pipe is ignored); the `Try` is
## there so a caller's `?` reads as it does with other platforms.
Stdout := [].{
	line! : Str => Try({}, [StdoutErr(Str)])
	line! = |text| {
		Host.write!(1, "${text}\n")
		Ok({})
	}

	write! : Str => Try({}, [StdoutErr(Str)])
	write! = |text| {
		Host.write!(1, text)
		Ok({})
	}

	## Whether stdout is a terminal, not a file or a pipe.
	is_terminal! : {} => Bool
	is_terminal! = |{}| Host.is_terminal!(1)
}
