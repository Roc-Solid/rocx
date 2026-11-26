import pf.Server
import crypto.Base32
import crypto.Base64
import crypto.Hkdf
import crypto.Hmac
import crypto.Sha256

## packages/auth's rules, plain Roc: no effect, so `expect`s check each. Where a sign-in may send
## the browser after (`path`), what a token looks like and how it is kept (`token`, `hash`), the
## cookies' names, an address as it is kept (`address`), the OAuth state cookie (`State`), the PKCE
## challenge, the URL that sends the browser to a provider, what an ID token or GitHub's answers
## say about who signed in, and two-factor sign-in's (recovery codes, the sealing key, how long a
## sign-in waits for its code). `Auth` puts the effects around them; `Totp` is the codes' own.
Rules := [].{

	## A path of this site to go to: `then` if it is one (`/notes/4?x=1`), else `home`; never another
	## site (`//elsewhere.example`, `/\elsewhere.example`, `https://…`), so a link or a provider's
	## answer can't send you off after you sign in. A control character anywhere (a tab, CR, LF, NUL,
	## DEL) makes it `home` too: a browser drops tabs and newlines from a URL as it reads one, so
	## `/<tab>/elsewhere.example` would be `//elsewhere.example` by the time it went there.
	path : Str, Str -> Str
	path = |then, home| if (then.starts_with("/") and !then.starts_with("//") and !then.contains("\\") and !then.to_utf8().any(|byte| byte < 0x20 or byte == 0x7f)) then else home

	## A new token from random bytes (32 of them): base64url, what goes in a cookie or a link.
	token : List(U8) -> Str
	token = |random| Base64.url_encode(random)

	## Whether `text` has a token's shape (base64url of 32 bytes), so that nothing else is looked up.
	is_token : Str -> Bool
	is_token = |text|
		match Base64.url_decode(text) {
			Ok(bytes) => bytes.len() == 32
			Err(_) => Bool.False
		}

	## How a token is kept: its SHA-256, base64url. A table of these signs no one in.
	hash : Str -> Str
	hash = |given| Base64.url_encode(Sha256.hash(given.to_utf8()))

	## Whether a session that ends at `expires` is kept for as long again when it is used at `now`:
	## once it is in its second half (`length`, a session's whole time), so a session in use goes on
	## and the table is written at most once a half, not at every request.
	renew : I64, I64, I64 -> Bool
	renew = |expires, now, length| expires - now <= length // 2

	## PKCE's S256 challenge for `verifier` (RFC 7636): base64url of its SHA-256.
	challenge : Str -> Str
	challenge = |verifier| Base64.url_encode(Sha256.hash(verifier.to_utf8()))

	## A cookie's name: with `__Host-` in front when the site is on HTTPS (`https`), so no other
	## site under the same domain can set or overwrite it; without, on plain HTTP (a local run),
	## where browsers refuse the prefix.
	cookie : Str, Bool -> Str
	cookie = |name, https| if (https) "__Host-${name}" else name

	## An email address as it is kept and compared: trimmed, lower-cased; `NotAnAddress` when it
	## has no `@` with something on each side, or has a space or a control character in it.
	address : Str -> Try(Str, [NotAnAddress])
	address = |given| {
		trimmed = given.trim().with_ascii_lowercased()
		parts = trimmed.split_on("@")
		bad = trimmed.to_utf8().any(|byte| byte <= ' ' or byte == 127)
		match parts {
			[local, domain] if !local.is_empty() and !domain.is_empty() and !bad => Ok(trimmed)
			_ => Err(NotAnAddress)
		}
	}

	## The value of `name` in a query string (`token=abc&then=%2F`), decoded; "" when it isn't there.
	query : Str, Str -> Str
	query = |text, name|
		match Server.form_fields(text).find_first(|field| field.name == name) {
			Ok(found) => found.value
			Err(_) => ""
		}

	## `base` with `params` as its query, each value encoded.
	url : Str, List((Str, Str)) -> Str
	url = |base, params| {
		encoded = params.map(|(name, value)| "${Server.encode_segment(name)}=${Server.encode_segment(value)}")
		joiner = if (base.contains("?")) "&" else "?"
		if (encoded.is_empty()) base else "${base}${joiner}${Str.join_with(encoded, "&")}"
	}

	## What the browser keeps while it is away at a provider (a cookie, ten minutes): which provider,
	## the state it must bring back, PKCE's verifier, the nonce the ID token must carry, and where to
	## go after.
	State : { provider : Str, state : Str, verifier : Str, nonce : Str, then : Str }

	## The state as the cookie's value: its parts joined by dots (each base64url, so none has one).
	state_value : Rules.State -> Str
	state_value = |kept| Str.join_with([kept.provider, kept.state, kept.verifier, kept.nonce, Base64.url_encode(kept.then.to_utf8())], ".")

	## The state a cookie's value holds, if it holds one.
	state_of : Str -> Try(Rules.State, [BadState])
	state_of = |value|
		match value.split_on(".") {
			[provider, state, verifier, nonce, then] =>
				match Base64.url_decode(then) {
					Ok(bytes) if !provider.is_empty() and Rules.is_token(state) and Rules.is_token(verifier) and Rules.is_token(nonce) => Ok({ provider: provider, state: state, verifier: verifier, nonce: nonce, then: Str.from_utf8_lossy(bytes) })
					_ => Err(BadState)
				}
			_ => Err(BadState)
		}

	## Whether the state a provider sent back is the one the browser kept, compared in constant time.
	same_state : Str, Str -> Bool
	same_state = |kept, given| Hmac.equal(kept.to_utf8(), given.to_utf8())

	## Where to send the browser to sign in at a provider: its authorization endpoint with the code
	## flow's parameters, PKCE's challenge, and, for OpenID Connect, the nonce; then the provider's
	## own (`params`: Google's `prompt=select_account`).
	authorize : { authorize_url : Str, client_id : Str, redirect_uri : Str, scopes : List(Str), state : Str, verifier : Str, nonce : Str, params : List((Str, Str)) } -> Str
	authorize = |asked|
		Rules.url(
			asked.authorize_url,
			[
				("response_type", "code"),
				("client_id", asked.client_id),
				("redirect_uri", asked.redirect_uri),
				("scope", Str.join_with(asked.scopes, " ")),
				("state", asked.state),
				("code_challenge", Rules.challenge(asked.verifier)),
				("code_challenge_method", "S256"),
				("nonce", asked.nonce),
			].concat(asked.params),
		)

	## Who signed in, as a provider says: their id there, their address if it is verified (else ""),
	## and their name (or "").
	Who : { subject : Str, email : Str, name : Str }

	## Who an ID token says signed in (OpenID Connect Core 1.0, 3.1.3.7), given the issuers it may
	## name (Google's tokens say either of two) and the client it must be for, the nonce the browser kept, and now (seconds). The token came straight
	## from the provider's token endpoint over TLS, which the spec accepts in place of checking its
	## signature; its issuer, audience, expiry and nonce are checked, and its address is taken only
	## when the provider says it is verified.
	claims : Str, { issuers : List(Str), client_id : Str, nonce : Str, now_s : I64 } -> Try(Rules.Who, Str)
	claims = |jwt, expected| {
		payload = payload_of(jwt)?
		core : Try({ iss : Str, sub : Str, exp : I64 }, _)
		core = Json.parse(payload)
		{ iss, sub, exp } = core.map_err(|_| "the ID token has no issuer, subject or expiry")?
		one : Try({ aud : Str }, _)
		one = Json.parse(payload)
		many : Try({ aud : List(Str) }, _)
		many = Json.parse(payload)
		audiences =
			match (one, many) {
				(Ok({ aud }), _) => [aud]
				(_, Ok({ aud })) => aud
				_ => []
			}
		nonce : Try({ nonce : Str }, _)
		nonce = Json.parse(payload)
		mail : Try({ email : Str, email_verified : Bool }, _)
		mail = Json.parse(payload)
		named : Try({ name : Str }, _)
		named = Json.parse(payload)
		if !expected.issuers.contains(iss) {
			Err("the ID token is from ${iss}, not ${Str.join_with(expected.issuers, " or ")}")
		} else if !audiences.contains(expected.client_id) {
			Err("the ID token isn't for this app")
		} else if exp <= expected.now_s {
			Err("the ID token has expired")
		} else if !(nonce.map_ok(|n| Rules.same_state(expected.nonce, n.nonce)) ?? Bool.False) {
			Err("the ID token's nonce isn't the one this browser was given")
		} else if sub.is_empty() {
			Err("the ID token names no one")
		} else {
			email =
				match mail {
					Ok({ email: given, email_verified: Bool.True }) => Rules.address(given) ?? ""
					_ => ""
				}
			Ok({ subject: sub, email: email, name: named.map_ok(|n| n.name) ?? "" })
		}
	}

	## Who GitHub's `GET /user` and `GET /user/emails` say signed in: their numeric id, their primary
	## verified address (else ""), their name (else their login).
	github : Str, Str -> Try(Rules.Who, Str)
	github = |user_json, emails_json| {
		user : Try({ id : I64, login : Str }, _)
		user = Json.parse(user_json)
		{ id, login } = user.map_err(|_| "GitHub's answer about the user has no id")?
		named : Try({ name : Str }, _)
		named = Json.parse(user_json)
		emails : Try(List({ email : Str, primary : Bool, verified : Bool }), _)
		emails = Json.parse(emails_json)
		email =
			match (emails ?? []).find_first(|each| each.primary and each.verified) {
				Ok(found) => Rules.address(found.email) ?? ""
				Err(_) => ""
			}
		name = named.map_ok(|n| n.name) ?? ""
		Ok({ subject: id.to_str(), email: email, name: if (name.is_empty()) login else name })
	}

	## The access token in a token endpoint's JSON answer (RFC 6749, 5.1), and the ID token beside
	## it, if any (OpenID Connect).
	tokens : Str -> Try({ access : Str, id : Str }, Str)
	tokens = |json| {
		access : Try({ access_token : Str }, _)
		access = Json.parse(json)
		id : Try({ id_token : Str }, _)
		id = Json.parse(json)
		refused : Try({ error : Str }, _)
		refused = Json.parse(json)
		match (access, refused) {
			(Ok({ access_token }), _) => Ok({ access: access_token, id: id.map_ok(|t| t.id_token) ?? "" })
			(_, Ok({ error })) => Err("the provider refused the code: ${error}")
			_ => Err("the provider's answer has no access token")
		}
	}

	## How long a sign-in waits for its second factor: ten minutes.
	code_ms : I64
	code_ms = 600_000

	## How many wrong codes a sign-in waiting for one may have: the fifth ends it. A user's
	## authenticator counts them too, across sign-ins and the pages that turn two-factor off or make
	## new recovery codes (`locked`).
	code_tries : I64
	code_tries = 5

	## How many wrong codes in a row a user may give, across sign-ins, before their codes are
	## refused for `code_lock_ms`: ten, two sign-ins' worth.
	lock_tries : I64
	lock_tries = 10

	## How long a user's codes are refused once they have given `lock_tries` wrong ones in a row: a
	## quarter of an hour after the last.
	code_lock_ms : I64
	code_lock_ms = 900_000

	## Whether a user's codes are refused now, given how many wrong ones they have given in a row
	## (`misses`, the last at `missed_at`): `lock_tries` of them, the last less than `code_lock_ms`
	## ago. Each wrong code after that starts the wait again, so a guesser who has a session of
	## theirs, or their first factor, gets one guess a quarter of an hour, not thousands a minute.
	locked : I64, I64, I64 -> Bool
	locked = |misses, missed_at, now| misses >= Rules.lock_tries and now - missed_at < Rules.code_lock_ms

	## `page`, going on to `then` after (`?then=`, left out when it is "" or "/"): the code page a
	## sign-in waiting for its code goes to.
	onward : Str, Str -> Str
	onward = |page, then| Rules.url(page, if (then.is_empty() or then == "/") [] else [("then", then)])

	## A code as typed, as it is compared: trimmed, without the spaces and dashes a person or an app
	## puts in it, lower-cased.
	typed : Str -> Str
	typed = |given| Str.from_utf8_lossy(given.trim().with_ascii_lowercased().to_utf8().drop_if(|byte| byte == ' ' or byte == '-'))

	## A recovery code from random bytes (10 of them): 16 letters of Base32, lower-cased, in groups of
	## four (`k7qx-m2pa-r4tz-b6wd`): 80 bits, so its SHA-256 alone keeps it.
	recovery_code : List(U8) -> Str
	recovery_code = |random| {
		letters = Base32.encode_unpadded(random.take_first(10)).with_ascii_lowercased().to_utf8()
		groups = [0, 4, 8, 12].map(|at| Str.from_utf8_lossy(letters.sublist({ start: at, len: 4 })))
		Str.join_with(groups, "-")
	}

	## Whether a code as typed (`typed`'s) has a recovery code's shape: 16 letters of Base32.
	is_recovery : Str -> Bool
	is_recovery = |typed_code|
		match Base32.decode(typed_code) {
			Ok(bytes) => bytes.len() == 10
			Err(_) => Bool.False
		}

	## The key that seals authenticators' secrets, from the app's secret (`APP_SECRET`): 32 bytes of
	## HKDF-SHA256 with this package's own `info`, so the app's secret can key other things too.
	sealing_key : Str -> List(U8)
	sealing_key = |secret| Hkdf.sha256(secret.to_utf8(), [], "roc solid packages/auth: two-factor secrets".to_utf8(), 32) ?? []

	## The secret a development server (`--dev`) seals with when the app gives none: never for
	## production, where the plugin won't start without one.
	dev_secret : Str
	dev_secret = "packages/auth: the development secret, under --dev only"

	## What is sealed of `user`'s authenticator: its secret, then their id, so a sealed secret moved
	## onto another user's row doesn't open as theirs.
	sealed_plain : List(U8), Str -> List(U8)
	sealed_plain = |secret, user| secret.concat(user.to_utf8())

	## The secret `sealed_plain` holds for `user`, if it is theirs.
	secret_of : List(U8), Str -> Try(List(U8), [NotTheirs])
	secret_of = |plain, user| {
		owner = user.to_utf8()
		if plain.len() > owner.len() and plain.take_last(owner.len()) == owner {
			Ok(plain.take_first(plain.len() - owner.len()))
		} else {
			Err(NotTheirs)
		}
	}

	## Where a sign-in that failed sends the browser: the app's sign-in page with why
	## (`?error=link|refused|provider|state|unavailable|attempts|locked|timeout` and, for `refused` and
	## `provider`, `&reason=`), whose address it was when it is known (`&email=`: `admit!` turned it
	## away), and where they were going (`&then=`); or the code page, after a wrong code
	## (`?error=code`).
	failed : Str, { code : Str, reason : Str, email : Str, then : Str } -> Str
	failed = |sign_in, why| {
		given = [("error", why.code), ("reason", why.reason), ("email", why.email)].keep_if(|(_, value)| !value.is_empty())
		Rules.url(sign_in, given.concat(if (why.then.is_empty() or why.then == "/") [] else [("then", why.then)]))
	}
}

