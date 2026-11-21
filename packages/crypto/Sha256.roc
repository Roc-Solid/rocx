## SHA-256 (FIPS 180-4), on Roc's builtin `Crypto.SHA256`: the digest an app keeps of a token (a
## session's, an invite's) instead of the token, and the hash under `Hmac`, `Hkdf` and S3's
## signatures. One place for the two shapes callers want (bytes and hex), and one place to change
## if the builtin moves.
Sha256 := [].{

	## The 32-byte digest of `bytes`.
	hash : List(U8) -> List(U8)
	hash = |bytes| Crypto.SHA256.hash(bytes).to_bytes()

	## The digest of `bytes` in 64 lowercase hex digits, as SigV4 and `sha256sum` write it.
	hex : List(U8) -> Str
	hex = |bytes| Crypto.SHA256.hash(bytes).to_hex()

	## The digest of the pieces one after another, without joining them first.
	chunks : List(List(U8)) -> List(U8)
	chunks = |pieces| {
		var $hasher = Crypto.SHA256.Hasher.empty()
		for piece in pieces {
			$hasher = $hasher.write(piece)
		}
		$hasher.finish().to_bytes()
	}

	## The bytes SHA-256 works on at a time (HMAC pads its key to this).
	block_size : U64
	block_size = 64
}

# NIST's examples (FIPS 180-4; csrc.nist.gov "Examples with intermediate values"): one block, two
# blocks, the 896-bit message, and a million a's. Also the empty message.
expect Sha256.hex("abc".to_utf8()) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
expect Sha256.hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
expect Sha256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".to_utf8()) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
expect Sha256.hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".to_utf8()) == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
expect Sha256.hex(List.repeat('a', 1000000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

# Lengths either side of the padding's edges (55/56 bytes, a block, two blocks), as `shasum -a 256`
# gives them.
expect Sha256.hex(List.repeat('a', 55)) == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
expect Sha256.hex(List.repeat('a', 56)) == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
expect Sha256.hex(List.repeat('a', 63)) == "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"
expect Sha256.hex(List.repeat('a', 64)) == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
expect Sha256.hex(List.repeat('a', 65)) == "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"
expect Sha256.hex(List.repeat('a', 119)) == "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb"
expect Sha256.hex(List.repeat('a', 120)) == "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c"

# Bytes and hex agree; pieces hash as the whole.
expect Sha256.hash("abc".to_utf8()).len() == 32
expect Sha256.hash("abc".to_utf8()) == Crypto.SHA256.hash("abc".to_utf8()).to_bytes()
expect Sha256.hash("abc".to_utf8()).first() == Ok(0xba)
expect Sha256.hash("abc".to_utf8()).last() == Ok(0xad)
expect Sha256.chunks(["ab".to_utf8(), [], "c".to_utf8()]) == Sha256.hash("abc".to_utf8())
expect Sha256.chunks([]) == Sha256.hash([])
expect Sha256.chunks([List.repeat('a', 63), List.repeat('a', 2), List.repeat('a', 55)]) == Sha256.hash(List.repeat('a', 120))
