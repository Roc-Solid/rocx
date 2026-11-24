# Platform decisions

Decisions about Roc Solid's platform APIs: what the server and browser platforms give an app, and
why they give it in that shape. Each entry has its context, the options weighed, the choice, the
API as it landed, why, and whether it can be undone. The server-side APIs are documented in
`server/README.md`, the browser-side ones (components, effects, forms) in `web/README.md`; where
this file and the code disagree, the code is right.

Every entry was checked against a few principles: SolidJS 2.0 parity on the UI side; one server
instance; batteries included, as Rails and Phoenix have them; a few lines of our own over a
dependency; and "would a second app want this?" Nothing goes into the platform that only one app
needs. D-014 to D-016 were deferred: D-014 and D-015 have been built since (D-056, and the
structured logger of 2026-11-21), and D-016's list parameters; the rest were decided on 2026-11-21.

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
  `proxy-authorization` are dropped when the origin changes. One connection per request, no pool
  (since D-056, connections are kept alive, and a proxy is used).

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
off; the docs say so. (Since D-057 it is: a signal ends it where it runs.)

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

**Status.** Built, as D-056 (2026-11-23): `--max-body` (`MAX_BODY`), bytes or KiB, MiB, GiB, 16 MiB
by default. Deferred until then: a request's body was 16 MiB at most (413 beyond), the limit
included. An app that uploads in parts can keep each part within it; another may want larger parts.

**Sketch.** `--max-body BYTES`, default 16 MiB. Streaming a request's body to storage (D-002's other
direction) would make the limit matter less.

## D-015 Structured log lines

**Status.** Built on 2026-11-21 (2bc114f), in another shape than the sketch: `Log.debug!`,
`Log.info!`, `Log.warn!` and `Log.error!` take a message and a record of fields (any
`Json.Encodable`, not a list of strings), every line on stderr (the host's, the platform's, the
app's) is an event with a level, a message and fields, and the format is the program's
(`logs: { format: Auto }`, `Pretty` or `Json`; `Auto` follows `ROCX_LOG`, or the terminal), written
off the request path by a thread of the host's. `Log.line!` stayed, a message alone at info. The
platform's own lines (migrations, plugins, packages/jobs's and packages/email's) kept writing their
details into the message until D-056 gave them levels and fields. Deferred until then: an app may
log one JSON object per event so each field can be filtered; `Log.line!` took text.

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
  only if the set changed (since D-057 it posts the change to the open stream instead, and
  `on_close!` hears `Dropped`); when the stream drops, after 0.5 s, doubled each time to 30 s. Each
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
  survive one). (Since D-057, with a database, timers are rows, and outlive a restart.)

**Why.** Tells and timers need the server to run a kind with no asker, which needs the kinds
registered; once they are, a mailbox per actor is the natural shape, and it orders tells and asks
alike. The runtime is ~300 lines on channels tokio already gives us, over a library whose
supervision and remote actors one server doesn't need.

**Reversible:** the API, with an edit at every call site (`define`'s record, `receive!`'s `me`); the
runtime, freely.

**Since D-066:** a kind is its name and starting state, and what its actors do is its methods
(`Actor.method`), each with its own input and reply; `ask!`, `tell!`, `tell_after!` and `after!`
take a method, and `program.actors` lists methods.

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
needs for keyboards anyway. A pointer drag of the platform's own is option 4, not done. **Since
D-055** a touch or a pen held a quarter second starts a drag of the runtime's own, in these same
events (not option 4's library: no sensors of its own, and the drop targets are D-029's).

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
`transform`) holds it (**since D-055** it scales from its old size too, is clipped as it lands, and
goes to the top layer inside a box that holds fixed elements). Each flush that
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
file watcher (rocx needed none then: `site/serve.mjs` watched; since D-062 rocx is on a platform
of the repo's own, which has one, and `rocx dev` and `just dev` are rocx's). The repo's own scripts, its tests and the
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
(`needs: [Plugin("jobs")]`). Its routes are a GET (which answers HEAD too) and a POST at its path.
For a day it claimed every method (`*`) instead: two closures that each capture the guard crashed a
server built with `--opt=speed` as it started (`test/compiler-bugs/two-guarded-routes-opt-speed`), a
compiler bug fixed upstream, in the fork since 9fcf362c0c. `JobsPage.respond!(request, { mount })`
stays for an app that mounts it itself. And one look: `Look` (on no platform, so the browser's half can still show the tables
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

**Status.** Accepted (2026-11-23), with every recommendation of the design's §17 as the user's
answer: the page's own document (1a), plain `<a>` (2a), the old page kept until the document is in
(3a), a page made anew when its params change (4a), layouts kept where it is safe (5a), the query in
place (6a), back and forward reusing a document under 10 s (7a), focus at `<body>`'s start (8a), the
stylesheet as a hashed file (9a), View Transitions as an app-wide opt-in (10a), prefetch on hover,
focus and touch (11a), and the phases in order (12). The design, with its phases, is
`spike/client-nav/DESIGN.md`. **Wasm splitting** (parked, `spike/wasm-split`) isn't built with it,
but the user expects to want it, so the design keeps a place for it (the design's §18): a page's
code is reached through one step that splitting will fill.

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

**As built.**

- Phase 1's foundation (nav-phase1, 2026-11-23): `Router.app!({ build, dev, routes })` on both
  platforms (`Host.app!`), the first line of `Generated/Root.roc`'s `view!`. `routes` isn't the
  typed list §3.2 sketches but JSON that rocx build writes as a constant (`Root.routes`), so the
  server, which keeps only the build's id, encodes nothing per request: each page in the order
  `Root` tries them, its path (`/lists/[id]`) and its levels from the root layout to the page, each
  its code (the module, §18's id) and the path its file covers; a dev build's stories; the error
  page's code. The build's id (`Root.build`) is FNV-1a, 32 bits, of the app's sources (its `.rocx`,
  the `.roc` rocx didn't write, its content's Markdown), the packages and platform its headers name,
  and the web platform with runtime.js and start.js (`Build.build_id!`). The host writes it on the
  bootstrap (`<script type="module" data-rocx data-build="…" src="/rocx/start.js">`), as
  `renderToString` does. `Router.location!` is a tracked source in the browser, the location the
  page on screen was rendered for (`committed`), so a hole that reads it is live on both sides (it
  carries its comments; it was static). `Router.navigate!`, `navigate_with!` (`Host.navigate!`,
  queued with a handler's writes) and `is_routing!` (`Host.is_routing!`). In runtime.js: `routeOf(path)`
  matches the table, `pageCode(level)` reaches a level's code (at once today), `codeOf(route)` all of
  a page's, and `readOnce` (a location read once, in a component's body) is a hook phase 2 fills.
- **The stylesheet as a file (question 9, moved up from phase 4; branch nav-styles).** With a
  browser's copy (`rocx build --client <out>`, every app of pages), `rocx build` writes the
  stylesheet beside `start.js`, `<out>/static/rocx/styles-<hash>.css`, the hash its bytes' FNV-1a
  (64 bits, 16 hex digits), and `Generated/Styles.roc` gets `href` and a `style` that is
  `<link rel="stylesheet" href="/rocx/styles-<hash>.css">`, the same in both copies and on every
  page of a build (navigation keeps it: an equal node in `<head>`). No new path: the host serves it
  from `--static <out>/static` as it serves `start.js`, and answers a file directly under `/rocx/`
  named `<name>-<16 hex>.<ext>` with `cache-control: public, max-age=31536000, immutable` (`.css`
  is now `text/css; charset=utf-8`); a static copy gets it with `start.js` (site/build.mjs's
  `assets`), and the page's link goes under the base with every other URL (`/rocx/rocx/…` on
  GitHub Pages). A build without a browser's copy keeps it inline. Dev builds use the file too:
  `rocx dev` rebuilds, restarts the server and reloads the page, which links the new name (and
  `--dev` answers `no-store`), so inline would make nothing simpler. Different from the design:
  the file is the browser's copy's, not a plugin's (D-050's files are in the executable and answered
  `no-cache` with an ETag), because the stylesheet is built with the copy, as `start.js` and the wasm
  are, and every server of a page app already serves that directory. On the docs site (`just site`,
  49 documents): the stylesheet is 107.5 KB, 15.8 KB brotli, fetched once; a page's document went
  from 17.5–49.7 KB brotli (median 21.9) to 1.8–33.7 KB (median 6.1), about 15.8 KB less each, and
  so does every navigation's document.
