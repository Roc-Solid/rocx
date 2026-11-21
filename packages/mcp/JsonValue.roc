## Any JSON value, read a field at a time: what a JSON-RPC message is before its method says what
## its `params` hold, and what a tool's arguments are before the tool is found. Roc's `Json` reads
## into a type known in advance; `decode` hands a value on to it once one is, and `encode` brings a
## typed value back.
##
## A number keeps the text it was written with (`Number("1e3")`), so a request's id goes back exactly
## as it came, and a tool's arguments reach `Json.parse` as the client wrote them: an `I64` or a `Dec`
## loses nothing on the way through an `F64`. An object keeps its keys in order, each once (a key
## given twice keeps its first place and its last value, as `JSON.parse` does).
JsonValue := [Null, Boolean(Bool), Number(Str), String(Str), Array(List(JsonValue)), Object(List((Str, JsonValue)))].{
	is_eq : _

	## The value `text` holds, whitespace around it allowed; nested at most `max_depth` deep.
	parse : Str -> Try(JsonValue, [InvalidJson(Str)])
	parse = |text| {
		bytes = text.to_utf8()
		parsed = value_at(bytes, 0, 0)?
		end = skip_space(bytes, parsed.at)
		if end == bytes.len() {
			Ok(parsed.value)
		} else {
			Err(InvalidJson("more after the value, at byte ${end.to_str()}"))
		}
	}

	## The value as JSON, without spaces: a number as it was written, a string as `Json` writes one.
	to_str : JsonValue -> Str
	to_str = |value|
		match value {
			Null => "null"
			Boolean(yes) => if (yes) "true" else "false"
			Number(text) => text
			String(text) => Json.to_str(text)
			Array(items) => "[${Str.join_with(items.map(JsonValue.to_str), ",")}]"
			Object(fields) => "{${Str.join_with(fields.map(|(key, item)| "${Json.to_str(key)}:${JsonValue.to_str(item)}"), ",")}}"
		}

	## An object's field; `Missing` when it has no such key, or isn't an object.
	get : JsonValue, Str -> Try(JsonValue, [Missing])
	get = |value, key|
		match value {
			Object(fields) =>
				match fields.find_first(|(name, _)| name == key) {
					Ok((_, found)) => Ok(found)
					Err(_) => Err(Missing)
				}
			_ => Err(Missing)
		}

	## A string's text; `NotText` for any other value.
	to_text : JsonValue -> Try(Str, [NotText])
	to_text = |value|
		match value {
			String(said) => Ok(said)
			_ => Err(NotText)
		}

	## Whether it is an object.
	is_object : JsonValue -> Bool
	is_object = |value|
		match value {
			Object(_) => Bool.True
			_ => Bool.False
		}

	## The value as a Roc type, as `Json` reads it (`JsonValue.decode(args) : Try({ city : Str }, _)`).
	decode : JsonValue -> Try(a, [InvalidJson(Str)]) where [a.Json.Parseable([InvalidJson(Str)])]
	decode = |value| Json.parse(JsonValue.to_str(value))

	## A Roc value as JSON, as `Json` writes it; `Unwritable` for an `F64` that is NaN or an infinity,
	## which JSON has no way to write.
	encode : a -> Try(JsonValue, [Unwritable]) where [a.Json.Encodable(e)]
	encode = |value|
		match Json.to_str_try(value) {
			Ok(json) =>
				match JsonValue.parse(json) {
					Ok(parsed) => Ok(parsed)
					Err(_) => Err(Unwritable)
				}
			Err(_) => Err(Unwritable)
		}

	## A whole number.
	int : I64 -> JsonValue
	int = |number| Number(number.to_str())

	## A count.
	uint : U64 -> JsonValue
	uint = |number| Number(number.to_str())

	## An object of only the fields that are given: `Ok(value)` kept, `Err(_)` left out. For a
	## result's optional fields (`title`, `mimeType`).
	object_of : List((Str, Try(JsonValue, [Absent]))) -> JsonValue
	object_of = |given| Object(given.keep_oks(|(key, maybe)| maybe.map_ok(|value| (key, value))))

	## A string, or nothing when it is empty: an optional text field.
	text_unless_empty : Str -> Try(JsonValue, [Absent])
	text_unless_empty = |said| if (said.is_empty()) Err(Absent) else Ok(String(said))

	## How deep arrays and objects may nest: deeper ones aren't read, before they could use up the stack.
	max_depth : U64
	max_depth = 64
}

Read : { value : JsonValue, at : U64 }

