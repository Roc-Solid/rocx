## HMAC-SHA-256 (RFC 2104) and HKDF-SHA-256 (RFC 5869), on Roc's builtin `Crypto.SHA256`: the key
## derivation Web Push's encryption is made of (RFC 8291's key combining, RFC 8188's content key and
## nonce). The server platform has the same in `Hmac` and `Hkdf`; they are here because a package
## can't import a platform's modules.
Kdf := [].{

	## The 32-byte HMAC-SHA-256 of `message` under `key`.
	hmac : List(U8), List(U8) -> List(U8)
	hmac = |key, message| {
		short_key = if (key.len() > block_size) Crypto.SHA256.hash(key).to_bytes() else key
		padded = short_key.concat(List.repeat(0, block_size - short_key.len()))
		inner = Crypto.SHA256.hash(padded.map(|each| each.bitwise_xor(0x36)).concat(message)).to_bytes()
		Crypto.SHA256.hash(padded.map(|each| each.bitwise_xor(0x5c)).concat(inner)).to_bytes()
	}

	## HKDF-Extract: the 32-byte pseudorandom key of `salt` and the input keying material.
	extract : List(U8), List(U8) -> List(U8)
	extract = |salt, input| Kdf.hmac(if (salt.is_empty()) List.repeat(0, 32) else salt, input)

	## HKDF-Expand: `length` bytes (at most 8160) from a pseudorandom key and `info`.
	expand : List(U8), List(U8), U64 -> Try(List(U8), [TooLong])
	expand = |pseudorandom_key, info, length| {
		if length > 255 * 32 {
			return Err(TooLong)
		}
		var $out = List.with_capacity(length + 32)
		var $block = []
		var $counter = 1.U64
		while $out.len() < length {
			$block = Kdf.hmac(pseudorandom_key, $block.concat(info).append($counter.to_u8_wrap()))
			$out = $out.concat($block)
			$counter = $counter + 1
		}
		Ok($out.take_first(length))
	}

	## HKDF: `expand(extract(salt, input), info, length)`. Web Push asks for 32 bytes at most, so
	## its callers take what it gives with `?? []` only where the length is a constant.
	hkdf : List(U8), List(U8), List(U8), U64 -> Try(List(U8), [TooLong])
	hkdf = |salt, input, info, length| Kdf.expand(Kdf.extract(salt, input), info, length)
}

block_size : U64
block_size = 64

hex : List(U8) -> Str
hex = |bytes| {
	digits = "0123456789abcdef".to_utf8()
	var $out = List.with_capacity(bytes.len() * 2)
	for each in bytes {
		$out = $out.append(digits.get((each // 16).to_u64()) ?? '0').append(digits.get((each % 16).to_u64()) ?? '0')
	}
	Str.from_utf8_lossy($out)
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

# RFC 4231, test cases 1, 2 and 6 (a key longer than a block, hashed first).
expect hex(Kdf.hmac(List.repeat(0x0b, 20), "Hi There".to_utf8())) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
expect hex(Kdf.hmac("Jefe".to_utf8(), "what do ya want for nothing?".to_utf8())) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
expect hex(Kdf.hmac(List.repeat(0xaa, 131), "Test Using Larger Than Block-Size Key - Hash Key First".to_utf8())) == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"

# RFC 5869, test cases 1 (basic), 2 (long inputs and output) and 3 (no salt, no info).
expect hex(Kdf.extract(counting(0x00, 0x0c), List.repeat(0x0b, 22))) == "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"
expect Kdf.hkdf(counting(0x00, 0x0c), List.repeat(0x0b, 22), counting(0xf0, 0xf9), 42).map_ok(hex) == Ok("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
expect
	Kdf.hkdf(counting(0x60, 0xaf), counting(0x00, 0x4f), counting(0xb0, 0xff), 82).map_ok(hex)
		== Ok("b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87")
expect Kdf.hkdf([], List.repeat(0x0b, 22), [], 42).map_ok(hex) == Ok("8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
expect Kdf.hkdf([1], [2], [], 0) == Ok([])
expect Kdf.hkdf([1], [2], [], 8161) == Err(TooLong)
