import Base64Url
import Ece
import Kdf

## A push message's encryption (RFC 8291): only the browser that subscribed can read it, and the
## push service in between sees bytes. For each message the server makes a new ECDH key pair on
## P-256 (`as_public`, the application server's) and agrees a secret with the subscription's key
## (`ua_public`, the user agent's `p256dh`); that secret and the subscription's 16-byte `auth`
## secret give the input keying material (`input_keys`), from which, with a random salt, the content
## coding of RFC 8188 (`Ece`) derives the AES-128-GCM key and nonce. The message is one record:
## the data, a delimiter and padding, sealed, after a header that carries the salt and `as_public`.
##
## The ECDH and the AES are the host's (PROPOSALS.md); `prepare` is everything before them and
## `body` everything after, so a sender is:
##
## ```roc
## { public_key, shared } = P256.ecdh_ephemeral!(subscription.p256dh)?     # the host's (proposed)
## sealing = WebPush.prepare({ ua_public: subscription.p256dh, auth_secret: subscription.auth, as_public: public_key, ecdh_secret: shared, salt: Random.bytes!(16), data, padding: 0 })?
## body = WebPush.body(sealing, AesGcm.seal_with!(sealing.key, sealing.nonce, sealing.record)?)
## ```
WebPush := [].{

	## The most data a message holds: a push service takes 4096 bytes of body, and the header
	## (86), the delimiter (1) and the tag (16) take the rest.
	max_data : U64
	max_data = 3993

	## The record size every message's header says, so its one record always fits.
	record_size : U32
	record_size = 4096

	## "WebPush: info", a zero byte, the browser's public key, then the server's: the info that
	## combines the keys.
	key_info : List(U8), List(U8) -> List(U8)
	key_info = |ua_public, as_public| "WebPush: info".to_utf8().append(0).concat(ua_public).concat(as_public)

	## The 32 bytes of input keying material for the content coding: HKDF of the ECDH secret,
	## salted with the auth secret, with `key_info` as its info.
	input_keys : { ecdh_secret : List(U8), auth_secret : List(U8), ua_public : List(U8), as_public : List(U8) } -> List(U8)
	input_keys = |{ ecdh_secret, auth_secret, ua_public, as_public }|
		Kdf.hkdf(auth_secret, ecdh_secret, WebPush.key_info(ua_public, as_public), 32) ?? []

	## A message ready for AES-128-GCM: the header that goes before it, the key and the nonce to
	## seal with, and the record to seal (the data, the delimiter, `padding` zeros).
	Sealing : { header : List(U8), key : List(U8), nonce : List(U8), record : List(U8) }

	## Everything before the AES. `BadKeys` unless the subscription's key and the server's are
	## uncompressed P-256 points (65 bytes, the first 4), the auth secret is 16 bytes, the ECDH
	## secret 32 and the salt 16 (each message a new, random one); `TooLarge` when the data and
	## its padding are more than `max_data`.
	prepare : { ua_public : List(U8), auth_secret : List(U8), as_public : List(U8), ecdh_secret : List(U8), salt : List(U8), data : List(U8), padding : U64 } -> Try(Sealing, [BadKeys, TooLarge])
	prepare = |{ ua_public, auth_secret, as_public, ecdh_secret, salt, data, padding }| {
		if !(point(ua_public) and point(as_public) and auth_secret.len() == 16 and ecdh_secret.len() == 32 and salt.len() == 16) {
			return Err(BadKeys)
		}
		if data.len() + padding > WebPush.max_data {
			return Err(TooLarge)
		}
		{ key, nonce } = Ece.keys(WebPush.input_keys({ ecdh_secret, auth_secret, ua_public, as_public }), salt)
		Ok({
			header: Ece.header({ salt, record_size: WebPush.record_size, key_id: as_public }),
			key,
			nonce,
			record: Ece.pad(data, padding, Bool.True),
		})
	}

	## The message's body: the header, then the sealed record (its ciphertext and its tag).
	body : Sealing, List(U8) -> List(U8)
	body = |sealing, sealed| sealing.header.concat(sealed)
}

## Whether `key` is an uncompressed P-256 point, as far as its shape says.
point : List(U8) -> Bool
point = |key| key.len() == 65 and key.first() == Ok(4)

## RFC 8291, appendix A: its keys, salt and message, in base64url, as it gives them.
b64 : Str -> List(U8)
b64 = |text| Base64Url.decode(text) ?? []

