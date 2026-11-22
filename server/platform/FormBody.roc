## A form's body (`name=Ada&count=2&tags=a&tags=b`, as a browser posts a form) read as the record
## an endpoint declares, field by field, by each field's type, as `Json` reads JSON (D-038): so one
## typed endpoint takes a plain form, the runtime's form, an action's JSON and a script's alike. A
## format of the decoding ability `Json` is one of; `Endpoint.local` and `remote` keep its reader
## for their arg (`Endpoint.respond!`, `Submission.input!` use it).
##
## - `Str`: the text as typed (an empty one too). Missing, the body is refused, naming the field.
## - A number (`U64`, `I32`, `Dec`, `F64`…): read from its text, spaces around it dropped. Missing or
##   empty, refused, naming the field; text that isn't one of its type, too.
## - `Bool`: `on` (a ticked checkbox), `true` or `1` are true; `false`, `0` or empty are false;
##   missing (a checkbox left unticked) is false.
## - `List`: every value the field has, in order (boxes that share a name, a multiple `<select>`),
##   each read as its type; missing, `[]`.
## - A tag union of tags with no payload (`[Low, High]`): the tag the text names.
## - A field the body has twice that isn't a list: its last value (a hidden input before a checkbox
##   of the same name is its default).
##
## A field the record doesn't have is let be. A record inside a field, a tuple, a dict or a tag
## with a payload has no form of its own: such a body is refused, saying so.
FormBody := [Default].{

	## Where the format is: the body's fields; the index of the record's field that comes next;
	## and what it is reading, the record's fields (`Fields`), one field's values (`Values`, with
	## its name) or a list's items still to come (`Items`).
	State : { fields : List({ name : Str, value : Str }), next : U64, at : [Top, Fields, Values(Str, List(Str)), Items(Str, List(Str)), Read] }

	## Why a body couldn't be read: a field it lacks, a value that isn't the field's type (the
	## field, and why), or a shape a form doesn't have.
	Problem : [Missing(Str), Bad(Str, Str), NoForm(Str)]

	## What a type must be to be read from a form: as `Json.Parseable`, for this format.
	a.Readable : where [a.parser_for : FormBody -> (FormBody.State -> Try({ value : a, rest : FormBody.State }, FormBody.Problem))]

	## The body's fields, as their record (`a`), or why not, in words naming the field.
	parse : List({ name : Str, value : Str }) -> Try(a, Str) where [a.FormBody.Readable]
	parse = |fields| {
		Shape : a
		match Shape.parser_for(FormBody.Default)({ fields: fields, next: 0, at: Top }) {
			Ok(parsed) => Ok(parsed.value)
			Err(Missing(name)) => Err("the field ${name} is missing")
			Err(Bad(name, why)) => Err("the field ${name} ${why}")
			Err(NoForm(why)) => Err(why)
		}
	}

	rename_field : FormBody, Str -> Str
	rename_field = |_, name| name

	missing_field : FormBody, Str -> Problem
	missing_field = |_, name| Missing(name)

	invalid_value : FormBody, State -> Problem
	invalid_value = |_, state| Bad(name_of(state), "isn't one of its choices")

	parse_str : FormBody, State -> Try({ value : Str, rest : State }, Problem)
	parse_str = |_, state| {
		found = taken(state)?
		Ok({ value: found.text, rest: found.rest })
	}

	parse_bool : FormBody, State -> Try({ value : Bool, rest : State }, Problem)
	parse_bool = |_, state|
		match state.at {
			Values(_, []) => Ok({ value: Bool.False, rest: { ..state, at: Read } })
			_ => {
				found = taken(state)?
				lower = found.text.trim().with_ascii_lowercased()
				if lower == "on" or lower == "true" or lower == "1" {
					Ok({ value: Bool.True, rest: found.rest })
				} else if lower == "false" or lower == "0" or lower.is_empty() {
					Ok({ value: Bool.False, rest: found.rest })
				} else {
					Err(Bad(found.name, "is yes or no (on, true or 1; false, 0 or nothing), not ${Json.to_str(found.text)}"))
				}
			}
		}

	parse_u8 : FormBody, State -> Try({ value : U8, rest : State }, Problem)
	parse_u8 = |_, state| number(state, U8.from_str, "a whole number from 0 to 255")

	parse_i8 : FormBody, State -> Try({ value : I8, rest : State }, Problem)
	parse_i8 = |_, state| number(state, I8.from_str, "a whole number from -128 to 127")

	parse_u16 : FormBody, State -> Try({ value : U16, rest : State }, Problem)
	parse_u16 = |_, state| number(state, U16.from_str, "a whole number from 0 to 65535")

	parse_i16 : FormBody, State -> Try({ value : I16, rest : State }, Problem)
	parse_i16 = |_, state| number(state, I16.from_str, "a whole number from -32768 to 32767")

	parse_u32 : FormBody, State -> Try({ value : U32, rest : State }, Problem)
	parse_u32 = |_, state| number(state, U32.from_str, "a whole number, 0 or more")

	parse_i32 : FormBody, State -> Try({ value : I32, rest : State }, Problem)
	parse_i32 = |_, state| number(state, I32.from_str, "a whole number")

	parse_u64 : FormBody, State -> Try({ value : U64, rest : State }, Problem)
	parse_u64 = |_, state| number(state, U64.from_str, "a whole number, 0 or more")

	parse_i64 : FormBody, State -> Try({ value : I64, rest : State }, Problem)
	parse_i64 = |_, state| number(state, I64.from_str, "a whole number")

	parse_u128 : FormBody, State -> Try({ value : U128, rest : State }, Problem)
	parse_u128 = |_, state| number(state, U128.from_str, "a whole number, 0 or more")

	parse_i128 : FormBody, State -> Try({ value : I128, rest : State }, Problem)
	parse_i128 = |_, state| number(state, I128.from_str, "a whole number")

	parse_dec : FormBody, State -> Try({ value : Dec, rest : State }, Problem)
	parse_dec = |_, state| number(state, Dec.from_str, "a number")

	parse_f32 : FormBody, State -> Try({ value : F32, rest : State }, Problem)
	parse_f32 = |_, state| number(state, F32.from_str, "a number")

	parse_f64 : FormBody, State -> Try({ value : F64, rest : State }, Problem)
	parse_f64 = |_, state| number(state, F64.from_str, "a number")

	parse_null : FormBody, State -> Try(State, Problem)
	parse_null = |_, state| Err(shapeless(state, "can't be null"))

	## A list: the field's values, each an item, as many as there are.
	parse_list_start : FormBody, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_list_start = |_, state|
		match state.at {
			Values(name, values) => Ok(Counted({ len: values.len(), rest: { ..state, at: Items(name, values) } }))
			_ => Err(shapeless(state, "can't be a list inside a list"))
		}

	parse_list_next : FormBody, State -> Try([Item(State), Done(State)], Problem)
	parse_list_next = |_, state| Ok(Done(state))

	parse_list_after_item : FormBody, State -> Try([Continue(State), Done(State)], Problem)
	parse_list_after_item = |_, state| Ok(Done(state))

	parse_tuple_start : FormBody, State, U64 -> Try(State, Problem)
	parse_tuple_start = |_, state, _| Err(shapeless(state, "can't be a tuple"))

	parse_tuple_next : FormBody, State, U64, U64 -> Try(State, Problem)
	parse_tuple_next = |_, state, _, _| Ok(state)

	parse_tuple_end : FormBody, State, U64 -> Try(State, Problem)
	parse_tuple_end = |_, state, _| Ok(state)

	## The body's record: each of its fields, in turn, with the values the body has for it.
	parse_record_start : FormBody, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_record_start = |_, state|
		match state.at {
			Top => Ok(Uncounted({ ..state, next: 0, at: Fields }))
			_ => Err(shapeless(state, "can't be a record: a form's fields are flat"))
		}

	parse_record_field : FormBody, Encoding.FieldName.FieldNames(_shape), State -> Try([Field({ field : Encoding.FieldName(_shape), rest : State }), TryField({ name : Str, rest : State }), TryFieldCaseless({ name : Str, rest : State }), Continue(State), Done(State)], Problem)
	parse_record_field = |_, names, state| {
		var $index = 0
		for field in Encoding.FieldName.FieldNames.iter(names) {
			if $index == state.next {
				name = field.name()
				values = state.fields.keep_if(|each| each.name == name).map(|each| each.value)
				return Ok(Field({ field: field, rest: { ..state, next: state.next + 1, at: Values(name, values) } }))
			}
			$index = $index + 1
		}
		Ok(Done(state))
	}

	parse_record_after_field : FormBody, State -> Try([Continue(State), Done(State)], Problem)
	parse_record_after_field = |_, state| Ok(Continue({ ..state, at: Fields }))

	skip_record_field : FormBody, State -> Try(State, Problem)
	skip_record_field = |_, state| Ok(state)

	parse_dict_start : FormBody, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_dict_start = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_dict_next : FormBody, State -> Try([Entry(State), Done(State)], Problem)
	parse_dict_next = |_, state| Ok(Done(state))

	parse_dict_after_key : FormBody, State -> Try(State, Problem)
	parse_dict_after_key = |_, state| Ok(state)

	parse_dict_after_entry : FormBody, State -> Try([Continue(State), Done(State)], Problem)
	parse_dict_after_entry = |_, state| Ok(Done(state))

	parse_key_str : FormBody, State -> Try({ value : Str, rest : State }, Problem)
	parse_key_str = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_bool : FormBody, State -> Try({ value : Bool, rest : State }, Problem)
	parse_key_bool = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_u8 : FormBody, State -> Try({ value : U8, rest : State }, Problem)
	parse_key_u8 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_i8 : FormBody, State -> Try({ value : I8, rest : State }, Problem)
	parse_key_i8 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_u16 : FormBody, State -> Try({ value : U16, rest : State }, Problem)
	parse_key_u16 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_i16 : FormBody, State -> Try({ value : I16, rest : State }, Problem)
	parse_key_i16 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_u32 : FormBody, State -> Try({ value : U32, rest : State }, Problem)
	parse_key_u32 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_i32 : FormBody, State -> Try({ value : I32, rest : State }, Problem)
	parse_key_i32 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_u64 : FormBody, State -> Try({ value : U64, rest : State }, Problem)
	parse_key_u64 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_i64 : FormBody, State -> Try({ value : I64, rest : State }, Problem)
	parse_key_i64 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_u128 : FormBody, State -> Try({ value : U128, rest : State }, Problem)
	parse_key_u128 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_i128 : FormBody, State -> Try({ value : I128, rest : State }, Problem)
	parse_key_i128 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_dec : FormBody, State -> Try({ value : Dec, rest : State }, Problem)
	parse_key_dec = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_f32 : FormBody, State -> Try({ value : F32, rest : State }, Problem)
	parse_key_f32 = |_, state| Err(shapeless(state, "can't be a dict"))

	parse_key_f64 : FormBody, State -> Try({ value : F64, rest : State }, Problem)
	parse_key_f64 = |_, state| Err(shapeless(state, "can't be a dict"))

	## A tag union: the tag the field's text names, which must have no payload.
	parse_tag_union : FormBody, Encoding.ParseTagUnionSpec(a, FormBody, State, Problem), State -> Try({ value : a, rest : State }, Problem)
	parse_tag_union = |format, spec, state| {
		found = taken(state)?
		name = found.name
		Encoding.ParseTagUnionSpec.parse(
			spec,
			{
				tag: found.text.trim(),
				encoding: format,
				state: found.rest,
				start_payloads: |payload, count| if (count == 0) Ok(payload) else Err(Bad(name, "names a choice with more to it than a form can say")),
				next_payload: |_, _, _| Err(Bad(name, "names a choice with more to it than a form can say")),
				finish_payloads: |payload, _| Ok(payload),
				missing: Bad(name, "isn't one of its choices: ${Json.to_str(found.text)}"),
			},
		)
	}
}