## The JSON a JWT carries: its second part, base64url.
payload_of : Str -> Try(Str, Str)
payload_of = |jwt|
	match jwt.split_on(".") {
		[_, payload, _] =>
			match Base64.url_decode(payload) {
				Ok(bytes) => Ok(Str.from_utf8_lossy(bytes))
				Err(_) => Err("the ID token isn't base64url")
			}
		_ => Err("the ID token isn't a JWT")
	}

# ---- two-factor ----
expect Rules.onward("/sign-in/code", "/notes?x=1") == "/sign-in/code?then=%2Fnotes%3Fx%3D1"
expect Rules.onward("/sign-in/code", "/") == "/sign-in/code"
expect Rules.typed(" 123 456 ") == "123456"
expect Rules.typed("K7QX-M2PA-R4TZ-B6WD") == "k7qxm2par4tzb6wd"
expect Rules.recovery_code(List.repeat(0, 10)) == "aaaa-aaaa-aaaa-aaaa"
expect Rules.recovery_code([0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0]) == "7777-7777-aaaa-aaaa"
expect Rules.is_recovery(Rules.typed(Rules.recovery_code(List.repeat(0xa5, 10))))
expect !Rules.is_recovery("123456")
expect !Rules.is_recovery("k7qxm2par4tzb6w")
expect !Rules.is_recovery("k7qxm2par4tzb6w1")
expect Rules.sealing_key("a secret of the app's, 32 characters or more").len() == 32
expect Rules.sealing_key("one") != Rules.sealing_key("two")
expect Rules.secret_of(Rules.sealed_plain([1, 2, 3], "user-1"), "user-1") == Ok([1, 2, 3])
expect Rules.secret_of(Rules.sealed_plain([1, 2, 3], "user-1"), "user-2") == Err(NotTheirs)
expect Rules.secret_of("user-1".to_utf8(), "user-1") == Err(NotTheirs)

