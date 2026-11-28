import crypto.Base64
import pf.AesGcm
import pf.Endpoint
import pf.Env
import pf.Http
import pf.Kv
import pf.Log
import pf.P256
import pf.Plugin
import pf.Random
import pf.Server
import pf.Time
import jobs.Job
import Delivery
import Notification
import Options
import PushStore
import Subscription
import Vapid
import WebPush
import "migrations/0001_push_subscriptions.sql" as table : Str
import "migrations/0001_push_subscriptions_sqlite.sql" as lite_table : Str
import "static/push-sw.js" as worker : List(U8)
import "static/push.js" as script : List(U8)

## Web Push from the server, as a plugin (`Push.plugin`): subscriptions saved as pages post them
## (the app's routes for them, `subscribe_route!`), notifications queued as jobs (`notify!`, `broadcast!`),
## one per subscription, and sent by the jobs plugin's workers (`deliver`): encrypted for the
## browser (RFC 8291), signed for its push service (VAPID, RFC 8292), posted (RFC 8030), and sent
## again later if the push service is busy or down, until the message's TTL runs out. A subscription
## the push service says is gone is deleted. Server-only: it imports the server platform's `Http`,
## `Plugin` and `Env`, and packages/jobs's `Job`.
##
## ```roc
## plugins: [Job.plugin({ jobs: App.jobs }), Push.plugin({})]
## ```
##
## Its endpoints are the app's routes (D-116), where `<PushButton api="/push">` looks, each calling
## its handler, behind the middleware of the folder it is in:
##
## ```roc
## # routes/push/key/+server.roc: GET, the public key
## respond! = |{ request, .. }| Push.key_route!(request)
## # routes/push/subscribe/+server.roc: POST; whose: "" for a visitor, or the app's id for the user
## # its folder's middleware handed on (`context.member`)
## respond! = |{ request, .. }| Push.subscribe_route!(request, "")
## # routes/push/unsubscribe/+server.roc: POST
## respond! = |{ request, .. }| Push.unsubscribe_route!(request, "")
## ```
##
## The keys come from the environment: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` (a P-256 pair in
## base64url) and `VAPID_SUBJECT` (`mailto:` or `https:`). Under `--dev` the plugin makes a pair
## when neither key is set, for that run alone (`keys!`), and logs the lines that keep it in `.env`;
## there `GET /__rocx/push/keys` answers a new pair each time, for a deployed server's environment.
## Elsewhere a key missing, keys that aren't a pair, or no contact stop the server at start, saying
## why.
##
## The elliptic curves are the server platform's (`P256`: the ECDH that encrypts, the ES256
## signature VAPID wants), and so is the AES (`AesGcm.seal_with_nonce!`, AES-128-GCM): D-080.
Push := [].{

	## The public key, `GET <api>/key` (`routes/push/key/+server.roc`, D-116), which a page subscribes
	## with. 405 for a method but GET.
	key_route! : Server.Request => Server.Response
	key_route! = |request| taking!(request, ["GET"], |{}| key!({}))

	## A subscription a page posts, `POST <api>/subscribe` (`routes/push/subscribe/+server.roc`),
	## kept as `owner`'s: the app's id for the user (what the folder's middleware handed on, say), or
	## "" for a visitor. 405 for a method but POST.
	subscribe_route! : Server.Request, Str => Server.Response
	subscribe_route! = |request, owner| taking!(request, ["POST"], |{}| subscribed!(request, owner))

	## A subscription a page drops, `POST <api>/unsubscribe` (`routes/push/unsubscribe/+server.roc`),
	## if it is `owner`'s. 405 for a method but POST.
	unsubscribe_route! : Server.Request, Str => Server.Response
	unsubscribe_route! = |request, owner| taking!(request, ["POST"], |{}| unsubscribed!(request, owner))

	## The push plugin: the service worker at the
	## site's root (`/push-sw.js`, so its scope is the whole site) and the page's script
	## (`/rocx/plugins/push/push.js`, which every page loads: the `push.subscribe` and
	## `push.unsubscribe` effects `<PushButton>` calls), both served before the app and its
	## middleware; its table (`push/0001_push_subscriptions`, on Postgres or SQLite); and its job,
	## `push.deliver`, which the jobs plugin's workers run. It needs the jobs plugin, a database and
	## the VAPID keys; its start checks the keys (or, under `--dev` without them, makes a pair), and
	## under `--dev`, `GET /__rocx/push/keys` answers a new pair (`new_keys!`).
	plugin : {} -> Plugin.Value(context)
	plugin = |{}| {
		{
			name: "push",
			early: [{ method: "GET", path: "/__rocx/push/keys", under: [Dev], answer!: |_| new_keys!({}) }],
			files: [
				{ path: "push-sw.js", at: Root, content_type: "text/javascript", body: worker },
				{ path: "push.js", at: Plugin, content_type: "text/javascript", body: script },
			],
			scripts: ["push.js"],
			migrations: [{ name: "0001_push_subscriptions", sql: table, on: Postgres }, { name: "0001_push_subscriptions", sql: lite_table, on: Sqlite }],
			calls: [Job.call(Push.deliver)],
			starts: [|_context| started!({})],
			needs: [Plugin("jobs"), Database],
		}
	}

	## The server's VAPID keys, from its environment (`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
	## `VAPID_SUBJECT`); or what is wrong with them, and how to make a pair. Under `--dev`, with
	## neither key set, the pair this run made, kept in the server's memory (`Kv`) until it stops,
	## so a restart makes another, and every browser subscribed with this one must subscribe again
	## (the log says so, with the lines that keep it in `.env`); and with no `VAPID_SUBJECT`,
	## `mailto:dev@example.com`.
	keys! : {} => Try(Vapid.Keys, Str)
	keys! = |{}| {
		dev = Env.dev!({})
		given = { public_key: setting!("VAPID_PUBLIC_KEY"), private_key: setting!("VAPID_PRIVATE_KEY"), subject: setting!("VAPID_SUBJECT") }
		subject = if (given.subject.is_empty() and dev) dev_subject else given.subject
		text =
			if given.public_key.is_empty() and given.private_key.is_empty() {
				if dev {
					pair = dev_pair!({})
					{ public_key: pair.public_key, private_key: pair.private_key, subject: subject }
				} else {
					return Err("VAPID_PUBLIC_KEY and VAPID_PRIVATE_KEY aren't set, and push needs a pair (and VAPID_SUBJECT, a mailto: or https: contact): ${making}")
				}
			} else {
				{ ..given, subject: subject }
			}
		match Vapid.from_text(text) {
			Ok(keys) => Ok(keys)
			Err(BadPublicKey) => Err("VAPID_PUBLIC_KEY isn't a P-256 public key in base64url (65 bytes, uncompressed): ${making}")
			Err(BadPrivateKey) => Err("VAPID_PRIVATE_KEY isn't a P-256 private key in base64url (32 bytes): ${making}")
			Err(BadSubject) => Err("VAPID_SUBJECT isn't a contact: write mailto: and an address, or an https: URL")
		}
	}

	## The public key in base64url, for the page to subscribe with (`applicationServerKey`); ""
	## when the server has no keys.
	public_key! : {} => Str
	public_key! = |{}|
		match Push.keys!({}) {
			Ok(keys) => Base64.url_encode(keys.public_key)
			Err(_) => ""
		}

	## Saves the subscription a page posted (an endpoint's body), for `owner` (the app's id for a
	## user, or "" for a visitor). It must be at a browser's push service
	## (`Subscription.known_service`), or, under `--dev`, at one on this machine, and its key a
	## point on P-256 (an ECDH with it is tried); `Invalid` says why not.
	subscribe! : Subscription.Body, Str => Try({}, [Invalid(Str), DbErr(Str)])
	subscribe! = |body, owner|
		match Subscription.from_body(body) {
			Ok(subscription) =>
				if !(subscription.known_service() or (Env.dev!({}) and !subscription.endpoint.starts_with("https://"))) {
					Err(Invalid("the endpoint isn't at a browser's push service"))
				} else if P256.ecdh!(subscription.p256dh).is_err() {
					Err(Invalid("keys.p256dh isn't a point on P-256"))
				} else {
					PushStore.save!(subscription, owner)
				}
			Err(BadEndpoint) => Err(Invalid("the endpoint isn't an https: URL"))
			Err(BadP256dh) => Err(Invalid("keys.p256dh isn't a P-256 public key in base64url"))
			Err(BadAuth) => Err(Invalid("keys.auth isn't 16 bytes in base64url"))
		}

	## Forgets `owner`'s subscription at `endpoint` (the page unsubscribed).
	unsubscribe! : Str, Str => Try({}, [DbErr(Str)])
	unsubscribe! = |endpoint, owner| PushStore.remove!(endpoint, owner).map_ok(|_| {})

	## Queues `notification` for each of `owner`'s subscriptions: how many. In a transaction
	## (`Db.transaction!`), they are queued only if it commits.
	notify! : Str, Notification, Options => Try(U64, Str)
	notify! = |owner, notification, options|
		match PushStore.of_owner!(owner) {
			Ok(ids) => queue_each!(ids, Notification.to_json(notification), options)
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
		}

	## Queues `notification` for every subscription: how many.
	broadcast! : Notification, Options => Try(U64, Str)
	broadcast! = |notification, options|
		match PushStore.everyone!({}) {
			Ok(ids) => queue_each!(ids, Notification.to_json(notification), options)
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
		}

	## A message for one subscription, as the job keeps it: the data (the notification's JSON), the
	## options (`urgency` as RFC 8030 writes it), when it was first queued, and how many times a
	## push service has said to come back later.
	Input : { subscription : I64, data : Str, ttl : U64, urgency : Str, topic : Str, queued_ms : U64, later : U64 }

	## The job that delivers a message to a subscription. A push service that is down, or answers
	## 5xx, or a request that fails, fails the attempt, and the worker tries again, waiting longer
	## each time (five attempts). One that says when to come back (`Retry-After`) gets a new job
	## then, five times at most. A message whose TTL has run out is dropped; a subscription that is
	## gone is deleted; a refusal (a bad VAPID key, a message too large) is logged and noted on the
	## subscription, not tried again.
	deliver : Job.Kind(_, Input)
	deliver = Job.define_with("push.deliver", { attempts: 5, timeout_ms: 60_000 }, |_context, input| deliver!(input))

	## One attempt at sending `data` (empty: a push with no data, which the service worker shows as
	## a notification with no text) to `subscription`, with `options`: what the push service's
	## answer means, or why no request was sent. The data is encrypted for the subscription's
	## browser (RFC 8291: a new ECDH key pair and a new salt each time, one record of `aes128gcm`),
	## and the request carries a VAPID token for the endpoint's origin, signed with `keys` (RFC 8292).
	send! : Vapid.Keys, Subscription, List(U8), Options => Try(Delivery.Outcome, Str)
	send! = |keys, subscription, data, options| {
		now = Time.now_millis!({})
		claims =
			match Vapid.claims(keys, subscription.endpoint, now) {
				Ok(said) => said
				Err(BadEndpoint) => return Err("the subscription's endpoint isn't a URL: ${subscription.endpoint}")
			}
		input = Vapid.signing_input(claims)
		signature =
			match P256.sign!(keys.private_key, keys.public_key, input.to_utf8()) {
				Ok(signed) => signed
				Err(BadKey) => return Err(not_a_pair)
			}
		jwt =
			match Vapid.token(input, signature) {
				Ok(made) => made
				Err(BadSignature) => return Err("the host's ES256 signature isn't 64 bytes")
			}
		body = if (data.is_empty()) [] else encrypted!(subscription, data)?
		request = Delivery.request({ endpoint: subscription.endpoint, authorization: Vapid.authorization(jwt, keys.public_key), body, options })
		match Http.fetch!(request.url, { method: Post, headers: request.headers, body: Http.bytes(request.body), timeout_ms: 30_000, max_bytes: 65_536, redirect: Manual }) {
			Ok(res) => Ok(Delivery.outcome({ status: res.status, headers: res.headers, body: res.body }, Time.now_millis!({})))
			Err(TimedOut) => Ok(Retry("the push service didn't answer within 30 seconds"))
			Err(TooLarge) => Ok(Retry("the push service's answer was too large to read"))
			Err(HttpErr(why)) => Ok(Retry("couldn't reach the push service: ${why}"))
		}
	}
}

