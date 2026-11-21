## A JSON value: what the repo's JavaScript (its tests, the site's build) and rocx say to each other
## through `rocx internal`. Objects keep their keys in order, as JavaScript's do; numbers are whole.
Value := [
	Null,
	Boolean(Bool),
	Number(I64),
	Text(Str),
	Array(List(Value)),
	Object(List({ key : Str, value : Value })),
].{

	## Two the same: compared with `==`.
	is_eq : _

	## The value of `key` in an object; `Null` when it has none, or isn't one.
	field : Value, Str -> Value
	field = |value, key|
		match value {
			Object(pairs) =>
				match pairs.find_first(|each| each.key == key) {
					Ok(found) => found.value
					Err(_) => Null
				}
			_ => Null
		}

	## A string's text; `""` for anything else.
	str : Value -> Str
	str = |value|
		match value {
			Text(text) => text
			_ => ""
		}

	## A string's text, or `fallback` for anything else (`undefined`, `null`).
	str_or : Value, Str -> Str
	str_or = |value, fallback|
		match value {
			Text(text) => text
			_ => fallback
		}

	## A string's text, or nothing.
	maybe_str : Value -> [Some(Str), None]
	maybe_str = |value|
		match value {
			Text(text) => Some(text)
			_ => None
		}

	## Whether it is `true`; `fallback` when it isn't a boolean.
	bool_or : Value, Bool -> Bool
	bool_or = |value, fallback|
		match value {
			Boolean(yes) => yes
			_ => fallback
		}

	## A number; `fallback` for anything else.
	int_or : Value, I64 -> I64
	int_or = |value, fallback|
		match value {
			Number(n) => n
			_ => fallback
		}

	## An array's items; none for anything else.
	items : Value -> List(Value)
	items = |value|
		match value {
			Array(list) => list
			_ => []
		}

	## An object's fields; none for anything else.
	fields : Value -> List({ key : Str, value : Value })
	fields = |value|
		match value {
			Object(list) => list
			_ => []
		}

	## Whether it is `null` (or missing: `field` answers `Null` then).
	is_null : Value -> Bool
	is_null = |value|
		match value {
			Null => Bool.True
			_ => Bool.False
		}

	## An array of strings.
	strs : List(Str) -> Value
	strs = |list| Array(list.map(|each| Text(each)))

	## A number from a count.
	count : U64 -> Value
	count = |n| Number(n.to_i64_wrap())

	## A string or `null`.
	text_or_null : [Some(Str), None] -> Value
	text_or_null = |maybe|
		match maybe {
			Some(text) => Text(text)
			None => Null
		}

	## What a function throws, as `rocx internal` answers it: an `Error` with `message`.
	problem : Str -> Value
	problem = |message| Object([{ key: "kind", value: Text("Error") }, { key: "message", value: Text(message) }])

	## A RocxError (a problem in a .rocx file, at a line and column), as `rocx internal` answers it.
	rocx_problem : { reason : Str, file : Str, line : U64, column : U64 } -> Value
	rocx_problem = |e|
		Object([
			{ key: "kind", value: Text("RocxError") },
			{ key: "message", value: Text("${e.file}:${e.line.to_str()}:${e.column.to_str()}: ${e.reason}") },
			{ key: "reason", value: Text(e.reason) },
			{ key: "file", value: Text(e.file) },
			{ key: "line", value: Value.count(e.line) },
			{ key: "column", value: Value.count(e.column) },
		])

	## A FormatError (`roc fmt` couldn't read the code), as `rocx internal` answers it.
	format_problem : Str -> Value
	format_problem = |message| Object([{ key: "kind", value: Text("FormatError") }, { key: "message", value: Text(message) }])

	## The value as JSON text, as `JSON.stringify` writes it (no spaces).
	encode : Value -> Str
	encode = |value|
		match value {
			Null => "null"
			Boolean(yes) => if (yes) "true" else "false"
			Number(n) => n.to_str()
			Text(text) => Value.json_string(text)
			Array(list) => "[".concat(Str.join_with(list.map(Value.encode), ",")).concat("]")
			Object(list) => "{".concat(Str.join_with(list.map(|each| Value.json_string(each.key).concat(":").concat(Value.encode(each.value))), ",")).concat("}")
		}

	## A string as `JSON.stringify` writes it.
	json_string : Str -> Str
	json_string = |text| {
		bytes = text.to_utf8()
		hexes = "0123456789abcdef".to_utf8()
		var $out = List.with_capacity(bytes.len() + 2).append('"')
		for c in bytes {
			if c == '\\' {
				$out = $out.concat(['\\', '\\'])
			} else if c == '"' {
				$out = $out.concat(['\\', '"'])
			} else if c == '\n' {
				$out = $out.concat(['\\', 'n'])
			} else if c == '\r' {
				$out = $out.concat(['\\', 'r'])
			} else if c == '\t' {
				$out = $out.concat(['\\', 't'])
			} else if c == 0x08 {
				$out = $out.concat(['\\', 'b'])
			} else if c == 0x0C {
				$out = $out.concat(['\\', 'f'])
			} else if c < 0x20 {
				$out = $out.concat(['\\', 'u', '0', '0', hexes.get((c // 16).to_u64()) ?? '0', hexes.get((c % 16).to_u64()) ?? '0'])
			} else {
				$out = $out.append(c)
			}
		}
		Str.from_utf8_lossy($out.append('"'))
	}

	## JSON text as a value.
	parse : Str -> Try(Value, [BadJson(Str)])
	parse = |text| {
		bytes = text.to_utf8()
		match Value.parse_at(bytes, Value.skip(bytes, 0)) {
			Ok(found) =>
				if Value.skip(bytes, found.end) == bytes.len() {
					Ok(found.value)
				} else {
					Err(BadJson("something after the value at ${found.end.to_str()}"))
				}
			Err(why) => Err(why)
		}
	}

	## Where JSON's whitespace at `i` ends.
	skip : List(U8), U64 -> U64
	skip = |bytes, i| {
		var $i = i
		while $i < bytes.len() and (Value.byte(bytes, $i) == ' ' or Value.byte(bytes, $i) == '\n' or Value.byte(bytes, $i) == '\r' or Value.byte(bytes, $i) == '\t') {
			$i = $i + 1
		}
		$i
	}

	byte : List(U8), U64 -> U8
	byte = |bytes, i| bytes.get(i) ?? 0

	## The value at `i` (no whitespace before it), and where it ends.
	parse_at : List(U8), U64 -> Try({ value : Value, end : U64 }, [BadJson(Str)])
	parse_at = |bytes, i| {
		c = Value.byte(bytes, i)
		if c == '{' {
			Value.parse_object(bytes, Value.skip(bytes, i + 1), [])
		} else if c == '[' {
			Value.parse_array(bytes, Value.skip(bytes, i + 1), [])
		} else if c == '"' {
			match Value.parse_string(bytes, i + 1) {
				Ok(found) => Ok({ value: Text(found.text), end: found.end })
				Err(why) => Err(why)
			}
		} else if c == 't' {
			Ok({ value: Boolean(Bool.True), end: i + 4 })
		} else if c == 'f' {
			Ok({ value: Boolean(Bool.False), end: i + 5 })
		} else if c == 'n' {
			Ok({ value: Null, end: i + 4 })
		} else if c == '-' or (c >= '0' and c <= '9') {
			Value.parse_number(bytes, i)
		} else {
			Err(BadJson("unexpected byte at ${i.to_str()}"))
		}
	}

	parse_number : List(U8), U64 -> Try({ value : Value, end : U64 }, [BadJson(Str)])
	parse_number = |bytes, i| {
		negative = Value.byte(bytes, i) == '-'
		var $j = if (negative) i + 1 else i
		var $n = 0
		while Value.byte(bytes, $j) >= '0' and Value.byte(bytes, $j) <= '9' {
			$n = $n * 10 + (Value.byte(bytes, $j) - '0').to_i64()
			$j = $j + 1
		}
		# A fraction or an exponent: rocx's numbers are whole, so the whole part is the number.
		while Value.byte(bytes, $j) == '.' or Value.byte(bytes, $j) == 'e' or Value.byte(bytes, $j) == 'E' or Value.byte(bytes, $j) == '+' or Value.byte(bytes, $j) == '-' or (Value.byte(bytes, $j) >= '0' and Value.byte(bytes, $j) <= '9') {
			$j = $j + 1
		}
		Ok({ value: Number(if (negative) 0 - $n else $n), end: $j })
	}

	parse_array : List(U8), U64, List(Value) -> Try({ value : Value, end : U64 }, [BadJson(Str)])
	parse_array = |bytes, i, so_far| {
		if Value.byte(bytes, i) == ']' {
			return Ok({ value: Array(so_far), end: i + 1 })
		}
		found = Value.parse_at(bytes, i)?
		after = Value.skip(bytes, found.end)
		c = Value.byte(bytes, after)
		if c == ',' {
			Value.parse_array(bytes, Value.skip(bytes, after + 1), so_far.append(found.value))
		} else if c == ']' {
			Ok({ value: Array(so_far.append(found.value)), end: after + 1 })
		} else {
			Err(BadJson("expected , or ] at ${after.to_str()}"))
		}
	}

	parse_object : List(U8), U64, List({ key : Str, value : Value }) -> Try({ value : Value, end : U64 }, [BadJson(Str)])
	parse_object = |bytes, i, so_far| {
		if Value.byte(bytes, i) == '}' {
			return Ok({ value: Object(so_far), end: i + 1 })
		}
		if Value.byte(bytes, i) != '"' {
			return Err(BadJson("expected a key at ${i.to_str()}"))
		}
		key = Value.parse_string(bytes, i + 1)?
		colon = Value.skip(bytes, key.end)
		if Value.byte(bytes, colon) != ':' {
			return Err(BadJson("expected : at ${colon.to_str()}"))
		}
		found = Value.parse_at(bytes, Value.skip(bytes, colon + 1))?
		after = Value.skip(bytes, found.end)
		c = Value.byte(bytes, after)
		more = so_far.append({ key: key.text, value: found.value })
		if c == ',' {
			Value.parse_object(bytes, Value.skip(bytes, after + 1), more)
		} else if c == '}' {
			Ok({ value: Object(more), end: after + 1 })
		} else {
			Err(BadJson("expected , or } at ${after.to_str()}"))
		}
	}

	## A string's text from after its opening quote, and where it ends (after its closing quote).
	parse_string : List(U8), U64 -> Try({ text : Str, end : U64 }, [BadJson(Str)])
	parse_string = |bytes, i| {
		var $out = []
		var $j = i
		while $j < bytes.len() {
			c = Value.byte(bytes, $j)
			if c == '"' {
				return Ok({ text: Str.from_utf8_lossy($out), end: $j + 1 })
			} else if c == '\\' {
				e = Value.byte(bytes, $j + 1)
				if e == 'n' {
					$out = $out.append('\n')
					$j = $j + 2
				} else if e == 't' {
					$out = $out.append('\t')
					$j = $j + 2
				} else if e == 'r' {
					$out = $out.append('\r')
					$j = $j + 2
				} else if e == 'b' {
					$out = $out.append(0x08)
					$j = $j + 2
				} else if e == 'f' {
					$out = $out.append(0x0C)
					$j = $j + 2
				} else if e == 'u' {
					unit = Value.hex4(bytes, $j + 2)
					if unit >= 0xD800 and unit <= 0xDBFF and Value.byte(bytes, $j + 6) == '\\' and Value.byte(bytes, $j + 7) == 'u' {
						low = Value.hex4(bytes, $j + 8)
						code = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
						$out = $out.concat(Value.utf8(code))
						$j = $j + 12
					} else {
						$out = $out.concat(Value.utf8(if (unit >= 0xD800 and unit <= 0xDFFF) 0xFFFD else unit))
						$j = $j + 6
					}
				} else {
					$out = $out.append(e)
					$j = $j + 2
				}
			} else {
				$out = $out.append(c)
				$j = $j + 1
			}
		}
		Err(BadJson("a string is never closed"))
	}

	hex4 : List(U8), U64 -> U32
	hex4 = |bytes, i| {
		var $n = 0
		var $k = 0
		while $k < 4 {
			b = Value.byte(bytes, i + $k)
			d = if (b >= '0' and b <= '9') b - '0' else if (b >= 'a' and b <= 'f') b - 'a' + 10 else if (b >= 'A' and b <= 'F') b - 'A' + 10 else 0
			$n = $n * 16 + d.to_u32()
			$k = $k + 1
		}
		$n
	}

	utf8 : U32 -> List(U8)
	utf8 = |code|
		if code < 0x80 {
			[code.to_u8_wrap()]
		} else if code < 0x800 {
			[(0xC0 + code // 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		} else if code < 0x10000 {
			[(0xE0 + code // 4096).to_u8_wrap(), (0x80 + (code // 64) % 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		} else {
			[(0xF0 + code // 262144).to_u8_wrap(), (0x80 + (code // 4096) % 64).to_u8_wrap(), (0x80 + (code // 64) % 64).to_u8_wrap(), (0x80 + code % 64).to_u8_wrap()]
		}
}
