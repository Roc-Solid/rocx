Opts := { suffix : (() -> Str) ?? (|| "!") }

shout = |s| {
	wrap = |_| {
		opts = Opts.{}
		Str.concat(s, (opts.suffix)())
	}
	wrap({})
}

expect shout("a") == "a!"