## `answer!` for a request whose method is one of `methods` (GET takes HEAD too), else 405.
taking! : Server.Request, List(Str), ({} => Server.Response) => Server.Response
taking! = |request, methods, answer!| {
	asked = if (request.method == "HEAD") "GET" else request.method
	if (methods.contains(asked)) answer!({}) else Endpoint.not_allowed(request, methods)
}

## The plugin's start: the keys checked (keys that aren't a pair stop the server, saying why: a
## signature by them is tried), or, under `--dev` without them, a pair made for the run; and the
## jobs plugin told of `push.deliver`.
started! : {} => Try({}, Str)
started! = |{}| {
	keys = Push.keys!({})?
	if Env.dev!({}) and setting!("VAPID_SUBJECT").is_empty() {
		Log.warn!("push: VAPID_SUBJECT isn't set, so this run tells push services ${dev_subject}: set it in .env to a mailto: or https: contact of yours", {})
	}
	match P256.sign!(keys.private_key, keys.public_key, []) {
		Ok(_) => Job.adopt!(Push.deliver)
		Err(BadKey) => Err(not_a_pair)
	}
}

## The environment variable `name`, trimmed; "" when it isn't set.
setting! : Str => Str
setting! = |name| (Env.var!(name) ?? "").trim()

## How to make a VAPID pair, for a message that wants one.
making : Str
making = "`rocx dev` makes one: without keys it makes a pair and logs the lines for .env, and GET /__rocx/push/keys on it answers a new pair each time"

