## The same shape as a nominal type of the app's own, its codecs derived as Builtin.roc declares
## `Try`'s: `roc test Workaround.roc` passes. A structural tag union (`[Ok(a), Err(e)]`) passes too.
Workaround := [].{
	Outcome(ok, err) := [Ok(ok), Err(err)].{
		encoder_for : _
		parser_for : _
		is_eq : _
	}

	failed : Outcome(U64, Str)
	failed = Err("no")

	written : Str
	written =
		match Json.to_str_try(failed) {
			Ok(json) => json
			Err(_) => "unwritable"
		}

	parsed : Str -> Try(Outcome(U64, Str), [InvalidJson(Str)])
	parsed = |text| Json.parse(text)

	tagged : Str -> Try([Ok(U64), Err(Str)], [InvalidJson(Str)])
	tagged = |text| Json.parse(text)
}

expect Workaround.written == "{\"Err\":\"no\"}"
expect Workaround.parsed("{\"Ok\":5}") == Ok(Ok(5))
expect Workaround.tagged("{\"Err\":\"x\"}") == Ok(Err("x"))
