## Base64 (RFC 4648, with padding), as MCP carries bytes in JSON (an image, a resource's blob) and
## a header's value that isn't plain ASCII (`=?base64?…?=`). The server platform has its own
## `Base64`; a package on no platform can't use it, and needs only these two.
Base64 := [].{

	## The bytes as Base64 text.
	encode : List(U8) -> Str
	encode = |bytes| {
		var $out = []
		var $at = 0
		while $at < bytes.len() {
			a = bytes.get($at) ?? 0
			b = bytes.get($at + 1) ?? 0
			c = bytes.get($at + 2) ?? 0
			left = bytes.len() - $at
			$out = $out.append(letter(a // 4))
			$out = $out.append(letter((a % 4) * 16 + b // 16))
			$out = $out.append(if (left > 1) letter((b % 16) * 4 + c // 64) else '=')
			$out = $out.append(if (left > 2) letter(c % 64) else '=')
			$at = $at + 3
		}
		Str.from_utf8($out) ?? ""
	}

	## The bytes Base64 text holds, padded or not; `NotBase64` for a letter that isn't one of its 64.
	decode : Str -> Try(List(U8), [NotBase64])
	decode = |text| {
		var $values = []
		for byte in text.to_utf8() {
			if byte != '=' {
				$values = $values.append(value_of(byte)?)
			}
		}
		if $values.len() % 4 == 1 {
			return Err(NotBase64)
		}
		var $out = []
		var $at = 0
		while $at < $values.len() {
			a = $values.get($at) ?? 0
			b = $values.get($at + 1) ?? 0
			c = $values.get($at + 2) ?? 0
			d = $values.get($at + 3) ?? 0
			left = $values.len() - $at
			$out = $out.append(a * 4 + b // 16)
			if left > 2 {
				$out = $out.append((b % 16) * 16 + c // 4)
			}
			if left > 3 {
				$out = $out.append((c % 4) * 64 + d)
			}
			$at = $at + 4
		}
		Ok($out)
	}
}

alphabet : List(U8)
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()

letter : U8 -> U8
letter = |value| alphabet.get(value.to_u64()) ?? '='

value_of : U8 -> Try(U8, [NotBase64])
value_of = |byte|
	if byte >= 'A' and byte <= 'Z' {
		Ok(byte - 'A')
	} else if byte >= 'a' and byte <= 'z' {
		Ok(byte - 'a' + 26)
	} else if byte >= '0' and byte <= '9' {
		Ok(byte - '0' + 52)
	} else if byte == '+' {
		Ok(62)
	} else if byte == '/' {
		Ok(63)
	} else {
		Err(NotBase64)
	}

expect Base64.encode("".to_utf8()) == ""
expect Base64.encode("f".to_utf8()) == "Zg=="
expect Base64.encode("fo".to_utf8()) == "Zm8="
expect Base64.encode("foo".to_utf8()) == "Zm9v"
expect Base64.encode("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64.encode([0, 255, 254]) == "AP/+"
expect Base64.decode("Zm9vYmFy") == Ok("foobar".to_utf8())
expect Base64.decode("Zg==") == Ok("f".to_utf8())
expect Base64.decode("Zm8") == Ok("fo".to_utf8())
expect Base64.decode("AP/+") == Ok([0, 255, 254])
expect Base64.decode("SGVsbG8sIOS4lueVjA==").map_ok(|bytes| Str.from_utf8(bytes) ?? "") == Ok("Hello, 世界")
expect Base64.decode("Zm9v!") == Err(NotBase64)
expect Base64.decode("Z") == Err(NotBase64)
