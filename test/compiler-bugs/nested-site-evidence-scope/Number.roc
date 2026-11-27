Opts := { f : (U8 -> U8) ?? (|n| n + 1) }

add = |s| {
	wrap = |_| {
		opts = Opts.{}
		Str.concat(s, (opts.f)(4).to_str())
	}
	wrap({})
}

expect add("a") == "a5"
