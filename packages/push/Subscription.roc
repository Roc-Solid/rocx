import Base64Url
import Vapid

## A browser's push subscription: where to send (`endpoint`, a URL at its push service) and its
## keys, decoded: `p256dh`, its P-256 public key (65 bytes, uncompressed), and `auth`, a 16-byte
## secret. The page sends it as `subscription.toJSON()` gives it:
##
##     {"endpoint":"https://fcm.googleapis.com/fcm/send/…","expirationTime":null,
##      "keys":{"p256dh":"BCVxsr7N…","auth":"BTBZMqHH…"}}
##
## Anyone can post one, so it is checked: an `https:` endpoint (or `http:` on this machine, for a
## push service in tests), and keys of the right sizes. `known_service` says whether the endpoint is
## at a browser's push service, which a server should insist on: it sends a request to whatever
## URL a subscription names.
Subscription := { endpoint : Str, p256dh : List(U8), auth : List(U8) }.{

	## Whether two are the same subscription.
	is_eq : Subscription, Subscription -> Bool
	is_eq = |left, right| left.endpoint == right.endpoint and left.p256dh == right.p256dh and left.auth == right.auth

	## The JSON the page posts, as a server function's or an endpoint's body reads it (other
	## fields, `expirationTime`, are ignored).
	Body : { endpoint : Str, keys : { p256dh : Str, auth : Str } }

	## A subscription from the page's JSON.
	parse : Str -> Try(Subscription, [InvalidJson(Str), BadEndpoint, BadP256dh, BadAuth])
	parse = |text| {
		body : Try(Subscription.Body, [InvalidJson(Str)])
		body = Json.parse(text)
		match body {
			Ok(given) =>
				match Subscription.from_body(given) {
					Ok(subscription) => Ok(subscription)
					Err(BadEndpoint) => Err(BadEndpoint)
					Err(BadP256dh) => Err(BadP256dh)
					Err(BadAuth) => Err(BadAuth)
				}
			Err(InvalidJson(why)) => Err(InvalidJson(why))
		}
	}

	## A subscription from the page's JSON, read already (an endpoint's body).
	from_body : Body -> Try(Subscription, [BadEndpoint, BadP256dh, BadAuth])
	from_body = |{ endpoint, keys }| Subscription.from_text({ endpoint, p256dh: keys.p256dh, auth: keys.auth })

	## A subscription from its three texts (a row of the subscriptions table).
	from_text : { endpoint : Str, p256dh : Str, auth : Str } -> Try(Subscription, [BadEndpoint, BadP256dh, BadAuth])
	from_text = |{ endpoint, p256dh, auth }| {
		key = Base64Url.decode(p256dh) ?? []
		secret = Base64Url.decode(auth) ?? []
		if !(endpoint_ok(endpoint)) {
			Err(BadEndpoint)
		} else if !(key.len() == 65 and key.first() == Ok(4)) {
			Err(BadP256dh)
		} else if secret.len() != 16 {
			Err(BadAuth)
		} else {
			Ok({ endpoint, p256dh: key, auth: secret })
		}
	}

	## Its keys as base64url text again, for the table or the page.
	to_text : Subscription -> { endpoint : Str, p256dh : Str, auth : Str }
	to_text = |subscription| { endpoint: subscription.endpoint, p256dh: Base64Url.encode(subscription.p256dh), auth: Base64Url.encode(subscription.auth) }

	## The page's JSON again.
	to_json : Subscription -> Str
	to_json = |subscription| {
		text = Subscription.to_text(subscription)
		"{\"endpoint\":${Json.to_str(text.endpoint)},\"keys\":{\"p256dh\":${Json.to_str(text.p256dh)},\"auth\":${Json.to_str(text.auth)}}}"
	}

	## The push services browsers subscribe at: Chrome's, Firefox's, Safari's and Edge's (a host,
	## or `.` and the end of one).
	services : List(Str)
	services = ["fcm.googleapis.com", "android.googleapis.com", "updates.push.services.mozilla.com", ".push.services.mozilla.com", "web.push.apple.com", ".push.apple.com", ".notify.windows.com"]

	## Whether its endpoint is at one of `services`, over `https:`.
	known_service : Subscription -> Bool
	known_service = |subscription|
		match Vapid.audience(subscription.endpoint) {
			Ok(origin) if origin.starts_with("https://") => {
				host = origin.drop_prefix("https://")
				Subscription.services.any(|service| if (service.starts_with(".")) host.ends_with(service) else host == service)
			}
			_ => Bool.False
		}
}

