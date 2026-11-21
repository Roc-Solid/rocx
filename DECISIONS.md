# Platform decisions

Decisions about Roc Solid's platform APIs: what the server and browser platforms give an app, and
why they give it in that shape. Each entry has its context, the options weighed, the choice, the
API as it landed, why, and whether it can be undone. The server-side APIs are documented in
`server/README.md`, the browser-side ones (components, effects, forms) in `web/README.md`; where
this file and the code disagree, the code is right.

Every entry was checked against a few principles: SolidJS 2.0 parity on the UI side; one server
instance; batteries included, as Rails and Phoenix have them; a few lines of our own over a
dependency; and "would a second app want this?" Nothing goes into the platform that only one app
needs. D-014 to D-016 are deferred; the rest were decided on 2026-11-21.

---

## D-001 Binary request and response bodies

**Context.** The host read a request's body into a string (lossy UTF-8), `respond!` took it as
`Str`, and an answer was text, a page or events. Any binary body was corrupted, both ways. An app
that takes image uploads and large videos in parts, and serves them back, can't work like that.

**Options.**
1. `Server.Request.body : List(U8)`, and a `Bytes(List(U8))` answer.
2. Keep `body : Str` and add `bytes : List(U8)` beside it: two copies of every large body.
3. Base64 in the `Str`: a third larger, and every endpoint decodes it.

**Choice.** 1.

```roc
Request : { method : Str, path : Str, query : Str, headers : List({ name : Str, value : Str }), body : List(U8) }
Body : [Text(Str), Bytes(List(U8)), Page({} => Html), Events(Events(Str)), Forward(Upstream)]   # Forward: D-002

Server.text_of : Request -> Str                        # the body as UTF-8 (lossy): what JSON and forms are read from
Server.bytes : U16, List({ name : Str, value : Str }), List(U8) -> Response
Server.from_http : Str, Str, Str, List(U8) -> Request
Server.body_text : Response -> Str                     # an answer's text; a Bytes answer read as UTF-8

# what the platform requires of an app: respond! : Str, Str, Str, List(U8), Str => Server.Response
```

The host passes the bytes it read and sends a `Bytes` answer as it is; a 16 MiB body reaches Roc
whole. `Endpoint` reads JSON and forms through `text_of`, so endpoints that take JSON didn't change.
One exception stays text: `Server.request!({})`, the request a page or a server function reads,
comes from the host as `Str` on both platforms, so its body has U+FFFD where it isn't UTF-8. An
endpoint is given the request `respond!` got, bytes intact.

**Why.** One copy, no encoding; SvelteKit's `request.arrayBuffer()` beside `text()`.
**Reversible:** costly. It changed the shared `Server` module and the `respond!` every app provides
(which `rocx build` generates for most apps).

## D-002 Bodies streamed from elsewhere: `Forward`

**Context.** Other services fetch whole videos (up to 500 MB) from an app's own links, and a video
player seeks with `Range`. Bytes that big must not pass through Roc, which holds a body whole.