## The value the format is at, as text, and the state after it: a field's last value, or a list's
## next item. A field the body hasn't (or a number left empty) is missing.
taken : FormBody.State -> Try({ text : Str, name : Str, rest : FormBody.State }, FormBody.Problem)
taken = |state|
	match state.at {
		Values(name, values) =>
			match values.last() {
				Ok(text) => Ok({ text: text, name: name, rest: { ..state, at: Read } })
				Err(_) => Err(Missing(name))
			}
		Items(name, values) =>
			match values.first() {
				Ok(text) => Ok({ text: text, name: name, rest: { ..state, at: Items(name, values.drop_first(1)) } })
				Err(_) => Err(Missing(name))
			}
		_ => Err(NoForm("a form's body is read as a record of its fields"))
	}

## A number of the field's, read from its text by `from_str`; empty is missing.
number : FormBody.State, (Str -> Try(n, _)), Str -> Try({ value : n, rest : FormBody.State }, FormBody.Problem)
number = |state, from_str, kind| {
	found = taken(state)?
	text = found.text.trim()
	if text.is_empty() {
		Err(Missing(found.name))
	} else {
		match from_str(text) {
			Ok(value) => Ok({ value: value, rest: found.rest })
			Err(_) => Err(Bad(found.name, "needs ${kind}, not ${Json.to_str(found.text)}"))
		}
	}
}

