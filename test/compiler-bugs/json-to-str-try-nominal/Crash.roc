## `Json.to_str_try` of a record holding a nominal type with a derived `encoder_for` beside another
## field: `roc test Crash.roc` (and `roc check`, `roc build` of an app doing it) crashes the
## compiler in `boxy_lowering` on nightly-2026-11-18-a520eed.
Crash := [].{
	Badge := { name : Str }.{
		encoder_for : _
	}

	badge : Badge
	badge = { name: "Ada" }

	written : Str
	written =
		match Json.to_str_try({ id: "a1", badge }) {
			Ok(json) => json
			Err(_) => "unwritable"
		}
}

expect Crash.written == "{\"badge\":{\"name\":\"Ada\"},\"id\":\"a1\"}"
