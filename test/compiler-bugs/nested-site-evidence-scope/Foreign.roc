import Labels

ask = |s| {
	wrap = |_| {
		label = Labels.{}
		Str.concat(s, (label.suffix)())
	}
	wrap({})
}

expect ask("b") == "b?"
