import Chars

## The YAML that frontmatter is written in: maps (`key: value`), lists (`- item`, or `[a, b]`),
## maps inline (`{ a: 1 }`), scalars plain or quoted (`"…"` with escapes, `'…'`), block scalars
## (`|` keeps line breaks, `>` folds them), `#` comments, and `~`, `null` or nothing for null.
## Not anchors, aliases, tags, several documents or keys that aren't scalars.
##
## A scalar stays text until it is decoded: `Yaml.decode` reads a value into any Roc type with a
## parser (a record, a list, a number, a tag union), so the type says whether `2026` is a number or
## a string. A field set to null is left out, so its default (`??`) holds.
Yaml := [Null, Scalar(Str), Seq(List(Yaml)), Map(List((Str, Yaml)))].{

	## What went wrong: the YAML itself (on which line, counting from 1), a field the type needs and
	## the YAML hasn't, or a value that isn't what the type says.
	Problem : [Syntax({ line : U64, message : Str }), MissingField(Str), Invalid({ field : Str, expected : Str, found : Str })]

	## Where `decode` is: the values still to read.
	State : { stack : List(Frame), field : Str }

	## The YAML as a value. An empty document is an empty map.
	parse : Str -> Try(Yaml, [Syntax({ line : U64, message : Str })])
	parse = |source| {
		lines = scan(source)
		match next_line(lines, 0) {
			Err(_) => Ok(Map([]))
			Ok(first) => {
				found = block(lines, first)?
				match next_line(lines, found.next) {
					Ok(extra) => Err(Syntax({ line: line_number(lines, extra), message: "this line is indented less than the one it follows, or isn't `key: value`" }))
					Err(_) => Ok(found.value)
				}
			}
		}
	}

	## A value as a Roc type: a record (by its fields' names), a list, `Str`, a number, `Bool`
	## (`true` or `false`), a `Dict(Str, _)`, or a tag union (a tag's name, as `status: Draft`).
	decode : Yaml -> Try(a, Yaml.Problem)
		where [a.parser_for : Yaml.Reader -> (Yaml.State -> Try({ value : a, rest : Yaml.State }, Yaml.Problem))]
	decode = |yaml| {
		Shape : a
		read = Shape.parser_for(Reader.Default)
		parsed = read({ stack: [Value(yaml)], field: "" })?
		Ok(parsed.value)
	}

	## Two values the same: scalars with the same text, lists and maps with the same in order.
	is_eq : Yaml, Yaml -> Bool
	is_eq = |a, b|
		match (a, b) {
			(Null, Null) => Bool.True
			(Scalar(x), Scalar(y)) => x == y
			(Seq(xs), Seq(ys)) => xs == ys
			(Map(xs), Map(ys)) => xs == ys
			_ => Bool.False
		}

	## A map's value for `key`.
	get : Yaml, Str -> Try(Yaml, [NotFound])
	get = |yaml, key|
		match yaml {
			Map(entries) =>
				match entries.find_first(|(name, _)| name == key) {
					Ok((_, value)) => Ok(value)
					Err(_) => Err(NotFound)
				}
			_ => Err(NotFound)
		}

	## A problem as a sentence: `line 3: …`, `title is missing`, `draft: expected true or false,
	## found "maybe"`.
	describe : Yaml.Problem -> Str
	describe = |problem|
		match problem {
			Syntax({ line, message }) => "line ${line.to_str()}: ${message}"
			MissingField(name) => "${name} is missing"
			Invalid({ field, expected, found }) => "${if (field.is_empty()) "the value" else field}: expected ${expected}, found ${found}"
		}

	## The format `decode` reads with: it hands the parser Roc writes for a type the values it asks
	## for, from the parsed YAML.
	Reader := [Default].{
		rename_field : Yaml.Reader, Str -> Str
		rename_field = |_, name| name

		missing_field : Yaml.Reader, Str -> Yaml.Problem
		missing_field = |_, name| MissingField(name)

		invalid_value : Yaml.Reader, Yaml.State -> Yaml.Problem
		invalid_value = |_, state| Invalid({ field: state.field, expected: "a different value", found: shown(state) })

		parse_str : Yaml.Reader, Yaml.State -> Try({ value : Str, rest : Yaml.State }, Yaml.Problem)
		parse_str = |_, state| scalar(state, "text", |text| Ok(text))

		parse_bool : Yaml.Reader, Yaml.State -> Try({ value : Bool, rest : Yaml.State }, Yaml.Problem)
		parse_bool = |_, state|
			scalar(
				state,
				"true or false",
				|text|
					if ["true", "True", "TRUE"].contains(text) {
						Ok(Bool.True)
					} else if ["false", "False", "FALSE"].contains(text) {
						Ok(Bool.False)
					} else {
						Err(NotThat)
					},
			)

		parse_u8 : Yaml.Reader, Yaml.State -> Try({ value : U8, rest : Yaml.State }, Yaml.Problem)
		parse_u8 = |_, state| scalar(state, "a whole number from 0 to 255", |text| U8.from_str(text).map_err(|_| NotThat))

		parse_i8 : Yaml.Reader, Yaml.State -> Try({ value : I8, rest : Yaml.State }, Yaml.Problem)
		parse_i8 = |_, state| scalar(state, "a whole number from -128 to 127", |text| I8.from_str(text).map_err(|_| NotThat))

		parse_u16 : Yaml.Reader, Yaml.State -> Try({ value : U16, rest : Yaml.State }, Yaml.Problem)
		parse_u16 = |_, state| scalar(state, "a whole number from 0 to 65535", |text| U16.from_str(text).map_err(|_| NotThat))

		parse_i16 : Yaml.Reader, Yaml.State -> Try({ value : I16, rest : Yaml.State }, Yaml.Problem)
		parse_i16 = |_, state| scalar(state, "a whole number", |text| I16.from_str(text).map_err(|_| NotThat))

		parse_u32 : Yaml.Reader, Yaml.State -> Try({ value : U32, rest : Yaml.State }, Yaml.Problem)
		parse_u32 = |_, state| scalar(state, "a whole number, 0 or more", |text| U32.from_str(text).map_err(|_| NotThat))

		parse_i32 : Yaml.Reader, Yaml.State -> Try({ value : I32, rest : Yaml.State }, Yaml.Problem)
		parse_i32 = |_, state| scalar(state, "a whole number", |text| I32.from_str(text).map_err(|_| NotThat))

		parse_u64 : Yaml.Reader, Yaml.State -> Try({ value : U64, rest : Yaml.State }, Yaml.Problem)
		parse_u64 = |_, state| scalar(state, "a whole number, 0 or more", |text| U64.from_str(text).map_err(|_| NotThat))

		parse_i64 : Yaml.Reader, Yaml.State -> Try({ value : I64, rest : Yaml.State }, Yaml.Problem)
		parse_i64 = |_, state| scalar(state, "a whole number", |text| I64.from_str(text).map_err(|_| NotThat))

		parse_u128 : Yaml.Reader, Yaml.State -> Try({ value : U128, rest : Yaml.State }, Yaml.Problem)
		parse_u128 = |_, state| scalar(state, "a whole number, 0 or more", |text| U128.from_str(text).map_err(|_| NotThat))

		parse_i128 : Yaml.Reader, Yaml.State -> Try({ value : I128, rest : Yaml.State }, Yaml.Problem)
		parse_i128 = |_, state| scalar(state, "a whole number", |text| I128.from_str(text).map_err(|_| NotThat))

		parse_dec : Yaml.Reader, Yaml.State -> Try({ value : Dec, rest : Yaml.State }, Yaml.Problem)
		parse_dec = |_, state| scalar(state, "a number", |text| Dec.from_str(text).map_err(|_| NotThat))

		parse_f32 : Yaml.Reader, Yaml.State -> Try({ value : F32, rest : Yaml.State }, Yaml.Problem)
		parse_f32 = |_, state| scalar(state, "a number", |text| F32.from_str(text).map_err(|_| NotThat))

		parse_f64 : Yaml.Reader, Yaml.State -> Try({ value : F64, rest : Yaml.State }, Yaml.Problem)
		parse_f64 = |_, state| scalar(state, "a number", |text| F64.from_str(text).map_err(|_| NotThat))

		parse_null : Yaml.Reader, Yaml.State -> Try(Yaml.State, Yaml.Problem)
		parse_null = |_, state|
			match take(state) {
				Ok((Null, rest)) => Ok(rest)
				_ => Err(Invalid({ field: state.field, expected: "nothing (null)", found: shown(state) }))
			}

		parse_list_start : Yaml.Reader, Yaml.State -> Try([Counted({ len : U64, rest : Yaml.State }), Uncounted(Yaml.State)], Yaml.Problem)
		parse_list_start = |_, state|
			match take(state) {
				Ok((Seq(items), rest)) => Ok(Uncounted({ ..rest, stack: rest.stack.append(Items(items)) }))
				_ => Err(Invalid({ field: state.field, expected: "a list", found: shown(state) }))
			}

		parse_list_next : Yaml.Reader, Yaml.State -> Try([Item(Yaml.State), Done(Yaml.State)], Yaml.Problem)
		parse_list_next = |_, state|
			match state.stack.last() {
				Ok(Items([])) => Ok(Done({ ..state, stack: state.stack.drop_last(1) }))
				_ => Ok(Item(state))
			}

		parse_list_after_item : Yaml.Reader, Yaml.State -> Try([Continue(Yaml.State), Done(Yaml.State)], Yaml.Problem)
		parse_list_after_item = |_, state|
			match state.stack.last() {
				Ok(Items([])) => Ok(Done({ ..state, stack: state.stack.drop_last(1) }))
				_ => Ok(Continue(state))
			}

		parse_tuple_start : Yaml.Reader, Yaml.State, U64 -> Try(Yaml.State, Yaml.Problem)
		parse_tuple_start = |_, state, len|
			match take(state) {
				Ok((Seq(items), rest)) if items.len() == len => Ok({ ..rest, stack: rest.stack.append(Items(items)) })
				_ => Err(Invalid({ field: state.field, expected: "a list of ${len.to_str()}", found: shown(state) }))
			}

		parse_tuple_next : Yaml.Reader, Yaml.State, U64, U64 -> Try(Yaml.State, Yaml.Problem)
		parse_tuple_next = |_, state, _, _| Ok(state)

		parse_tuple_end : Yaml.Reader, Yaml.State, U64 -> Try(Yaml.State, Yaml.Problem)
		parse_tuple_end = |_, state, _| Ok({ ..state, stack: state.stack.drop_last(1) })

		## A record's fields, in the order the YAML has them; one set to null is left out.
		parse_record_start : Yaml.Reader, Yaml.State -> Try([Counted({ len : U64, rest : Yaml.State }), Uncounted(Yaml.State)], Yaml.Problem)
		parse_record_start = |_, state|
			match take(state) {
				Ok((Map(entries), rest)) => Ok(Uncounted({ ..rest, stack: rest.stack.append(Entries(entries.drop_if(|(_, value)| value == Null))) }))
				_ => Err(Invalid({ field: state.field, expected: "a map (key: value)", found: shown(state) }))
			}

		parse_record_field : Yaml.Reader, Encoding.FieldName.FieldNames(_shape), Yaml.State -> Try([Field({ field : Encoding.FieldName(_shape), rest : Yaml.State }), TryField({ name : Str, rest : Yaml.State }), TryFieldCaseless({ name : Str, rest : Yaml.State }), Continue(Yaml.State), Done(Yaml.State)], Yaml.Problem)
		parse_record_field = |_, _, state|
			match state.stack.last() {
				Ok(Entries([(name, value), .. as others])) => Ok(TryField({ name, rest: { field: name, stack: state.stack.drop_last(1).append(Entries(others)).append(Value(value)) } }))
				_ => Ok(Done({ ..state, stack: state.stack.drop_last(1) }))
			}

		parse_record_after_field : Yaml.Reader, Yaml.State -> Try([Continue(Yaml.State), Done(Yaml.State)], Yaml.Problem)
		parse_record_after_field = |_, state|
			match state.stack.last() {
				Ok(Entries([])) => Ok(Done({ ..state, stack: state.stack.drop_last(1) }))
				_ => Ok(Continue(state))
			}

		## A key the record hasn't: its value is skipped.
		skip_record_field : Yaml.Reader, Yaml.State -> Try(Yaml.State, Yaml.Problem)
		skip_record_field = |_, state|
			match take(state) {
				Ok((_, rest)) => Ok(rest)
				Err(_) => Ok(state)
			}

		parse_dict_start : Yaml.Reader, Yaml.State -> Try([Counted({ len : U64, rest : Yaml.State }), Uncounted(Yaml.State)], Yaml.Problem)
		parse_dict_start = |_, state|
			match take(state) {
				Ok((Map(entries), rest)) => Ok(Uncounted({ ..rest, stack: rest.stack.append(Entries(entries)) }))
				_ => Err(Invalid({ field: state.field, expected: "a map (key: value)", found: shown(state) }))
			}

		parse_dict_next : Yaml.Reader, Yaml.State -> Try([Entry(Yaml.State), Done(Yaml.State)], Yaml.Problem)
		parse_dict_next = |_, state|
			match state.stack.last() {
				Ok(Entries([])) => Ok(Done({ ..state, stack: state.stack.drop_last(1) }))
				_ => Ok(Entry(state))
			}

		parse_key_str : Yaml.Reader, Yaml.State -> Try({ value : Str, rest : Yaml.State }, Yaml.Problem)
		parse_key_str = |_, state|
			match state.stack.last() {
				Ok(Entries([(name, value), .. as others])) => Ok({ value: name, rest: { field: name, stack: state.stack.drop_last(1).append(Entries(others)).append(Value(value)) } })
				_ => Err(Invalid({ field: state.field, expected: "a key", found: "none" }))
			}

		parse_dict_after_key : Yaml.Reader, Yaml.State -> Try(Yaml.State, Yaml.Problem)
		parse_dict_after_key = |_, state| Ok(state)

		parse_dict_after_entry : Yaml.Reader, Yaml.State -> Try([Continue(Yaml.State), Done(Yaml.State)], Yaml.Problem)
		parse_dict_after_entry = |_, state|
			match state.stack.last() {
				Ok(Entries([])) => Ok(Done({ ..state, stack: state.stack.drop_last(1) }))
				_ => Ok(Continue(state))
			}

		## A tag: its name (`status: Draft`), or a map of its name to its one payload (`size: { Px: 12 }`).
		parse_tag_union : Yaml.Reader, Encoding.ParseTagUnionSpec(t, Yaml.Reader, Yaml.State, Yaml.Problem), Yaml.State -> Try({ value : t, rest : Yaml.State }, Yaml.Problem)
		parse_tag_union = |format, spec, state| {
			wrong = Invalid({ field: state.field, expected: "one of the type's tags", found: shown(state) })
			tagged =
				match take(state) {
					Ok((Scalar(name), rest)) => Ok({ name, rest, payload: Bool.False })
					Ok((Map([(name, payload)]), rest)) => Ok({ name, rest: { ..rest, stack: rest.stack.append(Value(payload)) }, payload: Bool.True })
					_ => Err(wrong)
				}
			found = tagged?
			Encoding.ParseTagUnionSpec.parse(
				spec,
				{
					tag: found.name,
					encoding: format,
					state: found.rest,
					start_payloads: |payload, count| if ((count == 1) == found.payload) Ok(payload) else Err(wrong),
					next_payload: |_, _, _| Err(wrong),
					finish_payloads: |payload, _| Ok(payload),
					missing: wrong,
				},
			)
		}
	}
}

