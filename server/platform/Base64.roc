## Base64 (RFC 4648), both alphabets, both ways. The standard one, padded, is email's (a body that
## isn't plain ASCII, an encoded subject, SMTP's `AUTH PLAIN`); the URL one, unpadded, is for
## tokens and signatures that go in links and cookies (section 5).
##
## Decoding is strict, so one string means one value: only the alphabet asked for, no spaces or line
## breaks, padding either left out or exactly right, and the unused bits of the last character zero.
Base64 := [].{

	## The standard alphabet (`+`, `/`), padded with `=` to a multiple of 4.
	encode : List(U8) -> Str
	encode = |bytes| encoded(bytes, standard, Bool.True)

	## The standard alphabet, without the `=` padding.
	encode_unpadded : List(U8) -> Str
	encode_unpadded = |bytes| encoded(bytes, standard, Bool.False)

	## The URL and filename alphabet (`-`, `_`), without padding: what tokens in links are.
	url_encode : List(U8) -> Str
	url_encode = |bytes| encoded(bytes, url, Bool.False)

	## The URL and filename alphabet, padded with `=`.
	url_encode_padded : List(U8) -> Str
	url_encode_padded = |bytes| encoded(bytes, url, Bool.True)

	## The bytes of standard Base64, padded or not.
	decode : Str -> Try(List(U8), [InvalidBase64])
	decode = |text| decoded(text, Standard)

	## The bytes of URL-alphabet Base64, padded or not.
	url_decode : Str -> Try(List(U8), [InvalidBase64])
	url_decode = |text| decoded(text, Url)

	## `encode`, in lines of 76 characters, as MIME wants a body.
	lines : List(U8) -> Str
	lines = |bytes| {
		encoded_bytes = Base64.encode(bytes).to_utf8()
		var $out = []
		var $at = 0
		for each in encoded_bytes {
			if $at > 0 and $at % 76 == 0 {
				$out = $out.append('\r').append('\n')
			} else {
				{}
			}
			$out = $out.append(each)
			$at = $at + 1
		}
		Str.from_utf8_lossy($out)
	}
}

standard : List(U8)
standard = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()

url : List(U8)
url = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".to_utf8()

