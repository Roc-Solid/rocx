## A format that reads nothing: a type's parser, given it, says what the type is made of. Roc has
## no reflection, but a derived parser is one for any format, and is handed each record's field
## names; each field's parser then asks for what its type is (`parse_i64`, `parse_str`, a record, a
## list). So a row type's parser, run with `Probe`, tells its fields, the kind of each, and whether
## each tries `parse_null` first, as `Db.Nullable(a)`'s parser does, which only one of two passes
## can see: `Nulls` answers every `parse_null` with "null", so the fields that ask are found;
## `Kinds` answers "not null", so their inner type's parser is reached. roc-pg's `RowFormat` and
## the platform's `OpenApi.Schema` read types the same way.
##
## A tag union's parser doesn't say its tags, so the probe tries each name it is given (`State.tags`)
## until one is the union's: rocx gives it the capitalized names in the app's code.
Probe := [Nulls, Kinds].{

	## A field of the row: its name, what its type reads (`integer`, `float`, `string`, `boolean`,
	## `tags`, `json` for a record, a list, a dict or a tuple; `` when its parser asked for nothing
	## the probe knows), and whether it tries null first.
	Field : { name : Str, kind : Str, nullable : Bool }

	## Where the probe is: the row's fields, which one it reads (`current`), how deep it is (the row's
	## own fields are at 1), each record's next field (`at`), and the names a tag union is tried with.
	State : { fields : List(Field), current : U64, depth : U64, at : List(U64), tags : List(Str) }

	## Why a type couldn't be read: a tag union none of the names are tags of; a record field missing.
	Problem : [NoTags, NotNull, MissingField(Str), Invalid]

	## The start: nothing read, the names to try as tags.
	start : List(Str) -> State
	start = |tags| { fields: [], current: 0, depth: 0, at: [], tags }

	## The row's fields, from its parser run in each pass (`Nulls`, then `Kinds`); `Err` when the
	## type isn't a record, or a tag union in it had none of the names.
	fields : Try({ value : a, rest : State }, Problem), Try({ value : a, rest : State }, Problem) -> Try(List(Field), Problem)
	fields = |nulls, kinds| {
		nullable = nulls?.rest.fields
		kinded = kinds?.rest.fields
		Ok(kinded.map(|field| { ..field, nullable: nullable.any(|each| each.name == field.name and each.nullable) }))
	}

	rename_field : Probe, Str -> Str
	rename_field = |_, name| name

	missing_field : Probe, Str -> Problem
	missing_field = |_, name| MissingField(name)

	invalid_value : Probe, State -> Problem
	invalid_value = |_, _| Invalid

	parse_str : Probe, State -> Try({ value : Str, rest : State }, Problem)
	parse_str = |_, state| Ok({ value: "", rest: kind(state, "string") })

	parse_bool : Probe, State -> Try({ value : Bool, rest : State }, Problem)
	parse_bool = |_, state| Ok({ value: False, rest: kind(state, "boolean") })

	parse_u8 : Probe, State -> Try({ value : U8, rest : State }, Problem)
	parse_u8 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_i8 : Probe, State -> Try({ value : I8, rest : State }, Problem)
	parse_i8 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_u16 : Probe, State -> Try({ value : U16, rest : State }, Problem)
	parse_u16 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_i16 : Probe, State -> Try({ value : I16, rest : State }, Problem)
	parse_i16 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_u32 : Probe, State -> Try({ value : U32, rest : State }, Problem)
	parse_u32 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_i32 : Probe, State -> Try({ value : I32, rest : State }, Problem)
	parse_i32 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_u64 : Probe, State -> Try({ value : U64, rest : State }, Problem)
	parse_u64 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_i64 : Probe, State -> Try({ value : I64, rest : State }, Problem)
	parse_i64 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_u128 : Probe, State -> Try({ value : U128, rest : State }, Problem)
	parse_u128 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_i128 : Probe, State -> Try({ value : I128, rest : State }, Problem)
	parse_i128 = |_, state| Ok({ value: 0, rest: kind(state, "integer") })

	parse_dec : Probe, State -> Try({ value : Dec, rest : State }, Problem)
	parse_dec = |_, state| Ok({ value: 0, rest: kind(state, "float") })

	parse_f32 : Probe, State -> Try({ value : F32, rest : State }, Problem)
	parse_f32 = |_, state| Ok({ value: 0, rest: kind(state, "float") })

	parse_f64 : Probe, State -> Try({ value : F64, rest : State }, Problem)
	parse_f64 = |_, state| Ok({ value: 0, rest: kind(state, "float") })

	## `Nulls`: "null", and a row's field that asks is one that may be; `Kinds`: "not null", so the
	## type's own parser goes on.
	parse_null : Probe, State -> Try(State, Problem)
	parse_null = |format, state|
		match format {
			Nulls => Ok(if (state.depth == 1) mark(state, |field| { ..field, nullable: True }) else state)
			Kinds => Err(NotNull)
		}

	## A list: JSON, read as no items.
	parse_list_start : Probe, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_list_start = |_, state| Ok(Counted({ len: 0, rest: kind(state, "json") }))

	parse_list_next : Probe, State -> Try([Item(State), Done(State)], Problem)
	parse_list_next = |_, state| Ok(Done(state))

	parse_list_after_item : Probe, State -> Try([Continue(State), Done(State)], Problem)
	parse_list_after_item = |_, state| Ok(Done(state))

	## A tuple (a tag's payloads too): JSON, its items read one level deeper.
	parse_tuple_start : Probe, State, U64 -> Try(State, Problem)
	parse_tuple_start = |_, state, _| Ok(deeper(kind(state, "json")))

	parse_tuple_next : Probe, State, U64, U64 -> Try(State, Problem)
	parse_tuple_next = |_, state, _, _| Ok(state)

	parse_tuple_end : Probe, State, U64 -> Try(State, Problem)
	parse_tuple_end = |_, state, _| Ok(shallower(state))

	## A record: the row itself (its fields learned from the names it is handed), or, deeper, JSON.
	parse_record_start : Probe, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_record_start = |_, state| {
		marked = if (state.depth == 0) state else kind(state, "json")
		Ok(Uncounted({ ..deeper(marked), at: marked.at.append(0) }))
	}

	## Each of a record's fields in turn, by name; then done. The row's own, as it goes, are its fields.
	parse_record_field : Probe, Encoding.FieldName.FieldNames(_shape), State -> Try([Field({ field : Encoding.FieldName(_shape), rest : State }), TryField({ name : Str, rest : State }), TryFieldCaseless({ name : Str, rest : State }), Continue(State), Done(State)], Problem)
	parse_record_field = |_, names, state| {
		next = state.at.last() ?? 0
		var $index = 0
		for field in Encoding.FieldName.FieldNames.iter(names) {
			if $index == next {
				moved = { ..state, at: state.at.drop_last(1).append(next + 1) }
				rest = if (state.depth == 1) { ..moved, fields: moved.fields.append({ name: field.name(), kind: "", nullable: False }), current: moved.fields.len() } else moved
				return Ok(Field({ field: field, rest }))
			}
			$index = $index + 1
		}
		Ok(Done(shallower({ ..state, at: state.at.drop_last(1) })))
	}

	parse_record_after_field : Probe, State -> Try([Continue(State), Done(State)], Problem)
	parse_record_after_field = |_, state| Ok(Continue(state))

	skip_record_field : Probe, State -> Try(State, Problem)
	skip_record_field = |_, state| Ok(state)

	## A dict: JSON, read as no entries.
	parse_dict_start : Probe, State -> Try([Counted({ len : U64, rest : State }), Uncounted(State)], Problem)
	parse_dict_start = |_, state| Ok(Counted({ len: 0, rest: kind(state, "json") }))

	parse_dict_next : Probe, State -> Try([Entry(State), Done(State)], Problem)
	parse_dict_next = |_, state| Ok(Done(state))

	parse_dict_after_key : Probe, State -> Try(State, Problem)
	parse_dict_after_key = |_, state| Ok(state)

	parse_dict_after_entry : Probe, State -> Try([Continue(State), Done(State)], Problem)
	parse_dict_after_entry = |_, state| Ok(Done(state))

	parse_key_str : Probe, State -> Try({ value : Str, rest : State }, Problem)
	parse_key_str = |_, state| Ok({ value: "", rest: state })

	parse_key_bool : Probe, State -> Try({ value : Bool, rest : State }, Problem)
	parse_key_bool = |_, state| Ok({ value: False, rest: state })

	parse_key_u8 : Probe, State -> Try({ value : U8, rest : State }, Problem)
	parse_key_u8 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i8 : Probe, State -> Try({ value : I8, rest : State }, Problem)
	parse_key_i8 = |_, state| Ok({ value: 0, rest: state })

	parse_key_u16 : Probe, State -> Try({ value : U16, rest : State }, Problem)
	parse_key_u16 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i16 : Probe, State -> Try({ value : I16, rest : State }, Problem)
	parse_key_i16 = |_, state| Ok({ value: 0, rest: state })

	parse_key_u32 : Probe, State -> Try({ value : U32, rest : State }, Problem)
	parse_key_u32 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i32 : Probe, State -> Try({ value : I32, rest : State }, Problem)
	parse_key_i32 = |_, state| Ok({ value: 0, rest: state })

	parse_key_u64 : Probe, State -> Try({ value : U64, rest : State }, Problem)
	parse_key_u64 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i64 : Probe, State -> Try({ value : I64, rest : State }, Problem)
	parse_key_i64 = |_, state| Ok({ value: 0, rest: state })

	parse_key_u128 : Probe, State -> Try({ value : U128, rest : State }, Problem)
	parse_key_u128 = |_, state| Ok({ value: 0, rest: state })

	parse_key_i128 : Probe, State -> Try({ value : I128, rest : State }, Problem)
	parse_key_i128 = |_, state| Ok({ value: 0, rest: state })

	parse_key_dec : Probe, State -> Try({ value : Dec, rest : State }, Problem)
	parse_key_dec = |_, state| Ok({ value: 0, rest: state })

	parse_key_f32 : Probe, State -> Try({ value : F32, rest : State }, Problem)
	parse_key_f32 = |_, state| Ok({ value: 0, rest: state })

	parse_key_f64 : Probe, State -> Try({ value : F64, rest : State }, Problem)
	parse_key_f64 = |_, state| Ok({ value: 0, rest: state })

	## A tag union: `tags`, the kind Json writes it as (a tag with no payload a string, one with
	## payloads an object); its value the first of the names it is tried with that is one of its tags.
	parse_tag_union : Probe, Encoding.ParseTagUnionSpec(a, Probe, State, Problem), State -> Try({ value : a, rest : State }, Problem)
	parse_tag_union = |format, spec, state| {
		marked = kind(state, "tags")
		for name in marked.tags {
			tried = Encoding.ParseTagUnionSpec.parse(
				spec,
				{
					tag: name,
					encoding: format,
					state: deeper(marked),
					start_payloads: |payload, _| Ok(payload),
					next_payload: |payload, _, _| Ok(payload),
					finish_payloads: |payload, _| Ok(payload),
					missing: NoTags,
				},
			)
			match tried {
				Ok(done) => return Ok({ value: done.value, rest: shallower(done.rest) })
				Err(_) => {}
			}
		}
		Err(NoTags)
	}
}

## `state` with the row's current field's kind, if this is the first thing it asked for.
kind : Probe.State, Str -> Probe.State
kind = |state, what| if (state.depth == 1) mark(state, |field| if (field.kind.is_empty()) { ..field, kind: what } else field) else state

## `state` with the row's current field changed by `change`.
mark : Probe.State, (Probe.Field -> Probe.Field) -> Probe.State
mark = |state, change| { ..state, fields: state.fields.update(state.current, change) ?? state.fields }

deeper : Probe.State -> Probe.State
deeper = |state| { ..state, depth: state.depth + 1 }

shallower : Probe.State -> Probe.State
shallower = |state| { ..state, depth: if (state.depth > 0) state.depth - 1 else 0 }