## What `decode` has still to read: a value; a list's items left; a map's entries left.
Frame : [Value(Yaml), Items(List(Yaml)), Entries(List((Str, Yaml)))]

## The next value: the one at the top, or a list's next item.
take : Yaml.State -> Try((Yaml, Yaml.State), [Empty])
take = |state|
	match state.stack.last() {
		Ok(Value(value)) => Ok((value, { ..state, stack: state.stack.drop_last(1) }))
		Ok(Items([first, .. as others])) => Ok((first, { ..state, stack: state.stack.drop_last(1).append(Items(others)) }))
		_ => Err(Empty)
	}

## A scalar, read by `read`: `expected` says what it should have been when it isn't.
scalar : Yaml.State, Str, (Str -> Try(v, [NotThat])) -> Try({ value : v, rest : Yaml.State }, Yaml.Problem)
scalar = |state, expected, read|
	match take(state) {
		Ok((Scalar(text), rest)) =>
			match read(text) {
				Ok(value) => Ok({ value, rest })
				Err(_) => Err(Invalid({ field: state.field, expected, found: "\"${text}\"" }))
			}
		_ => Err(Invalid({ field: state.field, expected, found: shown(state) }))
	}

## The next value, as a problem names it.
shown : Yaml.State -> Str
shown = |state|
	match take(state) {
		Ok((Scalar(text), _)) => "\"${text}\""
		Ok((Null, _)) => "nothing"
		Ok((Seq(_), _)) => "a list"
		Ok((Map(_), _)) => "a map"
		Err(_) => "nothing"
	}

