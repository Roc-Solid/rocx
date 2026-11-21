import pf.Env
import pf.Http
import pf.Job
import pf.Log
import pf.Random
import pf.Time
import push.Delivery
import push.Notification
import push.Options
import push.Subscription
import push.Vapid
import push.WebPush
import PushStore

## Web Push from the server: subscriptions saved as pages post them (`subscribe!`), notifications
## queued as jobs (`notify!`, `broadcast!`), one per subscription, and sent by the job workers
## (`deliver`): encrypted for the browser (RFC 8291), signed for its push service (VAPID, RFC 8292),
## posted (RFC 8030), and sent again later if the push service is busy or down, until the
## message's TTL runs out. A subscription the push service says is gone is deleted. Server-only:
## it imports the server platform's `Http`, `Job` and `Env`.
##
## The keys come from the environment: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` (base64url, as
## `node packages/push/vapid-keys.mjs` prints them) and `VAPID_SUBJECT` (`mailto:` or `https:`).
##
## The P-256 and AES-128-GCM it needs are the host's to do, and the host has none yet
## (PROPOSALS.md): until it does, `host` says so, and every delivery fails with that reason.
Push := [].{

	## What the host does for Web Push: an ECDH with a new key pair each time (its public key and
	## the shared secret), AES-128-GCM with a given key and nonce (the ciphertext and the tag), and
	## an ES256 signature (64 bytes, `r` then `s`) by a private key (with its public key).
	Primitives : {
		ecdh! : List(U8) => Try({ as_public : List(U8), ecdh_secret : List(U8) }, Str),
		seal! : List(U8), List(U8), List(U8) => Try(List(U8), Str),
		sign! : List(U8), List(U8), List(U8) => Try(List(U8), Str),
	}

	## The host's, once it has them; for now, each says it is missing.
	host : Primitives
	host = {
		ecdh!: |_| missing!({}),
		seal!: |_, _, _| missing!({}),
		sign!: |_, _, _| missing!({}),
	}

	## The server's VAPID keys, from its environment; or what is wrong with them.
	keys! : {} => Try(Vapid.Keys, Str)
	keys! = |{}| {
		text = {
			public_key: Env.var!("VAPID_PUBLIC_KEY") ?? "",
			private_key: Env.var!("VAPID_PRIVATE_KEY") ?? "",
			subject: Env.var!("VAPID_SUBJECT") ?? "",
		}
		match Vapid.from_text(text) {
			Ok(keys) => Ok(keys)
			Err(BadPublicKey) => Err("VAPID_PUBLIC_KEY isn't a P-256 public key in base64url (65 bytes, uncompressed): `node packages/push/vapid-keys.mjs` makes a pair")
			Err(BadPrivateKey) => Err("VAPID_PRIVATE_KEY isn't a P-256 private key in base64url (32 bytes): `node packages/push/vapid-keys.mjs` makes a pair")
			Err(BadSubject) => Err("VAPID_SUBJECT isn't a contact: write mailto: and an address, or an https: URL")
		}
	}

	## The public key in base64url, for the page to subscribe with (`applicationServerKey`); ""
	## when the server has no keys.
	public_key! : {} => Str
	public_key! = |{}| (Env.var!("VAPID_PUBLIC_KEY") ?? "").trim()

	## Saves the subscription a page posted (an endpoint's body), for `owner` (the app's id for a
	## user, or "" for a visitor). It must be at a browser's push service
	## (`Subscription.known_service`), or, under `--dev`, at one on this machine; `Invalid` says
	## why not.
	subscribe! : Subscription.Body, Str => Try({}, [Invalid(Str), DbErr(Str)])
	subscribe! = |body, owner|
		match Subscription.from_body(body) {
			Ok(subscription) =>
				if subscription.known_service() or (Env.dev!({}) and !subscription.endpoint.starts_with("https://")) {
					PushStore.save!(subscription, owner)
				} else {
					Err(Invalid("the endpoint isn't at a browser's push service"))
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
	deliver : Job.Kind(Input)
	deliver = Job.define_with("push.deliver", { attempts: 5, timeout_ms: 60_000 }, |input| deliver!(Push.host, input))

	## One attempt at sending `data` (empty: a push with no data, which the service worker shows as
	## a notification with no text) to `subscription`, with `options`: what the push service's
	## answer means, or why no request was sent.
	send! : Primitives, Vapid.Keys, Subscription, List(U8), Options => Try(Delivery.Outcome, Str)
	send! = |primitives, keys, subscription, data, options| {
		now = Time.now_millis!({})
		claims =
			match Vapid.claims(keys, subscription.endpoint, now) {
				Ok(said) => said
				Err(BadEndpoint) => return Err("the subscription's endpoint isn't a URL: ${subscription.endpoint}")
			}
		input = Vapid.signing_input(claims)
		jwt =
			match Vapid.token(input, (primitives.sign!)(keys.private_key, keys.public_key, input.to_utf8())?) {
				Ok(made) => made
				Err(BadSignature) => return Err("the host's ES256 signature isn't 64 bytes")
			}
		body = if (data.is_empty()) [] else encrypted!(primitives, subscription, data)?
		request = Delivery.request({ endpoint: subscription.endpoint, authorization: Vapid.authorization(jwt, keys.public_key), body, options })
		match Http.fetch!(request.url, { method: Post, headers: request.headers, body: Http.bytes(request.body), timeout_ms: 30_000, max_bytes: 65_536, redirect: Manual }) {
			Ok(res) => Ok(Delivery.outcome({ status: res.status, headers: res.headers, body: res.body }, Time.now_millis!({})))
			Err(TimedOut) => Ok(Retry("the push service didn't answer within 30 seconds"))
			Err(TooLarge) => Ok(Retry("the push service's answer was too large to read"))
			Err(HttpErr(why)) => Ok(Retry("couldn't reach the push service: ${why}"))
		}
	}
}

missing! : {} => Try(a, Str)
missing! = |{}| Err("the server's host has no P-256 or AES-128-GCM yet, which Web Push needs (packages/push/PROPOSALS.md)")

## `data` encrypted for `subscription`: a new key pair, a new salt, one record.
encrypted! : Push.Primitives, Subscription, List(U8) => Try(List(U8), Str)
encrypted! = |primitives, subscription, data| {
	{ as_public, ecdh_secret } = (primitives.ecdh!)(subscription.p256dh)?
	sealing =
		match WebPush.prepare({ ua_public: subscription.p256dh, auth_secret: subscription.auth, as_public, ecdh_secret, salt: Random.bytes!(16), data, padding: 0 }) {
			Ok(ready) => ready
			Err(BadKeys) => return Err("the subscription's keys, or the host's ECDH, aren't P-256's")
			Err(TooLarge) => return Err("the message is ${data.len().to_str()} bytes: a push message holds ${WebPush.max_data.to_str()} at most")
		}
	sealed = (primitives.seal!)(sealing.key, sealing.nonce, sealing.record)?
	Ok(WebPush.body(sealing, sealed))
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
		match Job.enqueue!(Push.deliver, input, { when: Now }) {
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
deliver! : Push.Primitives, Push.Input => Try({}, Str)
deliver! = |primitives, input| {
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
	match Push.send!(primitives, keys, subscription, input.data.to_utf8(), options)? {
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
