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

**Later (2026-11-26):** the options have defaults, as a plugin's do (D-033): `Job.Opts := { when :
When ?? Now }` and `Job.KeyedOpts := { key : Str, when : When ?? Now }`. `Job.enqueue!(kind,
input, {})` queues a job now, `enqueue_keyed!` says only its `key`, and a call that says
`{ when: Now }` compiles as it did. The keyed form keeps its own name, since a key changes what the
call answers (`Queued` or `Exists`).

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

**Later (2026-11-26):** with the runtime, a form to any of the app's endpoints is sent with `fetch`,
whether a component asks for its submission or not (D-095); `use_submission!` reads it.

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

**Later (2026-11-26):** no package is copied into an app by hand. The last two that were, found by
an audit of the packages' APIs, are imported by name now: packages/mcp's `McpHttp` (the package
names the server platform, `browser.roc` the protocol's modules) and packages/otel's `Otel`, a
plugin (`Otel.plugin({})`) whose sums aren't an actor's state any more (which `rocx build` finds
only in an app's own files) but its loop's, fed through `Kv`, so a measurement is no database write
either. `just check` runs test/no-copies.test.mjs: no package has a `server/` folder of modules to
copy, and no tracked file outside packages/ is a word-for-word copy of a package's module. A
package that can't be imported is a gap in the platform or `rocx build` to fix, not a copy.

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

**Later (2026-11-26):** finished jobs are swept by a loop of the plugin's own, `jobs.sweep`
(`JobSweeper`), when the server starts and every `sweep_ms` after (an hour), instead of done jobs
alone at start (failed and canceled ones were kept for ever, and a cron every ten seconds left some
60,000 rows a week between restarts). `Job.Options` gains `keep_done_ms ?? 604_800_000` (the week
the start kept), `keep_failed_ms ?? 2_592_000_000` (30 days: failed and canceled, kept longer,
since someone may want to read why or retry one) and `sweep_ms ?? 3_600_000` (a row outlives its
keep by at most that; 0 stops the server at start, as a sweep that never waits would hammer the
database). The sweep is on `finished_at`, for every kind (one the app no longer runs too), never a
queued or running job, a thousand rows a statement so that on SQLite other writes come in between,
on Postgres (its times compared through `to_timestamp`) and SQLite (milliseconds) alike; it logs
how many went. `sweep_ms` is an option of its own, as Oban's pruner has an interval, so an app (and
the server's tests, which age rows past keeps of an hour and two, swept twice a second) says how
often rather than the sweep working it out from the keeps. The keeps are kept at start with the
kinds (`Job.keeps!`), so the jobs page says them ("Done jobs are kept for 1 h, …") rather than "a
week".

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

**Later (2026-11-26):** `Email.Message` is a record with defaults (`Message := { to, subject, text,
html ?? "", cc ?? [], bcc ?? [], reply_to ?? "", headers ?? [] }`), so a message has several
recipients, Cc, Bcc, Reply-To and headers of the app's own, and `{ to, subject, text, html }` is
still one. `to` stays a `Str` that may name several addresses, separated by commas as RFC 5322's
address list has them (a comma inside a quoted name is the name's), rather than becoming a list:
every message written before keeps working, the dev mailbox's `to` and packages/testing's
`waitForMail({ to })` stay strings, and it reads as the header the recipient sees. A message built
before it is sent must be typed `Email.Message` (a plain record type, even with the same fields,
isn't one: the one change an app may need; the template's sign-in route had it). Every address is
read before anything is sent; the SMTP client sends a `RCPT TO` for each address in `to`, `cc` and
`bcc` (each once), and a refused one fails the message for everyone, before it goes. No header
names the Bcc. An app's header is refused if a CR or LF in its name or value would start a header
of its own (as one in an address's name or the subject can't: those are encoded words), or if it is one the package writes itself
(`From`, `To`, `Cc`, `Bcc`, `Reply-To`, `Subject`, `Date`, `Message-ID`, `MIME-Version`,
`Content-*`). The mailbox's JSON gained `cc`, `bcc`, `reply_to` and `headers`, as the app gave
them; its pages show them.

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

**Later (2026-11-26):** §9.1's rule (a post form is the browser's unless a component asks for its
endpoint's submission) is gone: the route table lists the app's endpoints that take a POST, and the
runtime sends every form to one with `fetch` (D-095).

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

**Later (2026-11-26):** a `Postgres` app started without a URL still has no database, but one whose
app or plugins have tables (migrations) doesn't start without it, outside `--dev` and `--debug`,
saying which have them; under them a line on the log says so (`rocx server: no database`). An audit
found that a deploy that forgot `DATABASE_URL` started silently, its tables never made, its jobs
plugin's workers stopped, and every query failing. As D-079 made email refuse rather than lose mail.

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

**Later (2026-11-26):** presence's status is closed, `Stack.Status` (`Online`, `Away`, `Busy`,
`Offline`), the same type in `Wire.Meta(d)` and an avatar's face, so `visible!`'s away is `Away`
and an avatar's class one of four. The page says its member's `data` too (`Wire.Said(d)`'s
`Update(d)`, `join!`'s `update!`; the server takes up to 1024 bytes of JSON and keeps the check's
name, picture and colour), and examples/board's open card moved there from the status
(`Board.Viewing`). `join!` also gives `others!`, and `Wire.meta(name, data)` makes the metadata.

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

**Later (2026-11-26):** a browser test can't skip in CI. A missing browser was `null` from
`findChrome`, `findGecko` and packages/testing's `launchBrowser`, so the tests that needed one
skipped and a job whose browser install broke stayed green. Now web/test/browser.mjs's finders
(every launcher goes through them) throw where browsers are required: with
`ROCX_BROWSERS=required`, and wherever `CI` is set (GitHub sets `CI=true`) unless
`ROCX_BROWSERS=optional` says they may skip there. Elsewhere they skip as before, and the run says
so once a browser, on the console. Every job that runs browser tests (`test-rocx`/`test-web`,
`test-server`, `examples`) installs both browsers already (`browsers: "true"`), and none of them
skipped one; `check` and `site` run none, so no job changed.

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
  in before, and where the sign-in goes after (`then`); it answers the app's id for the user, or
  why not. It runs in the transaction that links the identity and starts the session: what it
  writes commits with the session or with its refusal (the private app files an access request as
  it turns someone away until an admin approves), and a database error rolls it all back.
- **Sessions in the database** (`auth_sessions`, the token's SHA-256; links in `auth_links`;
  identities in `auth_identities`), in one migration for SQLite and Postgres: times are
  milliseconds given by the package, so its statements are the same on both. A session lasts 30
  days (`session_ms`) and is kept for as long again when used in its second half, so requests don't write. The
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

**Moved onto it** (the user, 2026-11-24: every app that signs people in, the private app too): the
options became `session_ms` and `link_ms` (milliseconds, as `timeout_ms` and `ttl_ms` are: plate's
sessions last 90 days, uptime's 12 hours, notes' test link 3 s), and `admit!` optional (without it,
only `Auth.sign_in!` starts sessions: an app's own password, a person picked). journal's reader and
quiz's visitor stay cookies of their own: an anonymous id, no one signing in.

**Reversible:** yes: a package; no app depended on it before.


## D-073 A static copy of an app: `rocx build --static`

**Status.** Built (2026-11-24). The user asked for js-framework-benchmark entries, like Joy's; an
entry is a folder of files the benchmark's server serves, so rocx needed to write an app as files,
and the user asked whether that was SSG ("maybe we should tackle SSG"). They chose the order (SSG
first, the benchmark on top of it), that it is part of the `rocx` CLI, and that the CLI platform
gets a small HTTP client for it (over the app's server writing files itself, or `curl`).

**Context.** The docs site was already a static copy, by site/build.mjs's `prerender` (Node): it
started the site's server, asked it for each page in its route list (`ROUTES`: no params, no
middleware of its own) and for a hand-made list of GETs (`STATIC_GETS`), wrote each page as
`<path>/index.html`, put its URLs under a base (`underBase`), and copied what the pages load. That
was the site's own; any other app wanting a static host would have copied it.

**Decision.**

- **`rocx build <dir> --static <out> [--base /path/] [--route <path>]… [--built <build>] [-- server
  options…]`** (rocx-cli/Static.roc). rocx builds the app as for production into
  `<dir>/build/static` (rocx build without stories, the browser's copy in `client/`; the server
  from Roc's dev backend, since it only renders the pages here; the browser's wasm `--opt=size
  --specialize=yes`, as the docs site's is), starts the server on a free port (`--debug`, for the
  plugins' files; its output in `static-server.log`, shown only when the copy fails), and asks it
  for `/`, each page whose path has no params, each `--route`, and every page those link to
  (`<a href>` on this site; no other site, no query or fragment, nothing under `/rocx/` or
  `/__rocx/`), as a browser asks (`accept: text/html,*/*;q=0.8`).
- **What is written.** An HTML answer at `<path>/index.html`, its `href`, `src` and `action` URLs
  under `--base` (the rule `underBase` had); a path whose last part has a dot (`/openapi.html`,
  `/feed.xml`) at its path; any other answer (an endpoint's JSON) at its path, as it is. Then
  `404.html` (what `/404` answers), the plugins' files (`/__rocx/plugin-files`), and the
  directories the server serves files from (the app's `static/`, then `rocx/`: start.js, the
  runtime, the wasm, the stylesheet). A page carries the answers to the GETs it read while it
  rendered (as before), so its data is there with no server.
- **What isn't, said.** A link to a path that answers an error is a note (a page or `--route` that
  does fails the build); a page whose route file names its own middleware is neither asked for nor
  followed (it answers each request as it comes: who is asking?); and the build lists what only a
  server answers (methods that write, events, channels, `respond!`) and each page with params that
  nothing reached, with the `--route` that would write one.
- **Safe to run again.** The copy is made in `<out>.building` and replaces `<out>` only when
  complete; a failure leaves the copy before. `<out>` must not hold the app or the current
  directory, and must be empty or an earlier copy (it has an `index.html`).
- **`--built <build>`** skips the build: `<build>/server` and `<build>/client/static` are used as
  they are. site/build.mjs's `prerender` is now this, with `--built site/build`, the site's
  `STATIC_GETS` as `--route`s, and `-- --context-file …`; `ROUTES` stays for the site's tests.
- **The CLI platform** (cli/) gets `Http.get!` (plain HTTP/1.1 over `std::net`, no crate: a server
  on this machine; a chunked body put together; unit tests in cli/host/src/http.rs, run by
  test/static.test.mjs), `Http.free_port!`, `File.write_bytes!`, and `Cmd.log` (a spawned command's
  output into a file).
- **The runtime** reads a path ending in `/index.html` as its directory (`unbased`): a static host
  may show a page by its file's name (the benchmark opens `<entry>/index.html`), and the page
  should hydrate as the page at its directory.
- **test/static.test.mjs**: test/static/app (links, a page with params reached and one named by
  `--route`, one nothing reaches, a GET and a POST endpoint, a page behind middleware, `static/`)
  copied under `/base/`, served as plain files and opened in Chromium at directories and at
  `index.html`s (strict hydration, a click, navigation in place); the refusals; a server that
  won't start.

**Why.** A static copy is a build output, and rocx already has what it needs: the route table, the
browser's copy, the builds and a server to start (`rocx dev`, `rocx check --sql`). The platforms are
untouched but for the runtime's one line; apps need nothing new.

**Costs.** One more effect module on the CLI platform. A page with params needs a link or a
`--route`; no hybrid (some pages files, the rest served) and no incremental rebuild. A static
copy's links are followed only from `<a href>`: a URL a component builds at run time isn't asked for.

**Reversible:** yes: the site's prerender can go back to Node; nothing else depends on it.


## D-074 Roc Solid in js-framework-benchmark

**Status.** Built (2026-11-25). The user asked for js-framework-benchmark entries like Joy's, then
to run them beside "all those" (vanillajs, Solid, Leptos, Joy, React), then why Roc Solid was so
much slower; they chose the fixes before the published run.

**Context.** js-framework-benchmark (krausest) is the common yardstick for web frameworks: one page,
a table and six buttons; its runner clicks in Chrome and measures until the page has painted, the
memory the page holds and what it downloads. An entry is a folder of files, which `rocx build
--static` (D-073) writes.

**Decision.**

- **Two entries** in `benchmarks/jsframework/`: `keyed` (`.map` with `key={row.id}`) and
  `non-keyed` (`.map_with_index` with `key={i}`; upstream retired its non-keyed entries on
  2026-10-24, and its runner still measures them), each an app of one page with the vanillajs
  entry's markup, the rows' data plain Roc with its expects (`Rows.roc`).
- **`run.mjs`** (`just js-bench`): our entries built into a clone outside the repository
  (`~/jsfb/js-framework-benchmark`), the benchmark's server on 8089 (never 8080), the runner
  headless, the suite in rounds (benchmark by benchmark, every entry in turn; the second round in
  reverse order), pooled into `site/js-framework-benchmark.json` (committed) with the machine, its
  load, each step's power source, Chrome's version and the commits measured.
- **The runner patched** (`runner-trace-start.patch`): a trace's events from before tracing
  started are dropped. Our pages' traces held the warmup's clicks, which failed every benchmark that
  creates rows ("at most one mousedown event is expected"); the other entries' 135 traces of a run
  give the same durations with and without it.
- **What the first run found, and what was fixed** (keyed, the runner's means): create 1,000 rows
  217 ms against vanillajs's 19; replace all 798 against 21; swap 111 against 15; CPU geomean 4.99×
  the fastest. Two causes: the browser host's notes of what runs allocate filled with hash-map
  tombstones, so every run cost more than the one before (create 1,000 rows: 64 ms, then 199 after
  five creates and clears), and a result was looked for among all of a run's allocations (fixed:
  `clean`, and a string's allocation found at once); and a `.map`'s rows put in order moved every
  row between two swapped ones (fixed: the longest run already in order stays). Both have counting
  tests, not timing ones. And the runtime is minified (D-075).

- **The run after the fixes** (beb7be7, 2026-11-25, on mains, two rounds of 15, nothing failed;
  `site/js-framework-benchmark.json`), keyed, the runner's means, before → after: create 1,000 rows
  217 → 45.8 ms (vanillajs 18.6, Solid 19.5); replace all 798 → 49.6; partial update 58.6 → 22.3;
  swap 111 → 22.8; remove 22.4 → 16.3; create 10,000 637 → 474; append 69.6 → 52.5; CPU geomean
  86.8 ms, 4.99× the fastest → 35.8 ms, 2.06× (Solid 1.16×, Leptos 1.24×, Joy 1.26×, React 1.63×);
  run memory 6.1 → 4.6 MB (React 4.3); download 102 → 73 KB compressed. First paint is the best of
  them, 29 ms (vanillajs 32.5, Solid 46.5, Joy 161, React 205): the page is HTML before its wasm loads.

**Why.** A yardstick others use: where Roc Solid stands, and what to fix, from the same clicks
every framework gets.

**Costs.** A clone, Chrome for Testing and Joy's toolchain outside the repository; a patched runner.
The numbers are this machine's until the entries are upstream (once the repository is public and
its compiler can be downloaded).

**Reversible:** yes: the entries and the script are files of their own.


## D-075 The runtime minified in what ships

**Status.** Built (2026-11-25), the user's go ("great idea").

**Context.** `web/runtime.js` is written to be read: about 270 KB, half of it comments. Every page
loads it beside its wasm, 65 KB with brotli, two thirds of a js-framework-benchmark entry's
download (102 KB against Solid's 4.5 and Joy's 47).

**Decision.** `rocx build --client` (and so `--static`, the docs site, every production build)
writes the browser copy's `runtime.js` minified by rocx itself (`rocx-cli/Minify.roc`): comments
and indentation gone, runs of spaces one; line breaks kept (so no semicolon JavaScript inserts
changes), and no name shortened (so a stack trace names the runtime's functions). A small
tokenizer keeps strings, template literals (and the code in their `${…}`) and regular expressions
as they are. `--dev` (`rocx dev`, `just dev`) keeps the runtime as written. About 162 KB raw and
35 KB with brotli; esbuild's full minification would make it 31. esbuild minifying the source and
minifying our output gives byte-identical results (checked when it was built). The docs' sizes
(the site's facts, the examples' page) now measure the runtime as it ships.

**Why.** Half the bytes for nothing a page needs, with no tool beyond rocx: the same output on
every machine, nothing generated to keep in step with the source.

**Costs.** A tokenizer to keep right as the runtime's syntax grows (its expects, and the pages that
run it in the site's and the static build's tests).

**Reversible:** yes: copy the runtime as it is.


## D-076 A transaction inside a transaction is a savepoint of it

**Status.** Built (2026-11-25), the user's ask.

**Context.** The host kept one transaction per call: a second `Db.transaction!` inside the first
answered `a transaction is open already: one at a time`. Real code nests. packages/auth runs an
app's `admit!` inside the transaction that starts the session (D-072), and a helper of the app's
that opened its own transaction failed there; the private app had to stop opening one
(packages/auth/PROPOSALS.md §4). A helper can't know whether its caller is in a transaction.

**Decision.**

- **The host picks the SQL; `Db.transaction!`'s API is unchanged.** The call's context keeps its
  levels (`levels`, in `hosted.rs`). `Host.db_begin!` inside an open transaction runs
  `savepoint rocx_<n>`; `Host.db_commit!` in a level runs `release savepoint rocx_<n>`;
  `Host.db_rollback!` in a level runs `rollback to savepoint rocx_<n>` then `release`
  (`db::savepoint`, `db::release`, `db::rollback_to`, the same SQL on every backend). Outside a
  level they begin, commit and roll back as before. No new hosted function, no glue.
- **An inner `Ok` keeps its writes in the level around it; an inner `Err` (or a failing statement)
  undoes only its own**, and comes back to the body around it, which may handle it and go on. An
  outer `Err` undoes everything, inner levels' writes too. A crash, a call that ends or one cut off
  at its time limit rolls the whole transaction back, as before; the levels go with the connection.
- **What a level notified goes with it.** On SQLite and Turso the host keeps a call's notices until
  its transaction commits: each level remembers how many there were when it began, and one rolled
  back drops its own. Postgres drops a rolled-back savepoint's `NOTIFY` itself (checked by a test).
  So a job queued in a rolled-back level (a row and a notify) is never queued and wakes nobody.
- **A level that can't be released is undone.** On Postgres a failing statement aborts the
  transaction until its level rolls back: a level whose body drops such an error and returns `Ok`
  fails to release (`25P02`), so the host rolls back to its savepoint, and the inner
  `Db.transaction!` returns that error. SQLite and Turso fail the statement alone, and the level
  commits.
- **On Turso's MVCC only the outermost transaction runs again.** A conflict rolls Turso's whole
  transaction back there and then. `Host.db_conflicted!` answers false while the call's
  transaction is open, so a level never runs its body again by itself: its error reaches the body
  around it, and once the outermost `Db.transaction!` has rolled back, it runs again (D-049).
- **A transaction that lost is broken until it ends.** After a conflict (or a level that couldn't
  be undone), every statement, notify, level and commit of the call's transaction fails at once
  with why, and runs nothing: on Turso the connection is back in autocommit, so a body that took
  the inner's error in its stride would otherwise write outside any transaction (with this taken
  out, the Turso test's write after a lost level landed, and the outer ran again). This holds
  without nesting too.
- **All three engines, both Turso modes.** Postgres, SQLite (rusqlite) and Turso 0.8.4 have
  savepoints, in MVCC (`begin concurrent`, MVCC's named savepoints) and in WAL mode (`?mvcc=off`).
  `server/test/nested-checks.mjs` runs the same tests on each (`server.test.mjs` on Postgres,
  `sqlite.test.mjs` on SQLite, Turso and Turso in WAL mode): both levels kept, the inner undone and
  the outer committed, the outer undoing both, three levels deep, notifications and jobs in a
  rolled-back level, a crash in one, and on Turso's MVCC two writers on one row (the inner level
  loses, runs once per outer run, and the outer runs again). The docs' sample (`Samples.roc`:
  `place_order!` calling `award!`) runs on Postgres.

**Why.** Code composes: a helper that keeps its writes together should work whether or not its
caller already has a transaction. Django's `atomic` nests this way (Rails does with
`requires_new: true`; Ecto folds an inner transaction into the outer, so an inner rollback loses
both). Doing it in the host keeps `Db.transaction!` one function, with one meaning for its body's
result.

**Costs.** Two round trips more for each level (its savepoint, then its release or its rollback).
What isn't the database's (a fetch, a message) in a level still happens even when the level rolls
back, as in any transaction. On Turso's MVCC a conflict anywhere costs the whole transaction's work
again.

**Reversible:** yes: the host's levels are a few branches in `hosted.rs`; without them a nested
`Db.transaction!` would be refused again.

## D-077 packages/auth, round two: impersonation, and what moving the apps found

**Status.** Built (2026-11-25). The user, on the friction the moves found (packages/auth's
PROPOSALS.md §4): "I want all of them", and "it would be nice if the auth package tackled
impersonation".

**Context.** Moving notes, uptime, plate, tasks, board and the private app onto packages/auth
(D-072) worked, each with a workaround: a second middleware to load the app's user, a copy of what
`required` answers a signed-out request, `auth.Rules` imported for where a sign-in may go after,
two `Set-Cookie`s to switch person, the sentences for `?error=` written again in each app (the
package names the server platform, so a page in the browser couldn't use it), two modules named
`Auth`, and helpers that couldn't open a transaction inside `admit!` (D-076).

**Decision.**

- **Middleware**: `required_with(load!)`, where `load!` turns the session into what routes are handed
  and may answer `SignedOut` (the user is gone: the session ends) or `Answer(response)` (the database
  couldn't be read: the session stays); `signed_out!(request)`, what `required` answers; the
  `refusal` option, the words of its 401; `renew!` for an app's own middleware.
- **An app's own way in**: `path!(then)` (a path of this site, else `home`) and `switch!(request,
  answer, user)` (the request's session ended as the new one starts, one `Set-Cookie`).
- **`SignInError`**, a module on no platform (`browser.roc` lists it): `message(query)` for
  `?error=` and its `reason`, `field(query, name)`. An expired link's redirect keeps its `then`.
- **Impersonation**: `impersonate!(request, user, ms)` makes the request's session act as `user`
  until `ms` from now (`acting_as`, `acting_until` on its row: migration `auth/0002_impersonation`);
  `Session` gains `real_user`, the one who signed in; `stop_impersonating!`, the time running out or
  signing out end it; `sessions!` shows `acting_as`; each start and stop is on the log with both
  users. Who may is the app's to decide (the example: `ADMIN_EMAILS`, by `real_user`).
- **packages/mcp's `Auth` is `Bearer`** (`Bearer.token(headers)` for `Auth.bearer`), so an app with
  both packages needs no alias.
- The apps use them: board's and notes' middleware are `required_with`, tasks and board switch with
  `switch!`, uptime and plate go on with `path!`, notes' and the example's sign-in pages read
  `SignInError`.

**Why.** Each workaround was the same code in several apps; impersonation is what an admin of a real
app needs to help someone, and done outside the package it would need the session's internals.

**Costs.** `Session` has a field more (`real_user`), and `sessions!` one more (`acting_as`); a route
that checks permissions must use `user`, and one that records who did what `real_user`.

**Reversible:** yes: additions to a package, but for packages/mcp's rename.

## D-078 A one-command install, and `rocx new`

**Status.** Built (2026-11-25); the first release waits on the user (a LICENSE, the x86_64
compiler's publishing, the tag). The user asked for both (2026-11-24, with sign-in: "the three
things"), and took the design's defaults: date versions, `rocx test` and `rocx build --release`
now, the Linux targets in the macOS archive, the template's mail limit trusting one proxy.

**Context.** An app built only from a clone of this repository: `just setup` (Rust, Zig, the fork
compiler from source or a download), headers reaching the platform by `../` paths, `node
server/build.mjs` to deploy. A newcomer needed the repository's toolchain to write a page.

**Decision.** (The design is `spike/install/DESIGN.md`.)

- **An app reaches its version of rocx through a link.** `.rocx-version` (committed) names the
  version; `.rocx` (gitignored) links to `~/.rocx/versions/<v>`; headers say `./.rocx/…`. Every
  command on an app (`dev`, `build`, `check`, `test`, `routes`, `lint`) makes or mends the link, and
  when the app names another version, that version runs the command (installed first). From a
  clone, the link points at the clone. Roc's URL bundles were weighed and left: rocx reads packages'
  components and `browser.roc` from disk, which bundles leave out, and a platform with every
  target's host outgrows a bundle.
- **rocx finds its "app root"**: an app's `.rocx` when it has one, else rocx's own home; the
  compiler at `<root>/bin/roc`, then a clone's `.tools/roc-active`, then `$ROC`; no cargo without
  `server/host/` (prebuilt hosts in `targets/`).
- **New commands**: `rocx new <dir> [--db …]` (the template `templates/app/`: packages/auth's
  sign-in with its link page and the dev sign-in, its own users' table, `same_origin` and guard's
  headers, a rate limit on the sign-in mail, a layout, an account page, a component with a story
  and expects, a README; SQLite unless asked), `rocx test`, `rocx build <dir> --release <out>
  [--target …]` (the server `--opt=speed`, the wasm `--opt=size --specialize=yes`; `out/server
  --static out/static`), `rocx upgrade [v]`, `rocx --version`. The CLI platform gained
  `Stdin.line!`, `Stdin.is_terminal!`, `Stdout.is_terminal!`, `File.symlink!`.
- **A release** is the repository's own layout per target (`rocx-macos_arm64.tar.xz`,
  `rocx-linux_arm64.tar.xz`, `rocx-linux_x86_64.tar.xz`: about 84, 72 and 77 MB): `VERSION`,
  `LICENSE`, `NOTICES`, `bin/rocx`, `bin/roc` (the pinned fork), `web/`, `server/platform/` with its
  hosts built without debug info (Apple's `strip -S` breaks ThinLTO's symbols; `llvm-strip
  --strip-debug` is used), `packages/`, `templates/app/`; never `server/host/`, `rocx-cli/`.
  `install.sh` (POSIX sh) checks each SHA-256, installs read-only into `~/.rocx/versions/<v>`,
  points `current`, adds `~/.rocx/bin` to the shell's PATH. `just release-hosts`,
  `release-compilers`, `release-pack`, `release-test`; `flake.nix` with `nix/release.json`;
  `.github/workflows/release.yml` on a `v*` tag (hosts on Linux and macOS, packs, smoke on macOS
  and bare Alpine arm64 and x86_64, publish). The release's smoke test installs from its own
  archives and takes a newcomer's first app from `rocx new` to signed in.

**Why.** The user's goal: the fastest way to a production-ready full-stack app. One download, one
command for an app that signs people in and is safe by default, and one to deploy it.

**Costs.** About 80 MB to download and 500 MB on disk (mostly the compiler). The `.rocx` link must
be made on each machine (rocx does it). A release needs both a Mac (its host) and Linux runners.

**Reversible:** yes: a clone still works as before; the install is files under `~/.rocx`.

## D-079 Safe by default: a page's middleware, email with no SMTP server, names in hand-built markup

**Status.** Built (2026-11-25), before the first public release. The user decided each direction:
a page takes its route's middleware (found writing `rocx new`'s template), and the docs pass's two
questions (TODO.md, 2026-11-24): email fails without `SMTP_URL` outside `--dev`, and names that
aren't plain are never written.

**Context.** Three defaults were the unsafe way round, each found by writing a real page.

- The template's `routes/account/+server.roc` named `middleware = Middlewares.signed_in`, and its
  `+page.rocx` had to say it again: a page that forgot rendered for anyone, its own read got the
  401, and a signed-out visitor saw the error page instead of going to sign in.
- `Email.send!` with no `SMTP_URL` answered `Ok` and kept the message for the dev mailbox, on a
  deployed server too: every sign-in link was lost, and nothing said so but a line at info.
- `Html.element`, `Html.void` and `Html.attr` take any `Str` as a name, and the server's renderer
  wrote it as it was, so Roc that builds markup by hand from data could write
  `<img src=x onerror=…>`, an `onclick`, or a `<script>` (`.rocx` files name only what the file
  says, and the build refuses an inline handler there).

**Decision.**

- **A page that names no middleware runs behind the one its directory's `+server.roc` names**
  (`Routes.page_guard`): one line guards the page and the data it reads, so the page can't render
  for someone its data refuses. A page that names its own keeps it. Only the page's own directory
  counts: a parent's `+server.roc` guards nothing below it (it has no notion of the paths under it,
  and none was wanted). `rocx build` refuses `middleware` in a layout or the error page, which
  nothing runs (`middleware_problems`), rather than ignore it. `rocx routes`, the static build's
  list of pages it leaves out, and the docs' route tree say which a page runs behind. The template,
  the examples, the docs site and test/e2e's app dropped their pages' duplicated lines.
- **With no SMTP server, email is kept only where the dev mailbox can be read: `--dev`, and
  `--debug`**, which tests start a server with (packages/testing's `startServer` passes it; it
  serves the mailbox's JSON already; a deployed server never runs with its debug paths). Anywhere
  else the email plugin's start fails, so the server doesn't start: `rocx server: can't start` with
  `email: SMTP_URL isn't set, so email can't be sent: set it where the server runs …`. A plugin's
  `needs: [Env("SMTP_URL")]` would refuse `--dev` too, and a `check` only warns once the server
  runs; a start's `Err` is how the platform refuses to start. Without the plugin, `send!` answers
  `EmailErr` saying the same. A package tells `--debug` by `Env.debug!` (new: Roc over the host's
  existing `setting`, beside `Env.dev!`; no host change).
- **A name markup can't have is never written**, by every renderer that writes or builds markup:
  - a tag is an ASCII letter, then letters, digits and `-`;
  - an attribute's name (`attr`, `optional`, `flag` and the computed ones) an ASCII letter, then
    letters, digits, `-`, `_`, `.` and `:`, and never `on…` (an inline handler; rocx's handlers are
    `on:click`, Roc, never text);
  - a `<script>` is written only as a `.rocx` file has it: its children all its text as written
    (`Html.source_text`, which `rocx lint` refuses in hand-written Roc). One of text, of a hole, or
    of nothing but a `src` is left out. The transpiler gives a `<script … />` an empty
    `source_text`, so a file's self-closed script stays the file's.

  What isn't plain is left out (the element with what is inside it, or the attribute); a page
  never fails for a name. The server's walker (`signals.rs`: `plain_tag`, `plain_attribute`,
  `written_element`) logs one warning a render, `rocx server: markup named what a page can't have,
  which wasn't written`, with the page's `path` and the `names`. The runtime (`writable`, for
  building, hydrating and `renderToString`) warns on the console once a name, and lets go of a
  refused computed attribute's box. `Html.to_str` leaves them out quietly (it is pure). The checks
  are byte loops, as they run for every element. The phone's engine (native/core) is unchanged: it
  turns markup into native views, hides `<script>` and runs no attribute (TODO.md).

**Why.** A newcomer's app should be safe without knowing where the traps are: a forgotten line
shouldn't open a page, a missing variable shouldn't lose mail in silence, and data shouldn't name
markup. Each check is where the mistake would surface anyway (the route table, the plugin's start,
the renderers), and each says what is wrong. Not in `Html.serialize!`: the web host has no log to
say what was dropped, and the browser's renderer would still have to keep `createElement` from
throwing on a name with a space.

**Costs.** A page that should be public beside a `+server.roc` with a guard must name its own
middleware, and a `+server.roc`'s middleware that guards only some methods must look at the method
(as notes' `posts_only` does). An app deployed without `SMTP_URL` that counted on `Ok` no longer
starts. `--debug` keeps mail too, so it must stay off deployed servers (as it should: it serves
debug paths). A byte loop per element and per named attribute in each renderer. Names a browser
would take but the rule doesn't (`@click`, non-ASCII) are left out. In the browser, the holes inside
an element left out are never run, and their boxes are kept until the page goes.

**Reversible:** yes: each is a few functions (`page_guard`, the plugin's start, the renderers'
checks); taking one out brings the old behaviour back.

## D-080 P-256 and AES-128-GCM in the server's host, so Web Push sends

**Status.** Built (2026-11-25): packages/push's proposal 1 (PROPOSALS.md there), leaner.

**Context.** packages/push did everything Web Push needs but the crypto: its `Push.host` answered
"missing" for the ECDH that encrypts a message (RFC 8291), the AES-128-GCM with a derived nonce
that seals it (RFC 8188), and the ES256 signature on the VAPID token (RFC 8292), so every delivery
job failed, saying so. Elliptic curves in Roc were ruled out (slow, not constant-time, unreviewed).
`ring`, which the host links already, has all three.

**Decision.**

- **`P256`, a new server platform module, two effects.** `P256.ecdh!(peer)`: ECDH with a key pair
  the host makes for this call and forgets (ring's `EphemeralPrivateKey`, `agree_ephemeral`),
  answering `{ public_key, secret }` (65 and 32 bytes), `BadKey` unless `peer` is an uncompressed
  point on the curve. `P256.sign!(private_key, public_key, message)`: ES256 (ring's
  `ECDSA_P256_SHA256_FIXED_SIGNING`), 64 bytes `r` then `s` as JWS writes them, `BadKey` unless the
  32-byte scalar and the 65-byte point are a pair (ring checks). Keys are raw bytes, as browsers,
  Web Crypto and `web-push` write them.
- **`AesGcm.seal_with_nonce!(key, nonce, plaintext)`**, beside `seal!`: AES-GCM with the caller's
  12-byte nonce, AES-128 under a 16-byte key, AES-256 under a 32-byte one; the ciphertext then the
  tag (`BadKey`, `BadNonce`). Its doc says a nonce must never repeat under a key, and to use
  `seal!` otherwise.
- **Three hosted functions** (`p256_ecdh!`, `p256_sign!`, `aes_gcm_seal_with_nonce!`), each
  `Try(List(U8), Str)`, so the glue only adds their declarations (ECDH's two parts come back as one
  list, split by `P256.ecdh!`). Each starts `let _host = preempt::host();`.
- **packages/push calls them itself.** `Push.Primitives` and `Push.host` are gone (they were the
  seam for the missing host); `Push.send!(keys, subscription, data, options)`. The plugin's start
  signs once with the VAPID keys, so a pair that isn't one stops the server (the docs said so
  already; only the keys' shapes were checked). `Push.subscribe!` tries an ECDH with the
  subscription's key and refuses one off the curve, so a kept subscription can be sent to.
- **Not built, for want of a user:** ECDH with a given private key (RFC 8291's appendix replayed; it
  is checked by agreeing with Node instead), `P256.generate!` (VAPID keys still come from
  `vapid-keys.mjs` or `web-push`; TODO has the release gap; built since, D-097),
  `open_with_nonce!`, and verifying. The
  natural next primitive is `P256.verify!(public_key, message, signature)` for passkeys
  (packages/auth's PROPOSALS.md §2), on ring's `ECDSA_P256_SHA256_ASN1`: WebAuthn's signatures are
  DER, not JWS's `r` and `s`.
- **Tests.** server/test: `seal_with_nonce!` gives RFC 8291 appendix A's and RFC 8188 §3.1's
  ciphertexts byte for byte, and AES-256 that Node opens; `ecdh!` agrees with Node's ECDH, a new pair
  each call, and refuses points off the curve, compressed or cut short; Node verifies `sign!`'s
  signatures (RFC 8291's application server pair, and Node's), and keys that aren't a pair are
  refused; the docs' ES256 JWT sample (`Samples.es256_token!`) verifies in Node. packages/push's
  example, on SQLite and Postgres, under `--dev`: a broadcast delivered to a push service of the
  test's own that plays the browsers (Node's P-256 keys and auth secrets), checks each VAPID token's
  claims and ES256 signature against `VAPID_PUBLIC_KEY`, decrypts each message per RFC 8291 and
  checks the notification inside, and answers 201, 410 (deleted) or 403 (noted); a pair that isn't
  one stops the server. That push service is also the server's `HTTPS_PROXY`, refusing every
  CONNECT, so no test reaches a real push service.

**Why.** Sending was the package's one missing piece, and only the host can do it safely; ring adds
nothing to the build. Three effects are what sending needs, and nothing more.

**Costs.** One platform module and one `AesGcm` effect to keep. A nonce the caller gives can be
misused; the doc warns, and `seal!` stays the default. A real push service hasn't received a
message from these tests (by rule): the RFCs' vectors and a stand-in that decrypts are the checks
until a browser's first notification.

**Reversible:** yes: new functions nothing else calls; without them packages/push goes back to
failing every delivery with a reason.

## D-081 Two-factor sign-in: an authenticator app's codes, and recovery codes

**Status.** Built (2026-11-25). The user asked for two-factor sign-in in packages/auth (TOTP
authenticator apps, plus recovery codes), and for `rocx new`'s app to have it.

**Context.** packages/auth (D-072, D-077) signs people in with one factor: a mailed link or a
provider. Whoever holds someone's mailbox, or their provider account, is them. A second factor that
every phone already has is an authenticator app's six-digit code; passkeys wait on the host
verifying a P-256 signature (D-080 signs; PROPOSALS.md §2).

**Decision.**

- **TOTP as authenticator apps read it** (RFC 6238): HMAC-SHA1, 30-second steps, six digits, a
  20-byte random secret given as an `otpauth://totp/<issuer>:<account>?secret=<Base32>&issuer=…`
  URI (a QR code) and as its Base32 in groups of four. A code is accepted for the step now and one
  either side, and only for a step later than the last one the user used (kept as `last_step`, taken
  in one statement), so a code is good once. `auth.Totp` is the arithmetic, plain Roc, with RFC
  6238's SHA-1 vectors and RFC 4226's as `expect`s.
- **packages/crypto** gains `Sha1` (pure Roc; there is no builtin), `Hmac.sha1` and `verify_sha1`
  beside the unchanged SHA-256 API, and `Base32` (RFC 4648; decoding takes either case, padded or
  not, strict otherwise), with FIPS 180-4's, RFC 2202's and RFC 4648's vectors.
- **The secret at rest** is sealed with the platform's `AesGcm`, the user's id sealed beside it (a
  row moved to another user doesn't open), under a key derived with HKDF-SHA256 from the app's
  secret: `APP_SECRET` (the plugin's `key_env`), at least 32 characters. The package had no key of
  its own; `APP_SECRET` is the platform's documented app secret (D-004, D-006), and HKDF keeps this
  key for this purpose alone. It is checked by the plugin's start, not its `needs`: `needs` would
  stop `rocx dev` on every new app until one is set, so under `--dev` a development secret stands
  in (said on the log), and without `--dev` the server doesn't start, saying why.
- **Opt-in**, `Auth.plugin({ two_factor: Bool.True, code_page, issuer })`. Off (the default),
  nobody is asked and no key is needed.
- **Enrolment**: `two_factor_start!(user, account)` (a new secret, waiting for its first code; its
  `secret` and `uri`), `two_factor_pending!` (the same again while it waits, so a page that reloads
  or shows a wrong code keeps its QR code), `two_factor_confirm!(user, code)` (on, and ten recovery
  codes), `two_factor_disable!(user, code)` and `two_factor_regenerate!(user, code)` (each a code
  now or a recovery code), `two_factor!(user)` (`Off`, `Pending`, `On({ since_ms,
  recovery_codes })`). Recovery codes are 80 random bits (`k7qx-m2pa-r4tz-b6wd`), kept as their
  SHA-256, used up in one statement.
- **Signing in** with it on, every way (a link, a provider, the dev sign-in, and the app's own
  `sign_in!` and `switch!`) keeps a sign-in waiting for the code (`auth_waiting`: the token's hash,
  the user, where it goes, wrong codes so far, ten minutes) in the session cookie, and goes to the
  app's `code_page`. The middleware treats it as signed out, but `signed_out!` sends a page to the
  code page. `POST /auth/code` takes a code or a recovery code: right, a session under a new token
  (the waiting one signs no one in), on to `then`; wrong, back to the code page (`?error=code`);
  the fifth wrong code ends the sign-in (`?error=attempts`); none waiting, `?error=timeout`.
  `waiting!(request)` is the waiting sign-in, for the code page. `SignInError` has the sentences.
- **Who must have it** is the app's: `two_factor!` answers, a route refuses (the example's
  `/admin` asks its admins). Impersonation isn't asked for the target's code: no one signs in.
- **Tables**: migration `auth/0003_two_factor`, the same on SQLite and Postgres (and Turso).
- **`rocx new`'s app** has it on: its account page sets it up (`<QrCode>` and the key), turns it
  on (the recovery codes shown once) and off, and `/sign-in/code` asks for the code; plain forms,
  so all of it works before the page's script has loaded. Its README says to set `APP_SECRET`.
- **Tests**: the `expect`s above; the auth example's suite (enrolment, a waiting sign-in, the code
  page, a wrong code, a code used twice, a recovery code used once, too many tries, too long,
  turning it off, new recovery codes, a provider's sign-in, impersonation, `/admin`, the start
  without `APP_SECRET`), on SQLite and Postgres, with codes Node's crypto makes; the template's
  suite on SQLite, Turso and Postgres, in Chromium too.

**Why.** An authenticator app is the second factor people have, and the parts that are easy to get
wrong (a secret in clear, a code that works twice, unlimited guesses, a waiting sign-in that already
counts as signed in, a session token that survives the step up) belong in the package; the pages,
and who must have it, stay the app's.

**Costs.** The app needs `APP_SECRET` in production once two-factor is on, and keeps it: changed,
every authenticator stops working and only recovery codes sign in. One more read at each sign-in
(whether the user has it on), and at a signed-out page's GET with a cookie (whether it waits for a
code). Wrong codes are counted per sign-in, not per user across sign-ins (PROPOSALS.md §5).

**Later (2026-11-26):** they are counted per user too (`auth/0004_two_factor_misses`): an audit
found `two_factor_disable!` and `two_factor_regenerate!` counted none, so a stolen session could
guess its way to turning two-factor off. Ten wrong codes in a row, at sign-ins and those two, and
the user's codes are refused for a quarter of an hour after the last (`TooManyTries`;
`?error=locked` at a sign-in); each code is counted before it is looked at, by a compare-and-set on
the count, so codes sent at once can't get past it.

**Reversible:** yes: an option, off by default; a migration that adds tables.

## D-082 Payments and subscriptions through Stripe: packages/stripe

**Status.** Built (2026-11-25), the user's ask: Stripe's hosted Checkout for one-time payments and
subscriptions, its hosted Customer Portal, webhooks kept in step in the app's database, and a typed
way to ask what someone has paid for; no card forms of our own, no Elements, no Connect, no
invoicing beyond what Checkout and the portal give; named `stripe`, not a payments abstraction.

**Context.** A small SaaS wants to charge from its first day, and every Stripe integration writes
the same parts, each easy to get wrong: a webhook that checks the signature of the very bytes it was
sent and their age, an event handled once though Stripe sends it until it is answered, events that
come in any order, one customer per user, idempotency keys, and the page Checkout goes back to,
which comes before the events do. Stripe's objects also differ by API version (since
2025-03-31.basil a subscription's period end is its items', an invoice's subscription its
`parent`'s), and the webhook's events come in the endpoint's version, not the one the requests ask
for.

**Decision.**

- **A plugin, `Stripe.plugin({ webhook_at ?? "/stripe/webhook", on_event! })`**: one route (`POST
  /stripe/webhook`), one migration (`stripe/0001_stripe`: `stripe_customers`, `stripe_checkouts`,
  `stripe_subscriptions`, `stripe_events`, the same SQL on SQLite and Postgres, times in
  milliseconds given by the package), a check of the keys once started (`stripe.keys`: test or live
  mode, live keys under `--dev` a warning), and its needs: a database, `STRIPE_SECRET_KEY`,
  `STRIPE_WEBHOOK_SECRET`. `STRIPE_API_URL` points it at a stand-in.
- **Checkout**: `checkout!({ user, email, mode, prices, success_url, cancel_url, trial_days,
  promotion_codes, metadata })` finds the user's customer or makes one (the app's id as metadata
  `app_user_id`; its idempotency key the SHA-256 of the user and the address, so two checkouts at
  once make one), makes the session (the user as `client_reference_id` and in the metadata of the
  session and of its subscription or payment), keeps it with its prices, and gives its URL. A path
  is put after the public URL; the success URL gets `session_id={CHECKOUT_SESSION_ID}`. A customer
  Stripe no longer has is forgotten and made again.
- **The portal**: `portal!(user, return_url)`, `NoCustomer` for someone who never checked out.
- **The page Checkout goes back to**: `checkout_session!(user, id)` asks Stripe for the session with
  its subscription expanded, refuses another user's (`NotYours`), and keeps both, so the page and
  `subscribed!` are right before the events come. What it keeps counts as older than any event (its
  row's version is left as it was, 0 when new). The app's `on_event!` runs for events alone.
- **The webhook**: `Stripe-Signature`'s `t` and every `v1`, HMAC-SHA256 under the secret of `<t>.`
  and the request's body as it came (`Server.Request.body`: bytes), compared in constant time, at
  most 300 s old; anything else a 400. Then one transaction: the event's id inserted into
  `stripe_events` (none inserted: it came before, answered 200), the package's rows kept, and the
  app's `on_event!(Stripe.Event)` called; its `Err` or a database error rolls it all back and
  answers 500, so Stripe sends it again. `Stripe.Event` carries the type, the app's user it is about
  (the session's reference, or the user of the customer it names), `About` read (`Session`,
  `Subscription`, `Invoice`, `Other`) and the raw `data.object`.
- **Order**: a subscription's row keeps `version`, the event's time in seconds × 4 plus its kind
  (created 0, any other 1, deleted 2); an event writes only at a version as high or higher, and a
  `canceled` or `incomplete_expired` subscription stays so. Two changes in one second stand level:
  the package asks Stripe for the subscription once and keeps that. A checkout's status only leaves
  `open`, and its payment stays `paid`.
- **Who has paid**, from the tables only: `subscribed!`, `paid_for!(user, price or product)`,
  `subscription!`, `subscriptions!`, `payments!`, `customer!`. `Stripe.Status` is a tag union;
  `paying` is active, trialing or past due (the user may want otherwise: PROPOSALS.md asks). Both
  Bool checks are a no, and an error on the log, when the database can't be read.
- **Stripe's API**: form-encoded, `Authorization: Bearer`, `Stripe-Version: 2025-03-31.basil`, an
  `Idempotency-Key` on every POST, three tries for a network error, a 409, a 429 or a 5xx unless
  `Stripe-Should-Retry` says no; `post!` and `get!` for anything else.
- **Reading Stripe's JSON**: a small scanner in `StripeRules` reads a field by its path from the raw
  JSON (`text`, `int`, `id_at` for an id or an expanded object's id, `elements`), since `Json.parse`
  into a record fails on a field that is missing, and Stripe's objects lack or move fields by
  version and by `expand`. Both versions' places are read.
- **packages/stripe/example** sells a subscription and an e-book (packages/auth's dev sign-in for
  its users), its gates middleware on `Auth.required_with`; its tests (7 each on SQLite and
  Postgres, in `just test-server`) run against a Node stand-in for Stripe's API
  (`example/test/stand-in.mjs`), with events signed as Stripe signs them. The docs site's
  `/ecosystem/stripe` shows the example's files.

**Why.** The app layer first: `Http`, `Env`, `Db` transactions (nested ones are savepoints, D-076)
and crypto's `Hmac` are enough, and the request's body already reaches a route as bytes. Keeping
Stripe's state in the app's tables makes the checks cheap and keeps the browser out of who has paid.

**Costs.** A read of `stripe_subscriptions` per gated request. A tie between two changes in one
second costs the webhook a request to Stripe. Times compare Stripe's clock with the server's for a
signature's age. On Turso a transaction that loses to another's write runs again, `on_event!` with
it. Not tried against Stripe itself (the rule: no external calls): the stand-in follows Stripe's
reference, and TODO.md asks for one run in test mode.

**Reversible:** yes: a new package; no app depends on it.


## D-083 `create_selector!`

**Status.** Built (2026-11-25), the user's go, the first of the steps that close js-framework-benchmark's
gap (D-074).

**Context.** A list where one row is picked (the selected one, the open one) compares each row's id
with the picked one: `class:danger={selected!() == row.id}`. Every row's hole reads `selected!`,
so every pick runs every row's hole: a thousand runs to change two classes. Solid has
`createSelector` for this, and its benchmark entry uses it; ours couldn't.

**Decision.** `create_selector! : (() => a) => (a => Bool)` in `pf.Solid`:
`is_picked! = create_selector!(picked!)`, then `class:picked={is_picked!(row.id)}`. The selector is a
computation that answers its source's key (as `Str.inspect` writes it), run now and again when what
it reads changes. `is_picked!(key)` answers whether `key` is it, and is tracked by that key alone
(`Host.selector_new!`, `Host.selector_is!`): when the key changes, the readers of the key it was and
of the key it is run again, and no other. The browser's runtime keeps a source per key read, swept
of keys no reader reads once there are twice as many as the last sweep left, so a pick costs the same
however many rows there are. The server computes it once (nothing changes after); the native engine
has the same (`CompKind::Selector`, `Source::Selector(id, key)`). The benchmark's entries use it, as
Solid's does.

**Why.** It is Solid's answer to the same problem, and the pattern is common (a selected row, an open
item, the current tab): a pick costs two rows' holes, not the list's.

**Costs.** Keys are compared as text (`Str.inspect`), so a key is written once per read; a key type
whose inspection isn't unique (none of Roc's data types) would compare wrongly.

**Reversible:** yes: a reader can compare with the signal again.


## D-084 A `.map`'s row is a template

**Status.** Built (2026-11-25), the user's go: the third of the steps that close js-framework-benchmark's
gap (D-074; D-083 was the first).

**Context.** Making a row cost Roc its whole markup as JSON (every element, attribute and text, a
string built and joined at each level: about 110 allocations a row of the benchmark's table), and
the browser parsing it and making it an element at a time. Solid compiles a row's static markup into
a template it clones; the rest are its holes.

**Decision.** rocx writes a `.map`'s row as `Html.template(site, markup)`, `site` naming the module
and how many `.map`s come before it there (formatting doesn't change it). It marks what was written
in the file: a literal attribute is `Html.attr_literal` (`Literal`), a hole that reads nothing that
changes is `Html.shown` (`Shown`: a value, even when it is text, never part of a skeleton). In the
browser, once the page is up, the first row at a site sends its skeleton (its elements, literal
attributes and literal text, a slot for each other attribute and child) and its parts; every row
after sends only its parts, in the slots' order (`Host.template!` says which: 0 for none, else an id
and whether the skeleton is in). The runtime keeps the skeleton as nodes, clones it, finds each slot
by its path, and puts each part in with `element`'s and `build`'s code (`fill`, `instantiate`), so
a row is the nodes `element` would make (the web tests compare them). The server, the native engine
and hydration get the markup itself (`Host.template!` answers 0); so does a row whose root isn't an
element, or that holds `<script>`, `<style>`, `<title>`, `<textarea>` or a name D-079 refuses.

**Why.** Creating 1,000 of the benchmark's rows: 39 allocations a row instead of 110, about 24 ms
instead of 30 (click to layout, after D-083's selector and the host's cheaper notes). It needs no
analysis in the transpiler beyond what it knows as it writes: which attributes and text are literal.

**Costs.** Three constructors rocx writes (`template`, `attr_literal`, `shown`) and two variants
every match on `Html` handles; a skeleton per site kept for the page's life; rows only (a
component's markup, made once, isn't a template).

**Reversible:** yes: rocx stops writing `Html.template`; the markup is as before.

## D-085 Claude from the server: packages/ai, and packages/tools

**Status.** Built (2026-11-26), the user's ask (a way for apps to use AI, then agents usable as
tools, as in Strands Agents), as a package in pure Roc on the server platform's `Http.fetch_chunks!`, with no
platform change. Tried against the API itself with
`claude-haiku-5-5` (the user's choice for development); its tests run against a stand-in.

**Context.** An app that calls a model writes the same parts each time, each easy to get wrong:
reading the API's stream of events back into a message, keeping the model's thinking blocks and
their signatures exactly (the API checks them when a conversation goes on, and refuses some that
were changed), trying a 429 or a 5xx again but never once text has reached a page, handling a
refusal rather than reading empty content, stopping the model when the page that asked goes, a JSON
Schema the API's structured outputs accept, and a tool loop whose tools check their input. The
platform already had what it takes: `fetch_chunks!` hands a body on as it comes (its doc names "a
model's answer, word by word, to a stream of events"), an endpoint's `events!` streams to a page
and says when the page has gone, `OpenApi` writes a JSON Schema from a Roc type, and packages/mcp
has typed tools.

**Decision.**

- **Anthropic's Messages API, spoken directly**: no layer over several providers, which would give
  only what they share; another provider would be a module of its own. `anthropic-version:
  2026-10-21`; every call streams (`"stream": true`), so a long answer never times out; no
  `thinking` (the current models think as they need, `output_config.effort` says how hard, sent
  always, `Medium` by default), no sampling parameters, no forced `tool_choice`.
- **A plugin, `Ai.plugin({ key, model, base_url })`**, each `""` for the environment's
  (`ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL`, `ANTHROPIC_BASE_URL`). The model is `claude-opus-5-5`,
  and `claude-haiku-5-5` under `--dev`, where answers should come fast and cost little; the check
  once started (`ai.model`) says which and why. Outside `--dev` the server doesn't start without a
  key; under it each call answers `NoKey` (as D-079 treats email without SMTP). Without the plugin a
  call reads the environment itself.
- **Four effects on one `Ai.Request`** (`prompt`, `messages`, `system`, `model`, `max_tokens ??
  64_000`, `effort`, `cache ?? Bool.True`, `max_turns ?? 10`): `ask!` (one turn, whole), `stream!`
  (each text delta to a function whose `Err` closes the request: `Stopped`), `extract!` (structured
  outputs; the answer decoded with `Json`), `run!` (the tool loop). Each answers a `Reply` (text,
  the conversation with it, why it stopped, usage, the model) or an `Ai.Problem(err)`.
- **The stream** is read by `Sse.feed` (bytes to events, a chunk ending anywhere) and put together
  by `Turn.step` (each content block's start and deltas: text, thinking, signature, a tool's input
  JSON). `Turn.message` is the model's message as the next turn sends it; after a server-side
  fallback mid-turn, the declining model's thinking and tool uses before the last `fallback` block
  are left out, as the API asks.
- **Conversations** are `List(Message)`; a message holds its content blocks as `JsonValue`
  (packages/tools'), so what the model wrote goes back unchanged. `Message.save` and `load` keep one
  as JSON text.
- **Typed answers**: `extract!(request, Ai.schema(tags))`. `Ai.schema` is `OpenApi.body` given as a
  value, so it is made where the type is known (`McpHttp.openapi`'s reason). The schema is made the
  API's subset: objects closed, `oneOf` as `anyOf`, ranges, lengths and an integer's `format` left
  out for `Json` to check as it reads; a type that isn't a record is an object's `result`.
- **What a tool is moves out of packages/mcp into a package of its own, packages/tools** (the
  user's call): `Tool`, `Content` and `JsonValue`, on no platform. packages/ai and packages/mcp
  both import it, and ai no longer depends on mcp. Not into packages/ai: ai names the server
  platform (it needs `Http`), and mcp must stay platform-free (the docs site's browser half compiles
  its MCP demo), so mcp can't import ai. `Content.Contents` (a resource's contents, held whole) is
  the type mcp's `Resource.Contents` names. Plate reads Open Food Facts with `tools.JsonValue`
  (its README's gap, "`JsonValue` would be at home in a package of its own", closed).
- **Tools are packages/tools' `Tool(ctx)`**: one tool serves the app's MCP server and its own model.
  `Ai.tool(name, description, run!, Ai.schema([]))` makes one from a function of the app's. Each
  tool's input is streamed (`eager_input_streaming`), then parsed strictly and decoded into its
  type (`Tool.prepare`) before it runs; a bad input, a tool's `Err`, an unknown tool go back as
  tool errors; a `Failed` goes back as "<name> failed.", its reason logged (`ai.tool`). A turn that
  stopped for `max_tokens` or a refusal never runs its tools.
- **Agents, and agents as tools** (the user's ask, after Strands Agents): `Agent(ctx)` is a record
  (`name`, `description`, `system`, `tools ?? []`, `model`, `effort`, `max_turns`, `max_tokens`),
  asked with `Agent.ask!(agent, prompt, ctx, heard!)` or `Agent.chat!(agent, messages, ctx,
  heard!)` (`Ai.run!` with its settings). `agent.as_tool()` is a `Tool(ctx)` taking one `task`
  string: the agent runs it as a conversation of its own and its final text is the result; a
  problem is a tool error (`"<name> couldn't do it: …"`). The caller stays in charge (no handoff);
  the agent's own work isn't streamed to the caller's listener. A request's `label` (an agent's
  name) goes on each `ai.turn` line, so a team's spending can be told apart.
- **Retries**: 408, 409, 429, 5xx, and an `overloaded_error` event before anything was heard,
  tried again twice, after `retry-after` (a minute at most) or half a second, then a second
  (`ai.retry`). Not a connection that broke: its text may already be on a page.
- **Refusals** are `Err(Refused(category))`. On the models that take it (Opus 5.5 and 5, Sonnet
  5.5, Fable and Mythos 5.2 and 5.1) the request carries `"fallbacks": "default"` with
  `anthropic-beta: server-side-fallback-2026-07-01`; Haiku 5.5 has none.
- **Cost on the log**: `ai.turn` with the model, why it stopped, `input`, `cache_read`,
  `cache_write`, `output` and the milliseconds. `cache` (on by default) sends top-level
  `cache_control: {"type": "ephemeral"}`: a conversation's next turn reads the last from the cache.

**Alternatives.** A host-side client in Rust (an SDK's): a platform change for what `fetch_chunks!`
already does, against the user's rule that platforms stay lean (app layer first). Non-streaming
calls for `ask!` and `extract!`: two parsers instead of one, and a timeout to pick for long answers.
A provider-neutral `Model` type: the lowest common denominator of APIs that differ in thinking,
caching, tools and refusals.

**Costs.** The fallback request was first untested against the API (development used Haiku, which
has none); one call on `claude-opus-5-5` (2026-11-26) was accepted, fallbacks, beta
and structured output together. A connection that breaks mid-stream is not retried.
An app that names packages/ai names packages/tools (and crypto) too; one that imported
`mcp.Tool`, `mcp.Content` or `mcp.JsonValue` imports `tools.` instead (no re-export: a Roc package
can't expose another's modules).

**Reversible:** yes: packages/ai is a package nothing else depends on; packages/tools' three
modules could go back into packages/mcp.

## D-086 Every link says where the page is; `<A>` is gone

**Status.** Built (2026-11-26), the user's call: with markup simplified (D-070, D-071), a second link
tag was one too many.

**Context.** `<A>` (D-040, `import pf.A`) was Solid Router's: an `<a>` that read the location in Roc
and wrote `aria-current="page"` and a class while the page was at its path (`end`) or under it.
Every other link navigated in place just the same; only `<A>` knew where the page was, and each one
was a component, a computation reading the location, and a class to learn.

**Decision.** `<A>` is gone (and `A` from both platforms). Every `<a>` whose `href` is one of the
app's own paths (`/…`, not `//…`) and whose markup writes no `aria-current` of its own is marked:
`aria-current="page"` where the page is (its path, and its query if the link has one), `"true"` at
a path the page is under (`/lists` while at `/lists/7`; never `/`). The server writes the mark last
on the element (signals.rs's `current`, and the runtime's `renderToString`, the same rule); the
runtime marks a link it makes (`element`, a template's copy) or adopts, again when its `href`
changes, and every link it marks when a navigation in place commits (`markLinks`). Styling is CSS:
`a[aria-current="page"]` for `<A end>`, `a[aria-current]` for `<A>`. `active_class` has no
successor; `replace`, `noscroll`, `data-rocx-preload` and `data-rocx-link` were already an `<a>`'s.

**Why.** One link tag, as HTML has, and the active state for free, in the server's HTML too (no
frame before the runtime marks it), accessible by default.

**Costs.** A page's links all carry a mark when they are where it is, which a page that marks its
own way (a class) must say with `aria-current` to keep it to itself. A relative `href` (`../x`) or
another origin's is never marked.

**Reversible:** yes: the marking is a few lines in signals.rs and the runtime; `A.roc` is in git.


## D-087 The runtime an app ships has only what it uses

**Status.** Built (2026-11-26), the user's go: step 1 of the js-framework-benchmark plan (D-074),
with D-086's links; its benchmark page's runtime is 124 KB raw instead of 175 (27.5 KB with brotli
instead of 37.5).

**Context.** web/runtime.js answers every host function an app's wasm may call and has the code each
needs: navigating in place (D-040), forms and actions, drags, glides, the server-side renderer the
tests use, and more. A page of the benchmark's ran about a third of it; all of it was downloaded, and
the benchmark's server, compressing each file as it sends it, spends time by the raw byte.

**Decision.** `rocx build --static` and `--release`, once the app's wasm is built, write runtime.js
shaken (`rocx-cli/Shake.roc`) and then minified: the entries of `makeImports` the wasm doesn't
import go (its import section says which: `Shake.wasm_imports`, read with the CLI platform's new
`File.read_bytes!`), and then every member of `Runtime` no kept code names (`.name`, comments aside),
starting from what is outside the class, the constructor, the fields, the imports kept, and what
start.js, the tests and pages' scripts call (`Shake.kept`). A few lines are a feature's (`… //#nav`,
`//#drag`, `//#point`, `//#moves`) and go where the app doesn't use it (`Static.features!`):
navigating in place when it has one page and its wasm calls nothing that navigates; drags, a
pointer's point and `transition:move`'s glides when the browser's copy of its code doesn't write
them. The runtime is read by its lines, as it is written (members at one tab, closing with a lone
`}`; imports at three); a runtime written otherwise ships whole, with a warning. `rocx build
--client` and dev builds ship it whole, as do the tests that load web/runtime.js. Two methods were
renamed so a name names one thing (the forms' `send` is `sendSubmission`, the server-side `html` is
`serverHtml`); the runtime compiles the wasm as it downloads (`instantiateStreaming`). Preload hints
for runtime.js and the wasm in `<head>` were tried and dropped: on the benchmark's server, which
compresses each file as it sends it, the page's stylesheet waited behind them, and the first paint
went from about 45 ms to 275 for a page ready 16 ms sooner. So were delegated event handlers (one
listener on `<html>`): no gain that showed above the noise, and a handler kept on each element is
the page's JS heap where `addEventListener`'s isn't (0.2 MB more for 1,000 rows).

**Why.** What a page downloads and the benchmark's "ready to use" both grow with the runtime's
bytes; most apps use a part of it.

**Costs.** A member reached only by a name built at run time (`this[name]`) would be left out: the
runtime has none, and the docs site's static copy, every page hydrated and its demos used by the
site's tests, is a shaken build. A line tag must be on a whole statement. The decision of what a feature is reads the
app's code for words (`Html.on_point`), so a feature used only through a package's JavaScript
would need its tag never to be decided off.

**Reversible:** yes: Static.shake! is one call; without it runtime.js ships whole and minified.

## D-088 The server reads `.env` as it starts

**Status.** Built (2026-11-26), the user's call: the platform loads `.env` itself, so reading a
setting (`Env.var!`) works with a key kept in the file, for the app and for every plugin. Changed by
D-098 the same day: the server reads only the file `--env-file` names, `rocx dev` names the `.env`
where it runs, and `ROCX_ENV_FILE` is gone.

**Context.** A key kept in `.env` beside the checkout (`ANTHROPIC_API_KEY` for packages/ai) reached
nothing: no part of rocx read the file, so the shell had to export it. A function that read the
file into a record (`Env.from_file!`) was considered first, but plugins are a value made before any
effect runs, and read their keys at start with `Env.var!` (`Ai.plugin({})`, Stripe's, SMTP's): a
record the app reads can't reach them. Reading the file into the environment reaches everything.

**Decision.**

- **The host reads it, in `main`, first**: `.env` in the directory the server starts in, when there
  is one (as `data/app.db` is relative to it), or the file `--env-file FILE` names, which must be
  there, or else `ROCX_ENV_FILE`'s. `ROCX_ENV_FILE` set but empty reads none: `just test`'s recipes
  and packages/testing's `startServer` start servers so, as a developer's `.env` (a `DATABASE_URL`)
  must never reach a test's server. Before the log's thread or tokio's start, as changing the environment is only sound while
  one thread runs; so the server's own settings (`PORT`, `DATABASE_URL`, `KV_MAX_MB`), the log's
  (`TZ`) and the app's all see it. No new hosted function: `Env.var!` is unchanged.
- **The environment wins**: a variable it already has keeps its value, so a deployment's own
  settings (and a test's) are never overridden by a file left beside the server.
- **dotenv's lines** (`server/host/src/dotenv.rs`, no new crate): `NAME=value`, `export NAME=value`,
  `# comments`, a ` #` after an unquoted value; single quotes as written, double quotes with `\n`,
  `\t`, `\r`, `\"`, `\\`, either over several lines; a name given twice, its last value. No
  `${NAME}` expansion.
- **Loud**: a line that isn't a setting, or a named file that isn't there, stops the server (exit 2),
  saying which line; the log says what was set and what the environment kept (`rocx server:
  settings read`), names only, never a value, as the server listens (the app's log format is known
  then; logged at `main`, it was JSON in an app that asked for pretty lines).
- **Out of git**: `.env` is in the repository's `.gitignore` (D-085) and in `rocx new`'s template's.

**Alternatives.** `Env.from_file!(path)` into a typed record: can't reach plugins (above). Only under
`rocx dev`: a release would then need the shell to export what development read from the file, and
`--env-file` covers a release that wants a file. Walking up from the working directory to find one:
a file far from the server deciding its settings is a surprise in production.

**Costs.** A `.env` left beside a production server is read (the environment still wins); its log
line says so. Values with `${NAME}` are kept as written.

**Reversible:** yes: the host stops reading it; `Env.var!` never changed.

## D-089 Updates: what a page shows while a model works

**Status.** Built (2026-11-26), the user's ask: the AI package uses the API's progress updates when a
call asks, and emits updates a page can show ("looking for your info" while a search tool runs).

**Context.** On Claude Opus 5.5, Sonnet 5.5 and Fable, the notes a model writes between its tool
calls come back as `thinking` blocks, empty unless the request asks for `display: "updates"` (beta
`thinking-display-updates-2026-08-18`): a chat that renders text alone goes quiet for the whole
of a turn of tool calls. And an agent used as a tool (D-085's `as_tool`) worked silently: its
caller heard its name, then its answer.

**Decision.**

- **Opt-in: `updates : Bool ?? Bool.False`** on `Ai.Request` and on `Agent`. Off, nothing changes.
- **What is heard: `Ai.Heard : [Text(Str), Calling(Str), Update(Tool.Update)]`**, and
  `Tool.Update : [Progress({ agent, says }), Using({ agent, tool, says })]`, in packages/tools so
  that a tool can speak it: `agent` is the request's `label` (an agent's name).
- **Progress notes**: on the models that write them, the request asks for `thinking: {"type":
  "adaptive", "display": "updates"}` with its beta (beside the fallback's, comma separated); a
  `thinking` block with text, when it ends, is a `Progress` note (the interrupted-work sentinel
  isn't). Haiku 5.5 writes no such blocks: its notes stay `Text`.
- **Tools say what they are doing**: `Tool.doing(tool, "Looking for your info…")`, a new field of
  packages/tools' `Tool`; `Using` is sent as each of the app's tools starts to run (not as the model
  writes the call: a turn's calls are all written before the first runs), with that line. A tool the
  app doesn't have sends none.
- **Agents pass their updates up**: `Tool.with_listener(tool, run!)` gives a tool a run that is told
  a listener; `Ai.run!`, when its call has `updates`, runs such a tool with one that passes each
  update to its own listener. `as_tool` is such a tool: the agent runs with `updates` on and its
  `Update`s go up, each by its name, however deep the team. Its text doesn't (its final text is the
  calling model's tool result). An agent's `doing` is its tool's.
- **Delivery is the app's**: the listener is a function, so updates go out as an endpoint's events
  (the example's chat: a `status` and `agent` in each event, a status line under the coming reply)
  or are published on a channel (`Endpoint.publish!`), documented both ways. No channel of the
  package's own: a channel is a route of the app's, typed by it.

**Alternatives.** A channel the package publishes to: channels are app routes, so the package would
need the app's endpoint value and its types; a function is smaller and covers both. Sub-agent updates
through the app's context (`ctx`): every tool's context would change type. `Using` as the model
writes the call: a page would show the second tool's line before the first had run.

**Costs.** packages/tools' `Tool` gains two fields (`doing`, `listening`). `Ai.run!`'s listener is
`Ai.Heard`, not `Turn.Heard` (whose `Progress` is internal). The progress notes are billed as output
whether shown or not.

**Reversible:** yes: `updates` is off by default; the fields can go.

## D-090 The browser's host is Rust

**Status.** Built (2026-11-26), the user's go: after the wasm-engine spike (`spike/wasm-engine/
REPORT.md`, branch `spike/wasm-engine`), the step of the two that makes the hosts one language, before
the one that moves the reactive graph into the wasm.

**Context.** The browser's host (`web/host/host.zig`, 1,083 lines) was the only Zig among rocx's own
code: the server's, the CLI's and the phone's hosts are Rust (`server/host`, `cli/host`,
`native/core`). And `native/core`, which answers the same platform's hosted functions on the phone,
could share none of it: it has no tracking of what a run that unwinds held, so there such a run leaks
it (`native/core/src/roc.rs`). Zig stays where it was: it compiles the hosts' C for Linux, builds the
Roc fork, and links.

**Decision.** `web/host` is a Rust crate with no std (`#![no_std]`, with `alloc`), a static library
for `wasm32-unknown-unknown`, which `zig wasm-ld -r --whole-archive` makes the relocatable object Roc
links each app's wasm with (`web/platform/targets/wasm32/host.wasm`), as before. Rust's own linker
isn't used: Nix's Rust has no `rust-lld`, and Zig is in the toolchain anyway. It does what host.zig
did, for the same runtime.js (its 69 imports and 13 exports unchanged):

- `src/brk.rs`: Zig's allocator for wasm (`std.heap.BrkAllocator`), ported, so memory behaves as it
  did: slots of a power of two, each size's from its own 64 KiB pages, a freed slot kept on its
  size's list. It is the crate's global allocator too.
- `src/track.rs`: Roc's memory, each allocation with the host's header (its number, its length), and
  the frames, notes, bitmap and reclaiming that free what a run that unwound held.
- `src/lib.rs`: the hosted functions, the exports, and a panic handler that tells the runtime
  (`js_crashed`).
- `src/roc_platform_abi.rs`: RustGlue's, from `web/platform/main.roc`: the same file as
  `native/core`'s.

A string the runtime answers with is written straight into the Roc string's bytes (`js_take` into
its allocation), not into a buffer copied after. The host is built when its Rust is newer than the
object, by `server/build.mjs`'s `buildWebHost` (the tests, the site) and `rocx-cli/Hosts.roc`'s
`web_host!` (`rocx dev`, `rocx build --static`, a release), and by `just web-host`; `just glue`
writes its glue. `just setup` and CI's toolchain add Rust's `wasm32-unknown-unknown` target.

**Measured** (the keyed benchmark's page, Zig's host against Rust's, 2026-11-26): app.wasm 133,091
bytes raw and 39,569 with brotli against 134,083 and 39,712 (0.7% and 0.4% more). Creating 1,000 rows,
10,000, updating, swapping, appending: within each other's noise (two interleaved rounds of 15 each:
25.7 and 26.4 ms against 24.4 and 25.5 for 1,000 rows; 290 and 285 against 288 and 289 for 10,000).
web/test's platform suite passed whole on the first run.

**Why.** The project's own code in two languages, Rust and Roc (with the runtime's JavaScript), and
the way to code the browser's host and the phone's share: the allocation tracking first, which would
end native/core's leak, and more if the reactive graph moves into the wasm (the spike's other step).

**Costs.** Rust's wasm32 target, to install (rustup adds it; Nix's Rust has it). Rust 1.85's features
only, as for the other hosts.

**Reversible:** yes: host.zig is in git's history, and runtime.js didn't change.

## D-091 One memory for the web platform's two hosts

**Status.** Built (2026-11-26), the user's go: the first piece of a front end shared by every
target (D-090's "Why"), after spike/wasm-engine's round 2.

**Context.** The web platform has two hosts: the browser's (`web/host`, in the page's wasm) and the
phone's (`native/core`, D-063), which answers the same hosted functions. The browser's noted every
allocation made in a call into Roc, so what a call that ended early (a read that waits or fails)
held was freed once the runtime let go of what the run handed it (`frame_unwound`, `reclaim`). The
phone's had its own allocator and nothing of that: its guard jumps past Roc's frames, and what they
held leaked, every time a hole or a memo waited.

**Decision.** Roc's memory is a crate both hosts use, `rocx-memory` (`web/memory`, no std):

- The tracking, `web/host/src/track.rs` moved there and made to fit a 64-bit machine: the header is
  16 bytes there (8 on wasm32: the number, a u32, then the length, in its last word), a note's
  address a word, and the allocations still marked a hash set (open addressing) where wasm32's is a
  bitmap of its 4 GiB. Its memory comes from the program's global allocator, and its state is
  behind a spin lock off wasm (one thread runs Roc; the lock only keeps it whole should another
  allocate).
- Zig's allocator for wasm (`brk`, D-090's `src/brk.rs`), the browser's host's global allocator and
  the engine's in a browser (spike/wasm-engine).

The browser's host is as it was, its tracking now the crate's. The phone's runs each call into Roc
in a frame (`roc::guarded`): one that ends early answers its frame (`roc::Unwound`, which must be
used), and the engine reclaims it where runtime.js does, once it has let go of what the run made:
a computation's run that waited or failed (after its `making` is dropped and a memo's `next`
released), a probe, a handler (after its writes are released and its cleanups run), a component
that failed. A crash's frame isn't reclaimed, as the browser's isn't. Each box a hosted function
hands the engine to keep is noted (`hosted::handed`), so nothing the engine still holds is freed.
`native/mac` prints the notes kept after a run (0 when every frame was reclaimed).

**Measured.** The browser's: the benchmark's app.wasm 134,654 bytes raw, 39,930 with brotli
(134,083 and 39,712 before); web/test's platform suite 53/53. The phone's: phone-hello and
examples/tasks on native/mac against their own servers show the same screens and leave the same
live allocations as before, with `notes kept: 0`. `cargo test` of the crate (`just test-web` runs
it): a run that unwinds freed, one that handed a box over still held, runs inside runs, the hash
set.

**Costs.** A frame and a note per allocation on the phone too (the browser had them already). A
64-bit machine's marks are a hash set, not a bitmap.

**Reversible:** yes: native/core's own allocator and guard are in git's history.

## D-092 A path's params have the types their handlers give them

**Status.** Built (2026-11-26). Extended by D-101: a page may say its own (`Params : { id : I64 }`).

**Context.** A handler's `params` were a record of strings (`params : { id : Str }`), so an app
whose ids are numbers parsed them by hand in every handler, and answered `NotFound` itself for an id
that wasn't one (examples/uptime: five handlers of `match I64.from_str(params.id) { …, Err(_) =>
Err(NotFound) }`; the site's count, `U64.from_str(params.to) ?? 0`). Its pages did the same, and
its links wrote `id.to_str()`. The body already had a reader of a type from text (`FormBody`,
D-038), which a path's parts are too.

**Decision.**

- **The annotation says the type**: `get! : { request : Server.Request, params : { id : I64 },
  context : c } => …`. A param may be `Str`, a number (`U8` to `I128`, `Dec`, `F32`, `F64`), `Bool`,
  or a union of tags with no payload written out (`[Draft, Live]`): what `FormBody` reads from a
  part's text, and what every module rocx writes can name without importing the app's (a type of a
  module's is refused at its line: Paths and Root import no app module, and Paths is what pages
  import).
- **One type per param, wherever it is read**: a param is its directory's (`routes/monitors/[id]`),
  so every handler under that directory that names it must give it the same type (rocx build
  refuses two, naming both), and the pages and layouts under it are given it too: `view! = |{ params
  }|` gets `{ id : I64 }`, `Paths.monitors_id({ id: 7 })` takes one, `Root`'s route and its levels'
  keys have it. A param no handler types is `Str`, as before, so an app that writes nothing new
  is unchanged, its generated code too.
- **Read where the path is matched**: `Routes` reads a typed path's parts with
  `Endpoint.read_params` (`FormBody`, which isn't exposed, as a form's fields: `[{ name: "id",
  value: <part> }]`), and so does `Root` (both copies, so client navigation agrees with the server). A part that doesn't read as its type is no match: the 404 a path nothing has
  gets (the error page for a browser, text for anyone else), before any middleware or handler runs.
  A channel's subscription to such a path is a 404, and its close a 204.
- **Written back the way it is read**: Api's and Paths' URLs put a typed param in with
  `Server.encode_param` (JSON's text of a number or a yes-or-no, a tag's name, text as it is, then
  `encode_segment`), a `Str` with `encode_segment` as before.
- **Documented with its type**: `/openapi.json` gives such a path's parameters their schemas, from
  the params' record (`OpenApi.typed_path(at, Api.get_x, tags, operations)`, which writes the
  record's schema with `OpenApi`'s format and takes each field's); a `Str` param stays `{"type":
  "string"}` (`OpenApi.path`).

Converted: examples/uptime's monitors and incidents (`{ id : I64 }`: no parsing, no `NotFound` of
its own; its pages and links pass the number), and the site's count (`{ to : U64 }`).

**Alternatives.** A 400 for a part that doesn't read: but `/monitors/payments` names no monitor,
as `/monitors/9999` doesn't, and SvelteKit's param matchers and Rails' route constraints both make
it no route. Types per handler (each method parses its own): one path's page and endpoints would
then disagree on what `/notes/x` is, and Root has one type per page. A page-only declaration of
its params' types (a `Params` alias in `+page.rocx`): a second way to say it; the handlers'
annotations exist already, and a page without a `+server.roc` beside or below it still gets `Str`
(a later step could read a page's own). Any type with a `FormBody` reader (an app's nominal
`Slug`): Paths and Root would have to import the app's modules, which import Paths.

**Costs.** A typed param's type is the directory's, so two handlers under it can't differ. A part
is read with FormBody (a number's text, trimmed), so `/notes/%207` is note 7. The typed-path
check runs before the path's middleware: a guarded route answers a 404 rather than a 401 for a
part that doesn't read, as for any path nothing answers.

**Reversible:** yes: write `Str` in the annotations; nothing else changes.

## D-093 A body read and checked by the app's rules

**Status.** Built (2026-11-26).

**Context.** An endpoint that validated with packages/forms declared `body : {}` (or a record of
strings, for the page's pending rows), so the platform left the body alone, and re-read the raw
text in the handler: `match TaskForm.adding.parse_body(Server.text_of(request)) { Ok(task) => …,
Err(issues) => Err(Issues.refusal(issues)) }` (sixteen endpoints in tasks, plate, quiz and the
docs' demo). `parse_body` read URL-encoded text alone, so a JSON post failed; `/openapi.json`
described such a body as `{}`; and the 422's issues, JSON, went out labelled `text/plain`
(forms' PROPOSALS 2 and 3).

**Decision.** The route file names the rules, the platform runs them, and the platform never
depends on packages/forms:

```roc
# routes/lists/[id]/+server.roc
post_body = TaskForm.adding          # a value of a module's: Form(TaskForm.Adding)

post! : { request : Server.Request, params : { id : Str }, context : c, body : TaskForm.Adding } => Try(Str, Endpoint.Refusal)
post! = |{ params, body, .. }| Store.add!(params.id, body)

# Generated/Api.roc, both copies
post_lists_id = |params| Endpoint.checked(Endpoint.remote("POST", "/lists/…"), TaskForm.adding)

# web/platform/Endpoint.roc (shared)
Endpoint.checked : Endpoint(c, arg, r), rules -> Endpoint(c, arg, r)
	where [rules.parse : rules, List({ name : Str, value : Str }) -> Try(arg, issues), rules.json_schema : rules -> Str, issues.Json.Encodable(e)]
Endpoint.Refusal : [… Status(U16, Str), Json(U16, Str), Answer(Server.Response)]
```

- **Rules are a shape, not a package**: anything with `parse(fields)` and `json_schema()`. Forms'
  `Form(a)` has both; the platform calls them by static dispatch, so it imports nothing of forms.
- **Read from a form or JSON alike**: `respond!` gives a checked endpoint's rules the form's fields
  (URL-encoded or multipart, the URL's first, as D-054 has them) or a JSON object's, flattened as
  `with_fields` flattens one (text, numbers and yes-or-no as written, a list's items each a value,
  `null` none). A JSON body that isn't an object of such fields is a 400; a type it doesn't read,
  415.
- **Refused with the issues, as JSON**: what the rules refuse never reaches the handler; it is a
  422 whose body is the issues' JSON, `application/json`. A plain form's comes back to its page in
  the flash, as any refusal (LiveForm shows it, as before). A new refusal, `Json(U16, Str)`, is a
  status and a JSON body, sent as `application/json` by `respond!`, `stream!` and `channel!`;
  forms' `Issues.refusal` answers it, for what only the handler can check after the rules (a person
  not on the team).
- **The contract has them, in both copies**: `post_body = M.name` (rocx build refuses another
  shape, a method sent no body, or one the file doesn't define, at its line); Api copies it and
  imports `M` as it imports the types the handler names, so the browser's submissions read what was
  typed with the same rules (`input!`, `pending_inputs!`: tasks' pending rows are now the checked
  record), and `/openapi.json` documents the body with the rules' schema (`OpenApi.sent` of a
  checked endpoint: JSON, URL-encoded and multipart, `Endpoint.checked_schema`).
- **The handler's body is the rules' record**, the contract's arg, so it is a type JSON reads and
  writes and FormBody names, as any arg: forms' `Date` gained a codec, its text; a
  `Try(x, [Missing])` field is one JSON may leave out. An action or `Endpoint.send!` sends it as
  JSON, which the rules read again (a flat record comes through: a day as its text, a missing
  optional left out).

Converted: examples/tasks (3), quiz (3), plate (9) and the docs' forms demo, each to its form
(`post_body`) and a typed `body`; `parse_body` is gone from every endpoint.

**Alternatives.**

1. *A nominal type whose own FormBody/Json parser runs the rules* (`body : TaskForm.Adding`, one
   declaration). A type can't hold a value, so each form would need a type and a parser of its own;
   and the parser, generic over the format, can't do the job: it can't list a form's fields
   (FormBody yields only the names a record type's `FieldNames` give it, which the compiler makes),
   can't refuse with issues (the format's error is its own: Json's `[InvalidJson(Str)]`, so a 400),
   and OpenAPI's format would see what it reads, not the rules' constraints.
2. *The rules in Handlers only* (the server): the browser's submissions would read by type alone
   (a form's `Try(Date, [Missing])` doesn't read so), and `Api.openapi` couldn't name them.
3. *`<method>_schema` beside a hand-written handler* (forms' proposal 3): documents, but still
   reads the body twice and JSON not at all.
4. *RFC 9457 problem details for issues* (forms' proposal 2): a platform shape for field issues and
   a new `Server.Problem` case; kept as a proposal. The issues stay forms' JSON array, which LiveForm
   and `Issues.from_problem` already read, now labelled as JSON.

**Costs.** Two declarations, the rules and the body's type, which the compiler checks agree (the
rules' record is the contract's arg). The rules are a value of a module's, not the route file's.
McpHttp's tools run a handler with `Endpoint.run!`, which reads its arg by type and skips the rules
(TODO). A nested record in a checked body can't come as JSON (a form has no records); its rules
would read it from fields anyway. `Endpoint.checked` names no endpoint in its one crash (a JSON
writer that fails, for an `F64` NaN in the issues): a reader that captured the endpoint crashed the
fork's compiler in boxy_lowering.

**Reversible:** yes: drop `post_body`, and the handler reads its body as before.

## D-094 A setter's function form: `update!`

**Status.** Built (2026-11-26).

**Context.** `create_signal!` gives `(read!, write!)`, and the setter takes a value. A handler's
writes apply when it is done (Solid 2.0's batching), so a read in the handler gives the value before
them: `set_n!(n!() + 1)` twice adds one, and a helper that adds to a signal (`add!(by)`) can't be
called twice in one handler. Solid 2.0's setter also takes a function, given the latest value with
the writes not yet flushed (`setCount((c) => c + 1)`): its rules call that the writer's own
composition channel, the one thing that sees a write before it applies (`latest(count)` doesn't).
rocx's stores had this already (D-053: `set_todos!(|s| …)` starts from `Host.signal_latest!`);
signals and optimistic values didn't.

**Options.**
1. `Solid.update!(set_n!, |n| n + 1)`, given the setter alone. A setter is a Roc closure over its
   signal's id, and the runtime learns the id only when it is called, with a value: there is no way
   to read the latest value through it.
2. A second constructor that answers three things, `(n!, set_n!, update_n!)`. Non-breaking, and its
   call site is short, but the choice is made where the signal is made, not where it is written,
   and `create_optimistic!` would need a twin too.
3. `latest!(n!)` giving the handler's own writes. Solid 2.0's `latest` doesn't: nothing but the
   updater sees an unflushed write.
4. `Solid.update!(n!, set_n!, |n| n + 1)`: the accessor reads the latest value, the setter writes,
   so the types hold whatever the pair is.

**Decision.** 4: `update! : (() => a), (a => {}), (a -> a) => {}` in `pf.Solid`.

```roc
(count!, set_count!) = create_signal!(0)
add! = |n| update!(count!, set_count!, |c| c + n)
<button on:click={|| {
	add!(1)
	add!(1)
}}>Two more</button>
```

- It reads `read!` with `Host.own_writes!(Bool.True)`, then off. While it is on in a handler, a read
  of a signal (`js_signal_get`) gives the handler's latest queued write to it (a plain write, or an
  optimistic one), else its value; then `write!` queues the function's answer as a setter does. A
  plain read in the handler, before or after, still gives the value before the handler's writes.
- It takes an optimistic value's pair (`create_optimistic!`): its read is of a signal too.
- Anything else `read!` reads is as it is: a memo isn't computed again from the handler's writes.
- Outside a handler the flag does nothing, and the setter fails as it does on its own. A handler
  that waits and runs again starts with no writes and the flag off. The server's host does nothing
  (no handler runs there); the phone's engine has the same (`engine::own_writes`, its handler's
  `own`).

**Why.** Composing writes is the reason Solid has the function form, and the place it is chosen is
the write. Given the accessor too, it is one function for signals and optimistic values, with no
new constructor, and `create_signal!`'s pair is as it was.

**Costs.** Three arguments where Solid has one, and nothing checks that the accessor and the setter
are one signal's (a pair from two signals of one type reads one and writes the other). One hosted
function (`own_writes!`) on each host.

**Reversible:** yes: nothing else uses it.

## D-095 A form to an endpoint is always sent with `fetch`

**Status.** Built (2026-11-26). (Its context says SolidStart sends every form to an action with
`fetch`: only a form bound to an action, and never one to a plain URL; D-118 answers the
difference.) Changed by D-118: one nothing on the page reads is answered as a
plain form, and followed in place, instead of its refusal going to the console alone.

**Context.** With the runtime, a `<form method="post" action={Endpoint.url_of(e)}>` went with
`fetch` only while a component had called `use_submission!` or `use_submissions!` for that endpoint
(D-018, D-040 §9.1); otherwise the browser posted it, the page loaded again, and the endpoint
answered with a flash. Whether a form stayed on the page depended on a call somewhere else, which
nothing checked: the docs site's joining page didn't make it, so a refusal (a name of spaces)
reloaded the page and showed nothing, and examples/plate kept a registration it never read
(`_adds`) only to have its forms sent. SolidStart sends every form to an action with `fetch` once
JavaScript is there.

**Options.**
1. The runtime sends every form whose `action` is one of the app's endpoints with `fetch`, keeping
   the plain post for no JavaScript. It needs to know them: the route table it has (D-040) lists
   pages only.
2. `rocx build` warns of a page with such a form and no `use_submission!` of its endpoint in reach.
   Forms are in components, their `action` a value passed in (`live.url()`, a prop), the asking
   component anywhere on the page: a guess at best, and the fallback stays.
3. Both.

**Decision.** 1, and no build warning.

- rocx build writes the paths of the app's endpoints that take a POST into the route table
  (`Root.routes`' `posts`: each `+server.roc` with a `post!`, `/lists/[id]` as pages are written).
  Once `Router.app!` tells it, the runtime listens for `submit` and sends with `fetch` a form that
  posts to one (or to an endpoint a component registered, as before), on this site under its base,
  into this tab (no `target` but `_self`), not `text/plain`, not prevented by a handler. Any other
  form is the browser's: another site's, a plugin's own route (packages/auth's `/auth/sign-out` is
  in no route table), one posted before the runtime is there.
- A submission nobody asks for is kept under its endpoint's path (its query is fields,
  `with_fields`'), as any other: a component that comes later and asks reads it, and a navigation
  forgets it once it is done. Its result reads the page's reads again (or those its answer names),
  as SolidStart revalidates after any action; its redirect (`x-rocx-redirect`) is followed in place.
- A refusal, or no answer, that no component asks for shows nothing on the page, as it showed
  nothing after a plain post: the console says so, in every build (`unread`: the method, the
  endpoint, the status and why, and that `use_submission!` shows it), as the runtime already does
  for a refusal of what a channel was told. The phone's engine has the same (`engine::app` keeps
  the table's `posts`; its log says so).
- `Endpoint.posted_by` is `Runtime` for every such form the runtime sends, and `PlainForm` for one
  posted without it (no JavaScript, or before it is there).
  examples/tasks' delete answers the runtime with the list's id, which the task's own page (which
  didn't ask before, and so posted) now reads and goes to; the endpoint names what a delete changes
  (`Router.revalidate!`: the list and the team's counts), so that page isn't read again first (a
  404). The docs site's joining page reads its submission and shows the refusal; plate's `_adds` is
  gone.

**Why.** A form behaves one way with JavaScript, whatever else the page calls, as Solid Router's
do; the flash stays what it was for, no JavaScript. A build warning would be a guess about where a
form's endpoint is asked for, and it would still leave the page reloading; the console line is
exact, and comes when the refusal does.

**Costs.** An endpoint that answered a plain form and the runtime differently now gives every
JavaScript form the runtime's answer: a page that used to post and land where the endpoint sent it
reads the answer instead (tasks' delete). The route table is longer by the endpoints' paths.

**Reversible:** yes: drop `posts` from the table, and forms are sent only for those asked for again.

## D-096 `Db.one!`: the one row a statement reads

**Status.** Built (2026-11-26).

**Context.** Some thirty places in the examples read one row as a list of them: `rows = Db.all!(…)?`,
then `rows.first()` (or `.get(0)`) and a `map_err(|_| NotFound)` or a match. examples/notes and
examples/board each had a helper of their own for it (`first`), packages/auth matches
`rows.get(0)`. Three lines say what one could, and the annotation `rocx check --sql` reads (D-058)
is a `List(T)` nobody wanted.

**Decision.**

```roc
one! : Str, List(Value) => Try(row, [NotFound, DbErr(Str), BadRow(Str), ..others])
    where [row.Json.Parseable([InvalidJson(Str)])]
```

- **Its row is read as `all!` reads each**, by column name into the record its caller annotated, a
  column that may be null as `Db.Nullable(a)`; `DbErr` and `BadRow` are `all!`'s, its error union
  open as theirs, so a store whose `Problem` is `[NotFound, DbErr(Str), BadRow(Str)]` (tasks,
  plate, board, notes) returns it as it is, and a transaction's body `?`s it.
- **None is `NotFound`**, the tag the examples' stores and `Endpoint.Refusal` already use: an
  endpoint `?`s it into a 404.
- **Several: the first**, in the statement's order, the rest dropped. A statement that may read
  several says which it means (`order by … limit 1`).
- **Checked as `all!` is.** `rocx check --sql` finds `Db.one!(` too, and reads its row's type from
  a binding's annotation, `row : T` before `row = Db.one!(…)?` or `Try(T, …)` without the `?`, or
  from the result of the function the call is the body of (`Try(T, …)`); the check app's
  `DbCheck.Rows(T, Tags)` is the same as for `all!`'s rows (packages/dbcheck is unchanged).
- tasks, plate, board and notes read their single rows with it (board's and notes' `first` helpers
  are gone); the rest of the examples, packages/auth and `rocx new`'s template may move when they
  are next touched.

**Alternatives.**

- **More than one row an error** (Ecto's `Repo.one`). How many rows a statement reads is known only
  after it ran, so the error comes at run time, in production, for what the SQL can say (`limit 1`,
  a primary key) and the check can't; an `update … returning` has written by then. Every call
  converted took the first; sqlx's `fetch_one` and Rails's `find_by` do too.
- **A `limit 1` added by the host.** Db's SQL is the app's, never rewritten (D-045).
- **`Try(Try(row, [None]), …)`, an absent row not an error.** Every caller turned the inner `None`
  into `NotFound`; one that doesn't mind matches `Err(NotFound)`.

**Costs.** `one!` adds no `limit`: a statement that reads many rows still sends them all to Roc,
which decodes them all and keeps the first, and a row after the first that doesn't fit is
`BadRow`.

**Reversible:** yes: `one!` is `all!` and `first()`, which its callers can go back to.

## D-097 VAPID keys without Node: `P256.generate!`, and the push plugin's own pair under `--dev`

**Status.** Built (2026-11-26): TODO's "VAPID keys without Node", found landing D-080.

**Context.** packages/push's setup made its VAPID pair with `node packages/push/vapid-keys.mjs`,
which a release leaves out (`release/pack.sh` drops every `*.mjs`), so an installed rocx had only
`npx web-push generate-vapid-keys`: Node again. And the plugin's needs (`Env("VAPID_PUBLIC_KEY")`
and the other two) stopped `rocx dev` on an app before anything could be tried.

**Decision.**

- **`P256.generate!({})`**, a third effect of the server platform's `P256`: a new pair from the
  operating system's random bytes, `{ public_key, private_key }` (the 65-byte uncompressed point,
  the 32-byte scalar), the forms `sign!` takes. One hosted function, `Host.p256_generate! : {} =>
  List(U8)` (the point, then the scalar, split in Roc), which crashes the call when the system
  gives no random bytes, as `random_bytes!` does: no `Try` for a failure no caller could handle.
  ring makes the pair (`EcdsaKeyPair::generate_pkcs8`) but hands it out only as PKCS#8, which for
  P-256 it writes from one template; the host takes the scalar and the point from where the
  template puts them, checks the bytes around them, and has ring check the two are a pair
  (`from_private_key_and_public_key`) before answering. No new crate; the regenerated glue only
  adds the declaration. It starts `let _host = preempt::host();`.
- **Under `--dev`, no keys is no refusal.** The plugin's `needs` lose the three `Env`s and its start
  checks the keys instead (as packages/auth's start checks `APP_SECRET`, D-081), so `rocx dev` runs
  an app as it is. With neither key set, `Push.keys!` gives the run's own pair: made by the first to
  ask (the start), kept in `Kv` (`push:dev-keys`, until the server stops; `Kv.add!`, so two at once
  agree), and logged once, a warning with the two settings for `.env`, saying that the next start
  replaces it and a browser subscribed with it then subscribes again (`rocx dev` restarts the
  server at each change to its code; the page's script makes a new subscription when the server's
  key changed). With no `VAPID_SUBJECT`, the run tells push services `mailto:dev@example.com`, and
  logs that too. One key without the other still stops the server: a mistake, not a missing pair.
- **Outside `--dev`, as before**: a key missing or malformed, keys that aren't a pair, or no
  contact stop the server at start. Each message about the keys now says how to make a pair
  (`` `rocx dev` makes one: … ``).
- **A deployed server's pair: `GET /__rocx/push/keys`**, an early path of the plugin's (D-033),
  answered under `--dev` alone: a new pair each time, as the two lines that set it (`text/plain`,
  `no-store`), never the run's own, never kept. With `rocx dev` running, `curl -s
  localhost:8080/__rocx/push/keys` gives production a pair of its own, with nothing else installed.
- **`vapid-keys.mjs` is gone**: a release couldn't ship it, and two ways to make keys meant docs
  for both. `npx web-push generate-vapid-keys` still works, and the README says so.

**Considered.**

- The dev log line alone: the smallest change, but a second pair (production's) meant taking the
  keys out of `.env` and restarting.
- A `rocx` command (`rocx vapid-keys`): the CLI's host (`cli/host`) has no crypto (libc alone), so
  it would gain `ring`, a hosted function and its glue, and rocx would know one package's settings,
  which belong in the package.
- The deployed server printing a new pair when it refuses to start: a private key on a production
  log, which may be shipped elsewhere.
- One development pair written in the package, as packages/auth's development secret: subscriptions
  would survive restarts, but every app's dev server would sign with one published private key.

**Tests.** server/test: `generate!` answers 65 bytes (starting 4) and 32, a new pair each call;
Node computes the same public key from the private one; `sign!` takes the pair and Node verifies
its signature, while another pair's private key is refused; `ecdh!` takes the public key as a
peer's, and the secret is the one Node computes with the private key. packages/push's example, on
SQLite and Postgres: without `--dev`, no keys, the public key alone and no subject each stop the
server, saying why (and how to make a pair), and `/__rocx/push/keys` is the app's 404. Under
`--dev` with none, the start logs one pair (Node checks it is one) and the subject's default;
`GET /push/key` answers it; a broadcast is delivered, the push service checking each token against
the logged key, `sub` the dev contact; still one pair logged after; `/__rocx/push/keys` answers two
different pairs, neither the run's; and the public key alone still stops it.

**Costs.** Under `--dev`, a private key on the log and at a path, on the developer's machine (an
early path isn't answered without the flag). An app without keys in `.env` unsubscribes its test
browsers at each restart of `rocx dev`.

**Reversible:** yes: the needs back, the dev pair and the path out; `P256.generate!` stands alone.

## D-098 The server reads a settings file only when `--env-file` names it

**Status.** Built (2026-11-26), the user's call; changes D-088.

**Context.** Under D-088 the server read `.env` in the directory it started in, by itself, and a
server that must not (a test's) was started with `ROCX_ENV_FILE=` set but empty. Safety was the
harness's to remember, and forgetting it said nothing. An app's own test harness, which starts the
app's built server with an environment of its own (`PATH` and the settings each test wants), had
never heard of the variable: from the app's folder, its servers read the developer's `.env`, so its
tests ran with the developer's real OAuth keys, and the one that checks that nothing is configured
without keys failed. A `DATABASE_URL` there would have pointed its servers at the developer's
database. And a line of that `.env` the parser refuses would have stopped every one of them (exit 2),
a test's server failing for a file it was never meant to read. D-088 counted a `.env` left beside a
production server among its costs.

**Options.**
1. Keep D-088, and have every harness turn the file off: what failed.
2. Read `.env` only under `--dev`: a test's server is often started with `--dev` (its dev sign-in,
   its mailbox), so it would read it still.
3. A test mode that skips the file (as Next.js skips `.env.local` under `NODE_ENV=test`): the harness
   still has to say it is one.
4. **Read a file only when one is named**, and have the commands of development name it (Node's and
   Deno's `--env-file`).

**Decision.** 4.

- The host reads the file `--env-file FILE` names (`--env-file=FILE` too), which must be there, and
  no other: without the flag nothing is read, a `.env` where the server starts neither. Its lines,
  the environment winning, the log's line and exit 2 for a bad line or a missing file are D-088's.
- **No variable names it.** `ROCX_ENV_FILE` is gone: a variable reaches every process started under
  it, so one exported in a developer's shell would reach the tests' servers again. A flag is given
  to one server.
- **`rocx dev` names `.env`** in the folder it runs in, when there is one and what follows `--`
  names no file (`Hosts.env_file!`), for its server and for the SQL check it runs after each build
  (D-058), so both see the same `DATABASE_URL`. It looks once, as it starts. `rocx check --sql` on
  its own names none (CI and the tests run it from the repository's root, beside a developer's
  `.env`); `-- --env-file .env` gives it one.
- The harnesses lose their `ROCX_ENV_FILE=` (the Justfile's test recipes, server/build.mjs's
  `start`, packages/testing's `startServer`): there is nothing to turn off. test/dev.test.mjs runs
  `rocx dev` in the app's folder, with a `.env` there, and checks that the server read it.

**Why.** The safe way is the default, and forgetting costs a missing key in development, which the
log already says (`off: no ANTHROPIC_API_KEY`), never a test or a deployment reading a file nobody
gave it. A server started by hand, by a test, by CI or in production has the environment it was
given and nothing else, as twelve-factor's config is; the one command that is development's asks for
the file, as `node --env-file` does.

**Costs.** `./build/server` started by hand reads no `.env`: `--env-file .env` asks. A `.env` made
while `rocx dev` runs is read once it starts again. The docs say where the file is read: README,
server/README, Env's doc comment, the template's README, packages/ai's, and the site's settings,
server, platform and AI pages.

**Reversible:** yes: the host reads `.env` when none is named again.

## D-099 `rocx build --image`: a container image without a Dockerfile

**Status.** Built (2026-11-26), the user's idea ("something like what `dotnet` does, where it has
commands to build docker images").

**Context.** An app went into a container by a Dockerfile of the app's own: `rocx build --release
--target arm64musl`, then a base image (distroless's static, for a non-root user), the executable
and the static files copied onto it, and `docker build` to make it. The executable is static (musl)
and carries its TLS roots (webpki-roots), so the base added nothing but a user, and every app
wrote the same few lines. .NET's SDK (`dotnet publish /t:PublishContainer`), Go's ko and Java's
Jib write an image themselves: an image is files in a tar and three small JSON documents.

**Decision.**

- `rocx build <dir> --image <file.tar> [--tag name:tag] [--target arm64musl|x64musl]` builds the
  release (`Release.made!`, into the app's `build/image/release`) and writes the image itself:
  no Dockerfile, no base image, no Docker to build it. The target is this machine's processor's
  Linux unless named; the name is the directory's, `:latest`, unless `--tag` gives one.
- **One layer**, owned by root but for `/app/data`: `/app/server` (0755), `/app/static/` (as
  `--release` lays it out), `/app/data/` owned by 65532 (the working directory's `data/`, a SQLite
  or Turso app's `data/app.db`, where a volume goes), `/etc/passwd` and `/etc/group` naming root and
  `nonroot` (65532, as distroless's), and `/tmp` (1777). Every file's time is 0.
- **Its configuration**: user `65532:65532`, working directory `/app`, entrypoint `/app/server
  --host 0.0.0.0` (with `--static /app/static` when the app serves files), `PORT=8080`, port 8080
  exposed. Arguments to `docker run` go after the entrypoint's (`--dev`); settings are environment
  variables, as for any release.
- **The file** is an OCI image layout in a tar (`oci-layout`, `index.json`, `blobs/sha256/…`), the
  index naming the image as containerd and Docker read a name, with `docker save`'s
  `manifest.json` beside it for a Docker that reads no layout: `docker load -i` takes it, as do
  podman and skopeo (`oci-archive:`), which can push it to a registry. The layer is gzipped by the
  system's `gzip -n` (no name, no time); the digests are Roc's builtin SHA-256. The tar is
  rocx's own (`Image.tar`: ustar, a path over 100 bytes split into its prefix).
- test/image.test.mjs builds a small app's image, reads the file back (each blob's digest and size,
  the configuration, the layer's diff_id, the files' modes and owners) and, where Docker answers,
  loads it and fetches the app's page from the container.
- Found on the way: on a large app the compiler crashed (SIGSEGV in lambda-set solving) building the
  browser's wasm with `--specialize=yes`, so `--release`, `--static` and `--image` failed where
  `rocx dev` (which doesn't specialize) built. Their browser's build now tries specialized first and,
  when the compiler crashes (not when it refuses the program), builds without (`--specialize=no`,
  boxy, as the server is) and says so (`Static.browser_build!`). On that app the boxy wasm was
  2.0 MB raw, smaller than its dev build's 2.2.
- And: a clone built its musl hosts with the release profile's debug info (`debug = 1`, for
  backtraces under `rocx dev`), which a musl host never runs under; it was 140 MB of that app's
  180 MB server. A musl host is now built without (`CARGO_PROFILE_RELEASE_DEBUG=0`, in
  `Hosts.server_host!` and server/build.mjs), its symbols kept for a backtrace's names, as a
  release's hosts are stripped (release/hosts.sh). The Mac host `rocx dev` runs keeps its debug info.

**Why.** The image an app needs is the same for every app, and rocx already knows what goes in it.
Nothing to write, nothing to keep in step, and no Docker on the machine that builds it.

**Not chosen yet.** Pushing to a registry (`--push`, the registry's API with a token): skopeo, or
`docker load` then `docker push`, does it now. A base image of the app's choosing, labels, and more
than one layer (the executable apart from the static files, so a change to one sends only it).

**Reversible:** yes: the command goes, and a Dockerfile does what it did.

## D-100 A path is a page or an endpoint: a page's endpoints under `api/`

**Status.** Built (2026-11-26), the user's call: "the blessed path to be 'endpoint or page per
path, not both'", with a page's endpoints mirrored under `api/`; docs only for now, a configurable
lint later (TODO).

**Context.** A `+server.roc` beside a `+page.rocx` answered at the page's URL: a browser's GET was
the page, anything else the endpoint's, chosen by `Accept` (as SvelteKit's `+page.server.ts` and
`+server.ts` share a path). Nothing said so in the answers, so a cache (a CDN with a rule for the
path, the browser's own) could keep one and give it for the other: a page's JSON shown on a
navigation, its HTML given to a `fetch`. And a page with no `middleware` line ran behind the one
beside it (D-079), so moving or deleting the `+server.roc` unguarded the page with no change to it.
A lever that put endpoints under a prefix by themselves was considered and dropped: a file's URL
changing with what sits beside it is worse than the problem.

**Decision.**

- **The blessed layout**: a path is a page or an endpoint, never both. A page's endpoints (its data
  and its forms' actions) are `routes/api/<the page's path>/+server.roc`: the page at `/lists/:id`
  reads `GET /api/lists/:id` (`Api.get_api_lists_id`) and its forms post to `/api/lists/:id`. Each
  file names its own middleware. Endpoints that stand on their own (a webhook, a callback, a feed,
  `/.well-known`) stay where their URL must be.
- **A pair still works**, and says so: every answer at a path where a page and an endpoint meet, and
  the error page (chosen by `Accept` too, a page or text), carries `Vary: Accept`
  (`Routes.by_accept`, written by rocx build).
- **The examples, the packages' examples, the template and the docs site follow it**, and a page's
  other endpoints went under `api/` with them (what its forms post to, a stream it listens to: the
  template's two-factor and mail endpoints, board's cards and presence, quiz's rooms, the site's
  members' leave and the lobby channel). Left where they are, as their URL is held elsewhere or by
  convention: Stripe's webhook, packages/auth's `/auth/*`, the auth example's endpoints its README
  names as scripts' (`/admin`, `/impersonate`…), uptime's `/health`, the URL its seeded monitor
  checks, and packages/admin's mounted pages. test/e2e/app and web/test/nav keep their pairs, to test
  that a pair still answers as it did, now with `Vary`.
- A page's typed params (D-092) came from the handlers in its own directory, which the layout leaves
  empty: a page says its own now (D-101), and uptime's `monitors/[id]` and `incidents/[id]` moved too.
  notes' note page mirrored onto its public JSON API (`/api/notes/[id]`): its actions joined that
  file, behind the API's middleware (the user: "fine"), and the page reads the API's note.
- The docs (README, the template's README, the site's routing pages) teach the layout; nothing warns
  of a pair yet.

**Why.** One URL, one answer: nothing for a cache to mix up, and a page's guard is in the page.
Under `api/` at the page's path, the endpoint is found from the page without a rule to learn.

**Costs.** Two files a page with data where there was a folder with both; a page's form actions are
written as the endpoint's URL (`/api/orgs?/create`, or `Endpoint.url_of(…)`) rather than `?/create`.
Apps outside the repo that pair keep working.

**Reversible:** yes: the files back beside their pages, and `Vary` stays harmless.

## D-101 A page says its params' types: `Params : { id : I64 }`

**Status.** Built (2026-11-26), the user's call ("redeclaring types is fine"; nothing implicit).

**Context.** A path's param has the type the handlers in its directory give it (D-092), and the
pages there are given it. Under D-100 a page's endpoints are under `api/`, another directory, so a
page with endpoints there had no handler of its own directory to type its params: uptime's monitor
and incident pages would read `id` as a `Str` again. Taking the types from the `api/` directory at
the page's path was refused: a file's types coming from a directory it doesn't name is the coupling
D-100 removed. A type in the directory's name (`[id=I64]`, as SvelteKit's matchers) would be one
place for the page and its endpoint both, but `:` is no file name on Windows, a union of tags
doesn't fit a name, and the handlers' annotations would remain a second way.

**Decision.**

- A page may say its params' types, as a type in the page: `Params : { id : I64 }`, at the start of
  a line (over several lines while a brace is open). rocx reads it (`Routes.params_alias`) as it
  reads a handler's annotation: one more use of the params of the page's directory, under D-092's
  rules: the same types allowed (a number, `Bool`, `Str`, a union of tags written out), one type per
  param wherever it is said (a page's `Params` and a handler in its directory must agree, rocx build
  says where they don't), and the pages and layouts below are given it, as `Paths` and `Root` are.
- Nothing is read across directories: a page with no `Params` (and no handler beside it) has `Str`
  params, whatever an endpoint under `api/` says. The page and its endpoint each say the type.
- The page may use the alias itself (`params : Params`), or not.

**Why.** Each file says what it reads, as D-100 wants, in the language's own syntax.

**Costs.** The type is written twice for a page and its endpoint (`Params` and the handler's
`params : …`), and nothing checks that the two agree across directories.

**Reversible:** yes: the alias is read, nothing else depends on it.

## D-102 An endpoint is read and sent by its own methods: `read!` and `send!`

**Status.** Built (2026-11-26).

**Context.** A page read its data with `Endpoint.get!(Api.get_api_echo_message({ message }))`: a
wrapper around the contract's value, and the word `get` twice, the method's name in Api's and the
read's. A refusal as a value was a third function, `Endpoint.read!`, and sending was
`Endpoint.send!(endpoint, arg)`. Api's functions return a value, not a call (D-037), and that value
is used fifteen ways (`url_of`, `use_action!`, `use_submissions!`, `with_query`, channels), so it
can't become the call itself.

**Options.**
1. Generated twins in Api: `Api.get_api_echo_message!({ message })` beside the value. Two names per
   endpoint, and the read with a query (`with_query`) or of an endpoint passed around still needs
   `Endpoint`'s.
2. Static dispatch on the value, the names as they were: `Api.get_x({}).get!()`, `get` twice still.
3. One verb, `send!`, for everything: every page read would be a `Try` to match, and no refusal would
   reach an `<Errored>` by itself.
4. Two verbs, named by what they do, not by HTTP's methods, called on the value.

**Decision.** 4.

```roc
echo! = |message| Api.get_api_echo_message({ message }).read!()             # the value; a refusal fails the read
sent = Api.post_api_shout({}).send!(word)                                  # Try(result, Server.Problem)
link! = |token| Api.get_sign_in_link({}).with_query(query).send!({})       # a GET, its refusal as a value
```

- **`read!`** is what `get!` was: a GET's answer as a plain value, answered in-process and noted for
  the page while the server renders it; a refusal fails the computation, for the nearest `<Errored>`.
- **`send!`** is as it was for the other methods. Given a GET, it asks it as `read!` does (the
  host's fetch with its header written out, so a read that isn't in yet leaks nothing), with the
  refusal as a value: what `Endpoint.read!` was, now gone.
- **Method calls, not new names**: `endpoint.read!()` is `Endpoint.read!(endpoint)`, so a module that
  only reads and sends needs no `import pf.Endpoint` (48 such imports dropped). The docs, the
  examples, the packages' examples and the template write the method form, `Endpoint.send!(x, arg)`
  calls too.

**Why.** The read says what it does, once, after the endpoint it reads; a handler's `get!` and a
page's `read!` are no longer one name for two things.

**Costs.** A breaking rename: an app's `Endpoint.get!` doesn't compile, and its `Endpoint.read!`
gives the value, not a `Try` (a type error where it is matched). Apps outside this repository move
by hand.

**Reversible:** yes: `get!` back as `read!`'s other name.

## D-103 Middleware by folder: `+middleware.roc`, groups, and guards that go with an endpoint

**Status.** Built (2026-11-26), the user's call, after a review of where an app names middleware;
changes D-079 (a page's middleware from the `+server.roc` beside it).
Changed by D-114, then D-116: a plugin has no routes, and every URL is a route file, so
`routes/+middleware.roc` is around every request again.

**Context.** An app named middleware in two places, with a rule between them: the app's default
(`App.program({ middleware })` in main.roc) around every request, and a route file's own line
(`middleware = Middlewares.signed_in`) around that file alone; a page that named none took the line
of the `+server.roc` beside it (D-079). Nothing went down the tree, so the same line was copied into
nearly every file of an area: `Middlewares.signed_in` 64 times across the repository's apps, the
private app's 47 route files of 66, board's 18 of 20; and a file that forgot it was open. Two apps
scoped by path by hand instead, a list of public paths in their default middleware (plate's
`is_public`, the private app's `reachable_signed_out`), which nothing kept in step with the routes;
guard's example did the same for its API (`Guard.under("/api", …)`). D-100 put a page's endpoints
under `api/`, so the page and its data no longer share a directory, and D-079's rule guarded less.
Besides: an MCP tool ran an endpoint's handler directly (`Endpoint.run!`), past the endpoint's
middleware, so notes' `agent` middleware repeated `api`'s bearer check; the MCP server answered its
path from inside the app's middleware (`McpHttp.middleware`), a third way to put something at a
URL; two apps wrote the same "only for writes" wrapper (`posts_only`, `writes_only`); five
programs wrote a middleware that does nothing; and fifteen of twenty-two defaults began with
`Middleware.same_origin({})`.

**Decision.**

- **A `+middleware.roc` in a directory under `routes/`** names a middleware (`middleware = …`, a
  bare file as a route file is, written as a module under Generated/: `MembersMiddleware`) that runs
  around every page, endpoint and channel in that directory and the directories below it, outermost
  first, each given what the one around it handed on. Generated/Routes nests them
  (`Middleware.run!(A.middleware, request, context, |passed_1, handed_1| Middleware.run!(B…`); the
  types are checked as before: a handler that reads `context.user` compiles only behind one that
  adds it. `+middleware.rocx` is refused (it is plain Roc).
- **`routes/+middleware.roc` is the app's**, around every request the app answers (its plugins'
  routes, the OpenAPI document, a path nothing has): `App.program` loses `middleware`, and
  Generated/App imports the file's module. An app without one has no middleware.
- **Groups**: a directory in brackets, lower case (`(members)`, `(signed-in)`), adds nothing to the
  path. Its `+middleware.roc` and `+layout.rocx` reach the files in it alone, so a page and its
  endpoint under `api/` share a guard, and public pages sit outside it. Module names keep the group
  (`(members)/account/+page.rocx` is `MembersAccountPage`); paths and Paths' names don't (`/account`,
  `Paths.account`). Two pages, or two `+server` files, at one path in two groups are refused. The
  error page stays in `routes/` itself.
- **No middleware in a route file.** A page, an endpoint, a layout or the error page that names one
  is refused, saying which `+middleware.roc` to move the line to. D-079's rule is gone, and so is
  the transpiler's dropping of a page's middleware from the browser's copy (`without_middleware`).
- **A change another site's page sends is refused by the platform** (`Middleware.same_origin`,
  outermost, before routes/+middleware.roc), unless the app says `cross_site: Allowed`; then a
  directory's middleware may refuse it where it should.
- **`rocx routes`** says what runs around each route, outermost first (`Middlewares.default →
  Middlewares.signed_in`); the static build leaves out the pages behind any directory's middleware
  but routes/'s, as it left out a page behind its own.
- **An endpoint sent on the server goes through its route.** `Endpoint.send!` in code answering a
  request (a handler, an MCP tool) is answered in-process, as a page's reads are while it renders:
  behind the app's middleware and the endpoint's, with the request's headers (its cookies, its
  `authorization`), the method, the body and its `content-type` (the server's `roc_fetch`; nothing
  is noted for a page). `Endpoint.run!` is gone. `McpHttp.endpoint` sends Api's contract
  (`Api.post_api_search`, not Handlers'), so what guards an endpoint guards the tool, and a module a
  route file imports may make tools; `McpHttp.middleware` is gone: the MCP server is a route
  (`routes/mcp/+server.roc`, `respond! = |{ request, context, .. }| McpHttp.respond!(Agents.server,
  request, context)`, its folder's `+middleware.roc` deciding who may ask). `McpHttp.function`
  calls its function itself.
- **`Middleware.when(asked, guard)`**: `guard` for the requests `asked` says
  (`Middleware.when(Server.changes, Guard.rate_limit(…))`). `Guard.under` stays, for paths no
  directory has (a plugin's).

**Why.** One place says what guards an area, and it is where the area's files are: a new file in it
is guarded without a line, and `rocx routes` shows the whole chain. A guard written once in an
endpoint's directory holds for every way to reach the endpoint: a browser, a script, a page's read,
an MCP tool.

**Considered.** Prefix scoping by URL (a `+middleware.roc` reaching every request under its path,
plugins' and missing paths too): D-100's `api/` would have needed every guard twice. Keeping the
file's line beside the directory's, for a guard of one file alone: every file is alone in its
directory already, so a `+middleware.roc` there does it; what it costs is that it reaches the
directories below too. Middleware in `+layout.rocx` (SvelteKit's layouts' loads guard pages):
endpoints have no layouts, and D-079 refused it.

**Tests.** test/routes.test.mjs: nesting, groups, the root's middleware in App and not in Routes,
`rocx routes`' chains, the problems (a file that names its own, a `+middleware.roc` that names
none), clashes in groups; the browser's build reaches no middleware. server/test: a handler's
`send!` of an endpoint behind a middleware, answered with the request's cookie and refused without
it. The examples, the packages' examples, the template, the e2e app and the docs site moved.

**Costs.** Every app moves its main.roc's `middleware` and its route files' lines into
`+middleware.roc` files. A one-off guard in a directory with directories below reaches them too.
Middleware errors are reported in Generated/Routes.roc, as before. A plugin under a guarded
directory isn't guarded by it (`JobsPage.plugin({ guard })`, or `Guard.under` in routes/'s). A tool
call is a second request through the app's middleware (its log, its limits) inside the MCP request.

**Reversible:** yes: the field back in `App.program`, the line back in route files.

## D-104 A release's host has the app's database engine alone, and no debug info

**Status.** Built (2026-11-26), the user's call: the images `rocx build --image` (D-099) wrote were
big (a large app's 19 MB to send, a hello world's 15), and a release should carry SQLite alone where
that's all it needs. Per app rather than SQLite for all: an app names one engine, and gets that one.

**Context.** Measured for linux/arm64 (gzipped, as sent; on disk in brackets): a hello world was
14.6 MB (43.3), the large app 19.3 (56.9). The app's own Roc was 0.6 MB of hello's code (9.6 of
the large app's); the rest was the host, and every host had all three engines. Turso's was two-thirds of
the host's code once the generic code it brings is counted (16 MB of code, 5 without it); Postgres's
client about 1 MB. Then 12 MB was debug info that Rust's std brings into the host (the host's own
crates have had none since D-099), which nothing in a container reads. For comparison: Go's
`net/http` hello world is 2.2 MB to send stripped (4.4 as `go build` leaves it), Rust's
tokio+hyper one 0.4; before an app is in it, Node's alpine image is 62 MB, Python's slim 43, Bun's
distroless 59, .NET's chiseled ASP.NET 50.

**Decision.**

- **SQLite is in every host; Postgres and Turso are cargo features** of server/host (`postgres`,
  `turso`), both on by default: `rocx dev`'s host, the tests', `rocx check --sql`'s and an installed
  version's have every engine. `src/db/` leaves out what a build hasn't, and a server built without
  an engine refuses it as it starts, saying what to write in the program: a SQLite app's release
  given `--database-url turso:…` says it was built without Turso. (Trying a SQLite app on Turso is
  for `rocx dev`, or `rocx check --sql --engine turso`.)
- **`rocx build --release` and `--image` build the host with the engine the app's program names**,
  read from its main.roc (`Hosts.engines_of`): SQLite alone for `database: Sqlite(…)` or for an
  `App.program({ … })` that names none (its default since D-105; Postgres before), Turso for
  `Turso(…)`, Postgres for `Postgres`.
  A program that names it some other way (a value, a call), names two, or is given its record from
  another module (`App.program(config)`) gets every engine. Each set is
  built in a cargo target directory of its own (`server/host/target/engines-<name>`), beside the full
  host's. The release's message says which engines its server has.
- **The platform's own `targets/` stay as they are.** The release links against a copy of the
  platform's modules, with that host in its `targets/<target>/`, put in the platform's place by
  `roc build --replace-dep` (the fork's flag; it knows a dependency by its real path, and replaces it
  for the packages that name the platform too). The copy is one per app and target, in the
  system's temporary directory (`$TMPDIR/rocx-release-platforms/<app>-<hash>-<target>/`, deleted
  once the server is linked): not in the app, whose files `rocx lint`, `rocx fmt` and editors read
  (the platform's `Html.source_text` tripped the lint there), nor in rocx, which an installed
  version keeps read-only (the first release's dry run found that). A `rocx dev`, a test or another app's build linking against the platform
  meanwhile is unaffected, so nothing takes a lock.
- **A musl release's server loses its debug info**: `llvm-strip --strip-debug`, from rustup's
  `llvm-tools` (added when missing, as the musl target is), else `$LLVM_STRIP` or one on PATH; with
  none, the build says so and keeps it. Its symbols stay, for a backtrace's names. A Mac's
  executable has none to lose, and an installed version's hosts are stripped already
  (release/hosts.sh).

**Results** (linux/arm64, to send, on disk in brackets): hello world 14.6 → 4.4 MB (43.3 → 11.5),
as a Postgres app by default; 3.6 (9.5) with `database: Sqlite(…)`. The tasks example (SQLite) 15 →
4.8 (13.0); the same app on Turso 11.5 (32.1), on Postgres 5.6 (15.0). The large app (SQLite) 19.3 → 9.0
(57 → 25.2), its own Roc 9.6 MB of that.

**Tests.** test/image.test.mjs: the server has no `.debug_*` section and keeps `.symtab`, and the
app (which names no database, so Postgres) has no Turso in it, and Postgres and SQLite. Hosts.roc's
expects read programs' engines. All four combinations of the features build with no warnings.

**Not chosen yet.** Prebuilt bundles with a host per engine: an installed version links its full
host for now. Link-time optimization of the host (on the full host 12 MB less on disk and 2.6 less to
send, for minutes more per host build). Stripping the symbols too (0.4 MB less to send, backtraces
without names).

**Costs.** A release can't be pointed at another engine by its URL. The first release of each
engine's host compiles the host's crates again, in its own target directory (a minute or so).

**Since 2026-11-27, installed versions too.** A release's bundles carry, for each Linux target, the
host with SQLite alone and with Postgres (`server/platform/engines/<sqlite|postgres>/<target>/
libhost.a`, built and stripped by release/hosts.sh, copied by release/pack.sh: 39 and 48 MB beside
the full host's 98); an installed rocx's `release_platform!` stages the one the app names, and links
its full host when the bundle has none: a Turso app's (Turso's alone is 89 MB, too little smaller to
carry), a Mac target's release.

**Reversible:** yes: `release_platform!` gives the platform's own main.roc for every engine, and
the features stay on by default.

## D-105 An app's database is SQLite's `data/app.db` unless its program names one

**Status.** Built (2026-11-26), the user's call, after D-104 showed a hello world carrying Postgres
because `App.program`'s default was `Postgres`.

**Context.** `database` defaulted to `Postgres` (D-045), at `--database-url`, with no database without
one. But every example with a database names `Sqlite(…)`, `rocx new` asks with SQLite first, and the
image's `/app/data` (D-099) is for a SQLite file. An app that named nothing got the engine that needs a
server of its own, and since D-104 its release carried Postgres's client for it.

**Decision.**

- `App.program`'s `database` is `Sqlite("data/app.db")` unless the program names one: a file beside
  where the server starts, made with its directory when missing (`?? Sqlite("data/app.db")` in the
  `Generated/App` rocx build writes). `Postgres` and `Turso(path)` are named, as before.
- So an app that names none opens that file as it starts, and the platform's tables (jobs, actors)
  are made in it; `data/` is ignored where the repository's apps run. It is a SQLite app: a
  `postgres://` `DATABASE_URL` stops it at start, as for any SQLite app (D-045).
- `Hosts.engines_of` reads an `App.program({ … })` that names none as SQLite: its release's host has
  SQLite alone (D-104). A hello world's image is 3.7 MB to send (4.4 with Postgres).
- The apps in the repository that ran on the old default with a Postgres name it now: the e2e app,
  packages/testing's fixture and the posthog example (their tests' jobs are on `DATABASE_URL`), and the
  docs site (`rocx site dev` passes `DATABASE_URL` on, and it has no database without one).

**Costs.** An app with no database at all has a SQLite file anyway. An app that relied on the default
for Postgres says `database: Postgres` now: given a `postgres://` URL, it stops at start, saying
what to write; given none, it runs on the file.

**Reversible:** yes: the default back in `Generated/App`, and the four lines go.

## D-106 An answer of a handler's own is its `Ok`: `Try(Server.Response, Endpoint.Refusal)`

**Status.** Built (2026-11-26).

**Context.** A handler's `Ok` is sent as JSON: it is what the typed client reads (`read!`,
`send!`, a submission's `result!()`). An endpoint whose success isn't JSON, a text file a service
fetches to check the site is ours, a video, a redirect that sets a cookie, had one way to answer:
the refusal `Answer(response)`, "exactly this answer". So its success was an `Err`:

```roc
get! : { request : Server.Request, params : { file : Str }, context : c } => Try({}, Endpoint.Refusal)
get! = |{ params, .. }| if (params.file == "token.txt") Err(Answer(Server.response(200, …, "token=abc"))) else Err(NotFound)
```

It reads as a failure, and the `{}` it claims to answer is never sent. `respond!`, which answers
any method with a `Server.Response`, avoids it, but then the handler checks the method itself and
writes its own 405, which `get!` has for nothing.

**Options.**
1. As it was: `Err(Answer(…))`, a comment saying why.
2. `respond!` for these: no `Err`, but every method by hand.
3. A handler annotated `=> Try(Server.Response, Endpoint.Refusal)` has its `Ok` sent as it is.
   `rocx build` already reads the annotation (Api's types, D-037; typed params, D-092), so it tells
   these apart and answers them another way.
4. A wrapper type for such answers (`Endpoint.Own(response)`), sent as it is: a second spelling of
   `Server.Response`, to import and wrap.

**Decision.** 3.

```roc
get! : { request : Server.Request, params : { file : Str }, context : c } => Try(Server.Response, Endpoint.Refusal)
get! = |{ params, .. }| if (params.file == "token.txt") Ok(Server.response(200, …, "token=abc")) else Err(NotFound)
```

- **`Endpoint.respond_as_is!`** answers such an endpoint: `respond!`'s reading of the body and its
  refusals, and its `Ok` sent as `Answer`'s response is (a redirect of its own comes back to a form
  the runtime sent as 200 with `x-rocx-redirect`). The two share one body (`answered!`), handed how
  an `Ok` is answered. `Generated/Routes` calls it for a method whose annotation's answer is exactly
  `Server.Response` (`Routes.answers_as_is`), `respond!` for the rest.
- **The contract says so too**: Api's answer is `Server.Response` in both programs (the browser's
  platform has the type). The typed client doesn't read it: `read!`, `send!`'s result and a
  submission's `result!()` need an answer of JSON, and `Server.Response` has none (a compile error
  where one is asked for). A page links to such an endpoint, posts a form to it (its redirect is
  followed, D-095), or reads a submission's `error!()`.
- **`/openapi.json`** gives its answer any type and no schema (`OpenApi.as_is`: `"*/*":{}`): the
  handler says what it sends.