# Parsing.

## A line that means something: how far it is indented (spaces), and what follows, its comment
## gone unless it might be in a block scalar (`raw` keeps the line as written).
Line : { number : U64, indent : U64, text : Str, raw : Str }

scan : Str -> List(Line)
scan = |source|
	source.replace_each("\r\n", "\n").split_on("\n").map_with_index(
		|raw, index| {
			bytes = raw.to_utf8()
			indent = Chars.until(bytes, 0, |b| b != ' ')
			{ number: index + 1, indent, text: without_comment(Chars.trim(Chars.slice(bytes, indent, bytes.len()))), raw }
		},
	)

## The next line with something on it, from `i`.
next_line : List(Line), U64 -> Try(U64, [End])
next_line = |lines, i| {
	var $j = i
	while $j < lines.len() {
		match lines.get($j) {
			Ok(line) if !line.text.is_empty() => return Ok($j)
			_ => {}
		}
		$j = $j + 1
	}
	Err(End)
}

line_number : List(Line), U64 -> U64
line_number = |lines, i|
	match lines.get(i) {
		Ok(line) => line.number
		Err(_) => lines.len()
	}

line_at : List(Line), U64 -> Line
line_at = |lines, i| lines.get(i) ?? { number: 0, indent: 0, text: "", raw: "" }

