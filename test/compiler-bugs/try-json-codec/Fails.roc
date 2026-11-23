## The builtin `Try` as JSON: `roc test Fails.roc` fails to compile ("does not have a method named
## encoder_for", and `parser_for`), on the fork rocx pins and on nightly-2026-11-18-a520eed, though
## Builtin.roc declares both derived (`Try(ok, err) := [Ok(ok), Err(err)].{ parser_for : _,
## encoder_for : _ }`).
Fails := [].{
	failed : Try(U64, Str)
	failed = Err("no")

	written : Str
	written =
		match Json.to_str_try(failed) {
			Ok(json) => json
			Err(_) => "unwritable"
		}

	parsed : Str -> Try(Try(U64, Str), [InvalidJson(Str)])
	parsed = |text| Json.parse(text)
}

expect Fails.written == "{\"Err\":\"no\"}"
expect Fails.parsed("{\"Ok\":5}") == Ok(Ok(5))