- **`Answer(response)` stays**, for a handler that answers JSON but sometimes its own: a result with
  a cookie (the docs site's planner), a plain form's redirect beside the JSON the runtime reads
  (the tasks example's delete).
- The docs site's join and leave endpoints and the examples' handlers whose every success was
  `Err(Answer(…))` (board, notes, plate, quiz, tasks, uptime: 19 route files and quiz's `Entry`)
  answer `Ok` now. test/e2e.test.mjs checks a text answered as it is, its refusal, rocx's 405, a
  redirect with its cookie as it is and to the runtime's form, and the OpenAPI entry.

**Why.** A success is an `Ok`, and what a handler sends is what its annotation says. The method
check stays rocx's.

**Costs.** Two ways for an answer of one's own: a handler's `Ok`, when every success is one, and
`Answer`, beside a JSON result. A handler that names `Server.Response` gives up its typed client.
The generator tells it apart by the annotation's text, so an alias of `Server.Response` is taken
for JSON (and doesn't compile, since a response isn't JSON).

**Reversible:** yes: `respond_as_is!` and its branch in the generator go, and the handlers go back
to `Err(Answer(…))`.

## D-107 `rocx build` is the build to deploy; `rocx generate` writes the code; a CLI that draws its steps

**Status.** Built (2026-11-26), the user's two calls: `rocx build` builds to deploy (dist/, or an
image or a static copy by its flags), and the look with a mark and a time for each step.

**Context.** Starting an app was to be `rocx new`, `rocx dev`, `rocx build`. The first two held; the
third didn't: `rocx build` alone printed a 900-character usage line, and `rocx build .` only wrote
Generated/ and the browser's copy (`3 files written`), the deployable builds being
`rocx build . --release dist` and `rocx build . --image app.tar`. `rocx --help` was the same line.
Each command spoke in a style of its own (`rocx: …`, `rocx dev: built . in 0.24 s`, prose), and
`rocx dev`'s address was in a log line.

**Decision.**

- **`rocx build [dir]`** (here by default) is the release, into `dist/`; `--image` the container
  image, `<name>.tar` (the app's directory's name); `--static` the static copy, into `dist/`;
  `--out PATH` says where for each. The words before still read as they did (`BuildArgs`):
  `--release <out>`, `--image <file.tar>`, `<dir> --static <out>`; and `--client`, `--dev` or more
  than one directory is code generation.
- **`rocx generate [dir]… [--client <out>] [--dev]`** is what `rocx build <dir>…` was: Generated/
  and the browser's copy, nothing compiled; for editors and scripts. The repository's callers moved
  (packages/testing's `buildForTests`, the tests, the docs site's scripts, the examples' READMEs and
  bench, the Android build, check-times).
- **`rocx new [dir]`** asks for the name at a terminal when it isn't given (off one, it says to give
  it), and asks for the database with a short menu.
- **Help**: `rocx`, `rocx --help` and `rocx help` list the commands by what they're for (Start, Ship,
  Check, More); `rocx help <command>` and `rocx <command> --help` show one's usage and options. A
  command it doesn't know is one line on standard error, pointing at the help (exit 2).
