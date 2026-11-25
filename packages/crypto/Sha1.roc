import Hex

## SHA-1 (FIPS 180-4), in pure Roc: what an authenticator app's codes are made with (TOTP, RFC
## 6238, is HMAC-SHA1 unless it says otherwise, and every app reads that), under `Hmac.sha1`.
## SHA-1 is broken for collisions, so never sign with it, name content by it or keep a token's
## digest in it (use `Sha256`); HMAC-SHA1, which is all TOTP needs, doesn't rest on collisions
## (RFC 6194, section 3.2).
Sha1 := [].{

	## The 20-byte digest of `bytes`.
	hash : List(U8) -> List(U8)
	hash = |bytes| {
		message = padded(bytes)
		var $state = initial
		var $at = 0
		while $at < message.len() {
			$state = compressed($state, message, $at)
			$at = $at + 64
		}
		var $out = List.with_capacity(20)
		for word in $state {
			$out = $out.append(word.shr_zf_wrap(24).to_u8_wrap()).append(word.shr_zf_wrap(16).to_u8_wrap()).append(word.shr_zf_wrap(8).to_u8_wrap()).append(word.to_u8_wrap())
		}
		$out
	}

	## The digest of `bytes` in 40 lowercase hex digits, as `sha1sum` writes it.
	hex : List(U8) -> Str
	hex = |bytes| Hex.encode(Sha1.hash(bytes))

	## The bytes SHA-1 works on at a time (HMAC pads its key to this).
	block_size : U64
	block_size = 64
}

## The five words a digest starts from (FIPS 180-4, 5.3.1).
initial : List(U32)
initial = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]

## `bytes`, then a 1 bit, zeros up to 56 bytes into the last block, and the length in bits as 8
## bytes, big-endian (5.1.1): a whole number of blocks.
padded : List(U8) -> List(U8)
padded = |bytes| {
	length = bytes.len()
	bits = length * 8
	var $out = bytes.append(0x80).concat(List.repeat(0, (119 - length % 64) % 64))
	var $shift = 56.U8
	while $shift > 0 {
		$out = $out.append(bits.shr_zf_wrap($shift).to_u8_wrap())
		$shift = $shift - 8
	}
	$out.append(bits.to_u8_wrap())
}

## The state after the 64-byte block of `message` at `at` (6.1.2).
compressed : List(U32), List(U8), U64 -> List(U32)
compressed = |state, message, at| {
	var $w = List.with_capacity(80)
	var $t = 0
	while $t < 16 {
		i = at + $t * 4
		$w = $w.append(byte(message, i).shl_wrap(24).bitwise_or(byte(message, i + 1).shl_wrap(16)).bitwise_or(byte(message, i + 2).shl_wrap(8)).bitwise_or(byte(message, i + 3)))
		$t = $t + 1
	}
	while $t < 80 {
		$w = $w.append(rotl(word($w, $t - 3).bitwise_xor(word($w, $t - 8)).bitwise_xor(word($w, $t - 14)).bitwise_xor(word($w, $t - 16)), 1))
		$t = $t + 1
	}
	var $a = word(state, 0)
	var $b = word(state, 1)
	var $c = word(state, 2)
	var $d = word(state, 3)
	var $e = word(state, 4)
	$t = 0
	while $t < 80 {
		mixed =
			if $t < 20 {
				$b.bitwise_and($c).bitwise_or($b.bitwise_not().bitwise_and($d)).plus_wrap(0x5A827999)
			} else if $t < 40 {
				$b.bitwise_xor($c).bitwise_xor($d).plus_wrap(0x6ED9EBA1)
			} else if $t < 60 {
				$b.bitwise_and($c).bitwise_or($b.bitwise_and($d)).bitwise_or($c.bitwise_and($d)).plus_wrap(0x8F1BBCDC)
			} else {
				$b.bitwise_xor($c).bitwise_xor($d).plus_wrap(0xCA62C1D6)
			}
		next = rotl($a, 5).plus_wrap(mixed).plus_wrap($e).plus_wrap(word($w, $t))
		$e = $d
		$d = $c
		$c = rotl($b, 30)
		$b = $a
		$a = next
		$t = $t + 1
	}
	[word(state, 0).plus_wrap($a), word(state, 1).plus_wrap($b), word(state, 2).plus_wrap($c), word(state, 3).plus_wrap($d), word(state, 4).plus_wrap($e)]
}

## `x` turned left by `n` bits.
rotl : U32, U8 -> U32
rotl = |x, n| x.shl_wrap(n).bitwise_or(x.shr_zf_wrap(32 - n))

## The byte at `at`, as a word.
byte : List(U8), U64 -> U32
byte = |bytes, at| (bytes.get(at) ?? 0).to_u32()

## The word at `at`.
word : List(U32), U64 -> U32
word = |words, at| words.get(at) ?? 0

# FIPS 180-4's examples (csrc.nist.gov, "Examples with intermediate values"): one block, two
# blocks, the 896-bit message, and a million a's. Also the empty message.
expect Sha1.hex("abc".to_utf8()) == "a9993e364706816aba3e25717850c26c9cd0d89d"
expect Sha1.hex([]) == "da39a3ee5e6b4b0d3255bfef95601890afd80709"
expect Sha1.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".to_utf8()) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
expect Sha1.hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".to_utf8()) == "a49b2446a02c645bf419f995b67091253a04a259"
expect Sha1.hex(List.repeat('a', 1000000)) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f"

# Lengths either side of the padding's edges (55/56 bytes, a block, two blocks), as `shasum -a 1`
# gives them.
expect Sha1.hex(List.repeat('a', 55)) == "c1c8bbdc22796e28c0e15163d20899b65621d65a"
expect Sha1.hex(List.repeat('a', 56)) == "c2db330f6083854c99d4b5bfb6e8f29f201be699"
expect Sha1.hex(List.repeat('a', 63)) == "03f09f5b158a7a8cdad920bddc29b81c18a551f5"
expect Sha1.hex(List.repeat('a', 64)) == "0098ba824b5c16427bd7a1122a5a442a25ec644d"
expect Sha1.hex(List.repeat('a', 65)) == "11655326c708d70319be2610e8a57d9a5b959d3b"
expect Sha1.hex(List.repeat('a', 119)) == "ee971065aaa017e0632a8ca6c77bb3bf8b1dfc56"
expect Sha1.hex(List.repeat('a', 120)) == "f34c1488385346a55709ba056ddd08280dd4c6d6"

# Bytes and hex agree.
expect Sha1.hash("abc".to_utf8()).len() == 20
expect Sha1.hash("abc".to_utf8()).first() == Ok(0xa9)
expect Sha1.hash("abc".to_utf8()).last() == Ok(0x9d)
