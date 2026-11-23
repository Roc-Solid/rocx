## The builtin `Try` as JSON: `roc test Fails.roc` fails to compile on nightly-2026-11-18-a520eed
## ("does not have a method named encoder_for", and `parser_for`), though Builtin.roc declares both
## derived (`Try(ok, err) := [Ok(ok), Err(err)].{ parser_for : _, encoder_for : _ }`). Its expects
## pass on the fork since 4674b5973d.
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