- **The look (`Term`)**: a header (`  rocx build · shop → dist/ · arm64mac`), then a line for each
  step, `◌ what…` while it runs, drawn over by `✓ what  12.4 s` (or `✗`) when done, then what was made
  (sizes) and what to run next (`Run  dist/server --static dist/static`, `docker load -i shop.tar`).
  `rocx dev` opens with its address on a line of its own and the app's database under it, then
  `✓ built in 0.3 s`, `↻ routes/+page.rocx` on a save, and the SQL check as `✓ SQL: …`. `rocx check`
  is a step for each program and a verdict. Notes said in the middle of a step (a compiler's
  warnings) clear its line first (`Term.note!`).
- **Only at a terminal**: colour and drawing in place need standard error to be a terminal, NO_COLOR
  unset and TERM not `dumb` (the CLI platform's `Stderr.is_terminal!`, new). Elsewhere the build
  commands write the same lines as plain text, a step's start a line of its own; `rocx dev` and
  `rocx check` write exactly what they did, as the VS Code extension reads those lines
  (`rocx dev: … changed`, `rocx dev: built …`, the compiler's reports on standard output).

**Tests.** BuildArgs', Term's, Help's and the dev banner's expects; test/new, install, image and
static read the new lines; the callers above run `rocx generate`.

**Not chosen yet.** A spinner that turns while a step runs (the CLI platform runs a command to its
end; the `◌` line stays still). The server's own log under `rocx dev` (each plugin's line on each
restart) is the platform's, unchanged.

**Reversible:** yes: `rocx build <dir>` back to code generation, and Term's lines back to the old
ones.

## D-108 rocx's rules for coding agents: a block in the app's AGENTS.md, a guide in each version

**Status.** Built (2026-11-27), the user's call: "injecting our own stuff into AGENTS.md in a way
that allows us to update them easily over time".

**Context.** Agents write much of an app's code, and an app teaches them nothing about rocx: they
pair a page with an endpoint in one folder, name middleware in a route file, answer a file as
`Err(Answer(…))`, key a view on its whole answer so every live refresh remounts it (a video
reloads, focus is lost), or edit `Generated/`. What rocx would tell them changes with each
version, and an app's AGENTS.md is the app's own file, with its own notes.

**Options.**
1. A line in AGENTS.md pointing at a guide in `.rocx/`: always the app's version, but an agent that
   doesn't follow the link reads none of it.
2. The whole guide copied into AGENTS.md: every session reads all of it, and every upgrade is a long
   diff in a file the app owns.
3. A Claude Code skill: one agent's.
4. A short block of the rules that matter most, between markers rocx owns, pointing at the full
   guide in `.rocx/`; a command that rewrites the block and nothing else.

**Decision.** 4.

- **`agents/block.md`** is the block's text (about 35 lines: what the app is, where the guide is,
  the rules that matter most). **`agents/guide.md`** is the guide: an app's layout, the commands,
  routes, endpoints, middleware, components, data, forms, navigation, the database, settings,
  plugins, deploying, and the mistakes to avoid, each pointing into the references. An app reaches
  it as `.rocx/agents/guide.md`, the guide for the version it builds with, so it needs no update
  step. A release packs `agents/`, and now `server/README.md` and `web/README.md`, which the guide
  points into (release/test-install.sh checks they are there).