ua_public_example : List(U8)
ua_public_example = b64("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")

as_public_example : List(U8)
as_public_example = b64("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")

example : { ua_public : List(U8), auth_secret : List(U8), as_public : List(U8), ecdh_secret : List(U8), salt : List(U8), data : List(U8), padding : U64 }
example = {
	ua_public: ua_public_example,
	auth_secret: b64("BTBZMqHH6r4Tts7J_aSIgg"),
	as_public: as_public_example,
	ecdh_secret: b64("kyrL1jIIOHEzg3sM2ZWRHDRB62YACZhhSlknJ672kSs"),
	salt: b64("DGv6ra1nlYgDCS1FRnbzlw"),
	data: "When I grow up, I want to be a watermelon".to_utf8(),
	padding: 0,
}

combining : { ecdh_secret : List(U8), auth_secret : List(U8), ua_public : List(U8), as_public : List(U8) }
combining = { ecdh_secret: example.ecdh_secret, auth_secret: example.auth_secret, ua_public: example.ua_public, as_public: example.as_public }

expect WebPush.key_info(ua_public_example, as_public_example) == b64("V2ViUHVzaDogaW5mbwAEJXGyvs3942BVGq8e0PTNNmwRzr5VX4m8t7GGpTM5FzFo7OLr4BhZe9MEebhuPI-OztV3ylkYfpJGmQ22ggCLDgT-M_SrDepxkU21WCP3O1SUj0EwbZIHMtu5pZpTKGSCIA5Zent7wmC6HCJ5mFgJkuk5cwAvMBKiiujwa7t45ewP")

# The key combining's PRK, then the IKM.
expect Kdf.extract(example.auth_secret, example.ecdh_secret) == b64("Snr3JMxaHVDXHWJn5wdC52WjpCtd2EIEGBykDcZW32k")
expect WebPush.input_keys(combining) == b64("S4lYMb_L0FxCeq0WhDx813KgSYqU26kOyzWUdsXYyrg")

# The content coding's PRK, its two infos, the CEK and the nonce.
expect Kdf.extract(example.salt, WebPush.input_keys(combining)) == b64("09_eUZGrsvxChDCGRCdkLiDXrReGOEVeSCdCcPBSJSc")
expect Ece.key_info == b64("Q29udGVudC1FbmNvZGluZzogYWVzMTI4Z2NtAA")
expect Ece.nonce_info == b64("Q29udGVudC1FbmNvZGluZzogbm9uY2UA")
expect
	match WebPush.prepare(example) {
		Ok(sealing) =>
			sealing.key
				== b64("oIhVW04MRdy2XN9CiKLxTg")
				and sealing.nonce
					== b64("4h_95klXJ5E_qnoN")
				and sealing.header
					== b64("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")
				and sealing.record
					== "When I grow up, I want to be a watermelon".to_utf8().append(2)
		Err(_) => Bool.False
	}

# The appendix's message is the header and the record sealed under that key and nonce (the 58 bytes
# here are AES-128-GCM's, from Node: the host's to make).
expect
	match WebPush.prepare(example) {
		Ok(sealing) =>
			WebPush.body(sealing, b64("8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ"))
				== b64("DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
		Err(_) => Bool.False
	}

# What it refuses.
expect WebPush.prepare({ ..example, ua_public: example.ua_public.drop_last(1) }) == Err(BadKeys)
expect WebPush.prepare({ ..example, as_public: example.as_public.set(0, 3) ?? [] }) == Err(BadKeys)
expect WebPush.prepare({ ..example, auth_secret: [1, 2, 3] }) == Err(BadKeys)
expect WebPush.prepare({ ..example, salt: [] }) == Err(BadKeys)
expect WebPush.prepare({ ..example, ecdh_secret: [] }) == Err(BadKeys)
expect WebPush.prepare({ ..example, data: List.repeat(1, 3993) }).is_ok()
expect WebPush.prepare({ ..example, data: List.repeat(1, 3994) }) == Err(TooLarge)
expect WebPush.prepare({ ..example, data: List.repeat(1, 3000), padding: 994 }) == Err(TooLarge)

# The largest message is exactly 4096 bytes once sealed: header, record, tag.
expect
	match WebPush.prepare({ ..example, data: List.repeat(1, 3000), padding: 993 }) {
		Ok(sealing) => sealing.header.len() + sealing.record.len() + Ece.tag_size == 4096
		Err(_) => Bool.False
	}
