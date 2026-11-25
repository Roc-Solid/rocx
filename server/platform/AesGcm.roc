import Host

## AES-GCM, by the host (`ring`): bytes sealed under a key, so that only that key opens them and any
## change to them is seen (a token kept in the database, say). `seal!` and `open!` are AES-256-GCM
## under a 32-byte key: each seal draws a fresh random 12-byte nonce, and what it gives is the
## nonce, the ciphertext, then the 16-byte tag (Web Crypto's output with the nonce in front).
## `seal_with_nonce!` is for a protocol that derives its own nonce (Web Push's).
AesGcm := [].{

	## `plaintext`, sealed under `key`; `BadKey` unless the key is 32 bytes.
	seal! : List(U8), List(U8) => Try(List(U8), [BadKey])
	seal! = |key, plaintext|
		match Host.aes_gcm_seal!(key, plaintext) {
			Ok(sealed) => Ok(sealed)
			Err(_) => Err(BadKey)
		}

	## What `seal!` sealed. `Forged`: the nonce, the ciphertext or the tag was changed, or it wasn't
	## sealed under this key.
	open! : List(U8), List(U8) => Try(List(U8), [BadKey, Forged])
	open! = |key, sealed|
		match Host.aes_gcm_open!(key, sealed) {
			Ok(plaintext) => Ok(plaintext)
			Err("bad key") => Err(BadKey)
			Err(_) => Err(Forged)
		}

	## `plaintext`, sealed under `key` with the caller's 12-byte `nonce`, for a protocol that derives
	## its nonces (RFC 8188's `aes128gcm`, which Web Push writes): AES-128-GCM under a 16-byte key,
	## AES-256-GCM under a 32-byte one. It gives the ciphertext, then the 16-byte tag, with no nonce
	## in front. A nonce must never be used twice under one key, which gives the key away: use
	## `seal!`, which draws one, unless a protocol says otherwise. `BadKey`, `BadNonce`.
	seal_with_nonce! : List(U8), List(U8), List(U8) => Try(List(U8), [BadKey, BadNonce])
	seal_with_nonce! = |key, nonce, plaintext|
		match Host.aes_gcm_seal_with_nonce!(key, nonce, plaintext) {
			Ok(sealed) => Ok(sealed)
			Err("bad nonce") => Err(BadNonce)
			Err(_) => Err(BadKey)
		}
}
