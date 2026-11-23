import Host

## This program's standard error. Writing can't fail here; the `Try` is there so a caller's `?` reads
## as it does with other platforms.
Stderr := [].{
	line! : Str => Try({}, [StderrErr(Str)])
	line! = |text| {
		Host.write!(2, "${text}\n")
		Ok({})
	}

	write! : Str => Try({}, [StderrErr(Str)])
	write! = |text| {
		Host.write!(2, text)
		Ok({})
	}
}