syntax : List(Line), U64, Str -> [Syntax({ line : U64, message : Str })]
syntax = |lines, i, message| Syntax({ line: line_number(lines, i), message })

## The value whose first line is `i`: a list, a map, or a scalar.
block : List(Line), U64 -> Try({ value : Yaml, next : U64 }, [Syntax({ line : U64, message : Str })])
block = |lines, i| {
	line = line_at(lines, i)
	if is_item(line.text) {
		sequence(lines, i, line.indent)
	} else if (key_split(line.text)).is_ok() {
		mapping(lines, i, line.indent)
	} else {
		value = inline(line.text).map_err(|message| syntax(lines, i, message))?
		Ok({ value, next: i + 1 })
	}
}

is_item : Str -> Bool
is_item = |text| text == "-" or text.starts_with("- ")

## `key: value` lines at `indent`.
mapping : List(Line), U64, U64 -> Try({ value : Yaml, next : U64 }, [Syntax({ line : U64, message : Str })])
mapping = |lines, start, indent| {
	var $entries = []
	var $i = start
	var $going = Bool.True
	while $going {
		match next_line(lines, $i) {
			Ok(j) if (line_at(lines, j)).indent == indent and !is_item((line_at(lines, j)).text) => {
				line = line_at(lines, j)
				split = key_split(line.text).map_err(|_| syntax(lines, j, "expected `key: value`"))?
				if $entries.any(|(name, _)| name == split.key) {
					return Err(syntax(lines, j, "`${split.key}` is set twice"))
				}
				found = value_after(lines, j, indent, split.rest)?
				$entries = $entries.append((split.key, found.value))
				$i = found.next
			}
			Ok(j) if (line_at(lines, j)).indent > indent => return Err(syntax(lines, j, "this line is indented more than the key before it"))
			_ => {
				$going = Bool.False
			}
		}
	}
	Ok({ value: Map($entries), next: $i })
}

