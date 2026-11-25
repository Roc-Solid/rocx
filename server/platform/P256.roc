import Host

## Elliptic-curve cryptography on P-256 (secp256r1, prime256v1), by the host (`ring`): what Web Push
## needs (packages/push): ECDH with a key pair made for one message (RFC 8291), and ES256
## signatures (its VAPID token, RFC 8292; any JWT signed with ES256). A public key is an
## uncompressed point, 65 bytes (4, then `x` and `y`), and a private key its 32-byte scalar, as
## browsers, Web Crypto's raw and JWK formats and `web-push generate-vapid-keys` write them (in
## base64url: `Base64.url_decode`).
P256 := [].{

	## ECDH with a key pair the host makes for this call alone and then forgets, as RFC 8291 wants
	## for each message: its public key (65 bytes, for the other side), and the 32-byte secret it
	## shares with `peer` (the shared point's `x`), which only the holder of `peer`'s private key can
	## compute too. `BadKey` unless `peer` is an uncompressed point on the curve.
	ecdh! : List(U8) => Try({ public_key : List(U8), secret : List(U8) }, [BadKey])
	ecdh! = |peer|
		match Host.p256_ecdh!(peer) {
			Ok(both) if both.len() == 97 => Ok({ public_key: both.take_first(65), secret: both.drop_first(65) })
			_ => Err(BadKey)
		}

	## ES256: the signature of `message` (ECDSA on P-256 over its SHA-256) by `private_key`, whose
	## public key is `public_key`: 64 bytes, `r` then `s`, as JWS writes it (not DER). Each is
	## different (ECDSA draws a random number), and each verifies. `BadKey` unless the two keys are
	## a pair.
	sign! : List(U8), List(U8), List(U8) => Try(List(U8), [BadKey])
	sign! = |private_key, public_key, message|
		match Host.p256_sign!(private_key, public_key, message) {
			Ok(signature) => Ok(signature)
			Err(_) => Err(BadKey)
		}
}
