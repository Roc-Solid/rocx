import Host

Stdin := [].{

	## Everything on stdin, to its end, as text (bytes that aren't UTF-8 replaced).
	read_to_end! : {} => Str
	read_to_end! = |{}| Host.stdin!({})

	## One line, without its line ending (`\n`, or `\r\n`): `EndOfInput` when there is no more.
	line! : {} => Try(Str, [EndOfInput])
	line! = |{}|
		match Host.stdin_line!({}) {
			Ok(text) => Ok(text)
			Err(_) => Err(EndOfInput)
		}

	## Whether stdin is a terminal (someone typing), not a file or a pipe: whether to ask a question.
	is_terminal! : {} => Bool
	is_terminal! = |{}| Host.is_terminal!(0)
}
