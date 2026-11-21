## Queries and forms as a browser sends them (`a=1&b=two+words`), and links back: the admin reads
## every choice from its URL's query or a posted form, and writes links the same way.
Form := [].{

	## A field: its name and its value, decoded.
	Field : { name : Str, value : Str }

	## A query or a posted form's fields, in order, decoded: `+` is a space, `%26` an `&`.
	fields : Str -> List(Field)
	fields = |encoded|
		encoded.split_on("&").keep_if(|pair| !pair.is_empty()).map(
			|pair|
				match pair.split_first("=") {
					Ok({ before, after }) => { name: decoded(before), value: decoded(after) }
					Err(_) => { name: decoded(pair), value: "" }
				},
		)

	## The value of the last field called `name` ("" if there is none): a checkbox, when it is
	## ticked, comes after the hidden field that says it isn't.
	get : List(Field), Str -> Str
	get = |given, name|
		match given.find_last(|field| field.name == name) {
			Ok(field) => field.value
			Err(_) => ""
		}

	## Whether there is a field called `name`, with a value or without (`?new`).
	asks : List(Field), Str -> Bool
	asks = |given, name| given.any(|field| field.name == name)

	## The fields whose names start with `prefix`, without it, each name once (its last value):
	## `k.id=3` is `("id", "3")` for `"k."`.
	prefixed : List(Field), Str -> List((Str, Str))
	prefixed = |given, prefix| {
		names = given.keep_if(|field| field.name.starts_with(prefix) and field.name != prefix).map(|field| field.name.drop_prefix(prefix))
		once = names.fold([], |seen, name| if (seen.contains(name)) seen else seen.append(name))
		once.map(|name| (name, Form.get(given, "${prefix}${name}")))
	}

	## Text as a part of a query: anything but a letter, a digit or `-._~` as `%XX`.
	encode : Str -> Str
	encode = |text| {
		var $out = []
		for byte in text.to_utf8() {
			$out =
				if (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '.' or byte == '_' or byte == '~' {
					$out.append(byte)
				} else {
					$out.concat(['%', hex_digit(byte // 16), hex_digit(byte % 16)])
				}
		}
		Str.from_utf8_lossy($out)
	}

	## `path`, with `params` as its query; a param whose value is "" is left out.
	link : Str, List((Str, Str)) -> Str
	link = |path, params| {
		given = params.keep_if(|(_, value)| !value.is_empty()).map(|(name, value)| "${Form.encode(name)}=${Form.encode(value)}")
		if (given.is_empty()) path else "${path}?${Str.join_with(given, "&")}"
	}
}

## `+` as a space, and `%XX` as its byte; a `%` that isn't followed by two hex digits stays.
decoded : Str -> Str
decoded = |text| {
	bytes = text.to_utf8()
	var $out = []
	var $at = 0
	while $at < bytes.len() {
		byte = bytes.get($at) ?? 0
		if byte == '%' {
			match (hex_value(bytes.get($at + 1) ?? 0), hex_value(bytes.get($at + 2) ?? 0)) {
				(Ok(high), Ok(low)) => {
					$out = $out.append(high * 16 + low)
					$at = $at + 3
				}
				_ => {
					$out = $out.append(byte)
					$at = $at + 1
				}
			}
		} else {
			$out = $out.append(if (byte == '+') ' ' else byte)
			$at = $at + 1
		}
	}
	Str.from_utf8_lossy($out)
}

hex_value : U8 -> Try(U8, [NotHex])
hex_value = |byte|
	if byte >= '0' and byte <= '9' {
		Ok(byte - '0')
	} else if byte >= 'a' and byte <= 'f' {
		Ok(byte - 'a' + 10)
	} else if byte >= 'A' and byte <= 'F' {
		Ok(byte - 'A' + 10)
	} else {
		Err(NotHex)
	}

hex_digit : U8 -> U8
hex_digit = |n| if (n < 10) '0' + n else 'A' + n - 10

expect Form.fields("a=1&b=two+words&c=%26%3D&d") == [{ name: "a", value: "1" }, { name: "b", value: "two words" }, { name: "c", value: "&=" }, { name: "d", value: "" }]
expect Form.fields("") == []
expect Form.fields("q=caf%C3%A9&bad=%zz%4") == [{ name: "q", value: "café" }, { name: "bad", value: "%zz%4" }]
expect Form.get(Form.fields("v.on=false&v.on=true"), "v.on") == "true"
expect Form.get(Form.fields("a=1"), "b") == ""
expect Form.asks(Form.fields("table=users&new"), "new") and !Form.asks(Form.fields("table=users"), "new")
expect Form.prefixed(Form.fields("table=t&k.id=3&k.lang=en&k.id=4&k.=x"), "k.") == [("id", "4"), ("lang", "en")]
expect Form.encode("a b&c/é") == "a%20b%26c%2F%C3%A9"
expect Form.link("/admin", [("table", "users"), ("q", ""), ("k.id", "3")]) == "/admin?table=users&k.id=3"
expect Form.link("/admin", []) == "/admin"
expect Form.fields(Form.encode("x=1&y")) == [{ name: "x=1&y", value: "" }]
