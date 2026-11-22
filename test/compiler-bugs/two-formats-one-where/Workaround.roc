## The same two formats, each asked for by a function of its own, and both used on one type:
## `roc test Workaround.roc` passes. rocx does this (D-038): `Endpoint.local` keeps a reader of a
## form's fields made with `FormBody`, and `Endpoint.respond!` asks only for `Json.Parseable`.
Workaround := [].{
	Shape := [Default].{
		parse_str : Shape, U64 -> Try({ value : Str, rest : U64 }, [Bad])
		parse_str = |_, state| Ok({ value: "s", rest: state })

		parse_record_start : Shape, U64 -> Try([Counted({ len : U64, rest : U64 }), Uncounted(U64)], [Bad])
		parse_record_start = |_, state| Ok(Uncounted(state))

		parse_record_field : Shape, Encoding.FieldName.FieldNames(_shape), U64 -> Try([Field({ field : Encoding.FieldName(_shape), rest : U64 }), TryField({ name : Str, rest : U64 }), TryFieldCaseless({ name : Str, rest : U64 }), Continue(U64), Done(U64)], [Bad])
		parse_record_field = |_, names, state| {
			var $index = 0
			for field in Encoding.FieldName.FieldNames.iter(names) {
				if $index == state {
					return Ok(Field({ field: field, rest: state + 1 }))
				}
				$index = $index + 1
			}
			Ok(Done(state))
		}

		parse_record_after_field : Shape, U64 -> Try([Continue(U64), Done(U64)], [Bad])
		parse_record_after_field = |_, state| Ok(Continue(state))

		skip_record_field : Shape, U64 -> Try(U64, [Bad])
		skip_record_field = |_, state| Ok(state)

		missing_field : Shape, Str -> [Bad]
		missing_field = |_, _| Bad

		rename_field : Shape, Str -> Str
		rename_field = |_, name| name

		a.Readable : where [a.parser_for : Shape -> (U64 -> Try({ value : a, rest : U64 }, [Bad]))]
	}

	shaped : {} -> Try(a, [Bad]) where [a.Shape.Readable]
	shaped = |{}| {
		T : a
		parsed = T.parser_for(Shape.Default)(0)?
		Ok(parsed.value)
	}

	json : Str -> Try(a, [InvalidJson(Str)]) where [a.Json.Parseable([InvalidJson(Str)])]
	json = |text| Json.parse(text)
}

expect {
	got : Try({ a : Str, b : Str }, [Bad])
	got = Workaround.shaped({})
	got == Ok({ a: "s", b: "s" })
}

expect {
	got : Try({ a : Str, b : Str }, [InvalidJson(Str)])
	got = Workaround.json("{\"a\":\"x\",\"b\":\"y\"}")
	got == Ok({ a: "x", b: "y" })
}