# ---- wrong codes in a row ----
expect !Rules.locked(0, 0, 1_000_000)
expect !Rules.locked(9, 1_000_000, 1_000_000)
expect Rules.locked(10, 1_000_000, 1_000_000)
expect Rules.locked(14, 1_000_000, 1_000_000 + Rules.code_lock_ms - 1)
expect !Rules.locked(10, 1_000_000, 1_000_000 + Rules.code_lock_ms)

# ---- path ----
expect Rules.path("/notes/4?x=1", "/") == "/notes/4?x=1"
expect Rules.path("//elsewhere.example/", "/") == "/"
expect Rules.path("https://elsewhere.example/", "/home") == "/home"
expect Rules.path("/\\elsewhere.example", "/") == "/"
expect Rules.path("/a\r\nSet-Cookie: x", "/") == "/"
expect Rules.path("/\t/elsewhere.example", "/") == "/"
expect Rules.path("/\t\t/elsewhere.example", "/home") == "/home"
expect Rules.path("/a\u(0)b", "/") == "/"
expect Rules.path("/a\u(7f)b", "/") == "/"
expect Rules.path("/notes/a b", "/") == "/notes/a b"
expect Rules.path("", "/") == "/"

# ---- tokens ----
expect Rules.is_token(Rules.token(List.repeat(7, 32)))
expect !Rules.is_token(Rules.token(List.repeat(7, 31)))
expect !Rules.is_token("not a token")
expect Rules.hash("a") != Rules.hash("b") and Rules.hash("a").to_utf8().len() == 43
expect !Rules.renew(1000, 0, 1000)
expect !Rules.renew(1000, 499, 1000)
expect Rules.renew(1000, 500, 1000)
expect Rules.renew(1000, 999, 1000)
# RFC 7636, appendix B.
expect Rules.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

