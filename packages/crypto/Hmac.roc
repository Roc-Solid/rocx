import Hex
import Sha256

## HMAC-SHA256 (RFC 2104), in pure Roc on `Sha256`: no effect, so it runs anywhere, `expect`s
## included. Signs an app's links, and is under `Hkdf` and S3's signatures. Checked against
## every test case of RFC 4231.
Hmac := [].{

	## The 32-byte HMAC-SHA256 of `message` under `key`.
	sha256 : List(U8), List(U8) -> List(U8)
	sha256 = |key, message| {
		short_key = if (key.len() > Sha256.block_size) Sha256.hash(key) else key
		padded = short_key.concat(List.repeat(0, Sha256.block_size - short_key.len()))
		inner = Sha256.chunks([padded.map(|each| each.bitwise_xor(0x36)), message])
		Sha256.chunks([padded.map(|each| each.bitwise_xor(0x5c)), inner])
	}

	## Whether `signature` is `sha256(key, message)`, compared with `equal`.
	verify_sha256 : List(U8), List(U8), List(U8) -> Bool
	verify_sha256 = |key, message, signature| Hmac.equal(Hmac.sha256(key, message), signature)

	## Whether two byte lists are the same. Lists of the same length are compared to the end
	## whatever their first difference, so the time taken doesn't tell a forger how much of a
	## signature was right. (Lengths differ at once: a signature's length is no secret.)
	equal : List(U8), List(U8) -> Bool
	equal = |left, right| {
		if left.len() != right.len() {
			return Bool.False
		}
		var $difference = 0.U8
		var $at = 0
		while $at < left.len() {
			$difference = $difference.bitwise_or((left.get($at) ?? 0).bitwise_xor(right.get($at) ?? 0))
			$at = $at + 1
		}
		$difference == 0
	}
}

hex_of : Str -> List(U8)
hex_of = |text|
	match Hex.decode(text) {
		Ok(bytes) => bytes
		Err(_) => []
	}

# RFC 4231, section 4, test cases 1 to 7. Case 5's output is truncated to 128 bits; cases 6 and 7
# have a key longer than a block, hashed first.
expect Hex.encode(Hmac.sha256(List.repeat(0x0b, 20), "Hi There".to_utf8())) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
expect Hex.encode(Hmac.sha256("Jefe".to_utf8(), "what do ya want for nothing?".to_utf8())) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
expect Hex.encode(Hmac.sha256(List.repeat(0xaa, 20), List.repeat(0xdd, 50))) == "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
expect Hex.encode(Hmac.sha256(hex_of("0102030405060708090a0b0c0d0e0f10111213141516171819"), List.repeat(0xcd, 50))) == "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
expect Hex.encode(Hmac.sha256(List.repeat(0x0c, 20), "Test With Truncation".to_utf8()).take_first(16)) == "a3b6167473100ee06e0c796c2955552b"
expect Hex.encode(Hmac.sha256(List.repeat(0xaa, 131), "Test Using Larger Than Block-Size Key - Hash Key First".to_utf8())) == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
expect Hex.encode(Hmac.sha256(List.repeat(0xaa, 131), "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.".to_utf8())) == "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"

# Keys at the block's edge (64 bytes used as is, 65 hashed) and empty ones, as Python's hmac gives them.
expect Hex.encode(Hmac.sha256(List.repeat(0xaa, 64), "x".to_utf8())) == "ce3c639dcb9d8baae5d44c3b8b5e233faab4d1860e07489af5c84f213998bd79"
expect Hex.encode(Hmac.sha256(List.repeat(0xaa, 65), "x".to_utf8())) == "c2b9a0a013df029c7d812c5ac18388feef0194ee64fcc5f321d149c06137caa3"
expect Hex.encode(Hmac.sha256([], [])) == "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"
expect Hmac.sha256(List.repeat(0xaa, 131), "m".to_utf8()) == Hmac.sha256(Sha256.hash(List.repeat(0xaa, 131)), "m".to_utf8())

# Verifying, and comparing.
expect Hmac.verify_sha256("Jefe".to_utf8(), "hi".to_utf8(), Hmac.sha256("Jefe".to_utf8(), "hi".to_utf8()))
expect !Hmac.verify_sha256("Jefe".to_utf8(), "hi".to_utf8(), Hmac.sha256("Jeff".to_utf8(), "hi".to_utf8()))
expect !Hmac.verify_sha256("Jefe".to_utf8(), "hi".to_utf8(), Hmac.sha256("Jefe".to_utf8(), "ho".to_utf8()))
expect !Hmac.verify_sha256("Jefe".to_utf8(), "hi".to_utf8(), [])
expect !Hmac.verify_sha256("Jefe".to_utf8(), "hi".to_utf8(), Hmac.sha256("Jefe".to_utf8(), "hi".to_utf8()).take_first(16))
expect Hmac.equal([], [])
expect Hmac.equal([1, 2, 3], [1, 2, 3])
expect !Hmac.equal([1, 2, 3], [1, 2, 4])
expect !Hmac.equal([0, 2, 3], [1, 2, 3])
expect !Hmac.equal([1, 2, 3], [1, 2])
expect !Hmac.equal([1, 2], [1, 2, 3])
expect !Hmac.equal([0], [])
