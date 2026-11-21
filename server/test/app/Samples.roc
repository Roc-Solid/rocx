import crypto.Base64
import crypto.Hex
import crypto.Hkdf
import crypto.Hmac
import crypto.Sha256
import s3.S3
import pf.AesGcm
import pf.Env
import pf.Http
import pf.Job
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
	## environment: its text, or why there is none.
	forecast! : Str, Str => Try(Str, [HttpErr(Str), TimedOut, TooLarge, Refused(U16)])
	forecast! = |api, city| {
		token = Env.var!("FORECAST_TOKEN") ?? "none"
		asked = Http.get("${api}/forecast?city=${Server.encode_segment(city)}")
		answer = Http.fetch!(Http.with_header(asked, "authorization", "Bearer ${token}"))?
		if (answer.status == 200) Ok(Http.text(answer)) else Err(Refused(answer.status))
	}

	## A page someone else names (a link's preview): 5 s at most, 64 KiB at most, and a redirect is
	## the answer, not followed.
	preview! : Str => Try(Http.Response, [HttpErr(Str), TimedOut, TooLarge])
	preview! = |url| Http.send!(Http.get(url), { timeout_ms: 5_000, max_bytes: 65_536, follow_redirects: Bool.False })

	# ---- Settings: Env ----

	## Where the app is: its environment's `ORIGIN`, or a dev server's.
	origin! : {} => Str
	origin! = |{}| Env.var!("ORIGIN") ?? "http://localhost:8080"

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
	reminder : Job.Kind({ member : Str })
	reminder = Job.define_with("reminder", { attempts: 1, timeout_ms: 60_000 }, |{ member }| if (member.is_empty()) Err("no one to remind") else Ok({}))

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

	# ---- Files in S3: packages/s3 ----

	## The app's bucket: the one its `STORAGE_URL` names, reached with the platform's `Http.send!`
	## and `Time.now_millis!`.
	files! : {} => Try(S3.Bucket, [StorageErr(Str)])
	files! = |{}| S3.from_url(Env.var!("STORAGE_URL") ?? "", { send!: Http.send!, now!: Time.now_millis! })

	## A member's avatar, the bytes the browser sent, kept under the member's name.
	save_avatar! : Str, Server.Request => Try({}, [S3Err(S3.Refusal), StorageErr(Str)])
	save_avatar! = |member, request| {
		type = Server.header(request, "content-type") ?? "application/octet-stream"
		S3.put!(Samples.files!({})?, "avatars/${member}", request.body, { content_type: type })
	}

	## Its size and type, asked without its bytes.
	avatar_size! : Str => Try(Str, [NotFound, S3Err(S3.Refusal), StorageErr(Str)])
	avatar_size! = |member| {
		info = S3.head!(Samples.files!({})?, "avatars/${member}")?
		Ok("${info.size.to_str()} bytes of ${info.content_type}")
	}

	## Its bytes, read whole (64 MiB at most), and gone again.
	take_avatar! : Str => Try(List(U8), [NotFound, S3Err(S3.Refusal), StorageErr(Str)])
	take_avatar! = |member| {
		files = Samples.files!({})?
		bytes = S3.get!(files, "avatars/${member}")?
		S3.delete!(files, "avatars/${member}")?
		Ok(bytes)
	}

	## A link the browser uploads a file to S3 with itself, for an hour: the app's server never holds
	## its bytes.
	upload_link! : Str => Try(Str, [BadExpiry, StorageErr(Str)])
	upload_link! = |key| S3.signed_url!(Samples.files!({})?, key, { method: "PUT", expires_s: 3600 })

	## A video in parts, as a browser sends a large file: started, each part sent (5 MiB or more,
	## but the last), then finished, S3 putting them together.
	save_in_parts! : Str, List(List(U8)) => Try({}, [NotFound, S3Err(S3.Refusal), StorageErr(Str)])
	save_in_parts! = |key, parts| {
		files = Samples.files!({})?
		upload = S3.start_upload!(files, key, { content_type: "video/mp4" })?
		var $sent = []
		for part in parts {
			number = $sent.len() + 1
			etag = S3.upload_part!(files, key, upload, number, part)?
			$sent = $sent.append({ number, etag })
		}
		S3.finish_upload!(files, key, upload, $sent)
	}

	## A video, streamed from S3 to whoever asks, ranges and all, never through Roc. Without a
	## bucket, a 500, and the log says why.
	serve_video! : Str, Server.Request => Server.Response
	serve_video! = |key, request|
		match Samples.files!({}) {
			Ok(files) => S3.serve!(files, key, request, { content_type: "video/mp4", cache_control: "private, max-age=3600" })
			Err(StorageErr(why)) => {
				Log.error!("no storage", { why: why })
				Server.refused(500, "Something went wrong.")
			}
		}

	## The same, always whole: the request's range dropped before S3 is asked.
	serve_whole! : Str, Server.Request => Server.Response
	serve_whole! = |key, request| {
		whole = { ..request, headers: request.headers.drop_if(|header| header.name == "range") }
		match Samples.files!({}) {
			Ok(files) => S3.serve!(files, key, whole, { content_type: "video/mp4", cache_control: "private" })
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