**Options.**
1. A `Forward` body: the host makes a request (with D-003's client) and pipes its status and body
   to the client, never into Roc.
2. Redirect to a presigned S3 URL. Some services pull only from a domain verified as the app's, and
   the files must never be public, so the link has to stay on the app's domain.
3. Bytes in ranges only. A client that asks for the whole file without `Range` still gets it whole.

**Choice.** 1.

```roc
Upstream : { method : Str, url : Str, headers : List({ name : Str, value : Str }) }
Server.forward : Upstream, List({ name : Str, value : Str }) -> Response
Server.passed_on : Request -> List({ name : Str, value : Str })   # Range, If-Range, If-None-Match, If-Modified-Since

upstream = { method: "GET", url: "https://cdn.example/videos/41.mp4", headers: Server.passed_on(request) }
Server.forward(upstream, [{ name: "content-type", value: "video/mp4" }, { name: "cache-control", value: "private" }])
```

- Upstream's status is the answer's (200, 206, 304, 404…), with its `content-type`,
  `content-length`, `content-range`, `accept-ranges`, `etag` and `last-modified`. The answer's own
  headers are added after those or replace them; its own `status` is a stand-in.
- Upstream is sent `upstream.headers` and nothing else, so the request's cookies stay here.
- An error upstream (400 or more) is never passed on: the answer is its status and reason as plain
  text, without the answer's headers. A 416 keeps `content-range`. S3's error XML names the bucket
  and the key, which is the reason.
- No answer, a URL that isn't `http(s)`, or a redirect that can't be followed is a 502; a head
  slower than 30 s is a 504. These are logged without the URL's query (a presigned signature).
- A body that stops short closes the client's connection with its `content-length` unmet, so a cut
  file is never passed off as whole.

**Changed while building.** At first the host passed the request's range and cache headers on by
itself. Now it sends only what the app put in `upstream.headers` (`Server.passed_on` gives them):
what goes upstream is visible in the code, and an app can drop or change a range first.

**Why.** A reverse proxy is general (Rails' `send_file` with `X-Accel-Redirect`, generalised), and it
keeps the S3 client in Roc (D-005) while the bytes stay in the host. **Reversible:** yes. Not done:
the other direction, a request's body streamed to storage as it comes.

## D-003 Outbound HTTP: `Http`

**Context.** The server couldn't make an HTTP request. Apps need one for a sign-in provider's code
exchange, third-party APIs, documents someone else names (fetched with tight limits: 5 s, 5 KiB, no
redirects), and S3.

**Options.**
1. In the host: hyper's HTTP/1.1 client over rustls (hyper, rustls, webpki-roots and tokio were
   dependencies already).
2. In Roc on `Tcp`, as `Smtp` is: chunked bodies, redirects and timeouts in Roc, every byte through
   Roc, and no streaming for D-002.
3. reqwest: many more dependencies.

**Choice.** 1, shaped like an earlier Roc worker platform's `Http`, so code written for that ports.

```roc
Http.Request : { method : Str, url : Str, headers : List({ name : Str, value : Str }), body : List(U8) }
Http.Response : { status : U16, headers : List({ name : Str, value : Str }), body : List(U8) }
Http.Opts : { timeout_ms : U64, max_bytes : U64, follow_redirects : Bool }

Http.defaults : Opts                                   # 30 s, 64 MiB, redirects followed
Http.send! : Request, Opts => Try(Response, [HttpErr(Str), TimedOut, TooLarge])
Http.fetch! : Request => Try(Response, [HttpErr(Str), TimedOut, TooLarge])   # send! with defaults
Http.get : Str -> Request
Http.post_form : Str, List((Str, Str)) -> Request      # application/x-www-form-urlencoded
Http.post_json : Str, Str -> Request
Http.with_header : Request, Str, Str -> Request
Http.header : Response, Str -> Try(Str, [Missing])     # in any case
Http.text : Response -> Str
```

- Any status is `Ok`; `Err` means no answer at all. 0 means no limit. The timeout covers
  connecting, TLS, the head and the whole body. `TooLarge` comes from `content-length` before the
  body is read, or as a chunked body passes the limit.
- Headers cross to the host as `name: value` lines, so a name or value with a line break, or a
  name with a colon, is refused (`HttpErr`) rather than sent as two headers. `host` and
  `content-length` are added unless given. The path and query go out as given, with no normalising
  or re-encoding (S3's signatures depend on it). Nothing is decompressed.
- Redirects are followed as `fetch` follows them: at most 20, a relative `location` resolved. A
  303, or a 301 or 302 after a POST, becomes a GET without a body. `authorization`, `cookie` and
  `proxy-authorization` are dropped when the origin changes. One connection per request, no pool.

**Changed while building.** `with_header` was added: `Request` is a structural record, so it can't
have methods, and without it a bearer token meant rebuilding `post_json`'s headers by hand. And a
HEAD of an object larger than `max_bytes` was `TooLarge` until answers to HEAD, 204 and 304 were
read as bodiless (`Storage.head!` found it).

**Why.** One tested implementation for Roc and for `Forward`, waiting on the call's thread as `Tcp`
and `Db` do. **Reversible:** yes.

**Since D-024** the API is `Http.fetch!(url, init)`, as JS's `fetch`; this one is kept, deprecated,
over it (`fetch!(request)` is `send_request!` now). The host is the same.

## D-004 Crypto: `Sha256`, `Hmac`, `Hkdf`, `AesGcm`, `Base64`, `Hex`, `Random.bytes!`

**Context.** An app that signs links keeps SHA256 digests of its session and invite tokens, signs
with HMAC-SHA256 under a key derived with HKDF from its `APP_SECRET`, seals third-party tokens with
AES-256-GCM, and makes random 32-byte tokens. S3's signatures need SHA256 and HMAC too. The platform
had only `Random.seed_u64!`, and a `Base64` that encoded only, wasn't URL-safe and wasn't exposed.

**Options.**
1. Everything in the host (ring has all of it).
2. Roc's builtin `Crypto.SHA256`; HMAC and HKDF in pure Roc on it; AES-GCM in the host (ring,
   linked already).

**Choice.** 2. No platform module is called `Crypto`: that is the builtin's name.

```roc
Sha256.hash : List(U8) -> List(U8)                                # 32 bytes (the builtin's)
Sha256.hex : List(U8) -> Str                                      # 64 lowercase digits
Hmac.sha256 : List(U8), List(U8) -> List(U8)                      # key, message
Hmac.verify_sha256 : List(U8), List(U8), List(U8) -> Bool         # key, message, signature; constant time
Hmac.equal : List(U8), List(U8) -> Bool                           # constant time: for token digests
Hkdf.sha256 : List(U8), List(U8), List(U8), U64 -> Try(List(U8), [TooLong])   # key, salt, info, length
Hkdf.extract : List(U8), List(U8) -> List(U8)
Hkdf.expand : List(U8), List(U8), U64 -> Try(List(U8), [TooLong])
AesGcm.seal! : List(U8), List(U8) => Try(List(U8), [BadKey])      # key, plaintext: nonce ++ ciphertext ++ tag
AesGcm.open! : List(U8), List(U8) => Try(List(U8), [BadKey, Forged])
Random.bytes! : U64 => List(U8)
Base64.encode, encode_unpadded, url_encode, url_encode_padded : List(U8) -> Str   # url_encode is unpadded
Base64.decode, url_decode : Str -> Try(List(U8), [InvalidBase64])
Hex.encode : List(U8) -> Str
Hex.decode : Str -> Try(List(U8), [InvalidHex])
```

- All but `AesGcm` are Roc with no effect, checked by `expect`s against published vectors (NIST,
  RFC 4231, RFC 4648, RFC 5869) and against Node's output in the server tests. `Sha256` wraps the
  builtin: one place for the shapes callers want, and one place to change if the builtin moves.
- The decoders take padded or unpadded input but are strict otherwise (no whitespace, exact
  padding, unused trailing bits zero): one text, one value.
- `AesGcm` takes a 32-byte key and makes a fresh random 12-byte nonce for each seal, in Web Crypto's
  format with the nonce in front, so either opens the other's. If the operating system gives no
  random bytes, `Random.bytes!` crashes the call rather than return zeros.
- They are server-only for now; they can move to `web/platform` when the browser wants them.

**Why.** Only AES needs the host. The rest is deterministic and testable with `expect`s, and large
upload parts are never hashed in Roc (D-005 sends parts unsigned). **Reversible:** yes.

**Since D-025:** `Sha256`, `Hmac`, `Hkdf`, `Base64` and `Hex` are `packages/crypto`, the same
functions; `AesGcm` and `Random` stay here.

## D-005 Storage: an S3 client in Roc

**Context.** There was no blob storage. The target is any S3: rustfs or MinIO in development, R2 or
AWS in production.

**Options.**
1. Roc (`Storage.roc`) on `Http` (D-003) and the crypto (D-004), signing SigV4 in Roc, with big
   downloads through `Forward` (D-002).
2. In the host: aws-sdk-s3 (a large dependency tree), the rust-s3 crate (more dependencies), or
   SigV4 of our own in Rust (as much code as in Roc, and it still needs the client).

**Choice.** 1, configured with `--storage-url` or `STORAGE_URL`
(`s3://KEY:SECRET@127.0.0.1:9000/uploads?region=us-east-1&style=path&tls=no`, or
`s3://KEY:SECRET@<account>.r2.cloudflarestorage.com/uploads?region=auto`).

```roc
Storage.put! : Str, List(U8), { content_type : Str } => Try({}, [S3Err(Refusal), StorageErr(Str)])
Storage.get! : Str => Try(List(U8), [NotFound, S3Err(Refusal), StorageErr(Str)])     # 64 MiB at most
Storage.get_range! : Str, { offset : U64, length : U64 } => Try({ bytes : List(U8), size : U64 }, [NotFound, S3Err(Refusal), StorageErr(Str)])
Storage.head! : Str => Try(Info, [NotFound, S3Err(Refusal), StorageErr(Str)])
Storage.delete! : Str => Try({}, [S3Err(Refusal), StorageErr(Str)])

Storage.start_upload! : Str, { content_type : Str } => Try(Str, [S3Err(Refusal), StorageErr(Str)])   # the upload id
Storage.upload_part! : Str, Str, U64, List(U8) => Try(Str, [NotFound, S3Err(Refusal), StorageErr(Str)])   # key, upload, number: ETag
Storage.finish_upload! : Str, Str, List({ number : U64, etag : Str }) => Try({}, [NotFound, S3Err(Refusal), StorageErr(Str)])
Storage.abort_upload! : Str, Str => Try({}, [S3Err(Refusal), StorageErr(Str)])

Storage.serve! : Str, Server.Request, { content_type : Str, cache_control : Str } => Server.Response
Storage.signed_url! : Str, { method : Str, expires_s : U64 } => Try(Str, [BadExpiry, StorageErr(Str)])

Storage.Info : { size : U64, content_type : Str, etag : Str }
Storage.Refusal : { status : U16, code : Str, message : Str }
```

- **Errors.** `NotFound` is S3's `NoSuchKey` or `NoSuchUpload`, or a 404 to a HEAD. `S3Err` is
  S3's `<Error>` (`AccessDenied`, `SignatureDoesNotMatch`, `NoSuchBucket`, `EntityTooSmall`, …; a
  HEAD's has an empty code). `StorageErr` is no answer or a timeout, a missing or unreadable
  `--storage-url`, or an empty key. Each operation lists only the tags it can give. A
  `CompleteMultipartUpload` that answers 200 with an `<Error>` in its body is an error.
- `delete!` of a missing object and `abort_upload!` of a missing upload are `Ok`, so a cleanup may
  run twice. ETags come without their quotes; `finish_upload!` quotes them again and takes the
  parts in any order.
- `put!` always signs its body's SHA256 (8 MB costs about 50 ms in a dev build). Parts go as
  `UNSIGNED-PAYLOAD`, with TLS keeping them whole.
- `serve!` answers a request with an object of any size: a `Forward` (D-002) of a GET (a HEAD for
  a HEAD) signed in headers, with `Server.passed_on(request)` added, so S3's status, length, range
  and ETag come back. An empty `content_type` keeps S3's; an empty `cache_control` sends none. No
  `--storage-url`, or an empty key, is a 500, logged as `rocx storage: …`.
- `signed_url!` signs only the host, so anyone holding the URL may make that request until it
  expires (a presigned PUT with any content type). `BadExpiry` unless 1 s to a week (S3's limit).
- **The URL.** The keys end at the last `@`, so a `/` in a secret needs no escaping. Defaults:
  `region=us-east-1`, virtual-hosted style, TLS. An unknown parameter (`stlye=path`) is refused.
- **Limits.** 30 s for HEAD, DELETE, start and abort; 5 minutes for put, parts, finish and reads.
  Redirects aren't followed. At start, the server asks for an object that isn't there and logs
  whether S3 answers, with these keys, for this bucket. Left out: listing, and session tokens.

**Changed while building.** The sketch had one error tag, `StorageErr(Str)`. An app needs to tell
"not there" from "S3 refused" from "S3 didn't answer", so there are three. `serve` became `serve!`:
it reads the setting and the clock to sign.

**Why.** About eight S3 calls in a few hundred lines, the same shape as `Smtp` on `Tcp`. The
primitives under it were needed anyway, there is no SDK, and SigV4's published worked examples
became `expect`s (`S3Sign.roc`, internal). Every app with uploads wants this (Rails' Active
Storage). **Reversible:** yes. Apps see `Storage`; its inside can move into the host unchanged.

**Since D-025:** `Storage` is `packages/s3`'s `S3`, each operation taking a bucket first;
`--storage-url` and the check at start are gone.

## D-006 App settings readable everywhere: `Env`

**Context.** `--context-file` reached `respond!` only. Jobs need the app's origin, its
`APP_SECRET` and third-party keys, and a dev-only sign-in must know the server runs under `--dev`.

**Options.** 1. `Env.var!` (the process environment) and `Env.dev!`. 2. Pass the context file to
jobs as well.

**Choice.** 1.

```roc
Env.var! : Str => Try(Str, [NotFound])
Env.dev! : {} => Bool                  # started with --dev
```

A variable that is set but empty is `Ok("")`, not `NotFound`. With `--dev` the host stores a `dev`
setting, which requests, jobs and schedules read alike.

**Why.** Secrets belong in the environment (twelve-factor; Phoenix's `runtime.exs`, Rails' `ENV`).
The context stays for what a request is given, and the platform's own settings stay flags or their
variables (`DATABASE_URL`, `SMTP_URL`, …). **Reversible:** yes.

## D-007 Cookie options

**Context.** `Server.with_cookie` always wrote `Path=/; HttpOnly; SameSite=Lax`: no `Max-Age`, no
`Secure`. Apps want `__Host-` cookies (`Secure`, `Path=/`, no `Domain`), a session that lasts 30
days, a preference kept for a year, and a cookie that ends at a fixed moment (when a signed link
does).

**Choice.** A record of options, and a defaults record to spread.

```roc
Server.CookieOpts : { max_age_s : U64, expires_ms : U64, secure : Bool, http_only : Bool, same_site : [Lax, Strict, None], path : Str, domain : Str }
Server.cookie_defaults : CookieOpts         # 0, 0, False, True, Lax, "/", ""
Server.set_cookie : Response, Str, Str, CookieOpts -> Response
Server.clear_cookie : Response, Str, CookieOpts -> Response
Server.with_cookie : Response, Str, Str -> Response   # set_cookie with cookie_defaults

Server.set_cookie(answer, "__Host-session", token, { ..Server.cookie_defaults, secure: Bool.True, max_age_s: 30 * 86_400 })
```

- 0 leaves out `Max-Age` or `Expires`; `""` leaves out `Path` or `Domain`. With neither `Max-Age`
  nor `Expires`, it is a session cookie. Attributes are written in the order
  `Path; Domain; Max-Age; Expires; Secure; HttpOnly; SameSite`, so `with_cookie` writes exactly what
  it did before.
- `clear_cookie` writes `Max-Age=0` with the options' path, domain and flags, ignoring their
  lifetime. Nothing is enforced: a `__Host-` name or `SameSite=None` without `secure` is written as
  asked, and browsers drop it; the docs say so. Both platforms have it.

**Changed while building.** `expires_ms` and `domain` were added. A pure function can't turn a fixed
moment into `Max-Age` without knowing the time, so `Expires` is written from it (IMF-fixdate).

**Why.** SvelteKit's `cookies.set(name, value, opts)`; a defaults record because Roc records have no
optional fields. **Reversible:** yes (additive).

## D-008 Jobs: attempts and a time limit per kind

**Context.** Every job got five attempts, and a job that never returned held a worker forever. Some
work must run once (an upload cut off must never repeat) and within a time limit.

**Choice.**

```roc
Job.define : Str, (input => Try({}, Str)) -> Kind(input)          # five attempts, no limit
Job.define_with : Str, { attempts : U64, timeout_ms : U64 }, (input => Try({}, Str)) -> Kind(input)

reminder = Job.define_with("reminder", { attempts: 1, timeout_ms: 20 * 60_000 }, |{ member }| …)
```

`program.jobs` entries carry `attempts` and `timeout_ms` (`Job.handler` copies them), and
`define_with` makes `attempts` at least 1. The time limit is a deadline on the job's isolated call.
The first effect that waits past it ends the call, wherever the job is: a Postgres statement, a
socket, an `Http` request (its own timeout shortened to the deadline), a sleep, a lock, a live
topic. An actor the job asks shares the deadline. The job fails with `timed out after <limit> ms`
and is retried if it has attempts left. Cron's jobs get their kind's attempts too.

**Changed while building.** Past the deadline an effect was going to return an error. A job could
ignore it, carry on and return `Ok`, which would mark it done. Instead the effect jumps back to the
call's guard, as a crash does: what the call allocated is freed, and what it held is given back. A
Postgres statement cut off is cancelled, and its connection closed rather than returned to the pool
(a late cancel could hit the next user's statement).

**Why.** Oban's `max_attempts` and `timeout`, Sidekiq's `retry`. Per kind, because it belongs to what
the job does, not to who queues it. **Reversible:** yes. Roc that loops without an effect isn't cut
off; the docs say so.

## D-009 Jobs: keys unique while pending; cancel and move

**Context.** `rocx_jobs.unique_key` existed, but only cron set it, and it was unique forever. An app
with per-record work wants one pending job per record (`reminder:<id>`) that can recur after it ran,
is cancelled when the record goes, and moves when the record is rescheduled.

**Choice.**

```roc
Job.When : [Now, At(U64)]
Job.enqueue! : Kind(input), input, { when : When } => Try({}, [JobErr(Str)])
Job.enqueue_keyed! : Kind(input), input, { when : When, key : Str } => Try([Queued, Exists], [JobErr(Str)])
Job.cancel! : Str => Try(U64, [JobErr(Str)])        # queued jobs with this key become canceled: how many
Job.move! : Str, When => Try(U64, [JobErr(Str)])    # the queued job with this key runs then instead
```

While a job with a key is queued or running, queueing another with it does nothing and answers
`Exists`; once that job is done, failed or canceled, the key is free again. `cancel!` doesn't stop a
running job. Each call is a statement, so in a transaction it stays only if the transaction commits,
and it wakes the workers (and the jobs page) when it does. The platform migration `rocx/0002` adds
the state `canceled` and replaces the unique constraint with a partial unique index
(`on rocx_jobs (unique_key) where state in ('queued', 'running')`). Cron keys its jobs by schedule
and due time.

**Changed while building.** The plan was a `key` field with a default on `enqueue!`'s options. The
pinned Roc has no default fields in record types, and a plain field would have changed every
`{ when: Now }` call, so the keyed form has its own name.

**Why.** Oban's `unique` and `cancel_job`: every app with per-record work wants one job per record.
**Reversible:** the migration is forward-only, but nothing depended on the old constraint.

## D-010 Jobs: listing and control

**Context.** Nothing listed jobs or acted on them. The jobs page (D-011) is built on this, and an app
may build its own.

**Choice.**

```roc
Job.Row : { id : I64, kind : Str, input : Str, state : Str, attempts : U64, max_attempts : U64, key : [Null, Some(Str)],
    run_at : I64, locked_at : [Null, Some(I64)], finished_at : [Null, Some(I64)], last_error : [Null, Some(Str)], created_at : I64 }
Job.Filter : { state : Str, kind : Str, before_id : I64, limit : U64 }      # "" and 0 for any

Job.list! : Filter => Try(List(Row), [JobErr(Str)])                          # newest first, by id
Job.get! : I64 => Try(Row, [NotFound, JobErr(Str)])
Job.counts! : {} => Try(List({ kind : Str, state : Str, count : U64 }), [JobErr(Str)])
Job.retry! : I64 => Try({}, [NotFound, JobErr(Str)])       # failed or canceled: queued now, attempts back to 0
Job.cancel_id! : I64 => Try({}, [NotFound, JobErr(Str)])   # queued: canceled
Job.run_now! : I64 => Try({}, [NotFound, JobErr(Str)])     # queued for later: due now

Cron.schedules! : {} => List({ name : Str, schedule : Str, job : Str, next_at : [Null, Some(I64)] })
Cron.run_now! : Str => Try({}, [NotFound, JobErr(Str)])    # the schedule's job, queued now
```

`NotFound` means there is no such job. An action on a job in another state is a `JobErr` that says
why (`job #12 is done: it can't be retried`), as is a retry blocked by a pending job with the same
key. Only `main.roc` sees `program`, so at start it keeps the kinds and schedules in the host's
store, where `Cron` and the jobs page read them.

**Changed while building.** `next_at` became optional: a schedule that never comes round again (the
30th of February) has no next time. **Reversible:** yes (additive).

## D-011 The jobs page: drawn by the platform, mounted by the app

**Context.** An app whose admins need to see scheduled jobs wants what is queued, running and
failed, and to retry, cancel and run now. Only the app knows who is an admin.

**Options.**
1. The platform renders the page (server-side HTML, plain forms) as a `Server.Response`; the app
   mounts it behind its own middleware.
2. A platform component. Its data would come through server functions, which `rocx build` finds by
   scanning the app, not the platform.
3. Only D-010's API; each app draws its own page.

**Choice.** 1, with 3 beneath it.

```roc
JobsPage.respond! : Server.Request, { mount : Str } => Server.Response

# routes/admin/jobs/+server.roc
middleware = Middlewares.admin
respond! = |{ request, .. }| JobsPage.respond!(request, { mount: "/admin/jobs" })   # every method (D-013)
```

- Views by query: `?state=failed`, `?kind=…`, `?before=<id>` for older ones (fifty a page), and
  `?id=<id>` for one job (its input, times, attempts, time limit and whole last error). It also
  shows each kind (attempts, time limit, counts by state) and the schedules with their next time.
- Actions are plain forms posting to `mount` (`action=retry|cancel|run_now` with `id=`, or
  `action=run_schedule` with `name=`), answered with a 303 back to the view they came from. One that
  can't be done is a 409 page saying why. A POST from another site's page is refused (403), on top
  of the app's own same-origin middleware.
- Its main part listens to `mount?events`, which says `changed` when a job starts, finishes, is
  queued or changes, and a few lines of script swap the fresh main part in, keeping the reader's
  place. Without script there is a Refresh link. No components and no hydration, so it works
  whatever the app's pages are made of; its stylesheet is its own, under the class `rocx-admin`.

**Why.** The Sidekiq::Web and Oban Web model: mount it behind your own auth. **Reversible:** yes.

## D-012 The dev mailbox

**Context.** With no `--smtp-url`, mail was kept in memory (the last 100) as JSON at
`GET /__rocx/mail`. `just dev` restarts the server on every save, which emptied it, and JSON is no
way to read an email.

**Choice.** Under `--dev`, the platform answers `/__rocx/mail` itself, before the app:

- `GET /__rocx/mail` lists the messages newest first (when, from, to, subject), with a Clear button
  (`POST /__rocx/mail/clear`). It updates as mail arrives (`/__rocx/mail?events`, on the live topic
  `rocx:mail`).
- `/__rocx/mail/<id>` shows the headers, the text, the HTML in a sandboxed `<iframe srcdoc>` (no
  script runs; a link opens in a new tab), and the raw message as SMTP would have sent it.
- With a database, messages are kept in `rocx_outbox` (platform migration `rocx/0002`; the last 500,
  for a week), so restarts keep them. Without one they stay in the server's memory (the last 100).
- JSON stays for tests: `/__rocx/mail.json`, and `/__rocx/mail` with `accept: application/json`.
  `--debug` without `--dev` serves only the JSON. Without either flag, those paths are the app's.

**Changed while building.** The platform's Roc answers the mailbox (`Outbox.roc`, called from
`main.roc` before the app's `respond!`), not the host, which keeps only the in-memory outbox.

**Why.** Phoenix's Swoosh `/dev/mailbox`, Rails' letter_opener_web: no mail client needed.
**Reversible:** yes.

## D-013 Routing edges: raw bodies, `respond!`, `.well-known`

**Context.** `Endpoint.respond!` parsed every non-empty body as JSON (or a form) and answered 400
otherwise, so a `PUT` of video bytes never reached its handler. A mounted page (the jobs page) wants
every method on one route. And `rocx` skipped directories starting with a dot, so
`routes/.well-known/` (RFC 8615's documents, which other services look for) was never routed.

**Choice.**

1. An endpoint reads its body only when it says it is JSON (`application/json`, or a type ending
   `+json`) or a form (`application/x-www-form-urlencoded`), parameters ignored, any case. An empty
   body is `{}`. Any other body, including one with no content type (a `fetch` of a `Blob` slice, as
   an uploader sends parts), isn't read: the handler's arg is `{}` and it reads `request.body`
   (D-001). A body that isn't read, sent to a handler that wants an arg, is a 415 naming the type.
2. A `+server.roc` may define `respond! : { request, params, context } => Server.Response`. It
   answers every method the file doesn't name, instead of a 405, behind the file's middleware; beside
   a page, a browser's GET is still the page's. `rocx routes` lists it as `*`; it is in neither
   `Api` nor the OpenAPI document.
3. `.well-known` is routed, and other dot entries are still skipped. A route under it is named
   without the dot: `/.well-known/change-password` is `well_known_change_password` in `Api`, its
   module `WellKnown…`. `rocx fmt` and `rocx lint` still skip dot directories.

**Changed while building.** JSON sent as `text/plain` is now a 415, where it used to be read.
**Reversible:** yes.

## D-014 A configurable body limit

**Status.** Deferred. A request's body may be 16 MiB at most (413 beyond), the limit included. An
app that uploads in parts can keep each part within it; another may want larger parts.

**Sketch.** `--max-body BYTES`, default 16 MiB. Streaming a request's body to storage (D-002's other
direction) would make the limit matter less.

## D-015 Structured log lines

**Status.** Deferred. An app may log one JSON object per event so each field can be filtered.
`Log.line!` takes text; JSON written by hand works today.

**Sketch.** `Log.event! : [Info, Warn, Error], Str, List((Str, Str)) => {}`, writing one JSON line.

## D-016 List parameters and checked queries

**Status.** Deferred. `Db.Value` is `[Null, Text(Str), Int(I64), Bool(Bool)]`, with no list, so
`in (…)` takes a JSON array (`jsonb_array_elements_text($1::jsonb)`) or an array literal
(`any($1::text[])`). Queries aren't checked at build; rows are decoded by the record each caller
annotates.

**Sketch.** `Db.Value` gains `Texts(List(Str))`, sent as a Postgres array. Later, a command that
describes each query against the dev database (Postgres reports parameter and column types) and
checks the annotated record, as sqlc does. roc-pg already checks its queries at build.

## D-017 Web platform: effects, cleanup, timers

**Context.** A page must start listening to its live stream when it mounts and stop when it goes,
and texts like "in 2 h" must move with the clock. The web platform had signals, memos, `refresh!`,
contexts and `on:frame`, but no effect, no cleanup and no timer.

**Choice.** Solid 2.0's split effects (RFC 01) and ownership (RFC 02), and the browser's timers with
their cleanup built in (as solid-primitives' `createTimer`).

```roc
import pf.Solid exposing [create_effect!, on_cleanup!, on_settled!, set_interval!, set_timeout!]

create_effect! : (() => a), (a => {}) => {}      # compute (tracked), then apply (after the flush)
on_cleanup! : (() => {}) => {}                    # the running owner's: before it runs again, and when it goes
on_settled! : (() => {}) => {}                    # once, after the flush that put it on the page
set_interval! : U64, (() => {}) => (() => {})     # every ms, as a handler; answers its clear!
set_timeout! : U64, (() => {}) => (() => {})      # once, after ms, as a handler; answers its clear!

create_effect!(|| room!(), |room| Endpoint.listen!(Api.events_room({ room }), Call.listen!, heard!))
stop! = set_interval!(1000, || set_seconds!(seconds!() + 1))
```

- `compute` runs where the effect is made, tracked. `apply` runs untracked once the markup is on
  the page, as a handler: it may write signals, applied when it is done. When what `compute` read
  changes, it runs again, then the last `apply`'s cleanups, then `apply`. Values are never compared,
  as in Solid. A `compute` that fails shows the nearest `<Errored>`; one that waits runs again when
  its value is in, and holds no `<Loading>`.
- Ownership: an effect, a cleanup, a timer or a listen belongs to the component, computation or
  apply that made it, and goes with it: children first, then cleanups, the last registered first.
  `on_cleanup!` in an event handler fails, since nothing would run it.
- A timer is cleaned up as if it had called `on_cleanup!(clear!)` where it started. One started in
  an event handler belongs to the run that made the handler's element. A listen (`Call.listen!`)
  started in an owner is aborted when that owner is cleaned up; from a handler it runs to the end.
- On the server neither half of an effect runs, no cleanup is kept and no timer starts: what they
  would undo never started.

**Changed from Solid, where Roc forces it.** Solid's `apply` returns its cleanup, a function or
nothing. Roc has no "nothing" a function may return, so `apply` registers it with `on_cleanup!`.
Solid gives `apply` the previous value and `compute` its own; here neither does: keep what is
needed in the value.

**Changed while building.** A `create_interval!` of the platform's own was dropped once the browser
timers `set_interval!` and `set_timeout!` landed with ownership: one way to run code later, not two.
**Reversible:** yes.

## D-018 Web platform: form actions

**Context.** A form that shows refusals in place needs the refusal and what was typed back on its
page. A plain form posts, the endpoint answers, and the page is gone. SolidStart has `action()` and
`useSubmission()`.

**Choice.** Solid Router's terms (`useSubmission`, `<form action={…} method="post">`) and
SolidStart's no-JS flow (a flash cookie, a redirect, the submission seeded on the server). An
endpoint already has a URL, a method and types, so it is the action: nothing like `action()` is
needed.

```roc
# Server (both platforms): the flash a plain form's post comes back with
Server.Flash : { url : Str, fields : List({ name : Str, value : Str }), status : U16, body : Str }
Server.flash! : {} => Try(Flash, [NoFlash])
Server.flash_back : Request, { url : Str, input : Str, status : U16, body : Str } -> Response
Server.clear_flash : Request, Response -> Response
Server.Problem : [HttpErr(Str), Refused(U16, Str), BadAnswer(Str)]
Server.explain : Problem -> Str

# Router and Submission: the latest submission to an endpoint, Solid's fields as methods
Router.use_submission! : Endpoint(context, arg, result) => Submission(arg, result)
pending! : Submission(arg, result) => Bool
input! : Submission(arg, result) => Try(arg, [NoInput])          # what was typed, as the endpoint reads it
field! : Submission(arg, result), Str => Str                     # one field as typed ("" without): FormData.get
result! : Submission(arg, result) => Try(result, [NoResult])
error! : Submission(arg, result) => Try(Server.Problem, [NoError])
clear! : Submission(arg, result) => {}                           # in a handler
```

```roc
join = Api.post_members_join({})
submission = use_submission!(join)
<form method="post" action={Endpoint.url_of(join)}>
	<input name="name" value={submission.field!("name")} />
	<button disabled?={submission.pending!()}>Join</button>
	<Show when!={submission.error!()}>{|problem!| <p class="problem">{Server.explain(problem!())}</p>}</Show>
</form>
```

- **Without the runtime** (a form body, `accept: text/html`), `Endpoint.respond!` doesn't send its
  result or refusal, which would be a page of JSON or text. It answers `Server.flash_back`: a 303 to
  the referring page (`Referer` when it is this site's, `/` otherwise) with the cookie `rocx-flash`
  (the URL posted to, the form's body, the status and the body; `Max-Age=60`; the fields left out
  past ~3.8 KB). An endpoint's own answer (`Err(Answer(…))`, a redirect that sets a cookie) is sent
  as it is.
- `Server.flash!({})` reads it on the page the redirect lands on. The host notes what a page read
  in `<script type="application/json" class="rocx-flash">`, so hydration renders what the server
  did. `App.program` lets it go with that page (`Server.clear_flash`: a browser's next GET of a page
  clears the cookie), so a reload doesn't show it again.
- **With the runtime**, `use_submission!` registers its endpoint's URL while its component is there.
  A submit of a `method="post"` form to that URL (same site, not multipart, not prevented by a
  handler) goes with `fetch`, fields URL-encoded, with `accept: application/json` and
  `x-rocx-submission: 1`. It is pending until the answer is in: a 200 is its result, any other
  status its error (`Refused(status, why)`), no answer `HttpErr`. The latest submission wins.
- An endpoint's redirect comes back to the runtime as 200 with `x-rocx-redirect`, cookies kept, for
  the runtime to go there: `fetch` follows a 3xx before anyone can read it (SolidStart's
  `X-Server-Function-Redirect`). With no submission in the browser, a submission reads the flash for
  its endpoint, so a plain post shows the error and what was typed too. `clear!` hides both.

**Changed from Solid, where Roc forces it.** A record can't have getters, so the fields are methods.
The form's `action` is the endpoint's URL, since Roc can't turn an endpoint into a string by itself.
`input!` is the endpoint's typed arg, not a `FormData`, with `field!` for `FormData.get`. No `retry`
(a no-op on Solid's `useSubmission`), `useSubmissions`, `useAction` or `.with`: an endpoint's params
are in its URL. **Reversible:** yes.

## D-019 A server function's redirect while a page renders

**Context.** A layout calls a server function (who is signed in?), and the app's default middleware
sends a signed-out visitor to `/login` with a 303. The host answers that call in-process as the
page renders, so the call failed with `303`. The root `<Errored>` sits inside the root layout (a
boundary around the whole document can't work), so nothing caught it, and the page was a 500.

**Options.**
1. Document only: a layout guards its own holes that call the server with an `<Errored>`.
2. A generated boundary around the root layout; but its fallback can't be a second document.
3. A redirect a call gets while a page renders is the page's answer, as SolidStart answers a
   `redirect()` thrown while it renders.

**Choice.** 3 for redirects, 1 for every other failure.

- The first such redirect (a status from 300 to 399 with a `location`) is the page's answer, whether
  an `<Errored>` caught it or not. It keeps the cookies the redirect sets and the page's own headers
  except its `content-type`; nothing of the page is sent.
- A call that fails otherwise (401, 500) still fails its computation: inside an `<Errored>` it shows
  there, and in the root layout, with no boundary above it, the page is a 500. So a layout puts an
  `<Errored>` around the holes that call the server.
- Native rendering only: `renderToString` (the Node runtime) has no answer headers to read a
  `location` from, and renders the failure.

**Reversible:** yes.

## D-021 Actors: registered kinds, mailboxes, typed tells and timers, no locks

**Context.** An actor was a named lock (`Host.lock!`, a `tokio::sync::Mutex` per key) around a read
of its state, its `receive!` run in the asker's call (`Host.isolated_call!`, a box the asker made),
and a write to Postgres. Asks were ordered (the mutex is first-in first-out), but nothing could run
an actor when nobody was waiting: no tell, no timer. Every key ever asked stayed in memory, its lock
and its state, until a restart. And "called into being by its first message (`init(key)`)" read as
if `init` were a message.

**Options.**
1. Keep the lock; add a tell as a background ask, and idle eviction. A tell would hold a thread for
   as long as it waits for the lock, and still nothing could run a kind on its own.
2. An actor library (kameo, ractor): a mailbox and a task per actor, supervision, remote actors.
   Virtual actors (woken by a message, let go when idle) and the bridge to Roc calls would still be
   ours; supervision adds little when a crash already leaves the state as it was; one server needs
   no remote actors.
3. Our own, on tokio's channels: kinds registered by `rocx build`, a mailbox per actor, one router.

**Choice.** 3.

```roc
counter : Actor.Kind({ count : I64 }, [Add(I64), Get], I64)
counter = Actor.define({
    name: "counter",
    initial: |_key| { count: 0 },
    receive!: |me, state, message| …,
})

Actor.ask! : Kind(s, m, r), Str, m => Try(r, [ActorErr(Str)])
Actor.tell! : Kind(s, m, r), Str, m => {}
Actor.tell_after! : Kind(s, m, r), Str, U64, m => Timer
Actor.after! : Me(m), U64, m => Timer     # an actor's own, typed by its kind's messages
Actor.cancel! : Timer => {}
Actor.key_of : Me(m) -> Str
```

- `define` takes a record (named fields); `init` is now `initial`, the state a new actor starts
  from, which no message is.
- `rocx build` finds `Actor.define` at the top of a module's block (`name` first, a function of `{}`
  too) and lists each in `program.actors` (`Actor.handler`), as it lists jobs. The host refuses a
  message to a kind not listed.
- The host (`server/host/src/actors.rs`): one router task owns the table of awake actors and the
  timers; each awake actor is a task with an unbounded mailbox, running its turns one at a time,
  each a guarded call into Roc of its own (`actor_for_host!`). No mutex anywhere: the table is the
  router's alone; tasks talk over `tokio::sync::mpsc` (unbounded) and `oneshot`; timer numbers are
  an atomic counter. `memory.rs`, the store `Registry` uses, became a list that grows at its head by
  compare-and-swap. `Host.lock!`, `Host.unlock!` and `Host.isolated_call!` are gone.
- Order: one router, one mailbox each, both first-in first-out.
- A message an actor doesn't take (it doesn't parse as its kind's), a kind the app has none of, and a
  crash in `receive!` are logged at error (`rocx actor: a message failed`, with `actor`, `key`,
  `error`) and told to an asker; the actor goes on, its state as it was.
- An ask from a turn to an actor up its own chain of asks (itself included) is refused at once; an
  ask not answered in 30 s is given up on, and its message dropped if its turn hasn't come.
- With a database: state read by an actor's first turn, written after each turn that changes it;
  an actor idle for `--actor-idle-ms` (15 minutes) is let go when nothing was sent to it meanwhile,
  and woken as Postgres has it. Without one, its state is its task's, and it stays awake.
- Timers and tells are in memory: a restart loses those not yet handled (jobs are for work that must
  survive one).

**Why.** Tells and timers need the server to run a kind with no asker, which needs the kinds
registered; once they are, a mailbox per actor is the natural shape, and it orders tells and asks
alike. The runtime is ~300 lines on channels tokio already gives us, over a library whose
supervision and remote actors one server doesn't need.

**Reversible:** the API, with an edit at every call site (`define`'s record, `receive!`'s `me`); the
runtime, freely.

## D-022 Nulls are the reader's to say; sockets are their call's

**Context.** Postgres doesn't say in a statement's result whether a column may be null, and a
column that may be was read as `[Null, Some(a)]`, whose JSON (`"Null"`, `{"Some": a}`) isn't a
plain value's. So the host looked each column up in the catalog (`pg_attribute.attnotnull`), kept
the answers in a map shared by every call (a `Mutex`), forgot them after a script, and let a column's
name say otherwise (`"x?"` may be null, `"x!"` never is). The record a caller decodes rows into
already says which of its fields may be null; the host was guessing what the reader knew. And
`Tcp`'s sockets sat in a global table behind two `Mutex`es (the table's, and each socket's), though a
socket only ever belongs to the call that opened it, on one thread.

**Options.**
1. Keep both: they work, and neither lock is contended.
2. Rows as JSON has them (`null`, or the value), and a nominal `Db.Nullable(a)` that reads `null`
   as `Null` and anything else as `Some(a)` (its own `parser_for` and `encoder_for`); sockets in the
   thread's own table.
3. A Postgres client in Roc (roc-pg) that checks queries at build: types and nullability known
   before the server runs. A bigger change, for later.

**Choice.** 2.

```roc
notes : Try(List({ id : I64, body : Str, note : Db.Nullable(Str) }), [DbErr(Str), BadRow(Str)])

match row.note {
    Null => "-"
    Some(text) => text
}
```

- `Db.Nullable(a) := [Null, Some(a)]`, matched and built with `Null` and `Some(a)` as before; in
  JSON, `null` or the value, both ways, nested too (a list of them, a `jsonb` column's fields).
- A null in a field the record reads as a plain value is `BadRow`, naming the column ("`note` is
  null in a row; a column that may be null is read as Db.Nullable(a)").
- A column named `x?` or `x!` is refused, with how to say it now.
- `Job.Row`'s `key`, `locked_at`, `finished_at` and `last_error` are `Db.Nullable`.
- `tcp.rs`: a thread-local table; ids stay unique across threads (one atomic counter), so an id
  from another call is a closed connection, as it was once that call had ended.

**Why.** The type is where Roc says what may be missing, and the decoder follows it as sqlx's
`Option<T>` does: no catalog round trip, no shared cache, no rule about names. Sockets were never
shared, so the locks guarded nothing.

**Reversible:** yes; the API change is a type at each nullable column.

## D-023 Endpoints are how an app talks to its server; server functions are deprecated

**Context.** An app had two ways to reach its server. A server function (`name! = server!(…)`) was
answered at `POST /rocx/call/<Module>.<name>`, in-process while the server rendered, and recorded
for hydration. An endpoint (a route's `+server.roc`) had a URL of its own, typed through
`Generated/Api`, but a component could only send it from a handler. So a page whose data was also
an API defined it twice: once as a server function for the render, once as the route's `get!`.
And the server functions' URLs were rocx's, not the app's: unchosen, and absent from
`/openapi.json`.

**Options.**
1. Keep both, and document when to use which.
2. Give server functions URLs the app chooses: still a second way to say what an endpoint says.
3. Let a component read a GET endpoint where it renders, as it called a server function, and
   deprecate server functions (SvelteKit's `load` and SolidStart's `query` read data the same way:
   one definition, read on the server first, its answer serialized for the browser).

**Choice.** 3.

```roc
Endpoint.get! : Endpoint(context, {}, result) => result              # a refusal fails the computation
Endpoint.read! : Endpoint(context, {}, result) => Try(result, Server.Problem)
Endpoint.with_query : Endpoint(context, arg, result), Str -> Endpoint(context, arg, result)

profile! = create_memo!(|| Endpoint.get!(Api.get_profile({ id })))
board! = create_memo!(|| Endpoint.get!(Endpoint.with_query(Api.get_board({}), Router.location!({}).query)))
```

- **While the server renders a page**, a read is a GET of the endpoint's URL, answered in-process
  through its route, as the browser's GET would be: `accept: application/json`, the page's cookies
  and headers, `origin` this host, the route's middleware around it. Each URL is asked once a render.
  The answer, whatever its status, is noted in the page's answers script under `GET <url>` (the
  query part of the key), unless the read is inside a `<NoHydration>`.
- **Hydrating**, the browser reads each GET from the page and asks nothing. Strict hydration (the
  tests') throws if the page asks the server for anything it didn't carry.
- **Later** (`refresh!(memo!)`, a URL built from a signal), the browser GETs the endpoint's own URL
  for JSON: the same URL anything else would ask.
- An answer that isn't 200 fails the computation (`get!`), or is its value (`read!`); recorded too,
  so the browser fails where the server did. A redirect met while the page renders is the page's
  answer, as D-019 has it for server functions.
- A page's data is best at the page's own URL: a route's `+page.rocx` and `+server.roc` share a
  path, the page answering a browser's GET and `get!` the rest. A layout, which many paths share,
  reads an endpoint at a path of its own (the docs site's footer reads `GET /api/facts`).
- Middleware context is the handler's `context`, not `Server.context!`.
- `server!` still works, and `rocx build` warns at each one. Once no app uses them, server
  functions go, with `/rocx/call/`, `Generated/ServerFunctions`, `Server.local`/`remote`/`serve!`/
  `context!` and the host's `call!`/`record!`/`serve!`/`serving!`/`context!`.
- No new host effect: a read is the platform's `Call.fetch!`. On the server, `Host.fetch!` answers a
  GET of a path in-process while a page renders, and fails as before otherwise (a POST, another
  site's URL, no page being rendered). In the browser and in Node's `renderToString`, a fetch whose
  key the page's answers have is answered from them.
- The static export needs nothing new: a prerendered page carries the GETs it read.

**Why.** One definition of a page's data, at a URL the app chose, typed by the same `Api`, in the
OpenAPI document, behind the same middleware for the page's render, the browser and anyone else.
The render, hydration and later reads all meet the same handler.

**Changed from SolidStart.** No `query` wrapper or cache key: the endpoint's URL is the key, and a
memo is the cache. **Reversible:** reads, yes; removing server functions, once done, only by
bringing them back.

## D-024 Http as fetch

**Context.** D-003's client is a request record and builders around it:
`Http.fetch!(Http.with_header(Http.get(url), "authorization", "Bearer …"))`, `post_form` and
`post_json` for bodies, `send!(request, opts)` restating all three limits to change one, and
`Http.header(res, name)` and `Http.text(res)` to read the answer. A query was written by hand
(`Server.encode_segment` on each value), JSON both ways by hand (`Json.to_str`,
`Json.parse(Http.text(res))`), and each header was one more nested call. Everyone who writes for
the web knows `fetch(url, init)`. The user decided (2026-11-21) that the client is `fetch!`-like,
as in JS, and that it is the one way.

**Options.**
1. fetch-like: one effect, `Http.fetch!(url, init)`, where `init` is a record whose every field has
   a default, and an answer with methods.
2. A builder: methods on a nominal request (`Http.get(url).header(name, value).query(pairs)`) and a
   last `send!`.
3. Both.

**Choice.** 1. The API before it stays, deprecated, as thin wrappers over `fetch!` (an app outside
this repo uses `send!`, `defaults`, `Request` and `Response`, and `packages/s3` is given `send!`);
it goes in a later release.

```roc
Http.Method : [Get, Post, Put, Patch, Delete, Head, Options, Other(Str)]
Http.Body := [Empty, Json(Str), Form(List((Str, Str))), PlainText(Str), Bytes(List(U8))]
Http.Init := {
    method : Method ?? Get,
    headers : List((Str, Str)) ?? [],
    query : List((Str, Str)) ?? [],
    body : Body ?? Empty,
    timeout_ms : U64 ?? 30_000,           # 0: no limit
    max_bytes : U64 ?? 67_108_864,        # 0: any size
    redirect : [Follow, Manual] ?? Follow,
}
Http.fetch! : Str, Init => Try(HttpResponse, [HttpErr(Str), TimedOut, TooLarge])

Http.json : a -> Body where [a.Json.Encodable([])]   # application/json
Http.form : List((Str, Str)) -> Body                  # application/x-www-form-urlencoded
Http.plain_text : Str -> Body                         # text/plain; charset=utf-8
Http.bytes : List(U8) -> Body                         # no content-type, as fetch sends a Uint8Array

HttpResponse := { status : U16, ok : Bool, headers : List((Str, Str)), body : List(U8) }
HttpResponse.header : HttpResponse, Str -> Try(Str, [Missing])          # in any case
HttpResponse.text : HttpResponse -> Str                                  # UTF-8, lossy
HttpResponse.json : HttpResponse -> Try(a, [InvalidJson(Str)])           # as Json.parse reads it
HttpResponse.bytes : HttpResponse -> List(U8)
HttpResponse.new : U16, List((Str, Str)), List(U8) -> HttpResponse      # ok from the status
```

```roc
weather = Http.fetch!("${api}/forecast", { query: [("city", city)] })?.json()?
Http.fetch!(token_url, { method: Post, body: Http.form([("grant_type", "authorization_code"), ("code", code)]) })?
authed : Http.Init
authed = { headers: [("authorization", "Bearer ${token}")] }
res = Http.fetch!(url, { ..authed, method: Delete })?
if (res.ok) res.text() else …
```

- `{}` is a GET with every default. A record literal becomes an `Init` wherever one is expected, as
  `App.Config`'s does. A record kept to build on needs its annotation (`authed : Http.Init`): a
  record update can't add a field to a plain record, and `{ ..authed, method: Delete }` composes
  once `authed` is an `Init`.
- `query`: each name and value percent-encoded (all but letters, digits and `-._~`), joined by `&`,
  after a `?`, or after an `&` when the URL has a query already (after nothing when it ends in `?`
  or `&`), and before a `#fragment`.
- A body's `content-type` is added unless `headers` has one, in any case: the caller's is the only
  one sent.
- `ok` is a 2xx. The answer's header names are lower case (hyper's).
- Errors as in D-003. A header with a line break, or a name with a colon, is `HttpErr`.
- The host is unchanged: an `Init` becomes the same `Host.http_send!` call as a `Request` did.

**Names.**
- `HttpResponse` is a module of its own, not a type inside `Http`. A type's methods share its
  module's scope, so `Http.Response`'s `text` and `header` would clash with the deprecated
  `Http.text` and `Http.header`. And `Http.Response` stays the deprecated record, which an app outside
  this repo names. Once the deprecated API is gone, `Http.Response` can become another name for
  `HttpResponse`.
- The body helpers are `Http.json`, `Http.form` and `Http.bytes`, as planned: `res.json()` and
  `res.bytes()` are `HttpResponse`'s, so there is no clash (as JS has `Response.json(data)` beside
  `res.json()`). Text is `Http.plain_text`, because `Http.text` is the deprecated reader.
- `fetch!` is the new shape's name, so the old `fetch!(request)` is `send_request!` now, deprecated.

**Deprecated** (each with a `## deprecated: use Http.fetch!` doc, each `fetch!` underneath):
`Request`, `Response`, `Opts`, `defaults`, `send!`, `send_request!` (was `fetch!`), `get`,
`post_form`, `post_json`, `with_header`, `header`, `text`. `send!` passes a request's method as
written (`"PURGE"` is `Other("PURGE")`), and its body as bytes with its own headers, so the same
request goes out as before.

**Migrated:** packages/push (`Push.send!`, with `Delivery`'s and `Options`'s headers as
`(name, value)` pairs), the server's test app and the docs' samples, server/README.md and the HTTP
page. **Not migrated:** `packages/s3` (D-025) is on no platform, so it can't name `Http.Init` or
`HttpResponse`; it is given `Http.send!`, whose records it writes out, and stays on it until a
package can be handed `fetch!` in a shape it can name.

**Why.** It is the client every web developer knows, so the docs don't have to teach one: a query, a
body and a typed answer are each a field or a method, not a builder chain and an encoder by hand.
Defaults in the type keep `{}` and `{ method: Post, body: … }` short, and options are a value to
name and update (`authed`). A builder (2) needs a nominal request with a method for each option and
a last `send!`, which record defaults make unnecessary. Both (3) are two ways to teach and to read.

**Reversible:** yes. The host didn't change, and the old API is still there, so going back is an
edit at each call site. Removing the deprecated wrappers later is an edit at each caller left, and
needs a shape `packages/s3` can take instead of `send!`.

## D-025 S3 and the crypto written in Roc are packages

**Context.** `Storage` (D-005) and the crypto (D-004) were the platform's, but neither needs the
host: S3 is Roc on `Http.send!` and `Time.now_millis!`, and SHA-256, HMAC, HKDF, Base64 and hex are
Roc with no effect at all. The rule above says nothing goes into the platform that only some apps
need, and a platform module costs every app (its reference, its build) and every package: a package
can't import a platform's modules, so `packages/push` and `packages/mcp` kept copies of Base64 and
HMAC/HKDF of their own. A browser page couldn't use the crypto either, being on the other platform.

**Options.**
1. Leave them in the platform.
2. Packages on no platform: `packages/crypto` as it was, and `packages/s3` taking the two effects it
   needs as functions, as `packages/admin` takes `Db`'s.
3. Packages that name the server platform, copied into an app by hand until packages can ship
   server modules.

**Choice.** 2. A platform module stays only if it needs the host or the transpiler.

```roc
# app [program] { pf: platform "…", crypto: "…/packages/crypto/main.roc", s3: "…/packages/s3/main.roc" }
import crypto.Hmac                               # Sha256, Hmac, Hkdf, Base64, Hex: as they were
import s3.S3

S3.from_url : Str, S3.Effects -> Try(S3.Bucket, [StorageErr(Str)])
S3.Effects : { send! : S3.Request, S3.Opts => Try(S3.Response, [HttpErr(Str), TimedOut, TooLarge]), now! : {} => U64 }

bucket = S3.from_url(Env.var!("STORAGE_URL") ?? "", { send!: Http.send!, now!: Time.now_millis! })?
S3.put!(bucket, key, bytes, { content_type })?   # every Storage operation, with the bucket first
S3.serve!(bucket, key, request, opts)            # a Forward, as Server.forward makes one
S3.check! : S3.Bucket => Try({}, [S3Err(S3.Refusal), StorageErr(Str)])
```

- `S3.Request`, `S3.Response` and `S3.Opts` are `Http`'s records, written out, so `Http.send!` is
  passed as it is; `serve!`'s answer is a record whose body is `[Forward(…), Text(Str), ..others]`,
  which is a `Server.Response`. The request it takes is any record with `method` and `headers`.
- The URL is the app's to read (an environment variable, `STORAGE_URL`, say): the server's
  `--storage-url` is gone, and with it the look at S3 at start. `S3.check!` is that look, for an
  app's health check. A missing or unreadable URL is `StorageErr` from `from_url`; an empty key is
  `StorageErr` from each operation, and a 404 from `serve!`.
- `S3Sign` is `SigV4`, exposed. It keeps its own few lines of the calendar (`Calendar` is the
  platform's, for cron and email).
- Email (`Smtp`, MIME) still needs Base64, so the platform keeps a private one, `encode` and `lines`
  only, until email moves too.

**Not moved yet.** `Email` and `Audio` would move the same way, but each needs what a package can't
give an app yet: email's dev mailbox keeps mail in the host's memory without a database and is
answered at `/__rocx/mail` (which `packages/testing` reads), and `Audio`'s player is the runtime's
JavaScript. They move once packages can ship server modules, migrations and static files.

**Why.** The platform is what needs the host; the rest is an app's choice. Two modules that were
copied into packages become one package they can name, a page can hash and sign in the browser, and
a second store (another S3-like API, the local disk) is a sibling package rather than a platform
change.

**Reversible:** yes; the platform could expose them again unchanged.

**Since:** `packages/push` (its `Kdf` and `Base64Url`) and `packages/mcp` (its `Base64`) name
`packages/crypto` instead of keeping copies. mcp decoded more loosely (an `=` anywhere, bits left
over); its one decode, a client's `=?base64?…?=` header, falls back to the text as it came, so
input that isn't Base64 is now shown as it came rather than half decoded.

## D-026 A finer clock, and the route that answers a request

**Context.** OpenTelemetry metrics (`packages/otel`) time every request and label it by its route.
`Time.now_millis!` makes most of a fast server's requests, and nearly every query, 0 ms. And a
middleware has only the request's path, so `/posts/42` and `/posts/43` would be a series each: one
per post, with no end to them.

**Options.**
1. Leave both to the app: it passes its own clock and its route to each measurement.
2. `Time.now_nanos!`; and `route` on `Server.Request`, the route's pattern, set before the app's
   middleware runs, from a `Routes.pattern` that `rocx build` writes beside `Routes.respond!`.
3. A response header the router adds, which the middleware reads after `next!`. It works without a
   new field, but it is a header no one asked for.

**Choice.** 2.

```roc
started = Time.now_nanos!({})
answer = next!(request, context)
took = Time.now_nanos!({}) - started   # request.route: "/posts/[id]"
```

- `now_nanos!`: Unix nanoseconds, the system clock's when first read plus a steady clock's time
  since, so two readings never go back.
- `route`: the route file's directory (`/blog/[slug]`, `/` for routes/ itself);
  `/rocx/call/<name>` for a server function the app has; a dev build's stories, their path; `""`
  where nothing answers, in a request made by hand (`from_http`), and in the browser.

**Why.** A route's pattern is what every metric and log groups requests by. Only the router knows
it, and it knows it before anything runs.

**Reversible:** yes. Both are additions; a record that builds a `Server.Request` by hand gains
`route`.