## The contact a push service is given under `--dev` when `VAPID_SUBJECT` isn't set.
dev_subject : Str
dev_subject = "mailto:dev@example.com"

## Where the pair a `--dev` run made is kept (`Kv`).
dev_kept : Str
dev_kept = "push:dev-keys"

## The pair this `--dev` run made, in base64url, for a server with no VAPID keys: made by the first
## to ask, kept in the server's memory until it stops, and logged, with the lines that keep it.
dev_pair! : {} => { public_key : Str, private_key : Str }
dev_pair! = |{}|
	match Kv.get!(dev_kept) {
		Ok(kept) => kept
		Err(_) => {
			made = P256.generate!({})
			pair = { public_key: Base64.url_encode(made.public_key), private_key: Base64.url_encode(made.private_key) }
			match Kv.add!(dev_kept, pair, {}) {
				Ok({}) => {
					Log.warn!("push: no VAPID keys, so this run made a pair, which the next start replaces (a browser subscribed with it then subscribes again); to keep it, put these in .env, a line each: VAPID_PUBLIC_KEY=${pair.public_key} VAPID_PRIVATE_KEY=${pair.private_key}", {})
					pair
				}
				Err(Exists) => Kv.get!(dev_kept) ?? pair
			}
		}
	}

## `GET /__rocx/push/keys`, under `--dev`: a new VAPID pair each time, as the lines that set it, for
## `.env` or a deployed server's environment (`curl -s localhost:8080/__rocx/push/keys >> .env`).
## Never the running server's pair, and never kept.
new_keys! : {} => Server.Response
new_keys! = |{}| {
	made = P256.generate!({})
	Server.response(
		200,
		[{ name: "content-type", value: "text/plain; charset=utf-8" }, { name: "cache-control", value: "no-store" }],
		"VAPID_PUBLIC_KEY=${Base64.url_encode(made.public_key)}\nVAPID_PRIVATE_KEY=${Base64.url_encode(made.private_key)}\n",
	)
}

