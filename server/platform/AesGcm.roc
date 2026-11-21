import Host

## AES-256-GCM, by the host (`ring`): bytes sealed under a 32-byte key, so that only that key opens
## them and any change to them is seen (a token kept in the database, say). Each seal draws a fresh
## random 12-byte nonce; what it gives is the nonce, the ciphertext, then the 16-byte tag: Web
## Crypto's output with the nonce in front.
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
}