# ---- cookies, addresses, queries, URLs ----
expect Rules.cookie("session", Bool.True) == "__Host-session"
expect Rules.cookie("session", Bool.False) == "session"
expect Rules.address("  Ada@Example.COM ") == Ok("ada@example.com")
expect Rules.address("ada") == Err(NotAnAddress)
expect Rules.address("a@b@c") == Err(NotAnAddress)
expect Rules.address("a b@c") == Err(NotAnAddress)
expect Rules.address("@c") == Err(NotAnAddress)
expect Rules.query("token=abc&then=%2Fnotes%2F4", "then") == "/notes/4"
expect Rules.query("token=abc", "then") == ""
expect Rules.url("https://p/auth", [("a", "x y"), ("b", "/&=")]) == "https://p/auth?a=x%20y&b=%2F%26%3D"
expect Rules.url("/sign-in?x=1", [("error", "link")]) == "/sign-in?x=1&error=link"
expect Rules.url("/sign-in", []) == "/sign-in"
expect Rules.failed("/sign-in", { code: "link", reason: "", email: "", then: "/" }) == "/sign-in?error=link"
expect Rules.failed("/sign-in", { code: "refused", reason: "Not on the list", email: "a@b.c", then: "/notes" }) == "/sign-in?error=refused&reason=Not%20on%20the%20list&email=a%40b.c&then=%2Fnotes"