## `GET <at>/key`: the public key, as JSON, for the page to subscribe with.
key! : {} => Server.Response
key! = |{}| {
	key = Push.public_key!({})
	if (key.is_empty()) refused(503, "the server has no VAPID_PUBLIC_KEY") else json(Json.to_str(key))
}

## `POST <at>/subscribe`: the subscription the page posted (`toJSON()`'s), kept for `owner`.
subscribed! : Server.Request, Str => Server.Response
subscribed! = |request, owner| {
	body : Try(Subscription.Body, [InvalidJson(Str)])
	body = Json.parse(Server.text_of(request))
	match body {
		Err(InvalidJson(why)) => refused(400, "POST ${request.path} can't read its body: ${why}")
		Ok(given) =>
			match Push.subscribe!(given, owner) {
				Ok({}) => json("{}")
				Err(Invalid(why)) => refused(400, why)
				Err(DbErr(why)) => refused(500, why)
			}
	}
}

## `POST <at>/unsubscribe`: `owner`'s subscription at the endpoint the page posted, forgotten.
unsubscribed! : Server.Request, Str => Server.Response
unsubscribed! = |request, owner| {
	body : Try({ endpoint : Str }, [InvalidJson(Str)])
	body = Json.parse(Server.text_of(request))
	match body {
		Err(InvalidJson(why)) => refused(400, "POST ${request.path} can't read its body: ${why}")
		Ok(given) =>
			match Push.unsubscribe!(given.endpoint, owner) {
				Ok({}) => json("{}")
				Err(DbErr(why)) => refused(500, why)
			}
	}
}

json : Str -> Server.Response
json = |text| Server.response(200, [{ name: "content-type", value: "application/json" }], text)

refused : U16, Str -> Server.Response
refused = |status, why| Server.response(status, [{ name: "content-type", value: "text/plain; charset=utf-8" }], why)

## What a VAPID pair that isn't one is said to be.
not_a_pair : Str
not_a_pair = "VAPID_PRIVATE_KEY and VAPID_PUBLIC_KEY aren't a pair: ${making}"

