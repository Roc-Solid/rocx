## A function whose where clause asks a type to be parseable in two formats, `Json`'s and a
## format of the module's own (`Shape`, which reads every field as "s"): `roc test Crash.roc`
## crashes the compiler in `boxy_lowering` (SIGSEGV) on rocx-fork-3f66e242ea. It crashes whichever
## format the body uses: `either` here uses only `Json`.
Crash := [].{
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

	either : Str -> Try(a, [InvalidJson(Str)]) where [a.Shape.Readable, a.Json.Parseable([InvalidJson(Str)])]
	either = |text| Json.parse(text)
}

expect {
	got : Try({ a : Str }, [InvalidJson(Str)])
	got = Crash.either("{\"a\":\"x\"}")
	got == Ok({ a: "x" })
}