- Phase 1's navigation (nav-phase1, 2026-11-23), in runtime.js, as §3–§12 have it: the click
  listener with §3.1's opt-outs (`clicked`, `ours`; `data-rocx-navigation` `off`, and `explicit`
  taking only an `<a data-rocx-link>`), `popstate`, `navigate(url, { replace, scroll, pop })`
  (Router.navigate! queues it; a submission's redirect calls it unless the visitor navigated since),
  the document's fetch (`documentFor`: `x-rocx-navigate: 1`, eight kept, one under 10 s used again, a
  revalidation emptying them) beside `codeOf` (§18's step), its fallbacks (`appDocument`: not HTML, no
  bootstrap, another build; a failed fetch, a redirect to another site: `location.assign`, or
  `reload` for back and forward), a redirect's address (one adding only a trailing slash is the
  link's), and `commit`: answers and flash seeded, the address pushed, the location committed, the
  root run again in one flush with `arriving` (`reconcileHead`, `<body>` with the document's regions,
  `attributesFrom` for `<html>` and `<body>`, only the attributes the app writes). Then scroll (kept
  per entry in `sessionStorage`, as the click happens: the progress bar's height would move it by
  scroll anchoring), focus, the announcer, `rocx:navigated`, and only then the effects' applies,
  held through the render (`holdingEffects`), as a load's run after `rocx:ready`. Deviations: §8's
  stylesheet swap waits for the new sheets' `load`; the hub keeps a channel whose last subscriber went
  until its reconcile, so the next page's subscriber in the same flush is sent its resync (it never
  was); the base goes on the URLs the runtime writes (`written`), as §12.3 asked. Phase 2's hooks:
  `inPlace`, `remakeRoot`, `afterNavigate`. site.js re-wires its demos' inspectors on
  `rocx:navigated`. runtime.js grew 498 lines over the foundation's, 51.7 → 57.5 KB brotli; the wasm
  carries the route table (the site's, about 6 KB of JSON).
  Tests: web/test/navigation.test.mjs (web/test/nav, a scripted server: 11 tests, each of §15's), the
  site navigated page by page natively and as files under `/rocx/`, byte for byte against the
  document it was rendered from, and server/test's `data-build`.
- Phase 3 (nav-phase3, 2026-11-23): prefetch and View Transitions, as §11 and §5.3 have them. What a
  page needs is one cache entry with one age (`pageFor`: its document and `codeOf`, the levels'
  `pageCode` steps), which a navigation and a prefetch share (§18). A link (`linkOf`, the click's
  rules) is prefetched when the pointer rests on it 65 ms, when the keyboard focuses it (only
  `:focus-visible`: a click focuses its link on the way, and every click would have been a prefetch),
  on `touchstart`, and with `data-rocx-preload="viewport"` as it comes into sight (an
  `IntersectionObserver`, and a `MutationObserver` only while the page has such a link);
  `data-rocx-preload="off"` on it or above it, never. The prefetch asks with `x-rocx-navigate:
  preload` and a low priority; one that fails, or isn't of this build, is dropped. A navigation
  overtaking another aborts its fetch only when it was its own and for another page (with the cache
  shared, a second click on a link in flight waits for it). With `<html data-rocx-transitions>`,
  `document.startViewTransition` there and less motion not asked for, the commit and the scroll run
  in the transition's update. `use_before_leave!` wasn't built then: it needs a hosted call, an event
  Roc can stop and retry, and `beforeunload` for a load (built after phase 2, below). runtime.js grew 126
  lines, 57.5 → 59.1 KB brotli. Tests: web/test/navigation.test.mjs, 4 more (15): a rest of the
  pointer (not a pass), keyboard focus and touch prefetching, the click then asking nothing more; one
  older than 10 s fetched again and a submission's result emptying the cache; `off` on a link and
  on `<html>`, `viewport` once in sight; a View Transition only when asked for and available, never
  with less motion asked for.

- Phase 2 (nav-phase2, 2026-11-23): kept layouts, the query in place, `<A>`, `<Navigate>`.
  - **Levels reuse D-053's keyed part**, as the task asked: no `Html.keyed!` of its own. `Root`
    matches the location in a memo (`Root.route`, a tag a page, its params in it); the root layout is
    the root computation, the document, given `{}` for params and the page's `meta`; below it each
    other layout above the page, then the page, is an `Html.switched` part (the node a keyed
    `<Show>` is) whose case is its key (`Root.key`: its file and its own params, as path parts) and
    whose part `Root.made!` makes. So the runtime has nothing new to key: a `{"t":"show"}` whose
    case changed is made anew, one whose case is the same is kept. The server renders each level
    once, with its comments (`<!--show-->`), so every page's markup has them now.
  - **A layout is given its own params** (its directory's), not the page's. One test fixture's
    layout read its page's param (test/e2e's `posts/+layout.rocx`); it moved under `[slug]`. A
    layout that takes `meta` is given one type of it for every page under it, which rocx build
    checks (`Routes.meta_problems`: a page with none, a record with other fields, a root layout
    taking it with no `+error.rocx`); one that takes none is given `{}`.
  - **Untracked reads, per level.** A part a `<Show>` makes gets `scope.level`, its `<Show>`'s
    computation. Phase 1's `readOnce` hook notes a location read in a component's body or a part made
    once (not inside `untrack!`) on that level, or on the root; a navigation makes a noted level anew
    (`remakeLevels`: its case set to a value none has), and the root only when the root layout read
    it so, or the page on screen is navigated to again (`remakeRoot`). The level is the nearest
    `<Show>` part, an app's too, which is finer than the design's "the layout or the page" and as
    safe. A dev build says which level was made anew (`console.info`, and `notify("remade")`).
  - **Errored, regions, submissions.** `Root`'s `<Errored>` stays around the levels; a boundary
    that showed its fallback before a navigation is tried again once the levels are made, with the
    document's answers, so a failed page's error page gives way to the next. After the flush
    (`afterNavigate`) the page's `<NoHydration>` regions are matched one for one with the
    document's: one that differs takes the document's content (a script inert), which also fills a
    new level's (made empty while the document is `arriving`); with the root kept, the rest of
    `<head>` is reconciled with the document's too (phase 1's `reconcileHead`). Finished submissions
    of endpoints no component on the new page asks for are forgotten. For the byte-for-byte test with
    layouts kept, a class a hole turns on goes where the server writes it, not at the end
    (`Runtime.classInOrder`), and the site's site.js empties its footer's stat as a navigation
    starts (a kept layout's page-script text would outlive its page).
  - **The query in place** (`inPlace`): same path, another query, no level that read the location
    once, no fallback showing: no document, the address pushed (or replaced, or left for back and
    forward), the location committed, one flush. It scrolls as told: a link does unless `noscroll`
    (as §7's board example writes), `Search.set!` doesn't, `set_with!` and `navigate_with!` say.
    A navigation to the page on screen (a link to it) remakes the root from its document.
  - **API.** `Router.use_search_params!({}) : Search` (shared module `Search`: `get!`, `all!`,
    `set!`, `set_with!`; `set!` over phase 1's `Host.navigate!`). `<A>` (shared module `A`):
    `href`, `end`, `active_class`, `class`, `replace`, `noscroll`, `preload`; it renders
    `data-rocx-link`, so `explicit` mode takes it, and rocx gives it the component's scope class as
    it gives an `<a>`. `<Navigate href>`: a module of each platform, the browser's an effect
    calling `navigate_with!(href, { replace: Bool.True, scroll: Bool.True })`, the server's a new
    hosted call, `Host.redirect_page!`, that makes the page a 303 (the render's first redirect, as
    D-019's). GET forms: phase 1's document listener calls `gotForm`.
  - **Apps.** tasks' layout reads the location in a memo and its lists are `<A>`s; journal's
    `lang` is a memo of the location, its server-only regions read it where they render; the site's
    layout reads the path through a `Store`'s selections (D-053), so each part re-renders only when
    what it shows changes and its `Sidebar` (now effectful, getters) keeps its rows within a part;
    board's open card is a memo of `?card=` (its tile a plain link, `noscroll`; closing it
    `Search.set!`), so Back closes it.
  - **`meta` in a memo.** `Root` computes the page's `meta` once a navigation
    (`meta! = Solid.create_memo!(|| Root.meta(route!()))`) and gives the layouts that take it the
    memo's accessor (threaded through the levels when a nested one does), so one place calls
    `Root.meta`.
  - **The docs site's server is built with `--specialize=no`** (site/build.mjs; server/build.mjs's
    `buildApp` takes `specialize`). With levels, its `--opt=speed` build overflowed the 8 MiB stack a
    render runs on, on every page: not recursion, but specializations of `Html.serialize!` into which
    every closure of `Html`'s lambda sets is inlined, the site's every page with them, in frames of
    12.4 MB (six of them; master's build already has one of 1.4 MB there). The memo above leaves one,
    and no shape of `Root` tried (the level as `Html.html_of`) does better, since one dispatcher holds
    every page. Boxy lowering's largest frame is 28 KB, and it renders as fast: the site's 50 pages a
    round, 8 rounds, twice, 386 and 393 ms specialized against 386 and 367 ms boxy on master, 376 and
    369 ms boxy with levels (2.8 ms a page every way); and it builds in about 40 s, not 2 to 6
    minutes. No stack size changed. **Any large app built `--opt=speed` can meet the same growth**,
    since one dispatcher holds every page; the cure is the compiler's (test/compiler-bugs/huge-frame-
    opt-speed, its repro and the numbers). The wasm-split spike needs `--specialize=no` in the
    browser's build for the same reason (spike/wasm-split/REPORT.md), so the flag may become the
    default later; not on this branch. (D-064 made it every app's server's default.)
    The other apps, built `--opt=speed` with levels (largest frame; a render has 8 MiB): plate
    848 KiB, journal 372, notes 192, quiz 132, board 120, uptime 104, tasks 80, test/e2e's app 36,
    and checkboxes, echo, hello and sqlite-vs-turso 8; plate is the nearest, a tenth of the way.
  - **Tests.** test/routes (levels, own params, the meta check), test/e2e (levels' comments,
    `<Navigate>`'s 303), test/stories; web/test/navigation.test.mjs's phase-2 tests on phase 1's
    harness (kept levels and the page a load renders, byte for byte; the query in place; a layout
    read once; `<Navigate>`; a GET form), 19 of 19 with phase 1's and 3's; site/test's navigation
    through every page now checks the layout kept all along, natively and under `/rocx/`. The full
    gate: rocx 121, web and site 115, server 199, packages 50, every example (board 19, journal
    21, tasks 17, …). Sizes: runtime.js +13.5 KB (+2.8 KB brotli); tasks' wasm 8 KB smaller raw,
    0.5 KB larger with brotli.

- `use_before_leave!` (before-leave, 2026-11-23, the user's "let's add use_before_leave too"):
  Solid Router's `useBeforeLeave`, its shape kept.
  - **The API.** `Router.use_before_leave!(|leave| …)`, called in a component (or a computation),
    gives its listener a `Leave` (a module both platforms have, nominal so its methods read as
    Solid's): `to` (a path and query as `Router.location!` writes them, `""` for a load), `from`,
    `options` (`replace`, `scroll`), `delta` (back and forward's distance: Solid's numeric `to`, kept
    beside the path, which Roc can give and an app wants), `default_prevented` (as each listener is
    called, as Solid's spread gives it); `leave.prevent!()` and `leave.retry!(force)`. Three hosted
    calls on both platforms (`before_leave!`, `leave_prevent!`, `leave_retry!`); the server's let go
    of the listener and do nothing else.
  - **Asked as handlers, in order.** The listener is a computation of kind `leave` owned by what made
    it, so it goes with its component (D-017's owner); `navigate` asks each (`mayLeave`) before
    anything else: a link, `navigate!`, `<Navigate>`, a GET form, a submission's redirect, a change of
    the query alone (Solid Router asks for all of them too), back and forward. A hash on the same page
    isn't a leave; another site, or a path no page has, is a load (below). `prevent!` acts at once
    (Solid's `preventDefault`), on the leave being asked only. A listener that waits for the server
    isn't run again when the answer is in (`handle`'s `again: false`): the navigation is decided
    when every listener has run, so a listener decides from what the page has (a dev build warns).
    The tasks example's save is a submission whose redirect is asked too: its listener lets it go
    while the save is pending (`!live.pending!()`), as a Solid app's would.
  - **Retry.** The leaves asked lately are kept by id (64), so a dialog's handler can `retry!` one
    long after: a write, applied when its handler is done and, in a microtask, after the navigation
    it stopped has been decided; with `force`, no listener asked (Solid's `ignore`), else all again.
  - **Back and forward**: the address has changed when `popstate` comes, so each history entry now
    carries an index beside its key (`{ rocx: { key, index } }`, one more for each entry pushed, and
    for the browser's own entry for a hash), `popped` computes the distance, and a leave stopped there
    has the browser go back the other way (`history.go(-delta)`; the `popstate` that makes passed
    over, `restoring`), as Solid Router's `notifyIfNotBlocked` does with its depth. The page never
    changed. A retry goes `history.go(delta)` with the listeners passed over (`forcing`) while the
    page is on the entry it was left from, and navigates to the URL otherwise. An entry the runtime
    didn't index (none it makes) isn't asked about, as Solid's isn't without a depth.
  - **A load** (leaving the site, reloading, closing the tab) can't be held or asked in Roc, so each
    listener is asked ahead of time: its computation runs it as a handler that tracks its reads
    (`probeLeave`: a leave with id 0 and `to` "", its writes dropped, a memo or timer it made let go
    of), again whenever what it read changes (a draft typed into, saved), and `guardUnload` listens
    for `beforeunload` only while one would stop a load: web.dev's advice, since a page listening for
    it may be kept out of the back-forward cache (Firefox's, which the user browses with). The
    browser asks in its own words. A load the runtime starts once the listeners let a navigation go
    (a document of another build, a failed fetch) isn't asked again (`load`'s `asked`, for a second).
  - **Tests.** web/test/navigation.test.mjs, 4 more (23), on an editor page of web/test/nav (a
    draft's listener, a strict guard in a component shown on demand, each telling the page what it
    was asked): a link and `navigate!` stopped (the page, address and history as they were, nothing
    fetched), retried from the dialog, forced past the second listener and asked again; back stopped
    with the address put back, retried back, forward from a page with none, forward stopped; a
    listener gone with its component and its page; `beforeunload` listened for only while the draft
    is unsaved (counted), a reload asking through Chromium's dialog. examples/tasks: the task page's
    `Editor` asks before leaving changes not saved (its own question, "Leave without saving"), and
    a test for it beside the save's. Leave's expects. runtime.js 5523 → 5751 lines, 60.5 → 63.0 KB
    brotli.

- The docs site's page transitions (view-transitions, 2026-11-23): the site's layout has `<html
  data-rocx-transitions>`; its bar and its sidebar are named (`site-bar`, `site-sidebar`; the
  sidebar not below 52rem, where it is above the page and scrolls away with it), so they stay put,
  and site.css fades the rest out in 90 ms and in over 210 ms, rising 6 px. Same keyframes and no
  errors in Chromium and in Gecko (Firefox 160, Zen's). It found a runtime bug: a navigation
  starting before the last one's animation is ready (`updateCallbackDone` comes first, so `await
  runtime.navigate(a); runtime.navigate(b)` did it, as would a quick second click) skips the last,
  whose `ready` rejected unheard (an uncaught `AbortError` in the console); the runtime now hears
  `ready` and `finished`. Tests: web/test's View Transitions test does it (an error without the
  fix); site/test checks the names and that a click's transition animates them with the site's
  keyframes, and its navigation through every page runs with transitions on.

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

**Status.** Built (2026-11-22), with the user's answers: the path is the program's, the examples
are on SQLite, Plate moved without its data. The platform and the host (`db/postgres.rs`,
`db/sqlite.rs`), `Db.notify!` and `Db.backend!` (`[Postgres, Sqlite, None]`: none without a
database), migrations and needs a kind, jobs and cron on both (a test's own jobs woken through
`POST /__rocx/jobs/wake`, under `--dev` or `--debug`), `Time.offset!`, `packages/testing`'s
`testSqlite()`, the docs (`/platform/database`); packages/admin's tables admin on both (SQLite's
pragmas read as Postgres's catalog is; `AdminPage.Effects` has `backend!`) and packages/push on both;
and every example with a database on SQLite: plate, tasks, quiz, board, notes and uptime. Open:
`rocx new`'s question. Turso is D-046.

**Context.** Postgres is the platform's one database (`--database-url`). The platform runs one
server an app (one instance), and many apps on one server need no database server beside it:
SQLite in the server's process is a file, with no network between a query and its rows and nothing
to run in development or in tests. examples/plate is such an app. The host asks little of a
database (`server/host/src/db.rs`: a query's rows as JSON, a statement's count, a script, a
transaction's begin, commit and rollback, and listening), so a second backend fits behind the same
calls. What can't be shared is SQL: Postgres's and SQLite's differ, and the SQL is the app's.

**Proposal.**

- **The app picks its database's flavor when it is made, and writes its SQL for it.**
  `App.program({ ..., database: Sqlite("data/plate.db") })`, the file's path from where the server
  starts (made, with its directory, when missing), so a SQLite app runs with nothing set; or
  `Postgres`, the default (every app today), at `--database-url` (`DATABASE_URL`), with no database
  without one. `--database-url` puts a SQLite app's file elsewhere (`sqlite:/var/lib/plate.db`, a
  test's own); a URL of the other flavor stops the server at start, saying which the app wants. No SQL is translated, and no app runs on both. `rocx new` asks for the flavor
  (postgres, sqlite, none) when it is built, and writes the program's `database`
  (`Sqlite("data/app.db")`) and a first migration in it.
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
- **The examples are on SQLite**, so running one needs nothing beside it: board, notes, plate,
  quiz, tasks and uptime.
- **Plate moves to SQLite** (its data isn't copied): its search on FTS5 (a word's start is
  `word*`), `real` for its amounts (no `::float8` or `::numeric`, which is its README's gap 1), its
  days from a recursive `with`. Its day begins in the profile's time zone, which it asks of Postgres
  (`at time zone`, `pg_timezone_names`); SQLite knows no zones, so `Time` learns them from the host
  (`Time.offset!(zone, at)`, jiff, with the zone data compiled in).
- **The server's tests run on SQLite always, and on Postgres too when `DATABASE_URL` is set**; a
  SQLite test's database is a file of its own in a temporary directory.

**Not in it.** SQL that runs on both, a query builder, two databases in one app, MySQL.

**Phases.** 1: the SQLite backend, typed parameters, `Db.notify!` and `Db.backend!`, the program's
`database`, migrations a flavor, the needs; the server's test app on both. 2: jobs and cron on
both, the jobs page. 3: `Time`'s zones; Plate and the other examples on SQLite. 4: the docs (`/platform/postgres` becomes
`/platform/database`). Later: `rocx new`'s question, libSQL/Turso, admin's SQLite catalog.

**Reversible:** yes. A Postgres app changes in nothing; packages trade `pg_notify` for `Db.notify!`.


## D-046 Turso: SQLite's SQL on Turso's engine, a third backend

**Status.** Built (2026-11-22). `Turso(path)` in the program, `turso:<path>` as a URL, the host's
`db/turso.rs` on `turso_core` 0.8.4, `Db.engine!`, the server's SQLite tests run on both engines,
the docs (`/platform/database`). Its writes go on at once since D-049 (MVCC by default). Open: its
sync to Turso's cloud, its full-text search; a benchmark of the two engines
(`examples/sqlite-vs-turso`).

**Context.** D-045 made the database pluggable and left libSQL/Turso as "another file in
`db/`". Turso has two engines: libSQL, a fork of SQLite's C (its local file is SQLite's, its draw
a replica of a primary in Turso's cloud, written over the network), and Turso Database
(`turso_core`), SQLite written again in Rust, in-process, with concurrent writes (MVCC, beta), sync
to Turso's cloud, vectors, change capture and encryption, before its 1.0 but past its beta warning.
libSQL in-process adds nothing to SQLite here (and its bundled C would clash with rusqlite's); the
Rust engine is the one with something new, and the one to measure against SQLite.

**Decision.**

- **An engine, not a flavor.** Turso's SQL is SQLite's, so a Turso app writes SQLite's SQL, and
  what is SQLite's is its: a package's SQL for SQLite, a plugin's migrations `on: Sqlite`, a need
  `Sqlite` (Turso meets it). `Db.backend!` answers `Sqlite`; `Db.engine! : {} => [Postgres, Sqlite,
  Turso, None]` tells them apart (for what one has and the other hasn't, and for saying which). No
  package changes.
- **The program says `Turso(path)`; the URL picks the engine.** `database : [Postgres, Sqlite(Str),
  Turso(Str)]`. `--database-url turso:<path>` runs a SQLite app on Turso and `sqlite:<path>` a
  Turso app on SQLite (same SQL), so an app is tried on the other without a rebuild; a Postgres URL
  stops either at start, as before.
- **`db/turso.rs` mirrors `sqlite.rs`.** `turso_core` alone (no `turso` crate: its mimalloc would
  take the host's allocator), with `fs`, `json`, `time`, `series`, `uuid` and `percentile`: a file in
  WAL mode, a pool of 8 connections whose calls run on tokio's blocking threads, foreign keys on,
  a 10 s busy timeout, a transaction begun `immediate`, statements prepared once per connection
  (their programs kept by SQL, and used again while the schema holds), a statement past its call's
  time limit interrupted and its connection closed. Parameters and rows as on SQLite (`$1`, a
  declared boolean or json). The backend steps a statement itself: Turso's own loops spin through
  a lock's wait (its IO's `step` does nothing on Unix), so the thread sleeps the delay Turso asks
  for. Errors read as SQLite's (`ConstraintViolation: UNIQUE constraint failed: …`), which
  packages/jobs matches.
- **No CoreFoundation, no C of its own.** turso_core's `localtime` reaches chrono's time zone
  lookup, whose last resort (iana-time-zone) calls CoreFoundation on macOS, and Roc links an app
  against the C library alone: the host patches iana-time-zone (`server/host/patches/`, the same
  API) with one that reads /etc/localtime. `pure-rust-crypto` keeps aegis's C out (Turso's
  encryption is unused), so the musl builds compile no more C than before.
- **What differs is said.** The server holds a Turso file while it runs (an OS lock: no `sqlite3`
  or `node:sqlite` beside it, so `packages/testing`'s `testSqlite()` reads it only once the server
  stops); no FTS5 (examples/notes needs SQLite); MVCC unused (writes take turns, as on SQLite;
  D-049 turned it on).

**Not in it.** libSQL; `begin concurrent`; sync to Turso's cloud; Turso's full-text search and
vectors; `rocx new`'s question offering Turso.

**Reversible:** yes. Nothing that runs on SQLite changes; `Turso(path)` is one tag more.

## D-047 Storage: one package, three backends (S3, files, memory)

**Status.** Built (2026-11-22), with the user's answers: signed URLs are the app's to answer, by a
plugin's route; `memory:` is the host's, not `Kv`; the package is `packages/storage`. The host's
`Blobs` (with the keys under a prefix, for an upload's parts) and `Server.Body`'s `Stored` (the request
record's range and ETag carried with it, so an app may drop a range first, as with S3); the package's
three backends, its plugin at `/__storage`; a multipart object's ETag as S3 makes one, and a part listed
with another's ETag refused, on every backend. The server's storage tests run on memory and a
directory always, and on S3 when `STORAGE_URL` is set.

**Context.** `packages/s3` (D-025) is plain Roc on `Http.send!`: every object is a request to an S3,
so an app that keeps files needs one beside it (rustfs or MinIO in development), and its tests need
one too (`STORAGE_URL`, skipped without). D-045 let an app's database be a file beside it; its
files can be too, and a test's can be in memory.

**Proposal.**

- **One package, `packages/storage`, its module `Storage`**, the API `S3` had (put, get, a range,
  head, delete, multipart, `serve!`, `signed_url!`, `check!`), on a bucket a URL names, its scheme
  the backend: `s3://KEY:SECRET@host/bucket?…` as before; `file:<dir>` (`file:data/uploads`, from
  where the server starts, made when missing); `memory:` (`memory:<name>`, a bucket in the server's
  memory, gone when it stops: for tests). `S3Err` stays what S3 refusing is; `file:` and `memory:`
  fail with `StorageErr` (or `NotFound`). The S3 protocol and its signatures are internal modules.
- **It names the server platform** (as jobs and email do), so a bucket needs no effects handed in
  (`Storage.from_url(url)`), and it has a plugin (below). The browser's half doesn't see it.
- **The host keeps objects for `file:` and `memory:`** (`host/src/blobs.rs`, the platform's `Blobs`):
  put (written to a file beside it, then renamed: a crash leaves no half object), get, a range, head,
  delete, and compose (parts joined in order: a multipart upload's end), each under a root
  (`file:<dir>` or `memory:<name>`). An object's content type and ETag (its MD5, as S3's for a single
  put) are kept beside it (`<dir>/.storage/…`, hidden; in the map for memory). A key with `..`, an
  absolute path or an empty segment is refused.
- **`serve!` answers with a stored object** for `file:` and `memory:` (`Server.Body`'s `Stored`), as
  it answers with a `Forward` for S3: the host sends it as it is, never through Roc, with its length,
  type and ETag, a range (206, or 416), and 304 for a browser that has it (`If-None-Match`).
- **Signed URLs are answered by the app** for `file:` and `memory:`: `Storage.plugin({})` adds the
  route `/__storage/<key>` (GET, HEAD, PUT), which checks the URL's expiry and its HMAC-SHA256 (of
  the method, the key and the expiry) before it serves or keeps the object; `signed_url!` makes them,
  at the app's public URL (`Env.public_url!`). The secret is the bucket URL's (`?secret=…`), or else
  one the host draws for the root when the server starts (its URLs end with the process). A PUT is a
  request's body: 16 MiB at most (a larger file is a multipart upload, from the server).
- **Tests run on every backend**: the server's storage tests on `memory:` and `file:` always, and on
  S3 when `STORAGE_URL` is set.

**Not in it.** Listing a bucket's keys (S3 has it; the package never did), versions, other
providers' APIs (GCS, Azure), a bucket shared by two servers on `file:` (one instance, D-045).

**Phases.** 1: the host's `Blobs` and `Stored`. 2: `packages/storage` (the rename, the backends,
`serve!`). 3: the plugin and signed URLs. 4: the server's tests on each backend; callers, docs.

**Reversible:** yes; an app changes `s3.S3` for `storage.Storage` and drops the effects it handed in.

## D-048 Rows by index, what an element shows, and a flush that scales: virtual lists as a package

**Status.** Built (2026-11-23) for examples/checkboxes, a million checkboxes shared live (the
user's ask: "we will need virtual lists on framework side"). The platform: `<Repeat>`,
`on:viewport` (`Html.Viewport`), and the flush's heap; `packages/virtual`'s `<VirtualList>` and
`Rows`; the docs (/components, /ecosystem/virtual, /examples/checkboxes).

**Context.** A list of a million rows can't be a `<For>`: it walks its whole list on every change,
and the page would hold every row. A virtual list renders the rows that show and moves them as the
box scrolls, which needs two things rocx didn't have: rendering a range of rows without a list
behind it, and knowing what of a box shows (a handler was given one string, the target's value: no
scroll position, no size). And at that scale a third thing broke: a grid whose 2,560 boxes read one
signal put 2,560 computations in the flush, which sorted them all to take each one (O(D² log D)): a
scroll step took 173 ms, a change from the server 30 ms.

**Proposal.**

- **`<Repeat count!={n!()} from!={first!()}>{|index| …}</Repeat>`**, Solid 2.0's: a row per index
  from `from!` (0 unless it says), with a fallback while the count is 0. It is the platform's (a shared
  module, `Repeat.roc`), built on `Html.each` with each row keyed by its index, so the server renders
  it and hydrating adopts it as it does a `<For>`, and nothing in the host or the runtime changed for
  it. As the range moves, only the rows that come into it are made; a kept row's index doesn't change,
  so it has nothing to re-run. The child is effectful (D-036).
- **`on:viewport={|view| …}`**, a synthetic event as `on:frame.ms` is: the handler is given an
  `Html.Viewport` (`top`, `left`: how far the element is scrolled; `width`, `height`: what shows inside
  its borders; whole pixels) once the element is on the page, then each time it scrolls or changes size
  (a scroll listener and a ResizeObserver, taken off with the owner's cleanups), at most once an
  animation frame and only when one of the four changed. The server measures nothing: a component
  renders a first view both agree on. rocx writes `Html.on_viewport(…)` (`["view","viewport",id]`); it
  takes no modifier, isn't `<Window>`'s or `<Document>`'s, and is refused in a `<NoHydration>`.
- **The flush takes the oldest of what waits from a heap** (`Pending`: a set beside a binary heap by
  id, a deleted one passed over when it comes up), for what is dirty and the effects due alike: log D
  to take one. The order is the same (oldest first).
- **`<VirtualList>` is a package** (`packages/virtual`, D-025's rule: nothing in it needs the host):
  `count` rows `row_height` high, in a box of its own that scrolls, rendering those its view shows and
  `overscan` (4) more each side, `first_height` (800) pixels' worth before it is measured, and
  `on_view!` for the app (a grid's width). It writes its view only when the range of rows changes.
  `Rows.shown` is its arithmetic, plain Roc. A list higher than browsers let an element be (Firefox
  caps it at about 17.8 million pixels) is drawn scaled in 10 million: the box's scroll maps onto the
  rows' whole height, and the rows that show are placed so the one at the box's top is where it should
  be.

**Measured** (examples/checkboxes in Chromium at 1920 by 1080, 2,560 boxes on the page, each flush
timed): a change from the server 30 ms → 2.5 ms, a scroll of five rows 173 ms → 8.5 ms, a click
39.5 ms → 3.6 ms. The heap is most of it; the rest is the page's: a count that skips chunks never
changed, and a column count written only when it changes (a write runs every reader, a change or not:
written on each scroll, it re-ran every box's holes).

**Not in it.** Rows of their own heights, measured as they show; a window that scrolls rather than a
box (TanStack's window virtualizer); horizontal virtualization. A signal that compares what can be compared, so a
write of the same value runs nothing (the example's README lists it as open).

**Reversible:** yes; `<Repeat>` and `on:viewport` are additions, and the heap keeps the flush's order.


## D-049 Turso writes at once: MVCC by default

**Status.** Built (2026-11-23), the user's choice ("concurrent writes by default, cause why not").

**Context.** D-046 ran Turso as SQLite runs: WAL, one writer at a time, a transaction begun
`immediate`. Turso's MVCC is what it has that SQLite hasn't: transactions begun `concurrent` write
at once, each on a snapshot of its own, and Turso refuses the later of two that write the same row
(first committer wins), which must roll back and run again. In MVCC mode `begin immediate` and a
plain write outside a transaction still take an exclusive lock (single-writer, SQLite's
semantics), and a schema change needs one (`DDL statements require an exclusive transaction`).

**Decision.**

- **A Turso file is in MVCC mode.** `turso.rs` sets `journal_mode = 'mvcc'` when it opens the file
  (converting a WAL one). `turso:<path>?mvcc=off` keeps (or puts back) WAL mode, writes taking
  turns as on SQLite.
- **`Db.transaction!` begins `concurrent`, and runs its body again after a conflict**, up to 100
  times, each time after a random pause that grows (up to 1 ms, then 2, 4… 64 ms: `db::backoff`):
  without one, a writer slower than the others loses to them every time and gives up (eight
  workers on one row, under load, did), and the losers' runs were six to the transaction where
  with it they are about one and a twentieth. Turso's conflicts (a write-write conflict, a stale snapshot, a dependency rolled back, a
  terminated transaction) read `Conflict: …`; the host notes one of the call's transaction (a
  statement's, or its commit's) and `Host.db_conflicted! : {} => Bool` says so, so the body runs
  again even when it turned the `DbErr` into an error of its own. Its notices and its jobs go with
  the rolled-back run (they are the transaction's); what isn't the database's (a fetch, a message)
  runs again, which `Db.transaction!`'s docs say.
- **A schema change is tried again exclusive.** A statement refused in a concurrent transaction
  for changing the schema reads `Exclusive: …`: the host marks the call, and its next transaction
  begins `immediate`. A migration (`Migrations.apply_one!`: a transaction around `Db.script!`)
  takes one wasted run; `Db.script!`'s own transaction is `immediate` always.
- **A write outside a transaction runs in a concurrent one of its own** (an `insert`, `update`,
  `delete`, `replace`, or a `with` before one, by its first word), committed, and begun again by
  the host on a conflict (after the same pause), up to 100 times; anything else (a read, a schema change, a pragma) runs
  as it is.
- **The file is Turso's while in MVCC mode**: its header's versions are 255, which SQLite calls
  "not a database". SQLite's backend says instead that it is Turso's MVCC file and how to give it
  back (`turso:<path>?mvcc=off` once). So `turso:` on a SQLite app's file converts it.
- **Turso's own tables (`__turso_internal_…`, MVCC's `__turso_internal_mvcc_meta`) aren't the
  app's**: packages/admin's catalog leaves them out, as it does `sqlite_…`.

**What it costs.** Snapshot isolation, not SQLite's serial writes: two transactions that read rows
and write different ones both commit (write skew), where on SQLite one would wait and see the
other's. A body may run more than once. No `WITHOUT ROWID` tables, no virtual tables (no FTS5,
already so), no `REINDEX`, in MVCC mode. And a cliff in turso_core 0.8.4: once Turso has
checkpointed rows (its log past 4 MB), deleting many of them slows every later statement 75 to
250 times until the next checkpoint (examples/sqlite-vs-turso's third run on one file took 663 s,
where one takes 3); `pragma wal_checkpoint(truncate)` after the deletes avoids it, which the
example does, and `?mvcc=off` doesn't have it. Not fixed in the platform: to be reported.

**Reversible:** yes: `?mvcc=off`, or the default flipped back in `db/mod.rs`.

## D-050 A plugin's files and scripts

**Status.** Built (2026-11-23), the user's go ("let's do this", the same day): the rest of the
plugin design's phase 2 (`spike/plugins/DESIGN.md`, §4, §7 and §8), for push and audio as plugins
(D-051).

**Context.** D-033's plugins carried routes, early paths, tables, calls, loops, starts and checks,
and no files: a plugin that needs a script on every page, or a service worker at the site's root,
had the app copy its `static/` into a directory the server serves (`--static`) and put a
`<script>` in its layout by hand (push's README had both). Behind the app's middleware those files
would meet the app's guard, which may refuse a request that carries no session (a service worker's
fetch of itself carries none worth trusting).

**Options.**
1. The plugin's routes answer its files, as any route does: through Roc, behind the app's
   middleware, a call per request.
2. Files are values the platform hands the host once, at start, and the host serves them before
   anything else, as it serves `--static` and `--file`; scripts are URLs the host's renderer adds to
   every page.

**Choice.** 2.

```roc
Plugin.Value(ctx) := {
    …,
    files : List(Plugin.File) ?? [],     # served as they are, before the app and its middleware
    scripts : List(Str) ?? [],           # paths of its files every page loads, before start.js
}
Plugin.File : { path : Str, at : [Plugin, Root], content_type : Str, body : List(U8) }
Plugin.url : Str, Plugin.File -> Str     # /rocx/plugins/<plugin>/<path>, or /<path> at the root

import "static/push-sw.js" as worker : List(U8)      # embedded when the app is built
files: [{ path: "push-sw.js", at: Root, content_type: "text/javascript", body: worker }]
```

- **Where.** A file is at `/rocx/plugins/<plugin>/<path>`, or at `/<path>` when `at: Root`: a
  service worker, whose scope is where it is; `/.well-known/…`. The query doesn't count
  (`/push-sw.js?api=/push` is the file).
- **How.** The platform's start hands each file to the host (`Host.plugin_file!(url, type,
  bytes)`), once; the host keeps the bytes and their SHA-256 and answers before anything else (the
  channels' stream, `--static`, the early paths, the app): `GET` and `HEAD` with the file's
  `content-type`, `etag` (the hash's first 16 bytes, hex), `cache-control: no-cache` (`no-store`
  under `--dev`), and 304 when `If-None-Match` has the ETag; any other method, 405 with `allow:
  GET, HEAD`. No call into Roc, so a file costs what a `--file` does, and the app's middleware never
  meets it: a guard that refuses everything still lets the service worker and the scripts through.
- **Scripts** are paths of the plugin's own files. The start tells the host their URLs
  (`Host.page_scripts!`), and every page the host renders has a `<script type="module" data-rocx
  src="…">` for each, in the plugins' order, after the answers and before start.js: module scripts
  run in order, so a plugin's script has registered its effects before the page wakes. `data-rocx`
  makes the tag the host's own, which hydrating passes over, so strict hydration holds;
  `renderToString({ scripts })` (web/runtime.js) writes the same tags, for the byte-for-byte checks.
- **Effects get `{ under }`.** A script registers browser effects on `window.rocxEffects`, named
  `<plugin>.<effect>` (`audio.play`), and `Browser.call!` finds them there, as it found a page's.
  The runtime gives every effect a second argument, `{ under }`: `under(url)` is a URL that begins
  with `/` under the site's base (`/rocx/sounds/eat.wav` for `/sounds/eat.wav` on the docs' copy at
  `example.github.io/rocx/`), which a script can't know otherwise. An effect nobody registered,
  named `<plugin>.<effect>`, says on the console which plugin's script would have.
- **Start checks** (D-033's list, all at once): a file's path that isn't relative (`/sw.js`,
  `../x`, empty segments, `?` or `#`); a file at the root under `rocx/` or `__rocx/` (the
  platform's); two files at one URL (two plugins' at the root, or one plugin's twice); a file at the
  root where a route is, the app's or a plugin's (`/x: routes/x/+page.rocx, and the clash plugin's
  file`); a script that is none of the plugin's files. A route with a `[param]` a file's path would
  fit isn't a clash: the file answers first, the route the rest. The log counts them (`push: 3
  routes, 2 files, 1 script, …`).
- **A static copy of the site** (site/build.mjs's `prerender`, the docs on GitHub Pages) asks the
  server for its files (`GET /__rocx/plugin-files` under `--debug`: each URL, type, and whether
  pages load it) and writes each at its URL; the pages' tags are rewritten under the base with the
  rest of their URLs (`/rocx/rocx/plugins/audio/audio.js` under `/rocx/`).

Different from the design: the listing for a static copy is new; the scripts' tags have
`data-rocx`, as start.js's has, so hydrating passes over them.

**Moving to it.** Nothing changes for an app: `files` and `scripts` default to `[]`. A program
written by hand keeps `plugins.map(Plugin.running)`; one that builds `Plugin.Running` records itself
adds `files: []` and `scripts: []`. A browser effect that took one argument still works (the second
is extra).

**Costs.** Every file is in the executable, and in memory, whole; meant for scripts and workers,
not media. A page loads every plugin's scripts, so a plugin with a heavy one loads the rest itself
when it is needed. **Why.** A plugin's install is one line, and the web's fixed places (a service
worker's scope) are a plugin's to take, checked at start like its routes. **Reversible:** yes.

## D-051 Push and audio are plugins

**Status.** Built (2026-11-23), the user's go with D-050 ("let's do this"): the plugin design's
phase 2, for the two packages that waited on files and scripts.

**Context.** Push's README had six steps: copy `server/Push.roc` and `server/PushStore.roc` into
the app, and a migration into its `migrations/`, write three endpoints, put `<script
src="/push.js">` in the layout, and start the server with `--static ../packages/push/static`, so
that the service worker was at the root. `Audio.play!` was in both platforms, and its player in
web/runtime.js (the effect `rocx:audio`), so every app shipped the player, sounds or not: the one
module D-025's rule (a platform module stays only if it needs the host or the transpiler) still
kept for no reason but where the player was.

**Choice.** Each is a package and a plugin, on D-050's files and scripts.

```roc
# Push: one line in plugins, with the jobs plugin that runs its job
plugins: [Job.plugin({ jobs: App.jobs }), Push.plugin({})]
Push.Setup(ctx) := { at : Str ?? "/push", owner : (ctx -> Str) ?? (|_| "") }
Push.plugin : Push.Setup(ctx) -> Plugin.Value(ctx)

# Audio: Audio.play! as before (import audio.Audio), and the player listed once
plugins: [AudioPlayer.plugin({})]
Audio.play! : Str => {}                                  # Browser.call!("audio.play", { url, volume, rate })
Audio.play_with! : Str, { volume : F64, rate : F64 } => {}
```

- **Push** (`packages/push`) names the server platform and packages/jobs in its header, with
  `Push` and `PushStore` beside the pure modules (they were `server/`, a package of their own); the
  browser's half sees the pure modules (`browser.roc`). Its plugin brings its three endpoints at
  `at` (`GET <at>/key`, `POST <at>/subscribe`, `POST <at>/unsubscribe`, behind the app's middleware,
  the owner of a subscription `owner(ctx)`); its table (`push/0001_push_subscriptions`, Postgres's
  or SQLite's, made only if it isn't there); its service worker at the root (`/push-sw.js`, a file
  `at: Root`, so its scope is the whole site) and the page's script (`push.js`, which every page
  loads); and its job, `push.deliver`. It needs the jobs plugin, a database and `VAPID_PUBLIC_KEY`,
  `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT`; its start checks the pair is one (a bad key stops the
  server, saying which). The effects are `push.subscribe` and `push.unsubscribe` (they were
  `push:subscribe`, `push:unsubscribe`), and the script puts every URL under the site's base
  (`{ under }`). `<PushButton api="/push">` is as it was.
- **A plugin's job.** The jobs plugin ran only the kinds in its options (`App.jobs`, which rocx
  build finds in the app's modules), so a kind a package defines had to be copied into the app.
  packages/jobs gains `Job.call(kind)` (the call a job of the kind runs in, named as the kind is, for
  the bringing plugin's `calls`) and `Job.adopt!(kind)` (from its `starts`: the jobs plugin's
  registry lists it, its jobs a stop cut short are queued again). The workers read the registry once
  every start has run, and run a plugin's kind in its own call (`Plugin.isolated!("push.deliver",
  input, limit)`); the app's still run in `jobs.run`. The jobs plugin's workers always run now, and
  one with no kind to run (or no database) ends at once.
- **Audio** is `packages/audio`: `Audio` (`play!`, `play_with!`), which both halves compile (the
  package's `browser.roc` names the browser's platform, its `main.roc` the server's), a
  `Browser.call!("audio.play", { url, volume, rate })`; and `AudioPlayer.plugin({})`, whose script
  (`/rocx/plugins/audio/audio.js`) is the player that left web/runtime.js: it registers
  `audio.play` and resolves a sound's URL with `{ under }`. `rocx:audio` is gone from the runtime,
  which keeps `rocx:focus` (`Browser.focus!`). The plugin is a module of its own, beside `Audio`:
  `Plugin` is the server platform's, and a module both halves compile can't name it.
- **Sounds the app bundles** are as they were: files the app serves (`--static`; the docs site's
  `site/static/sounds/`, quiz's `static/sounds/`, which their `sounds.mjs` make), at the same paths.

**Moving to it.** For an app outside the repo, in this order:
- **Audio.** Its header names the package (`audio: "…/packages/audio/main.roc"`); its modules (and
  components) import `audio.Audio` instead of `pf.Audio`; its plugins list
  `AudioPlayer.plugin({})` (`import audio.AudioPlayer` in `main.roc`). No sound path changes: the
  files it bundles stay where they are, and `/sounds/eat.wav` is still under the site's base. Page
  JavaScript that called the effect itself calls `audio.play` (it was `rocx:audio`).
- **Push.** Its header names push from the package's root, as before (`push:
  "…/packages/push/main.roc"`, now a package on the server platform), and packages/jobs; its plugins
  list `Push.plugin({})` after `Job.plugin(…)` (with `at` if its endpoints weren't at `/push`, and
  `owner` if its endpoints gave a user's id). Delete: the copies of `Push.roc` and `PushStore.roc`
  (modules import `push.Push` and `push.PushStore`), the three endpoint files
  (`routes/push/key/`, `subscribe/`, `unsubscribe/`), the `<script type="module" src="/push.js">` in
  the layout, `--static …/packages/push/static` from how the server starts, and any copy of
  `push.js` or `push-sw.js` among its own static files. Its copy of the migration may stay or go:
  the plugin's (`create table if not exists`) keeps the table it made, and records itself as
  `push/0001_push_subscriptions`. The server now needs the VAPID variables to start. Page
  JavaScript that called the effects itself calls `push.subscribe` and `push.unsubscribe`.

**Costs.** Push's and audio's scripts load on every page of an app that lists them (push.js 6.1 KB,
2.0 KB brotli'd; audio.js 1.2 KB, 0.5 KB), one request each. A package's job is two lines of its
plugin (`Job.call`, `Job.adopt!`). Every app's runtime.js is 0.7 KB smaller (0.2 KB brotli'd)
without the player. **Why.** Installing either is a line in the header and one in `plugins`, nothing copied, and the
platforms keep only what needs the host or the transpiler. **Reversible:** yes.

## D-052 Solid 2.0's primitives: untrack, its dev warning, latest, merge and omit, static holes

**Status.** Built (2026-11-23), in two landings: first `untrack!` and the dev build's warning of a
read made once, a props record passed on (`..rest`, `{...rest}`), `latest!`, and holes that read
nothing written as static by the server and adopted as text (4e3ece8); then, once plugin-files'
second stage (D-051) had changed the code beside the effects, render effects and an effect's
`error` handler.

**Context.** D-039 made value props getters, and left three follow-ups
(`spike/reactive-props/DESIGN.md`, "Follow-ups"): Solid's `untrack` and Solid 2.0's dev warning for
a reactive read at a component's top (which needs `untrack` first: the charts read their goal once,
on purpose, `create_signal!(goal!())`); a hole that reads nothing made static on both sides (a prop
given a constant became a computation, with comments, on every page); and `merge`/`omit` to pass a
props record on. `latest` was the last of Solid 2.0's reads not here. Solid 2.0 is the north star
(`@solidjs/signals` 2.0.3 read for each: `untrack(fn)`, `latest(fn)`, `merge`, `omit`, and the dev
build's STRICT_READ_UNTRACKED).

**Decision.**

- **`Solid.untrack!(read!)`**, Solid's `untrack`: `read!` runs with the running computation's
  reads not noted (`Host.untrack!(Bool.True)`, then `Bool.False`: a depth on the run's record, so an
  abort that skips the second leaves nothing behind). A computation made inside tracks its own reads,
  and a read that waits still waits, as Solid's does. `is_pending!` inside it keeps no query, and an
  endpoint read inside it doesn't make the computation one a result reads again.
- **Solid 2.0's dev warning, in a dev build** (`rocx build --dev`, `rocx dev`). The transpiler wraps
  each accessor a component's body calls (`count!()`, a prop's getter `label!()` or `(props.label)()`,
  and a pure helper's read made in the body) as `Html.read_at!("Ui/Chart.rocx:44:39", goal!)`, which
  tells the runtime the place while the read runs (`Host.read_at!`, answering the place before, to
  put back); lines stay lines. A tracked read while a component runs, with a place, is warned of in
  the console, once a place. Why both halves: the runtime alone knows what is a reactive read (a
  getter given a constant reads nothing, so is never warned of; Solid's compiler doesn't make a
  getter for a constant either), and the transpiler alone knows where it is (a wasm stack has no
  source lines; Solid's compiler writes `loc` for the same reason). Any other build writes no
  `read_at!` (nothing costs), and the server warns of nothing, as Solid's server doesn't. Not seen:
  a read a helper makes (`total!(items)`), and one at a `<For>` row's top; said in web/README's
  "Not yet". The charts' start values are `create_signal!(untrack!(goal!))` now.
- **`Solid.latest!(read!)` is `read!()`**, documented. Solid 2.0's `latest` reads the newest value
  while a transition holds writes back; here nothing holds them back (a memo read again already
  shows the value it last settled at, `is_pending!` saying so), so every read is already the latest.
  It becomes meaningful if transitions ever hold writes back. A failed refresh still goes to
  `<Errored>`, as Solid sends failures there (the coordinator's answer: not the last good value).
- **`merge` and `omit` are Roc's record syntax and JSX's spread** (the coordinator's choice, option
  A). Roc can't have them as functions: it can't make a record of two, and a field's name isn't a
  value. Roc's fork can take a record apart, `|{ kind, ..rest }|`, so:
  - **omit** is a view's pattern with a rest: `kind` is a getter as before (`kind: kind!`), and
    `rest` a record of the others, getters still; `rest.label` is read as `(rest.label)()`, as a
    whole record's field is (D-039).
  - **merge** is a spread on a component's tag, `<Base {...rest} size={3} />`, JSX's: its fields as
    they are, so `Base` reads the outer caller's expressions, live. Of two of a name, the last wins
    (an attribute after replaces a field; a spread after, an attribute). Where the view's props are
    annotated, rocx writes the fields out one by one (`label: rest.label`), so attributes may add
    fields and `Base`'s `??` defaults still fill. Where not, it writes Roc's record update,
    `Base.view!({ ..rest, size: || 3 })` (or `Base.view!(rest)` alone), which needs `Base`'s props to
    be the record's type; `rocx check` puts a hint at the end of the compiler's report at that line
    saying so, and to annotate the view's props (another for written-out fields: `Base` must take each
    one). Two records rocx doesn't know the fields of can't be merged (refused, at the tag); a spread
    on an element, or on the platform's or a pure component (whose props aren't getters), is refused.
- **Static holes.** A text hole (`{"t":"x"}`) or a markup one (`"h"`, `"l"`) whose run read and made
  nothing that changes is static: no tracked read (a signal, a memo, a row, a submission, an
  endpoint, `is_pending!`, all but inside `untrack!`), and no signal, memo, effect, cleanup, timer,
  listen, subscription or title made. The runtime knows it from the run's record (`inert`, with a
  `live` flag for what the record doesn't show: an endpoint read, and, rendering as a server would,
  the calls that do nothing there); the native server notes the same host calls on the running frame
  (signals.rs's `touched`). Then the server writes the hole without its comments, and hydrating runs
  it first, finds it static too, and takes its text as a static text's (splitting off what the
  parser joined), or its markup in place, under strict hydration as well; nothing keeps its
  computation (a markup hole's stays as the owner of what is inside, never run again). Built in the
  browser, the same. A computed attribute whose run was inert isn't kept either (the server writes
  attributes the same way already). Both sides decide by running the hole, so they agree by
  construction; a hole that reads `Router.location!` or the flash is static, as neither is tracked
  (D-040 would make the location tracked, and so not static).
- Why not decide at build: the transpiler already makes a hole that calls nothing with `!` static,
  but a getter's caller is in another file (a component is written once for all its callers), so
  only a run can tell.
- **`Solid.create_render_effect!(compute, apply)`**, Solid 2.0's `createRenderEffect`: its `apply`
  runs as soon as `compute` has answered, in the run (made in a component, before the component's
  markup is built; in a flush, before the effects' applies, which wait for nothing to be dirty).
  Solid runs it in its render queue for DOM bindings; Roc has no DOM of its own, so here it is what
  keeps a value in step with the render, with no flush between. On the server neither half runs,
  as no effect does here (Solid's server runs both: a write there would fail, since the server never
  writes a signal), so what a first `apply` writes is patched in as the page hydrates.
- **`Solid.create_effect_with!(compute, { apply, error })`**, Solid 2.0's
  `createEffect(compute, { effect, error })`: a record, as Roc has no overloading, the bundle's
  `effect` named `apply` as rocx's other effect names it. A `compute` that fails calls `error` with
  why (the failure's message) instead of showing the nearest `<Errored>`: after the flush, in the
  apply's place, as a handler, the last apply's cleanups first; if `compute` answers again before
  then, `apply` runs instead, as Solid's sees only settled failures. A failure in `apply` or `error`
  is a handler's, logged (Solid sends an effect-phase throw to the boundary; rocx's handlers never
  did, and a rethrow from `error` isn't there: leave `error` out for the boundary).
- **One hosted function for both, `Host.effect_options!(render, error_box)`**, which such an
  effect's `compute` calls first each run (the error handler a box kept as its maker runs, given
  why through `Host.event_value!`). The runtime notes them on the effect: a failure can come before
  the compute answers, so they must be known before it runs. A plain `create_effect!` doesn't call
  it, so costs nothing more; the server's is a no-op.

**What it costs.** Three hosted functions (`untrack!`, `read_at!`, `effect_options!`) on both platforms. A hole is run
before its place is taken while hydrating (no extra run). Measured with `just site` on master
5689240 and on this branch rebased onto it:

- The site's client wasm: 1,332,734 → 1,332,872 bytes (+138), 295,165 → 295,211 br (+46).
- Every page's layout has two markup holes that read nothing: −46 bytes a page. The front page,
  −23 bytes (19,774 → 19,747 br); /ecosystem/charts, 126 text holes → 109 and 6 markup holes → 0,
  −337 bytes (44,732 → 44,769 br: brotli's own noise); /ecosystem/forms, 12 text holes → 1, −233
  bytes (31,152 → 31,132 br). The browser keeps that many fewer computations hydrating them.

**Reversible:** yes, each part on its own: `inert` answering false makes every hole live again; the
transpiler's `dev` flag off writes no `read_at!`; a spread is new syntax nothing else depends on.

## D-053 Solid 2.0's control flow and stores: keyed `<Show>`, `<Switch>`/`<Match>`, `createStore`; pure components stay values

**Status.** Built (2026-11-23): keyed `<Show>`, `<Switch>` and `<Match>`; stores (designed in
`spike/stores/DESIGN.md`, the coordinator's go given with two conditions, both met below); `<For
compared>`; and the decision that a pure component stays a function of values.

**Context.** web/README's "Not yet" had the rest of Solid 2.0's control flow: keyed `<Show>` and
`<Switch>`/`<Match>`; stores as `createStore` makes them; and "a pure component patched in place"
(a pure `view` given a value read from what changes is a hole made anew, where a `view!` is kept,
D-039). Solid 2.0 is the north star (`solid-js` 2.0.3's `Show`, `Switch`, `Match` read for each).

**Decision.**

- **Keyed `<Show>`** (Solid 2.0's `keyed`). Solid's keyed condition is a memo compared by identity,
  so the part is made anew when the value changes, not only when it turns truthy, and a function
  child gets the value itself. Roc's values have no identity, so the value is its own key: two values
  are the same one when `Str.inspect` says the same of them. `<Show when!={…} keyed>` is
  `Show.view_keyed!` (children, made anew per value) or `Show.view_with_keyed!` (a function child
  given the value). `keyed` is a flag, as Solid's is: rocx refuses a key function there
  (`<For>`'s `keyed={|t| t.id}` stays `<For>`'s). A function inside the value prints as
  `<function>`, so a change of one alone isn't a change: said in the docs.
- **`<Switch>` and `<Match>`.** Solid's `Switch` reads its `Match`es' conditions in order up to the
  first that holds, and makes the part anew when another one holds first, or a keyed one's value
  changes; a non-keyed one's narrowed accessor follows its value, the part kept. The same here:
  `Match` has `<Show>`'s four forms (`view!` a Bool; `view_with!` a Try narrowed to an accessor;
  `view_keyed!`, `view_with_keyed!`), each `Html.matched(case!, made!)`, and `Switch.view!` takes the
  first that holds (`Html.switch`). rocx refuses a `<Match>` that isn't a `<Switch>`'s child, and
  anything but `<Match>`es (and the spaces between them) in a `<Switch>`: Solid passes over such
  children silently; here it is a mistake said at its line.
- **One node for all of them.** Both are `Html.switched(case!, made!, fallback)`, serialized as a
  `<Show>`'s node: `"r"` answers the case's name (`"#…"`, never empty, so truthy) or `false`, and
  `"with"` makes the part. The runtime already makes a `<Show>`'s part anew when what `"r"` answers
  changes, and the native server and hydration take a `"show"` node as they always have, so neither
  host changed: two modules of Roc, `Html`'s two variants, and the transpiler's `keyed` and
  `<Switch>` rules.
- **A pure component stays a function of values** (item 4, the coordinator agreed). Patched in
  place as Solid patches a component, it would take getters (`() => Str`) read in its holes. A pure
  function can't call one, and `Html.to_str` can't run one, so every call of it from Roc would break:
  the `expect`s that test components with `Html.to_str(Avatar.view({ name }))` (examples/journal,
  tasks, plate), and an email's HTML. Writing every pure component twice (as written, and a getter
  copy for tags) would double its code in the wasm and the transpiler's work, and a pure component
  that reads a prop in its body (most of examples/journal's: `intl = I18n.intl(lang)`) would be made
  anew anyway. Solid's way is already there, one `!` away: a `view!` is kept and patched (D-039), and
  a pure component may take an accessor that its holes read (`left! : () => U64`, examples/quiz's
  `Countdown`), which keeps it. Made anew, a pure component loses no state (it has none), only what
  the browser keeps in its elements (the focus, a field's text, a scroll).

- **Stores** (Solid 2.0's `createStore`). Roc has no proxies, no identity and no reflection, so a
  store can't see which field a read touches. A read selects, and is tracked by the value it
  selected: `(todos, set_todos!) = create_store!(init)`, then `todos.get!(|s| s.filter)`. Where the
  reader tracks (a hole, an attribute, a memo, an effect's compute), `get!` makes a *selection*: a
  memo of the part, owned by the reader's run, which compares its new value with the one it had and
  tells its readers only when they differ; anywhere else (a handler, a component's body,
  `untrack!`, the server) it is `select` of the value, once. A write is a function of the state, the
  draft setter of Solid 2.0, Roc's record update being the draft; two in one handler compose.
  `Store.of(accessor)` reads any accessor (an endpoint's answer, a memo, a prop) by parts. Not
  built, and why: derived stores and projections (a memo is the derived read),
  `createOptimisticStore` (D-030's optimistic memos), `reconcile` and `storePath` (writing a new list
  whole, and Roc's record update, do their work). Alternatives weighed (lenses per field, JSON
  paths, transpiler sugar, every memo compared): `spike/stores/DESIGN.md`.
- **Compared with `==`, not text.** The coordinator's condition: Roc's structural equality where the
  type allows. A part's type must have `is_eq` (`get! : Store(s), (s -> a) => a where [a.is_eq : a,
  a -> Bool]`): records, tags, lists, text and numbers do, a nominal type needs its own, and a
  function or markup can't be selected, which keeps selections to data. No text is made, so a
  selection's run allocates nothing to compare (a write to four hundred selections: 407
  allocations, about one each, for the closure and box of the part). The design's `Str.inspect`
  would have allocated a text per selection per write, and treated two functions as one.
- **`<For compared>`, opt-in.** The coordinator's other condition: rows compared by value for every
  list only if it costs nothing that matters, measured first. Measured (Chromium, `--opt=size`,
  a `<For>` of 10,000 rows of `{ id, title, done }`, each row two holes; medians of seven, on a busy
  machine):

  | | one item changed | every item changed |
  |---|---|---|
  | before (as on master) | 1,865 ms, 20,001 runs, 100,017 allocations | 1,868 ms, 20,001 runs |
  | keys made unique with a `Dict` (below) | 66 ms, 20,001 runs, 90,048 | 66 ms, 90,048 |
  | and every row compared by `Str.inspect` | 41 ms, 3 runs, 90,050 | 73 ms (+11%), 110,048 (+22%) |
  | and `compared` (`==`) | 37 ms, 3 runs, 70,050 | 70 ms (+5%), 90,048 (no more) |

  At 300 rows (a board's size): 3.5 ms before, 2.0 ms with the `Dict`, 1.4 ms compared. Comparing
  every list by text slows a list whose items all change and allocates a fifth more, so it isn't
  the default. Comparing every list with `==` would make `<For>` require `is_eq` of its items,
  refusing a list of records that hold functions or markup (packages/intl's language picker is one,
  of every `<For>` in the site and the examples; lists of actions with handlers, of items with an
  icon, are common), so it isn't the default either. So `compared` is a flag: `<For each!={…}
  keyed={…} compared>` (`For.view_with_keyed_compared!`, `view_with_unkeyed_compared!`) hands each
  item with whether it is `==` the one the row had (`Host.row_last!`), and only a changed row is
  told. examples/checkboxes renders `<Repeat>`, whose rows have no item: unchanged. The board and
  the site's planner use plain `<For>`s, unchanged but for the faster keys; either may add
  `compared` (their items compare).
- **A `<For>`'s keys made unique in linear time.** Measuring found the cost: a key seen before gets
  `#1`, `#2`, counted by scanning every key seen so far, so ten thousand rows took fifty million
  comparisons a change. A `Dict` of counts makes it ten thousand lookups: 1,865 ms to 66 ms a change
  for 10,000 rows, for every `<For>`.

**What it costs.** Keyed `<Show>`, `<Switch>` and `<Match>`: no host or runtime.js change;
`Html.serialize!`'s two new cases are in every app's wasm (the site's client, which uses neither,
1,336,620 to 1,338,583 bytes, +1,963; 296,342 to 296,691 brotli'd, +349); `Str.inspect` of a keyed
value on each run of its condition. Stores and `compared`: four hosted
functions on both hosts (`tracking!`, `memo_last!`, `signal_latest!`, `row_last!`), two given a flag
(`memo_done!`'s and `row_set!`'s `same`, `Bool.False` from `create_memo!` and a plain `<For>`), the
glue regenerated; the runtime's memo keeps quiet when told `same`, and counts selections
(`stats.selections`); the wasm host counts allocations (`allocations()`, for the tests). A write runs
every live selection of its store, where Solid's touches only the paths written: four hundred take
about half a millisecond (0.8 ms in a dev build). A selection is its reader run's, made anew when the
reader runs again. The site's client wasm, which uses no store, with all of D-053: 1,349,117 bytes
on master (1c34928) to 1,365,897 (+16,780), 299,868 to 304,786 brotli'd (+4,918). Of that, the
`Dict` of keys is about 15,400 bytes (3,807 brotli'd, measured before the rebase onto 1c34928): every app with a `<For>` carries it, for a `<For>` many times faster at
length (a sort of each key's hash instead was larger still, 70 KB, from the iterator and sort it
needs; the hosts could count keys instead, a hosted function more). The stores and `compared` add
nothing measurable to an app that doesn't use them.

**Reversible:** yes; the new views, the store and `compared` are additions, and nothing else depends
on them (the `Dict` of keys is a plain speed-up).

## D-054 Solid Router's actions, createOptimistic, @solidjs/meta's head elements, form bodies in OpenAPI

**Status.** Built (2026-11-23): items 1 to 4 of the brief. Item 5 (`Try` across the wire) since the
fork pin 4674b5973d (2026-11-24), which has upstream's fix for it (`test/compiler-bugs/try-json-codec`).

**Context.** D-030 built Solid Router's `useAction` and `useSubmissions`, with an optimistic value
derived from the submissions on their way, and left the rest: `.with`, a submission's `retry`,
revalidate keys (every GET the page read was read again), and multipart forms (skipped by the
runtime, unread by the server). Solid 2.0's `createOptimistic` wasn't there. `<Title>` was the only
one of @solidjs/meta's components. The OpenAPI document listed a body as JSON only, though D-038's
endpoints read a form's fields by the same type (examples/journal's no-JavaScript reactions).

**Decision.**

- **Revalidate keys are the handler's, on the server** (Solid Router's `json(data, { revalidate })`,
  whose action runs on the server): `Router.revalidate!(keys)`, each key a URL
  (`Endpoint.url_of(Api.get_board({}))`). The host notes it on the request being answered (one
  hosted function, `revalidate!`, a field of `Asked`) and puts it in the answer, `x-rocx-revalidate:
  ["/board"]`; the runtime then reads again only the reads of a GET whose URL is a key, or begins
  with one and a `/` or a `?` (`"/api/notes"`: every note), as Solid matches a key's prefix; `[]`
  reads none, and the submission is done at once. Without it, every GET, as before. In a handler in
  the browser, the same function reads those reads again itself (Solid Router's client
  `revalidate(keys)`), once the handler is done. Why URLs, not Solid's query names: a read is an
  endpoint, and its URL is what the runtime keys its calls by already, params and query in it.
- **`retry!`** (`Submission.retry!()`, `Submissions.retry!(id)`): the runtime keeps each
  submission's request, and sends it again as the same submission, pending again, from a handler.
  One on its way isn't sent twice; a plain form's flash, which the runtime never sent, isn't sent.
- **`.with` is `Endpoint.with_fields(endpoint, { id })`** (`with` is Roc's keyword): a form's fields
  given ahead of time, in the URL the form posts to (`/todos/toggle?id=7`), so they work without
  JavaScript too. The record is written as JSON and flattened to fields (text as it is, numbers and
  yes-or-no as written, a list as its items; a record inside crashes, saying so). The server reads a
  form's URL's query as fields before its body's (a field both have that isn't a list is the
  body's: FormBody takes the last). Its submissions are the endpoint's (`base_of`: the URL without
  those fields), as Solid lists an `action.with`'s under its action; the runtime matches a form's
  URL to the longest known endpoint it begins with, then `?` or `&`. An action's values are bound
  by a closure (`|done| toggle!({ id, done })`): Roc's closures already are `.with` there, and a
  typed arg can't be half a record.
- **Multipart, both halves.** The runtime sends a form with `enctype="multipart/form-data"` as the
  browser's `FormData` (its input: its fields URL-encoded, a file's its name, as `URLSearchParams`
  of the form gives it). The server parses `multipart/form-data` in Roc (`Server.multipart`, pure,
  in the shared Server module: no host change): its text parts are fields, read by the arg's type
  as a URL-encoded body's are, and a file's field is its name. The handler reads the file with
  `Server.file(request, "photo")` (`Server.Upload`: field, name, type, bytes) or `Server.files`;
  packages/storage keeps one with `Storage.put_upload!(bucket, key, upload)`, the one place a
  streamed upload would later be copied from (the host keeping a large part aside as it comes)
  without an app changing. A plain multipart form goes back with a flash as a URL-encoded one does.
  A file is part of the body, read whole: one over `--max-body` (16 MiB by default) is a 413, `the
  request's body is too large`, before Roc sees it (D-056), tested with a 17 MiB form.
- **Files from the page (with D-055):** an action whose arg has a top-level field holding the URL of
  a file the page has, or a list of them, is sent as multipart: each file a part of its field's
  name (several under one name for a list), the other fields as a form's. A string is a file only
  when it is a key of the runtime's files (`fileOf(url)`, which D-055's `on:drop.files`,
  `on:paste.files` and `on:change.files` fill, and revoke with their owner), never because it starts
  with `blob:`. The arg's type has the field as a `Str`: on the server the file's name, as a form's;
  in the browser the URL, so a pending input shows the file (`<img src={input.photo}>`) while it is
  on its way. A record inside such an arg fails, saying a form has none.
- **`create_optimistic!(compute)`** (Solid 2.0's `createOptimistic`): a signal holding `Held(value)`
  or `Unheld`, read as the value or `compute`'s memo. Its write (`Host.optimistic_set!`) is queued
  with the handler's writes; applying them, the runtime opens a transition, open for the rest of the
  task, which the submissions sent meanwhile join (the handler's actions, and the form its `submit`
  event sends after it: the page's listener runs after the element's). When its last submission is
  done (a result once the reads it names are in, a refusal at once), its writes are undone in that
  same call, so the flush that shows the server's data shows the value as the server's: no frame of
  the old. With none sent, undone at once (Solid 2.0 undoes a write outside a transition). Several
  transitions held on one value: the latest held shows, each undone on its own. On the server no
  handler runs, so the page hydrates as rendered. Why both ways stay: D-030's memo over
  `pending_inputs!` applies each submission on its way to the server's latest data, for many at
  once; `create_optimistic!` is for a value the handler knows, as Solid 2.0 writes it. D-030's worry
  (a handler that waits runs again, applying its write twice) doesn't arise: a handler's writes,
  this one's too, are dropped when it waits, and applied once when it is done.
- **`<Meta>`, `<Link>`, `<Style>`** are rocx's tags, as `<Document>` is (a module of the file's own
  by that name is a component instead): written as a `<meta>`'s, a `<link>`'s and a `<style>`'s are,
  holes and all (`<Style>`'s CSS static, as a `<style>`'s). Each is `Html.document_head(element)`: a
  hole that renders nothing, whose run fills the element's attributes and tells the host its markup
  (`data-rocx` first) and key (`Host.head!`). A key is @solidjs/meta's cascade: a `<Meta>`'s `name`
  (`property` the same), `http-equiv`, `charset` or `itemprop`, with its `media`; a later one with an
  earlier's key takes its place, at its own place in the order. Their place is before `</head>`, in
  the order of their first runs (layouts' before their page's), after the title (D-050's plugin
  scripts go before `</body>`, so nothing else of the host's is in `<head>`): the server (signals.rs's
  `headed`) and `renderToString` (`Runtime.headed`) write the same bytes. The browser keeps them by
  their holes' computations, as titles, and after a flush in which one changed makes the head's
  `[data-rocx]` elements (but `<title>`) match: one `isEqualNode` to what is there is kept (the
  server's, hydrating: a stylesheet isn't loaded again), one that differs replaced, one more added at
  the end, one fewer taken out. Why rocx's tags and not components with props: their attributes are
  an element's (`http-equiv` isn't a Roc field name; a hole in `content` is an attribute hole), which
  the transpiler already reads. A `<meta>` in the layout's own `<head>` isn't one of them (hydration
  would refuse changing it): a default is a `<Meta>` in the layout.
- **Form bodies in OpenAPI:** `OpenApi.sent(endpoint, tags)` lists an operation's request body as
  JSON and, when its type is one a form has (a record of text, numbers, yes-or-no, choices and lists
  of them: what FormBody reads), as `application/x-www-form-urlencoded` and `multipart/form-data` too,
  the same schema with a yes-or-no and a list not required (a form leaves them out). The schema
  format notes, writing the form's, the shapes a form hasn't (a record in a field, a tuple, a dict,
  null, a tag with a payload, a list of lists) and drops the form's entries then. `OpenApi.body` is
  the JSON schema still (packages/mcp's tools use it); `operation` takes the contents.
- **`Try` across the wire, not built.** Builtin.roc declares `Try(ok, err) := [Ok(ok),
  Err(err)].{ parser_for : _, encoder_for : _ }` and the canonicalizer makes derived methods of
  them, but the checker finds neither on `Try` (a "missing method" error on the fork rocx pins and on
  nightly-2026-11-18), while the same union as an app's own nominal type writes `{"Ok":5}` and reads
  it back. Reduced in `test/compiler-bugs/try-json-codec`; the tag union stood in, and `rocx check`
  added a hint naming it. **Since 4674b5973d (2026-11-24)** the fork has upstream's fix (issue 13112:
  52b8b05fa5, 48043c2f08, cherry-picked after its tests): a `Try` is its tag union to its derived
  codec, `{"Ok":3}` and `{"Err":"Empty"}`, except the format's own `Try(a, [Null])` and a record
  field's `Try(a, [Missing])`. The hint is gone, and the server test app's `/probe/length` answers a
  `Try`.

**What it costs.** Four hosted functions on both platforms (`head!`, `revalidate!`,
`submission_retry!`, `optimistic_set!`; the last two do nothing on the server), the glue regenerated;
a field on the server's `Asked`. runtime.js: a head section beside the title's, the optimistic
transition, the forms section's multipart, `retry` and keys; the shared code touched is one line at
the flush's end, the handler-writes loop's branches, and a signal's release (`releaseSignal`, for
held writes). A multipart body is parsed in Roc, a byte at a time for its boundaries. Measured with
`just site`, master 1c34928 against this branch on it: the site's client wasm 1,350,921 → 1,348,937
bytes (300,295 → 300,202 brotli'd; the site uses none of the new functions); web/runtime.js 188,612 →
201,488 bytes (46,559 → 49,506 brotli'd).

**Reversible:** yes, each on its own: no `revalidate!` reads everything again; `create_optimistic!`
and the head tags are new; a multipart body can go unread again (a 415).
## D-055 Drags by touch and a pen, what a drag carries and shows, files dropped, moves that resize, presence's cursor and away

**Status.** Built (2026-11-23), with the coordinator's answers to the API questions (1 to 4 below).

**Context.** D-029 made drag and drop the browser's events, and said what it didn't do: a touch
starts no drag in many mobile browsers (Safari's long press does), nothing a drag carries but text
can be read, files dropped can't be, and an app can't say what a drag shows or carries for other
pages. D-031's glide translates and doesn't scale, and two clipping cases were left. And
packages/presence waited on three asks: where the pointer is (W1), whether the page shows (W3), and
the app's own metadata on the wire (R1).

**Choices.**

1. **A drag by touch or a pen is the runtime's own, in the browser's events.** A pointer that
   isn't a mouse, pressed on an element that starts drags (a dragstart handler, `drag:data` or
   `drag:image`; `draggable`), held still a quarter second (moving under 8 px), starts one: synthetic
   `DragEvent`s carrying one `DataTransfer`, hit-tested with `elementFromPoint` each animation frame,
   so D-029's drop targets and every app's handlers take it unchanged (examples/board works by touch
   with no change to its markup). A swipe scrolls (no `touch-action: none`), a tap clicks; while it is
   held and drags, the element has no long-press callout and selects no text; while it drags, a
   non-passive `touchmove` on the element (there before the touch starts, as a passive one can't
   cancel) keeps the page still; a copy of the element follows the finger in the top layer; a box that
   scrolls, or the page, scrolls under a finger near its edge; the browser's own drag, should a long
   press start one, is called off, and the lift's click doesn't come. **A mouse keeps the browser's
   drag**: it carries data and files to other windows, which a drag of the runtime's can't.
   Rejected: a library's sensors (dnd-kit's), a second set of events (`on:pointerdrop`), and a drag
   that starts at a distance (a column of cards would never scroll by touch).
2. **What a drag carries: `drag:data={[(type, value), …]}`** on the source (`Html.drag_data`, or
   `drag_data_of` computed), put on the drag as dragstart ends, each by type (`text/uri-list` opens as
   a link in another tab); `on:drop.data` gives a drop every piece by type
   (`List(Html.DragItem)`: `{ type, value }`); `on:drop.value` stays the `text/plain` alone.
3. **What it shows: `drag:image={id}`**, a copy of the element with that id (hidden or not), held at
   the share of it the source was taken at: `setDragImage` for the browser's drag, the same copy under
   a finger.
4. **Files: `on:drop.files`** (and `on:paste.files`, a file input's `on:change.files`) gives
   `List(Html.File)`: `{ name, type, size, url }`, `url` a `blob:` URL the runtime keeps
   (`runtime.files`, `runtime.fileOf(url)`) and revokes with the target's owner. **Keeping one has one
   way: D-054's multipart actions** (an action whose input has a field holding a kept URL sends that
   file as a part; `Server.file`, `Storage.put_upload!` on the server). Uploads straight to storage (a
   `PUT` to a signed URL) are a follow-up in TODO.md, not a second way now.
5. **Moves that resize** scale as they glide, FLIP's way (`scale` about the element's
   `transform-origin`, beside `translate`), so the old box is exactly where the glide starts; what is
   inside is scaled with it (counter-scaling children costs a pass a frame). A lifted glide is clipped
   as the boxes it leaves and lands in clip it (`clip-path`), so one whose place is scrolled away
   slides under its new box's edge; inside a box that makes fixed elements its own (a `transform`, a
   `filter`, `contain`) it is lifted into the top layer (a manual popover, its own look kept), which no
   box holds or clips. Without popovers, that last one stays clipped (web/README's "Not yet").
6. **Where the pointer is: `on:pointermove.point`** (`Html.on_point`), `Html.Point` as shares of the
   element's box to thousandths, at most once an animation frame with the latest place; on
   `<Document>` and `<Window>`, of the viewport. Presence's `create_pointer!` throttles a page's cursor
   to 20 sends a second (the last place kept), `<LiveCursors>` takes `on_move!` and `on_leave!`, and
   `join!`'s `moved!` and `away!` go through it (W1).
7. **Whether the page shows: `on:visibilitychange.visible`** (`Html.on_visible`, a Bool), and
   presence's `join!` gains `visible!(shown)`: `away` while hidden, the app's status back when shown
   (W3). Open question 3 (automatic or the app's choice) is answered **the app's choice, in one
   line** (`<Document on:visibilitychange.visible={here.visible!} />`), Solid's way: a primitive does
   one thing and the app composes them (solid-primitives' `createPageVisibility` beside a store, not
   inside it); a store that listened to the document itself would be a listener the app can't see in
   its markup, and would need a store-level listener the platform doesn't have (a host change); and
   what a hidden tab means is the app's word (away, idle, or nothing on a wall screen).
8. **R1 works on the fork**: a function with `where [d.is_eq : d, d -> Bool, d.Json.Encodable([]),
   d.Json.Parseable([InvalidJson(Str)])]` carries `List(Room.Here(Wire.Meta(d)))` both ways
   (`Json.to_str` wants `Encodable([])`; an open error type was the "missing encoder_for"). So the
   metadata is `Wire.Meta(d)`: the fields the components read (name, picture, colour, status) and
   `data : d`, the app's own (`{}` for none), with `PresenceServer` and `join!` generic in `d`; open
   question 2 is answered both: the fixed fields stay, and the free one is typed.

```rocx
<li draggable="true" drag:data={[("text/uri-list", url), ("text/plain", card.title)]} drag:image="ghost" on:dragstart={…}>…</li>
<ul on:drop.files={|files| set_files!(files)}>…</ul>          # each { name, type, size, url }, url a blob: URL
<LiveCursors cursors!={…} on_move!={here.moved!} on_leave!={here.away!}>…</LiveCursors>
<Document on:visibilitychange.visible={here.visible!} />
```

**Costs.** web/runtime.js grows by the drag section (pointerDrag, its frames, the scroll near an
edge, the copy under a finger), the drag's data, image and files, `.point`, and the glide's scale
and clip. Html gains seven attributes (`OnPoint`, `OnData`, `OnFiles`, `DragData`, `DragDataOf`,
`DragImage`, `DragImageOf`) and four types (`Point`, `DragItem`, `File`); no host changes. A drag
source listens to `pointerdown` and a non-passive `touchmove` (the browser waits for the page on each
touchmove that starts there). **Reversible:** yes; mouse drags are as D-029 made them either way.

## D-056 The server's limits: a body limit, the platform's log events, Http's connections and proxies

**Context.** TODO.md's "the server's other limits" listed, from `server/README.md`'s "Not yet":
D-014's body limit, deferred (16 MiB, fixed in the host); the platform's own log lines (migrations,
plugins, packages/jobs and packages/email) written with `Log.line!`, a message at info with its
details in the text, though D-015's structured logger had landed; and `Http`, a connection a
request, none kept alive, no proxy, an answer's body into Roc whole. The user asked (2026-11-23)
for the "decided but not built" list to be built; the coordinator settled the four choices below.

**Options and choices.**

1. **The body limit** (D-014): a flag and an environment variable, as the server's other settings
   (`--kv-max-mb`/`KV_MAX_MB`) are, or a field of `program` too. *Chosen:* `--max-body` and
   `MAX_BODY`, no program field: an app sets none of the others (the store's size, an actor's idle
   time, the channel beat) in its program, and the limit is the deployment's (what memory the host
   has) as much as the app's.
2. **The platform's log lines**: as they were, or a message that doesn't change and fields. *Chosen:*
   the latter, at the level each is: a job that fails and runs again is a warning, one that failed for
   good an error.
3. **Keeping connections**: hyper-util's pooled client (another layer of dependencies and its own
   connector for rustls), or a pool of our own over hyper's connections (`SendRequest` says when a
   connection is ready again, or closed). *Chosen:* our own, a few dozen lines in `client.rs`, the
   limits constants, documented, not flags (the coordinator: no knob until an app needs one).
4. **The proxy's option**: per request in `Http.Init` (as Bun's `fetch` has `proxy`), a server flag
   (`--http-proxy`), or both. *Chosen:* per request: `Http` has no client object to hang it on, and
   the environment covers the server's own.
5. **Loopback and the environment's proxy**: as Go (never through it) or as curl (only `NO_PROXY`
   says). *Chosen:* Go's, so a server's sidecar and its tests' servers aren't sent to a corporate
   proxy; a proxy a request names applies to loopback too.
6. **An answer's body in chunks** (optional in the brief): built, as a fold, since it fit without
   changing `fetch!` or the host's ABI types.

**As built.**

```
--max-body 16MiB        the most a request's body may be (MAX_BODY): bytes, or KiB, MiB, GiB; 0 or
                        anything else stops the server; 413 beyond, the limit itself fits
```

```roc
Http.Init := { …, proxy : [FromEnv, Direct, Via(Str)] ?? FromEnv }
Http.Received : [Head(HttpResponse), Chunk(List(U8))]
Http.fetch_chunks! : Str, Init, state, (state, Received => Try(state, err)) => Try(state, [HttpErr(Str), TimedOut, TooLarge, Stopped(err)])

Log.warn!("rocx jobs: a job failed, and runs again", { kind, id, attempt, of, again_in_ms, error })
```

- **The body limit.** `http::Config.max_body`, read up to the limit and refused as it passes it,
  said or chunked. Refusing one whose `content-length` is over before reading it was tried and
  dropped: the client, still sending, saw the connection reset instead of the 413.
- **Log events.** `rocx server: migrated` (`migration`); `rocx plugins: added` (`plugin`, `adds`:
  "1 migration, 5 loops"; `Plugins.summary` became `Plugins.added`); a plugin's check, its message
  with `check` (`email.smtp`), at info, or warn when it fails; `rocx jobs: a job failed, and runs
  again` (warn: `kind`, `id`, `attempt`, `of`, `again_in_ms`, `error`); `rocx jobs: a job failed for
  good` (error: `kind`, `id`, `attempts`, `error`); `rocx jobs: jobs cut short by the last stop,
  queued again` (warn, `count`); `rocx jobs: couldn't take a job`, `… couldn't record how a job went`
  (error), `… can't hear when a job is queued, so looks every second instead` (warn); `rocx cron: a
  schedule's job wasn't queued` (error, `cron`, `error`); `email: kept, not sent (no SMTP_URL)`
  (info, `to`, `subject`). `Log.line!` stays, for apps.
- **Kept connections** (`client.rs`): idle ones a place (scheme, host, port, and the proxy), kept
  30 s, or a second less than the server's `keep-alive: timeout=N` (Node and Apache close theirs
  after 5 s), 32 idle at most a place, the oldest going first; no cap on open ones (Go's and
  undici's default). A connection goes back when its answer's body is read to its end (a task waits
  on `SendRequest::ready`); a body dropped part-read is drained by hyper if the rest has come, and
  its connection closed if not. A task closes the expired ones every second while there are any. A
  request on a kept connection that fails is made again once on a new one when hyper hands it back
  unsent, or when it may be sent twice (GET, HEAD, OPTIONS, TRACE, PUT, DELETE, an
  `idempotency-key`) and the connection went (closed, reset, cut short), as Go's transport does.
  `Server.forward` shares the pool.
- **Proxies** (`proxy.rs`, plain Rust, its tests compiled alone): `HTTPS_PROXY` for `https` URLs,
  `HTTP_PROXY` for `http` ones, upper case first, an empty one unset, read once; `NO_PROXY` by commas:
  `*`, an address, a CIDR range, a domain and the names under it, `.domain` (or `*.domain`) for
  those under it only, each with `:port` for that port alone; `localhost` and loopback never. A
  proxy's URL: `http://` or `https://` (TLS to it), credentials percent-decoded into `Basic`,
  `host:port` alone read as `http://`; anything else is an `HttpErr` naming the variable, never a way
  around the proxy. An `http` URL's request goes to the proxy whole (its absolute URL, and
  `proxy-authorization` unless the caller gave one), the connections kept to the proxy shared by
  every host; an `https` URL's goes through `CONNECT host:port`, TLS to the server inside it (by the
  server's name), its connections kept a place each. Errors name the proxy without its credentials.
- **Chunks.** `Host.http_open!` makes the request and keeps the answer's body in the host, its id the
  call's (a list in the call's context, as `Tcp`'s sockets are, let go when the call ends, crashed or
  not); `Host.http_read!(id)` gives the next chunk as it comes (`[]` at the end, after which the host
  has let it go), within what is left of the time limit and the size limit; `Host.http_close!(id)`
  lets go early. Their results are `Try(Str, Str)` and `Try(List(U8), Str)`, types the ABI had, so
  the glue wasn't regenerated. `fetch_chunks!` hides the id: a handle Roc could keep past its call
  would be a leak, a fold can't be.

**Tests.** `server/test/server.test.mjs`: `--max-body` and `MAX_BODY` (1 KiB: the limit fits, a byte
more is a 413, said and chunked; 2000 from the environment; 0, `lots` and `16 MB` refused, exit 2);
the log's events (a job's failures with their fields, migrations, plugins, a check, mail kept;
`sqlite.test.mjs`'s migrations, pretty); kept connections counted by a server the test runs (five in
a row on one; four at once, then reused; 1,000 bytes dropped and drained, 4 MiB dropped and closed;
`connection: close`; `keep-alive: timeout=2` let go after a second); a kept connection closed under a
GET, made again, and under a POST, not; a proxy the request names (a plain request whole with its
credentials and the target's host, one connection for two hosts, a tunnel with TLS to the server's
name, a 407 to a tunnel and to a plain request, `socks5://` refused, a proxy that isn't there); the
environment's (through it, loopback, `localhost`, `NO_PROXY`'s host and a name under one, `Direct`,
`HTTPS_PROXY` for an `https` URL, a named proxy taking loopback); `proxy.rs`'s six unit tests;
`fetch_chunks!` (three writes 80 ms apart as three chunks, stopped after three with the server
seeing the connection go, a 300 ms limit over the whole, a size limit over every chunk, a crash in
a step letting the body go); the docs' samples (`lines!`, `partner!`).

**What it costs.** A server that closes an idle connection just as it is reused fails a POST that
can't be made again (`HttpErr`, as Go's client would); the 30 s idle time keeps up to 32 sockets
a place open that a connection a request wouldn't. A `CONNECT` answer is read a byte at a time (its
head only, so nothing of TLS's is read by mistake). No SOCKS proxy, no HTTP/2.

**Reversible:** yes. The pool is `checkout`/`checkin` in `client.rs` (a connection a request again
is `IDLE` at 0); the proxy is `Init`'s field with a default, so code that never names it is
unchanged; `fetch_chunks!` is new; the log events are messages and fields an app's log reader may
match on, which would change back.


## D-057 The server's live gaps: dropped or gone, timers that outlive a restart, a deadline for Roc that never waits, flags kept

**Status.** Built (2026-11-23). The user chose, on the worker's recommendations: the post's
cookies for a channel subscribed over an open stream (with an unguessable id bound to the tab and
the stream, the same-origin check, and refusals for a wrong or another tab's id); presence leaving
at once on `Dropped`; timers written outside the caller's transaction, told at least once.

**Context.** Four limits listed in server/README.md's "Not yet" and TODO.md: a change of what a tab
subscribes to opened its stream again, so `on_close!` heard `Gone` for a channel the page dropped
as for a tab that closed; actors' timers lived in the host's memory, and a restart lost them; a
job's time limit ended it only at an effect that waits, so Roc looping without one held its worker
(and its Roc thread) for good; and packages/guard's flag overrides lived in `Kv` alone since D-043.

**Decision.**

- **Channels: changes over the one stream** (`channels.rs`, the hub in `runtime.js`). A stream says
  its id first (`event: hello`: 24 random bytes, hex), registered with its tab while it is open.
  The hub posts `{"channel":…,"subscribe":true}` and `{"channel":…,"unsubscribe":true}` to
  `POST /rocx/live/send?tab=…&stream=…`; the stream opens a subscribed channel as it opens those in
  its query (its check, `resync`, `on_open!`) and drops an unsubscribed one, purging what it had
  waiting to send of it and telling `on_close!` **`Dropped`**; a stream's end tells the rest
  **`Gone`** (`Channel.Closed : [Dropped, Gone, Refused(Str)]`). Ordering stays D-020's and the
  live gaps': one stream per tab, a tab's hooks in order (an unsubscribe's `on_close!` before a later
  subscribe's `on_open!`, even in one post; a channel dropped while its check ran is told
  `Dropped` once that check is answered, before anything asked after it). A subscribe's check is
  asked with the post's request headers, the tab's cookies as they are now, which the stream keeps
  for its beats from then on, so a page that signs in without a reload reaches members' channels
  (and one whose cookies no longer let it into a channel loses it at the next beat). The whole of
  `/rocx/live/send` now refuses a post another site's page sent (403, its `Origin` against the
  request's host, as `Server.same_origin` reads it: the app's middleware never sees `/rocx/live`),
  and a change naming no open stream of its tab (none, a wrong id, another tab's, one ended) is
  refused, 404, on which the hub opens a new stream. The hub posts a change only once the stream
  has said hello (changes made before are told then), opens a stream that never says hello again
  with the new set (an older server), and with nothing left to subscribe to tells the stream, then
  closes it. packages/presence leaves a room at once on `Dropped` (`Room.quit`) and after its grace
  on `Gone`.
- **Actors' timers are rows** (`server/platform/ActorTimers.roc`, `actors.rs`), with a database, on
  each backend (`rocx_actor_timers`: Postgres's migration `rocx/0004 actor timers`, SQLite's and
  Turso's `rocx/0002 actor timers`): a timer's number (random, 63 bits: the platform's now, not the
  host's counter, so a number kept in an actor's state names its own timer after a restart), its
  actor, message and time. `tell_after!` and `after!` write the row in a call of their own
  (`Host.isolated!("rocx:actor-timer-set", …)`, a name no plugin's call can have), outside any
  transaction the caller has open, then hand the host the timer (`Host.actor_after!` now takes its
  number). Once the turn that handled it has ended, however it ended, the host deletes the row
  (`rocx:actor-timer-done`); the platform's start, after the migrations, sets every row again for
  the time it has left. Delivery is at least once: a server killed in the middle of the turn tells
  it again after its restart. `cancel!` deletes the row and stops the timer, also one that has
  fired whose turn hasn't come (the router keeps a flag for each fired timer until its turn,
  which drops the message). Without a database, timers are in memory, as before.
- **A deadline for Roc that never waits** (`host/src/preempt.rs`). Each Roc thread has a slot with
  the deadline of the call running on it, kept by `hosted` as calls start, pause, resume and end
  (none while paused). A watchdog thread signals (`SIGURG`) a thread whose call is past its
  deadline, every 2 ms until it ends. The handler reads where the thread was interrupted: in Roc's
  compiled code, which Roc's linker puts in a segment of its own (`__ROC_TEXT`, found through the
  executable's load commands on macOS; on Linux the one executable `PT_LOAD` that isn't the host's),
  it rewrites the context so the thread calls `preempted` there (the return address the
  interrupted instruction), which ends the call as an effect past its deadline does (`cut_off`,
  then `roc_crashed`'s jump to the call's guard); elsewhere (host code, a hosted function, the C
  library, where a lock may be held) it only marks the call, and the next `roc_alloc`,
  `roc_realloc` or `roc_dealloc` (which only Roc's code calls now: the host's own helpers use
  functions of their own) ends it holding nothing. A jump from any instruction of Roc's code is
  what `roc_crashed` already does (a crash may happen anywhere in it), and what the call allocated
  is in its list and freed. That segment was only a dev build's (the fork's fast dev link,
  `src/cli/macho/PatchLink.zig`); an optimized build (`--opt=speed`: LLVM, and the system's
  linker) puts Roc's code in `__TEXT` after the host's, so it landed first for dev builds alone.
- **Then, for every build: an "in Roc" flag** (the user's choice, 2026-11-23). Each Roc thread
  keeps a flag that it runs Roc: the trampoline of a call's guard (`roc::guarded`'s `run`) sets it
  once the jump target is set (never before: a jump into a target half made would be lost), and
  the guard puts it back however the call ended; every function Roc calls clears it first thing
  and puts it back as it returns (`let _host = preempt::host();`, a guard dropped last: the 6
  runtime symbols, the 111 hosted functions of `hosted.rs` and `signals.rs`, the 6 `RocHost`
  callbacks, and the interrupt's own landing); a paused call stashes it with the rest of its state.
  The handler redirects only when the flag is set and the PC is in one of the executable's own
  code segments (macOS: those its load commands mark executable; Linux: its executable `PT_LOAD`s),
  never a library's (dyld's binder or the system allocator could hold a lock). With the flag set
  the thread is in Roc's code, or in code that holds nothing a crash there wouldn't: the guard's
  trampoline building its arguments (whose allocations go through `host_alloc`, which clears the
  flag), the glue's own callbacks between Roc and an allocation, `memcpy` called by Roc. Forgetting
  the line is made impossible by a test that reads the sources (`server/test/host-entries.test.mjs`):
  every runtime and hosted symbol the glue declares must be defined with it first, and so must every
  function the host exports and the callbacks it hands Roc. Roc's code in a section of its own, from
  the fork's LLVM backend, would let the handler tell it by address instead: cleaner, but a compiler
  change and a PR the user opens (TODO.md).
- **guard's overrides in a table** (`FlagStore.plugin({})`, D-033): plugin `guard`, migration
  `guard/0001_flags` (`guard_flags`: a row a flag, its override as JSON, `""` once reset), a start
  that reads the table into `Kv` and keeps `guard:flags-kept` (`Plugin.keep!`), and `needs:
  [Database]`. With it listed, `FlagStore.set!` and `reset!` upsert the flag's row (a reset too, so
  every change to a flag writes the same row: Postgres's row lock, SQLite's write lock, or Turso's
  conflict and rerun order them) and change `Kv` in the same transaction, before its commit, so
  changes reach memory in the order they reach the table. Without it, `Kv` alone, as before; an
  app without a database doesn't list it.

**Why.** Each closes a gap a real app meets: presence flickered a member who switched rooms, a
reminder set for tomorrow vanished with a deploy, one bad loop in a job took a Roc thread for good,
and a maintenance switch flipped back on a restart. Each stays as small as it could in the host:
the timers' rows, the flags' table and presence's leaving are Roc, in the platform and the
packages; the host adds a stream id and two posts, a router flag, and the interrupt.

**What it costs.** A subscribe is a post and a check rather than a reconnect: cheaper for a page
that switches channels, but the hub now keeps what it told the stream. A stream's id is a
credential for its tab's subscriptions, sent only in the stream, and guarded by the post's
same-origin check. Timers cost a row and two small calls each (set and done); every timer is set
again at start, a task each in memory, which an app with millions of far timers would want read a
window at a time. The interrupt is a signal handler that rewrites a thread's registers, per
architecture (aarch64 and x86_64, macOS and Linux: run on arm64 macOS, by the tests, and on arm64
Linux, the test app built `--target=arm64musl` in a container, dev and optimized builds both; the
flag costs two writes of a thread-local and a compiler fence around each call into the host,
allocations included; the x86_64 paths are written, but
neither built nor run here: this machine has no x86_64 toolchain, as `x64mac` and `x64musl` aren't
run yet);
it relies on Roc's linker keeping the app's code apart, which a future linker could change (then it
says so, and falls back). Overrides cost a row write per change.

**Reversible:** yes: the hub's old reconnect is its fallback for a server without `hello`;
timers without a database are as before; the interrupt is off where Roc's code isn't found; the
guard plugin is opt-in.

## D-058 `Db`'s queries checked at build: the engine describes, the compiler checks rows

**Status.** Built (2026-11-23), phases 2 to 4 of `spike/db-checked/DESIGN.md`, whose questions
were answered as recommended except the eighth (below). The spike it measured with is beside it;
phase 5 is in TODO.md.

**Context.** `Db.all!` and `Db.run!` take SQL as a string, and `Json.parse` decodes the rows into
the record the caller annotated (D-022). So a typo in a column, a field the statement doesn't
return, or a nullable column read as a plain value shows up only when the call runs. The last of
these shows up only when a row is actually null. D-016 deferred checked queries; roc-pg checks
its own at compile time. Since D-045 and D-046 an app runs on Postgres, SQLite or Turso. Of the
repo's 270 `Db` calls, 241 take their SQL as a literal at the call.

**Options** (the design's §11). The engine describes and the compiler checks rows (chosen); rocx
reads row types from the text; `Db.all!` takes a `Db.Sql(row)` checked at the literal, as roc-pg's
are (the platform can't reach the app's schema without every module importing a generated `Db`);
query files and generated functions, as sqlc and Squirrel do (every app's SQL moves); a SQL grammar
in Roc (months, and less faithful than the engine); a check at run time (only what tests reach,
and blocked by a compiler bug).

**Choice.**

```
$ rocx check --sql examples/plate
rocx check --sql: 38 statements checked on SQLite (the rows of 22 against their records): no problems
```

- **The engine describes.** `--describe-sql FILE` on the app's own server answers no HTTP. It runs
  the platform's start (the platform's, the plugins' and the app's migrations) on a scratch
  database of the app's kind, prepares each statement in FILE without running it, prints the
  engine's error or the statement's parameters and columns as JSON, and removes the scratch. Each
  column has its name, its type, how the host reads it (`kind`), and, when it comes straight from a
  table's column, that column and its `not null`: SQLite's column metadata, Turso's plan,
  Postgres's `pg_attribute`. The scratch is a SQLite or Turso file in a directory of its own under
  the system's temporary directory, or a Postgres database (`rocx_check_…`) made on the server
  `--database-url` names and dropped after. **Question 8, as the user changed it:** the check never
  migrates or describes a database nobody named for it. Without `CREATEDB` it fails, saying to
  grant it or to name one it may migrate (`--sql-database URL`, `ROCX_SQL_DATABASE`), the only kind
  it ever migrates.
- **rocx checks SQL and parameters.** `rocx check --sql [dir] [--engine sqlite|turso] [--verbose]
  [-- server options]` (rocx-cli/Sql.roc, rocx-cli/CheckSql.roc) reads each `Db.all!` and
  `Db.run!` whose SQL is a string literal at the call, outside comments and strings, with the
  parameters it gives when they are a list literal. It builds the server as `rocx dev` does
  (nothing, for an app with no SQL) and reports, at the call's `file:line:column`, what the engine
  refused and parameters that aren't the statement's `$1` to `$n`, each used. SQL interpolated, in
  a variable, or `Db.unchecked(sql)` (an identity, for a table the app makes as it runs) is
  counted, and listed with `--verbose`.
- **The compiler checks rows.** For each `Db.all!` whose row type rocx reads (a binding's
  annotation `rows : List(T)` or `Try(List(T), …)`, the call followed only by `?` or `.map_err`; or
  the result of the function whose body the call is, or whose block it ends), rocx writes a check
  app: `build/sql/check/main.roc`, beside a copy of the app's sources, since an app file can't
  import modules above its own directory. The app has the app's header with `dbcheck` added, the
  imports of each call's module (its own types qualified, `Store.Row`), and a constant a call,
  `q1 : DbCheck.Rows(T, Tags)`, whose string is the description as text (a line a column, its parts
  between tabs). `roc check` compiles it. `DbCheck.Rows.from_quote` (packages/dbcheck, plain Roc on
  no platform) runs at compile time: it reads `T`'s fields through `Probe`, a format that reads
  nothing, in two passes (`Nulls` answers `parse_null` with null, `Kinds` without), as roc-pg's
  `RowFormat` and `OpenApi.Schema` do. It refuses a field the statement doesn't return, a type the
  column's values can't decode into, or a plain field over a column without `not null`; rocx reads
  the compile errors back and reports them at the calls. `Tags` holds the app's capitalized words,
  the names a tag union in a row is tried with.
- **When.** `rocx check --sql` exits 1 on a finding, and `just examples` runs it for every
  example. It exits 1 too when the check app doesn't compile for another reason than a row (an
  error in it, or in the copy of the app's modules), saying where and what the compiler said, or
  when `roc check` ends in a way rocx can't read: its rows weren't all checked. (Until 2026-11-24
  that was a note `--verbose` listed, exit 0; when D-065 made `init!` required and the check app
  had none, every app's rows went unchecked, and `just examples` passed.) `rocx dev` runs it after each build in a process of its own, with the server it built
  (`--server`, `--quiet`: an app with no SQL says nothing), and says what it finds while the server
  is served. `rocx build`, `roc check` and `roc build` don't change, and apps change nothing.
- **What it found.**
  - The examples' 133 literal statements and 80 rows check clean, in about a second an app; 8
    statements in examples/sqlite-vs-turso read tables its big run makes with `Db.script!`, and
    are now `Db.unchecked`.
  - On Turso (`--engine turso`), Turso refuses examples/board's `json_group_array(value order by
    key)` (no `order by` inside an aggregate) and the FTS5 tables of examples/notes and
    examples/plate. Those apps run on SQLite, so neither matters until one is started on a `turso:`
    URL; the Turso docs say so.
  - The server's Postgres test app: 40 statements and 19 rows. Its six findings are exactly the
    statements its tests make fail on purpose.
- **Not yet** (TODO.md): nulls from an outer join's other side and SQLite's expression types (both
  read from the plan, as sqlx does); interpolated SQL whose pieces are module constants; a
  description cache for a Postgres app's CI; Postgres parameter types; packages' own SQL, per
  backend; the checks in the app's own compile; a check at run time.

**Why.** The engine is the only exact judge of its own SQL, and describing costs milliseconds; the
compiler is the only exact judge of a Roc type, aliases and packages included. rocx only connects
them, as it does for `Generated/Api` (D-037). Nothing in `Db` changes, so no app does.

**Reversible:** yes. Nothing in `Db` changes but `Db.unchecked`, and the check is a command.

## D-062 rocx on a platform of its own: `rocx dev`, `rocx check --sql` and `just dev` in Roc

**Status.** Built (2026-11-23). The spike it started from is `spike/cli-platform/DESIGN.md`. The
user's answer to its questions was "move as much as possible into the Roc rocx, without Node, and
see if it's faster", so its recommendations were taken, but one: the site's extra steps are rocx's
own (`rocx site prepare`), not a program of the site's.

**Context.** D-032 made rocx Roc on basic-cli. Three things stayed Node:
- `rocx dev`, which handed off to `rocx-cli/dev.mjs`;
- `rocx check --sql`, which handed off to `check-sql.mjs`;
- `just dev`, which was `site/serve.mjs` with `site/build.mjs --dev`, whose prepare step ran
  `site/reference.mjs` and the generators in the measuring scripts.

A dev loop needs a tree watched, children stopped with SIGTERM (the server finishes what it is
running), the signals it is sent, and one wait for whichever of those comes first. basic-cli 0.28.1
has children and signals, but no watcher, no choice of signal, and no way to wait on several things
at once. The page reload needs no HTTP in the loop: under `--dev` the server serves `/__reload`.

**Options.**
1. basic-cli, with a loop that polls: sleep, poll the signals and each child, walk the trees.
2. A platform of the repo's own. This is D-032's option 4, which now has something basic-cli lacks.
3. Keep the loops in Node.

**Choice.** 2.
- **`cli/`**, the platform: `cli/platform` in Roc, and `cli/host` in Rust on the C library alone.
  - It has output, stdin, the environment, files (`create_new!` for locks, `copy!` and `delete!` of
    trees), and `Cmd`, a command run to its end, beside the program (`Child`), or in its place
    (`exec!`).
  - It has `Watch.dir!` and `Events.next!`, the one wait. A program that watches is one plain loop.
  - The host reports a file only when its size or time changed, or it appeared or went.
  - On macOS it watches with FSEvents, loaded with `dlopen`, since Roc links an app against libc
    alone. Elsewhere it polls.
  - See `cli/README.md`.
- **rocx-cli** moved onto it; its file effects were already in `Fs.roc`.
  - `Dev.roc` is the loop, for a plan of what to build, serve, watch and check.
  - `rocx dev` is an app's plan, with rocx build in-process.
  - `CheckSql.roc` is `rocx check --sql`.
  - `Hosts.roc` finds Roc, Zig and the target, and builds the server's host (skipping cargo when
    nothing under `server/host` is newer than the library), the CLI host, and rocx itself.
  - `Site.roc`, `SiteSources.roc` and `SiteReference.roc` are `rocx site prepare`. The generated
    files are byte for byte what the JavaScript wrote; site/build.mjs calls it.
  - `SiteDev.roc` is `rocx site dev`, which is `just dev`. When rocx's own Roc changed, a build
    builds rocx again, and the loop runs the new rocx in its place (`Cmd.exec!`), so an edit to
    rocx, its loop included, is used at once.
  - `rocx self-build` rebuilds rocx when stale, as `rocxBinary()` does, under the same lock.
  - `dev.mjs`, `check-sql.mjs`, `site/serve.mjs` and `site/reference.mjs` are gone, and rocx runs
    no Node.
- **The Justfile** gets rocx from `bin/rocx self-build`, or `just rocx-bootstrap` (cargo, then roc)
  when there is none. `just dev` is `rocx site dev`, and `just check`/`just test` prepare the site
  with `rocx site prepare`.

**Still Node:**
- the tests;
- `just site`'s full build: it measures the wasm in Node with `web/runtime.js`, and prerenders
  through the server;
- the measuring scripts (example-apps, sqlite-vs-turso, example-shots);
- `server/build.mjs`, for the JavaScript.

Measured against master's Node, Node and Roc runs taking turns, three rounds, the machine loaded
by other work (load 9 to 12 on 10 cores; medians; a save is the time from writing the file to the
new server listening):

| | Node | Roc | |
|---|---|---|---|
| `just dev`: started, serving | 1.92 s | 1.26 s | 1.5× |
| `just dev`: a save, served | 1.37 s | 1.07 s | 1.3× |
| `rocx dev examples/tasks`: a save, served | 0.73 s | 0.60 s | 1.2× |
| `rocx check --sql examples/tasks` | 641 ms | 471 ms | 1.4× |
| the site's prepare (`rocx site prepare`) | 443 ms | 295 ms | 1.5× |

The gain is Node's start (a process each save, for `just dev`), the build in-process, and cargo
skipped when the server's host hasn't changed. What is left of a save is mostly the server
stopping and starting.

**Costs.**
- A second Rust host to keep, and one per target. Linux is named but untried.
- Adding a hosted function renames the glue's result types; `cli/host/src/lib.rs` aliases them in
  one place.
- Making rocx from nothing needs cargo, which the server already needs.
- Output is text: a command's bytes that aren't UTF-8 are replaced.

**Reversible:** yes. The ported scripts are in history, and basic-cli's API was a drop-in shape for
most of rocx-cli.

## D-063 iOS and Android apps: the same .rocx files, native views, no JS

**Status.** Proposed (2026-11-23); the Android spike in master since 2026-11-24, as an experiment to
iterate on (nothing of it runs unless asked for). The design, with its phases and the questions it
waits on, is `spike/native-apps/DESIGN.md`. The web stays the primary target; this is background
work. Built (2026-11-23, branch `nxy7/native-android`): `native/core` (the engine and the hosted
functions: 63 since landing, master's D-040, D-053 and D-054 among them), `native/android` (JNI, a
Kotlin applier, `build.sh`, no Gradle) and `native/mac`; `spike/native-apps/phone-hello` runs as
native views on the emulator with typed calls to the server (`spike/native-apps/README.md`). The
app's Roc is the fork's `arm64musl` archive linked by the NDK, so no fork change was needed. Native
code was chosen; OTA is deferred (DESIGN.md, Later). An Expo-like dev mode followed: `rocx dev
--android` and a dev client that loads each build's library (built by Roc's dev backend) in place
of the last, about a second from a save to the phone, each reload a fresh start (the user's choice:
no state kept), a failed build's error on a red screen, phones on Wi-Fi by a QR code (`--lan`,
`packages/qr`) and the phone's log in the terminal over HTTP (README.md, Dev mode).

**Context.** The user wants iOS and Android apps from an app's `.rocx` files, the way React Native
gives them, with Lynx's approach (a web-like vocabulary and a CSS subset rendered as native views)
and no JavaScript. Lynx itself can only be driven from JS (its Element PAPI is main-thread JS
globals; no public native API; wasm only on Android, interpreted), so it was ruled out. A
component's markup already reaches its host as JSON whose holes are boxes the host runs, with no
DOM operation in `Host.roc`, so the Roc side carries over.

**Proposal.**

- The app compiled for a phone is the browser's app compiled for another target: `web/platform`
  gains `arm64ios`, `arm64iossim` and `arm64android` targets, with the same hosted functions.
- `native/core` (Rust, no platform code): a port of `runtime.js`'s engine, minus the DOM; a CSS
  subset compiled and checked at build time; Taffy for block, flex and grid layout; batches of view
  ops per flush. `native/ios` (objc2) and `native/android` (JNI and a small Kotlin applier) turn the
  ops into native views and measure text.
- HTML tags keep their meaning (a `<div>` is a view, a `<p>` a text view, an `<input>` a native
  field, a same-app `<a>` pushes a screen). What a phone can't do is reported by the build, never
  refused for the web.
- One thread, as in a browser; the same server over HTTP with a cookie jar; every page in the
  binary, a stack of screens, layouts kept.
- Phase 0 needs no phone: the engine, linked with `web/test/app` compiled for the Mac, must match
  Chromium's DOM after the same steps.

**Costs.** Two reactive engines (JS and Rust) held together by a conformance suite; a CSS subset
that can make a web page look off on a phone; three more fork targets; about two and a half to
three months of background work to Plate on both phones.

**Reversible:** yes. Everything is in `native/` and new platform targets; the web's code paths
don't change.

## D-064 Every app's optimized server is built with boxy lowering (`--specialize=no`)

**Status.** Built (2026-11-23). The user's decision: make D-040's workaround for the docs site the
default for every app, and measure whether the browser's wasm should follow.

**Context.** Roc's `--opt=speed` specializes lambda sets by default: a call through a closure field
becomes a switch over every closure the program stores there, each case the closure's body inlined.
An app's pages all sit behind such calls (`Html`'s holes and components hold closures, and D-040's
route levels put every page behind one dispatcher), so one function ends up holding the whole app,
and its cases' stack slots aren't shared. D-040 phase 2 found the docs site's server with a 12.4 MB
frame in `Html.serialize!`'s specializations, past the 8 MiB stack a render runs on (D-027): every
page overflowed it. The repro and the numbers are in `test/compiler-bugs/huge-frame-opt-speed`.
D-040 built the site's server alone with `--specialize=no`. The other apps were below the limit but
grew with their size (largest frame, specialized, at d782488: plate 848 KiB, journal 372, notes
192, quiz 132, board 120, uptime 104, tasks 80, test/e2e's app 36). The wasm-split spike
(spike/wasm-split/REPORT.md) also needs `--specialize=no`, in the browser's build.

**Options.**
1. Keep specialization, and build an app boxy only once it overflows (D-040's site-only case).
   An app finds out in production, on its first render past the limit.
2. Bigger render stacks. The frame grows with the program, so no size is safe. Each coroutine
   (D-027) would reserve it too.
3. Boxy lowering for every optimized server, with a way back in.
4. Wait for the compiler fix.

**Choice.** 3, with 4 still to come.
- **`server/build.mjs`'s `specializeFlags(opt, specialize)`** gives `roc build` its flag:
  - nothing for the dev backend;
  - `--specialize=no` for `--opt=speed` (and `--opt=size`, whose default it already is);
  - `--specialize=yes` when asked for.
- `buildApp` uses it, so every build of an app does: `node server/build.mjs … --opt=speed`, `just
  site`, the measuring scripts, echo's `bench.sh`, and the tests' builds (test/e2e's,
  `ROCX_TEST_OPT=speed`). So does packages/testing's `buildForTests`, so `just examples` and the
  examples' tests do too.
- The site's special case is gone.
- **Opting back in:** `--specialize=yes` to `server/build.mjs`, `specialize: true` to `buildApp` or
  `buildForTests`, or `ROCX_SPECIALIZE=yes` in the environment for every build.
- **rocx build and rocx dev:** nothing changes. `rocx build` writes the program and compiles nothing,
  and `rocx dev` builds with the dev backend.
- **rocx itself** (`bin/rocx`, on the CLI platform) stays specialized. It isn't an app of pages,
  and its largest frame is 28 KiB.
- **The browser's wasm stays specialized** (`--opt=size --specialize=yes`, the site's
  `CLIENT_OPT`, and the tooling page's Justfile). Measured below, boxy is worse there.

**The numbers.** Measured on an M5 (10 cores) shared with other sessions' builds (load 10 to 27),
the two builds taking turns.

*Largest stack frame of each app's `--opt=speed` server* (the stack probe in a function's prologue,
in 4 KiB pages; 8 KiB is the host's own Rust, turso's and ring's; with boxy only two of the
site's Roc functions are big enough to need a probe):

| App | specialized (D-040) | boxy | boxy build |
|---|---|---|---|
| the docs site | 12.4 MB (overflows) | 28 KiB | 77 s |
| plate | 848 KiB | 8 KiB | 19 s |
| journal | 372 KiB | 8 KiB | 12 s |
| notes | 192 KiB | 8 KiB | 16 s |
| quiz | 132 KiB | 8 KiB | 18 s |
| board | 120 KiB | 8 KiB | 17 s |
| uptime | 104 KiB | 8 KiB | 32 s |
| tasks | 80 KiB | 8 KiB | 17 s |
| test/e2e's app | 36 KiB | 8 KiB | 18 s |
| checkboxes, echo, hello, sqlite-vs-turso | 8 KiB | 8 KiB | 4 to 7 s |

(Build times include `rocx build`. Specialized builds took 2 to 6 minutes for the site, 74 s for
board and 26 s for journal.)

*Rendering on the server*: Roc's own time per page (the `server-timing` header), one request at a
time, 8 rounds, medians. No HTTP benchmark.

| App | specialized | boxy |
|---|---|---|
| journal (9 pages) | 0.85 ms a page | 0.96 ms |
| board (2 pages) | 1.30 ms a page | 1.46 ms |
| the docs site (48 pages) | overflows | 363 to 386 ms a round at best, as D-040 measured (376 and 369 ms for 50) |

Boxy costs the examples about 12% (0.1 ms a page). The site's round drifts with the machine's
load, not with the server's age: a fresh server is no faster, and its RSS stays at 42 to 64 MB.

*The browser's wasm*, `--opt=size` specialized against boxy:
- sizes in KB;
- rendering a page in Node as `site/build.mjs` measures it (warm, median of 5 interleaved rounds);
- hydrating it in Chromium (`rocx:ready`'s ms, the time the site's pages show; median of 12 loads
  each, alternating).

| | site, specialized | site, boxy | journal, specialized | journal, boxy | board, specialized | board, boxy |
|---|---|---|---|---|---|---|
| raw | 1372.6 | 1173.3 | 402.8 | 490.3 | 895.8 | 805.9 |
| gzip | 417.1 | 411.2 | 138.7 | 183.0 | 273.9 | 284.3 |
| brotli | 300.6 | 311.2 (+3.5%) | 109.4 | 144.0 (+32%) | 199.5 | 216.3 (+8%) |
| rendering | `/` 430 µs, `/components` 4.5 ms, `/routing` 1.1 ms, `/ecosystem/charts` 43 ms | 507 µs, 4.7 ms, 1.1 ms, 85 ms | `/en` 106 µs, a post 555 µs | 132 µs, 599 µs | `/` 250 µs, a board 4.2 ms | 344 µs, 4.6 ms |
| hydrating | 14, 23, 15, 39 ms | 7, 16, 8, 35 ms | 6, 9 ms | 6, 10 ms | 9, 18 ms | 8, 15 ms |
| build | 12 s | 5 s | 3 s | 2 s | 11 s | 5 s |

In the browser, boxy is bigger to download on all three apps, and renders slower once warm (the
charts page half as fast). Hydrating is the same or a few ms quicker, probably because there is
less code to compile before the first run. Boxy is worse on two of the three measures, so by the
rule set for this decision (boxy only if it is no worse) the wasm stays specialized. One thing
doesn't follow that rule today: the examples' and the tests' wasm is built `--opt=size` alone
(packages/testing, `just example-apps`, README's build line), which is boxy by the compiler's
default. Specialized, journal's would be 24% smaller with brotli (TODO.md).

**Costs.**
- Server renders are about 12% slower on the examples measured: 0.1 ms a page.
- echo's published benchmark (8f7abc5) is of a specialized build. It ships boxy now, and runs again
  only on the user's go (TODO.md).
- The site's server already built boxy, so its pages are unchanged.

**Reversible:** yes, by an app (`ROCX_SPECIALIZE=yes`) or for all (`specializeFlags`'s default).
Once the compiler keeps a frame from growing with the program, specialization can be the default
again. The fix would keep closure bodies out of line past a size, or let a switch's cases share
their stack slots (lifetime markers on the allocas). Then measure the site's and plate's frames
specialized again.

## D-065 The app's context: made once by `init!`, kept by the host, given to everything that runs the app's code

**Status.** Built (2026-11-24). Open: whether a route's handler is given the app's context beside
what its middleware hands on, and under what name; the jobs plugin's `on_failed!` and plugins'
early paths aren't given it.

**Context.** An app's `respond!` was given `--context-file`'s text with each request
(`context(started)`, a pure function), and nothing else was given anything: a setting read from the
environment was read again on every request, a value worked out once had nowhere to live, and jobs,
actors and plugins' loops reached for effects of their own (`Env.var!`, D-006). The host kept no
Roc value from one call to the next: what it kept was text (`memory.rs`, actors' state).

Roc's own webserver platform (roc-lang/basic-webserver, on the new compiler) has the shape apps
want: `requires { [Context : context] for program : { init!, respond!, … } }`, `init!` making the
context once, every `respond!` given it, the host holding it as one boxed pointer and adding a
reference a request.

**Options.**
1. Keep `context(started)`, and settings read on every request.
2. `init!` returns data alone, kept as text (as `memory.rs` keeps the job registry) and decoded for
   each call: no host change, but nothing that isn't JSON (no functions, no handles).
3. `init!` returns any value, boxed; the host keeps it for as long as the server runs and hands it
   to each call, which shares it.

**Choice.** 3.
- The platform requires `[AppContext : app_context] for program`, with
  `init! : Str => Try(app_context, Str)` (`AppContext`, as the platform already exposes a module
  called `Context`). An app needn't name the type: the compiler takes it from `init!`.
- The start is three calls: the platform's (the plugins checked, the migrations applied); the app's
  `init!`, given `--context-file`'s text, after the migrations so it may read the database, its
  `Err` stopping the server; then the actors' timers set again and the plugins' starts, given it. A
  check of the app's SQL (`--describe-sql`) makes only the first.
- The host keeps the box (`roc.rs`'s `CONTEXT`) and never lets it go. Each call that runs the app's
  code gets one reference more, which Roc lets go of as the call ends: a request, a plugin's call (a
  job's run), a background loop or check, an actor's turn, the plugins' starts. Roc's reference
  counts are atomic, so every thread reads it at once; no Roc value is changed while another holds
  it, and the host always holds it. A call that crashes never lets go of its reference: the count
  only grows, and the context, never freed, stays.
- A call made while `init!` runs that needs the context (an actor `init!` asks) is refused, saying
  so. The platform's own calls (`rocx:…`, its actors' timers' rows) have an entry of their own,
  given no context, and run then too.
- `App.program({ init!, middleware, … })`: the context is what the middleware is given for each
  request. `Job.define(name, |context, input| …)`, `Job.Kind(context, input)`; an actor's method
  is given it in its turn (`{ me, context, state, input }`, D-066); a
  plugin is `Plugin.Value(context, ctx)`, its calls, loops, starts and checks given `context`, its
  routes `ctx`. A kind's annotation names the context as the app has it with `_`
  (`Job.Kind(_, { member : I64 })`, `Actor.Method(_, state, input, reply)`): a value can't be generic
  in it.
- The per-request `started` the host passed along is gone; `--context-file` is `init!`'s.

**Why.** Settings, handles and work done once at the start, typed, in one place, failing the start
when they are wrong; the same shape as Roc's own webserver platform. Tests (`server/test/context`):
made once; 400 requests at once, some pausing, all seeing it whole; 50 crashes after reading it,
nothing left allocated; a stream reading it after its request ended; a job, an actor's turn and a
plugin's call, loop, start and check each given it; an actor asked from `init!` refused; an `Err`
from `init!` stopping the server. The box's reference count is 1 before every call.

**Reversible:** yes, at the cost of every app's `init!` becoming `context` again and every job's,
actor's and plugin's context parameter going.

## D-066 Actors' methods: each call its own input and reply

**Status.** Built (2026-11-24), with D-065.

**Context.** A kind of actor (D-021) had one `receive!` and one message type, a tag union, and one
reply type for all of them. An actor with many messages had a reply union of every answer, and
every caller matched all of it, including answers its message never gets: asking a quiz room how a
visitor sees it could only answer `Seat(…)`, but its caller handled `Done`, `Joined`, `Unjoined`
and `Refused` too, through helpers the app wrote to hide that. Adding a message meant editing the
union, the reply union and the one `match`; and with the app's context (D-065) `receive!` had four
positional parameters.

**Options.**
1. Keep `receive!`, its parameters a record. Fixes their order, not the replies.
2. A record of handlers, one field a message. Needs a first-class field name to ask with.
3. Methods, as Cloudflare's Durable Objects moved to (RPC methods in place of `fetch` and routing)
   and Orleans grains have: a kind is its name and starting state; each method its own input and
   reply.

**Choice.** 3.
- `Actor.Kind(state) : { name, initial }`, `Actor.define`.
- `Actor.method(kind, name, |{ me, context, state, input }| { state, reply })` is an
  `Actor.Method(context, state, input, reply)`; a turn is given one record, so a method takes only
  what it uses.
- `Actor.ask!(method, key, input)` is `Try(reply, [ActorErr(Str)])`, the reply its method's;
  `tell!`, `tell_after!(method, key, ms, input)` and `after!(me, ms, method, input)` likewise.
  `Me(state)` ties `after!` to methods of the actor's state's type, and the turn crashes if the
  method is another kind's.
- One mailbox per kind and key, as before: an actor takes one turn at a time whichever method
  each is, so its state is never touched by two at once. The host is unchanged: a call is the
  method's name, a newline and its input as JSON, and `actor_for_host!` finds the method.
- `rocx build` lists the methods an app's modules define (`x = Actor.method(…)` at the top of a
  module's block, or `x = |{}| Actor.method(…)`, a method that names itself through a timer), and
  still checks its kinds: placed there, `name` first, each name its own. Two methods of one kind
  with one name stop the server as it starts.
- A call the method can't take (an input of another shape: a caller built against an older kind)
  and a method the kind doesn't have are errors logged and told to the asker, as a message an actor
  didn't take was.

**Why.** Every reply typed for its call, nothing impossible to match, a method added by adding a
definition; the quiz's room lost its message and reply unions and the helpers that hid them. A
timer row or a stored state written before keeps its kind's name: state reads as before, and a
timer's old message, with no method name, is refused once and logged.

**Reversible:** yes, every actor rewritten again.

**Since D-067:** a kind has a key type, `Actor.Kind(key, state)`, `Actor.Method(context, key, state,
input, reply)`: text with `define`, the app's own with `define_keyed`.

## D-067 Actors' keys: a kind's own type

**Status.** Built (2026-11-24).

**Context.** An actor's key was text. A key with a shape was a string with a format, which the app
made and then parsed back in its rules (a quota's `instagram:<account>`, read with
`starts_with("instagram:")`), and any text was any kind's key: a post's id passed to the quota
actor compiled. D-066's methods also made every method's annotation long, `Actor.Method(_, state,
input, reply)`, and a key type would make it longer.

**Options.**
1. One `ActorId := Str` for every kind. Keeps text out, but a post's id still fits a quota.
2. A key type a kind's own, as JSON in each call. Nominal types have no JSON of their own, so every
   key type would write its codec.
3. A key type a kind's own, named by its `to_str` and read back by its `from_str`.

**Choice.** 3.
- `Actor.Kind(key, state)`; `Actor.define({ name, initial })` is a kind keyed by text, as before;
  `Actor.define_keyed({ name, initial })` one keyed by any type with `to_str` and `from_str` (a
  nominal type of the app's; the numbers have both), the two kept in the kind. `Str` has `to_str`
  but no `from_str`, hence the two.
- What `to_str` makes of a key is the key, in the host, the log and the database (`rocx_actors`,
  `rocx_actor_timers`): a key type that makes the text a kind used before keeps its actors' state.
- A turn is given the key as it is typed: `Actor.key_of(me)`, and `initial`. `Me(key, state)`
  keeps the text too, which `after!` names the actor by. A text the kind's `from_str` doesn't read
  is an error, told to the asker.
- `ask!`, `tell!` and `tell_after!` take the key as it is typed. `Actor.Method(context, key,
  state, input, reply)`; `Actor.Turn(context, key, state, input)`.
- A module names its kind's methods' type once, the app's context first:
  `Method(input, reply) : Actor.Method({}, Str, State, input, reply)`. An alias can't hold `_`, so a
  package, which doesn't know the app's context, keeps it a parameter (`Method(context, input,
  reply)`, written `Otel.Method(_, …)`).
- `rocx build` finds `Actor.define_keyed` as it finds `Actor.define`.

**Why.** A key's shape is a type, matched rather than parsed, and a key of another kind's type
doesn't compile; a method's annotation is its input and its reply. Tests (`server/test/context`):
a kind keyed by a slot of the app's own type and one by a number, each key its own actor, the turn
given the key typed, `initial` the number, a timer finding its actor by the key's text, and the
database naming each by its `to_str`.

**Reversible:** yes: every annotation loses its key again.

**Since D-068:** a kind is a type with `name` and `initial`, and a key needs `to_str` and
`from_quote` (`Actor.Keyed`), so `define` and `define_keyed` are gone.

## D-068 A kind of actor is a type; a method is called on the method

**Status.** Built (2026-11-24).

**Context.** A kind was a value made by `Actor.define` or `Actor.define_keyed`, and its methods
named it (`Actor.method(Rooms.room, "join", …)`): a module was a namespace holding the kind and its
methods, and calls went through the module `Actor`: `Actor.ask!(Rooms.join, code, input)`. A timer
to another kind's method compiled and crashed the turn at run time. Roc has no interfaces, but
static dispatch and where aliases (named groups of method requirements, met by any type that has
the methods) do the same work.

**Options.**
1. Keep kinds as values; name the key's requirement (`Actor.Keyed`).
2. A kind is a type with `name` and `initial` (`Actor.Kind`, a where alias); `Method` and `Me`
   nominal, with methods: `Rooms.join.ask!(code, input)`, `me.after!(ms, method, input)`.
3. Methods generated from an actor module in `.rocx`: `Rooms.join!(code, input)`, no name strings.

**Choice.** 2 (the user's).
- `kind.Kind(key, state) : where [kind.name : {} -> Str, kind.initial : key -> state]`: the module's
  type is the kind (`Rooms := [].{ name = |{}| "room"  initial = |_code| … }`); nothing declares
  it. A where requirement is a function, hence `name = |{}| "room"`.
- `key.Keyed : where [key.to_str : key -> Str, key.from_quote : Str -> Try(key, [BadQuotedBytes(Str)])]`:
  `from_quote` is what reads a key back (`Str` has it, and no `from_str`), and lets a string literal
  be a key, checked as the app is built. The numbers have none: a number key is a type of the app's
  over one. A where alias constrains only its receiver, so a use says both
  (`where [kind.Kind(key, state), key.Keyed]`).
- `Actor.Method(kind, context, key, state, input, reply)`, nominal, with `ask!`, `tell!` and
  `tell_after!` called on it; `Actor.method(name, run!)` takes no kind: its annotation says whose it
  is (`Rooms.Method(Str, Game.Seat)`, the kind's alias), so a method needs one.
- `Actor.Me(kind, key, state)`, nominal: `me.key()`, and `me.after!(ms, method, input)` takes only a
  method of its own kind, a type error otherwise (D-066 crashed the turn).
- `Actor.Turn(kind, context, key, state, input)`; `Actor.handler`, `Actor.cancel!` as before.
- `rocx build` finds kinds by their name (`name = |{}| "…"`) for its check that each is its own; a
  type may be anywhere, so their placement isn't checked.

**Why.** The kind is the module, as it reads; a call reads as the method it calls; the compiler
checks what a kind has (`Actor.Kind`), what a key has (`Actor.Keyed`), and that a timer calls its
own kind. The names stay strings (`Actor.method("join", …)`): Roc can't give a value its binding's
name, and option 3 would make every actor module `.rocx`. `name` and `initial` take those names in
a kind's block, so a local of the same name shadows them.

**Reversible:** yes: every kind becomes a value again and every call goes back through `Actor`.

## D-069 CI on GitHub's Linux arm64 runners, with the fork's compiler published as binaries

**Status.** Built (2026-11-24): on macOS runners first, the same day on Linux arm64 ones (the
user's).

**Context.** The repository is public and in an organization of its own, so GitHub Actions is free
for it, but nothing ran there: every build needs the Roc fork's compiler (`roc_fork_commit`), and
the fork's fixes are kept private until they are upstream, so a runner had no compiler to build
with. A newcomer without the fork was in the same place: `just setup` stopped.

**Options.**
1. A self-hosted runner on the machine with the fork. No upload, but every push runs the full gate
   there, and GitHub advises against self-hosted runners on public repositories (a pull request's
   code runs on the machine).
2. The fork pushed to a private repository, built in CI (10 to 20 minutes, cached per pin), with a
   token. Pushes the fork's source.
3. The fork's compiler as a binary in a private repository's release, downloaded with a token.
   Pull requests from forks get no secrets, so no CI.
4. The binaries as a public release of this repository; no token.

**Choice.** 4 (the user's), and Linux arm64 runners (the user's, after a first day on macOS ones).
- `just publish-roc-fork`, on the machine with the fork: the compilers built there, this Mac's
  (`just setup`, `.tools/roc-fork/<commit>/`) and Linux's on arm64 (`just roc-fork-linux`: the
  fork's commit cross-compiled by Zig, `zig build build-release -Dtarget=aarch64-linux-musl`, a
  static binary, into `.tools/roc-fork/<commit>-linux_arm64/`), each `bin/roc` in an xz tarball
  (44 MB; the binaries are some 275 MB), assets of release `roc-fork-<the commit's first 10>`, a
  pre-release. Nothing is uploaded if a binary's strings hold the home directory or a private
  word (as whole words: Apple's and Microsoft's API names have one inside theirs); an asset the
  release has is kept, one it lacks added. It prints each tarball's SHA-256.
- `roc_fork_sha256_macos_apple_silicon` and `roc_fork_sha256_linux_arm64` in the Justfile pin
  them. `just setup` builds from the fork where it has the commit, as before; elsewhere, on either
  of those, it downloads the release's asset for it, checks the SHA-256 and unpacks it in place of
  the build. A pin bump publishes first.
- `.github/workflows/ci.yml`: on every push to master and every pull request (a newer push stops a
  pull request's older run; pull requests grouped by number), five jobs side by side on
  `ubuntu-24.04-arm`: `just check` (then `just check-times`, below); `just site`; `just test` as
  two, its three parts being recipes of their own (`test-rocx` then `test-web`, each step run even
  when the one before failed; `test-server` beside them, with a Postgres 18 service as `just db`
  has it, user and password rocx, as `DATABASE_URL`); and `just examples`. The browsers are
  Playwright's Chromium headless shell and Firefox, with the system's libraries they need.
  `.github/actions/setup` is the toolchain: Node 24, just, Rust with the musl target, Zig and the
  nightly cached by their pins, the hosts' crates cached (saved by master's runs), then `just
  setup`.
- After `just check`, `just check-times` (test/check-times.mjs): each example's and the docs
  site's `rocx build`, and `rocx check` of each of its programs with `--no-cache` (all of the work,
  every run; a cached check is some 20 ms), the median of three. The job's summary has the table
  against the last green master run's numbers (its `check-times` artifact, which carries the last
  30 master runs' totals); a check slower by half and by 250 ms or more is a warning, not a failure
  (runners vary from run to run). So checking that grows slow, as apps, the platforms and the
  compiler change, is seen when it happens.
- The tests see what a laptop shows, whatever the machine says: web/test/browser.mjs launches
  Chromium with `--force-prefers-no-reduced-motion` and `--hide-scrollbars` (and, on Linux,
  `--no-sandbox`, as Playwright does), Gecko with the same as prefs. Tests that measure time allow
  `ROCX_TIME_SCALE` times as much (CI's runners: 3).

**Why.** Linux arm64 runners are free for public repositories, start at once, and run twenty jobs
at a time; GitHub's macOS arm64 ones left jobs unstarted twice on the first day for want of
capacity, and five at once is a free organization's most. rocx's Linux targets (`arm64musl`) were
in place; the fork's compiler is one static binary Zig cross-builds on the Mac that has the fork.
The fork's source stays private while anyone can build and test the repository.

**Reversible:** yes: delete the workflow and the releases; `just setup` falls back to the fork.

## D-070 One hole, and a hole's own `if` and `match` as control flow

**Status.** Built (2026-11-24).

**Context.** A hole said what it held by how it opened: `{x}` a `Str`, `{=x}` one `Html`, `{...x}`
a list of it, because rocx runs before the compiler and can't see a type. So a branch of markup was
`{=if (c) <b /> else <></>}`, and a number `{count.to_str()}`. In a component such a hole is a
computation: when anything its condition read changed, it ran again and made its whole branch anew,
so `{=if (count!() > 3) <Timer /> else <></>}` started a new `<Timer>` (its signals, its DOM, a
field's focus and text) on every click past 3. `<Show>`, `<Switch>` and `<Match>` (D-053, Solid's)
kept a part while its condition held, as components with props of their own (`when!`, `keyed`,
`fallback`, a function child narrowing a `Try`). The user asked for one kind of `if`, native rather
than components, that behaves as `<Show>` does.

**Options.**
1. Keep both: `{=if}` remakes its branch, `<Show>` keeps it; document when to use which.
2. Drop `{=if}`, keep `<Show>` as the only conditional markup.
3. One hole whose kind the compiler finds from the type, and the `if` and `match` in it compiled
   as `<Show>` and `<Switch>` compile, since rocx sees their branches (Solid can't: a JSX ternary is
   JavaScript); `<Show>`, `<Switch>` and `<Match>` gone.

**Choice.** 3 (the user's: "native constructs are just nicer"; a match arm's names following its
value, and numbers shown as they are).
- **One hole.** `{x}` is `Html.hole(x)`, or `Html.hole_of(|| Html.hole(x))` when it reads what
  changes: text, a number (its digits) or markup, by `x`'s type, through Roc's encoding:
  `Str.encode(Html.Hole)` is `Hole.encode_str`, a number's `encode_u64` and the rest, and
  `Html.encode` the markup itself. Another type (a record, a `Bool`) is a compile error at the
  hole. `{=x}` is the same hole, kept for old files; `{...x}` is still a list.
- **What a hole of either kind is.** Its JSON is `{"t":"hx"}`, and its run answers a JSON string
  while it shows text alone, its markup's JSON otherwise. The runtime, the server's renderer and the
  native engine write and patch it as a text hole (`<!--x-->`, the text patched) while it shows
  text, as a markup hole (`<!--html-->`) otherwise; text that turns into markup turns into a range.
  So a text hole costs what it did, in bytes, nodes and allocations.
- **`if`.** A hole whose code is an `if` (its `else if`s, in either form: `if (c) a else b`,
  `if c { a } else { b }`) and whose conditions read what changes is the part its branch makes
  (`Html.branched`, the machinery `<Switch>` had): the case names the branch that holds, and the
  part is made again only when another branch does, not when what the condition read changes
  otherwise. It is no level of the page (D-040: `Html.switched`'s, a route's keyed part, are), and
  the run that picks its branch reads the condition again without that counting as a read of the
  location made once (the case follows it). Each branch is a hole of its own, so what it reads itself still follows. A switched part
  whose case read nothing that changes is static: no comments, adopted as it is (D-052).
- **`match`.** The same, the case naming the arm. An arm's names are getters (D-039's machinery,
  the innermost view winning, the component's own props kept): `Ok(card) => <Card card={card} />`
  keeps the arm while the card changes, and the card the arm reads is the newest. Read once the arm
  no longer holds (never, as the runtime makes the arm again first), a name is `Html.unmatched!`, a
  failure. A guard is the case's too.
- **No `else` needed.** An `if` in a hole may leave its `else` out (`{if open!() { <Panel /> }}`,
  `{if (a) <x /> else if (b) <y />}`): rocx gives it `Html.empty({})`, each branch being a hole, so it
  fits whatever the branches show (the user, 2026-11-24, after the move left 120 `} else { <></> }`s).
  Only a hole's own `if`: one inside its code is Roc's, which needs one.
- **Text alone stays a text hole.** An `if` or `match` whose every branch is a string literal
  (`{if (pending!()) "Saving…" else "Save"}`) is a text hole, patched, as before; so is one whose
  conditions read nothing that changes (run once).
- **Lines.** The generated code keeps the source's line ends and their indentation.
- **What a test counts.** The browser host holds the last run's answer until the next; its live
  count leaves that out, since an `if`'s part answers markup, which needs the heap.
- **Keyed parts.** `<Show keyed>` made its part anew for each value; a `<For>` over a list of none
  or one, keyed by the value, does that (`keyed={|card| card}`: a key is its `Str.inspect`).
- **A value read once, checked.** Before, `{=match}` made its arm anew for each value, and
  components were written for that: `{ now, .. } = data` in a body read the arm's value once. With
  the arm kept, such a component keeps the first value, and nothing failed: only a dev build's
  read-once warning (D-052), in the browser, said so. rocx build now checks it across files: each
  component's body's reads of its props made once (no closure around them, outside an arm), by its
  tag, and each arm's name given to a component's value prop (or as an accessor prop,
  `found!={found}`); a match of the two is a warning at the call, which `rocx check` counts (exit
  2). `untrack!(|| data)` says the one read is meant. It found five: the private app's board, post
  and cover (made anew for each answer: a `<For>` keyed by the answer, the reads `untrack!`ed; the
  cover reads its saved one where it shows it), examples/board's card editor (another card opened
  kept the first card's editor, its lease and its saves: now a panel for each card opened, a
  `<For>` keyed by it) and examples/plate's food form (its starting values, read once on purpose:
  `untrack!`).