## An endpoint a server may send to: an `https:` URL with a host, or an `http:` one on this
## machine; 2048 bytes at most, with no spaces or control characters.
endpoint_ok : Str -> Bool
endpoint_ok = |endpoint| {
	bytes = endpoint.to_utf8()
	plain = bytes.len() <= 2048 and bytes.all(|each| each > ' ' and each != 127)
	match Vapid.audience(endpoint) {
		Ok(origin) => plain and (origin.starts_with("https://") or origin == "http://localhost" or origin.starts_with("http://localhost:") or origin == "http://127.0.0.1" or origin.starts_with("http://127.0.0.1:"))
		Err(_) => Bool.False
	}
}

## RFC 8291's user agent, subscribed at a push service.
example_json : Str
example_json = "{\"endpoint\":\"https://fcm.googleapis.com/fcm/send/dE3x:APA91b\",\"expirationTime\":null,\"keys\":{\"p256dh\":\"BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4\",\"auth\":\"BTBZMqHH6r4Tts7J_aSIgg\"}}"

example_text : { endpoint : Str, p256dh : Str, auth : Str }
example_text = { endpoint: "https://fcm.googleapis.com/fcm/send/dE3x:APA91b", p256dh: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4", auth: "BTBZMqHH6r4Tts7J_aSIgg" }

expect
	match Subscription.parse(example_json) {
		Ok(subscription) => subscription.endpoint == "https://fcm.googleapis.com/fcm/send/dE3x:APA91b" and subscription.p256dh.len() == 65 and subscription.auth.len() == 16
		Err(_) => Bool.False
	}

# There and back: text, JSON.
expect Subscription.from_text(example_text).map_ok(Subscription.to_text) == Ok(example_text)
expect Subscription.parse(example_json).map_ok(Subscription.to_json) == Ok("{\"endpoint\":\"https://fcm.googleapis.com/fcm/send/dE3x:APA91b\",\"keys\":{\"p256dh\":\"${example_text.p256dh}\",\"auth\":\"${example_text.auth}\"}}")
expect Subscription.parse(example_json).map_ok(Subscription.to_json).map_ok(Subscription.parse) == Ok(Subscription.parse(example_json))

# Padded keys, as some code writes them, are the same keys.
expect Subscription.from_text({ ..example_text, auth: "BTBZMqHH6r4Tts7J_aSIgg==" }) == Subscription.from_text(example_text)

# What isn't a subscription.
expect
	match Subscription.parse("{\"endpoint\":\"https://a.example\"}") {
		Err(InvalidJson(_)) => Bool.True
		_ => Bool.False
	}
expect
	match Subscription.parse("not json") {
		Err(InvalidJson(_)) => Bool.True
		_ => Bool.False
	}
expect Subscription.from_text({ ..example_text, endpoint: "http://fcm.googleapis.com/fcm/send/x" }) == Err(BadEndpoint)
expect Subscription.from_text({ ..example_text, endpoint: "javascript:alert(1)" }) == Err(BadEndpoint)
expect Subscription.from_text({ ..example_text, endpoint: "https://a.example/x y" }) == Err(BadEndpoint)
expect Subscription.from_text({ ..example_text, endpoint: "https://a.example/${Str.repeat("x", 2048)}" }) == Err(BadEndpoint)
expect Subscription.from_text({ ..example_text, endpoint: "http://localhost:9000/push/1" }).is_ok()
expect Subscription.from_text({ ..example_text, endpoint: "http://127.0.0.1/push/1" }).is_ok()
expect Subscription.from_text({ ..example_text, endpoint: "http://localhost.evil.example/push/1" }) == Err(BadEndpoint)
expect Subscription.from_text({ ..example_text, p256dh: example_text.auth }) == Err(BadP256dh)
expect Subscription.from_text({ ..example_text, p256dh: "B+V" }) == Err(BadP256dh)
expect Subscription.from_text({ ..example_text, auth: example_text.p256dh }) == Err(BadAuth)
expect Subscription.from_text({ ..example_text, auth: "" }) == Err(BadAuth)

# The browsers' push services, and others.
known : Str -> Bool
known = |endpoint|
	match Subscription.from_text({ ..example_text, endpoint }) {
		Ok(subscription) => subscription.known_service()
		Err(_) => Bool.False
	}

expect known("https://fcm.googleapis.com/fcm/send/abc")
expect known("https://updates.push.services.mozilla.com/wpush/v2/gAAA")
expect known("https://web.push.apple.com/QGuQyavXut0")
expect known("https://wns2-par02p.notify.windows.com/w/?token=BQYAAA")
expect !known("https://fcm.googleapis.com.evil.example/fcm/send/abc")
expect !known("https://evilnotify.windows.com/w")
expect !known("https://push.example.net/x")
expect !known("http://localhost:9000/push/1")
