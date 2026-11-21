## Base64 in the URL and filename alphabet (RFC 4648, section 5), unpadded: how Web Push writes its
## keys (a subscription's `p256dh` and `auth`, the VAPID public key) and a JWT's parts. Decoding
## takes it padded or not, and is otherwise strict, as the server platform's `Base64` is: only the
## alphabet, no spaces, padding either left out or exactly right, the last character's unused bits
## zero. One text, one value.
Base64Url := [].{

	## The URL alphabet (`-`, `_`), unpadded.
	encode : List(U8) -> Str
	encode = |bytes| {
		count = bytes.len()
		var $out = List.with_capacity((count + 2) // 3 * 4)
		var $at = 0
		while $at < count {
			group = byte(bytes, $at).shl_wrap(16).bitwise_or(byte(bytes, $at + 1).shl_wrap(8)).bitwise_or(byte(bytes, $at + 2))
			left = count - $at
			$out = $out.append(letter(group.shr_zf_wrap(18))).append(letter(group.shr_zf_wrap(12)))
			if left > 1 {
				$out = $out.append(letter(group.shr_zf_wrap(6)))
			}
			if left > 2 {
				$out = $out.append(letter(group))
			}
			$at = $at + 3
		}
		Str.from_utf8_lossy($out)
	}

	## The bytes of URL-alphabet Base64, padded or not.
	decode : Str -> Try(List(U8), [InvalidBase64])
	decode = |text| {
		chars = text.to_utf8()
		count = chars.len()
		pads =
			if chars.last() != Ok('=') {
				0
			} else if count >= 2 and chars.get(count - 2) == Ok('=') {
				2
			} else {
				1
			}
		data = count - pads
		if pads > 0 and count % 4 != 0 {
			return Err(InvalidBase64)
		}
		if data % 4 == 1 {
			return Err(InvalidBase64)
		}
		var $out = List.with_capacity(data // 4 * 3 + 2)
		var $at = 0
		while $at < data {
			taken = U64.min(4, data - $at)
			var $group = 0.U32
			var $each = 0
			while $each < 4 {
				sextet = if ($each < taken) six_bits(chars.get($at + $each) ?? '=')? else 0
				$group = $group.shl_wrap(6).bitwise_or(sextet)
				$each = $each + 1
			}
			# The bits after the last whole byte must be zero ("Zh" is not another spelling of "Zg").
			unused = if (taken == 2) 0xFFFF else if (taken == 3) 0xFF else 0
			if $group.bitwise_and(unused) != 0 {
				return Err(InvalidBase64)
			}
			$out = $out.append($group.shr_zf_wrap(16).to_u8_wrap())
			if taken > 2 {
				$out = $out.append($group.shr_zf_wrap(8).to_u8_wrap())
			}
			if taken > 3 {
				$out = $out.append($group.to_u8_wrap())
			}
			$at = $at + 4
		}
		Ok($out)
	}
}

alphabet : List(U8)
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".to_utf8()

byte : List(U8), U64 -> U32
byte = |bytes, at|
	match bytes.get(at) {
		Ok(value) => value.to_u32()
		Err(_) => 0
	}

letter : U32 -> U8
letter = |sextet| alphabet.get(sextet.bitwise_and(63).to_u64()) ?? '='

six_bits : U8 -> Try(U32, [InvalidBase64])
six_bits = |char|
	if char >= 'A' and char <= 'Z' {
		Ok((char - 'A').to_u32())
	} else if char >= 'a' and char <= 'z' {
		Ok((char - 'a').to_u32() + 26)
	} else if char >= '0' and char <= '9' {
		Ok((char - '0').to_u32() + 52)
	} else if char == '-' {
		Ok(62)
	} else if char == '_' {
		Ok(63)
	} else {
		Err(InvalidBase64)
	}

# RFC 4648, section 10, without the padding.
expect Base64Url.encode([]) == ""
expect Base64Url.encode("f".to_utf8()) == "Zg"
expect Base64Url.encode("fo".to_utf8()) == "Zm8"
expect Base64Url.encode("foo".to_utf8()) == "Zm9v"
expect Base64Url.encode("foob".to_utf8()) == "Zm9vYg"
expect Base64Url.encode("fooba".to_utf8()) == "Zm9vYmE"
expect Base64Url.encode("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64Url.decode("") == Ok([])
expect Base64Url.decode("Zm9vYg") == Ok("foob".to_utf8())
expect Base64Url.decode("Zm9vYg==") == Ok("foob".to_utf8())
expect Base64Url.decode("Zm9vYmE=") == Ok("fooba".to_utf8())
expect Base64Url.decode("Zm9vYmFy") == Ok("foobar".to_utf8())

# The two characters this alphabet differs in; the standard alphabet's are refused.
expect Base64Url.encode([251, 255, 191]) == "-_-_"
expect Base64Url.encode([251, 255]) == "-_8"
expect Base64Url.decode("-_-_") == Ok([251, 255, 191])
expect Base64Url.decode("+/+/") == Err(InvalidBase64)

# Every byte value there and back, and every length's tail.
expect {
	var $all = []
	var $each = 0.U64
	while $each < 256 {
		$all = $all.append($each.to_u8_wrap())
		$each = $each + 1
	}
	Base64Url.decode(Base64Url.encode($all)) == Ok($all)
}
expect {
	var $ok = Bool.True
	var $length = 0
	while $length < 8 {
		bytes = List.repeat(0xa5, $length)
		$ok = $ok and Base64Url.decode(Base64Url.encode(bytes)) == Ok(bytes)
		$length = $length + 1
	}
	$ok
}

# Refused: other characters, a lone character, padding wrong, bits left over.
expect Base64Url.decode("Zm9v!") == Err(InvalidBase64)
expect Base64Url.decode("Z") == Err(InvalidBase64)
expect Base64Url.decode("Zm9vY") == Err(InvalidBase64)
expect Base64Url.decode("Zm9v Yg") == Err(InvalidBase64)
expect Base64Url.decode("Zg=") == Err(InvalidBase64)
expect Base64Url.decode("Zm9v=") == Err(InvalidBase64)
expect Base64Url.decode("Zh") == Err(InvalidBase64)

# A P-256 public key as browsers give it: 65 bytes, the first 4 (uncompressed).
expect
	match Base64Url.decode("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4") {
		Ok(key) => key.len() == 65 and key.first() == Ok(4)
		Err(_) => Bool.False
	}