## The name of the field the format is at, or "" at the top.
name_of : FormBody.State -> Str
name_of = |state|
	match state.at {
		Values(name, _) => name
		Items(name, _) => name
		_ => ""
	}

## A shape a form has no way to send: refused, naming the field.
shapeless : FormBody.State, Str -> FormBody.Problem
shapeless = |state, why|
	match name_of(state) {
		"" => NoForm("a form's body ${why}")
		name => Bad(name, why)
	}

pairs_of : List((Str, Str)) -> List({ name : Str, value : Str })
pairs_of = |pairs| pairs.map(|(name, value)| { name: name, value: value })

expect {
	got : Try({ name : Str, count : U64, ok : Bool, off : Bool, tags : List(Str), none : List(U64), price : Dec, level : [Low, High] }, Str)
	got = FormBody.parse(pairs_of([("name", "Ada"), ("count", " 2 "), ("ok", "on"), ("tags", "a"), ("tags", "b"), ("price", "1.5"), ("level", "High"), ("extra", "x")]))
	got == Ok({ name: "Ada", count: 2, ok: Bool.True, off: Bool.False, tags: ["a", "b"], none: [], price: 1.5, level: High })
}
expect {
	got : Try({ name : Str }, Str)
	got = FormBody.parse(pairs_of([]))
	got == Err("the field name is missing")
}
expect {
	got : Try({ name : Str }, Str)
	got = FormBody.parse(pairs_of([("name", "")]))
	got == Ok({ name: "" })
}
expect {
	got : Try({ count : U64 }, Str)
	got = FormBody.parse(pairs_of([("count", "")]))
	got == Err("the field count is missing")
}
expect {
	got : Try({ count : U64 }, Str)
	got = FormBody.parse(pairs_of([("count", "two")]))
	got == Err("the field count needs a whole number, 0 or more, not \"two\"")
}
expect {
	got : Try({ ok : Bool }, Str)
	got = FormBody.parse(pairs_of([("ok", "maybe")]))
	got == Err("the field ok is yes or no (on, true or 1; false, 0 or nothing), not \"maybe\"")
}
expect {
	got : Try({ ok : Bool, a : Bool, b : Bool }, Str)
	got = FormBody.parse(pairs_of([("ok", "false"), ("ok", "on"), ("a", "1"), ("b", "0")]))
	got == Ok({ ok: Bool.True, a: Bool.True, b: Bool.False })
}
expect {
	got : Try({ ids : List(U64) }, Str)
	got = FormBody.parse(pairs_of([("ids", "1"), ("ids", "x")]))
	got == Err("the field ids needs a whole number, 0 or more, not \"x\"")
}
expect {
	got : Try({ level : [Low, High] }, Str)
	got = FormBody.parse(pairs_of([("level", "Middle")]))
	got == Err("the field level isn't one of its choices: \"Middle\"")
}
expect {
	got : Try({ inner : { a : Str } }, Str)
	got = FormBody.parse(pairs_of([("a", "x")]))
	got == Err("the field inner can't be a record: a form's fields are flat")
}
expect {
	got : Try({}, Str)
	got = FormBody.parse(pairs_of([("a", "x")]))
	got == Ok({})
}