## `- item` lines at `indent`. An item may start a map (`- name: x`, its other keys under `name`) or
## a list of its own (`- - a`).
sequence : List(Line), U64, U64 -> Try({ value : Yaml, next : U64 }, [Syntax({ line : U64, message : Str })])
sequence = |lines, start, indent| {
	var $items = []
	var $lines = lines
	var $i = start
	var $going = Bool.True
	while $going {
		match next_line($lines, $i) {
			Ok(j) if (line_at($lines, j)).indent == indent and is_item((line_at($lines, j)).text) => {
				line = line_at($lines, j)
				after = line.text.drop_prefix("-")
				rest = Chars.trim(after)
				if rest.is_empty() {
					found =
						match next_line($lines, j + 1) {
							Ok(k) if (line_at($lines, k)).indent > indent => block($lines, k)?
							_ => { value: Null, next: j + 1 }
						}
					$items = $items.append(found.value)
					$i = found.next
				} else if is_item(rest) or key_split(rest).is_ok() {
					# The item's own block starts on this line: read it as if it were on a line of its own.
					offset = indent + 1 + (after.count_utf8_bytes() - after.trim_start().count_utf8_bytes())
					$lines = $lines.set(j, { ..line, indent: offset, text: rest }) ?? $lines
					found = block($lines, j)?
					$items = $items.append(found.value)
					$i = found.next
				} else {
					found = value_after($lines, j, indent, rest)?
					$items = $items.append(found.value)
					$i = found.next
				}
			}
			_ => {
				$going = Bool.False
			}
		}
	}
	Ok({ value: Seq($items), next: $i })
}

## The value after a key's colon (or an item's dash) on line `j`: inline, a block scalar, or the
## block on the lines under it.
value_after : List(Line), U64, U64, Str -> Try({ value : Yaml, next : U64 }, [Syntax({ line : U64, message : Str })])
value_after = |lines, j, indent, rest| {
	if rest.is_empty() {
		match next_line(lines, j + 1) {
			Ok(k) if (line_at(lines, k)).indent > indent => block(lines, k)
			Ok(k) if (line_at(lines, k)).indent == indent and is_item((line_at(lines, k)).text) => sequence(lines, k, indent)
			_ => Ok({ value: Null, next: j + 1 })
		}
	} else if rest.starts_with("|") or rest.starts_with(">") {
		block_scalar(lines, j, indent, rest)
	} else if (rest.starts_with("[") or rest.starts_with("{")) and !balanced(rest) {
		# A flow list or map over several lines: joined until its brackets close.
		var $text = rest
		var $k = j + 1
		while !balanced($text) and $k < lines.len() {
			$text = "${$text} ${(line_at(lines, $k)).text}"
			$k = $k + 1
		}
		value = inline($text).map_err(|message| syntax(lines, j, message))?
		Ok({ value, next: $k })
	} else {
		value = inline(rest).map_err(|message| syntax(lines, j, message))?
		# A plain scalar may go on over more indented lines, folded into one.
		match value {
			Scalar(text) if !rest.starts_with("\"") and !rest.starts_with("'") => {
				var $text = text
				var $k = j + 1
				var $going = Bool.True
				while $going {
					match next_line(lines, $k) {
						Ok(next) if (line_at(lines, next)).indent > indent and key_split((line_at(lines, next)).text).is_err() and !is_item((line_at(lines, next)).text) => {
							$text = "${$text} ${(line_at(lines, next)).text}"
							$k = next + 1
						}
						_ => {
							$going = Bool.False
						}
					}
				}
				Ok({ value: Scalar($text), next: $k })
			}
			_ => Ok({ value, next: j + 1 })
		}
	}
}