- **`<Show>`, `<Switch>`, `<Match>`.** Gone from both platforms; writing one is an error that says
  what to write. Every use in the repository moved: a `<Show>` an `if`, its fallback the `else`; one
  with a function child a `match` (`Ok(v) => …, Err(_) => fallback`), its accessor the arm's name.

**Why.** One way to write a branch, Roc's own, and the one that keeps what it made: the behaviour a
user expects of an `if` in markup. The compiler, not the syntax, says what a hole holds, as it can
where rocx can't. Solid needs components for control flow because JSX can't see into an expression;
rocx reads the `if` before the compiler does, as Svelte reads `{#if}`.

**Costs.** A hole's error for a value it can't show names `encode`, not `Str` ("does not have a
method named encode"). A condition is read by the case and again by the part (cheap: a signal or a
memo). A match arm's value is read again by each name's getter. An `if` whose branches are markup
returned by a function (`panel(data!())`) still makes that branch's hole anew when what it reads
changes: the part stays, its hole runs.

**Reversible:** partly: the hole and the `if`/`match` compilation can go back to D-053's components;
the moved files would move back.

## D-071 A hole's `.map` as a list's rows; `<For>` gone

**Status.** Built (2026-11-24).

**Context.** D-070 made a hole's `if` and `match` what `<Show>` and `<Switch>` were. A list was
still a component: `<For each!={todos!()} keyed={|todo| todo.id}>{|todo!, _| <li>{todo!().title}</li>}</For>`,
an accessor to call in every row. Roc's own `.map` was there too, `{...todos!().map(|todo| …)}`,
and was the worse of the two: a list that changed made every row anew (focus, typing, a
component's signals lost). The user asked whether `.map` could be what `<For>` was, as `if` became
`<Show>`, and chose (2026-11-24): a row with no key is refused, as a `<For>` without `keyed` was;
`<For>` goes.

**Decision.**
- **`{...list.map(|item| row)}`** whose list reads what changes is `Html.rows!(|| list, |item| key,
  |item!, _| row)`: a row per key, made once, moved with its key and dropped with it, as `<For
  keyed>` kept them. Its key is the row's root's `key={…}` (`<li key={todo.id}>`), any value (a
  string as it is, any other as `Str.inspect` writes it; an element's `key` takes any value too now). A row that is an `if` keys each branch;
  the first `key` on the row's outermost markup is the row's. A component's `key` is the row's, never
  a prop.
- **`.map_with_index(|item, i| … key={i})`** is `Html.rows_at!`: a row per position, as `keyed={Bool.False}`
  was, its index its position (a value; a getter would make a condition on it a switched part, which
  the server writes static and the browser, building it, wouldn't). A key made from the index
  otherwise is refused.
- **The row's names are getters**, as a match arm's are (D-070): the row reads its item now, and, in
  a row per key, its index, which changes as rows move. A row is effectful, as a `<For>`'s child was, so it may hold a
  component, an `if` or another `.map`. D-070's check across files counts a row's names as an arm's:
  one given to a component that reads it once is a warning.
- **Compared, always.** A row is told its item changed only when it isn't `==` the one it had
  (D-053's `compared`, a flag before): one changed item of a thousand runs one row's holes. Items must
  compare, as a store's parts do; every list in the repository and the private app does. A list of
  functions or markup is no list of rows (map it to the data first).
- **No key** is refused at the row, saying what to write. A list that reads nothing that changes is
  made once, as before, and needs none; nor does one inside a `<NoHydration>`, which is the server's.
- **`<For>`** is gone from both platforms (`For.roc`); writing one is an error that says what to write.
  Its fallback is an `if` beside the rows (`{if (todos!().is_empty()) <li>None</li>}`).

**Moved.** Every `<For>` in the repository (examples, site, packages, the web tests) by a converter;
`{...x!().map(…)}` holes whose list changes got keys (board's assignees and labels, notes' tags,
plate's portions, quiz's choices, tasks' assignees, the docs' sidebar); rows reading their id once,
each keyed by that id, say so (`untrack!`, board's column and archived card, uptime's admin row and
update form). The private app: its `<For>`s, D-070's keyed parts as `.map`s of one, and two lists.

**Why.** Roc's own way to make a list, and the one that keeps its rows: what a user writes first is
the right thing. One way to write a row.

**Costs.** A key on every row of a list that changes, where `.map` needed none (and made every row
anew). Items must compare. `Host.row_set!`'s `same` is always computed (`==` per row per change).

**Reversible:** yes: `<For>` can come back as a component over `Html.rows!`; the moved files would
move back.


## D-072 Sign-in as a package: packages/auth

**Status.** Built (2026-11-24). The user chose its shape: sign-in by a mailed link and at providers
(Google, GitHub, any OpenID Connect one) first, passwords next, passkeys later; the package keeps
sessions, links and identities, the app keeps its users and says who gets in; no pages in the
package (`rocx new` will have them).

**Context.** Every app signed in its own way: the private app with Google's OpenID Connect, sessions
kept by their token's hash and `__Host-` cookies; examples/notes with mailed links and a signed
cookie; uptime and plate with a password from the environment; tasks, board and journal with a name
in an unsigned cookie. Signing in is where a framework that gets an app to production fast has to
be right by default, and the user asked for it, with `rocx new` and a one-command install, as the
three things Roc Solid needs next.

**Decision.**

- **A plugin, `Auth.plugin({ admit!, providers, … })`**, whose endpoints (under `/auth`) each answer
  with a redirect: `GET|POST /auth/link` (a mailed link, used once), `GET /auth/<provider>` and
  `/auth/<provider>/callback`, `POST /auth/sign-out`, and `POST /auth/dev` under `--dev` only. A
  sign-in that fails goes to the app's sign-in page with `?error=link|refused|provider|state|
  unavailable` (and `&reason=`, `&then=`).
- **No pages.** The app's sign-in page posts to `Auth.link!`'s endpoint of its own (the app mails the
  URL, as it likes) and links to `/auth/<provider>` (`Auth.providers!` lists those set up). With
  `link_page`, a mailed link opens the app's page, which shows whom it signs in (`Auth.link_for!`,
  which doesn't use it) and posts the token from a button, so a mail scanner can't use links up.
- **The app keeps its users.** `admit! : Auth.Identity => Try(Str, Str)` is given the provider, the
  identity's subject there, its verified address, a name, and `Known(user)` when the identity signed
  in before; it answers the app's id for the user, or why not. It runs in the transaction that
  links the identity and starts the session, so what it writes stays only if the sign-in does.
- **Sessions in the database** (`auth_sessions`, the token's SHA-256; links in `auth_links`;
  identities in `auth_identities`), in one migration for SQLite and Postgres: times are
  milliseconds given by the package, so its statements are the same on both. A session lasts 30
  days and is kept for as long again when used in its second half, so requests don't write. The
  cookie is `HttpOnly`, `Lax`, and `Secure` and `__Host-` on HTTPS (the public URL).
- **Middleware**: `Auth.required(add)` and `Auth.optional(add)`, each putting the session into the
  app's context through `add`; a signed-out page's GET goes to the sign-in page with `?then=`, the
  rest is a 401. And `sign_in!`, `sign_out!`, `sign_out_everywhere!`, `sessions!`, `revoke!`,
  `identities!`.
- **OAuth**: the code flow with PKCE (S256), a state and a nonce kept in a ten-minute cookie; the ID
  token read from the token endpoint's answer over TLS (Core 1.0, 3.1.3.7), its issuer, audience,
  expiry and nonce checked, its address taken only when verified; GitHub's user and verified primary
  address from its API. `Auth.google`, `Auth.github` and `Auth.oidc` make providers, record updates
  change them; client ids and secrets come from the environment, and a provider without one isn't
  offered.
- **What is plain Roc is `Rules`**, with its `expect`s: where a sign-in may go after (a path of this
  site only), tokens, hashes, cookies' names, addresses, the state cookie, PKCE (RFC 7636's own
  example), an ID token's claims, GitHub's answers, when a session is renewed.
- **packages/auth/example** signs in every way; its tests run it on SQLite and on Postgres against a
  stand-in provider that checks the client's secret, the redirect URI and PKCE's verifier, and makes
  the ID token (22 tests, in `just test-server`). The docs site's `/ecosystem/auth` shows its files.

**Why.** The parts of signing in that are easy to get wrong (tokens kept in plain text, links that
work twice, redirects off-site, OAuth without state or PKCE, sessions that never end) are the same
in every app; the parts that differ (pages, the email's words, who gets in) are the app's. The app
layer first (no platform change): Random, Http, Env and the database are enough.

**Costs.** One read of `auth_sessions` per request that names the middleware. A provider's ID
token's signature isn't checked (the code flow doesn't need it; discovery and its keys are a
proposal). Passwords wait for Argon2 in the host, passkeys for P-256 (PROPOSALS.md).

**Reversible:** yes: a package; no app depended on it before.
