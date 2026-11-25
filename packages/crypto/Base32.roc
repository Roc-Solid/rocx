## Base32 (RFC 4648, section 6): `A` to `Z` and `2` to `7`, five bits a letter. How an
## authenticator app's secret is written (the `secret=` of an `otpauth://` URI, and the text a
## person types when they can't scan the code), where letters only, in one case, matter more than
## length.
##
## Decoding takes either case (a person may type the secret in lowercase), padded or not, and is
## strict otherwise, so one string means one value: only the alphabet, no spaces or dashes, padding
## either left out or exactly right, and the unused bits of the last letter zero.
Base32 := [].{

	## Padded with `=` to a multiple of 8, as RFC 4648 writes it.
	encode : List(U8) -> Str
	encode = |bytes| encoded(bytes, Bool.True)

	## Without the `=` padding: an `otpauth://` URI's `secret`.
	encode_unpadded : List(U8) -> Str
	encode_unpadded = |bytes| encoded(bytes, Bool.False)

	## The bytes of Base32, in either case, padded or not.
	decode : Str -> Try(List(U8), [InvalidBase32])
	decode = |text| {
		chars = text.to_utf8()
		count = chars.len()
		var $pads = 0
		while $pads < count and chars.get(count - 1 - $pads) == Ok('=') {
			$pads = $pads + 1
		}
		data = count - $pads
		if $pads > 0 and (count % 8 != 0 or $pads != (8 - data % 8) % 8) {
			return Err(InvalidBase32)
		}
		var $out = List.with_capacity(data * 5 // 8)
		var $buffer = 0.U32
		var $bits = 0.U8
		for char in chars.take_first(data) {
			$buffer = $buffer.shl_wrap(5).bitwise_or(five_bits(char)?)
			$bits = $bits + 5
			if $bits >= 8 {
				$bits = $bits - 8
				$out = $out.append($buffer.shr_zf_wrap($bits).to_u8_wrap())
				$buffer = $buffer.bitwise_and((1.U32).shl_wrap($bits) - 1)
			}
		}
		# What is left must be fewer bits than a letter, and zero: one letter, three or six can't
		# end a value, and "MZ" is not another spelling of "MY".
		if $bits >= 5 or $buffer != 0 {
			return Err(InvalidBase32)
		}
		Ok($out)
	}
}

alphabet : List(U8)
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".to_utf8()

encoded : List(U8), Bool -> Str
encoded = |bytes, padded| {
	var $out = List.with_capacity((bytes.len() + 4) // 5 * 8)
	var $buffer = 0.U32
	var $bits = 0.U8
	for each in bytes {
		$buffer = $buffer.shl_wrap(8).bitwise_or(each.to_u32())
		$bits = $bits + 8
		while $bits >= 5 {
			$bits = $bits - 5
			$out = $out.append(letter($buffer.shr_zf_wrap($bits)))
		}
		$buffer = $buffer.bitwise_and((1.U32).shl_wrap($bits) - 1)
	}
	if $bits > 0 {
		$out = $out.append(letter($buffer.shl_wrap(5 - $bits)))
	}
	if padded {
		while $out.len() % 8 != 0 {
			$out = $out.append('=')
		}
	}
	Str.from_utf8_lossy($out)
}

letter : U32 -> U8
letter = |quintet| alphabet.get(quintet.bitwise_and(31).to_u64()) ?? '='

five_bits : U8 -> Try(U32, [InvalidBase32])
five_bits = |char|
	if char >= 'A' and char <= 'Z' {
		Ok((char - 'A').to_u32())
	} else if char >= 'a' and char <= 'z' {
		Ok((char - 'a').to_u32())
	} else if char >= '2' and char <= '7' {
		Ok((char - '2').to_u32() + 26)
	} else {
		Err(InvalidBase32)
	}

# RFC 4648, section 10, every BASE32 vector, each way.
expect Base32.encode([]) == ""
expect Base32.encode("f".to_utf8()) == "MY======"
expect Base32.encode("fo".to_utf8()) == "MZXQ===="
expect Base32.encode("foo".to_utf8()) == "MZXW6==="
expect Base32.encode("foob".to_utf8()) == "MZXW6YQ="
expect Base32.encode("fooba".to_utf8()) == "MZXW6YTB"
expect Base32.encode("foobar".to_utf8()) == "MZXW6YTBOI======"
expect Base32.decode("") == Ok([])
expect Base32.decode("MY======") == Ok("f".to_utf8())
expect Base32.decode("MZXQ====") == Ok("fo".to_utf8())
expect Base32.decode("MZXW6===") == Ok("foo".to_utf8())
expect Base32.decode("MZXW6YQ=") == Ok("foob".to_utf8())
expect Base32.decode("MZXW6YTB") == Ok("fooba".to_utf8())
expect Base32.decode("MZXW6YTBOI======") == Ok("foobar".to_utf8())

# Unpadded, and in lowercase.
expect Base32.encode_unpadded("f".to_utf8()) == "MY"
expect Base32.encode_unpadded("foobar".to_utf8()) == "MZXW6YTBOI"
expect Base32.decode("MY") == Ok("f".to_utf8())
expect Base32.decode("MZXW6YTBOI") == Ok("foobar".to_utf8())
expect Base32.decode("mzxw6ytboi") == Ok("foobar".to_utf8())
# RFC 6238's SHA-1 seed, "12345678901234567890", as authenticator apps are given it.
expect Base32.encode_unpadded("12345678901234567890".to_utf8()) == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

# Every byte value, and every length's padding, there and back.
expect {
	var $all = []
	var $each = 0.U64
	while $each < 256 {
		$all = $all.append($each.to_u8_wrap())
		$each = $each + 1
	}
	Base32.decode(Base32.encode($all)) == Ok($all) and Base32.decode(Base32.encode_unpadded($all)) == Ok($all)
}
expect {
	var $ok = Bool.True
	var $length = 0
	while $length < 12 {
		bytes = List.repeat(0xa5, $length)
		$ok = $ok and Base32.decode(Base32.encode(bytes)) == Ok(bytes) and Base32.decode(Base32.encode_unpadded(bytes)) == Ok(bytes)
		$length = $length + 1
	}
	$ok
}

# Refused: other characters (0, 1, 8, 9 aren't letters of it), spaces and dashes, lengths no
# value has, padding wrong or in the middle, bits left over.
expect Base32.decode("MZXW6YT0") == Err(InvalidBase32)
expect Base32.decode("MZXW6YT8") == Err(InvalidBase32)
expect Base32.decode("MZXW 6YTB") == Err(InvalidBase32)
expect Base32.decode("MZXW-6YTB") == Err(InvalidBase32)
expect Base32.decode("M") == Err(InvalidBase32)
expect Base32.decode("MZX") == Err(InvalidBase32)
expect Base32.decode("MZXW6Y") == Err(InvalidBase32)
expect Base32.decode("MY=====") == Err(InvalidBase32)
expect Base32.decode("MY=======") == Err(InvalidBase32)
expect Base32.decode("MZXW6Y==") == Err(InvalidBase32)
expect Base32.decode("MY======MY======") == Err(InvalidBase32)
expect Base32.decode("========") == Err(InvalidBase32)
expect Base32.decode("MZ") == Err(InvalidBase32)
expect Base32.decode("MZ======") == Err(InvalidBase32)
