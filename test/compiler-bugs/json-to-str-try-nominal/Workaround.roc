## The same, through a function whose error type is an open union naming the floats' failures,
## as the platforms' `Server`, `Call`, `Endpoint` and `Browser` write it: `roc test Workaround.roc`
## passes. A type variable there (`Encodable(e)`) crashes as Crash.roc does. `[..]` passes here,
## but crashed in a bigger app once an `F64` was beside the nominal type, so the platforms name
## the floats' failures.
Workaround := [].{
	Badge := { name : Str }.{
		encoder_for : _
	}

	Point := { x : F64 }.{
		encoder_for : _
	}

	write : a -> Str where [a.Json.Encodable([Infinity, NaN, NegativeInfinity, ..])]
	write = |value|
		match Json.to_str_try(value) {
			Ok(json) => json
			Err(_) => "unwritable"
		}

	badge : Badge
	badge = { name: "Ada" }
}

expect Workaround.write({ id: "a1", badge: Workaround.badge }) == "{\"badge\":{\"name\":\"Ada\"},\"id\":\"a1\"}"
expect Workaround.write([{ id: "a1", badge: Workaround.badge }]) == "[{\"badge\":{\"name\":\"Ada\"},\"id\":\"a1\"}]"
expect Workaround.write((Workaround.badge, 1.5)) == "[{\"name\":\"Ada\"},1.5]"
expect Workaround.write({ user: SignedIn({ id: "a1", badge: Workaround.badge }) }) == "{\"user\":{\"SignedIn\":{\"badge\":{\"name\":\"Ada\"},\"id\":\"a1\"}}}"
expect {
	point : Workaround.Point
	point = { x: 0.0 / 0.0 }
	Workaround.write({ point, badge: Workaround.badge }) == "unwritable"
}