## `|` (lines kept) or `>` (folded into one, a blank line a break), with `-` (no final line break)
## or `+` (all of them kept): the lines indented more than the key.
block_scalar : List(Line), U64, U64, Str -> Try({ value : Yaml, next : U64 }, [Syntax({ line : U64, message : Str })])
block_scalar = |lines, j, indent, header| {
	literal = header.starts_with("|")
	chomp = if (header.contains("-")) Strip else if (header.contains("+")) Keep else Clip
	var $k = j + 1
	var $body = []
	var $going = Bool.True
	while $going and $k < lines.len() {
		line = line_at(lines, $k)
		if Chars.trim(line.raw).is_empty() {
			$body = $body.append(line.raw)
			$k = $k + 1
		} else if line.indent > indent {
			$body = $body.append(line.raw)
			$k = $k + 1
		} else {
			$going = Bool.False
		}
	}
	# Trailing blank lines belong to the next key, but `+` keeps them.
	var $content = $body
	var $trailing = 0
	while ($content.last() ?? "x").trim().is_empty() and !$content.is_empty() {
		$content = $content.drop_last(1)
		$trailing = $trailing + 1
	}
	shift = $content.fold(1000, |least, raw| if (Chars.trim(raw).is_empty()) least else U64.min(least, Chars.until(raw.to_utf8(), 0, |b| b != ' ')))
	stripped = $content.map(|raw| Chars.slice(raw.to_utf8(), U64.min(shift, raw.count_utf8_bytes()), raw.count_utf8_bytes()))
	joined = if (literal) Str.join_with(stripped, "\n") else fold_lines(stripped)
	text =
		match chomp {
			Strip => joined
			Clip => if (joined.is_empty()) "" else "${joined}\n"
			Keep => "${joined}${Str.repeat("\n", $trailing + 1)}"
		}
	Ok({ value: Scalar(text), next: j + 1 + $body.len() })
}

## Folded lines: each break a space, but a blank line a break, and more indented lines kept.
fold_lines : List(Str) -> Str
fold_lines = |lines|
	lines.fold(
		"",
		|out, line|
			if out.is_empty() {
				line
			} else if line.is_empty() or out.ends_with("\n") or line.starts_with(" ") {
				"${out}\n${line}"
			} else {
				"${out} ${line}"
			},
	).replace_each("\n\n", "\n")

## `key: rest`: the key (quoted or not) up to the first `: ` (or a `:` ending the line).
key_split : Str -> Try({ key : Str, rest : Str }, [NotKey])
key_split = |text| {
	bytes = text.to_utf8()
	first = Chars.at(bytes, 0)
	if first == '"' or first == '\'' {
		close = Chars.until(bytes, 1, |b| b == first)
		if Chars.at(bytes, close + 1) == ':' and (close + 2 >= bytes.len() or Chars.at(bytes, close + 2) == ' ') {
			key = match inline(Chars.slice(bytes, 0, close + 1)) {
				Ok(Scalar(unquoted)) => unquoted
				_ => Chars.slice(bytes, 1, close)
			}
			return Ok({ key, rest: Chars.trim(Chars.slice(bytes, close + 2, bytes.len())) })
		}
		return Err(NotKey)
	}
	if first == '[' or first == '{' or (first == '-' and Chars.at(bytes, 1) == ' ') {
		return Err(NotKey)
	}
	var $i = 0
	while $i < bytes.len() {
		if Chars.at(bytes, $i) == ':' and ($i + 1 >= bytes.len() or Chars.at(bytes, $i + 1) == ' ') and $i > 0 {
			return Ok({ key: Chars.trim(Chars.slice(bytes, 0, $i)), rest: Chars.trim(Chars.slice(bytes, $i + 1, bytes.len())) })
		}
		$i = $i + 1
	}
	Err(NotKey)
}