- **`rocx agents [dir] [--force]`** (`Agents.roc`) writes the block into AGENTS.md between
  `<!-- rocx:start <fingerprint> · … -->` and `<!-- rocx:end -->`: it makes AGENTS.md (a heading,
  then the block) where there is none, adds the block at the end of one without it, replaces a block
  of another rocx, and does nothing to a current one. Nothing outside the markers is touched. It
  writes a CLAUDE.md of one line, `@AGENTS.md`, where there is none, for Claude Code; a CLAUDE.md of
  the app's own that doesn't name AGENTS.md gets a hint, never a change.
- **The fingerprint** is the first 16 hex digits of the block text's SHA-256 (line endings as
  `\n`). Read against the text between the markers, it says whether someone edited the block;
  against this rocx's text, whether the block is current. An edited block, or a start marker with no
  end, is refused (exit 1, saying what to do) unless `--force`. A clone has no version number, so
  the marker holds the text's fingerprint, not a version.
- **`rocx check`** says when the block is another rocx's or was edited (`! AGENTS.md's rocx block
  is from another version of rocx: rocx agents rewrites it`), and never counts it against the check.
  An app with no block hears nothing.
- **`rocx new`** writes both files; the template's README lists them, and says to run `rocx agents`
  after `rocx upgrade`. Nothing writes AGENTS.md but these two commands: no build does.

**Tests.** `Agents.roc`'s expects (a new file, the block added, replaced with the notes around it
kept, unchanged, edited, unclosed, line endings); test/agents.test.mjs runs the command on files
(new, the app's own AGENTS.md and CLAUDE.md, a stale block, an edited one with and without
`--force`, an unclosed one); test/new.test.mjs checks a new app's AGENTS.md and CLAUDE.md, that its
checks say nothing of them, and that `rocx check` says so of a stale block and still passes.

**Why.** The rules an agent most needs are in the file it reads first; the rest is one link away
and always the app's version; and an upgrade's change to them is one command and a short diff.

**Costs.** A file rocx writes into the app's repository, under rocx's markers; an app that wants
none doesn't run the command (or deletes the block: nothing writes it back). The guide is prose to
keep true as rocx changes: a decision that changes a rule changes the block or the guide too.

**Reversible:** yes: the command, the check's line and `rocx new`'s call go; an app's block stays
as plain text.

## D-109 A memo computed again to the same value tells no one

**Status.** Built (2026-11-27).

**Context.** `create_memo!` told its readers each time it ran (`Host.memo_done!(…, Bool.False)`),
whatever it computed. Solid's `createMemo` compares (`===`, by default) and stays quiet when the
value is the same. Found in an app whose page reads its data again on each piece of news: a memo
of a part that hadn't changed (a week number, the page's title) still ran every reader, and a pure
view given it (D-039: a pure view's props are values, its call made anew when one changes) was made
anew with its element: an icon, a link, an image reloaded. Store selections already compared
(D-053: `Host.memo_last!`, then `memo_done!`'s `same`), by Roc's `==`.

**Options.**
1. As it was: a memo always tells; what wants quiet reads a store's selection.
2. An option per memo, Solid's `{ equals }`, or a second function that compares.
3. `create_memo!` compares, by `==`, as a selection does; its value must compare (`a.is_eq`).

**Decision.** 3. `create_memo!` asks the runtime for the memo's last value (`memo_last!`) and says
whether the new one equals it (`memo_done!`'s `same`); an equal one tells no one. Its type says
`where [a.is_eq : a, a -> Bool]`, and so does `create_optimistic!`'s, which holds a memo. A memo's
first value has no readers to tell.

- **What needs `is_eq`:** a memo of a type of one's own. The repository had two, packages/charts'
  `Scale` and `Band` (the charts' scales, in memos), which compare their fields now. A memo of
  what can't compare (a function, markup) is a function instead: `doubled! = || count!() * 2`
  computes when read.
- **Docs:** the platform's README, `Solid.create_memo!`'s comment, the components page.
- **Tested:** web/test's `Untracked` holds a memo computed again to the same value as its count
  changes, and a pure view given it: the view's element is the same after a click.

**Why.** Solid's semantics, and the platform's own store selections': a value that didn't change
moves nothing. Readers of a memo of a part of a page's data run only when that part changed.

**Costs.** A comparison each time a memo runs (`==` of its value: a list's is linear in its
length). A memo of a type of one's own needs its `is_eq`, or the memo is a function.

**Reversible:** yes: `memo_done!(…, Bool.False)` again, and the constraint goes.

**Fixed with it** (not a decision): a comment line before a hole's `match` arm (D-070) was read as
part of the arm's pattern, which made the pattern more than a line, and the match a plain hole,
every arm made anew each time its value changed, with no warning. `Flow.skip_comments` passes over
whole comment lines where a pattern starts; their lines are kept, so reports point where they did.
test/transpile.test.mjs checks a match with comments before its first arm and between arms.


## D-111 A dev server says where to go, a log line easier to read, and the build level a flag

**Status.** Built (2026-11-27), the user's calls: links at the start in dev, one line for the
plugins, a flag for how hard the compiler works with a quicker default in dev, and a log line
that reads better.

**Context.** A dev server's start was a column of the host's and the platform's lines: a line a
plugin saying what it added (`rocx plugins: added adds="1 early route, 1 migration, 1 call, 6
loops, 1 start" plugin=jobs`), the address among them, and nothing about the places a person opens
while working: the stories, the dev mailbox, the sign-in page, the OpenAPI page, an app's own (an
MCP endpoint). Every pretty line was `14:03:12 INFO  message key=value…` in one colour but the
level's. And an app that built its own way had the browser's wasm at `--opt=size`, a minute of the
compiler's time on each build.