# ---- state ----
expect {
	random = Rules.token(List.repeat(1, 32))
	kept = { provider: "google", state: random, verifier: random, nonce: random, then: "/notes/4?x=1" }
	Rules.state_of(Rules.state_value(kept)) == Ok(kept)
}
expect Rules.state_of("google.x.y.z.w") == Err(BadState)
expect Rules.state_of("nonsense") == Err(BadState)
expect Rules.same_state("abc", "abc") and !Rules.same_state("abc", "abd")
expect {
	random = Rules.token(List.repeat(1, 32))
	url = Rules.authorize({ authorize_url: "https://p/authorize", client_id: "id", redirect_uri: "https://app/auth/p/callback", scopes: ["openid", "email"], state: random, verifier: "v", nonce: "n", params: [("prompt", "select_account")] })
	url.starts_with("https://p/authorize?response_type=code&client_id=id&redirect_uri=https%3A%2F%2Fapp%2Fauth%2Fp%2Fcallback&scope=openid%20email&state=") and url.ends_with("&code_challenge=${Rules.challenge("v")}&code_challenge_method=S256&nonce=n&prompt=select_account")
}

# ---- ID tokens ----
encode : Str -> Str
encode = |json| Base64.url_encode(json.to_utf8())

## An ID token with good claims, each in `changed` (a name and its JSON) in place of its own.
id_token : List((Str, Str)) -> Str
id_token = |changed| {
	base = [("iss", "\"https://issuer\""), ("aud", "\"client\""), ("exp", "2000"), ("sub", "\"123\""), ("nonce", "\"n1\""), ("email", "\"Ada@Example.com\""), ("email_verified", "true"), ("name", "\"Ada\"")]
	fields = base.map(|(name, json)| (name, changed.find_first(|(n, _)| n == name).map_ok(|(_, j)| j) ?? json))
	body = Str.join_with(fields.map(|(name, json)| "\"${name}\":${json}"), ",")
	"${encode("{\"alg\":\"RS256\"}")}.${encode("{${body}}")}.signature"
}