value_at : List(U8), U64, U64 -> Try(Read, [InvalidJson(Str)])
value_at = |bytes, start, depth| {
	at = skip_space(bytes, start)
	if depth > JsonValue.max_depth {
		return Err(InvalidJson("nested deeper than ${JsonValue.max_depth.to_str()}"))
	}
	match bytes.get(at) {
		Ok('{') => object_at(bytes, at + 1, depth + 1)
		Ok('[') => array_at(bytes, at + 1, depth + 1)
		Ok('"') => {
			read = string_at(bytes, at)?
			Ok({ value: String(read.text), at: read.at })
		}
		Ok('t') => word_at(bytes, at, "true", Boolean(Bool.True))
		Ok('f') => word_at(bytes, at, "false", Boolean(Bool.False))
		Ok('n') => word_at(bytes, at, "null", Null)
		Ok(_) => number_at(bytes, at)
		Err(_) => Err(InvalidJson("a value expected, at byte ${at.to_str()}"))
	}
}

word_at : List(U8), U64, Str, JsonValue -> Try(Read, [InvalidJson(Str)])
word_at = |bytes, at, word, value| {
	expected = word.to_utf8()
	if bytes.sublist({ start: at, len: expected.len() }) == expected {
		Ok({ value: value, at: at + expected.len() })
	} else {
		Err(InvalidJson("not a value, at byte ${at.to_str()}"))
	}
}

## A string, from its opening quote: its closing one found (skipping what a `\` escapes), then
## the whole of it read by `Json`, which knows its escapes, and refuses a raw control character.
string_at : List(U8), U64 -> Try({ text : Str, at : U64 }, [InvalidJson(Str)])
string_at = |bytes, start| {
	var $at = start + 1
	while $at < bytes.len() {
		match bytes.get($at) {
			Ok('"') => {
				token = bytes.sublist({ start: start, len: $at + 1 - start })
				decoded : Try(Str, [InvalidJson(Str)])
				decoded =
					match Str.from_utf8(token) {
						Ok(json) => Json.parse(json)
						Err(_) => Err(InvalidJson("not UTF-8"))
					}
				return
					match decoded {
						Ok(said) => Ok({ text: said, at: $at + 1 })
						Err(_) => Err(InvalidJson("not a string, at byte ${start.to_str()}"))
					}
			}
			Ok('\\') => {
				$at = $at + 2
			}
			_ => {
				$at = $at + 1
			}
		}
	}
	Err(InvalidJson("a string that doesn't end, at byte ${start.to_str()}"))
}

## A number, as JSON writes one: `-`, digits (no leading zero), a fraction, an exponent.
number_at : List(U8), U64 -> Try(Read, [InvalidJson(Str)])
number_at = |bytes, start| {
	refused = Err(InvalidJson("not a value, at byte ${start.to_str()}"))
	minus = if (bytes.get(start) == Ok('-')) start + 1 else start
	whole = digits(bytes, minus)
	if whole == minus or (bytes.get(minus) == Ok('0') and whole > minus + 1) {
		return refused
	}
	fraction =
		if bytes.get(whole) == Ok('.') {
			after = digits(bytes, whole + 1)
			if (after == whole + 1) return refused else after
		} else {
			whole
		}
	end =
		match bytes.get(fraction) {
			Ok(e) if e == 'e' or e == 'E' => {
				signed =
					match bytes.get(fraction + 1) {
						Ok(sign) if sign == '+' or sign == '-' => fraction + 2
						_ => fraction + 1
					}
				after = digits(bytes, signed)
				if (after == signed) return refused else after
			}
			_ => fraction
		}
	match Str.from_utf8(bytes.sublist({ start: start, len: end - start })) {
		Ok(written) => Ok({ value: Number(written), at: end })
		Err(_) => refused
	}
}

## Where the digits from `start` end.
digits : List(U8), U64 -> U64
digits = |bytes, start| {
	var $at = start
	while $at < bytes.len() and is_digit(bytes.get($at) ?? 0) {
		$at = $at + 1
	}
	$at
}

is_digit : U8 -> Bool
is_digit = |byte| byte >= '0' and byte <= '9'

array_at : List(U8), U64, U64 -> Try(Read, [InvalidJson(Str)])
array_at = |bytes, start, depth| {
	first = skip_space(bytes, start)
	if bytes.get(first) == Ok(']') {
		Ok({ value: Array([]), at: first + 1 })
	} else {
		items_at(bytes, first, depth, [])
	}
}

## An array's items, from the next one on.
items_at : List(U8), U64, U64, List(JsonValue) -> Try(Read, [InvalidJson(Str)])
items_at = |bytes, at, depth, items| {
	item = value_at(bytes, at, depth)?
	next = skip_space(bytes, item.at)
	match bytes.get(next) {
		Ok(',') => items_at(bytes, next + 1, depth, items.append(item.value))
		Ok(']') => Ok({ value: Array(items.append(item.value)), at: next + 1 })
		_ => Err(InvalidJson("`,` or `]` expected, at byte ${next.to_str()}"))
	}
}

object_at : List(U8), U64, U64 -> Try(Read, [InvalidJson(Str)])
object_at = |bytes, start, depth| {
	first = skip_space(bytes, start)
	if bytes.get(first) == Ok('}') {
		Ok({ value: Object([]), at: first + 1 })
	} else {
		fields_at(bytes, first, depth, [])
	}
}

