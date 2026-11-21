import Hex
import Hmac

## HKDF-SHA256 (RFC 5869), in pure Roc on `Hmac`: keys of their own derived from one secret, as an
## app that signs links derives its link-signing key from its `APP_SECRET`. Checked against RFC
## 5869's SHA-256 test cases.
Hkdf := [].{

	## `length` bytes (at most 255 × 32 = 8160) of key material from `key`, `salt` and `info`:
	## `expand(extract(key, salt), info, length)`.
	sha256 : List(U8), List(U8), List(U8), U64 -> Try(List(U8), [TooLong])
	sha256 = |key, salt, info, length| Hkdf.expand(Hkdf.extract(key, salt), info, length)

	## The 32-byte pseudorandom key of `key` (the input keying material) and `salt`. No salt
	## means 32 zero bytes, as the RFC says.
	extract : List(U8), List(U8) -> List(U8)
	extract = |key, salt| Hmac.sha256(if (salt.is_empty()) List.repeat(0, 32) else salt, key)

	## `length` bytes of output from a pseudorandom key (`extract`'s, or a key that is already
	## uniformly random) and `info`.
	expand : List(U8), List(U8), U64 -> Try(List(U8), [TooLong])
	expand = |pseudorandom_key, info, length| {
		if length > 255 * 32 {
			return Err(TooLong)
		}
		var $out = List.with_capacity(length + 32)
		var $block = []
		var $counter = 1.U64
		while $out.len() < length {
			$block = Hmac.sha256(pseudorandom_key, $block.concat(info).append($counter.to_u8_wrap()))
			$out = $out.concat($block)
			$counter = $counter + 1
		}
		Ok($out.take_first(length))
	}
}

hex_of : Str -> List(U8)
hex_of = |text|
	match Hex.decode(text) {
		Ok(bytes) => bytes
		Err(_) => []
	}

counting : U64, U64 -> List(U8)
counting = |from, to| {
	var $out = []
	var $each = from
	while $each <= to {
		$out = $out.append($each.to_u8_wrap())
		$each = $each + 1
	}
	$out
}

# RFC 5869, appendix A, test case 1 (the basic one): the PRK and the OKM.
expect Hex.encode(Hkdf.extract(List.repeat(0x0b, 22), hex_of("000102030405060708090a0b0c"))) == "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
expect
	Hkdf.sha256(List.repeat(0x0b, 22), hex_of("000102030405060708090a0b0c"), hex_of("f0f1f2f3f4f5f6f7f8f9"), 42).map_ok(Hex.encode)
		== Ok("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")

# Test case 2: longer inputs and outputs (80-byte key, salt and info; 82 bytes out).
expect Hex.encode(Hkdf.extract(counting(0x00, 0x4f), counting(0x60, 0xaf))) == "06a6b88c5853361a06104c9ceb35b45cef760014904671014a193f40c15fc244"
expect
	Hkdf.sha256(counting(0x00, 0x4f), counting(0x60, 0xaf), counting(0xb0, 0xff), 82).map_ok(Hex.encode)
		== Ok("b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87")

# Test case 3: no salt, no info.
expect Hex.encode(Hkdf.extract(List.repeat(0x0b, 22), [])) == "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04"
expect Hkdf.sha256(List.repeat(0x0b, 22), [], [], 42).map_ok(Hex.encode) == Ok("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")

# The ends of the range (a Python HKDF for the longest), and past it.
expect Hkdf.sha256(List.repeat(0x0b, 22), [], [], 0) == Ok([])
expect Hkdf.sha256(List.repeat(0x0b, 22), [], "x".to_utf8(), 1).map_ok(Hex.encode) == Ok("e0")
expect
	match Hkdf.sha256(List.repeat(0x0b, 22), [], [], 8160) {
		Ok(bytes) => bytes.len() == 8160 and Hex.encode(bytes.take_last(8)) == "47aae9cd77993ea6"
		Err(_) => Bool.False
	}
expect Hkdf.sha256([1], [], [], 8161) == Err(TooLong)
expect Hkdf.expand(List.repeat(1, 32), [], 8161) == Err(TooLong)

# A prefix of a longer output is the shorter output.
expect Hkdf.sha256([1, 2, 3], [4], [5], 40).map_ok(|bytes| bytes.take_first(10)) == Hkdf.sha256([1, 2, 3], [4], [5], 10)