encoded : List(U8), List(U8), Bool -> Str
encoded = |bytes, alphabet, padded| {
	count = bytes.len()
	var $out = List.with_capacity((count + 2) // 3 * 4)
	var $at = 0
	while $at < count {
		group = byte(bytes, $at).shl_wrap(16).bitwise_or(byte(bytes, $at + 1).shl_wrap(8)).bitwise_or(byte(bytes, $at + 2))
		left = count - $at
		$out = $out.append(letter(alphabet, group.shr_zf_wrap(18))).append(letter(alphabet, group.shr_zf_wrap(12)))
		if left > 1 {
			$out = $out.append(letter(alphabet, group.shr_zf_wrap(6)))
		} else if padded {
			$out = $out.append('=')
		} else {
			{}
		}
		if left > 2 {
			$out = $out.append(letter(alphabet, group))
		} else if padded {
			$out = $out.append('=')
		} else {
			{}
		}
		$at = $at + 3
	}
	Str.from_utf8_lossy($out)
}

decoded : Str, [Standard, Url] -> Try(List(U8), [InvalidBase64])
decoded = |text, which| {
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
			sextet = if ($each < taken) six_bits(chars.get($at + $each) ?? '=', which)? else 0
			$group = $group.shl_wrap(6).bitwise_or(sextet)
			$each = $each + 1
		}
		# The bits after the last whole byte must be zero ("Zh==" is not another spelling of "Zg==").
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

byte : List(U8), U64 -> U32
byte = |bytes, at|
	match bytes.get(at) {
		Ok(value) => value.to_u32()
		Err(_) => 0
	}

letter : List(U8), U32 -> U8
letter = |alphabet, sextet| alphabet.get(sextet.bitwise_and(63).to_u64()) ?? '='

six_bits : U8, [Standard, Url] -> Try(U32, [InvalidBase64])
six_bits = |char, which|
	if char >= 'A' and char <= 'Z' {
		Ok((char - 'A').to_u32())
	} else if char >= 'a' and char <= 'z' {
		Ok((char - 'a').to_u32() + 26)
	} else if char >= '0' and char <= '9' {
		Ok((char - '0').to_u32() + 52)
	} else {
		match (which, char) {
			(Standard, '+') => Ok(62)
			(Standard, '/') => Ok(63)
			(Url, '-') => Ok(62)
			(Url, '_') => Ok(63)
			_ => Err(InvalidBase64)
		}
	}

# The module's earlier expects, kept.
expect Base64.encode("".to_utf8()) == ""
expect Base64.encode("f".to_utf8()) == "Zg=="
expect Base64.encode("fo".to_utf8()) == "Zm8="
expect Base64.encode("foo".to_utf8()) == "Zm9v"
expect Base64.encode("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64.encode([0, 117, 0, 112]) == "AHUAcA=="

# RFC 4648, section 10, every vector, each way.
expect Base64.encode("foob".to_utf8()) == "Zm9vYg=="
expect Base64.encode("fooba".to_utf8()) == "Zm9vYmE="
expect Base64.decode("") == Ok([])
expect Base64.decode("Zg==") == Ok("f".to_utf8())
expect Base64.decode("Zm8=") == Ok("fo".to_utf8())
expect Base64.decode("Zm9v") == Ok("foo".to_utf8())
expect Base64.decode("Zm9vYg==") == Ok("foob".to_utf8())
expect Base64.decode("Zm9vYmE=") == Ok("fooba".to_utf8())
expect Base64.decode("Zm9vYmFy") == Ok("foobar".to_utf8())

# Unpadded, in both alphabets (the RFC's vectors without their `=`).
expect Base64.encode_unpadded("".to_utf8()) == ""
expect Base64.encode_unpadded("f".to_utf8()) == "Zg"
expect Base64.encode_unpadded("fo".to_utf8()) == "Zm8"
expect Base64.encode_unpadded("foo".to_utf8()) == "Zm9v"
expect Base64.encode_unpadded("foob".to_utf8()) == "Zm9vYg"
expect Base64.encode_unpadded("fooba".to_utf8()) == "Zm9vYmE"
expect Base64.encode_unpadded("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64.url_encode("".to_utf8()) == ""
expect Base64.url_encode("f".to_utf8()) == "Zg"
expect Base64.url_encode("fo".to_utf8()) == "Zm8"
expect Base64.url_encode("foo".to_utf8()) == "Zm9v"
expect Base64.url_encode("foob".to_utf8()) == "Zm9vYg"
expect Base64.url_encode("fooba".to_utf8()) == "Zm9vYmE"
expect Base64.url_encode("foobar".to_utf8()) == "Zm9vYmFy"
expect Base64.url_encode_padded("f".to_utf8()) == "Zg=="
expect Base64.url_encode_padded("fooba".to_utf8()) == "Zm9vYmE="
expect Base64.decode("Zg") == Ok("f".to_utf8())
expect Base64.decode("Zm9vYmE") == Ok("fooba".to_utf8())
expect Base64.url_decode("Zm9vYg") == Ok("foob".to_utf8())
expect Base64.url_decode("Zm9vYg==") == Ok("foob".to_utf8())
expect Base64.url_decode("Zm9vYmFy") == Ok("foobar".to_utf8())

# The two characters the alphabets differ in (RFC 4648, sections 4 and 5).
expect Base64.encode([251, 255, 191]) == "+/+/"
expect Base64.url_encode([251, 255, 191]) == "-_-_"
expect Base64.encode([251, 255]) == "+/8="
expect Base64.url_encode([251, 255]) == "-_8"
expect Base64.url_encode_padded([251, 255]) == "-_8="
expect Base64.decode("+/+/") == Ok([251, 255, 191])
expect Base64.url_decode("-_-_") == Ok([251, 255, 191])
expect Base64.url_decode("-_8") == Ok([251, 255])
expect Base64.decode("+/+/").is_ok() and Base64.url_decode("+/+/").is_err()
expect Base64.url_decode("-_-_").is_ok() and Base64.decode("-_-_").is_err()

# Every byte value, and every length's padding, there and back.
expect {
	var $all = []
	var $each = 0.U64
	while $each < 256 {
		$all = $all.append($each.to_u8_wrap())
		$each = $each + 1
	}
	Base64.decode(Base64.encode($all)) == Ok($all)
		and Base64.url_decode(Base64.url_encode($all)) == Ok($all)
		and Base64.decode(Base64.encode_unpadded($all)) == Ok($all)
		and Base64.url_decode(Base64.url_encode_padded($all)) == Ok($all)
}
expect {
	var $ok = Bool.True
	var $length = 0
	while $length < 8 {
		bytes = List.repeat(0xa5, $length)
		$ok = $ok and Base64.decode(Base64.encode(bytes)) == Ok(bytes) and Base64.url_decode(Base64.url_encode(bytes)) == Ok(bytes)
		$length = $length + 1
	}
	$ok
}

# Refused: other characters, a lone character, padding wrong or in the middle, bits left over.
expect Base64.decode("Zm9v!") == Err(InvalidBase64)
expect Base64.url_decode("Zm9v!") == Err(InvalidBase64)
expect Base64.decode("Z") == Err(InvalidBase64)
expect Base64.decode("Zm9vY") == Err(InvalidBase64)
expect Base64.decode("Zm9v Yg==") == Err(InvalidBase64)
expect Base64.decode("Zm9v\r\nYg==") == Err(InvalidBase64)
expect Base64.decode("Zg=") == Err(InvalidBase64)
expect Base64.decode("Zm8==") == Err(InvalidBase64)
expect Base64.decode("Zm9vYmE==") == Err(InvalidBase64)
expect Base64.decode("Zm9v=") == Err(InvalidBase64)
expect Base64.decode("Zg===") == Err(InvalidBase64)
expect Base64.decode("====") == Err(InvalidBase64)
expect Base64.decode("Zg==Zg==") == Err(InvalidBase64)
expect Base64.decode("Zh==") == Err(InvalidBase64)
expect Base64.decode("Zm9=") == Err(InvalidBase64)
expect Base64.url_decode("Zh") == Err(InvalidBase64)

# MIME lines: 57 bytes make one full line of 76; the 58th starts another.
expect Base64.lines(List.repeat(0, 57)) == Str.repeat("A", 76)
expect Base64.lines(List.repeat(0, 58)) == Str.concat(Str.repeat("A", 76), "\r\nAA==")
expect Base64.lines("foo".to_utf8()) == "Zm9v"
