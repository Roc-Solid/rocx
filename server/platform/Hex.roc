## Hexadecimal (RFC 4648, section 8, in lowercase): how `sha256sum`, SigV4's signatures and most test
## vectors write bytes. `decode` takes either case.
Hex := [].{

	## Two lowercase digits a byte.
	encode : List(U8) -> Str
	encode = |bytes| {
		var $out = List.with_capacity(bytes.len() * 2)
		for each in bytes {
			$out = $out.append(digit(each // 16)).append(digit(each % 16))
		}
		Str.from_utf8_lossy($out)
	}

	## The bytes two digits each stand for; either case, nothing else (no `0x`, no spaces).
	decode : Str -> Try(List(U8), [InvalidHex])
	decode = |text| {
		chars = text.to_utf8()
		if chars.len() % 2 == 1 {
			return Err(InvalidHex)
		}
		var $out = List.with_capacity(chars.len() // 2)
		var $at = 0
		while $at < chars.len() {
			high = value(chars.get($at) ?? 0)?
			low = value(chars.get($at + 1) ?? 0)?
			$out = $out.append(high * 16 + low)
			$at = $at + 2
		}
		Ok($out)
	}
}

digit : U8 -> U8
digit = |nibble| if (nibble < 10) '0' + nibble else 'a' + nibble - 10

value : U8 -> Try(U8, [InvalidHex])
value = |char|
	if char >= '0' and char <= '9' {
		Ok(char - '0')
	} else if char >= 'a' and char <= 'f' {
		Ok(char - 'a' + 10)
	} else if char >= 'A' and char <= 'F' {
		Ok(char - 'A' + 10)
	} else {
		Err(InvalidHex)
	}

# RFC 4648, section 10 (BASE16, written here in lowercase).
expect Hex.encode([]) == ""
expect Hex.encode("f".to_utf8()) == "66"
expect Hex.encode("fo".to_utf8()) == "666f"
expect Hex.encode("foo".to_utf8()) == "666f6f"
expect Hex.encode("foob".to_utf8()) == "666f6f62"
expect Hex.encode("fooba".to_utf8()) == "666f6f6261"
expect Hex.encode("foobar".to_utf8()) == "666f6f626172"
expect Hex.decode("666F6F626172") == Ok("foobar".to_utf8())
expect Hex.decode("") == Ok([])

# Every digit, both cases.
expect Hex.encode([0, 1, 9, 10, 15, 16, 127, 128, 171, 205, 239, 255]) == "0001090a0f107f80abcdefff"
expect Hex.decode("0001090a0F107f80ABcdEFff") == Ok([0, 1, 9, 10, 15, 16, 127, 128, 171, 205, 239, 255])
expect {
	var $all = []
	var $each = 0.U64
	while $each < 256 {
		$all = $all.append($each.to_u8_wrap())
		$each = $each + 1
	}
	Hex.decode(Hex.encode($all)) == Ok($all)
}

# Refused: an odd length, and anything not a digit.
expect Hex.decode("abc") == Err(InvalidHex)
expect Hex.decode("zz") == Err(InvalidHex)
expect Hex.decode("0x12") == Err(InvalidHex)
expect Hex.decode("12 4") == Err(InvalidHex)
expect Hex.decode("g0") == Err(InvalidHex)
expect Hex.decode("0G") == Err(InvalidHex)