## A value on one line: quoted, a flow list or map, or plain.
inline : Str -> Try(Yaml, Str)
inline = |text| {
	bytes = text.to_utf8()
	first = Chars.at(bytes, 0)
	if first == '"' {
		double_quoted(bytes)
	} else if first == '\'' {
		end = single_end(bytes)
		if end == 0 {
			Err("a '…' string isn't closed")
		} else if !Chars.trim(Chars.slice(bytes, end + 1, bytes.len())).is_empty() {
			Err("something follows the closing quote")
		} else {
			Ok(Scalar(Chars.slice(bytes, 1, end).replace_each("''", "'")))
		}
	} else if first == '[' {
		if !text.ends_with("]") {
			Err("a [ list isn't closed")
		} else {
			parts = split_flow(Chars.slice(bytes, 1, bytes.len() - 1))
			Ok(Seq(parts.map_try(inline)?))
		}
	} else if first == '{' {
		if !text.ends_with("}") {
			Err("a { map isn't closed")
		} else {
			parts = split_flow(Chars.slice(bytes, 1, bytes.len() - 1))
			entries = parts.map_try(
				|part|
					match key_split(part) {
						Ok({ key, rest }) => inline(rest).map_ok(|value| (key, value))
						Err(_) => Err("expected `key: value` in a { map }")
					},
			)?
			Ok(Map(entries))
		}
	} else if text.is_empty() or text == "~" or text == "null" or text == "Null" or text == "NULL" {
		Ok(Null)
	} else {
		Ok(Scalar(text))
	}
}

## A `"…"` string: `\"`, `\\`, `\n`, `\t`, `\uXXXX`… replaced.
double_quoted : List(U8) -> Try(Yaml, Str)
double_quoted = |bytes| {
	var $out = []
	var $i = 1
	while $i < bytes.len() {
		b = Chars.at(bytes, $i)
		if b == '"' {
			if !Chars.trim(Chars.slice(bytes, $i + 1, bytes.len())).is_empty() {
				return Err("something follows the closing quote")
			}
			return Ok(Scalar(Str.from_utf8_lossy($out)))
		} else if b == '\\' {
			next = Chars.at(bytes, $i + 1)
			if next == 'u' or next == 'x' {
				digits = if (next == 'u') 4 else 2
				code = hex_value(Chars.slice(bytes, $i + 2, $i + 2 + digits))
				$out = $out.concat(Chars.utf8(code))
				$i = $i + 2 + digits
			} else {
				escaped = match next {
					'n' => ['\n']
					't' => ['\t']
					'r' => ['\r']
					'0' => [0xEF, 0xBF, 0xBD]
					_ => [next]
				}
				$out = $out.concat(escaped)
				$i = $i + 2
			}
		} else {
			$out = $out.append(b)
			$i = $i + 1
		}
	}
	Err("a \"…\" string isn't closed")
}

hex_value : Str -> U32
hex_value = |digits|
	digits.to_utf8().fold(
		0,
		|code, b| {
			value = if (b >= '0' and b <= '9') b - '0' else if (b >= 'a' and b <= 'f') b - 'a' + 10 else if (b >= 'A' and b <= 'F') b - 'A' + 10 else 0
			code * 16 + value.to_u32()
		},
	)

## Where a `'…'` string ends (`''` is a quote inside it), or 0.
single_end : List(U8) -> U64
single_end = |bytes| {
	var $i = 1
	while $i < bytes.len() {
		if Chars.at(bytes, $i) == '\'' {
			if Chars.at(bytes, $i + 1) == '\'' {
				$i = $i + 2
			} else {
				return $i
			}
		} else {
			$i = $i + 1
		}
	}
	0
}

## A flow list's or map's parts, split at the commas outside quotes and brackets.
split_flow : Str -> List(Str)
split_flow = |inner| {
	bytes = inner.to_utf8()
	var $parts = []
	var $from = 0
	var $depth = 0
	var $quote = 0
	var $i = 0
	while $i < bytes.len() {
		b = Chars.at(bytes, $i)
		if $quote != 0 {
			if b == $quote {
				$quote = 0
			}
		} else if b == '"' or b == '\'' {
			$quote = b
		} else if b == '[' or b == '{' {
			$depth = $depth + 1
		} else if (b == ']' or b == '}') and $depth > 0 {
			$depth = $depth - 1
		} else if b == ',' and $depth == 0 {
			$parts = $parts.append(Chars.trim(Chars.slice(bytes, $from, $i)))
			$from = $i + 1
		}
		$i = $i + 1
	}
	last = Chars.trim(Chars.slice(bytes, $from, bytes.len()))
	if (last.is_empty()) $parts else $parts.append(last)
}

## Whether a flow value's brackets close, outside quotes.
balanced : Str -> Bool
balanced = |text| {
	var $depth = 0
	var $quote = 0
	for b in text.to_utf8() {
		if $quote != 0 {
			if b == $quote {
				$quote = 0
			}
		} else if b == '"' or b == '\'' {
			$quote = b
		} else if b == '[' or b == '{' {
			$depth = $depth + 1
		} else if b == ']' or b == '}' {
			$depth = $depth - 1
		}
	}
	$depth <= 0
}

