import crypto.Base64
import crypto.Hex
import crypto.Hkdf
import crypto.Hmac
import crypto.Sha256
import storage.Storage
import pf.AesGcm
import pf.Db
import pf.Env
import pf.Http
import pf.HttpResponse
import jobs.Job
import pf.Kv
import pf.Log
import pf.Random
import pf.Server
import pf.Time

## What the docs' platform pages show (site/routes/platform/…), written as an app would write it:
## compiled with the test app, which routes `/samples/…` to it, and run by its tests
## (`server/test/server.test.mjs`, "samples"). The site's build picks the lines it shows from here.
Samples := [].{

	# ---- Requests to other servers: Http ----

	## Tomorrow's forecast for a city, from a JSON API another server answers, with a token from the
	## environment: what it says, or why it says nothing.
	forecast! : Str, Str => Try({ tomorrow : Str }, [HttpErr(Str), TimedOut, TooLarge, InvalidJson(Str), Refused(U16)])
	forecast! = |api, city| {
		token = Env.var!("FORECAST_TOKEN") ?? "none"
		res = Http.fetch!("${api}/forecast", { query: [("city", city)], headers: [("authorization", "Bearer ${token}")] })?
		if (res.ok) Ok(res.json()?) else Err(Refused(res.status))
	}

	## An order sent to a shop's API as JSON, with a token, then cancelled with the same token: the
	## order's id, which the shop's answer gave.
	order! : Str, Str, { item : Str, count : U64 } => Try(Str, [HttpErr(Str), TimedOut, TooLarge, InvalidJson(Str), Refused(U16)])
	order! = |shop, token, order| {
		authed : Http.Init
		authed = { headers: [("authorization", "Bearer ${token}")] }
		placed : { id : Str }
		placed = Http.fetch!("${shop}/orders", { ..authed, method: Post, body: Http.json(order) })?.json()?
		res = Http.fetch!("${shop}/orders/${placed.id}", { ..authed, method: Delete })?
		if (res.ok) Ok(placed.id) else Err(Refused(res.status))
	}

	## A page someone else names (a link's preview): 5 s at most, 64 KiB at most, and a redirect is
	## the answer, not followed.
	preview! : Str => Try(HttpResponse, [HttpErr(Str), TimedOut, TooLarge])
	preview! = |url| Http.fetch!(url, { timeout_ms: 5_000, max_bytes: 65_536, redirect: Manual })

	## The lines of an answer too large to hold (an export, a log), counted as its chunks come, none
	## kept after it is counted; an answer that isn't a success stops at its head.
	lines! : Str => Try(U64, [HttpErr(Str), TimedOut, TooLarge, Stopped([Refused(U16)])])
	lines! = |url|
		Http.fetch_chunks!(
			url,
			{ timeout_ms: 0, max_bytes: 0 },
			0,
			|count, received|
				match received {
					Head(res) => if (res.ok) Ok(count) else Err(Refused(res.status))
					Chunk(bytes) => Ok(count + bytes.count_if(|byte| byte == '\n'))
				},
		)

	## A partner's API, through the proxy its network asks for (`PARTNER_PROXY`), when one is set; the
	## app's other requests go as `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` say.
	partner! : Str => Try(HttpResponse, [HttpErr(Str), TimedOut, TooLarge])
	partner! = |url|
		match Env.var!("PARTNER_PROXY") {
			Ok(proxy) => Http.fetch!(url, { proxy: Via(proxy) })
			Err(NotFound) => Http.fetch!(url, {})
		}

	# ---- Settings: Env ----

	## Where the app is, for a link in an email: `--public-url` or `PUBLIC_URL` when the server has
	## one, else where it listens. Never a request's `Host`, which whoever asks writes.
	origin! : {} => Str
	origin! = |{}| Env.public_url!({})

	## A secret from the server's environment, or none.
	signing_key! : {} => Try(Str, [NotFound])
	signing_key! = |{}| Env.var!("APP_SECRET")

	## Signing in as anyone, with no email: on a server started with `--dev` only.
	dev_sign_in! : Str => Server.Response
	dev_sign_in! = |member|
		if (Env.dev!({})) {
			Server.with_cookie(Server.redirect("/"), "member", member)
		} else {
			Server.refused(404, "No page here.")
		}

	# ---- Crypto: packages/crypto's Sha256, Hmac, Hkdf, Base64 and Hex; the platform's AesGcm and Random ----

	## A fresh token for a link: 32 random bytes, URL-safe.
	token! : {} => Str
	token! = |{}| Base64.url_encode(Random.bytes!(32))

	## What an app keeps of a token: its digest, never the token, so a leaked table signs no one in.
	digest : Str -> Str
	digest = |token| Sha256.hex(token.to_utf8())

	## A link for a member, until a moment (ms), signed with a key of its own derived from the app's
	## `APP_SECRET`.
	signed_link! : Str, U64 => Str
	signed_link! = |member, until| {
		said = "${member}.${until.to_str()}"
		"${said}.${Base64.url_encode(Hmac.sha256(link_key!({}), said.to_utf8()))}"
	}

	## Whom a signed link is for, if its signature holds and it hasn't run out by `now` (ms).
	link_member! : Str, U64 => Try(Str, [BadLink, Expired])
	link_member! = |link, now|
		match link.split_on(".") {
			[member, until, signature] => {
				said = "${member}.${until}"
				signed = Base64.url_decode(signature) ?? []
				if (!Hmac.verify_sha256(link_key!({}), said.to_utf8(), signed)) {
					Err(BadLink)
				} else if ((U64.from_str(until) ?? 0) < now) {
					Err(Expired)
				} else {
					Ok(member)
				}
			}
			_ => Err(BadLink)
		}

	## A secret kept in the database (another service's token), sealed with AES-256-GCM under a key
	## derived from `APP_SECRET`, as hex.
	seal! : Str => Try(Str, [BadKey])
	seal! = |secret| {
		sealed = AesGcm.seal!(sealing_key!({}), secret.to_utf8())?
		Ok(Hex.encode(sealed))
	}

	## The secret again; `Forged` if what was kept was changed, or sealed under another key.
	unseal! : Str => Try(Str, [BadKey, Forged, InvalidHex, BadUtf8])
	unseal! = |kept| {
		sealed = Hex.decode(kept)?
		opened = AesGcm.open!(sealing_key!({}), sealed)?
		Str.from_utf8(opened).map_err(|_| BadUtf8)
	}

	# ---- Jobs: options, keys, listing ----

	## A reminder: tried once, within a minute (`Job.define`'s are tried five times, with no limit).
	reminder : Job.Kind(_, { member : Str })
	reminder = Job.define_with("reminder", { attempts: 1, timeout_ms: 60_000 }, |_context, { member }| if (member.is_empty()) Err("no one to remind") else Ok({}))

	## A member's reminder, a day from now: one at a time, keyed by the member, so a second is
	## `Exists`, and nothing is queued.
	remind_tomorrow! : Str => Try([Queued, Exists], [JobErr(Str)])
	remind_tomorrow! = |member| Job.enqueue_keyed!(reminder, { member: member }, { when: At(Time.now_millis!({}) + 86_400_000), key: "reminder:${member}" })

	## Not tomorrow after all: canceled, or moved to an hour from now. Each says how many it changed.
	forget_reminder! : Str => Try(U64, [JobErr(Str)])
	forget_reminder! = |member| Job.cancel!("reminder:${member}")

	remind_sooner! : Str => Try(U64, [JobErr(Str)])
	remind_sooner! = |member| Job.move!("reminder:${member}", At(Time.now_millis!({}) + 3_600_000))

	## The last twenty reminders that failed, and why: what an app's own page of jobs might list.
	failed_reminders! : {} => Try(List(Str), [JobErr(Str)])
	failed_reminders! = |{}| {
		rows = Job.list!({ state: "failed", kind: "reminder", before_id: 0, limit: 20 })?
		Ok(
			rows.map(
				|row|
					match row.last_error {
						Some(why) => "${row.id.to_str()}: ${why}"
						Null => row.id.to_str()
					},
			),
		)
	}

	# ---- A transaction inside a transaction: Db (D-076) ----

	## Gives a customer points, in a transaction of its own: more than 100 at once are refused, and
	## none stay. Called inside another transaction, its transaction is a level of that one.
	award! : Str, I64 => Try({}, [DbErr(Str), TooMany])
	award! = |customer, points|
		Db.transaction!(
			|{}| {
				_ = Db.run!("insert into points (customer, points) values ($1, $2)", [Text(customer), Int(points)])?
				if (points > 100) Err(TooMany) else Ok({})
			},
		)

	## An order, and a point for every 10 spent. Points refused leave the order without them: their
	## level is rolled back, and this transaction goes on and commits.
	place_order! : Str, I64 => Try(Str, [DbErr(Str)])
	place_order! = |customer, total|
		Db.transaction!(
			|{}| {
				_ = Db.run!("insert into orders (customer, total) values ($1, $2)", [Text(customer), Int(total)])?
				match award!(customer, total // 10) {
					Ok({}) => Ok("ordered, with points")
					Err(TooMany) => Ok("ordered, without points")
					Err(DbErr(why)) => Err(DbErr(why))
				}
			},
		)

	# ---- Files: packages/storage ----

	## The app's bucket: the one its `STORAGE_URL` names (`s3://…`, `file:<dir>`, `memory:`).
	files! : {} => Try(Storage.Bucket, [StorageErr(Str)])
	files! = |{}| Storage.from_url(Env.var!("STORAGE_URL") ?? "")

	## A member's avatar, the bytes the browser sent, kept under the member's name.
	save_avatar! : Str, Server.Request => Try({}, [S3Err(Storage.Refusal), StorageErr(Str)])
	save_avatar! = |member, request| {
		type = Server.header(request, "content-type") ?? "application/octet-stream"
		Storage.put!(Samples.files!({})?, "avatars/${member}", request.body, { content_type: type })
	}

	## Its size and type, asked without its bytes.
	avatar_size! : Str => Try(Str, [NotFound, S3Err(Storage.Refusal), StorageErr(Str)])
	avatar_size! = |member| {
		info = Storage.head!(Samples.files!({})?, "avatars/${member}")?
		Ok("${info.size.to_str()} bytes of ${info.content_type}")
	}

	## Its bytes, read whole (64 MiB at most), and gone again.
	take_avatar! : Str => Try(List(U8), [NotFound, S3Err(Storage.Refusal), StorageErr(Str)])
	take_avatar! = |member| {
		files = Samples.files!({})?
		bytes = Storage.get!(files, "avatars/${member}")?
		Storage.delete!(files, "avatars/${member}")?
		Ok(bytes)
	}

	## A link the browser uploads a file with itself, for an hour: to S3, which the app's server never
	## sees; or to the app, the storage plugin's (`file:`, `memory:`).
	upload_link! : Str => Try(Str, [BadExpiry, StorageErr(Str)])
	upload_link! = |key| Storage.signed_url!(Samples.files!({})?, key, { method: "PUT", expires_s: 3600 })

	## A video in parts, as a browser sends a large file: started, each part sent (5 MiB or more,
	## but the last, for S3), then finished, the parts put together.
	save_in_parts! : Str, List(List(U8)) => Try({}, [NotFound, S3Err(Storage.Refusal), StorageErr(Str)])
	save_in_parts! = |key, parts| {
		files = Samples.files!({})?
		upload = Storage.start_upload!(files, key, { content_type: "video/mp4" })?
		var $sent = []
		for part in parts {
			number = $sent.len() + 1
			etag = Storage.upload_part!(files, key, upload, number, part)?
			$sent = $sent.append({ number, etag })
		}
		Storage.finish_upload!(files, key, upload, $sent)
	}

	## A video, sent to whoever asks, ranges and all, never through Roc. Without a bucket, a 500,
	## and the log says why.
	serve_video! : Str, Server.Request => Server.Response
	serve_video! = |key, request|
		match Samples.files!({}) {
			Ok(files) => Storage.serve!(files, key, request, { content_type: "video/mp4", cache_control: "private, max-age=3600" })
			Err(StorageErr(why)) => {
				Log.error!("no storage", { why: why })
				Server.refused(500, "Something went wrong.")
			}
		}

	## The same, always whole: the request's range dropped before the bucket is asked.
	serve_whole! : Str, Server.Request => Server.Response
	serve_whole! = |key, request| {
		whole = { ..request, headers: request.headers.drop_if(|header| header.name == "range") }
		match Samples.files!({}) {
			Ok(files) => Storage.serve!(files, key, whole, { content_type: "video/mp4", cache_control: "private" })
			Err(_) => Server.refused(500, "Something went wrong.")
		}
	}

	# ---- Bodies: bytes, and from elsewhere ----

	## An upload's digest: its body, the bytes as they came.
	upload_digest : Server.Request -> Server.Response
	upload_digest = |request| Server.response(200, [{ name: "content-type", value: "text/plain" }], Sha256.hex(request.body))

	## A file from another server (a CDN), sent on as it comes, its range and cache questions with it.
	from_cdn : Server.Request, Str -> Server.Response
	from_cdn = |request, url| {
		upstream = { method: "GET", url, headers: Server.passed_on(request) }
		Server.forward(upstream, [{ name: "cache-control", value: "public, max-age=86400" }])
	}

	# ---- Values in memory: Kv ----

	## Five sign-in tries a minute from each address: the count is the store's, a window a minute
	## long from the first try.
	may_try! : Str => Bool
	may_try! = |address| {
		tries = Kv.increment!("login:${address}", 1, { ttl_ms: 60_000 }) ?? 0
		tries <= 5
	}

	## A sign-in with another site begins: a random state it will send back, kept ten minutes.
	begin_sign_in! : {} => Str
	begin_sign_in! = |{}| {
		state = Base64.url_encode(Random.bytes!(16))
		Kv.set!("oauth:${state}", Time.now_millis!({}), { ttl_ms: 600_000 })
		state
	}

	## The state comes back: good once, within ten minutes. A second use finds nothing.
	finish_sign_in! : Str => Try({}, [UnknownState])
	finish_sign_in! = |state| {
		started : Try(U64, [NotFound, BadValue(Str)])
		started = Kv.take!("oauth:${state}")
		match started {
			Ok(_) => Ok({})
			Err(_) => Err(UnknownState)
		}
	}

	# ---- Cookies ----

	## A session for a month, over HTTPS only, for this host alone (`__Host-`).
	signed_in : Server.Response, Str -> Server.Response
	signed_in = |answer, token| Server.set_cookie(answer, "__Host-session", token, { ..Server.cookie_defaults, secure: Bool.True, max_age_s: 30 * 86_400 })

	## A link's review cookie, until the link runs out (ms), for the review pages only.
	reviewing : Server.Response, Str, U64 -> Server.Response
	reviewing = |answer, token, until| Server.set_cookie(answer, "review", token, { ..Server.cookie_defaults, expires_ms: until, path: "/review", same_site: Strict })

	## The session gone: cleared with the attributes it was set with.
	signed_out : Server.Response -> Server.Response
	signed_out = |answer| Server.clear_cookie(answer, "__Host-session", { ..Server.cookie_defaults, secure: Bool.True })
}

## The links' key: derived from the app's secret, for links alone, so no other use of the secret
## signs one.
link_key! : {} => List(U8)
link_key! = |{}| Hkdf.sha256(app_secret!({}), [], "links".to_utf8(), 32) ?? []

## The key secrets are sealed under, derived for that alone.
sealing_key! : {} => List(U8)
sealing_key! = |{}| Hkdf.sha256(app_secret!({}), [], "sealed".to_utf8(), 32) ?? []

## The app's secret, from its environment (a development one without).
app_secret! : {} => List(U8)
app_secret! = |{}| (Env.var!("APP_SECRET") ?? "a development secret, not for production").to_utf8()
