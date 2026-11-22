import crypto.Base64
import crypto.Hmac

## The session cookie: who is signed in, and until when, signed with HMAC-SHA256 (packages/crypto),
## so nobody can make one up or change one. Plain Roc: the key and the clock are given to it, so the
## `expect`s below try every way a cookie can be wrong.
##
## A cookie is `<person>.<epoch>.<expires>.<signature>`: the person's id, the session epoch it was
## signed in (raised by "sign out everywhere", which so refuses every cookie signed before it), when
## it stops being good (milliseconds since 1970), and the signature of the three, in Base64 for URLs.
## Nothing in it is secret, and the server keeps no session at all: the signature is what makes it
## good.
Session := [].{

	## What a cookie says.
	Claim : { person : Str, epoch : U64, expires : U64 }

	## The cookie's name. `__Host-` would pin it to this host over HTTPS; a local run is HTTP.
	cookie : Str
	cookie = "acme_notes_session"

	## How long a session lasts: 30 days.
	lifetime_ms : U64
	lifetime_ms = 30 * 24 * 60 * 60 * 1000

	## A cookie for `claim`, signed with `key`.
	sign : List(U8), Session.Claim -> Str
	sign = |key, claim| {
		said = said_by(claim)
		"${said}.${Base64.url_encode(Hmac.sha256(key, said.to_utf8()))}"
	}

	## What a cookie says, if `key` signed it and it is still good at `now`. The signature is
	## compared in constant time (`Hmac.verify_sha256`), so how long a refusal takes tells a forger
	## nothing.
	verify : List(U8), Str, U64 -> Try(Session.Claim, [Malformed, Forged, Expired])
	verify = |key, value, now|
		match value.split_on(".") {
			[person, epoch_text, expires_text, signature] =>
				match (U64.from_str(epoch_text), U64.from_str(expires_text), Base64.url_decode(signature)) {
					(Ok(epoch), Ok(expires), Ok(signed)) if !person.is_empty() => {
						claim = { person, epoch, expires }
						if !Hmac.verify_sha256(key, said_by(claim).to_utf8(), signed) {
							Err(Forged)
						} else if expires <= now {
							Err(Expired)
						} else {
							Ok(claim)
						}
					}
					_ => Err(Malformed)
				}
			_ => Err(Malformed)
		}
}

## The part of a cookie that is signed.
said_by : Session.Claim -> Str
said_by = |claim| "${claim.person}.${claim.epoch.to_str()}.${claim.expires.to_str()}"

key = "a key only the server knows, 32+".to_utf8()

other_key = "another key, which signed nothing".to_utf8()

ada = { person: "7", epoch: 0, expires: 2_000 }

expect Session.verify(key, Session.sign(key, ada), 1_000) == Ok(ada)
# Past its time: refused, however well signed.
expect Session.verify(key, Session.sign(key, ada), 2_000) == Err(Expired)
# Signed with another key: forged.
expect Session.verify(other_key, Session.sign(key, ada), 1_000) == Err(Forged)
# Someone else's id, a later time or a newer epoch, with the old signature: forged.
expect {
	signature = Session.sign(key, ada).split_on(".").last() ?? ""
	Session.verify(key, "8.0.2000.${signature}", 1_000) == Err(Forged)
		and Session.verify(key, "7.0.9999999.${signature}", 1_000) == Err(Forged)
		and Session.verify(key, "7.1.2000.${signature}", 1_000) == Err(Forged)
}
# Not a cookie at all.
expect Session.verify(key, "", 1_000) == Err(Malformed)
expect Session.verify(key, "7.0.2000", 1_000) == Err(Malformed)
expect Session.verify(key, "7.x.2000.abc", 1_000) == Err(Malformed)
expect Session.verify(key, ".0.2000.abc", 1_000) == Err(Malformed)
expect Session.verify(key, "7.0.2000.not base64!", 1_000) == Err(Malformed)