expected = { issuers: ["https://issuer"], client_id: "client", nonce: "n1", now_s: 1000 }

expect Rules.claims(id_token([]), expected) == Ok({ subject: "123", email: "ada@example.com", name: "Ada" })
expect Rules.claims(id_token([("aud", "[\"other\",\"client\"]")]), expected) == Ok({ subject: "123", email: "ada@example.com", name: "Ada" })
expect Rules.claims(id_token([("email_verified", "false")]), expected) == Ok({ subject: "123", email: "", name: "Ada" })
expect Rules.claims(id_token([("aud", "\"other\"")]), expected).is_err()
expect Rules.claims(id_token([("iss", "\"https://evil\"")]), expected).is_err()
expect Rules.claims(id_token([("exp", "999")]), expected).is_err()
expect Rules.claims(id_token([("nonce", "\"n2\"")]), expected).is_err()
expect Rules.claims("nonsense", expected).is_err()

# ---- GitHub, token answers ----
expect Rules.github("{\"id\":42,\"login\":\"ada\",\"name\":\"Ada L\"}", "[{\"email\":\"old@x.io\",\"primary\":false,\"verified\":true},{\"email\":\"Ada@X.io\",\"primary\":true,\"verified\":true}]") == Ok({ subject: "42", email: "ada@x.io", name: "Ada L" })
expect Rules.github("{\"id\":42,\"login\":\"ada\",\"name\":null}", "[{\"email\":\"ada@x.io\",\"primary\":true,\"verified\":false}]") == Ok({ subject: "42", email: "", name: "ada" })
expect Rules.github("{\"login\":\"ada\"}", "[]").is_err()
expect Rules.tokens("{\"access_token\":\"a\",\"id_token\":\"i\",\"token_type\":\"bearer\"}") == Ok({ access: "a", id: "i" })
expect Rules.tokens("{\"access_token\":\"a\"}") == Ok({ access: "a", id: "" })
expect Rules.tokens("{\"error\":\"bad_verification_code\"}") == Err("the provider refused the code: bad_verification_code")
