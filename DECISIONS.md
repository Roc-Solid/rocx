# Platform decisions

Decisions about Roc Solid's platform APIs: what the server and browser platforms give an app, and
why they give it in that shape. Each entry has its context, the options weighed, the choice, the
API as it landed, why, and whether it can be undone. The server-side APIs are documented in
`server/README.md`, the browser-side ones (components, effects, forms) in `web/README.md`; where
this file and the code disagree, the code is right.

Every entry was checked against a few principles: SolidJS 2.0 parity on the UI side; one server
instance; batteries included, as Rails and Phoenix have them; a few lines of our own over a
dependency; and "would a second app want this?" Nothing goes into the platform that only one app
needs. D-014 to D-016 are deferred (D-016's list parameters landed since); the rest were decided on
2026-11-21.

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
One exception stays text: `Server.request!({})`, the request a page or an endpoint reads,
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

**Later (2026-11-22):** jobs are packages/jobs's, a plugin (D-034); these functions are its `Job`'s and `Cron`'s, unchanged.

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

**Later (2026-11-22):** the jobs page is packages/admin's, a plugin with a required guard (`JobsPage.plugin({ at, guard })`), its look one with the tables admin's (D-034); `JobsPage.respond!` still mounts it from a route file.

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
  **Since D-028:** always in the server's memory (`Kv`, the last 100), database or not; `rocx/0003`
  drops the table.
- JSON stays for tests: `/__rocx/mail.json`, and `/__rocx/mail` with `accept: application/json`.
  `--debug` without `--dev` serves only the JSON. Without either flag, those paths are the app's.

**Changed while building.** The platform's Roc answers the mailbox (`Outbox.roc`, called from
`main.roc` before the app's `respond!`), not the host, which keeps only the in-memory outbox.

**Why.** Phoenix's Swoosh `/dev/mailbox`, Rails' letter_opener_web: no mail client needed.
**Reversible:** yes.

**Later (2026-11-22):** the mailbox is packages/email's, the email plugin's early paths, at the same paths (D-035).

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

**Status.** List parameters landed on 2026-11-22 as `Db.array : List(Value) -> Value`, a function
that writes the Postgres array literal as a `Text` (the host sends every parameter as text, and
Postgres reads it as the array its place wants), not as a new `Value` tag, so every match on
`Db.Value` keeps compiling and the host is unchanged. Checked queries are still deferred.

Before: `Db.Value` is `[Null, Text(Str), Int(I64), Bool(Bool)]`, with no list, so
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

**Later (2026-11-22):** the flash is kept in the server's memory for a minute, under a random id the
cookie holds, and the first page that reads it takes it (`Server.flash_back!`, now effectful); there
is no size limit. `Html` never writes a `value` into an `<input type="password">`, and the page's
note of the flash leaves out the fields it has as one, so a password typed is never sent back.

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

**Reversible:** yes. Since D-023 a page reads endpoints instead, and the same holds for them.

## D-020 Channels: typed live updates over one stream per tab

**Context.** A page that follows something live (an org's news, who is in a room, where the others'
cursors are) listened to an endpoint's events (`Endpoint.listen!`): a `fetch` of its own per
listener, so a page with seven of them waited for a connection (a browser opens six per host over
HTTP/1.1). Two components couldn't share one, a page couldn't change what it listened to without a
new one, what was published between the page's render and its listening was lost, a stream that
dropped never came back, and the check that let a listener in ran once, so someone who lost access
kept hearing. And each open stream held one of the server's 1024 threads for Roc, so a thousand open
tabs would stop it answering.

**Options.**
1. Keep `events!`, and fix each problem in the app: a stream per page, its own reconnects and checks.
2. WebSockets: one connection both ways. A second protocol, its own upgrade path through proxies,
   and state per connection on the server; the browser's pages say little, and plain HTTP posts do.
3. Channels the app defines (a check, a message type, what pages may say), carried over one
   server-sent-events stream per tab that the host keeps without a thread, a hub in the runtime
   that reconnects it, and plain posts for what pages say.

**Choice.** 3.

```roc
# routes/org/[org]/news/+server.roc, behind the route's middleware
channel! : { request : Server.Request, params : { org : Str }, context : Member } => Try(Channel(Str, News, [Hello(Str)]), Endpoint.Refusal)
channel! = |{ params, context, .. }| if context.org == params.org Ok(Channel.allow(context.name)) else Err(Forbidden)
receive! = |{ who, said, channel, .. }| …       # optional: what pages say, after the same check
on_open! = |{ who, tab, channel, .. }| [welcome] # optional: sent first, after each Resync
on_close! = |{ who, tab, why, channel, .. }| …   # optional: why is Gone or Refused(Str)

# a component, from an effect
create_effect!(|| org!(), |org| Endpoint.subscribe!(Api.channel_org_org_news({ org }), heard!))
Endpoint.say!(Api.channel_org_org_news({ org }), Hello("hi"))   # from a handler
Endpoint.resync!(Api.channel_org_org_news({ org }))

# the server: a request, a job, an actor
Endpoint.publish!(Api.channel_org_org_news({ org: "acme" }), news)
Endpoint.publish_latest!(Api.channel_rooms_room({ room }), member, cursor)

Channel(who, message, said)                       # what channel! answers: Channel.allow(who)
Channel.Event(message) : [Message(message), Resync, Refused(U16, Str), Ended(Str)]
```

- **A channel is a route's `channel!`**, at a path the app chose, as an endpoint is (D-023): its
  identity is that path with its params. `rocx build` writes it into `Generated/Api` as
  `channel_<path>(params)`, an `Endpoint` whose method is `CHANNEL`; the browser's copy is its URL.
  A path a channel alone is at answers no HTTP request. A page reads the channel's data as the
  server renders it from a `get!` on the same path.
- **One stream per tab, `GET /rocx/live?tab=<id>&c=<url>…`**, server-sent events, answered by the
  host on the async side (`server/host/src/channels.rs`). Roc runs only briefly, a call at a time on
  the blocking pool: each channel's check as the stream opens, again on each beat, a hook. The
  tests keep 40 streams open on 8 threads while requests answer at once.
- **The check is a request** the host makes of the app for the channel's own path, with the
  stream's headers, `accept: application/json` and `x-rocx-channel: open`, through the app's
  middleware and the route's: the route's middleware guards its channel as it guards its endpoints,
  and its context is the check's `context`. The host drops `x-rocx-channel` from every request it is
  sent. `/rocx/live` itself never reaches the app's middleware, so a sign-in guard has nothing to
  let through (as it had for `/rocx/call/`).
- **Refusal is per channel**: a refused one gets `event: refused` (its status and why), and the
  stream goes on for the others.
- **Checked again on every beat** (`: beat`, every 15 s, `--live-beat-ms`): one that now refuses
  gets `event: ended` and its `on_close!` is told `Refused(why)`. A server error (500) ends nothing.
- **Resync**: a channel let in gets `event: resync`, then its `on_open!` messages, then what is
  published. Its topic is listened to before its check runs, so nothing published meanwhile is
  missed. A subscriber that falls behind (256 messages) is resynced instead of being sent what it
  missed; a page may ask (`Endpoint.resync!`), and a new subscriber to a channel already open
  does, through `POST /rocx/live/send`, without a reconnect.
- **The hub** (`runtime.js`) keeps the tab's subscriptions, two subscribers to a channel sharing
  it. When the set changes it opens the stream again once the render that changed it is done, and
  only if the set changed; when the stream drops, after 0.5 s, doubled each time to 30 s. Each
  subscriber hears its events one at a time, in order. A tab's id, random, kept in sessionStorage,
  names it to the hooks. Where no server answers (a static copy), every subscriber hears
  `Refused(404, …)`, asked once.
- **What pages say** goes in `POST /rocx/live/send?tab=<id>`, a frame's sayings in one JSON list,
  each through the channel's middleware and check, then `receive!`: 204, or each refusal. JSON
  only, so another site's form can't post it.
- **Hooks** are given the path's params, who the check said, the tab's id, and the channel (a route
  file can't import `Api`). `who` is JSON, kept by the host for `on_close!`, which runs outside the
  middleware: the subscriber's access may be what ended it.
- **Order**: a channel's messages arrive in the order they were published. `publish_latest!`
  messages are a topic of their own: a subscriber behind gets only the newest per key, never a
  resync, and they aren't ordered with the others.
- **Dead clients**: a 20 s deadline on what the server sent going unacknowledged
  (`TCP_USER_TIMEOUT`, `TCP_RXT_CONNDROPTIME`) ends a stream whose client vanished about 35 s
  later, at a beat, and `on_close!` is told `Gone`.
- Publishing is `Live`'s (topics `channel:<url>`, `latest:<url>`), in one server's memory. A
  Postgres `listen`/`notify` backend could carry it later behind the same `publish!`.

**Why.** One connection per tab whatever the page follows, a check that keeps applying, no gap a
subscriber can't see (it is told to read again), and servers that hold no thread per open tab. The
server keeps nothing per stream but the stream itself, so reconnecting with the new set works
through any proxy; a connection id with subscribe and unsubscribe posts is the fallback if
reconnects ever cost too much. No second protocol: what pages say is a post.

**Changed while building.** Channels were first a `channel!` construct inside components, like
`server!`; after D-023 they are a route's, as endpoints are. A subscription's end can't say
`Unsubscribed`: a change of what a tab subscribes to opens its stream again, and the old stream's
end is `Gone`. `/rocx/live` has no route pattern (`Server.Request.route`, D-026): the host answers
it, so a metric in the app's middleware never sees it; each check is labelled by its channel's
route.

**Reversible:** the API, with an edit at each channel and subscription; the transport (one stream,
the hub), freely: it is the platform's.

**Since (2026-11-22).** A tab has one stream, and its hooks come in order: a new stream for a tab
(a reload, a reconnect, a change of channels, which the host may see before the old connection's
close) ends the tab's old one first, telling it `event: replaced`, and waits for its `on_close!`s
before its own checks and `on_open!`s. A route keeps who is here by tab with nothing to count
(examples/quiz counted each tab's open streams before). A page that hears `replaced` is a duplicated
tab, whose sessionStorage held the same id: it takes one of its own. packages/presence runs on a
channel since, its hooks the package's, its room in `Kv`.

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

## D-023 Endpoints are how an app talks to its server; server functions are gone

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
   remove server functions (SvelteKit's `load` and SolidStart's `query` read data the same way:
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
- Server functions are gone (removed the same day, once the apps that used them had moved): with
  them `/rocx/call/`, `Generated/ServerFunctions`, `Server.local`/`remote`/`serve!`/`context!`,
  `Call.server!` and the hosts' `call!`/`record!`/`serve!`/`serving!`/`context!`. `server!(…)` is a
  build error at its line that says what to write instead.
- No new host effect: a read is the platform's `Call.fetch!`. On the server, `Host.fetch!` answers a
  GET of a path in-process while a page renders, and fails as before otherwise (a POST, another
  site's URL, no page being rendered). In the browser and in Node's `renderToString`, a fetch whose
  key the page's answers have is answered from them.
- The static export needs nothing new: a prerendered page carries the GETs it read.
- Moving an app off server functions, two things met it:
  - **An import only a server function's body used.** `rocx build` dropped such an import from
    the browser's copy along with the body. Once the body is an endpoint, the page's import of a
    module (for a type, say) stays in the browser's copy, and if that module imports what only the
    server has (`pf.Db`), the browser's build fails. The import belongs in the route's
    `+server.roc`. `rocx build --client` now warns of such an import, at the line that reaches it:
    a module the browser's build reaches (from its `main.roc`) that imports what only the server
    platform exposes.
  - **The shape of what tests read.** A page's data and its layout's are two answers now, the
    page's own GET and the layout's endpoint: a test that read them as one JSON reads two.

**Why.** One definition of a page's data, at a URL the app chose, typed by the same `Api`, in the
OpenAPI document, behind the same middleware for the page's render, the browser and anyone else.
The render, hydration and later reads all meet the same handler.

**Changed from SolidStart.** No `query` wrapper or cache key: the endpoint's URL is the key, and a
memo is the cache. **Reversible:** reads, yes; server functions only by bringing them back.

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

**Later (2026-11-22):** plugins (D-033) let the rest follow the same rule: jobs and cron, and the jobs page with its look (D-034), and email with its mailbox (D-035) are packages.

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

## D-027 Roc calls on stackful coroutines

**Context.** Roc's effects are synchronous calls into the host: a hosted function returns its
answer. So the host ran each call into Roc (a request and the page it renders, a stream, an actor's
turn, a background loop, the platform's start) on a thread of tokio's blocking pool, and a hosted
function that waited (Postgres, a socket, another server, a sleep, an actor's answer) blocked that
thread on its future. The pool held 1024 threads at most (`--blocking-threads`, 8 MiB stacks): at
most 1024 calls in progress, waiting or not. An open `events!` stream held one for its whole life,
as every background loop did, and past the cap requests queued for a thread. Channels (D-020) had
already moved their streams off it.

**Options.**
1. Blocking threads, as they were, with a larger cap. Each is a kernel thread, with a stack and the
   scheduler's attention: ten thousand open streams are ten thousand threads.
2. Async Rust: hosted functions return futures. Impossible without Roc yielding: a Roc function in
   the middle of its own frames can't be suspended when it calls an effect, and Roc has no async.
3. Stackful coroutines in the Rust host: each call into Roc runs on a stack of its own, and a hosted
   function that waits switches back to the thread, which runs other calls and resumes this one
   when its future is done. Roc, the platform's API and apps don't change.
4. A Zig host on Zig's `std.Io`, whose evented backends would do the same switching: unfinished as
   of Zig 0.17.1, and a rewrite of the host (tokio, hyper, rustls, tokio-postgres) besides.

**Choice.** 3, with `corosensei`, keeping tokio, hyper, rustls, tokio-postgres and deadpool.

- Roc runs on threads of its own (`server/host/src/coroutine.rs`), as many as the machine has
  cores, or `--roc-threads` (`ROCX_ROC_THREADS`). Each runs a small executor with the server's tokio
  runtime entered, so the sockets, timers and tasks a call's futures make are tokio's, driven by its
  threads, as they were when a blocking thread waited on them.
- Each call is a coroutine with an 8 MiB stack (Roc's default, as the threads had; reserved, not
  committed) above a 256 KiB guard; a thread keeps 64 stacks to reuse. New calls wait on one queue,
  and whichever of Roc's threads is free starts the next. A call never moves after that: compiled
  code may keep a thread-local's address across a call, so a call resumed on another thread could
  read that thread's state. No coroutine is `Send`.
- `hosted::wait` pauses: in a call, it hands its thread the future (on the call's own stack), which
  the thread polls, and resumes the call when it is done; outside one, it blocks, as before. A panic
  while polling is the call's error, as it was.
- What the host keeps per call in thread-locals is taken out while the call is paused and put back
  when it resumes: its context (`CALL`: the request, the stream, the deadline, the transaction,
  rooms, the actor's turn), Roc's (its list of allocations, the page whose render keeps what it
  makes, why it crashed or failed), the guard's jump target (`guard.c`'s `current`, through
  `rocx_guard_swap`), the render (`RENDER`) and its sockets (`tcp.rs`'s table). The guard is set
  inside the coroutine, so a crash's `longjmp` stays on the call's own stack. Roc's compiled code
  keeps no thread-locals of its own (`nm` of the test app: only Rust crates' and the host's).
- `send!` waits on the stream's channel through `wait` (it was `blocking_send`). `Tcp` is tokio's
  sockets and tokio-rustls (it was blocking `std::net` and `rustls::StreamOwned`), with the same
  timeouts, reads and errors.
- Requests, streams, actor turns, channels' calls (`in_roc`), the platform's start and the
  background loops all start through `coroutine::run`, which the async side awaits as it awaited a
  `JoinHandle`. `--blocking-threads` is gone: given, it stops the server, saying what to use.
- Unchanged: time limits (a call is cut off at its next wait past its deadline), the short `Mutex`
  sections (never held across a wait), the platform's Roc API, the glue. A call that logs when the
  log's queue is full still blocks its thread until there is room: rare, a brake on whatever floods
  it, and the writer is a thread that never waits on Roc.

Measured as `examples/echo/bench.sh` does (bombardier, `--opt=speed`, 10 s a level), master
(7bb8926) and this branch each built from a clean checkout, run interleaved (master, coroutines,
master, coroutines) on one busy machine: 10 cores, load average 14–25, Docker busy beside them.
The sleeping rows are an echo that waits 10 ms or 100 ms (`Live.next!`) before it answers.

| POST /echo                   | master: run 1 / run 2                 | coroutines: run 1 / run 2           |
|------------------------------|---------------------------------------|-------------------------------------|
| 1 connection                 | 14.9k / 11.0k req/s, p50 55 / 71 µs   | 15.3k / 15.8k, p50 54 / 53 µs        |
| 16                           | 56.9k / 62.6k, p50 215 / 206 µs       | 72.8k / 74.0k, p50 183 / 187 µs      |
| 64                           | 61.5k / 65.7k, p50 0.94 / 0.90 ms     | 58.2k / 62.5k, p50 0.86 / 0.77 ms    |
| 256                          | 67.5k / 63.7k, p50 3.4 / 3.7 ms       | 77.7k / 57.6k, p50 2.6 / 3.2 ms      |
| the server's threads         | 89–229                                | 22                                  |
| waits 10 ms, 2,000 conns     | 38.0k / 37.4k, p50 44 / 47 ms         | 46.7k / 45.7k, p50 35 / 37 ms        |
| waits 100 ms, 2,000 conns    | 10.1k / 10.0k, p50 202 / 202 ms       | 18.7k / 17.6k, p50 103 / 104 ms      |
| threads, 2,000 waiting       | 1,036                                 | 22                                  |

Roc's own time per echo (`server-timing`) is 30–50 µs in both. With 100 ms waits, master's 1024
threads answer in two rounds; the coroutines answer every connection in one. At 256 connections and
more, some connects are reset in both (macOS's listen queue holds 128).

The tests (server/test, on two Roc threads): 2,000 requests that each wait a second answer in about
a second; 2,000 open `events!` streams, and a request beside them answered at once; 600 calls
interleaved (waits then crashes, pages that wait in a memo, in an `<Errored>`'s read and in a hole,
refusals, TCP, crashes that don't wait), each answered as its own, nothing left allocated; a stack
overflow that ends the process, saying so. The whole suite passes built `--opt=dev` and
`--opt=speed`, and the test app built for `arm64musl` runs in an Alpine container.

**Costs.** Roc that computes for long without an effect can't pause: the calls already on its
thread wait for it (new ones go to the other threads). A paused call keeps its stack, though only
the pages it touched cost memory: with 2,000 calls paused the server was about 150 MB resident,
where 1,024 blocked threads were about 130 MB. Profilers and debuggers see calls on stacks of their
own rather than threads. A stack overflow hits the guard and ends the process, as a thread's did;
a handler on an alternate signal stack says so on stderr first (`rocx server: a call into Roc
overflowed its stack (8 MiB): the process ends`, in the log's format).

**Why.** Waiting is most of what a server's calls do, and a waiting call should cost a stack, not a
kernel thread. This does it without Roc knowing, and keeps tokio, hyper and tokio-postgres, which
work. Zig's evented I/O isn't there yet; a Zig host would have bought the same thing later, for a
rewrite.

**Reversible:** yes, entirely: it is the host's. `coroutine::run` back to `spawn_blocking` and
`wait` back to `block_on` is the old model; apps and the platform's Roc never saw the change.

## D-028 Values in memory: `Kv`

**Context.** The dev mailbox kept email in host memory (a `Mutex` around a queue in `outbox.rs`)
or in Postgres, with its own three host functions. guard (rate limits), presence and otel (state
that needn't be written to Postgres), and any app with a cache or a one-time token (OAuth's state)
want the same thing: values by key, in memory, some for a while. The host's value store
(`memory.rs`) only grows: it is for what the platform keeps at start.

**Options.**
1. A key-value store in the host: one map behind one lock, with deadlines and a size limit; a Roc
   module over it with typed values (JSON) and a few atomic operations.
2. Actors whose state isn't written (`keep: Memory`): one message at a time per key, but a call of
   its own and JSON both ways for every read.
3. One owner thread and a channel per call (as actors' mailboxes are), to avoid the lock.

**Choice.** 1. The "no mutex" line of D-021 was about actors, not a rule for the host (the user,
2026-11-22): each operation is a few map and tree steps with nothing awaited while the lock is
held, so a call waits microseconds at most, and every operation is atomic without more machinery.

```roc
Kv.Opts := { ttl_ms : U64 ?? 0 }                                  # 0: until the server stops
Kv.ListOpts := { keep : U64, ttl_ms : U64 ?? 0 }

Kv.set! : Str, value, Kv.Opts => {}                               # value: Json.Encodable
Kv.get! : Str => Try(value, [NotFound, BadValue(Str)])            # value: Json.Parseable
Kv.delete! : Str => {}
Kv.take! : Str => Try(value, [NotFound, BadValue(Str)])           # read and forgotten: once
Kv.add! : Str, value, Kv.Opts => Try({}, [Exists])                # only if nothing is there
Kv.increment! : Str, I64, Kv.Opts => Try(I64, [NotAnInteger(Str)])
Kv.push! : Str, value, Kv.ListOpts => {}                          # newest first, the newest `keep`
Kv.list! : Str => Try(List(value), [BadValue(Str)])
```

- A value is JSON in the host; Roc encodes it and decodes it as its reader's type. A counter is a
  JSON number, so `Kv.get!` reads it as an `I64`.
- A time to live is set by `set!` and `add!` (replacing the old one); a new counter's or list's
  starts when it is made, and later `increment!`s and `push!`es don't move it, so a counter counts
  in windows.
- Expired entries go at the next operation, oldest deadline first. Past `--kv-max-mb` (64, or
  `KV_MAX_MB`) the least recently read or written go, never the one just written.
- Memory only: a restart forgets everything. What must last goes in Postgres.
- The host's crate defines `main` for Roc, so `cargo test` can't run `kv.rs`'s unit tests; they
  are compiled alone (`rustc --test`) by the server's tests.

- The dev mailbox keeps its last 100 messages under `rocx:mail` (ids from `rocx:mail:id`), database
  or not, so a restart forgets them (the user, 2026-11-22: "always KV for this dev thing"); the
  host's outbox (`outbox.rs`, three host functions) is gone, and `rocx/0003` drops `rocx_outbox`.

**Why.** It is the smallest thing every one of those uses needs, it is Roc-shaped (typed values,
`Try` for what can be missing), and it replaces the outbox's special host functions. One instance of
an app means one store. **Reversible:** yes.

## D-029 Drag and drop in the browser

**Context.** A planner moves an item to another day by dragging it, a kanban board a card to
another column. Handlers were `on:<event>={…}` for any event, so `on:dragstart` and `on:drop`
could be written, but a drop never came: the browser drops only on an element whose dragover's
default is prevented, and the runtime prevented a default only for `submit` and a key's handler.
Firefox starts no drag without data on it. And dragenter and dragleave fire again each time a drag
crosses a child, so "a drag is over this column" took a counter of the app's own.

**Options.**
1. Leave it to the page's JavaScript (`Browser.call!`): the runtime would know nothing of drags.
2. A generic way to prevent any event's default (`on:dragover.prevent`), and nothing more: every
   drop target writes `on:dragover.prevent={|| {}}`, sets no `dropEffect`, and counts its own
   enters and leaves.
3. The browser's drag and drop as events, with the runtime doing what a drop target always needs:
   accepting the drag, data on it for Firefox, enter and leave as the element's own. Plus `.prevent`
   for any other default (a link's click).
4. A pointer-events drag of the platform's own (`solid-dnd`, `dnd-kit`): it works by touch, but it
   is a library's worth of code (hit testing, scrolling, a ghost, keyboard sensors) for every page.

**Choice.** 3.

```rocx
(dragging!, set_dragging!) = create_signal!("")

<li draggable="true" on:dragstart={|| set_dragging!(card.id)} on:dragend={|| set_dragging!("")}>{card.title}</li>

<ul class:over={over!()} on:dragenter={|| set_over!(Bool.True)} on:dragleave={|| set_over!(Bool.False)}
	on:drop={|| move!({ card: dragging!(), day })}>…</ul>

<a href="/next" on:click.prevent={go!}>Next</a>      # Html.on_prevent: the default prevented first
<ul on:drop.value={|text| add!(text)}>…</ul>        # the text dropped from elsewhere
```

- An element with a drop handler is a drop target. The runtime prevents its dragenter's and
  dragover's default (how the browser is told), sets `dropEffect` to a move (a copy or a link if
  the drag allows only that), and prevents its drop's (a dropped link or file doesn't open). Where
  there is no drop handler, nothing is accepted, and no drop comes.
- An element's dragenter handlers run when a drag comes over it from outside, its dragleave
  handlers when the drag leaves it for outside, is dropped on it, or ends (a listener on the page):
  as mouseenter and mouseleave, counted from the browser's enters and leaves, not once per child.
- An element with a dragstart handler gets data on its drag (`application/x-rocx`), so Firefox starts
  one. What is dragged is the app's, through closures as usual: a signal the dragstart handler sets,
  the drop handler reads. `on:drop.value` is the drag's `text/plain`.
- `.prevent` on any handler (`["onp",…]`) prevents the event's default before it runs, so a
  component takes over a link's click (client-side navigation, when it comes, needs it).
- The server renders nothing for any of it; inside `<NoHydration>` rocx refuses a handler, as before.

**Touch.** A touch user gets what the browser gives: Safari on iPad and iPhone turns a long press
into a drag and drop, which works here; many other mobile browsers start no drag from a touch. An
app gives touch and
keyboard users another way to move a thing (the docs' planner has a menu on each plan), which it
needs for keyboards anyway. A pointer drag of the platform's own is option 4, not done.

**Changed from Solid, where the browser forces it.** Solid binds `onDragEnter` as the browser fires
it; here dragenter and dragleave are the element's own, since that is what a drop target's
highlight needs and the browser has no `dragenter` that doesn't bubble. A drag source the drop
removes (its row moved to another list) gets no dragend handler run, its box gone with its row:
the drop handler clears what dragstart set. **Reversible:** yes; `.prevent` stays either way.

## D-030 Actions without a form, every submission, optimistic values

**Context.** From a drop, a planner sends the move to its endpoint and shows it at once, before the
server answers; keeps it while the request is on its way; gives way to the server's data when it
succeeds, with no frame of the old position; puts it back when it is refused, saying why; and
lets two moves be on their way at once. The platform had `use_submission!` (D-018): the latest
submission of a form, and only a form. A handler could send an endpoint (`Endpoint.send!`), but one
that waits on the server drops its writes and runs again once the answer is in, so a signal written
before the call didn't show until the server answered: no optimistic UI.

**Options.**
1. Solid 2.0's `createOptimistic` / `createOptimisticStore`: a value whose writes, made inside an
   action, show at once and are undone when the action's transition ends; the action is a generator
   that holds the transition open across `yield`, and refreshes its source before it ends. A rocx
   handler that waits doesn't pause: it runs again from the top, so its optimistic write would be
   applied twice (`moved(board!(), …)` over a board already moved) or need its first run's writes
   kept and its reads replayed, and the "transition" would be the runtime's guess.
2. Solid Router's actions, as its docs write optimistic UI: `useAction(action)` sends it,
   `useSubmissions(action)` lists every submission, and the optimistic value is derived, the
   server's data with the inputs of the submissions on their way applied. A submission stays pending
   until the router's revalidation after it is in. Pure, so a handler that runs again is no problem;
   each request is its own submission; a refusal undoes it by not being pending.
3. A signal the app writes before sending and writes back on a refusal, by hand: every app gets the
   flicker on success wrong (the old data shows between the answer and the refreshed read).

**Choice.** 2, in Solid Router's names, on both platforms; Solid 2.0's names where they fit
(`isPending` is its own decision).

```roc
import pf.Router exposing [use_action!, use_submissions!]

Router.use_action! : Endpoint(context, arg, result) => (arg => {})               # from a handler
Router.use_submissions! : Endpoint(context, arg, result) => Submissions(arg, result)
Submissions.all! : Submissions(arg, result) => List(Sent(arg, result))
Submissions.Sent(arg, result) : { id : U64, pending : Bool, input : Try(arg, [NoInput]), result : Try(result, [NoResult]), error : Try(Server.Problem, [NoError]) }
Submissions.pending! : Submissions(arg, result) => Bool                            # any on its way
Submissions.pending_inputs! : Submissions(arg, result) => List(arg)                # what those on their way sent
Submissions.clear! : Submissions(arg, result), U64 => {}                           # forgets one, from a handler
Time.sleep! : U64 => {}                                                            # the server's: a call that waits on purpose
```

```rocx
moves = use_submissions!(Api.post_planner_move({}))
move! = use_action!(Api.post_planner_move({}))
week = Api.get_planner({})
plans! = create_memo!(|| {
	server = Endpoint.get!(week)
	moves.pending_inputs!().fold(server, moved)          # the server's, with the moves on their way
})

<section on:drop={|| move!({ plan: dragging!(), day })}>…</section>
<p class:saving={moves.pending!()}>…</p>
<For each!={moves.all!().keep_if(|sent| sent.error.is_ok())} keyed={|sent| sent.id}>
	{|sent!, _| <p>{why(sent!().error)} <button on:click={|| moves.clear!(sent!().id)}>Dismiss</button></p>}
</For>
```

- `use_action!`'s function, called in a handler, queues a submission with the handler's writes
  (`Host.submit!`), so a handler that waits and runs again sends it once. It is sent as
  `Endpoint.send!` sends one: the arg as JSON, `x-rocx-submission: 1`, `accept: application/json`.
  Nothing waits for it. Called anywhere else it fails; on the server no handler runs.
- The runtime keeps every submission to an endpoint's URL, forms' (D-018) and actions' alike,
  oldest first, until forgotten. `use_submissions!(endpoint)` reads them; `all!` gives records, not
  methods, so `keep_if` and `<For>` take them (Roc's list functions take pure functions).
- A submission answered 200 has the page's reads read again: every computation that read a GET
  (`Endpoint.get!`, `read!`) has its answers cleared and runs again, its last value shown meanwhile,
  and the submission is done in the run of the last one to have its answer (or fail, or go). What
  reads both the data and the submissions sees the server's new data and the submission's end in
  one flush, so the optimistic value gives way with nothing of the old in between; meanwhile
  `is_pending!` of a memo read again is true, so a page may dim what is about to change. A refusal, or no
  answer, is done at once: its input is no longer applied, and its `error` says why.
- Several may be on their way; each is answered on its own. An input still on its way is applied to
  data read again for another, which may already have it: applying one should be idempotent (a
  plan's day, not one more).
- On the server there are no submissions (`all!` is a plain form's flash, as `use_submission!`'s
  is, or none) and nothing is applied, so the page the browser hydrates is the one rendered.
- Submissions are kept by URL, so an endpoint with params in its path has a list per URL: what
  varies goes in the body.

**Changed in D-018.** A form's submissions are a list now: the latest is what `use_submission!`
reads, as before, and an earlier one's answer, which was dropped, is kept on it. A form's result
reads the page's reads again too (Solid Router revalidates after every action), where an app called
`refresh!` itself before. `Submission.clear!` forgets the latest, as before; `Submissions.clear!`
one by id.

**Changed from Solid, where Roc forces it.** `useSubmissions` gives objects with getters; `all!`
gives records as they are now (a computation reading them runs again when one changes), and
`clear!` takes an id. No `createOptimistic`: the optimistic value is a memo over the server's data
and `pending_inputs!`. No `.with` and no `retry` yet; revalidation is of every GET the page read,
with no keys to narrow it.

**Found while building.** A read that isn't in yet unwinds its computation by a JavaScript throw,
which skips Roc's drops: what the run made before the read is lost, and revalidation makes such
runs common. The host's own part is fixed (`js_fetch` answers "waits" and `js_waits` throws once the
host has let go of the request's text), `Endpoint.read!` passes its header as text rather than a
list, and `Endpoint.remote`'s `run` captures nothing; the rest is the app's to keep in mind: read
first, and name the endpoint outside the computation. (Since 2026-11-22 the host frees what an
unwound run made, once the runtime has let go of what it handed over: web/README.md, Waiting. An
app need not order its reads for it.) In an app's browser copy an endpoint has no
types (its route file isn't there), so a submission's result nothing reads stays a type variable,
and the compiler can't specialize `all!` for it (`--specialize=yes`, as the site builds: a missing
`parser_for` in a small app, a crash of the fork's compiler in the site's): the app says the
submissions' types (`moves : Submissions(Move, Str)`). The docs' planner needed a slow endpoint:
`Time.sleep!` exposes the host's sleep, which pauses the call and holds no thread (D-027).
**Reversible:** yes.

## D-031 An element that moves glides

**Context.** A card dragged from Monday's list to Tuesday's leaves one `<For>` and enters another:
two rows, one dropped and one made, and nothing moved the eye from where it was to where it is.
Within one keyed `<For>`, a row put elsewhere jumped there, and the rows a new one pushed jumped
too.

**Options.**
1. The View Transitions API (`document.startViewTransition`): the browser snapshots the page,
   applies the change, and cross-fades, with `view-transition-name` pairing elements. It freezes the
   whole page for the transition (no input meanwhile), names must be unique on the page, Firefox
   has it only in its newest releases, and a row that comes and one that goes at the same moment
   can't each keep their own transitions (`transition:in`, `transition:out`).
2. Svelte's `animate:flip` (reorders within a keyed each) and `crossfade` (`send`/`receive`, an
   element leaving one list flying to where its pair arrives): two directives and a pair of
   functions an app makes.
3. FLIP in the runtime, for elements that ask: measured before the flush first changes the page's
   structure and after it, the difference played back with `element.animate`; and a page-wide `key`
   that makes an element leaving one place and one arriving in another the same one.

**Choice.** 3: Svelte's two ideas in one attribute, the runtime's.

```rocx
<li key={card!().id} transition:move={Transition.glide}>…</li>   # Transition.glide: 250 ms, easing out
<li transition:move={Transition.glide.ms(400)}>…</li>               # glides as its list changes around it
```

- `transition:move={…}` (`Html.transition(Move, …)`; computed, `transition_of`) marks an element as
  one that glides; only the transition's pace counts (`ms`, `delay`, `easing`). `key={…}`
  (`Html.key`, or `Html.key_of` when it reads an accessor, as a row's item is) names it on the page.
- Before a flush first changes the page's structure (a row comes, goes or moves; a part switches; a
  hole's markup is made anew), the runtime reads where each such element is; after the flush, one
  that moved plays from there to its place with `translate` (so its own `transform` stays its own).
- One with a key that appears in the flush as one with the same key went (taken away, or on its way
  out) glides from the other's place: neither plays its transition in or out, and the other, if it
  was leaving, goes at once. Rows reordered within one `<For>`, and rows pushed by one that comes
  or goes, glide too: the same element measured twice.
- An element inside another that glides moves with it, not on its own as well. A glide playing is
  stopped, and the next starts from where the element is seen. With `prefers-reduced-motion:
  reduce`, nothing glides. Hydrating and mounting measure nothing, and the server renders nothing for
  it: hydration is unchanged.

**Limits.** It translates; it doesn't scale an element from its old size to its new one. One
inside a box that clips (`overflow: auto`) was clipped as it crossed into another; since then (the
browser gaps, 2026-11-22) it is lifted for its glide, fixed above the page with a hidden stand-in
in its place, and put back when it lands, unless a box that makes fixed elements its own (a
`transform`) holds it. Each flush that
changes structure while something glides costs two layout reads. A text change alone (a card's
title growing) moves nothing. **Reversible:** yes.

## D-032 rocx is Roc

**Context.** rocx, the transpiler and the command (`rocx build`, `check`, `lint`, `routes`, `fmt`),
was JavaScript on Node: `bin/rocx.mjs` and `src/*.mjs`, about 3,800 lines. Node was the only tool
an app needed besides Roc, and the plan was to ship rocx on npm. On 2026-11-21 it was to stay
JavaScript until its output settled; on 2026-11-22 the user asked for it in Roc now, for one binary
to distribute, and for speed.

**Options.**
1. Keep the JavaScript and ship it on npm: every user needs Node.
2. The JavaScript as one executable (Node's single executable applications, `bun build --compile`):
   50 to 100 MB, and no faster.
3. rocx in Roc on basic-cli: one native executable a target, each built from one machine
   (`roc build --target=…`; static for Linux).
4. rocx in Roc on a platform of the repo's own: more to keep, for nothing basic-cli lacks.

**Choice.** 3, on basic-cli 0.28.1, with the Roc fork the repo builds with (the Justfile pins it).

- `src/` is rocx (renamed `rocx-cli/` on 2026-11-22, below): `main.roc` (the command), `Transpile.roc`, `Styles.roc`, `Routes.roc`,
  `Stories.roc` (with `catalog.html`, the catalog page, embedded), `Remap.roc`, `Format.roc`,
  `Commands.roc` (`check`, `lint`), `Build.roc` (`rocx build`), `ServerOnly.roc` (its warning where
  the browser's copy reaches what only the server has), and the helpers they share: `Text`
  (JavaScript's whitespace, string literals and sort orders, columns in UTF-16 units), `Fs` (Node's
  path rules, a directory's entries sorted as Node gave them), `Value` (JSON).
- `bin/rocx` is built from it whenever its Roc changes: `server/build.mjs`'s `rocxBinary()`, which
  every script and test uses (`--opt=speed`; `ROCX_OPT=dev` for a quick build while working on it).
- rocx finds the repo from where it is (`bin/..`): `web/platform`, `web/start.js` and
  `web/runtime.js` are read when it runs, so a change to them needs no new rocx. A release can
  embed them (`import "…" as x : Str` works on this compiler).
- The tests didn't change: `src/rocx.mjs` exports the old functions' names, each a call of the
  binary (`rocx internal`, its arguments and answer as JSON), so the JavaScript's tests test the Roc.
- Port, not redesign: every output is what the JavaScript wrote, byte for byte. Checked on 18 runs
  over the repo's apps, its package examples and a large app of its own (`build` with and without
  `--client` and `--dev`, `routes`, `lint`, `fmt --check`, `check`), dev and `--opt=speed` builds
  alike; and, while porting, on 35,000 mutated `.rocx` files (code, errors, lines and columns), 400
  compiler reports for `check`, and every `<style>` here.

Measured on the same files, interleaved, the machine loaded by other work (medians):

| | JavaScript | Roc (`--opt=speed`) | |
|---|---|---|---|
| `rocx build site --client` | 587 ms | 240 ms | 2.4× |
| `rocx build` of a large app | 508 ms | 232 ms | 2.2× |
| `rocx routes site` | 94 ms | 17 ms | 5.7× |
| `rocx lint site web/test/app` | 87 ms | 17 ms | 5.1× |
| starting, and nothing else | 65 ms | 8 ms | 8× |

`bin/rocx` is 5.9 MB for macOS (arm64); the same Roc cross-builds to 3.5 MB static Linux binaries.

**Moving to it.** Whatever ran `node bin/rocx.mjs …` runs `bin/rocx …`: outside the repo too (an app
of its own, a script), where `bin/rocx.mjs` is gone ("Cannot find module"). A Node script gets the
binary's path from `server/build.mjs`'s `rocxBinary()`, which builds it if it is missing or stale; one
that imported `src/transpile.mjs`, `src/routes.mjs` and the others imports the same names from
`rocx-cli/rocx.mjs`.

**Costs.** An optimized rocx takes about a minute and a half to build (a dev build, seconds); the
binary rebuilds when `rocx-cli/` changes. Roc keeps more words than JavaScript (`module`, `packages`,
`where`, `platform` can't be names), and the compiler's bugs are rocx's now too. basic-cli has no
file watcher (rocx needs none: `site/serve.mjs` watches). The repo's own scripts, its tests and the
testing package's helpers are still JavaScript on Node; an app no longer needs Node to build. Each call
the repo's JavaScript makes starts the binary (a few milliseconds), so a script that asks many
times asks once (`callMany`, as the site's build does for its route files).

**Why.** One small executable for each platform, built from one machine, and faster than the
JavaScript at everything it does.

**Reversible:** yes. The JavaScript is in the history (up to the commit that removed bin/rocx.mjs), and the tests still call
rocx by the JavaScript's names (`rocx-cli/rocx.mjs`).

**Renamed (2026-11-22):** rocx's Roc moved from `src/` to `rocx-cli/`, since the repo holds much more than rocx (two platforms, packages, the site). `bin/rocx` stays where it is. A script outside the repo that imported `<repo>/src/rocx.mjs` imports `<repo>/rocx-cli/rocx.mjs`.

## D-033 Plugins: what a package adds to an app

**Context.** A package could give an app pure Roc, and components, which `rocx build` copies into
both halves. Anything that needed the server platform (a route, a table, a job, a background loop,
a page only for development) was copied into the app by hand (push's README had six steps for
it), or stayed in the platform (jobs, cron, the jobs page, email), against D-025's rule that a
platform module stays only if it needs the host or the transpiler. The app's side was decided on
2026-11-21 (`spike/plugins/CLIENT-API.md`): plugins listed in `App.program({ plugins: [...] })`,
each plugin with an options type of its own, two routes at one path stopping the server at start,
a plugin reading its documented environment variables unless the app passes a function.
`spike/plugins/DESIGN.md` specified the rest.

**Options.**
1. As designed: `rocx build` copies a package's `server/*.roc` into the app's `Generated/<package>/`
   and rewrites imports of them.
2. A package whose modules need the server platform names it in its header, as an app does; the
   browser's half sees its `browser.roc`, a second header beside `main.roc` listing the modules the
   browser can compile.

**Choice.** 2, and the plugin type as designed, with the changes below.

- Roc resolves `import email.Email` in an app's own `.roc` files (`main.roc`, `Jobs.roc`), which
  rocx doesn't write, only through the app's header; and a module that imports `pf.X` must be in a
  package that names the platform. A package may name the platform its app names (the same file,
  by a path of its own; checked on the pinned compiler), and one directory may hold two package
  headers. So one name in the header (`admin`) gives the server's half all of a package and the
  browser's half what it can compile. Copying would make the import work only in the files rocx
  writes, and one line mean two things.
- `rocx build --client` names such a package's `browser.roc` in the browser's `main.roc` (or leaves
  the package out when it has none), and warns at the line of a page that imports one of its
  server's modules, as it does for `pf.Db`.

```roc
Plugin.Value(ctx) := {
    name : Str,
    routes : List(Plugin.Route(ctx)) ?? [],     # behind the app's middleware, before its own routes
    early : List(Plugin.Early) ?? [],           # /__rocx/…, before the app, under --dev or --debug
    migrations : List(Plugin.Migration) ?? [],  # recorded as <plugin>/<name>
    calls : List(Plugin.Call) ?? [],            # <plugin>.<name>, each run in a call of its own
    loops : List(Plugin.Loop) ?? [],            # <plugin>.<name>, in the background
    starts : List(Plugin.Start) ?? [],          # after every migration; an Err stops the server
    checks : List(Plugin.Check) ?? [],          # <plugin>.<name>, once, in the background; logged
    needs : List(Plugin.Need) ?? [],            # Env("NAME"), Database, Plugin("other")
}
```

- `App.Config` has `plugins : List(Plugin.Value(handed)) ?? []`. Generated/App answers a request,
  inside the app's middleware, with the first plugin route whose method and path match (`[param]`
  segments as the app's; GET answers HEAD; `*` any method; `request.route` the plugin's pattern),
  or else with the app's routes; and hands the platform each plugin's other parts
  (`Plugin.running`) and the app's own routes (`Routes.claims`, which rocx build writes).
- At start, before anything is applied, every problem at once stops the server, a line each: a
  name that isn't lowercase letters, digits and `-`, or is used twice; a call, loop or check not
  named `<plugin>.<name>`; an early path outside `/__rocx/`; two routes at one method and path (the
  app's and a plugin's, or two plugins'; `*` meets every method, and params' names don't count); an
  environment variable unset or empty; `Database` without `--database-url`; a plugin not in the
  list; needs in a circle. Then the plugins are put in the order their needs say (the list's order
  breaking ties), their migrations applied after the platform's and before the app's, their starts
  run, and the log says what each added (`rocx plugins: push: 3 routes, 1 migration, 1 call`).
- What a plugin's own Roc needs from the platform: `Plugin.isolated!` (run one of its calls, as a
  job is run), `Plugin.stopping!` (a loop's cue), `Plugin.keep!` and `kept!` (what it keeps at
  start, for its modules: the host's store, which `Kv`'s evictions never touch).
- A fixture plugin package (`server/test/fixture`) is in the server's tests: a route with the app's
  context, an early path, a table, a call that crashes, a loop, a start, a check, a need; and an
  app whose plugins break every rule (`server/test/refused`), whose whole message is checked.

Different from the design:
- No copying of `server/*.roc` (above).
- No `files` and `scripts` yet (push and Audio need them), and no `jobs`, `crons` or `actors`:
  jobs and cron leave the platform as a plugin of their own (D-034); actors stay (D-021).
- `calls` and `starts` are new: what jobs need (a job run isolated; the kinds kept, and jobs a stop
  cut short queued again, at start).
- Early paths are anywhere under `/__rocx/`, not under `/__rocx/<plugin>/`: the dev mailbox keeps
  `/__rocx/mail`, which packages/testing reads. `under` is a list (`[Dev, Debug]`): the mailbox's
  JSON answers under either. The host has no `--test`.
- A plugin generic in the app's context is a function even with no options (`Acme.plugin({})`):
  a value can have only one type.

**Moving to it.** An app on `App.program` changes nothing: `plugins` is `[]` unless it lists some. A
program written by hand (not `App.program`) adds `plugins: []` and `routes: []`; with plugins, it
lists `plugins.map(Plugin.running)` and answers their routes with `Plugin.respond!` (as
server/test/app does).

**Costs.** A plugin package names the server platform by a path, so the app must name the same
file: a platform from a URL (a bundle) would need the copying after all. A list of records holding
functions has crashed `--opt=speed` builds before; the test app builds and runs optimized with none,
one and three plugins, and its tests pass optimized (`ROCX_TEST_OPT=speed`).

**Why.** Installing is a line in the header and one in `plugins`; what a plugin adds is checked
before the first request and listed in the log; and the jobs, the jobs page and email can leave the
platform (D-034, D-035). **Reversible:** yes.

## D-034 Jobs and cron are a package, and a plugin

**Context.** D-025's rule: a platform module stays only if it needs the host or the transpiler.
`Job`, `Cron` and the schedules' loop made no host calls; the workers used three general ones
(`db_listen!`, `stopping!`, `isolated!`) and the kinds were kept in the host's store. What tied them
to the platform was `program`'s `jobs` and `crons` and the start (the kinds kept, the schedules
checked, jobs a stop cut short queued again, the workers started). The user decided on 2026-11-22
to move jobs and cron, the jobs page with its look, and email into the ecosystem, once plugins
(D-033) could carry them.

**Choice.** `packages/jobs`, a plugin on the platform's general effects.

```roc
Job.Options := {
    jobs : List(Job.Handler),                                       # App.jobs: the kinds rocx build finds
    crons : List({ name : Str, schedule : Str, job : Str, input : Str }) ?? [],   # Cron.every(…)
    workers : U64 ?? 4,
    retry_ms : U64 ?? 1000,
}
Job.plugin : Job.Options -> Plugin.Value(ctx)

program = App.program({ …, plugins: [Job.plugin({ jobs: App.jobs, crons: [Cron.every("0 3 * * *", Jobs.nightly, {})] })] })
```

- `Job` and `Cron` keep their API (`Cron.every` takes a kind by its shape, so `Cron` doesn't import
  `Job`), and `Job` gains `plugin`, `Options`, `Handler`, `kinds!` (what the plugin runs, which the
  jobs page reads) and `changes` (the live topic the workers say on what they start and finish).
  `Calendar` comes too (cron's dates). The workers, the schedules' loop and what they keep at start
  are the package's own modules.
- **Where schedules go: the plugin's options.** They are the plugin's: it checks them at start and
  runs them. `App.program` has no `crons` any more, and `App.jobs` (Generated/App, when the header
  names a package with `Job`) is the kinds the app's modules define. An app that defines jobs and
  names no jobs package is a build error saying what to add.
- The plugin: the table (`jobs/0001_jobs`), `workers` worker loops and the schedules' loop (none
  without a database), a call each job runs in (`jobs.run`), and a start that keeps the kinds and
  schedules, checks every schedule (a bad one stops the server), and queues again the jobs a stop
  cut short. `Job.enqueue!` without the plugin listed is a `JobErr` saying so.
- The platform gained what a plugin like it needs: `Db.listen!`, `Db.connected!`, and D-033's
  `Plugin.isolated!`, `stopping!`, `keep!`, `kept!`. It lost `program.jobs`, `program.crons`, its
  `Job`, `Cron` and `JobsPage` modules, and `--job-workers` and `--job-retry-ms` (each now an error
  naming the plugin's option).
- **Existing databases keep working.** The table keeps its name (`rocx_jobs`), its notifications
  (`rocx_jobs`) and its topic (`rocx:jobs`), which packages/testing reads too. The plugin's migration
  makes it only if it isn't there (`create table if not exists`, its indexes likewise), so a
  database the platform migrated records `jobs/0001_jobs` and changes nothing. On a new database the
  platform's `rocx/0001` makes only `rocx_actors`, and `rocx/0002` brings up to date a queue its old
  first migration made (inside `to_regclass('rocx_jobs') is not null`). Tested twice: a server test
  that lays down the platform's old migrations word for word and a queue, then starts; and by hand,
  master's own server migrating a database and queueing jobs (one keyed for later, one failed, one
  done, one left running), then this one starting on it: the running one queued again and run, the
  keyed one cancelled by its key, the rest where they were, and the schema the same as a new
  database's.
- The jobs page moves to `packages/admin`, with its look (`AdminHtml`), since it reads `Job`:
  `packages/admin` names the server platform now, and lists its tables admin's modules in
  `browser.roc` for the browser's half (D-033). The dev mailbox keeps a copy of the look in the
  platform until email moves (D-035).

**The jobs page, a plugin (the same day).** `JobsPage.plugin({ at, guard })` lists the page
in the app's plugins: `JobsPage.Options(ctx, out) := { at : Str ?? "/admin/jobs", guard :
Middleware(ctx, out) }`. `guard` has no default, so a page that acts on the queue is never public
because an option was left out: without it the app doesn't compile ("This record is missing the
field: guard"; a server test checks the message). A request at `at` passes the app's middleware,
then `guard` (what it hands on is ignored), then the page; it needs the jobs plugin
(`needs: [Plugin("jobs")]`). It claims every method at its path (`*`; the page answers GET, HEAD
and POST, and 405 to the rest), not a GET and a POST route: two closures that each capture the
guard crash a server built with `--opt=speed` as it starts, with the pinned nightly and the fork
alike (`test/compiler-bugs/two-guarded-routes-opt-speed`, reduced to 36 lines); back to two routes
once the compiler is fixed. `JobsPage.respond!(request, { mount })` stays for an app that mounts it
itself. And one look: `Look` (on no platform, so the browser's half can still show the tables
admin) has the rules every admin page shares, part by part, and the helpers; the tables admin's
stylesheet and `AdminHtml`'s (the server's pages) put their own rules among them. The copy the
tables admin kept, and the test that held it to the platform's, are gone.

**Moving to it.** What an app outside the repo changes:
- Its header names the package (`jobs: "…/packages/jobs/main.roc"`), and `admin:
  "…/packages/admin/main.roc"` for the jobs page; its modules import `jobs.Job`, `jobs.Cron` and
  `admin.JobsPage` instead of `pf.Job`, `pf.Cron` and `pf.JobsPage` (route files too).
- `App.program({ …, crons: [...] })` becomes `App.program({ …, plugins: [Job.plugin({ jobs:
  App.jobs, crons: [...] })] })`; an app with no schedules drops `crons: []`.
- `--job-workers N` and `--job-retry-ms N` become `Job.plugin({ …, workers: N, retry_ms: N })`; the
  server refuses the flags, saying so.
- A program written by hand drops `jobs` and `crons`, and lists
  `Job.plugin({ jobs: [Job.handler(kind), …], crons })` in its plugins (`Plugin.running`).
- A database it has keeps its queue: nothing to do.
- The jobs page: `JobsPage.plugin({ at: "/admin/jobs", guard: Middlewares.admin })` in its plugins,
  in place of the route file that mounted it (`routes/admin/jobs/+server.roc` goes); or the route
  file stays, importing `admin.JobsPage`.

**Costs.** One more line in `main.roc` and one in the header. A plugin package names the server
platform by a path, so the app names the same file (D-033). The dev mailbox's look is in two places
until D-035. **Why.** The platform keeps what needs the host; jobs are Roc on general effects, and
now an example of a plugin that brings tables, loops, a call and a start. **Reversible:** yes.

## D-035 Email is a package, and a plugin

**Context.** D-025's rule, and the user's decision of 2026-11-22 (D-034). Email was the platform's
Roc on its general effects: `Email` (MIME), `Smtp` (on `Tcp`), the dev mailbox (`Outbox`, on `Kv`
since D-028), drawn with the platform's copy of the admin look. What tied it to the platform: the
host's `--smtp-url` and `--mail-from` (settings the Roc read), the mailbox's paths answered in
`respond_for_host!` before the app, and the SMTP check as one of the platform's background loops.
D-025 kept it there until plugins could carry dev-only paths and checks (D-033).

**Choice.** `packages/email`: `Email`, `Smtp` and `Mailbox`, and a plugin.

```roc
Email.Options := { from : Str ?? "", smtp_url! : ({} => Str) ?? (reads SMTP_URL) }
Email.plugin : Email.Options -> Plugin.Value(ctx)

program = App.program({ …, plugins: [Email.plugin({ from: "Acme <hello@example.com>" })] })
```

- `Email.send!` and `Email.Message` are as they were. Who mail is from is `from`, or `MAIL_FROM`;
  where it goes is `smtp_url!`, by default `SMTP_URL` from the environment, read when the server
  starts (a plugin reads its documented variables unless the app passes a function: the user,
  2026-11-21). The plugin's start keeps both (`Plugin.keep!`) for `send!`; without the plugin,
  `send!` reads the environment itself.
- The dev mailbox is the plugin's early paths: `GET /__rocx/mail` and `/__rocx/mail.json` under
  `--dev` or `--debug`, `GET /__rocx/mail/[id]` and `POST /__rocx/mail/clear` under `--dev`, as
  before (packages/testing reads the JSON unchanged). Its mail is in `Kv` under `email:mailbox`.
- The SMTP check is the plugin's check (`email.smtp`), logged once the server has started; a server
  that doesn't answer doesn't stop the app.
- **The look:** the mailbox depends on packages/admin (`Look`, `AdminHtml`), which depends on
  packages/jobs. Another split (the look in a package of its own) would make an app that wants
  email and no admin pages name nothing more: it doesn't today either, since a package's
  dependencies come with it. One look in one package is the simpler thing to keep.
- The platform lost `Email`, `Smtp`, `Outbox`, its copy of `AdminHtml`, `Calendar` and `Base64`
  (email uses packages/crypto's), the mail check, and `--smtp-url` and `--mail-from` (now errors
  naming the variables). It keeps nothing about email.

**Moving to it.** What an app outside the repo changes:
- Its header names the package (`email: "…/packages/email/main.roc"`); its modules (and route
  files) import `email.Email` instead of `pf.Email`.
- Its plugins list `Email.plugin({})` (with `from` if it says who mail is from in the app), for the
  dev mailbox and the check.
- `--smtp-url URL` and `--mail-from ADDRESS` become `SMTP_URL` and `MAIL_FROM` in the server's
  environment (which the server already read), or the plugin's options; the server refuses the flags.
- Log lines change: `rocx mail (kept, not sent: no --smtp-url): to …` is
  `email (kept, not sent: no SMTP_URL): to …`; the check's lines are `email.smtp: …`.
- The mailbox's paths and JSON are the same.

**Costs.** An app names one more package and lists one more plugin. **Why.** The platform keeps what
needs the host; email is Roc on `Tcp` and `Kv`, and now the example of a plugin with dev-only paths
and a check. **Reversible:** yes.

## D-036 A control-flow component's function child is effectful

**Context.** `<For>`'s row and `<Show>`'s narrowed child (`{|post!, index!| …}`) were typed pure
(`(() => a) -> Html`). rocx writes a component as `Html.component(|| X.view!(…))`, a value, so a
component inside a function child was fine; but rocx calls the platform's own `<For>` and `<Show>`
directly (`For.view_with_keyed!(…)`), an effect, so neither could sit inside a function child: a
`<For>` in a `<For>`'s row, or in a `<Show>`'s child, was a type error about generated code.
Three of the six examples (journal, quiz, notes) met it, and split the part into a `view!`
component of its own, or showed it under a `Bool` and read an accessor with a default.

**Options.**
1. Leave it, and say so in the docs.
2. Have rocx wrap a nested `<For>` or `<Show>` in `Html.component`, as it wraps components.
3. Type the function child effectful (`=>`): it already runs inside the effectful thunk that
   makes its row or its part (`row : () => Html`, `Html.shown_with`'s `() => Html`).

**Choice.** 3: what makes markup that is alive (rows that come and go, parts that switch) is
effectful, as a component's `view!` is.

```roc
For.PropsKeyed(a, k) := { …, children : (() => a), (() => U64) => Html }
For.PropsUnkeyed(a) := { …, children : (() => a), U64 => Html }
Show.PropsWith(a, e) := { …, children : (() => a) => Html }
```

- A pure child still type-checks where an effectful one is wanted, so no app changed: the docs
  site and every example build as before.
- The child runs when its row or part is made, owned by it, so a nested `<For>` or `<Show>` (or
  anything a component's body may do) is the row's and goes with it. `web/test/app/Nested.rocx`
  renders both nestings on the server, hydrates them strictly and follows their signals.
- examples/journal's reactions put their `<For>` back inside their `<Show>`'s child.

**Why.** The rule was a leftover of the types, not something the runtime needed, and it pushed
apps into components or defaults that exist only to get around it. **Reversible:** yes, but code
that nests would break.

## D-037 Generated/Api is the app's contract; the router owns the handlers

**Context.** `Generated/Api.roc` was what an endpoint *is* and what *runs* it at once: each entry
was `Endpoint.local(method, url, handler)`, so Api imported every route's `+server.roc` module.
Nothing a route imports (a store, a job, an actor) could import Api: that was an import cycle.
Four example apps met it. board, quiz and uptime published on their channels through a
hand-written `Endpoint.remote("CHANNEL", url)` with a hand-copied type, where a typo in the path or
the type compiled and published to nowhere; notes mounted its MCP server from `main.roc`, because a
route couldn't import Api. The browser's copy had the same root: it was an untyped
`Endpoint.remote`, so apps spelled out memo, submission and read types by hand, and `roc check`
passed where the wasm build then failed ("This decodes a record whose full set of fields is not
known"). Yet most callers never need the handler: `publish!` reads the URL, and `get!`/`read!` on
the server already go through the route by URL. Only the router (`respond!`, `stream!`,
`channel!`) and `Endpoint.run!` (an in-process call that skips the middleware: packages/mcp's
`McpHttp`, the calls page) run it.

**Options.**
1. Leave it: hand-written contracts where a module below the routes needs one.
2. Keep the handlers in Api, and let a route module's dependencies take the endpoint as an
   argument (passed down from the route): every caller threads it, and an actor or a job has no
   route to be given it by.
3. Api the contract alone (method, URL and types, copied from each handler's annotation), the same
   in both copies; the handlers bound to it in a module of their own, which the router imports.
4. As 3, with `run!` going through the router by URL and skipping the middleware, so no module of
   handlers is needed. But each route's middleware hands its handler a context of its own type, and
   one function can't take them all: the call would be JSON in, JSON out, untyped.

**Choice.** 3.

```roc
# Generated/Api.roc: imports pf.Endpoint, pf.Server, and what the types name; no route file
get_b_board : { board : Str } -> Endpoint(context, {}, Board.Data)
get_b_board = |params| Endpoint.remote("GET", "/b/${Server.encode_segment(params.board)}")
channel_b_board : { board : Str } -> Endpoint(context, {}, Channel(Str, Board.News, []))
channel_b_board = |params| Endpoint.remote("CHANNEL", "/b/${Server.encode_segment(params.board)}")

# Generated/Handlers.roc, the server's alone: each contract bound to its handler
get_b_board = |params| Endpoint.bind(Api.get_b_board(params), |request, context, {}| BBoardServer.get!({ request, params, context }))

# web/platform/Endpoint.roc (and the server's copy)
bind : Endpoint(c, a, r), (Server.Request, c, a => Try(r, Refusal)) -> Endpoint(c, a, r)
```

- **The contract.** `rocx build` copies each handler's types from its annotation: its params (from
  the path), its body (POST, PUT, PATCH; `{}` for the rest) and its answer; for `channel!` its
  `Channel(who, message, said)`, for `events!` what it streams. The `context` stays a type
  variable: only the handler cares. Api imports the modules those types name (the route file's
  imports, their paths rewritten from `Generated/`, as the route modules' copies have them), and
  no route module, so any module may import it: a store, a job, an actor, a route.
  `Api.openapi` is written from these typed values as before.
- **Every handler is annotated.** `rocx build` refuses one that isn't, or whose annotation it can't
  read (a type alias for the whole, a `where` clause), at its line, saying what to write. It
  refuses a POST, PUT or PATCH handler whose record has no `body`, a type the route file defines
  itself (Api imports no route file: the type goes into a module of its own), and two route files
  whose types name different modules by one name. 107 of the repo's 111 handlers were annotated; the other
  four are now.
- **The router owns the handlers.** `Generated/Handlers.roc` binds each contract to its handler
  (`Endpoint.bind`), so the compiler checks that they agree; `Generated/Routes.roc` answers with
  Handlers' endpoints, and gives a channel's hooks Api's. Handlers imports every route file, so a
  module a route file imports can't import it: `main.roc` can, a plugin can, and so can a module
  only they import. It is what `Endpoint.run!` runs (Api's contract has no handler; `run!` on one
  crashes, saying to use Handlers'). `main.roc` is the place to mount what sits in front of the
  routes and runs their handlers, as examples/notes mounts its MCP server; a route file that runs
  another route's handler binds it itself (`site/routes/calls/+server.roc`).
- **The browser's copy is the same contract** (step 4 of the plan, landed). A component that sends
  the wrong body or reads the answer as anything else compiles in neither copy, and `rocx check`
  points at its `.rocx` line in both (the browser's copy's `.rocx-client` says where its app is, so
  a report about the copy follows the marker back to the app's file). So a type a route's
  annotation names must compile in the browser: when the browser's copy reaches a module that
  imports what only the server has (`pf.Db`) through Api, `rocx build` stops, at the route's
  handler, naming the type and the module. Measured on the site, the eight examples, `test/e2e`,
  `web/test/app` and the packages' example apps: one type moved (quiz's `Sets.Summary`, in a module
  that imports `Db`, is `Draft.Summary`).
- **A narrow cycle remains.** A module that defines a type a route's annotation names and imports
  Api (or imports a module that does) is a cycle, which Roc refuses without naming either module.
  `rocx build` says so at the import of Api, naming the route and the type, and says to move the
  type into a module of its own: uptime's `News.Said` became `Report.News`.
- The workarounds went: board's `News.channel`, quiz's `Rooms.channel` and uptime's `News.channel`
  publish through Api; notes' tools run Handlers' endpoints; the memo, submission and read
  annotations tasks, quiz, notes, board and journal had for the browser are gone (top-level reads
  with a doc comment kept theirs).

**Why.** The contract is what both halves and every module agree on; what runs it is the server's
business, and only two things need it. With the types copied from the handler, a typo in a path or
a type is a compile error, in both halves, and an app writes each type once. **Reversible:** yes;
apps would lose the imports of Api below the routes, and annotations would be optional again.

## D-039 A value prop is a getter

**Decided** 2026-11-22. The design, with the generated code before and after and the options
weighed, is `spike/reactive-props/DESIGN.md`.

**Context.** A component's value prop (`<Shows label={word!()} />`) had Roc's type, so it couldn't
be a getter. rocx wrote `Html.component_with(|| { label: word!() }, Shows.view!)`, and the props were
read before the component ran. In a hole, a change made the component anew, its signals with it.
Outside a hole the props were read once. Two examples met it and worked around it:

- examples/board: a stack's label inside a `<Show>`, made once, empty;
- examples/quiz: the podium showing the lobby's scores.

Solid's props are getters: the child is made once, and each place that reads a prop tracks it.

**Options.**
1. One accessor of the whole props record (`props! : () => { label : Str }`), reads rewritten to
   `props!().label`.
2. A getter per prop, as Solid's props object has: the caller passes `label: || word!()`, and rocx
   rewrites the child's reads of `label` into `label!()` where they are written.
3. Keep values, and make the child anew when one changes (`component_with` in a hole).

**Choice.** 2. Option 1 has three problems:

- a read of one prop runs, and tracks, every prop's expression (a markup hole made anew, an effect
  applied again, when another prop changes);
- one prop that waits holds every read;
- Roc fills no `??` defaults in a record a thunk returns.

Option 3 loses the child's state.

```roc
# Written, unchanged:
Shows := [].{
	view! : { label : Str } => Html
	view! = |{ label }| <button>{label} {clicks!().to_str()}</button>
}
<Shows label={word!()} />

# Generated:
view! : { label : () => Str } => Html             # `max : U64 ?? 5` becomes `max : (() => U64) ?? (|| 5)`
view! = |{ label: label! }| … Html.text_of(|| label!()) …
Html.component(|| Shows.view!({ label: || word!() }))
```

- **Where a read runs**, as rocx writes it (`rocx-cli/Getters.roc` finds the views and writes their
  types and patterns; `Transpile.read_code` rewrites the reads):
  - in a hole, a computed attribute or a getter rocx writes: there, as a computation, tracked;
  - in a lambda known to be an effect's (`|| …`, a handler, a function child, one given to a `!`
    function, or bound to a `!` name or field): when it runs;
  - in the component's body: once, untracked;
  - in another lambda, which may be pure (`.keep_if(|i| i.owner == me)`, a helper bound to a plain
    name): read where it is made, by a wrapper, `(|me| |i| i.owner == me)(me!())`. A root inside
    another root's run names its own (`me_2`).
- **A view that names its whole record** (`|props|`) reads `(props.label)()`: `props.label()` would
  call a method of its nominal type. An accessor named through a prop (`left!={clock.left!}`) is
  `|| (clock!().left!)()`.
- **Route views**, too: Root passes a page's `params`, a layout's `meta` and `params`, and the error
  page's `status` and `problem` as getters. So D-040 (client-side navigation) may keep a page or a
  layout across a change of its params, if the user chooses that.
- **What isn't a getter:**
  - accessor props (`label!`), `children`, and the platform's own components' props;
  - a pure `view`'s props: values. A call that passes one read from what changes becomes a hole of
    its own, rendered anew.
  - a file's own function component (`answer! = |{ said }|`) is rewritten only when the file uses
    it only as a tag. Called directly too, it keeps values, and `rocx build` warns at a tag that
    gives it one read from what changes.
- **`<For>` rows and `<Show>` function children run untracked** (Solid's `mapArray`, `untrack`): a
  computation flag in `runtime.js`. A read that waits still runs them again.
- **`Html.component_with` goes.** D-044's browser-copy rewrite unbinds a getter's binding as
  `params: _`.
- **Examples:** board's stack is back in the tile with a plain `label`. Quiz's `Podium`, `Lobby` and
  `Board` take plain props.

**Why.** Solid's semantics with Roc's syntax. The child is made once and keeps its signals, only
what reads a prop is patched, and no app's source changes, packages' components included.

**Reversible:** yes. It is the transpiler's and the runtime's, so no app's source changes; but code
that relies on a child kept, or on untracked rows, would change behavior.

## D-038 A form's body is read by its endpoint's types

**Context.** A plain form posts urlencoded strings, and `Endpoint.respond!` read them as a JSON
object of strings. So an endpoint that both a plain form and an action (`use_action!`, JSON) post to
had to take a record of strings: examples/tasks' toggle took `{ id : Str, done : Str }` and its add
read the body twice, typed strings for the list and again through packages/forms. A box left
unticked sends nothing, so a record with a `Bool` for it failed to read: examples/notes used two
radio buttons.

**Options.**
1. A form format beside `Json`, type-directed through the same decoding ability (`parser_for`):
   the platform's `FormBody`, as `OpenApi`'s `Schema` is a format of its own.
2. A lenient mode of JSON's decoder for form bodies. `Json` is the compiler's: its formats are a
   closed set (`JsonEncoding`), so this is a change to the compiler.
3. JSON built from the fields by guessing each value's type: `"2"` a number, but a title of `2`
   too.

**Choice.** 1. The rules the user approved:

- a number (`U64`, `I32`, `Dec`, `F64`…) from its text, spaces around it dropped;
- `Bool`: `on`, `true` and `1` are true; `false`, `0` and empty are false; missing (a box left
  unticked) is false;
- the values a field has, in order, as a `List`; a missing `List` is `[]`;
- `Str` stays text (an empty one too); a missing `Str`, or a number missing or empty, is a 400
  naming the field, as is text that isn't the field's type (`the field count needs a whole number,
  0 or more, not "two"`);
- and, as they come with the format: a tag with no payload by its name (a `<select>`); a field a
  non-list has twice, its last value (a hidden default before a checkbox); a field the record lacks,
  let be. A record in a field, a tuple or a dict has no form, and is refused saying so.

JSON is read as before, strictly: only a form's body is read this way.

```roc
# web/platform/FormBody.roc (both platforms; not exposed)
FormBody.parse : List({ name : Str, value : Str }) -> Try(a, Str) where [a.FormBody.Readable]

# web/platform/Endpoint.roc
Endpoint(c, a, r) :: { method, url, run, form : [Typed(List({ name : Str, value : Str }) -> Try(a, Str)), Untyped] }
Endpoint.remote : Str, Str -> Endpoint(c, a, r) where [a.FormBody.Readable]           # Api's contract: the reader, made here
Endpoint.bind : Endpoint(c, a, r), handler -> Endpoint(c, a, r)                        # keeps the contract's reader
Endpoint.local : Str, Str, handler -> Endpoint(c, a, r) where [a.FormBody.Readable]   # an endpoint outside the routes: here too
Endpoint.local_json : Str, Str, handler -> Endpoint(c, a, r)                          # none: a form's fields as strings
Endpoint.form_of : Endpoint(c, a, r) -> (List({ name : Str, value : Str }) -> Try(a, Str))

# web/platform/Submission.roc, Submissions.roc: the endpoint's reader, given by use_submission(s)!
Submission.of : Str, (List({ name : Str, value : Str }) -> Try(a, Str)) -> Submission(a, r)
```

- **Where the reader is made.** A where clause naming both formats
  (`[a.FormBody.Readable, a.Json.Parseable(…)]`) crashes the compiler (test/compiler-bugs/
  two-formats-one-where). So `respond!` and `Submission.input!` ask for `Json.Parseable` alone,
  and use the reader the endpoint was made with. `Endpoint.remote` makes it: `Generated/Api` gives
  each contract its handler's types (D-037), in the browser's copy as on the server, so the
  reader is typed in both; `bind` keeps it for the router. `Router.use_submission!` and
  `use_submissions!` give it to the submissions, so a form the runtime sent, or a plain form's
  flash, is read in the browser as the server reads it (`input!`, `pending_inputs!`, `all!`).
- **`local_json`.** A function generic in its arg as JSON alone can't call `local`: packages/mcp's
  `McpHttp.function`, and the type witnesses it hands `OpenApi`, use `local_json`, whose endpoints
  read a form, if one is ever posted to them, as strings, as before.
- **Built in two steps.** The server's half landed first, while `Api` was still untyped in the
  browser's copy; once D-037 typed it, the reader moved onto `remote`, the browser's submissions
  took it, and examples/tasks' toggle and move left their strings (`done : Bool`, `to : U64`).

**Why.** One endpoint, one type, for every way it is sent; and the rules are the type's, not a
guess. **Reversible:** yes: `remote` and `local` without the reader read strings again.

## D-040 Client-side navigation

**Status.** Proposed (2026-11-22). Nothing is built; the design, with its phases and the questions
it waits on, is `spike/client-nav/DESIGN.md`.

**Context.** Every link is a full page load: a document, the wasm compiled again, the whole page
hydrated again. examples/board opens a card with `?card=12` and a click it takes over, so Back
doesn't close it; an app couldn't switch `?days=` in place; `Router.location!` never changes, so
nothing follows it. Solid Router is the model.

**Proposal.**

- A click on a same-app link (this origin, under the base, a path the app's route table has a
  page for; no modifier key, `target`, `download` or `rel="external"`), a handler's
  `Router.navigate!`, back and forward, navigate in place. A plain `<a>` does, as Solid Router's
  do; `<A>` adds the active state. Anything else is the browser's, as today.
- The browser fetches the page's own HTML document, as the server answers a load (behind its
  middleware, its endpoint reads answered in-process, a redirect followed), or the file `just site`
  wrote, and renders the page from the wasm with that document's answers, regions and head. No new
  server route; on the docs site the document is 2–16% larger with brotli than a JSON of the same
  answers and regions would be. Not an app document of this build (a text 401, a crash, a new
  deploy, no network): the browser loads it.
- The old page stays until the document is in (`Router.is_routing!`). Layouts and the page are kept
  levels, made anew when their file or own params change, or when something they read once in their
  body (the location) changed, which the runtime sees. A change of the query alone is in place, no
  document fetched (`use_search_params!`).
- The runtime keeps history, scroll (restored on back and forward), focus (the start of `<body>`)
  and a live region that announces the new title; prefetches on hover; checks a build id on each
  document. Generated `Root` hands the runtime its route table and the build id
  (`Router.app!`); the host writes the id on the bootstrap.

**Phases.** 1: links, `navigate!`, the whole page made anew, no app changed. 2: kept layouts, the
query in place, `<A>`, `<Navigate>` (needs D-039). 3: prefetch, View Transitions. 4, if measured:
the stylesheet as a cached file, a JSON payload, wasm splitting.

**Reversible:** yes, until apps rely on kept layouts and `use_search_params!`.

## D-041 The host hands over a request as one record, with the connection's address

**Context.** The host called Roc with a request's parts as five arguments (`respond!(method,
target, headers, body, context)`), and dropped the connection's address where it accepted it. So
Roc never knew who connected: packages/guard's `Guard.ip(Direct)` gave no key and limited no one,
`Proxies(…)` couldn't check that a request came through the app's own proxies, and three examples
(journal, uptime, notes) counted by a cookie, a mailbox or everyone at once instead.

**Options.**
1. A field on `Server.Request`, `peer : Str`, and the host's call one record that carries it.
2. An effect, `Server.peer!({})`, read from the call's context (packages/guard's PROPOSALS.md had
   recommended it).
3. A header the host sets (`x-rocx-peer`), removing any a client sent.

**Choice.** 1: a request says where it came from as it says its headers, so a middleware and a test
see it without asking the host, and what else the host comes to know of a request (a scheme, a
request id) goes in the same record without changing the call again.

```roc
# server/platform/main.roc
HostRequest : { method : Str, target : Str, headers : Str, body : List(U8), peer : Str }
respond_for_host! : HostRequest, Str => …                 # the record, and what the server was started with
program.respond! : Server.Request, Str => Server.Response # was Str, Str, Str, List(U8), Str

# web/platform/Server.roc (both platforms)
Server.Request : { method, path, query, headers, body, route, peer : Str }
```

- `peer` is the connection's IP, without its port; an IPv4 client of a dual-stack listener as IPv4
  (`203.0.113.7`, not `::ffff:203.0.113.7`). Behind a proxy it is the proxy's, and guard's `Hops`
  or `Proxies` read past it in `X-Forwarded-For`.
- A GET a page reads as the server renders it, and a channel's checks and hooks, have the page's or
  the stream's address. `Server.request!` gives it back too (the host writes it after the target:
  `GET /about 203.0.113.7`).
- `""` in the browser and for a request made by hand (`Server.from_http`).
- The program's `respond!` is given the `Server.Request` ready-made: `App.program` no longer calls
  `Server.from_http`, and an app that writes its own program takes `|request, context|`.
- packages/guard's `peer` reads it, so `Guard.ip(Direct)` limits by address; the examples' copies
  of `Guard.roc` follow.

**Why.** The host had the address and threw it away; a record keeps the call stable as the host
learns more of a request. **Reversible:** yes, at the cost of the field.

## D-044 A name only `<NoHydration>` used is unbound in the browser's copy

**Context.** The browser's copy of a `.rocx` file drops a `<NoHydration>`'s children, and the imports
only they used. A name only they used stayed: a page whose `params` (or a local, `lang =
params.lang`) is read only inside `<NoHydration>` was an unused variable in the browser's copy. Roc
warned, `roc build` exited 2, and a script that reads that as failure (packages/testing's
`buildForTests`) failed the app. examples/journal read its params in a `<Title>` too, to get round
it.

**Options.**
1. Rewrite such a name where it is bound, in the browser's copy only.
2. Let the browser's build pass on warnings (exit 2): it would hide the app's own warnings too.
3. Leave it, and document it.

**Choice.** 1. rocx compares the two copies: a name the server's copy uses, whose one occurrence
left in the browser's is where it is bound, is rewritten there.

- A field of a record pattern: `|{ params }|` is `|{ params: _ }|`.
- A lambda's parameter: `|props|` is `|_props|`.
- A local definition in a function's body: `lang = params.lang` is `_lang = params.lang`.
- Anything else (a member of a block, which another module may read; a place it can't read for
  certain) is left as it is, and warns as before. The server's copy is never touched.
- Only code counts: a word in a string's text, a character or a comment is no name. (The first
  version read them as code, and rewrote `"Comments, entities, raw text"` in a record to
  `"Comments, entities: _, raw text"` in the browser's copy, so the site's pages rendered
  differently there.)

**Why.** The warning was rocx's doing, not the app's. **Reversible:** yes.

## D-042 `rocx build` finds a collection's files

**Context.** packages/markdown reads a collection from a list of `{ path, source }`, each source a
file imported as text. Every app wrote that list by hand: a new post meant a new import and a new
line, and a forgotten one dropped the post without a word (examples/journal listed nineteen).
Finding files needs the file system at build time, which only `rocx build` has.

**Options.**
1. `rocx build` lists each folder under `content/` in a module of its own, the files imported as
   text; with the frontmatter's type beside them, the module reads them too.
2. The server reads the files when it starts (a host primitive): nothing checked until it runs, and
   the browser can't have them.
3. Leave the list to the app.

**Choice.** 1, as packages/markdown's PROPOSALS.md sketched it.

```
content/posts/Post.roc         # Post := { title : Str, … }.{ parser_for : _ }
content/posts/hello.md
content/posts/2026/later.md
```

```roc
import Generated/Content/Posts

Posts.files      # List({ path : Str, source : Str }), in the order of their paths
Posts.all        # with a type: List(Collection.Entry(Post)), read as the app is built
Posts.get(id)    # Try(Collection.Entry(Post), [NotFound])
```

- A folder's module is named after it (`content/blog-posts/` is `BlogPosts`), a name in lower case
  as a route's directory is; one `.roc` type beside the Markdown at most. `all` crashes on a wrong
  file, which `roc check` reports as the build's error, naming the file.
- A folder that goes takes its module with it; a new file is in it at the next build. `rocx dev`
  rebuilds on a change to one, as on any file of the app.
- The browser's copy has the files too, for a component that reads one.
- With no type, the module has `files` alone, for an app that reads them its own way:
  examples/journal reads `content/en/` and `content/pl/` with one `Post` type and rules of its own.

**Why.** A collection is a folder; listing it by hand was a chore that could silently drop a file.
**Reversible:** yes: an app lists its files again.

## D-043 guard keeps its state in `Kv`, with a compare-and-swap, and names the server platform

**Context.** packages/guard's middleware (`Guard`), with what it keeps between requests (`Kept`, the
rate limits' tallies; `FlagStore`, the flags' overrides), was copied into every app that used it
(journal, board, notes, guard's own example), with tests in two of them keeping the copies the same.
Two things kept it copied. A package couldn't hold the server's modules, which D-033 solved. And
its state was in actors, whose kinds `rocx build` finds only in the app's own files, so a package's
actor was never registered. Actors also cost a message, a call of its own and, with a database, a
Postgres write for every limited request. `Kv` (D-028) has no read-and-write-back, so a tally,
read, changed and written, could lose a hit to another request.

**Options.**
1. `Kv.swap!(key, was, value, opts)`, a compare-and-swap: the host replaces the value only if it is
   still what the caller read. guard's tallies and overrides go into `Kv`, each change a read, the
   package's pure step, and a swap, again on `Changed`. The package names the server platform, with
   a `browser.roc`.
2. Counters (`Kv.increment!` under a key per client and window): no new primitive, but a fixed or
   weighted window instead of guard's token bucket, and its tests' semantics changed.
3. Let `rocx build` find actors in the packages the header names: guard is no longer copied, but
   keeps actors and their costs.

**Choice.** 1.

```roc
Kv.swap! : Str, was, value, Kv.Opts => Try({}, [Changed])   # was and value: Json.Encodable
```

- The host compares the stored text with `was`, written as JSON as `Kv` writes it, under the store's
  one lock; nothing there (or a list) is no match: `add!` puts a first value.
- `Kept`: a limit's tallies under `guard:<limit>/<shard>`, a hit read and swapped, 50 tries before it
  lets the request through with a warning, as a limiter that can't count did before.
- `FlagStore`: the overrides under `guard:flags`, set and reset the same way. They are memory only
  now, so a restart brings back the code's rules (an actor kept them in Postgres with a database);
  a plugin with a table could keep them again.
- packages/guard's `main.roc` names the server platform and exposes `Guard`, `Kept` and `FlagStore`;
  `browser.roc` exposes the logic. Apps write `import guard.Guard`: the examples' copies and their
  copy tests went, and guard's example has HTTP tests of its own (`just test` runs them).

**Why.** guard's logic is unchanged, the copies are gone, and a limited request costs a few map
steps instead of a message and a write. **Reversible:** yes; `swap!` stays useful to anything that
reads and writes back.


## D-045 The database is pluggable: Postgres or SQLite, as the app chooses

**Status.** Proposed (2026-11-22). Nothing is built.

**Context.** Postgres is the platform's one database (`--database-url`). The platform runs one
server an app (one instance), and many apps on one server need no database server beside it:
SQLite in the server's process is a file, with no network between a query and its rows and nothing
to run in development or in tests. examples/plate is such an app. The host asks little of a
database (`server/host/src/db.rs`: a query's rows as JSON, a statement's count, a script, a
transaction's begin, commit and rollback, and listening), so a second backend fits behind the same
calls. What can't be shared is SQL: Postgres's and SQLite's differ, and the SQL is the app's.

**Proposal.**

- **The app picks its database's flavor when it is made, and writes its SQL for it.**
  `App.program({ ..., database: Sqlite })`, `Postgres` by default (every app today). Where the
  database is stays the server's to be told (`--database-url`, `DATABASE_URL`: `postgres://…`, or
  `sqlite:data/plate.db`); a URL of the other flavor stops the server at start, saying which the
  app wants. No SQL is translated, and no app runs on both. `rocx new` asks for the flavor
  (postgres, sqlite, none) when it is built, and writes the program's `database` and a first
  migration in it.
- **A package says which flavors it works with; it may work with one.** A plugin's `needs` gets
  `Postgres` and `Sqlite` beside `Database` (any): the server's start check (`Plugins.unmet!`) says,
  with the rest, "admin needs Postgres; this app's database is SQLite". A package with SQL for both
  asks `Db.backend! : {} => [Postgres, Sqlite]` which to run. A migration may say which flavor it is
  for (`on: Sqlite`; any by default), and the server applies those of its own, so a plugin lists one
  of each under one name. A package without a plugin says so in its README.
- **The host has a backend a flavor** (`server/host/src/db/`: `postgres.rs`, today's `db.rs`, and
  `sqlite.rs`), behind the calls it makes today, chosen at start by the URL's scheme. Another backend
  (libSQL/Turso, which keeps a copy elsewhere in sync) is a file there and nothing else. SQLite is
  rusqlite with SQLite compiled in (FTS5 and JSON with it): WAL, a pool of connections whose calls
  run on threads of their own (they block), a busy timeout. A transaction begins `immediate`, holding
  the write lock from its start, and keeps its connection as a Postgres one does; a statement past
  the call's time limit is interrupted and its transaction rolled back.
- **A parameter keeps its type to the host.** `Db.Value` goes as JSON's text, number, boolean or
  null (today all text): Postgres's backend sends text, as now; SQLite's binds an integer as an
  integer and a `Bool` as 1 or 0. `$1`, `$2`… are parameter names in SQLite too, bound by name, so
  an app writes them in both. `Db.array` is Postgres's (an array literal); SQLite reads a list as
  JSON (`in (select value from json_each($1))`).
- **A row is JSON in both.** SQLite's columns are what each value is (an integer or real a number,
  text a string, null), a column declared `boolean` a JSON boolean, one declared `json` its JSON. A
  boolean SQLite works out (`exists (…)`) is 0 or 1, read as an `I64`. A time is the app's to store:
  milliseconds in an integer (`Time.now_millis!`) is the advice.
- **`Db.notify!(channel, payload)` takes `pg_notify`'s place in SQL.** Postgres's backend runs
  `pg_notify`; SQLite's publishes in the process when the call's transaction commits (never if it
  rolls back), at once outside one. Both reach the topic `db:<channel>` (was `pg:<channel>`), which
  `Db.listen!` hears; on SQLite there is nothing to listen to.
- **Nothing slow in a transaction.** On SQLite one holds every other write back until it ends (on
  Postgres only the rows it wrote), so `Db.transaction!`'s docs say to keep a fetch or a wait out of
  one.
- **The platform's own tables have both flavors** (`rocx_migrations`, `rocx_actors`); the advisory
  lock that makes two servers take turns migrating is Postgres's alone (SQLite's write lock does it).
- **Jobs and cron work on both.** packages/jobs keeps its SQL in one module, each statement in both
  flavors (about 15), and `0001_jobs` in both. On SQLite: times are milliseconds in integer
  columns, now given by Roc (no clock in the SQL); a worker takes the next job with
  `update … where id = (select … limit 1) returning …`, with no `skip locked` (writes take turns, and
  there is one server); a queued job wakes the workers with `Db.notify!`; the kinds are a JSON list;
  `on conflict (unique_key) where state in (…) do nothing` is SQLite's too. `Job.Row` is
  milliseconds already, so the jobs page reads both. Cron's ticker is Roc, and changes only in the
  statement that queues.
- **Plate moves to SQLite**, the example of an app on one: its search on FTS5 (a word's start is
  `word*`), `real` for its amounts (no `::float8` or `::numeric`, which is its README's gap 1), its
  days from a recursive `with`. Its day begins in the profile's time zone, which it asks of Postgres
  (`at time zone`, `pg_timezone_names`); SQLite knows no zones, so `Time` learns them from the host
  (`Time.offset!(zone, at)`, jiff, with the zone data compiled in).
- **The server's tests run on SQLite always, and on Postgres too when `DATABASE_URL` is set**; a
  SQLite test's database is a file of its own in a temporary directory.

**Not in it.** SQL that runs on both, a query builder, two databases in one app, MySQL. admin
(its catalog reads Postgres's own tables) and push stay `needs: [Postgres]` until they have SQLite's
statements.

**Phases.** 1: the SQLite backend, typed parameters, `Db.notify!` and `Db.backend!`, the program's
`database`, migrations a flavor, the needs; the server's test app on both. 2: jobs and cron on
both, the jobs page. 3: `Time`'s zones; Plate on SQLite. 4: the docs (`/platform/postgres` becomes
`/platform/database`). Later: `rocx new`'s question, libSQL/Turso, admin's SQLite catalog.

**Waits on the user.** (1) A SQLite app given no URL: its file at `data/app.db`, made when missing,
so `rocx dev` needs nothing set (recommended), or no database, as a Postgres app given none.
(2) Plate's own diary is in Postgres: copied once into its SQLite file (recommended), or begun
again.

**Reversible:** yes. A Postgres app changes in nothing; packages trade `pg_notify` for `Db.notify!`.