## An object's fields, from the next one's key on.
fields_at : List(U8), U64, U64, List((Str, JsonValue)) -> Try(Read, [InvalidJson(Str)])
fields_at = |bytes, at, depth, fields| {
	if bytes.get(at) != Ok('"') {
		return Err(InvalidJson("a key expected, at byte ${at.to_str()}"))
	}
	key = string_at(bytes, at)?
	colon = skip_space(bytes, key.at)
	if bytes.get(colon) != Ok(':') {
		return Err(InvalidJson("`:` expected, at byte ${colon.to_str()}"))
	}
	item = value_at(bytes, colon + 1, depth)?
	kept = with_field(fields, key.text, item.value)
	next = skip_space(bytes, item.at)
	match bytes.get(next) {
		Ok(',') => fields_at(bytes, skip_space(bytes, next + 1), depth, kept)
		Ok('}') => Ok({ value: Object(kept), at: next + 1 })
		_ => Err(InvalidJson("`,` or `}` expected, at byte ${next.to_str()}"))
	}
}

## The fields with `key` set to `value`: in its place if it is there already, else at the end.
with_field : List((Str, JsonValue)), Str, JsonValue -> List((Str, JsonValue))
with_field = |fields, key, value|
	if fields.any(|(name, _)| name == key) {
		fields.map(|(name, old)| if (name == key) (name, value) else (name, old))
	} else {
		fields.append((key, value))
	}

skip_space : List(U8), U64 -> U64
skip_space = |bytes, start| {
	var $at = start
	while $at < bytes.len() and is_space(bytes.get($at) ?? 0) {
		$at = $at + 1
	}
	$at
}

is_space : U8 -> Bool
is_space = |byte| byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r'

expect JsonValue.parse(" null ") == Ok(Null)
expect JsonValue.parse("true") == Ok(Boolean(Bool.True))
expect JsonValue.parse("[1, -2.5e3, 0, 0.25]") == Ok(Array([Number("1"), Number("-2.5e3"), Number("0"), Number("0.25")]))
expect JsonValue.parse("{\"a\": {\"b\": [\"x\\n\\u00e9\"]}, \"c\": false}") == Ok(Object([("a", Object([("b", Array([String("x\né")]))])), ("c", Boolean(Bool.False))]))
expect JsonValue.parse("{\"a\":1,\"b\":2,\"a\":3}") == Ok(Object([("a", Number("3")), ("b", Number("2"))]))
expect JsonValue.parse("{}") == Ok(Object([]))
expect JsonValue.parse("[]") == Ok(Array([]))

## What JSON doesn't allow: leading zeros, a bare `.`, a trailing comma, a raw newline in a string,
## a second value, an unclosed object.
expect JsonValue.parse("01").is_err()
expect JsonValue.parse("1.").is_err()
expect JsonValue.parse("-").is_err()
expect JsonValue.parse("[1,]").is_err()
expect JsonValue.parse("\"a\nb\"").is_err()
expect JsonValue.parse("1 2").is_err()
expect JsonValue.parse("{\"a\":1").is_err()
expect JsonValue.parse("{a:1}").is_err()
expect JsonValue.parse("").is_err()
expect JsonValue.parse("nul").is_err()
expect JsonValue.parse(Str.repeat("[", 100)).is_err()

## Written back as it was read, numbers and all.
expect JsonValue.parse("{\"id\": 12345678901234567890, \"x\": [true, null, \"\\\"q\\\"\"]}").map_ok(JsonValue.to_str) == Ok("{\"id\":12345678901234567890,\"x\":[true,null,\"\\\"q\\\"\"]}")

expect JsonValue.parse("{\"name\":\"a\"}").map_ok(|value| value.get("name")) == Ok(Ok(String("a")))
expect {
	said : JsonValue
	said = String("a")
	said.get("name") == Err(Missing)
}
expect JsonValue.object_of([("a", Ok(Null)), ("b", Err(Absent)), ("c", JsonValue.text_unless_empty("x"))]) == Object([("a", Null), ("c", String("x"))])

## Into a Roc type, and back.
expect {
	parsed : Try({ city : Str, days : U8 }, [InvalidJson(Str)])
	parsed = JsonValue.decode(Object([("city", String("Oslo")), ("days", Number("3"))]))
	parsed == Ok({ city: "Oslo", days: 3 })
}

expect {
	parsed : Try({ city : Str, days : U8 }, [InvalidJson(Str)])
	parsed = JsonValue.decode(Object([("city", String("Oslo"))]))
	parsed.is_err()
}

expect {
	total : I64
	total = 3
	JsonValue.encode({ total: total, names: ["a"] }) == Ok(Object([("names", Array([String("a")])), ("total", Number("3"))]))
}
