import crypto.Base64

## VAPID (RFC 8292): how a push service knows a message comes from the server the browser
## subscribed with. The server has a P-256 key pair; the page subscribes with its public key; and
## each request carries a JWT signed with the private key (ES256), for the push service's origin
## (`aud`), expiring within a day (`exp`), naming who to contact (`sub`, a `mailto:` or `https:`
## URL), with the public key beside it:
##
##     Authorization: vapid t=<the JWT>, k=<the public key, base64url>
##
## The signature is the server platform's (`P256.sign!`, D-080): this builds what it signs
## (`signing_input`) and the header from the signature (`token`, `authorization`).
Vapid := [].{

	## The server's key pair and its contact: the public key an uncompressed P-256 point (65
	## bytes, the first 4), the private key its 32-byte scalar.
	Keys : { public_key : List(U8), private_key : List(U8), subject : Str }

	## The keys from the text an app keeps them as (`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
	## `VAPID_SUBJECT`): base64url keys, as `web-push generate-vapid-keys` and this package's
	## `vapid-keys.mjs` print them, and a `mailto:` or `https:` contact. Which part is wrong, when
	## one is.
	from_text : { public_key : Str, private_key : Str, subject : Str } -> Try(Keys, [BadPublicKey, BadPrivateKey, BadSubject])
	from_text = |{ public_key, private_key, subject }| {
		public = Base64.url_decode(public_key.trim()) ?? []
		private = Base64.url_decode(private_key.trim()) ?? []
		if !(public.len() == 65 and public.first() == Ok(4)) {
			Err(BadPublicKey)
		} else if private.len() != 32 or private.all(|each| each == 0) {
			Err(BadPrivateKey)
		} else if !Vapid.contact(subject.trim()) {
			Err(BadSubject)
		} else {
			Ok({ public_key: public, private_key: private, subject: subject.trim() })
		}
	}

	## Whether `subject` is a contact a push service takes: `mailto:` and an address, or an
	## `https:` URL.
	contact : Str -> Bool
	contact = |subject|
		if subject.starts_with("mailto:") {
			subject.contains("@") and !subject.contains(" ")
		} else {
			subject.starts_with("https://") and subject.to_utf8().len() > 8 and !subject.contains(" ")
		}

	## The origin of a subscription's endpoint, which the token is for: its scheme, host and port
	## (lower-cased, a default port left out), `https://fcm.googleapis.com` for
	## `https://fcm.googleapis.com/fcm/send/…`. `BadEndpoint` for one that isn't `https:` (or
	## `http:`, for a push service on this machine), or has no host, or has credentials in it.
	audience : Str -> Try(Str, [BadEndpoint])
	audience = |endpoint| {
		(scheme, rest, default_port) =
			if endpoint.starts_with("https://") {
				("https", endpoint.drop_prefix("https://"), ":443")
			} else if endpoint.starts_with("http://") {
				("http", endpoint.drop_prefix("http://"), ":80")
			} else {
				return Err(BadEndpoint)
			}
		bytes = rest.to_utf8()
		authority = Str.from_utf8_lossy(bytes.take_first(bytes.find_first_index(|each| each == '/' or each == '?' or each == '#') ?? bytes.len()))
		if authority.is_empty() or authority.starts_with(":") or authority.to_utf8().any(|each| each == '@' or each <= ' ' or each == '\\') {
			return Err(BadEndpoint)
		}
		host = authority.with_ascii_lowercased()
		Ok("${scheme}://${if (host.ends_with(default_port)) host.drop_suffix(default_port) else host}")
	}

	## What a token says: the push service's origin, when it expires (seconds since the epoch),
	## and who to contact.
	Claims : { aud : Str, exp : U64, sub : Str }

	## The claims for sending to `endpoint` at `now_ms` (milliseconds since the epoch): expiring in
	## 12 hours, half the most RFC 8292 allows.
	claims : Keys, Str, U64 -> Try(Claims, [BadEndpoint])
	claims = |keys, endpoint, now_ms| {
		aud = Vapid.audience(endpoint)?
		Ok({ aud, exp: now_ms // 1000 + 12 * 60 * 60, sub: keys.subject })
	}

	## The JWT's header: ES256, ECDSA on P-256 with SHA-256.
	header_json : Str
	header_json = "{\"typ\":\"JWT\",\"alg\":\"ES256\"}"

	## The JWT's claims, in RFC 8292's order.
	claims_json : Claims -> Str
	claims_json = |{ aud, exp, sub }| "{\"aud\":${Json.to_str(aud)},\"exp\":${exp.to_str()},\"sub\":${Json.to_str(sub)}}"

	## What is signed: the header and the claims, each base64url, a `.` between them.
	signing_input : Claims -> Str
	signing_input = |said| "${Base64.url_encode(Vapid.header_json.to_utf8())}.${Base64.url_encode(Vapid.claims_json(said).to_utf8())}"

	## The JWT: the signing input, a `.`, and the signature, which is ES256's 64 bytes (`r` then
	## `s`, 32 bytes each, as JWS writes them; not DER). `BadSignature` for another length.
	token : Str, List(U8) -> Try(Str, [BadSignature])
	token = |input, signature|
		if signature.len() == 64 {
			Ok("${input}.${Base64.url_encode(signature)}")
		} else {
			Err(BadSignature)
		}

	## The `Authorization` header's value for a token and the public key it is checked with.
	authorization : Str, List(U8) -> Str
	authorization = |jwt, public_key| "vapid t=${jwt}, k=${Base64.url_encode(public_key)}"
}

b64 : Str -> List(U8)
b64 = |text| Base64.url_decode(text) ?? []

# RFC 8292, section 2.4 and 3.1's example (its signature checks against its key: Node's crypto.verify).
rfc_claims : Vapid.Claims
rfc_claims = { aud: "https://push.example.net", exp: 1453523768, sub: "mailto:push@example.com" }

rfc_input : Str
rfc_input = "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9.eyJhdWQiOiJodHRwczovL3B1c2guZXhhbXBsZS5uZXQiLCJleHAiOjE0NTM1MjM3NjgsInN1YiI6Im1haWx0bzpwdXNoQGV4YW1wbGUuY29tIn0"

rfc_signature : List(U8)
rfc_signature = b64("i3CYb7t4xfxCDquptFOepC9GAu_HLGkMlMuCGSK2rpiUfnK9ojFwDXb1JrErtmysazNjjvW2L9OkSSHzvoD1oA")

rfc_public : List(U8)
rfc_public = b64("BA1Hxzyi1RUM1b5wjxsn7nGxAszw2u61m164i3MrAIxHF6YK5h4SDYic-dRuU_RCPCfA5aq9ojSwk5Y2EmClBPs")

expect Vapid.claims_json(rfc_claims) == "{\"aud\":\"https://push.example.net\",\"exp\":1453523768,\"sub\":\"mailto:push@example.com\"}"
expect Vapid.signing_input(rfc_claims) == rfc_input
expect
	Vapid.token(rfc_input, rfc_signature).map_ok(|jwt| Vapid.authorization(jwt, rfc_public))
		== Ok("vapid t=${rfc_input}.i3CYb7t4xfxCDquptFOepC9GAu_HLGkMlMuCGSK2rpiUfnK9ojFwDXb1JrErtmysazNjjvW2L9OkSSHzvoD1oA, k=BA1Hxzyi1RUM1b5wjxsn7nGxAszw2u61m164i3MrAIxHF6YK5h4SDYic-dRuU_RCPCfA5aq9ojSwk5Y2EmClBPs")
expect Vapid.token(rfc_input, rfc_signature.drop_last(1)) == Err(BadSignature)
expect Vapid.claims_json({ aud: "https://a", exp: 1, sub: "mailto:\"q\"@example.com" }) == "{\"aud\":\"https://a\",\"exp\":1,\"sub\":\"mailto:\\\"q\\\"@example.com\"}"

# The audience: the endpoint's origin.
expect Vapid.audience("https://fcm.googleapis.com/fcm/send/dE3x:APA91b") == Ok("https://fcm.googleapis.com")
expect Vapid.audience("https://updates.push.services.mozilla.com/wpush/v2/gAAAAABk") == Ok("https://updates.push.services.mozilla.com")
expect Vapid.audience("https://web.push.apple.com/QGuQyavXut0") == Ok("https://web.push.apple.com")
expect Vapid.audience("https://Push.Example.NET:443/a?b#c") == Ok("https://push.example.net")
expect Vapid.audience("https://push.example.net:8443/a") == Ok("https://push.example.net:8443")
expect Vapid.audience("https://push.example.net?x") == Ok("https://push.example.net")
expect Vapid.audience("http://localhost:9000/push/1") == Ok("http://localhost:9000")
expect Vapid.audience("http://localhost:80/push/1") == Ok("http://localhost")
expect Vapid.audience("ftp://push.example.net/a") == Err(BadEndpoint)
expect Vapid.audience("https:///a") == Err(BadEndpoint)
expect Vapid.audience("https://:443/a") == Err(BadEndpoint)
expect Vapid.audience("https://user@push.example.net/a") == Err(BadEndpoint)
expect Vapid.audience("https://push.example.net /a") == Err(BadEndpoint)

# Claims for a request: 12 hours on.
expect
	Vapid.claims({ public_key: rfc_public, private_key: List.repeat(1, 32), subject: "mailto:ops@example.com" }, "https://push.example.net/x", 1_700_000_000_123)
		== Ok({ aud: "https://push.example.net", exp: 1_700_043_200, sub: "mailto:ops@example.com" })

# Keys from text.
rfc_keys_text : { public_key : Str, private_key : Str, subject : Str }
rfc_keys_text = {
	public_key: "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
	private_key: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
	subject: "mailto:ops@example.com",
}

expect
	match Vapid.from_text(rfc_keys_text) {
		Ok(keys) => keys.public_key.len() == 65 and keys.private_key.len() == 32 and keys.subject == "mailto:ops@example.com"
		Err(_) => Bool.False
	}
expect Vapid.from_text({ ..rfc_keys_text, public_key: " ${rfc_keys_text.public_key}\n" }).is_ok()
expect Vapid.from_text({ ..rfc_keys_text, public_key: rfc_keys_text.private_key }) == Err(BadPublicKey)
expect Vapid.from_text({ ..rfc_keys_text, private_key: rfc_keys_text.public_key }) == Err(BadPrivateKey)
expect Vapid.from_text({ ..rfc_keys_text, private_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }) == Err(BadPrivateKey)
expect Vapid.from_text({ ..rfc_keys_text, private_key: "" }) == Err(BadPrivateKey)
expect Vapid.from_text({ ..rfc_keys_text, subject: "ops@example.com" }) == Err(BadSubject)
expect Vapid.from_text({ ..rfc_keys_text, subject: "https://example.com/contact" }).is_ok()
expect Vapid.from_text({ ..rfc_keys_text, subject: "http://example.com" }) == Err(BadSubject)