## A line's text without its comment: a `#` at its start, or after a space, outside quotes.
without_comment : Str -> Str
without_comment = |text| {
	if !text.contains("#") {
		return text
	}
	bytes = text.to_utf8()
	var $quote = 0
	var $i = 0
	while $i < bytes.len() {
		b = Chars.at(bytes, $i)
		if $quote != 0 {
			if b == $quote {
				$quote = 0
			}
		} else if (b == '"' or b == '\'') and ($i == 0 or " [{,:".to_utf8().contains(Chars.at(bytes, $i - 1))) {
			$quote = b
		} else if b == '#' and ($i == 0 or Chars.is_space_or_tab(Chars.at(bytes, $i - 1))) {
			return Chars.trim(Chars.slice(bytes, 0, $i))
		}
		$i = $i + 1
	}
	text
}

Post := { title : Str, date : Str, count : U64, tags : List(Str) ?? [], draft : Bool ?? Bool.False, status : [Draft, Live] ?? Draft, rating : Dec ?? 0.0 }.{
	parser_for : _
	is_eq : _
}

post : Str -> Try(Post, Yaml.Problem)
post = |source|
	match Yaml.parse(source) {
		Ok(yaml) => Yaml.decode(yaml)
		Err(Syntax(problem)) => Err(Syntax(problem))
	}

expect Yaml.parse("title: Hello\ntags: [a, \"b c\"]\nnested:\n  x: 1\n  y: ~\nlist:\n  - one\n  - two # comment\n") == Ok(Map([("title", Scalar("Hello")), ("tags", Seq([Scalar("a"), Scalar("b c")])), ("nested", Map([("x", Scalar("1")), ("y", Null)])), ("list", Seq([Scalar("one"), Scalar("two")]))]))
expect Yaml.parse("people:\n- name: Ada\n  role: maths\n- name: Grace\n") == Ok(Map([("people", Seq([Map([("name", Scalar("Ada")), ("role", Scalar("maths"))]), Map([("name", Scalar("Grace"))])]))]))
expect Yaml.parse("a: |\n  one\n    two\n\nb: >-\n  folded\n  text\n\n  para\nc: 'it''s'\nd: \"tab\\there \\u00e9\"\n") == Ok(Map([("a", Scalar("one\n  two\n")), ("b", Scalar("folded text\npara")), ("c", Scalar("it's")), ("d", Scalar("tab\there é"))]))
expect Yaml.parse("") == Ok(Map([]))
expect Yaml.parse("a: 1\n  b: 2") == Err(Syntax({ line: 2, message: "this line is indented more than the key before it" }))
expect Yaml.parse("a: 1\na: 2") == Err(Syntax({ line: 2, message: "`a` is set twice" }))
expect Yaml.parse("url: https://example.com/a#b\nwhen: 12:30\n") == Ok(Map([("url", Scalar("https://example.com/a#b")), ("when", Scalar("12:30"))]))
expect Yaml.parse("description: a long\n  line, folded\nnext: x") == Ok(Map([("description", Scalar("a long line, folded")), ("next", Scalar("x"))]))
expect Yaml.parse("tags: [a,\n  b]\nmap: { x: 1, y: [2, 3] }") == Ok(Map([("tags", Seq([Scalar("a"), Scalar("b")])), ("map", Map([("x", Scalar("1")), ("y", Seq([Scalar("2"), Scalar("3")]))]))]))

expect {
	got = post("title: Hello\ndate: 2026-11-21\ncount: 3\ntags: [a, b]\nstatus: Live\nrating: 4.5\nextra: ignored")
	match got {
		Ok(p) => p.title == "Hello" and p.date == "2026-11-21" and p.count == 3 and p.tags == ["a", "b"] and !p.draft and p.status == Live and p.rating == 4.5
		Err(_) => Bool.False
	}
}

expect {
	got = post("title: Hi\ndate: today\ncount: 1\ndraft: ~\n")
	match got {
		Ok(p) => p.tags == [] and !p.draft and p.status == Draft
		Err(_) => Bool.False
	}
}

expect post("date: x\ncount: 1") == Err(MissingField("title"))
expect post("title: x\ndate: y\ncount: many") == Err(Invalid({ field: "count", expected: "a whole number, 0 or more", found: "\"many\"" }))
expect post("title: x\ndate: y\ncount: 1\nstatus: Lost") == Err(Invalid({ field: "status", expected: "one of the type's tags", found: "\"Lost\"" }))
expect Yaml.describe(Invalid({ field: "count", expected: "a number", found: "\"many\"" })) == "count: expected a number, found \"many\""

expect {
	got : Try(Dict(Str, Str), Yaml.Problem)
	got = Yaml.decode(Map([("a", Scalar("1")), ("b", Scalar("2"))]))
	got.map_ok(|dict| dict.get("b")) == Ok(Ok("2"))
}