## `data` encrypted for `subscription` (RFC 8291): a new key pair, a new salt, one record.
encrypted! : Subscription, List(U8) => Try(List(U8), Str)
encrypted! = |subscription, data| {
	{ as_public, ecdh_secret } =
		match P256.ecdh!(subscription.p256dh) {
			Ok({ public_key, secret }) => { as_public: public_key, ecdh_secret: secret }
			Err(BadKey) => return Err("the subscription's p256dh isn't a point on P-256")
		}
	sealing =
		match WebPush.prepare({ ua_public: subscription.p256dh, auth_secret: subscription.auth, as_public, ecdh_secret, salt: Random.bytes!(16), data, padding: 0 }) {
			Ok(ready) => ready
			Err(BadKeys) => return Err("the subscription's keys, or the host's ECDH, aren't P-256's")
			Err(TooLarge) => return Err("the message is ${data.len().to_str()} bytes: a push message holds ${WebPush.max_data.to_str()} at most")
		}
	match AesGcm.seal_with_nonce!(sealing.key, sealing.nonce, sealing.record) {
		Ok(sealed) => Ok(WebPush.body(sealing, sealed))
		Err(_) => Err("AES-128-GCM refused the content key or the nonce: they aren't 16 and 12 bytes")
	}
}

queue_each! : List(I64), Str, Options => Try(U64, Str)
queue_each! = |ids, data, options| {
	checked =
		match Options.check(options) {
			Ok(fine) => fine
			Err(BadTopic) => return Err("the topic ${Json.to_str(options.topic)} isn't 32 characters at most of letters, digits, - and _")
		}
	if data.to_utf8().len() > WebPush.max_data {
		return Err("the notification is ${data.to_utf8().len().to_str()} bytes as JSON: a push message holds ${WebPush.max_data.to_str()} at most")
	}
	now = Time.now_millis!({})
	var $count = 0
	for id in ids {
		input = { subscription: id, data, ttl: checked.ttl, urgency: urgency_text(checked.urgency), topic: checked.topic, queued_ms: now, later: 0 }
		match Job.enqueue!(Push.deliver, input, {}) {
			Ok({}) => {}
			Err(JobErr(why)) => return Err(why)
		}
		$count = $count + 1
	}
	Ok($count)
}

urgency_text : [VeryLow, Low, Normal, High] -> Str
urgency_text = |urgency|
	match urgency {
		VeryLow => "very-low"
		Low => "low"
		Normal => "normal"
		High => "high"
	}

urgency_of : Str -> [VeryLow, Low, Normal, High]
urgency_of = |text|
	match text {
		"very-low" => VeryLow
		"low" => Low
		"high" => High
		_ => Normal
	}

## An attempt of the `deliver` job.
deliver! : Push.Input => Try({}, Str)
deliver! = |input| {
	row =
		match PushStore.find!(input.subscription) {
			Ok(Found(found)) => found
			Ok(Missing) => return Ok({})
			Err(DbErr(why)) => return Err(why)
			Err(BadRow(why)) => return Err(why)
		}
	subscription =
		match Subscription.from_text({ endpoint: row.endpoint, p256dh: row.p256dh, auth: row.auth }) {
			Ok(read) => read
			Err(_) => {
				_ = PushStore.remove_id!(row.id)
				return Ok({})
			}
		}
	now = Time.now_millis!({})
	options =
		match Options.remaining({ ttl: input.ttl, urgency: urgency_of(input.urgency), topic: input.topic }, input.queued_ms, now) {
			Ok(left) => left
			Err(Expired) => {
				Log.info!("push: a message's TTL ran out before it was delivered", { subscription: row.id, ttl: input.ttl })
				return Ok({})
			}
		}
	keys = Push.keys!({})?
	match Push.send!(keys, subscription, input.data.to_utf8(), options)? {
		Delivered => PushStore.delivered!(row.id).map_ok(|_| {}).map_err(|DbErr(why)| why)
		Gone => {
			Log.info!("push: a subscription is gone, so it is deleted", { subscription: row.id, owner: row.owner })
			PushStore.remove_id!(row.id).map_ok(|_| {}).map_err(|DbErr(why)| why)
		}
		RetryAfter(ms) =>
			if input.later < 5 and Options.remaining(options, now, now + ms).is_ok() {
				Job.enqueue!(Push.deliver, { ..input, later: input.later + 1 }, { when: At(now + ms) }).map_err(|JobErr(why)| why)
			} else {
				Err("the push service said to come back in ${(ms // 1000).to_str()} s, which is past the message's TTL or its fifth time")
			}
		Retry(why) => Err(why)
		Refused(why) => {
			Log.warn!("push: a push service refused a message", { subscription: row.id, why })
			PushStore.refused!(row.id, why).map_ok(|_| {}).map_err(|DbErr(problem)| problem)
		}
	}
}