**Decision.**

- **Links.** A plugin says the places it adds that a person may want to open (`Plugin.Link`:
  `{ label, path }`, a path of the app's or a whole URL): the email plugin its mailbox, the auth
  plugin the app's sign-in page, the jobs page its page. The generated `App.program` takes the
  app's own (`links`) and adds, first in the plugins' list, a plugin of the app's (`app`) adding
  nothing but links: its stories (a dev build's), its OpenAPI document or page as it serves them,
  then its own. Under `--dev` the platform hands them to the host as it starts
  (`Host.dev_links!`, new: a line a link, its label, a tab, its path), and the host lists them
  under its address: pretty, a line each, `➜ label  URL`, the labels lined up under the message
  (`logging::listing`); JSON, one event, `rocx server: links`, a link a field. None outside
  `--dev`.
- **Plugins.** One line at info names them in their order (`rocx plugins: jobs, email, auth`); a
  plugin that adds nothing but links isn't named. What each added is at debug, and only under
  `--debug` (the log has no level filter: a debug line is written), so `--dev` shows the one line.
- **The pretty line.** `14:03:12 info  gate failed  error="no session" path=/admin`: the level in
  lower case, the fields two spaces after the message. At a terminal the time and the fields'
  names are dimmed and the level coloured (debug grey, info cyan, warn yellow, error a bold red),
  so what is read, the message and the values, stands out. JSON is as it was.
- **The build level.** `rocx dev --opt dev|size|speed` builds both programs at that level (`dev`,
  as before, by default: seconds); `rocx build --opt …` (the release, and `--image`) builds both at
  it, where by default the server is built for speed and the browser's wasm for size.

**Why.** The start says where things are, once; the platform's own wiring is a debug detail; the
level is the reader's eye's first stop, the message its second. A build level is a choice to make
when trying what ships, not a constant.

**Costs.** A host function more (`Host.dev_links!`, the glue regenerated). A tool that read the
pretty line by its upper-case level reads lower case now. The app's own plugin is a plugin named
`app`, which an app's plugin can't be named.

**Reversible:** yes: the links field and the host's listing go, the level back upper case, the
plugin lines back at info.

## D-112 Hydrating passes over an extension's elements; a mismatch names its node

**Status.** Built (2026-11-27).

**Context.** A hosted app (signed in) warned on every first load: `the page isn't what the app
renders (<body> has more than the server's markup says); rendering <body> again`. The server and
the browser agreed: headless Chromium and Gecko hydrated the page cleanly, the visitor's
extensions too, signed out. The cause was a password manager's (Proton Pass's) content script: on
a page with fields it adds its own element to `<body>` (`<protonpass-root-…>`), and adds it again
if it is taken out. It runs at `document_end`, so it is there before the runtime, which waits for
the wasm, hydrates. Hydrating took any node it didn't render for a mismatch, and rendering
`<body>` again took the extension's element out, with everything the server rendered. Grammar
checkers and dark themes do the same in `<body>` and `<head>`. The warning didn't say which node:
by the time devtools opened, rendering again had removed it. And rendering `<body>` in the browser
showed a second bug: a computed `class={…}` beside `class:name={…}` lost its value when the
runtime built the element (`styled` wrote the static class and the `class:name`s only), so a board
whose dots are placed by their class drew them in a heap. The servers wrote such an element two
`class` attributes (the `class:name`s', then the computed one), the parser keeping the first. A
computed `style` from Html's functions (`Html.attr_of("style", …)`; a `.rocx` file's `style` is
static) beside `style:name`s had the same two faults.

**Options.**
1. As it was: an extension's node is a mismatch, and `<body>` rendered again.
2. Pass over what the app doesn't render anywhere.
3. Pass over elements straight in `<html>`, `<head>` or `<body>`, where extensions put theirs (React
   19 does the same; Solid's hydration never visits a node it didn't render), and keep them when
   `<body>` is rendered again; inside the app's own elements a mismatch stays a mismatch. Not when
   hydrating strictly.

**Decision.** 3.

- **Passed over:** an element hydrating doesn't expect, straight in the document's `<html>`,
  `<head>` or `<body>`, when what the app renders comes after it (`Cursor.passForeign`), or is
  all that is left (`Cursor.left`). It stays where it is.
- **Kept:** rendering `<body>` again (after a mismatch, or a navigation that renders it) keeps the
  host's elements, the elements hydrating passed over, and any element after the host's last (the
  bootstrap script, the last the server writes), which only a script puts there.
- **Strictly** (`{ strict: true }`: the tests'), nothing is passed over, so an app's tests still
  see a page that isn't what the server sent. A browser can ask for it too:
  `localStorage.setItem("rocx:strict", "1")`, read by start.js, to look into a page in one's own
  browser, where it throws with a stack instead of rendering again.
- **Named:** a mismatch says what it found and where (`expected <circle>, found <rect> in body >
  svg.dot`; `<body> has more than the server's markup says: <protonpass-root-1f2e> in body`). The
  warning gives the console the node itself, and the document gets `rocx:mismatch`
  (`{ message, node }`) for an app's error reporting. packages/posthog's page script sends it
  (`HydrationMismatch`). A text node is named `text`, not quoted: what a page says is its visitor's.
- **One `class`, one `style`:** an element's own `class` (static, optional or computed) and its
  `class:name`s are one attribute in the markup's order, in every writer (signals.rs, the
  runtime's `renderToString`, `Html.to_str`) and in the runtime as it builds and patches
  (`wholeClass`: a computed class's new value keeps the `class:name`s that are on, and a
  `class:name` keeps the computed value). The same for `style` and `style:name`s
  (`wholeStyle`). The phone's engine (native/core) keeps the `class:name`s too.

- **Docs:** the platform's README (hydrating a document; attributes), the docs' browser page, the
  syntax page, packages/posthog's README, start.js's and the runtime's comments.
- **Tested:** web/test's document tests: an extension's elements in `<body>` (before the app's,
  after the host's) and in `<head>` hydrate with nothing patched and stay; a mismatch inside an
  `<svg>` renders `<body>` again with the warning, the node and `rocx:mismatch`, the extension's
  elements kept; strictly, each throws, naming the node; an unmarked script in `<body>` is
  passed over, and strictly is a mismatch. Props: a computed class beside a
  `class:name`, and a style beside a `style:name`, hydrated and made in the browser, patched both
  ways. test/e2e: the native server writes one `class` and one `style` for them, the browser
  patches nothing as it hydrates, and a click changes them. native/core: `whole_class`. packages/posthog: the script
  sends `rocx:mismatch`.

**Why.** Extensions are part of the browser a page meets; a page shouldn't be built again, losing
the server's nodes and the extension's, because one added a node beside the app. A mismatch that
remains should be found where it happens: named, inspectable, and reported from visitors'
browsers.

**Costs.** A real difference straight in `<body>` (the server rendering an element the browser's
app doesn't, before the ones it does) is passed over in visitors' browsers, the server's element
left unbound; strict hydration in an app's tests catches it. An extension's element inside the
app's own elements is still a mismatch.

**Reversible:** yes: `foreignKept = false` makes every hydration exact again.

## D-113 A pretty line's fields: a request's first, durations in their unit

**Status.** Built (2026-11-27), the user's call, reading an app's request lines: "path, then
method, then status, then duration … `duration=3ms` or `duration=50ns` … and we can drop naked
`request`".

**Context.** A pretty line's fields came in their names' order: a record is encoded field by
field in that order, and the host's JSON map sorts them too. A request's line read
`request  body=text duration_ms=0 method=GET path=/x status=308`: what was asked last, and a
duration in whole milliseconds, nearly always 0.

**Decision.** In the pretty format only (JSON is as it was):

- `path`, `method` and `status` come first, in that order; then the durations; then the rest, in
  their order.
- A duration is a number whose name ends in `_ns`, `_us` or `_ms`: shown without the suffix, in
  the unit that reads best: below 2 µs in nanoseconds, below 2 ms in microseconds, below 2 s in
  milliseconds, whole; then seconds, to a tenth (`duration_ns=12345` is `duration=12µs`,
  `again_in_ms=60000` is `again_in=60.0s`).
- An event with no message is its fields alone, with no gap: `info  path=/posts method=GET
  status=200 duration=12µs`. An app's request line may be just that.

**Why.** The line is read left to right, and these are what a person looks for first; a
duration's number means nothing without its unit, and a unit in the name is for machines.

**Costs.** The formatter knows four names (`path`, `method`, `status`, and the units' suffixes);
an app that means something else by `path` gets it first anyway. A field named `<x>_ms` that is
no duration is shown as one.

**Reversible:** yes: `arranged` goes, and the fields come in their order again.

## D-114 A plugin's routes and the OpenAPI document are behind the middleware main.roc gives them

**Status.** Superseded by D-116 the same day: a plugin has no routes, and the OpenAPI document is a
route of the app's, so neither needs a middleware of its own. Built (2026-11-27), the user's call, after the private app's own gate sent
`/openapi.html` and `/admin/jobs` to its sign-in page, and its sign-in page under `--dev` offered
Google alone.

**Context.** D-103 put `routes/+middleware.roc` around every request the app answers, its plugins'
routes and the OpenAPI document included; the folders' middleware reached the app's route files
alone. A plugin isn't in the file tree, so the one middleware that reached it was the app's root,
the place an app is most likely to put a sign-in gate. An app with such a gate had to list the
plugins' public paths by hand again (`/auth/google`, `/auth/google/callback`), which D-103 was meant
to end, and the OpenAPI page and the jobs page were sent to sign in with no way for the app to say
otherwise. Each package did the rest its own way: `at` on most, a `guard` on the jobs page alone
(which ran inside the root anyway), `owner : ctx -> Str` on push.

**Decision.**

- **No `+middleware.roc` is around a plugin's routes or the OpenAPI document**, not even
  `routes/`'s. `Generated/App` answers a request with: the platform's cross-site check (as
  before), then a plugin's route, then the OpenAPI document, then the app's middleware
  (`routes/+middleware.roc`) around the app's routes and the error page. A path nothing answers
  still goes through the app's middleware.
- **A plugin with routes takes `middleware : Middleware(context, ctx)`, with no default**, and puts
  its routes behind it (`Plugin.behind`): auth, push, posthog, stripe, storage and the jobs page
  (whose `guard` it replaces). Its routes read what it hands on (`Push.plugin({ middleware,
  owner: |ctx| … })`). `Plugin.Value(context, ctx)` is `Plugin.Value(context)`: a route is given
  the app's context, before the middleware the plugin was given.
- **`openapi` names its middleware too**: `Document(middleware)`, `Page(Swagger, middleware)`,
  `Page(Scalar, middleware)`. `OpenApi.Shown` is what is served without it, for `OpenApi.respond`.
- **`Middleware.none({})`** is the middleware that hands every request on as it came: what a plugin
  anyone may reach is given (Stripe's webhook, signed storage links).
- **What runs around everything is passed by name.** An app that wants its request log or its
  headers on a plugin's routes gives that plugin its root's middleware (`Middlewares.default`), or a
  folder's chain written out (`Middlewares.default.then(Middlewares.admin)`); rocx writes no module
  of chains. Each package's `at` (`webhook_at` for Stripe) moves its routes when two would meet.

**Why.** What guards a plugin is written where the plugin is listed, so a gate in the root can't
reach something it wasn't meant for, and a page that should be private can't be public because an
option was left out. The user chose: a path nothing answers stays behind the root; the OpenAPI
document requires its middleware; and what runs around every request is passed explicitly.
Defaults were meant for the plugins anyone may reach, but a field default may not tie `ctx` to
`context` (the compiler refuses it: "default constrains a type parameter"), so every plugin with
routes requires it.

**Costs.** An app with `cross_site: Allowed` that checks forms in its own root loses that check
on a plugin's routes it gives `Middleware.none({})`: it splits its root and passes the ungated part
(the private app did: its auth plugin is behind its log, one-origin redirect and form check).
Every app lists a `middleware` for each plugin with routes, `Middleware.none({})` where
none is wanted. A root middleware that logs or adds headers no longer reaches a plugin's routes
unless the app passes it; an app whose root mixes headers and a gate must split them to pass one
without the other. The examples pass their `Middlewares.default`, which only adds headers, logs or
identifies, so they behave as before.

**Reversible:** yes: `Generated/App` puts the root around `Plugin.respond!` again, and the
plugins drop the option.

## D-116 A plugin adds no routes: a package offers handlers, and every URL is a route file

**Status.** Built (2026-11-27), the user's call, the same day as D-114, which it replaces in part.

**Context.** D-114 put a plugin's routes and the OpenAPI document outside `routes/+middleware.roc`,
each behind a middleware main.roc gave it. It answered the private app's problem, but plugins still
had a way of their own to put something at a URL, which no file showed, `rocx routes` didn't list,
and folders' middleware didn't reach: so every package with routes needed an `at` and a
`middleware` option, the app wrote a folder's chain by hand to pass one, and the auth plugin's
`admit!`, push's `owner` and Stripe's `on_event!` were options of a plugin for what are a route's
concerns. The user's view: plugins aren't part of the file structure, so they behave unexpectedly;
all routes reflected in the folders is worth a change in every consumer.

**Decision.**

- **`Plugin.Value` has no `routes`.** A plugin adds tables, jobs and calls, loops, starts, checks,
  files and scripts, dev pages (`early`, under `/__rocx/`) and places to list; never a route.
  `Plugin.behind`, `Plugin.respond!`, `Plugin.pattern` and `Plugin.Route` are gone, and so are the
  start's checks of a plugin's routes against the app's (its files and early paths are still
  checked).
- **A package that answers requests offers handlers**, a route file's `respond!` calls, each
  checking its methods (405 otherwise): `Auth.provider_route!`, `callback_route!`, `link_route!`,
  `code_route!`, `sign_out_route!`, `dev_route!` (packages/auth); `Push.key_route!`,
  `subscribe_route!`, `unsubscribe_route!`; `PostHog.errors_route!`, `script_route`;
  `Stripe.webhook_route!`; `Storage.signed_route!` (at `/_storage`, where its signed links point;
  it was `/__storage`, which a route file can't be); `JobsPage.respond!` (`JobsPage.plugin` is
  gone). What a route concerns is the handler's argument: `admit!`, the subscription's owner (what
  the folder's middleware handed on), `on_event!`, the provider list (the app's, in a module both the
  plugin's options and the route import: `Accounts.providers`).
- **The OpenAPI document is a route of the app's**: `routes/openapi.json/+server.roc` calls
  `OpenApi.document_route(request, Api.openapi)`, `routes/openapi.html/+server.roc`
  `OpenApi.page_route(request, Scalar)`. `App.program` loses `openapi`; the server lists the page
  under `--dev` when a route answers `/openapi.html` (or the document, `/openapi.json`).
- **Every URL is a route file**, so `routes/+middleware.roc` is around every request the app
  answers again (D-103 as it was), and the folders' middleware around the package's handlers as
  around any route. `Middleware.none` goes with the options that needed it.
- **The dev sign-in stays** (`dev_route!`): an app's way to try it and its tests' way in, with no
  mail and no provider. Starting a reachable server with `--dev` is the operator's to avoid.

**Why.** One way to put something at a URL: the file. `rocx routes` lists a package's endpoints
with the middleware around them, a folder guards them as it guards the app's own, and the app picks
their paths by where it puts the files, so no package needs `at` or `middleware`. A handler's
change is a compile error at the route file's line that calls it.

**Costs.** An app writes a small file for each step it uses (six for every auth step, none for an
app that signs people in itself), where it listed a plugin; `rocx new`'s template ships its own.
Storage's links still go to one fixed path. Every consumer of a package with routes changed once.

**Reversible:** yes: `routes` comes back to `Plugin.Value`, and the handlers become a plugin's
routes again.

## D-117 A submission's redirect reads again what the navigation keeps

**Status.** Built (2026-11-27), the user's call: things should work on the plain path. Changed by
D-119: what the new page's document answered is read from it, the rest from the server.

**Context.** A form the runtime sends (D-095) or an action whose answer is a redirect
(`x-rocx-redirect`, or one `fetch` followed) goes there in place (D-040), keeping the levels the two
pages share (§4.3: the root layout, every time). A result (200) reads the page's reads again
(`revalidate`, as SolidStart does after any action); a redirect only emptied the page cache, so a
kept layout showed what it read before the form. Moving the private app's dev sign-in to a route
of its own (D-116) showed it: written as a `post!`, its form went with `fetch`, the redirect home
kept the root layout, and the header still said nobody was signed in. The same holds for any form
that changes what a layout shows (an org made or switched, a count of requests waiting).

**Decision.** Once a submission's redirect is followed in place, the computations it kept read
again what they read: every read, or the answer's `Router.revalidate!` keys (`x-rocx-revalidate`,
which a redirect's answer carries as a result's does). What the navigation makes anew reads from
the server anyway, so it isn't asked twice. Not when the visitor went to another page meanwhile
(the redirect isn't followed then).

**Why.** Solid Router revalidates every query after an action, a redirect's too, and SvelteKit's
`use:enhance` runs `invalidateAll` and `goto` with it for a redirect: the plain way works there, and
a sign-in written as a `post!` behaves as one written as a `respond!` (which the browser posts).

**Costs.** A kept layout's reads go again after such a redirect: one round of them, which a handler
narrows with `Router.revalidate!`.

**Reversible:** yes.

## D-118 A form nothing on the page reads is answered as a plain form, in place

**Status.** Built (2026-11-27), the user's call: things should work on the plain path, as in Solid
and SvelteKit. Changed by D-119: brought back to the page it is on, the page is kept, not made anew.

**Context.** D-095 sends every form that posts to one of the app's endpoints with `fetch`, for the
endpoint's result or refusal, and said a refusal nothing reads "shows nothing on the page, as it
showed nothing after a plain post". But a plain post goes back to its page with a flash, which the
page reads (`Server.flash!`, `use_submission!` before the runtime sends one, an app's own notice):
the private app's organization page shows "nobody@… doesn't have access yet" that way. With the
runtime, the same form's refusal went to the console alone, the page didn't move, and its test
timed out. A result nothing read was read again on the page, but what the flash would have shown
(a "saved" notice) didn't show either. SvelteKit answers a form it doesn't enhance as the browser's
post, and Solid takes over only forms bound to an action.

**Decision.**

- **The runtime asks how a form is read.** One a component reads (`use_submission!`,
  `use_submissions!`, `use_action!` of its endpoint) goes as before (`x-rocx-submission: 1`, JSON),
  for that component. One nothing reads goes as the browser would post it (`accept: text/html`, no
  `x-rocx-submission`), with `x-rocx-in-place: 1`.
- **The server answers it as a plain form**: `Endpoint.posted_by` says `PlainForm`, so its result
  or refusal is flashed back to the page it came from, and its handler's own redirect is as it is;
  an app's own plain-form code (a middleware that flashes back) sees a plain form too.
- **`Endpoint.for_runtime`**, which the platform answers every request through, gives the runtime
  any redirect answering it (`x-rocx-submission` or `x-rocx-in-place`) as 200 with
  `x-rocx-redirect`, its cookies kept, whoever made it: a handler, a middleware, a flash back.
- **The runtime follows it in place**: the page it goes to, the same page again included, is made
  anew from its document (with the flash), the layouts it keeps reading again what they read
  (D-117), and the submission done once there (it stayed pending for ever before: the runtime never
  ended a submission answered with a redirect).
- A page made anew from its document took that document's `<NoHydration>` regions as it was made;
  the check of a kept root's regions against the document's no longer runs then (it warned of
  regions it had already taken).

**Why.** The page shows what it would show without JavaScript, whatever the endpoint and whatever
reads it, and only the page changes: no load. A component that wants the answer itself says so by
reading the submission, as Solid binds a form to an action.

**Costs.** A form nothing reads now asks for its page's document after it is answered (one request
more than a result's revalidation), and its page is made anew: its signals start again, as after a
plain post.

**Reversible:** yes: every form goes as the runtime's again.

## D-119 What a navigation keeps follows its document; a form's answer keeps the page it comes back to

**Status.** Built (2026-11-27), from the private app's tests on D-117 and D-118 (130 of 134 then;
134 of 134 now).

**Context.** D-117 read a kept layout's reads again from the server after a submission's redirect,
though the document the navigation had just fetched carried an answer for every one of them (the
server renders the layouts with the page): a request more, and the private app's tests, which hold
that a page brings every answer it reads, saw `/api/viewer` asked. D-118 followed a plain form's
flash back to the page it came from by making that page anew from its document: a page's own
signals (the board's picked post) started again, as after a plain post. An audit against Solid
and SvelteKit had the same point: a kept level's answers in the document were thrown away.

**Decision.**

- **After every navigation, what it kept follows its document** (`refreshKept`): a kept
  computation whose reads of the server the document answered, one of them now differently, runs
  again, reading them from the document's answers: no request. What reads the flash (`js_flash`)
  runs again when the document brings another.
- **After a submission's redirect** (D-117), what the document didn't carry is read from the
  server: every read, or the answer's `Router.revalidate!` keys.
- **An answer that brings back the page it is on keeps it** (D-118's flash back, a handler's
  redirect to its own page): the root and the page aren't made anew, the scroll and the focus stay,
  nothing is announced; its reads and the flash follow the document. A link to the page it is on
  still makes it anew, as a load would (D-040).

**Why.** The document is the server's word on every level of the page, fetched anyway: reading the
kept levels from it is free and current. SvelteKit keeps a page's state across `use:enhance`'s
refresh; Solid keeps it across revalidation.

**Costs.** A kept computation whose answer changed runs again on a navigation that isn't a
submission's too: what it shows follows the server, as it would after a load.

**Reversible:** yes.

## D-120 A `<NoHydration>` that read the server's data follows a form's result

**Status.** Built (2026-11-27), from an audit against Solid and SvelteKit, on the user's go.

**Context.** A form's result reads the page's reads again (`revalidate`), but what is inside a
`<NoHydration>` the browser has no copy of: a region that read an endpoint as the server rendered it
(a listing beside the form, the journal's masthead) stayed as it was until the page loaded again.
SvelteKit's `use:enhance` refreshes everything after an action; Solid re-renders what read the data.

**Decision.** The server marks a region whose markup read an endpoint: `<!--nohydration:read-->`
(signals.rs counts the GETs a region makes). After a form's result, a page with such a region asks
for its document and takes the regions from it (`refreshRegionsFromServer`). A page whose regions
read nothing (prose) asks for nothing. The browser build, rendering against a page, keeps a
region's mark (`regionsOf` gives `{ read, html }` for one).

**Why.** Correct where it matters, free where it doesn't: most regions are static.

**Costs.** One document more after a result, on a page with a region that read data.

**Reversible:** yes.

## D-121 A form nothing reads that fails shows it where the form is

**Status.** Built (2026-11-27), from the audit, on the user's go.

**Context.** Since D-118, a form nothing on the page reads is answered as a plain form; one whose
answer isn't where to go (a crash's 500, a middleware's refusal, no answer at all) left the page as
it was, the console alone saying so. Without the runtime, the browser shows that answer as a page;
SvelteKit's `use:enhance` shows the nearest error page.

**Decision.** The runtime shows it in the nearest `<Errored>` around the form: its fallback, given
`POST /notes: 500: …` and a retry (the app's error page, around the page, at the least). With no
`<Errored>` around it, the console says so.

**Why.** A failure isn't silent, and it shows where the app shows failures.

**Reversible:** yes.

## D-122 A form that succeeded starts empty again

**Status.** Built (2026-11-27), from the audit, on the user's go.

**Context.** A form the runtime sent kept what was typed after it succeeded, and `field!` gave the
sent value whatever the answer, so `value={submission.field!("name")}` filled an add form again
after its add: an invitation to add twice. The page a plain post comes back to has the form empty;
SvelteKit's `use:enhance` resets a form after its success.

**Decision.** A form the runtime sent is reset once it succeeded (a result, or a redirect that isn't
a refusal coming back in a plain form's flash), unless it, or what is around it, says
`data-rocx-keep`. `Submission.field!` is "" after a result; it gives what was typed after a refusal,
to put it back. `input!` still says what was sent.

**Why.** The form after a success is the form before one, with JavaScript or without it.

**Reversible:** yes.

## D-123 Behind HTTPS, every cookie is `Secure`

**Status.** Built (2026-11-27), from the audit, on the user's go.

**Context.** `Server.cookie_defaults` isn't `Secure` (D-007, for development over HTTP), and only
packages/auth set it per request: an app's own `Server.with_cookie` went over plain HTTP too in
production. SvelteKit's cookies are `secure` but on `http://localhost`.

**Decision.** When the app's public URL is HTTPS (`--public-url`, `PUBLIC_URL`), the server platform
makes every cookie an answer sets `Secure` as it sends it (`Server.secure_cookies`); one that says so
already is as it is. The default stays as it was, for development over HTTP.

**Why.** Safe in production with nothing to remember, and `http://localhost` works as it is.

**Reversible:** yes.

## D-124 `data-rocx-reload` leaves a link or a form to the browser

**Status.** Built (2026-11-27), from the audit, on the user's go.

**Context.** A link or a form that should load the page whole (a sign-out that must drop every
state, a form to a page of another build) had no way to say so but `<html data-rocx-navigation>`,
for every link of the app. SvelteKit has `data-sveltekit-reload` on an element and what is inside it.

**Decision.** `data-rocx-reload` on a link, a form, a form's button, or an element around them,
leaves that one to the browser: a load, or a plain post. `data-rocx-reload="off"` takes it back for
what is inside.

**Reversible:** yes.

## D-125 `enhanced:src`: smaller copies of a photo, made by the server as pages show it

**Status.** Built (2026-11-27), on the user's go (their design: one attribute, made on a request,
never in the page's way).

**Context.** A photo written as `<img src="/harbour.jpg">` is sent whole to every screen: a phone
downloads the 2400-pixel original to show it 400 pixels wide, and the page has no room kept for it
until it comes. SvelteKit's `enhanced:img`, Astro's `<Image>` and Next.js's `next/image` make the
copies and write the `srcset`; each has a step of its own (a build, a service that resizes on
request). An app here has a server, and pages are rendered by it.

**Decision.** `<img enhanced:src={…}>` (a quoted path too) is the one way: a plain `src` is never
touched.

- **rocx** writes it as the `src`, a mark (`Html.enhanced`, `["e"]`), and `loading="lazy"`,
  `decoding="async"` unless the markup says how it loads (`loading`, `fetchpriority`) or decodes.
  `src` or `srcset` beside it is refused; only an `<img>` has one.
- **The server**, writing the page (signals.rs, beside D-086's `aria-current`), asks whether the
  photo's copies are made (server/host/src/images.rs). If they are, it writes their `srcset`, a
  `sizes` (`100vw`, at most the written `width` in pixels: `(max-width: 1200px) 100vw, 1200px`)
  and the photo's `width` and `height` (or the one not written, in its shape), unless written. If not, the page has the `src` alone, and the
  photo is queued: the next page that shows it has its copies. A page never waits.
- **The copies** are WebP (libwebp's lossy encoder, quality 80) at 160, 320, 640, 960, 1280 and
  1920 pixels wide under the photo's own width, and its own up to 1920; turned upright by its EXIF
  orientation, its metadata (a location) left out. JPEG, PNG and WebP are read; anything else, more
  than 64 megapixels or 64 MiB, keeps its `src`, remembered until the source changes; an SVG (by its
  extension) isn't tried, as it is drawn at any size. Two workers
  (threads of their own) make them, one photo each at a time; a photo a hundred pages ask for is
  made once.
- **A source is a path of this site**: a file in a `--static` directory, or else what the app
  answers a signed-out GET of it (the server asks itself, with no cookies). Never another site's
  URL: a value from data would make the server fetch an address of someone's choosing, and a
  private photo would get copies anyone may fetch.
- **Kept** in `data/images` (`--images-dir`), named by the photo's content: `<hash>-<width>.webp`,
  and `<hash>.txt` (its size, the widths) written last, so the directory is its own index, read as
  the server starts. `<path hash>.src` says which photo a source is (a file's length and modified
  time, or a route's), so a server started again has the copies on its first page; a file changed
  since is a photo not known yet, a route's photo is shown while it is asked again (every 5
  minutes, as a page shows it).
- **Served** at `/rocx/images/<hash>-<width>.webp`, `immutable`, as the app's stylesheet is.
- **Pruned**: a `.txt`'s modified time is when a page last named the photo (written once a day at
  most); as the server starts and daily, photos no page named for 30 days go, then the least
  recently used while the directory is over `--images-max-mb` (1024). A photo removed is made again
  the next time a page shows it, its `src` meanwhile.
- **A static build** (`rocx build --static`) starts its server with `--images-wait` (a page waits
  for its photos, since no next request would bring them) and `--images-dir <app>/build/images`
  (kept from one build to the next), and copies the copies its pages name; `--base` reaches every
  URL of a `srcset`.
- **In the browser** the element is its `src`: hydrating keeps what the server wrote (it compares
  elements, not attributes), and another value in the `src` takes away the `srcset`, `sizes`,
  `width` and `height` the markup didn't write, which were the last photo's. A page reached in
  place (D-040) is made by the runtime from its document's answers, so its photos are given what
  the server wrote for them in the document (`enhancedFrom`: the page's of one `src` and the
  document's of that `src` with a `srcset`, one for one, in order; a photo's copies are made for
  every `<img>` showing it, or for none).
- **Releases** have the image code (cargo's `images` feature: image, fast_image_resize, libwebp)
  when the app's markup writes an `enhanced:src` (`rocx build --release`, `--image`); `rocx dev`'s
  and the tests' hosts always have it; `rocx dev` doesn't rebuild for a write in `data/images/`.

**Why.** One rule to learn (the attribute), nothing to wire (no job, no build step, no service), and
nothing a visitor waits for. Made on the server, it works for photos the app keeps as well as for
its own, and the server knows what is public.

**Costs.** The first view of a photo after it is added or changed is the original; the server is
bigger by the image code when an app uses it. A photo whose colours are in another space than sRGB
(a phone's Display P3) is copied as if it were sRGB: slightly paler (TODO.md). An `<img>` whose
`src` the browser changes shows that `src` alone.

**Reversible:** yes.

## D-126 Videos made of components: packages/video, a player, a renderer, and the stories' transport

**Status.** Built (2026-11-27), on the user's ask: a Remotion-like way to make videos of an app's
real components, so a video changes when they do; both motion pieces (written from the frame) and
demos of the real screens; MP4 and WebM; live motion embedded in a page too; and the catalog making
it easy to compare videos side by side, playing at once. Whether to render on the server with an
app's data is open.

**Context.** Remotion makes videos of React components: `useCurrentFrame()`, `<Sequence>`,
`interpolate` and `spring`, a `<Player>` for a page, and a renderer that films each frame in a
headless Chrome and encodes it with ffmpeg. It forbids CSS animations, since its renderer can't seek
them. The stories (`<story>`, the dev build's catalog) already render a component in isolation, in
the app's layout, at a URL of its own, only in a dev build: what a composition needs, but for time.

**Decision.** A package, not the platform (the app-layer-first rule): nothing in it needs the host.

- `video.Timeline`, plain Roc: `progress`, `ease` (`Linear`, `In`, `Out`, `InOut`, `Back`),
  `eased`, `mix`, `tween`, `keys`/`keys_with`, `spring`/`spring_with` (the analytic damped spring,
  Remotion's defaults), `since`, `typed`, `round`. The same answer for the same frame.
- `<Player>` (a component the build copies into the app, as the charts are): the frame a signal,
  provided as a context (`Player.clock!` gives `{ frame!, fps, frames }`); the server renders the
  poster frame and the browser hydrates the same; live, `on:frame.ms` adds up the time and plays
  from 0 (autoplay, loop, a corner button by default: WCAG 2.2.2). Its scrubber
  (`input.video-seek`, hidden unless `controls={Bar}`) is how anything drives it from outside:
  set a frame and dispatch `input`, and it goes there, paused. Its element says `data-frame`,
  `data-playing`, `data-live`. `fit={Scale}` lays a composition out at the video's size and scales
  it.
- `<Sequence from frames hold>`: a stretch with its own clock; without `hold` what is inside is
  made and goes with it (its transitions play), with `hold` it waits at its first frame and stays at
  its last.
- `render.mjs` (Node, Chromium through the repository's driver, ffmpeg): the page loads and
  hydrates in real time, then `clock.js` (run before the page's scripts) freezes time:
  `performance.now()`, `Date`, timers and animation frames move only by the renderer, and every
  animation (`document.getAnimations()`: the platform's transitions, CSS transitions and
  animations) is held and put where the clock says. Each frame: the clock moves a frame, the player
  is sought, the page settles, the stage is photographed, ffmpeg encodes. So a frame doesn't depend
  on the time it took, and unlike Remotion a component's own CSS transitions and `on:frame`
  animations are in the file.
- The stories: a story with a live player gets a transport in the catalog, one clock for every
  player shown, so a component's stories side by side (or stories compared) play in step; Render
  copies the command (rocx build puts render.mjs's path in the catalog when the app names the
  package). Comparing any stories side by side (a pin per story, `#compare/<ids>`) is new for every
  story, not only videos.

A demo of real screens is a composition that drives them by their props from the frame (a pointer
drawn moving, a box ticked at a frame); a pure component is given a memo, so it is made once per
change and its transitions play. A computed style can't multiply (`safe_css` takes no `*` or `/`):
numbers go in custom properties, the arithmetic in the stylesheet.

**Not built.** Reduced motion (Roc can't read a media query; one host function would do),
starting when it scrolls into view, real input scripted at frames, `rocx render` in the CLI, audio,
and rendering on the server with an app's data (TODO.md).

**Reversible:** yes.

## D-115 The fork on upstream's main: `rocx-fixes-5`, and `rocx --version` names its compiler

**Status.** Built (2026-11-27), the user's calls: keep the fork in step with upstream, on its main
rather than a nightly, before the first release pins the compiler a release carries.

**Context.** The pin was 4674b5973d, seven fixes (each with its failing test) on
nightly-2026-11-18-a520eed; upstream's main had moved 737 commits since (a520eed..bec95b9f4a). Four of the fixes
are upstream's now (the Try codecs, `List.map`'s in-place extraction, the inlined call's clone,
the binding group's claim). The round of fixes of 2026-11-27 (test/compiler-bugs/README.md indexes
them) was first put on the latest nightly (`rocx-fixes-4`, 3943c21646, on 890d6c8); upstream's main
was 93 commits further on, and the fixes go upstream as PRs against main.

**Decision.**

- **The fork's branch `rocx-fixes-5`**, pin 2dd60e319d: upstream's main at bec95b9f4a, then the
  fork's fixes, each a failing test and the fix: the nested codec derivation, `List.map`'s output
  item, and the round of 2026-11-27: the slot-lifetime fix again (upstream's marks only the slots
  passed to a call: the docs site's frames 2.86 MB against 248 KB), the dispatcher's frame, a
  nested site's evidence scope (a component call leaving out a closure-defaulted prop built a wrong
  program without a word under `--specialize=yes`), an effectful closure's default, a nested
  lambda literal's default, a `?` on a rigid row, two formats in one where clause (reported, not a
  crash), an endpoint captured by a closure. Upstream's main still has nine of the thirteen bugs
  the folder keeps. Rebasing the round onto main changed one line: upstream's `runUnify` takes its
  options by pointer. `rocx-fixes-3` and `rocx-fixes-4` (both on the nightly) were steps on the way.
- **PR #13549's regressions, fixed in the fork.** Upstream's main brought polymorphic constants
  (a top-level constant generalizes, each closed instance computed at compile time), and rocx's
  tests met six regressions of it the nightly hadn't: a constant read in a local function over its
  enclosing function's variable (servers built `--opt=dev`: the static build's, auth's, guard's, the
  stories app's); a constant in a recursive group taking on a function's JSON codec requirement (the
  push example); a constant read in a value the platform types, an app's `program` (the testing
  app); and, in a recursive group, a field's kind built as its slot, the constant read in a generic
  function under `--specialize=yes`, and a number literal's type generalized. Each is a two-commit
  branch on upstream's main with a repro and a README in test/compiler-bugs/; upstream's main still
  has them.
- **`roc_commit` is upstream's main** (bec95b9f4a), where `just setup` takes the glue spec from;
  `roc_nightly` stays the nearest nightly (890d6c8), which `just compiler-bugs` compares against
  and a release's notices read Roc's license from. The glue spec didn't change between them.
- **The glue, regenerated** with the new compiler (`just glue`): the hosts' ABI files keep their
  items in a module and their callbacks `unsafe extern "C"`; the CLI host's allocator calls say
  `unsafe`; the server's lists `Host.dev_links!` (D-111) in order.
- **What the compiler asks of the code now**: a closed error union is no longer widened into a
  bigger one by itself (one docs demo annotates its value with the union the function returns);
  a type declared in a module's block isn't another module's to name, which roc-pg 0.5.3's MD5
  did, so the roc-pg example moves to 0.5.4 (its release for the newer compiler).
- **What the fixes let go**: `Endpoint.checked`'s reader crashes naming its endpoint's method and
  URL (a reader capturing the endpoint crashed the old compiler). examples/uptime may write
  `..others` for a transaction's errors now; it keeps its closed union, which says what it means.
- **`rocx --version` names the compiler** on a second line, `roc <its version> (<its path>)`: the one
  rocx runs there (`Hosts.roc!`: an installed version's `bin/roc`, a clone's `.tools/roc-active`,
  else `$ROC`), as its own `roc version` names it; or that there is none. The first line is as it
  was. A report of a bug says which compiler it met.
- **Compilers for every platform at the pin**, published as roc-fork-2dd60e319d and pinned by
  SHA-256: macOS on Apple silicon, Linux arm64 and, the first time, x86_64 (the first release
  covers it).

**Reversible:** yes: the pin back to 4674b5973d and the glue with it.

## D-127 Roles: what a user holds and why, in packages/auth

**Status.** Built (2026-11-27).

**Context.** An app that sells a subscription also gives it away: to its own people, to a friend,
for a trial without a card. packages/stripe says who has paid (`subscribed!`, `paid_for!`), but a
gift isn't a payment, and an app that asked "paid, or given?" everywhere would ask it differently in
each place. packages/auth knew who someone is and nothing of what they may do: who is an admin was
each app's own list (`ADMIN_EMAILS`), checked before `impersonate!`.

**Options.**
1. A package of its own for plans: what a user is on, from payments, trials and grants.
2. Grants in packages/stripe, so `subscribed!` says yes for a gift too.
3. Roles in packages/auth: what a user holds, granted and revoked, with the reason it is held.

**Decision.** 3, as a module of its own, `Roles` (the package's `revoke!` already ends a session).

- **The app's own tags.** A role is one of the app's tags (`[Pro, Admin]`), and so is the reason
  it is held (`via: [Paid, Trial, Gift]`), so a misspelt one is the compiler's to catch. The table
  keeps each as its JSON (`"Pro"`), through Roc's `Json`, as actors keep their state.
- **One record to give one**: `grant!({ user, role, via, by, ends, note })`, `ends : [Never,
  At(ms)]` (for good unless it says), `revoke!({ user, role, via, by })`, `has!(user, role)`,
  `of!(user)`, `forget!(user)`.
- **A grant for each reason.** A user holds a role while any of their grants of it lasts, one grant
  for each reason: a subscription that ends never takes away a gift, and a gift isn't cut short by a
  payment. `by` says who acted (an admin's id, `"stripe"`, `"trial"`) and is no part of which grant
  it is, so an admin ends another admin's gift.
- **Granting again moves the end.** While a grant lasts, granting it again changes its end (sooner
  or later), its `by` and its note in place: a row is one unbroken stretch, so a payment that grants
  until the next period's end each month keeps one row. The open grant for a user, role and reason
  is a partial unique index (`closed_at is null`), and the grant an upsert on it, so two grants at
  once give one, on SQLite and on Postgres; one whose end has come is closed first (at its end), and
  a new one starts.
- **A history, never deleted** but by `forget!` (the app deletes the user): a grant that ran out
  or was revoked stays, with when and by whom, for `of!` to show and for the app to ask (a trial
  had already).
- **Payments are the app's to turn into grants**, by reading the payment's state, not each event:
  with packages/stripe, a function that reads the user's subscription and grants `via: Paid` until
  its period's end (and a few days for the card's retries), or revokes it once it has ended, run
  for every event about the user and now and then for everyone who pays. Events that come twice or
  out of order change nothing; one missed is made up.
- **Tested:** the example (SQLite and Postgres): an admin's gift for good and for days, refused to
  others, kept as JSON; a trial once, refused after it ran out; a gift revoked while a trial keeps
  the role; a grant given again moving its end, one that ran out starting anew; eight grants at once
  giving one open grant; impersonation seeing the user's roles; `forget!`. Roles' `state` by
  `expect`s.
- **Docs:** packages/auth's README (Roles, the tables, Status) and PROPOSALS (6: seats an
  organization pays for, a gate, an admin's page, Turso), the example's `main.roc`, the site's auth
  page.

**Why.** "May this person do this?" is asked where the session is, and the answer has more than one
source: who paid, who is trying it, who was given it. Keeping the reason with each grant is what
lets the sources not step on each other, and the history is what answers "why did I lose it?" and
"had a trial already?". The other names for it (entitlements, plans) describe the same rows.

**Costs.** A query each `has!` (one indexed row). A tag renamed in the app leaves its old grants
unread: `of!` leaves them out (said on the log) and `has!` doesn't count them until the rows are
updated. The partial index and the upsert on it are untried on Turso.

**Reversible:** yes: the module and its table go; an app's grants are its rows.

## D-128 Chromium driven from Roc: the CLI platform's WebSocket, packages/headless, `rocx render`

**Status.** Built (2026-11-28), on the user's ask: could e2e tests be Roc, and why not move the
browser driver to Roc too, as a package; first user, the video renderer. A spike that replaces
packages/video's `render.mjs`.

**Context.** The browser tests drive Chromium's headless shell (and Gecko) from Node, with the
repository's own driver (web/test/browser.mjs: the DevTools protocol and WebDriver BiDi over Node's
WebSocket, about 650 lines; Playwright only downloads the browsers). Playwright's clients in other
languages each run a bundled Node driver, so Roc bindings to it would bring Node back into every
run. packages/video's renderer (D-126) was Node over that driver, and TODO.md had "`rocx render` in
the CLI (it would drive Chromium itself)". The CLI platform had HTTP GETs but no WebSocket.

**Decision.**

- **The CLI platform's `WebSocket`** (cli/platform/WebSocket.roc, cli/host/src/websocket.rs, std
  alone, as the rest of that host): `connect!`, `send!`, `request!`, `receive!`, `close!`. A thread
  per socket reads its frames, answers pings and keeps each message until Roc takes it. Roc has no
  mutable counter or queue for a protocol's ids and events, so the host does both: `request!`
  sends a JSON object with the socket's next `id` put first in it and waits for the message whose
  top-level `id` is that number (the host reads just enough of each message to find it), wherever
  it is among those waiting; `receive!` takes the oldest message still waiting. The DevTools
  protocol, WebDriver BiDi and JSON-RPC all answer so. Past 10,000 waiting events the oldest goes.
- **packages/headless** names the CLI platform: `Chrome.find!` (`$CHROME`, or Playwright's newest
  headless shell), `launch!` (a profile in the system's temporary directory, the flags the Node
  driver passes plus `--no-sandbox` everywhere, as Playwright does; its port read from the profile's
  `DevToolsActivePort`, so nothing reads its stderr and no port is picked beforehand), `open!`
  (`Target.createTarget`, then a socket of the tab's own at `/devtools/page/<id>`, so a tab's events
  are its own and no session ids are needed), `close!`. `Tab`: `goto!`, `eval!` (JSON as
  packages/tools' `JsonValue`), `wait!`, `before_each_document!`, `click!`/`click_at!`, `type!`,
  `press!`, `viewport!`, `screenshot!` (the PNG's Base64 read from where it starts, not the
  answer parsed whole), `errors!`, `call!` for any method.
- **`rocx render`** (rocx-cli/Render.roc) is render.mjs in Roc, with the same options and output;
  it embeds packages/video's clock.js. One difference: the PNGs wait in a temporary folder and one
  ffmpeg encodes them after the last (the platform can't write to a child's stdin), where Node fed
  ffmpeg as it filmed. render.mjs is deleted; the catalog's Render copies `<this rocx> render <url>
  -o <story>.mp4 -o <story>.webm`.
- **Checked against the old one**: on the video example, the 46 frames of `--from 0 --to 45 --scale
  1` are byte for byte render.mjs's (and the same again on a second run), 3.4 s against 4.0 s; the
  whole video at `--scale 2` to MP4 and WebM took 26.8 s against 24.2 s (ffmpeg after filming, not
  during), its MP4 the same bytes (the WebM differs only in the muxer's random segment id).
- **Tests**: websocket.rs's unit tests (frames of each length, replies by id among events, pings,
  closing, timeouts; run as the other host modules' are, `hostUnitTests`); packages/headless's
  checks as a Roc program on a page made for them (`test/main.roc`, built and run by
  `test/headless.test.mjs`, which skips without Chromium as packages/testing does); the video
  example's tests run `rocx render` (twice, the same frames; MP4 and WebM; a page with no such
  player and an unknown option said).

**Not decided here.** Whether packages/testing's browser moves to Roc (its queries in a tab, Gecko
over BiDi, drags and touch: packages/headless/PROPOSALS.md), and an app's tests written in Roc
(packages/testing's proposal 8). rocx's own suites stay in Node: they check what the compiler makes
from outside it.

**Reversible:** yes: render.mjs back from git, the catalog's command with it; the package and the
platform's module removed.

## D-129 An app's own billing page: the card, the invoices, cancelling and keeping, in packages/stripe

**Status.** Built (2026-11-28).

**Context.** packages/stripe (D-082) sends a subscriber to Stripe's Customer Portal for everything
they may change, and tells the app who has paid from its own tables. An app that shows billing on a
page of its own (the plan and when it renews, the card, the invoices, Cancel beside them, in its own
words and look) had only `get!` and `post!`: Stripe's JSON to read by hand, in the version the
package pins (since 2025-03-31 an invoice's subscription is its `parent`'s, a period's end each
item's), and a cancel whose result the page couldn't show until the event came.

**Options.**
1. Leave it to the portal: a page of the app's own links there for everything.
2. Typed reads and changes for what such a page shows and does, each asking Stripe, keeping what it
   changes.
3. Keep cards and invoices in the package's tables, from the events (`invoice.*`,
   `payment_method.*`), so the page reads no other server.

**Decision.** 2, with the portal kept for the one thing a page can't do itself, taking a card.

- `card!(user) : Try(Card, [NoCard, StripeErr, DbErr])`, `Card : { brand, last4, exp_month,
  exp_year }`: the subscription that hasn't ended, asked with `expand[]=default_payment_method`
  (Checkout sets it to the card typed there), else the customer's
  `invoice_settings.default_payment_method`. `NoCard` with no customer, or nothing that is a card.
- `invoices!(user) : Try(List(Invoice), [StripeErr, DbErr])`: `GET /v1/invoices?customer=`, the last
  24, the newest first; none without a customer. `Invoice` gains `created_ms`, `number` and
  `pdf_url`, for the webhook's events too.
- `cancel!(user)` and `keep!(user) : Try(Subscription, [NotSubscribed, StripeErr, DbErr])`: the
  subscription that hasn't ended set to end at its period's end (`cancel_at_period_end=true`), or
  to go on (`false`; or `cancel_at=""` for an end set in the Dashboard). Stripe's answer is kept as
  `checkout_session!` keeps what it reads (its state, not a version), so `subscription!` says it at
  once and the event about the change still counts when it comes.
- `card_portal!(user, return_url)`: the portal with `flow_data[type]=payment_method_update`, back
  to `return_url` once the card is changed.
- **Tested:** the example's account page has them all (`/api/billing`, its cancel, keep and card);
  its tests (SQLite and Postgres) through the stand-in, which now keeps payment methods (a completed
  checkout's subscription on a Visa ending 4242) and invoices (its first, `bill` for a month's,
  newest first), answers `GET /v1/customers/:id`, `GET /v1/invoices`, `POST /v1/subscriptions/:id`
  and portal flows: the card from the subscription, from the customer, none; invoices listed;
  cancelling said before the event, kept after all, a Dashboard's end unset, nothing asked of Stripe
  for an ended subscription; the portal's flow. StripeRules' readers and forms by `expect`s.
- **Docs:** the README (An app's own billing page, the types, testing an app), PROPOSALS (4, 7), the
  docs site's Stripe page.

**Why.** Billing on the app's own page reads as the app, and a cancel shown at once is a page that
doesn't lie for the seconds before the event. Reading cards and invoices from Stripe each time
keeps the package's tables what they are (what decides who has paid), and needs no events an app
would have to subscribe its endpoint to; a billing page is seldom opened, so the requests are few.

**Costs.** `card!` is one or two requests to Stripe and `invoices!` one, each time the page is read:
an app that showed the card on every page would be slow, and the docs say so. A subscription charged
through a legacy source (`default_source`, a card object of before PaymentMethods) is `NoCard`.

**Reversible:** yes: the functions go, and an app's page links to the portal again.

## D-130 A chart's data gives its colours (`color` on a donut's slices and a bar chart's bars), and a donut's shares add up to 100

**Status.** Built (2026-11-28).

**Context.** A donut's slices took the chart's five colours (`--chart-1` to `--chart-5`), each
slice the next free one, kept while others come and go. An app whose slices have colours of their
own (a party's, a brand's, a category the rest of the app colours) could only set the five
variables by position, and a slice's colour is its slot's, not its position's: once the data
changed, a slice could take another's colour. So such an app drew its own ring. A bar chart's bars
were all `--chart-color`. The donut's legend rounded each share alone (`Format.percent(…, 0)`), so
they could add up to 99 or 101 and a slice of 2 in 2,000 said "0%" (an app hid the legend for it and
drew a list of its own), and drew that slice as a sliver too thin to see.

**Options.**
1. A prop that maps a label to a colour (`color : Str -> Str`).
2. The colour in the data: each item may carry one.
3. Slot variables set by key rather than position (a CSS selector per label).

**Decision.** 2. `DonutChart.Slice := { label : Str, value : Dec, color : Str ?? "" }` and
`BarChart.Bar := { label : Str, value : Dec, color : Str ?? "" }`: any CSS colour (`"#c0392b"`,
`"var(--brand)"`), set as the slice's `--slice` and its legend swatch's (a slice going away keeps
its own while it shrinks), or as the bar's `--chart-color` and `--chart-active` (it keeps its colour
when pointed at). `""`, the default, is the chart's own colour, as before.

The donut's shares (legend, middle, each slice's accessible name) are whole percents that add up to
100: each rounded down, the points left over to the largest remainders, "<1%" for a value that
comes to none. A slice with anything is drawn at least a hundredth of the ring (`least`), the others
making room; the legend and the total keep the true values.

- The types are nominal now, to have a default: a record written where the chart's data is (`{
  label, value }`, `.map(|x| { label: …, value: … })`) is one, with or without `color`; a list
  already typed as plain records isn't, so its annotation names the chart's type
  (`List(BarChart.Bar)`), or the records are built where they are passed. The site's demos and the
  quiz example name the type; the plate example's rules, plain Roc on no platform, build them on its
  page.
- **Tested:** `expect`s (a slice's and a bar's colour from the data, `""` without; a colour taken at
  once and kept by a slice that is going; shares that add up to 100, "<1%", nothing; a sliver drawn
  for a value too small to see); the site's chart tests, unchanged.
- **Docs:** packages/charts' README, the docs site's charts page.

**Why.** What colours a slice is part of what the slice is: the data already names it, so it can
say its colour too, and it glides, comes and goes with it. A label-to-colour prop would split one
fact over two places, and still say nothing about two slices with one label.

**Costs.** A plain record list isn't the chart's type (above). A stacked bar chart's series are a
list of names (`series : List(Str)`), so they still take the five colours.

**Reversible:** yes: the field goes, and the types are plain records again.

## D-131 A subscription's items say their price's terms

**Status.** Built (2026-11-28).

**Context.** `Stripe.Item` was a price's id, its product and how many. An app selling one product
on more than one plan (a month at a time, or a year) couldn't say which one a subscriber is on, or
what they pay, without asking Stripe for each price on each page; and an app that promises a
subscriber their price after it rises (the lookup key moved to a new price, D-127) had nothing to
show that price from: its pages could only say today's.

**Decision.** `Stripe.Item` (and `StripeRules.Item`) gains the price's terms as the subscription
object carries them (Stripe sends each item's whole price, in events and in its API's answers):
`unit_amount : I64` (the currency's smallest unit), `currency : Str`, `interval : Str` (`day`,
`week`, `month`, `year`; "" for a one-time price), `interval_count : U64` and `lookup_key : Str`
("" for none). They are kept in the row's `items` JSON with the rest, so `subscription!` and
`subscriptions!` say them without asking Stripe. `StripeRules.subscription_item` reads one item;
a price given by its id alone says only that.

- A row kept before this has only the price, product and quantity: it is read with 0 and "" for
  the rest (`items_of`), where it used to fail to the whole list, until Stripe's next event about
  the subscription writes it again. No migration: the column is the same JSON.
- **Tested:** `expect`s (an item with its whole price, one with an id alone, a three-monthly
  interval, a null lookup key; a row's items read back; an older row's items with zeros; nonsense);
  the example's tests (a kept row's items with their terms).
- **Docs:** the README (`Stripe.Item`, what a subscriber pays after a price changes), the docs
  site's Stripe page.

**Why.** What a subscriber pays is their subscription's, not the lookup key's: the key moves when
the price changes, and the subscriptions on the old price keep it. The subscription already says
it, in every event the package reads, so keeping it costs nothing and asks Stripe nothing.

**Costs.** A record type with more fields: an app that builds `Stripe.Item`s itself (its tests)
writes them all.

**Reversible:** yes: the fields go, and older rows read as before.

## D-132 What a user may do: the app's own function of what a request knows

**Status.** Built (2026-11-28).

**Context.** Roles (D-127) say what a user holds, and why. What a user may do was asked of them
directly, wherever it mattered: `Roles.has!(user, Pro)` in a route, an admin list read again in
the next, and an app's "an admin, or someone holding Pro" written out at each place that needed
it. Each `has!` is a query, so a request that asked three times read the table three times; and a
rule that changed (admins get Pro too; a new role that may do the same) changed everywhere it was
written.

**Options.**
1. Permissions stored: a table of what each role (or user) may do, edited at run time.
2. A permission type in the package (`Roles.Permission`, a gate middleware taking a role).
3. The roles held now read once a request into its context, and what a user may do a pure
   function of the app's own over that context, never stored.

**Decision.** 3.

- **`Roles.current!(user) : Try(List(role), [DbErr(Str), BadRow(Str), ..])`**: the roles held
  now, each once, in one query (`select distinct role` over the open grants that last); a role
  the app's tags no longer read is left out and said on the log, as `of!` does. `has!` stays for a
  check outside a request.
- **The rest is the app's**, a module of its own (the example's `Policy.roc`): its actions as a
  tag union (`[UsePro, Administer, Impersonate, Grant]`), `can : { roles : List(Role), admin :
  Bool, .. }, Action -> Bool`, and `need` (the same as a route's answer, `Try({}, Endpoint.Refusal)`,
  so a route writes `Policy.need(context, UsePro)?`). Who it reads is an open record: a request's
  context is one, and a job builds one for someone outside a request.
- **A check about a thing** is an action that carries it (`Edit(post)`, `ManageOrg(org)`): the
  route reads the thing, then asks. Nothing in the package or the shape changes for it; a list of
  permissions worked out in the middleware couldn't hold one, which is why it is a function.
- **The example**: its middleware's `Me` gains `roles` (the user the routes see) and `admin` (who
  really signed in, from `ADMIN_EMAILS`, read each request, so taking someone off the list ends
  their admin at once); roles that can't be read are a 503, not none. `/pro`, `/admin`,
  `/impersonate`, `/roles/grant` and `/roles/revoke` ask `need`; `/roles` says `can(…, UsePro)`.
- `ADMIN_EMAILS` stays a list rather than an `Admin` role: the first admin would need granting
  from somewhere, and a role granted from the list would outlive the address's removal from it.
- `rocx new`'s template has no roles yet, so it gets no `Policy.roc`.
- **Tested:** `Policy`'s `expect`s (each rule, a refusal); the example's tests (unchanged: Pro
  given, revoked, run out and behind impersonation, admins' routes, now through the roles the
  middleware read).
- **Docs:** packages/auth's README (`current!`, What a user may do) and PROPOSALS (6), the docs
  site's Auth page (What a user may do, the example's `Policy.roc`).

**Why.** Roles are facts about a user, kept with their history; permissions are rules, and rules
belong in code: changed by a commit, never by a migration, and tested with `expect`. One read a
request makes every check after it free, and the actions as tags make the compiler ask about each
one a `match` doesn't cover.

**Costs.** A query on every signed-in request, also for routes that ask nothing (an indexed read,
beside the user's row the middleware reads already). A context type with two more fields.

**Reversible:** yes: `current!` goes, and routes ask `has!` again.

## D-133 UUIDs in packages/crypto: version 7 and version 4, as text

**Status.** Built (2026-11-28).

**Context.** Apps make row ids, and so does a package that keeps rows of its own (packages/auth's
users, D-134). Each wrote its own: random bytes in base64url, or a hand-made version 4 UUID. A
random id scatters inserts across an index; one that leads with its time keeps them at its end, and
sorting by id sorts by when rows were made. Neither the platform nor a package offered one.

**Options.**
1. `Random.uuid!` in the server platform: one call, but a platform API, and the browser's program
   wouldn't have it.
2. A pure module in packages/crypto, given the time and the random bytes.
3. Leave ids to each app.

**Decision.** 2.

- **`Uuid.v7 : U64, List(U8) -> Str`**: RFC 9562's version 7, milliseconds since 1970 (the low 48
  bits) then 74 random bits from the first 10 bytes given, with the version and variant set, in
  lowercase text. Two in the same millisecond are ordered by their random bits (RFC 9562, 6.2,
  allows it); no counter is kept, as the module keeps no state.
- **`Uuid.v4 : List(U8) -> Str`**: version 4, from the first 16 bytes. **`Uuid.is_uuid : Str ->
  Bool`**: 8-4-4-4-12 hex digits, either case.
- A byte missing from those given counts as 0, so a short list gives an id rather than an error;
  the README says to give each its full count.
- Text of 36 characters, not 16 bytes: the same in SQLite (no UUID type) and Postgres (`text`, or
  `uuid`, which reads it), readable in a query's output and in a URL.
- **Tested:** RFC 9562's own examples (A.6, version 7; A.4, version 4), the version and variant
  bits whatever the bytes say, bits above 48 dropped, the time leading, and `is_uuid`'s refusals.
- **Docs:** packages/crypto's README (the API, UUIDs), the docs site's Crypto page.

**Why.** An id is bytes made into text, which is what the package is for, and plain Roc keeps it
testable with `expect` and usable in the browser. Version 7 for anything new: index locality and
time order cost nothing over version 4.

**Costs.** A version 7 id says when it was made to anyone who sees it; where that matters, version
4. Twenty more bytes a row than binary.

**Reversible:** yes.

## D-134 packages/auth keeps the app's users

**Status.** Built (2026-11-28).

**Context.** `admit!` gives the app's id for a user, and the package hands it `identity.user`
(`Known(id)` for an identity that signed in before) for that. Every app wrote the rest: a users
table and "find the user with this address, or make one" (the example's `made!`). One that skipped
it and gave the address as the id, which is less to write, made the address its key everywhere:
in every row that names a person, so a new address at the provider made a stranger of them (their
rows stayed with the old one), and deleting a person meant rewriting each of those columns. And
deleting a person meant knowing every table the package keeps for them, which only the package
does.

**Options.**
1. Leave users to the app, and add only `Auth.forget!`.
2. The package keeps users: a table, `user_for!` for `admit!`, lookups, and `forget!`.

**Decision.** 2 (the user, 2026-11-28).

- **`auth/0006_users`**: `auth_users (id, email unique, created_at)`. The app may read it in its
  queries (a join for an address); only the package writes it.
- **`Auth.user_for!(identity) : Try(Str, [NoAddress, DbErr(Str), BadRow(Str), ..])`**, for
  `admit!`: `Known(user)` is that user, and their address becomes the provider's if it changed and
  no other user has it; their `email` identities for other addresses go then (an address given up
  may be someone else's later, and a link to it would sign in as them). `New` is the user with its
  address (a mailed link and a provider with the same verified address are one person, as the
  example did before), else a new user with a version 7 UUID (D-133). No verified address is
  `NoAddress`. The insert is one statement (`on conflict do nothing`, then read by address), so two
  sign-ins of a new address at once make one user.
- **An app with ids of its own** keeps them: a `Known` identity whose user has no row gets one,
  with that id, so moving onto the package needs no copy of the ids (an app that wants its old rows
  can insert them in its own migration, which runs after the plugins').
- **`Auth.user!(id)`, `Auth.user_by_email!(email)`**: `Try(Auth.User, [NotFound, ..])`, `Auth.User :
  { id, email, created_ms }`.
- **`Auth.user_with_address!(email) : Try(Str, [NotAnAddress, DbErr(Str), BadRow(Str), ..])`**: the
  user with an address, made if there is none, for an app that names someone before they sign in
  (an invitation to their address, an admin letting them in ahead, a test account its own link signs
  in as with `sign_in!`); their first sign-in with that verified address finds them. `user_for!`'s
  new identities go the same way.
- **`Auth.forget!(id) : Try({}, [DbErr(Str), ..])`**, one transaction: their sessions (an admin
  acting as them is themselves again), links on their way to their addresses, identities,
  authenticator, recovery codes, sign-ins waiting for a code, grants (`Roles.forget!`'s) and row.
  Others' rows naming them (who granted a role) stay, naming no one. On the log.
- No `name` column: the identity's name is the app's to keep (a profile), as is everything else
  about a person.
- **Not yet:** `rocx new`'s template (`templates/app`, its `users` table and `made!`) and the notes
  example (`Store.person_for!`) still keep users of their own; moving them onto `user_for!` is
  next.
- **The example** keeps no users table now (`0001_users` gone; an applied migration that is gone is
  passed over): `admit!` is `user_for!` after its refusal of `refused.example`, and its routes look
  people up with `user!` and `user_by_email!`.
- **Tested:** the example's tests, on SQLite and Postgres: a version 7 id led by its time, the same
  user by a mailed link and a provider with the address, another user's address not taken, the
  provider's new address becoming the user's and the old address's link making someone new,
  `forget!` (sessions gone, the admin acting as them back to themselves, no row left in
  `auth_users`, `auth_identities`, `auth_sessions` or `auth_roles`, a new user on signing in again),
  `user_with_address!` (made once, found again, the same user at the first sign-in, not an address
  refused);
  a session whose user's row is gone answered as signed out, as before.
- **Docs:** packages/auth's README (installing, Users, the API, the tables), the docs site's Auth
  page (Users, the tables).

**Why.** Every app needs users and wrote the same table and lookup; the package already maps
identities to them, so the step that finds or makes the user belongs beside it, and with it the
one place that knows everything to delete. An opaque id the package makes keeps the address out of
the app's rows: a new address is one update, and deleting a person is `forget!` and the app's own
rows.

**Costs.** A table every app with the plugin gets, used or not. An app joins `auth_users` to show
an address where it used to read a column of its own.

**Reversible:** yes, while apps can read the ids: the table stays, and `admit!` goes back to the
app's own lookup.

## D-135 packages/stripe forgets a user: `Stripe.forget!`

**Status.** Built (2026-11-28).

**Context.** An app deleting a person (a request to erase their data) deletes its own rows and
packages/auth's (`Auth.forget!`, D-134). The package's rows name the user too (their customer,
checkouts, subscriptions), and Stripe keeps a customer whose subscription goes on charging. Only the
package knows both. Deleting the rows alone isn't enough: Stripe's next event about the subscription
names the user in its metadata, and the package would write its row again.

**Options.**
1. The app deletes the package's rows by SQL and the customer through `Stripe.post!`.
2. `Stripe.forget!(user)`: the customer deleted at Stripe, the rows deleted, and the customer kept as
   forgotten so later events keep nothing.

**Decision.** 2 (the user, 2026-11-28).

- **`Stripe.forget!(user) : Try({}, [StripeErr(Str), DbErr(Str), ..])`**: `DELETE /v1/customers/<id>`
  (Stripe ends the customer's subscriptions at once, with no refund, and keeps their invoices), then
  `stripe_subscriptions`, `stripe_checkouts` and `stripe_customers` rows of the user deleted, in one
  transaction. A 404 `resource_missing` (Stripe has no such customer) is taken as done
  (`StripeRules.missing`). Nothing is asked of Stripe for a user with no customer. On the log.
- **`stripe/0003_forgotten`**: `stripe_forgotten (customer_id, forgotten_at)`. An event whose object's
  customer is there is recorded (handled once, a 200) and kept nowhere; `on_event!` is given it with no
  user. The customer's id names no person once Stripe deleted it.
- The package's requests take `DELETE` now beside `GET` and `POST` (tried again as they are).
- The example's stand-in for Stripe answers `DELETE /v1/customers/<id>` as Stripe does: the customer
  gone, its subscriptions `canceled`, a 404 `resource_missing` for one it hasn't.
- **Tested:** `StripeRules.missing`'s expects; the example's tests on SQLite and Postgres (a subscriber
  forgotten: the one `DELETE`, the customer gone at Stripe, its subscription ended, no row left, the pro
  pages shut; the subscription's end and the customer's deletion sent after, answered 200, bringing
  nothing back; forgotten again and someone who never checked out, nothing asked of Stripe).
- **Docs:** packages/stripe's README (Deleting a user, the API, the tables), the docs site's Stripe page
  (the tables), DECISIONS.md.

**Why.** Erasing a person is the app's to decide and the packages' to carry out, each for what it
keeps; the subscription must stop at Stripe, not only here, and a tombstone is the one way an event
that comes after can't undo it.

**Costs.** A row per forgotten customer, kept for good. No refund: an app that owes one refunds first.

**Reversible:** yes: the function and the table go; deleted customers stay deleted at Stripe.

## D-136 A stacked area chart in packages/charts, its bands' colours from the data

**Status.** Built (2026-11-28).

**Context.** An app charting one count split into parts over time (visits by source, views by
channel, sales by region, each day or since something began) had a line of the total
(`<LineChart>`), which says nothing of the parts, or a column a day (`<StackedBarChart>`), whose
series take the five colours by position and whose columns are slots, not a scale of time. Such
an app drew its own stacked area with the package's `Scale`, `Path`, `Ticks` and `Ease`, and used
it in two places. The donut's shares that add up to 100 (D-130) were `DonutChart.shares`, inside a
component, which another component can't import.

**Options.**
1. Leave it to apps: the arithmetic is the package's already.
2. A `stacked` prop on `<LineChart>`, taking several series.
3. A component of its own, `<StackedAreaChart>`: points across to scale, as the line chart's, and a
   band for each part, its colour from the data, as D-130's slices.

**Decision.** 3. `StackedAreaChart.Data : { xs : List(Dec), bands : List(Band) }`,
`Band := { label : Str, values : List(Dec), color : Str ?? "" }`: each band stacked from the axis
up in order (the first at the bottom), filled (`--chart-fill`, 0.3 unless set) under an edge in its
colour, so the top edge is the whole; the axis up from zero to the highest whole. A band keeps its
label's key (`Keys.unique`), and is in its `color` (set as its `--band`) or, given none, the
chart's colour for its place (`--chart-1` to `--chart-5`), as a stacked bar chart's series. A
legend over the chart says each band's label, its value and, with more than one, its share of the
whole: at the point nearest the pointer (whose whole shows over the plot and whose `x` on the axis,
found by `Scale.strips` as the line chart's points), or, while none is, as `resting` says: `Last`,
the last point's (a running total's now, the default), or `Sum`, all its points' added up (of a
count each day, the period's: the last point would be only today's so far). Props as the line
chart's otherwise: `label`, `format`, `format_x`, `smooth`. New values glide the bands to them a
frame at a time; more points or fewer, or other bands, are the data's at once.

- `Format.shares(values)` is the donut's arithmetic, moved where a component can import it (plain
  Roc): whole percents that add up to 100, "<1%" for a sliver. `DonutChart.shares` stays, calling it.
- The donut centres its ring when its legend wraps under it in a narrow box (`justify-content:
  center`; on one row the legend grows, so nothing moves): before, the ring sat at the row's start.
- **Tested:** `expect`s (two bands stacked, the second's lower edge the first's upper; below zero
  and missing values as zero; a band's colour from the data, two bands with one label two bands; the
  outline; the legend's values and shares at the last point, at a point pointed at and summed; a
  band alone with no share; gliding the same bands, and other bands at once; `Format.shares`, moved
  from the donut's); the site's chart test (the demo's three bands from the server, the legend's
  shares adding up to 100, another fortnight moving them, no frames once there).
- **Docs:** packages/charts' README (the component, `Format.shares`, the colours, styling, limits),
  the docs site's charts page (a live demo, a shop's orders each day by where they came from,
  resting on the fortnight's), the root README's list.

**Why.** A count by part over time is a common dashboard chart, and the parts are what a reader asks
about ("which of them made the views?"). Its own component keeps `<LineChart>`'s one line simple, and
the colours from the data let an app's parts look as they do elsewhere in it.

**Costs.** An eighth component copied into each app that names the package. The chart is one image
to a screen reader, as the line chart is; the legend's words are what it reads of the values.

**Reversible:** yes: the component goes, and an app draws its own again.

## D-137 A phone lays its views out as CSS does: Taffy, text measured by the platform

**Status.** Built (2026-11-28).

**Context.** The Android host (D-063) laid its views out with nested `LinearLayout`s: blocks stacked,
a flex box was a row, nothing wrapped, there was no grid, no positioning, no inline formatting, and
margins collapsed only between siblings. Its CSS knew type, class and id selectors, descendant and
child combinators, and a few dozen properties. A real app (a large one: sixteen pages, a design
system of about forty components) uses `display` four hundred times, `gap`, padding and margin
hundreds, `grid-template-columns` fifty, `position` sixty, `flex-wrap`, `overflow`, `transform`,
`box-shadow`, `line-height`, `white-space`, `:has()`, `:not()`, attribute selectors, custom
properties everywhere and `@media` on width for its phone layouts. DESIGN.md (§5, §6.2, §6.3)
planned Taffy, text measured by the platform, and a CSS subset checked at build time.

**Options.**
1. Keep the platform's layouts (LinearLayout, ConstraintLayout) and map CSS onto them.
2. Taffy over a tree mirroring the projected views, the CSS resolved in `native/core` at run time,
   text measured by the platform through Taffy's measure function; the views placed absolutely.
3. As 2, with the CSS compiled to a table at build time (DESIGN §6.2).

**Decision.** 2, the build-time table left for later (a large app's 150 KB sheet, 1,491 rules, parses
in 7.5 ms on the Mac and about twice that on the emulator, once, and again on a rotation):

- **CSS** (`css.rs`, `values.rs`): selectors with the four combinators, `:not()`, `:is()`,
  `:where()`, `:has()`, the `-child` and `-of-type` pseudo-classes, attributes, `:disabled`,
  `:checked`, `:focus`/`:focus-visible`/`:focus-within` from the native focus, `:empty`, `::before`
  and `::after` with their `content`; a rule index by id, class and tag; the cascade with
  `!important` and the `style` attribute; shorthands expanded after `var()`; `@media` (a phone's
  answers), `@supports`, `@layer`, `@container` against the screen; every length unit, `calc()`
  kept when it has a percentage, every colour syntax with `color-mix()`; a user-agent sheet close
  to the HTML spec's. What isn't done warns once, as D-063 said.
- **Boxes** (`native.rs`): projected by `display`, as CSS makes boxes: a block of inline content is
  one text view of styled runs (a link's run tappable on its own); an inline box among text makes
  its block a line, a flex row that wraps (CSS's line boxes approximated); `display: contents`,
  pseudo-elements, list markers; absolute views drawn in their containing block's view, fixed ones on
  a layer over the scrolling page, siblings by `z-index`; `overflow: auto`/`scroll` a native scroll
  view.
- **Layout** (`layout.rs`): Taffy 0.16 on a tree of the engine's own kept between flushes (its
  `calc()` resolved, aspect-ratio for flex and grid boxes given a width, a flex box's fit-content,
  `order`, which Taffy hasn't), text measured by the platform (`Platform::measure`: Android's
  `StaticLayout` over JNI, cached by version and width), the screen's size from the activity.
- **Ops**: a render applies its views' changes, lays them out, then sends their frames: `FRAME` (7)
  and `EXTENT` (8) are new, and the paint and post-layout properties (`style.inset`,
  `style.transform`, gradients, borders and radii per side and corner, shadows, rings, outlines).
- **Kotlin**: `Box` (a ViewGroup placing children at their frames, clipping to its corners when its
  overflow says), `TextBox` (styled runs in a `StaticLayout`, CSS line heights, ellipsis and line
  clamps, link taps), `CssPaint` (every view's background), scroll views around a content box,
  sticky views moved as the scroll goes, the screen's size told to the host.
- **Incremental**: the document notes when each node, and anything in it, changed; a render with
  nothing changed is skipped, and one with changes takes again the views of every element whose
  subtree, siblings' attributes and parent's styles didn't change.
- **`on:viewport`** runs: its handler told its element's scroll and size after each layout that
  changed them, as runtime.js tells it.
- **Tested:** cargo tests (selectors, the cascade, media and pseudo-elements; lengths, colours,
  gradients, shadows, transforms, calc; CSS to Taffy; block, flex, grid and absolute layouts;
  aspect-ratio; a field and its button sharing a wrapping row; a flex item's long text fitting its
  room; text runs; displays and their boxes; incremental projection, a `:has()` left of the subject;
  a 1,204-view page's timing); a large app's landing, sign-in and eight members pages on the emulator
  compared with Chromium at 412 px; examples/pomodoro and phone-hello, each with its server.
- **Docs:** spike/native-apps/README.md (CSS and layout, how it runs, measurements, gaps),
  DESIGN.md (§3, §6.3, §13, §16), DECISIONS.md.

**Why.** Taffy implements block, flex and grid from the specs, so an app's CSS means on a phone what
it means in a browser, with the platform's own text, fields, scrolling and accessibility; a
LinearLayout mapping would have been a second layout engine of our own, worse at each. Absolute
placement keeps the applier small and the layout in `native/core`, where iOS gets it too. Measuring
by the platform keeps the drawn text the measured text.

**Costs.** Two layout engines (Chromium's and Taffy's) and two text engines: an app's text wraps
where its fonts do (Roboto against a Mac's SF). CSS's line boxes are approximated (a text beside an
inline box wraps as one piece), as are sticky (top only) and baselines; transitions, animations,
filters, `@font-face` and dark mode wait. The APK grows about 0.85 MB (Taffy and its CSS parser).
The projection is the engine's own, kept in step with runtime.js's DOM by the conformance suite
(DESIGN §12) still to come.

**Reversible:** yes: the projection can go back to sending properties alone and the applier to
LinearLayouts; the CSS module stands on its own.

## D-138 A phone app navigates as the browser does: the page's document, its own history, a cookie jar

**Status.** Built (2026-11-28).

**Context.** The Android host (D-063) showed one page at its start path: `Router.navigate!` was
logged and ignored, links did nothing, there was no back, no cookies (so no sessions), a connection
a request, and a redirect was an answer, not a place to go. A real app starts at `/` (a landing page
signed out, its board signed in), signs in (a form that sets a session cookie and redirects), keeps
its members' pages behind folder middleware that redirects to `/login`, navigates by links,
`navigate!` and query changes, and posts forms whose answers redirect. DESIGN.md's question 4
proposed a light route check (the page's middleware, no render) for a phone's guards.

**Options.**
1. A light route check: the server runs a page's middleware for the phone and answers its status and
   redirect; the phone renders the page and asks its reads.
2. D-040's own way: the phone fetches the page's document, as the browser's navigation does
   (`x-rocx-navigate: 1`), follows its redirects, and reads only what it seeds.
3. Guards left to the reads: a page shows what its endpoints refuse (a 401), never redirected.

**Decision.** 2. A navigation is runtime.js's (`navigate`, `pageFor`, `commit`, `inPlace`,
`remakeRoot`, `refreshKept`), ported to native/core (`nav.rs`):

- **Where the app is** (`Router.location!`) is a source; a level that read it once is made anew
  (`readOnce`, D-070's branch-picking parts excepted). The query alone changing is made in place.
- **A navigation fetches the page's document** (`accept: text/html`, `x-rocx-navigate: 1`): the server
  runs the page's middleware, the client follows its redirect, and where it ended is the page. The
  phone reads the document's seeds alone (`rocx-answers`, `rocx-flash`: two `<script>`s found in the
  text, no HTML parsed), so the page's first frame asks nothing; what the navigation keeps reads
  again what the document answered otherwise. The app's first page goes the same way (its document,
  then the mount). A document that isn't one of the app's pages (another site's, a file), a link with
  a `target` or `download`, `mailto:` and `tel:` open in the system.
- **History**: the app's own (each entry its target and its scroll); Android's back goes to the entry
  before, and at the first the activity finishes. Leave listeners (`use_before_leave!`) are asked
  before each navigation and back.
- **Links**: a tap on an `<a href>`, or on what has a click handler, sends `click` to that element
  (a text view's link is a run of its own, a `ClickableSpan`: `links`, `start:end:id` runs), and the
  engine's dispatch navigates unless a handler took the default (`.prevent`). `aria-current` as
  runtime.js marks it.
- **Forms**: as runtime.js sends them: a component's submissions, plain forms (D-118, D-121, D-122),
  their redirects navigated to (D-117, D-119); a form the runtime wouldn't send (to a path no
  endpoint has) is the browser's, so a phone posts it as a navigation, its answer the page. A
  checkbox or radio is sent as it was tapped; Enter in a field submits its form.
- **Sessions**: a cookie jar in native/core (`cookies.rs`: RFC 6265's storage model; `Secure` as
  browsers have it, sent over `http://localhost`), every request's, written to the app's files.
- **HTTP** (`http.rs`): `fetch`'s redirects (another site's handed back, not followed), keep-alive (a
  small pool per host), timeouts, `Origin` on what isn't a GET (a server's cross-site form check),
  and streams (D-140). Plain `http://`: the emulator reaches a dev server so; rustls waits.
- **`Browser.call!`**: the page functions apps commonly register, done on the engine's document with
  their browser arguments (`calls.rs`: `focus`, `click`, `reveal`, `go`, `replace_query`); a
  platform's own handler by the name first.
- **Tested:** cargo tests (the jar: sending, replacing, deleting, domains, `Secure`, dates, its file;
  the URL resolver; the client: redirects, a 307's body, a closed kept connection, a stream; SSE
  parsing; a document's seeds; the route table's pages; link marks; selectors); the Mac runner's new
  steps (`--path`, `--files`, `link:`, `nav:`, `back`, `where`, `cookies`, `check:`, `at:`) and the
  emulator against a large app's dev server: its landing, the dev sign-in (a form post, its 303, the
  session cookie), the header's links to every members page and back, a query's pages in place and by
  document, a text post composed and published (its endpoint's redirect to the new post), accounts
  connected through the server's redirects, signing out, the app reopened still signed in, a
  provider's sign-in opened in the system's browser, back to a long page at its scroll; the tasks
  example's question before leaving a task with changes (its Cancel link and back stopped, Keep
  editing, Leave without saving); phone-hello and pomodoro as before.
- **Docs:** spike/native-apps/README.md (Pages, sessions and the server; the hosted functions; the
  runner's steps; gaps), DESIGN.md (§3, §8, §9, §13), DECISIONS.md.

**Why.** The browser's way is the app's semantics: its guards, redirects and seeds are what its pages
were written against, and the server needs nothing new (a route check would have been a second
answer to keep in step with the page's). The document costs a render on the server, as a browser's
navigation does; the phone parses only two scripts of it.

**Costs.** A navigation's document is HTML the phone mostly doesn't read. Two engines keep the same
navigation (runtime.js's and nav.rs), which the conformance suite (DESIGN §12) is to keep one. A
provider's sign-in leaves for the system's browser and doesn't come back (an App Link would). No
prefetching, focus handling or announcing of the new page yet; plain HTTP.

**Reversible:** yes: nav.rs, cookies.rs and calls.rs go, and the phone shows its one page again.

## D-140 Live updates on a phone: `listen!` and channels over the HTTP client's streams

**Status.** Built (2026-11-28).

**Context.** `listen!` (an endpoint's server-sent events), `subscribe!`, `say!` and `resync!` (the
channels, D-020, over `/rocx/live`) were stubs on the phone that failed with why. An app's board
listens to its org's stream to read itself again when a post's state changes; channels carry
presence and shared state.

**Options.**
1. Polling: read the endpoints again every few seconds.
2. The browser's own: server-sent events read by the HTTP client as they come, and runtime.js's
   `listenTo` and `Hub` ported.

**Decision.** 2 (`live.rs`, on `http::stream`):

- **`listen!`**: a GET with `accept: text/event-stream`, its cookies sent, its redirects followed; each
  event's data to the handler (`{"Event":…}`), then `"Ended"` (an `end` event), `{"Failed":…}` (cut
  off) or `{"Refused":[status, body]}` (an answer that isn't a stream). Started in a component or a
  computation, it stops when that goes: its socket shut from the main thread.
- **Channels**: one stream for the app, `GET /rocx/live?tab=…&c=<url>…`; its `hello`; the set followed
  by `subscribe` and `unsubscribe` posts naming the stream (D-057), and what is said and the resyncs in
  one `POST /rocx/live/send` a flush; a 5xx or a drop opened again after a wait that doubles from 0.5
  s to 30 s (a quarter added at random), starting over once a stream stayed up 10 s; no server for
  channels, every subscriber refused. The app is one tab: its id made once a process, a new one when
  the server says another has it (`replaced`).
- **Tested:** SSE parsing (events across reads, a character cut between them, comments) and a stream
  read as it comes (cargo); a large app's board on the Mac runner and the emulator heard a post made
  and published in a browser tab (Chromium) and read itself again; the checkboxes example's channel
  resynced, heard what curl and another runner said, and what the phone said reached the other; its
  stream, dropped by the server's restart, opened again half a second later and resynced.
- **Docs:** spike/native-apps/README.md, DESIGN.md (§9, §13), DECISIONS.md.

**Why.** The same wire as the browser's keeps the server unchanged and the semantics one; a stream
costs a thread on the phone, idle between events.

**Costs.** A thread a stream. A subscriber's next event isn't held until a handler that waited for
the server is done (the browser's is). The streams stay open while the app is in the background, as a
browser tab's do; Android may cut them, and they open again.

**Reversible:** yes: live.rs goes, and the hosted functions are stubs again.
