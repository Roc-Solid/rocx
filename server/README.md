# Roc Solid's server platform

Roc compiled to native code, in a Rust host: one executable that answers HTTP, streams events,
renders pages of components, runs jobs and cron, sends email, keeps live rooms, channels, actors
and values in memory, with Postgres beneath all of it. The browser's platform is `web/` (wasm): an
app is two programs, one on each, talking over HTTP. The docs site's platform pages (`/platform`)
say all this at more length.

The host (`host/`, Rust) gives Roc general things: HTTP, coroutines that Roc's calls run on (below),
a pool of Postgres connections and one that listens, TCP and TLS sockets, requests to other
servers, live topics and rooms, channels' streams, background loops that sleep until woken,
isolated calls, actors' mailboxes and timers, a key-value store in memory, the environment, secure
random numbers, AES-GCM, and rendering components. Migrations, the
jobs queue and its workers, cron, email (an SMTP client, MIME) and actors' state are the platform's
Roc (`platform/*.roc`), written on those. Files in S3 and the crypto written in Roc (SHA-256, HMAC,
HKDF, Base64, hex) are packages an app names, on no platform (`packages/s3`, `packages/crypto`:
D-025).

```sh
just dev        # the docs site on it: http://localhost:8080, rebuilt on save
just db         # a Postgres in Docker; prints its DATABASE_URL
node server/build.mjs app.roc out/app [--opt=speed] [--target=arm64musl]
```

## An app

```roc
app [program] { pf: platform "…/server/platform/main.roc" }

program = {
    respond!,                                   # every request, answered with a Server.Response
    migrations: [{ name: "0001_tables.sql", sql: tables }],   # import "0001_tables.sql" as tables : Str
    jobs: [Job.handler(welcome)],               # what the job workers run
    crons: [Cron.every("0 3 * * *", nightly, {})],
    actors: [Actor.handler(cart)],              # the kinds of actor (below)
    logs: { format: Auto },                     # the log's format: Auto, Pretty or Json (below)
    plugins: plugins.map(Plugin.running),       # what packages add (below); [] for none
    routes: [],                                 # the app's own routes, which plugins' mustn't meet
}
```

`respond!` takes a request's method, target, headers (`name: value` a line), body (`List(U8)`, the
bytes as they came) and what the server was started with (`--context-file`), and answers with a
`Server.Response`: `Server.from_http` makes the request. An app with routes writes none of this
record: `rocx build` writes `Generated/App`, whose `App.program({ context, middleware, crons,
openapi })` is a program that answers every request with the app's routes (pages, `+server.roc`
endpoints and channels) behind its middleware, and lists the jobs and kinds of actor its modules
define and its `migrations/*.sql` (`site/main.roc` is a whole app). The
response's body is text; bytes (`Server.bytes`, below); a body the host fetches from elsewhere and
sends on (`Server.forward`, below); a page of components (`Page`), which the host renders (below); or
a stream of `Events`, which the host runs in a call of its own with `{ send!, sleep! }`.
`Server.for_host` hands each over, flattened: `{ status, headers, kind, text, bytes, upstream, page,
feed }`, `kind` 0 for `text`, 1 for the `page` (a box the host runs: `Html.serialize!` of the page's
markup, made once per answer), 2 for the `feed`, 3 for the `bytes`, 4 for the `upstream` (its
method, URL and headers); the boxes an answer doesn't send do nothing, and the host releases them.
`program.actors` lists the app's kinds of actor (`Actor.handler`), so the host can run an actor's
turn when nobody waits on it (a tell, a timer). The platform exposes `Db`, `Job`, `Cron`, `Email`,
`Kv`, `Live`, `Actor`, `Log`, `Time`, `Tcp`, `Http` (and `HttpResponse`, its answer), `Env`,
`Random` and `AesGcm`; the jobs page (`JobsPage`); the modules components are written with
(`Html`, `Solid`, `Show`, `For`, `Loading`, `Errored`, `Context`, `Call`, `Router`, `Title`,
`HttpStatusCode`, `Transition`, `Submission`, `Submissions`, `Browser`, `Audio`); and HTTP's
(`Server`, `Endpoint`, `Channel`, `Middleware`, `Events`, `OpenApi`). Those last two kinds are the
web platform's too: their source is in `web/platform`, and the build copies them here
(`SHARED_MODULES` in `build.mjs`).

### Postgres: `Db`

```roc
notes : Try(List({ id : I64, body : Str, note : Db.Nullable(Str) }), [DbErr(Str), BadRow(Str)])
notes = Db.all!("select id, body, note from notes where author = $1", [Int(author)])

added = Db.run!("insert into notes (body) values ($1)", [Text(body)])     # rows changed

Db.transaction!(|{}| {
    _ = Db.run!("insert into orders …", […])?
    Job.enqueue!(receipt, { order }, { when: Now })?      # queued only if this commits
    Ok(order)
})
```

A parameter is `Null`, `Text`, `Int` or `Bool`, sent as text: Postgres reads it as the type its
place wants. Rows come back as JSON and `Json.parse` decodes each into the record the caller
annotated, by column name: a null is JSON's `null`, any other value itself. A column that may be
null is read as `Db.Nullable(a)` (`Null` or `Some(a)`, matched as a tag union; `null` or the value in
JSON, both ways); a null in a column read as a plain value is `BadRow`, which names the column. The
record says what may be null, so the host asks the catalog nothing (D-022). Booleans, integers,
floats, text, `json`/`jsonb`, `uuid`, timestamps and dates are read; anything else asks for a cast
(`::text`).

`Db.transaction!` keeps one connection for the call: what the body writes, and the jobs it queues,
stay only if it returns `Ok`. An `Err`, a failing statement or a crash rolls it all back, and a call
that ends with a transaction open has it rolled back. `Db.script!` runs statements with no
parameters.

**Migrations** are in the executable: `program.migrations` lists them, each a name and its SQL
(`import "migrations/0001_tables.sql" as tables : Str` reads a file when the app is compiled). When
the server starts they are applied in the order listed, each once, each in a transaction (recorded
by name in `rocx_migrations`); two starting at once (a deploy's old server and its new one) take
turns (an advisory lock). The
platform's own tables (`rocx_jobs`, `rocx_actors`: `rocx/0001`, `rocx/0002`, …)
come first; one that fails stops the server.

Connections use TLS when the database offers it (or the URL's `sslmode` asks), checked against the
web's certificate authorities.

**roc-pg** ([niclas-ahden/roc-pg](https://github.com/niclas-ahden/roc-pg)), a Postgres client in
Roc whose queries are checked against a schema when the app is compiled, runs on this platform: it
connects with `Tcp.connect!` and logs in with `Random.seed_u64!`. `examples/roc-pg` uses the same
`schema.sql` as its migration and as what roc-pg checks against; the tests build it and run it.
From cold, checking it takes 0.8 s, a dev build 1.2 s, an optimized one 6.3 s.

### Jobs and cron: `Job`, `Cron`

```roc
welcome : Job.Kind({ member : I64 })
welcome = Job.define("welcome", |{ member }| { … Email.send!(…) … })    # Ok({}), or Err(why)

# Tried once, within 20 minutes (Job.define: five times, no limit).
reminder = Job.define_with("reminder", { attempts: 1, timeout_ms: 20 * 60_000 }, |{ member }| …)

Job.enqueue!(welcome, { member: 7 }, { when: Now })
Job.enqueue!(welcome, { member: 7 }, { when: At(Time.now_millis!({}) + 60_000) })   # a minute from now
Job.enqueue_keyed!(reminder, { member: "ada" }, { when: Now, key: "reminder:ada" })  # Ok(Queued), or Ok(Exists)
Job.cancel!("reminder:ada")                               # the queued jobs with that key: how many
Job.move!("reminder:ada", At(due))                        # the queued one with that key runs then
Cron.every("0 3 * * *", nightly, {})                      # five fields, UTC; six begin with seconds
```

A job is a row in `rocx_jobs`. Workers (`--job-workers`, 4; none if the app lists no jobs or has no
database) are
background loops (`platform/JobWorker.roc`): each takes the next job due of a kind the app lists
(apps may share a database) with `for update skip locked`, so none is taken twice, and runs it in an
isolated call, so a crash is that job's failure, not the worker's. A job that fails (an `Err`, a
crash, or its time limit passing) runs again, after `--job-retry-ms` (1000), then twice that, and so
on, as many attempts in all as its kind says (`attempts`; five with `Job.define`); then it is
`failed`, with its last error. Queueing one sends `NOTIFY rocx_jobs`, which Postgres delivers when
the transaction commits and the host publishes on the live topic `pg:rocx_jobs`; a worker sleeps on
it (`Live.next!`) until then, or until the next delayed job or retry falls due. A job running when
the server stopped runs again at the next start; done jobs are kept for a week.

**A time limit** (`timeout_ms`, 0 for none) is a deadline on the job's isolated call
(`Host.isolated!` is given it). The first effect that waits past it ends the call, wherever the job
is: a Postgres statement (cancelled, and its connection closed rather than given back to the pool, a
transaction on it with it), a socket's read or write, a request to another server, an actor's
answer, a live topic. The effect doesn't return an error the job could ignore: it jumps back to the
call's guard, as a crash does, so what the call allocated is freed and what it held (its
transaction, sockets, rooms) is given back. The job fails with `timed out after <limit> ms`, and is
tried again if it has attempts left. An actor it asks doesn't share its deadline: the actor's turn
is its own, and ends as it would. Roc that loops without an effect isn't cut off.

**A key** (`enqueue_keyed!`) is one pending job's: while a job with it is queued or running,
queueing another with it does nothing and answers `Exists`; once that one is done, failed or
canceled, the key is free again (a unique index on `unique_key` where the state is `queued` or
`running`). It names what the job is for (`reminder:ada`), so `Job.cancel!` (queued ones become
`canceled`; a running one isn't stopped) and `Job.move!` can find it. Each is a statement, so in a
transaction it stays only if the transaction commits. Cron's jobs are keyed by their schedule and
the second they were due.

**Listing and control**, what the jobs page is made of, and an app may build its own on:

```roc
Job.list!({ state: "failed", kind: "", before_id: 0, limit: 50 })   # List(Job.Row), newest first; "" and 0 for any
Job.get!(id)                       # Job.Row, or NotFound
Job.counts!({})                    # how many of each kind in each state
Job.retry!(id)                     # failed or canceled: queued again, due now, attempts back to none
Job.cancel_id!(id)                 # queued: canceled
Job.run_now!(id)                   # queued for later (or for its next attempt): due now
Cron.schedules!({})                # each schedule, its job, and when it comes round next (next_at)
Cron.run_now!(name)                # the schedule's job, queued now
```

A `Job.Row` is a job's id, kind, input (JSON), state (`queued`, `running`, `done`, `failed`,
`canceled`), attempts and `max_attempts`, key, last error, and its times in milliseconds (`run_at`,
`locked_at` when its last attempt began, `finished_at`, `created_at`). An action on a job in a state
it doesn't apply to is a `JobErr` saying so. `main.roc` alone sees `program`; it keeps the kinds (with
their attempts and time limits) and the schedules in the host's store when the server starts
(`platform/Registry.roc`), where `Cron` and the jobs page read them.

A schedule (`platform/Cron.roc`, `CronTicker.roc`: the parser and the clock are Roc) queues its job
each time it comes round, keyed by the time it was due (its ticker starts from now, so a restart
never queues one twice), tried as many times as its kind says. One it can't read, or whose job the
app doesn't list, stops the server at start.

### The jobs page: `JobsPage`

```roc
# routes/admin/jobs/+server.roc: behind the app's own middleware (only the app knows who is an admin)
middleware = Middlewares.admin
respond! = |{ request, .. }| JobsPage.respond!(request, { mount: "/admin/jobs" })   # every method
```

The platform draws it (`platform/JobsPage.roc`, on `AdminHtml.roc`), as a whole HTML page answered
at `mount`, a console of the queue: how many jobs are queued, running, failed, done and canceled;
what finished in each five minutes of the last hour (done, done after a retry, failed) and the
latest failures; each kind with its attempts, time limit and jobs by state; the schedules, in words
where it can (`daily at 03:00`), with when each comes round next and a **Run now** button; and the
jobs (newest first, fifty a page, **Older** for the next) with their state, attempts, times, key and
last error. A sidebar narrows it to a state or a kind. `?state=failed`, `?kind=…`, `?before=<id>`
choose them; `?id=<id>` opens one job in a drawer over the list: its input, its timeline, its
attempts and time limit, its last error whole. **Retry** (a failed or canceled job),
**Cancel** and **Run now** (a queued one) are plain forms posting to `mount` (`action=retry|cancel|
run_now&id=…`, `action=run_schedule&name=…`), answered with a 303 back to the view they came from;
one that can't be done is a page saying why (409), and a POST another site's page sent is refused
(403, as `Middleware.same_origin` refuses it; the app's own same-origin middleware should run in
front too). It refreshes itself as jobs change: it listens to `mount?events` (a stream of events
that says `changed` when a worker starts or finishes a job, or Postgres says one was queued or
changed: the topics `rocx:jobs` and `pg:rocx_jobs`), and a few lines of script fetch the page again
and put its sidebar and main part in place, keeping an open drawer where the reader was. Without
script it is the same page, with a button that refreshes it. No hydration, no components: it works
whatever the app's pages are made of. Its stylesheet is its own, under the class `rocx-admin`, and
follows the reader's light or dark scheme.

### Email: `Email`

```roc
Email.send!({ to: "ada@example.com", subject: "Welcome", text: "…", html: "<p>…</p>" })
```

With `--smtp-url` (`smtp://user:password@host:587?tls=required`, `smtps://…:465`; or `SMTP_URL`)
it is sent, from `--mail-from` (`MAIL_FROM`), as text, or text and HTML. Without one it is kept in
an outbox in the server's memory and logged, so development sends nothing: the dev mailbox shows it.
At start the server connects to the SMTP server (TLS and all) and logs whether it answers. Send from
a job, so a mail server that doesn't answer is tried again. The client is Roc (`platform/Smtp.roc`,
over `Tcp`): STARTTLS or TLS from the start, `AUTH PLAIN`; a subject that isn't ASCII is encoded, a
body that isn't is sent as base64.

**The dev mailbox.** Under `--dev` the platform answers `/__rocx/mail` itself, before the app
(`platform/Outbox.roc`, from `main.roc`'s `respond_for_host!`): the email kept, newest first (when,
from, to, subject), a **Clear** button (`POST /__rocx/mail/clear`), and each message at
`/__rocx/mail/<id>`: its headers, its text, its HTML in a sandboxed frame (`<iframe sandbox
srcdoc>`: no script runs in it, a link opens in a new tab), and the message whole, as SMTP's DATA
would have carried it. The list updates as mail comes (a stream of events, `/__rocx/mail?events`,
on the live topic `rocx:mail`). The last 100 are kept in the server's memory (`Kv`, under
`rocx:mail`), database or not, so a restart forgets them (D-028). The JSON (oldest first: id, at, from, to,
subject, text, html, raw) is at `/__rocx/mail.json`, and at `/__rocx/mail` when asked for
(`accept: application/json`); with `--debug` alone (the tests), only the JSON is served. Without
`--dev` or `--debug`, those paths are the app's.

### Requests to other servers: `Http`

```roc
weather = Http.fetch!("${api}/forecast", { query: [("city", city)] })?.json()?

granted : { access_token : Str }
granted = Http.fetch!("https://oauth2.example.com/token", { method: Post, body: Http.form([("grant_type", "authorization_code"), ("code", code)]) })?.json()?

authed : Http.Init
authed = { headers: [("authorization", "Bearer ${granted.access_token}")] }
placed = Http.fetch!("${shop}/orders", { ..authed, method: Post, body: Http.json(order) })?
res = Http.fetch!("${shop}/orders/${id}", { ..authed, method: Delete })?
if (res.ok) res.text() else …

# a document someone else names: 5 s, 5 KiB, a redirect is the answer
doc = Http.fetch!(url, { timeout_ms: 5_000, max_bytes: 5_120, redirect: Manual })
```

`Http.fetch!(url, init)` is JS's `fetch`, waiting for the whole answer (D-024). `init` (an
`Http.Init`) has a default for every field, so `{}` is a GET: `method` (`Get`, `Post`, `Put`,
`Patch`, `Delete`, `Head`, `Options`, `Other(Str)`), `headers` (`(name, value)` pairs), `query`
(pairs percent-encoded onto the URL, after an `&` if it has a query already), `body` (`Empty`),
`timeout_ms` (30 s; 0: none), `max_bytes` (64 MiB; 0: any) and `redirect` (`Follow`, or `Manual`:
the redirect is the answer). A record kept to build on is annotated `Http.Init`, so a record update
can add to it. The body's helpers set its `content-type` unless `headers` has one:
`Http.json(value)` (`application/json`), `Http.form(pairs)` (`application/x-www-form-urlencoded`),
`Http.plain_text(text)` (`text/plain; charset=utf-8`) and `Http.bytes(list)` (none, as `fetch`
sends a `Uint8Array`).

Any status is an answer (`Ok`), an `HttpResponse`: `res.status`, `res.ok` (2xx), `res.headers`
(names in lower case), `res.header(name)` (in any case), `res.text()` (UTF-8, lossy),
`res.json()` (the type wanted, as `Json.parse` reads it: `Err(InvalidJson(why))` if it isn't) and
`res.bytes()`. An `Err` means there was none: `HttpErr(why)` (the address, the connection, TLS, HTTP
itself, a header with a line break), `TimedOut` (no whole answer in time, from connecting to the
body's last byte), `TooLarge` (a body over the limit: refused by its `content-length`, or as it
passes it).

The API before `fetch!` (`Http.Request`, `Response`, `Opts`, `defaults`, `send!`, `send_request!`,
which was `fetch!(request)`, `get`, `post_form`, `post_json`, `with_header`, `header`, `text`)
still works, deprecated: each is `fetch!` underneath, and goes in a later release.

The host makes it (`host/src/client.rs`): hyper's HTTP/1.1 client, a connection a request, over
rustls checked against `webpki-roots`, the call paused while it waits, as `Db` and `Tcp` do. Redirects
are followed as `fetch` follows them, twenty at most: a relative `location` against the URL it
answered; a 303 (or a 301 or 302 to a POST) becomes a GET without its body; `authorization` and
`cookie` don't go on to another origin. `host` and `content-length` are added unless given; nothing
is decompressed (send `accept-encoding` and the body is as the server sent it). An answer to a HEAD
has no body, so its `content-length` is never too large.

### Files in S3: `packages/s3`

Any S3 (rustfs or MinIO in development, R2 or AWS in production) is a package, on no platform
(D-025). An app makes a bucket from a URL it keeps in its environment and the two effects the
package needs, the platform's own. The package names no platform, so it can't name `Http.Init` or
`HttpResponse`: it is given `Http.send!`, the deprecated shape, whose records it writes out (D-024).

```roc
# main.roc's header: s3: "../packages/s3/main.roc"
bucket = S3.from_url(Env.var!("STORAGE_URL") ?? "", { send!: Http.send!, now!: Time.now_millis! })?
S3.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?
S3.serve!(bucket, "videos/${id}", request, { content_type: "video/mp4", cache_control: "private" })   # an answer
```

`S3.serve!` answers with a `Forward` (below), so the server streams the object from S3 and it never
comes into Roc. `packages/s3/README.md` has the rest: the URL, every operation, the errors, and the
limits.

### Bytes: `request.body`, `Server.bytes`

```roc
Server.text_of(request)                  # the body as text (UTF-8; U+FFFD where it isn't): JSON, a form
S3.put!(bucket, "images/${id}", request.body, { content_type: "image/jpeg" })?  # the bytes as they came
Server.bytes(200, [{ name: "content-type", value: "image/jpeg" }], cover)       # sent as they are
```

A request's body is `List(U8)`, never decoded on the way: an upload is the bytes the client sent.
`Server.text_of` reads it as text, and an endpoint's JSON or form is read through it, so an
endpoint that takes JSON doesn't change. An endpoint reads its body only when it says it is JSON
(`application/json`, or a type ending `+json`) or a form; an upload of any other type (or of none)
gives its handler `{}`, and the handler reads `request.body`. A body it doesn't read, sent to a
handler that wants an arg, is a 415. A very large answer is better a `Forward` (below) than
bytes: those are held whole. `Server.request!({})`, the request a page or an endpoint is
answering, comes over from the host as text, so its body is `text_of`'s. An answer of
`Bytes` is sent as it is; `Server.body_text` reads one as text.

### Bodies from elsewhere: `Server.forward`

```roc
upstream = { method: "GET", url: "https://cdn.example/videos/41.mp4", headers: Server.passed_on(request) }
Server.forward(upstream, [{ name: "content-type", value: "video/mp4" }, { name: "cache-control", value: "private" }])
```

A `Forward` answer's body never passes through Roc: the host makes the request (`host/src/client.rs`'s
`open`, redirects followed) and sends the answer on as it comes, so a 500 MB video costs Roc nothing
and starts at once. Upstream's status is the answer's (200, 206 for a range, 304, 404…), with its
`content-type`, `content-length`, `content-range`, `accept-ranges`, `etag` and `last-modified`; the
answer's headers are added, or replace those (the answer's own status is a stand-in). Upstream is
sent `upstream.headers` and nothing else: the host adds nothing of the request (its cookies stay
here, and so do its range and its cache's questions). `Server.passed_on(request)` is the request's
`Range`, `If-Range`, `If-None-Match` and `If-Modified-Since`, as the request record has them, for
the upstream's headers; an app that changes the record (drops a range that doesn't fit) changes
what is asked. A HEAD gets the headers and no body.

An error upstream (400 or more) is answered with its status and its reason (`Not Found`) as text,
never with what upstream said (S3's XML names the bucket), nor with the answer's headers, which
describe the body it would have been; a `416` keeps its `content-range`. Upstream not answering, a
URL that isn't `http` or `https`, or a redirect that can't be followed, is a 502 (a 504 after 30 s
without its head). Those are logged, without the URL's query (a presigned URL's signature is
there), as is an error upstream other than a 404 or a 416. Once the body flows, a piece may take 60
s to come; if upstream stops short, the client's connection is closed, so a cut body is never
passed off as whole. packages/s3's `S3.serve!` is a `Forward` to S3.

### Cookies: `Server.set_cookie`

```roc
Server.set_cookie(answer, "__Host-session", token, { ..Server.cookie_defaults, secure: Bool.True, max_age_s: 30 * 86_400 })
Server.set_cookie(answer, "review", token, { ..Server.cookie_defaults, expires_ms: link.expires })   # until then
Server.clear_cookie(answer, "__Host-session", { ..Server.cookie_defaults, secure: Bool.True })
Server.with_cookie(answer, "member", name)               # set_cookie with cookie_defaults
```

`Server.CookieOpts` is `Set-Cookie`'s attributes: `max_age_s` (`Max-Age`) and `expires_ms`
(`Expires`, a moment in milliseconds since the epoch), each left out at 0, and with neither the
cookie ends with the browser; `secure`, `http_only`, `same_site` (`Lax`, `Strict`, `None`), `path`
and `domain` (each left out when empty). `Server.cookie_defaults` is `/`, `HttpOnly`,
`SameSite=Lax`, this host alone, until the browser closes, over HTTP too. A `__Host-` cookie needs
`secure`, `path: "/"` and no domain; `SameSite=None` needs `secure`; browsers drop one without.
`clear_cookie` is given the path, domain and `secure` it was set with. The value is `%XX`-encoded
(`Server.cookie` decodes it). These are the web platform's too (`web/platform/Server.roc`).

### Forms: the flash, `Endpoint.respond!`

```roc
# routes/members/join/+server.roc: a form posts { name }
post! = |{ body, .. }| if body.name.trim().is_empty() Err(BadRequest("a member has a name")) else Ok("Welcome, ${body.name}")

# the page it was posted from
Server.flash!({})      # Ok({ url: "/members/join", fields: [{ name: "name", value: "" }], status: 400, body: "a member has a name" })
```

A form a browser posts without the runtime (a plain `<form method="post">`: a form's body,
`application/x-www-form-urlencoded`, from a page, `accept: text/html`) would get a page of JSON, or
of text, from its endpoint. `Endpoint.respond!` sends neither: for its result, its refusal, or a
body it can't read (400), it answers `Server.flash_back`: a 303 to the page the form was posted
from (`Referer`, when it is this site's; `/` otherwise), with the cookie `rocx-flash` (the URL it
posted to, the form's body as posted, the status and the body: `Path=/; HttpOnly; SameSite=Lax;
Max-Age=60`; past what a cookie may hold, ~3.8 KB, the fields are left out and the answer kept). An
answer of the endpoint's own (`Err(Answer(…))`: a redirect that sets a cookie) is sent as it is.
The page the browser lands on reads it with `Server.flash!({})`, or as its form's submission
(`Router.use_submission!(endpoint)`, which is the flash when it is that endpoint's): what was typed,
and the result or the refusal. The host notes the flash a page read in `<script
type="application/json" class="rocx-flash">`, before the answers, so the browser renders it as the
server did. `App.program` lets it go with that page (`Server.clear_flash`: a browser's next GET of
a page clears the cookie, read or not), so a reload doesn't show it again; an app that writes its
own program calls `Server.clear_flash(request, answer)` itself.

With the runtime, a form whose page reads its submission is sent with `fetch` instead
(`x-rocx-submission: 1`, `accept: application/json`): it gets the endpoint's result as JSON, or its
refusal, and an answer of the endpoint's own that redirects comes back as 200 with
`x-rocx-redirect` (fetch would follow a 303 before the runtime could read it), its cookies kept,
for the runtime to go there. A script's post (JSON, or a form not for a page) gets the endpoint's
answer as always. So does an action (`Router.use_action!`, D-030): the browser's runtime sends its
arg as JSON, with `x-rocx-submission: 1`, and a result has it read the page's reads again
(`Endpoint.get!`'s GETs); the server sees plain requests, and an endpoint that answers one with its
own `Err(Answer(…))` (a cookie set along with its JSON, as the docs site's planner keeps a reader's
week) is sent as it is.

### Settings: `Env`

```roc
origin = Env.var!("ORIGIN") ?? "http://localhost:8080"     # Try(Str, [NotFound])
if (Env.dev!({})) dev_sign_in else Server.refused(404, "No page here.")     # started with --dev
```

`Env.var!` reads the server's environment: the app's secrets and what differs between machines,
read alike in a request, a job or a schedule (twelve-factor; Phoenix's `runtime.exs`). The context
file stays for what a request is given. `Env.dev!` says whether the server was started with
`--dev`. The platform's own settings stay flags or their variables (`DATABASE_URL`, `SMTP_URL`, …).

### Time: `Time`

`Time.now_millis!` and `Time.now_nanos!` (D-026) read the clock. `Time.sleep!(ms)` waits: the call
pauses and holds no thread (D-027), so a request that waits on purpose (a retry's pause, a demo's
slow endpoint) holds up only itself; a job's time limit ends its wait.

### Sockets and randomness: `Tcp`, `Random`

`Tcp.connect!(host, port)` (or `connect_tls!`, or `start_tls!` on an open one) opens a socket for the
call; `write_bytes!`, `read_exactly!`, `read_up_to!` and `read_until!` use it, the call paused while each
waits (10 s to connect, 60 s for each read or write): tokio's sockets, and tokio-rustls for TLS,
checked against `webpki-roots`. A socket the call leaves open is closed when it ends. A socket is the
call's alone: the host keeps it in the table of the thread the call runs on, taken out while the
call is paused, so nothing about it is locked or shared, and its id means nothing to another call. `Random.seed_u64!` and
`Random.bytes!(count)` are the operating system's randomness (`ring`); if it gives none, the call
crashes rather than make a key of anything less.

### Crypto: `AesGcm`, and `packages/crypto`

```roc
sealed = AesGcm.seal!(app_key, plaintext)?                         # nonce ++ ciphertext ++ tag
opened = AesGcm.open!(app_key, sealed)                             # Try(List(U8), [BadKey, Forged])
```

`AesGcm` is the host's (`ring`'s AES-256-GCM): a 32-byte key (`BadKey` otherwise) and a fresh
random 12-byte nonce each seal; what it seals is Web Crypto's output with the nonce in front, so
either opens the other's. Its key comes from `Random.bytes!`, or from the app's secret through HKDF.

The rest is Roc with no effect, so it is a package on no platform (`packages/crypto`, D-025), which a
page in the browser may use too: `Sha256`, `Hmac` (with a comparison in constant time), `Hkdf`,
`Base64` (both alphabets, strict) and `Hex`, each checked by `expect`s against its published vectors
(NIST, RFC 4231, RFC 4648, RFC 5869).

### Values in memory: `Kv`

```roc
Kv.set!("cache:${url}", page, { ttl_ms: 60_000 })                  # any type JSON writes; 0: until a stop
page = Kv.get!("cache:${url}")?                                     # Try(value, [NotFound, BadValue(Str)])
tries = Kv.increment!("login:${address}", 1, { ttl_ms: 60_000 })?   # a window a minute long
Kv.add!("seen:${request_id}", {}, { ttl_ms: 86_400_000 })?          # Err(Exists): one request gets in
state = Kv.take!("oauth:${given}")?                                 # good once
Kv.push!("email:outbox", message, { keep: 100 })                    # a capped list, newest first
Kv.list!("email:outbox")?
```

Values by key, kept in the server's memory for as long as `ttl_ms` says (0, the default: until it
stops), never written anywhere: for what is cheap to lose and read on every request. A value is kept
as JSON and read back as the type its reader asks for. Each operation is atomic, and a new counter's
or list's time to live starts with it (later increments and pushes don't move it). The host keeps one
map behind one lock (`host/src/kv.rs`; nothing is awaited while it is held), expired entries going at
the next operation; past `--kv-max-mb` (64) the least recently read or written go, never the one
just written. Keys name their owner first, by convention (`email:outbox`).

### Live: `Live`

```roc
# Who is here: each stream counts until it ends, and hears when others come and go.
Events.stream(|{ send!, .. }| {
    Live.join!("online")
    var $open = Bool.True
    while $open {
        send!({ online: Live.count!("online") })?
        $open = Live.next!(15_000) != Gone       # Heard(…), Quiet after 15 s, or Gone
    }
    Ok({})
})
```

Topics carry messages (`Live.publish!`, `Live.listen!`, `Live.next!`) to every call listening;
rooms count who is in them (`Live.join!`, `Live.count!`), and tell those in them `join` and `leave`.
What a call joins or listens to lasts until it ends: a stream's, until its client goes, or it
crashes. It is all in the server's memory.

### Channels: `channel!`, `Endpoint.subscribe!`, `Endpoint.publish!` (D-020)

```roc
# routes/org/[org]/news/+server.roc: behind the route's middleware, which hands on who is asking
channel! : { request : Server.Request, params : { org : Str }, context : Member } => Try(Channel(Str, News, [Hello(Str)]), Endpoint.Refusal)
channel! = |{ params, context, .. }| if context.org == params.org Ok(Channel.allow(context.name)) else Err(Forbidden)

receive! = |{ who, said, channel, .. }|        # what a page says: Endpoint.say!(channel, Hello("hi"))
    match said {
        Hello(words) => Ok(Endpoint.publish!(channel, { title: "${who} says ${words}" }))
    }
on_open! = |{ who, .. }| [{ title: "welcome, ${who}" }]   # sent first, after each Resync
on_close! = |{ who, tab, why, .. }| Log.info!("left", { who, tab })   # why: Gone, or Refused(why)

# anywhere on the server: a request, a job, an actor
Endpoint.publish!(Api.channel_org_org_news({ org: "acme" }), { title: "Launch" })
Endpoint.publish_latest!(Api.channel_rooms_room({ room }), member, cursor)   # only the newest per key
```

A channel is a route's `channel!` (`Channel(who, message, said)`): its check answers who the
subscriber is, or a refusal. `rocx build` puts it in `Generated/Api` (`Api.channel_<path>(params)`,
method `CHANNEL`), and pages subscribe to it with `Endpoint.subscribe!` (web/README.md). Its hooks,
each optional: `receive!`, what pages say, after the same middleware and check; `on_open!`, what a
subscriber is sent first, each time it subscribes; `on_close!`, told when a subscription ends,
outside the middleware. Each is given the path's params, `who`, the tab's id, and the channel.

The host answers the tab's stream itself, on the async side, holding no thread of Roc's
(`host/src/channels.rs`): `GET /rocx/live?tab=<id>&c=<url>&c=<url>…`, as server-sent events.

- Each channel's check runs as the stream opens: a request the host makes of the app for the
  channel's own path, with the stream's headers (its cookies), `accept: application/json` and
  `x-rocx-channel: open`, behind the app's middleware and the route's, as a GET of it would be. A
  refused one is `event: refused` and the stream goes on for the others. One let in is
  `event: resync`, then its `on_open!` messages, then what is published on it. Its topic is listened
  to before its check runs, so nothing published meanwhile is missed (a message may come twice
  around a resync: a subscriber reads its data again on `Resync` anyway).
- Every beat (`--live-beat-ms`, 15 s) the stream sends `: beat` and runs each channel's check again
  (`x-rocx-channel: check`); one that now refuses is `event: ended`, and its `on_close!` is told
  `Refused(why)`. A server error (500) at a beat ends nothing.
- `POST /rocx/live/send?tab=<id>`, a JSON list of `{"channel":"<url>","message":…}` (the route's
  `receive!`, after its middleware and check: `x-rocx-channel: receive`) and
  `{"channel":"<url>","resync":true}` (the tab's stream resyncs that channel): 204, or 200 with
  `{"refused":[{"index":…,"status":…,"why":…}]}`. JSON only, so a form from another site can't send
  it without asking first.
- A subscription's end (the client gone, the server stopping, or refused at a beat) is
  `x-rocx-channel: close`, its body who the check said it was and why: `App` answers it outside the
  middleware, with the route's `on_close!`.
- The host drops `x-rocx-channel` and `x-rocx-tab` from every request it is sent, so only it asks.
- `/rocx/live` never reaches the app's middleware, so an auth middleware has nothing to let
  through: a channel is guarded by its own path's middleware instead.
- Order: a channel's messages arrive in the order they were published (`Live`'s order per topic, one
  queue per stream). One that falls behind its topic's backlog (256) gets `resync` instead of what it
  missed. `publish_latest!` messages are a topic of their own, `latest:<url>`: a subscriber behind
  gets only the newest per key, never a resync, and they aren't ordered with the others.
- A client whose network went: the host sets a 20 s deadline on what it sent going unacknowledged
  (`TCP_USER_TIMEOUT` on Linux, `TCP_RXT_CONNDROPTIME` on macOS), so a beat's write ends the stream
  about 35 s after the client vanished, and `on_close!` is told `Gone`.
- Published on `Live` topics (`channel:<url>`, and `latest:<url>` for `publish_latest!`), in the
  server's memory.

### Actors: `Actor`

```roc
cart : Actor.Kind({ items : List(Str) }, [Add(Str), Clear], U64)
cart = Actor.define({
    name: "cart",
    initial: |_key| { items: [] },
    receive!: |_me, state, message|
        match message {
            Add(item) => { state: { items: state.items.append(item) }, reply: state.items.len() + 1 }
            Clear => { state: { items: [] }, reply: 0 }
        },
})

count = Actor.ask!(cart, member, Add("a book"))?   # waits for the reply
Actor.tell!(cart, member, Clear)                    # doesn't
timer = Actor.tell_after!(cart, member, 60_000, Clear)
Actor.cancel!(timer)
```

An actor is a kind and a key, and nobody makes or ends one: a message to any key finds it as its
last message left it, or new (`initial(key)`, the kind's starting state: no message of its own). It
handles one message at a time, in the order they came: each actor that is awake has a mailbox in
the host (`host/src/actors.rs`). One task, the router, owns the table of actors that are awake and
the timers, and passes every ask, tell and timer to its actor's mailbox; each actor is a task of its
own that runs its turns one after another, each a call into Roc of its own (`actor_for_host!`).
Nothing in it is locked: the router's table is its alone, and the tasks talk over channels
(`tokio::sync::mpsc`, unbounded, and `oneshot`). So what one sender sends an actor is handled in
the order it was sent, and a hundred asks at once each see the state the one before left.

`receive!` is given the actor itself (`Me`): its key (`Actor.key_of`), and its own timers
(`Actor.after!(me, ms, message)`, typed as the kind's messages are; a timer every so often is one
that sets the next). `rocx build` lists the kinds an app's modules define (`Actor.define`, at the top
of a module's block, `name` first) in `program.actors`; the host refuses a message to a kind not
there. Messages, replies and state cross to the host as JSON: a message an actor doesn't take (it
doesn't parse as its kind's: a caller built against an older kind, say), a kind the app has none
of, and a crash in `receive!` are logged as errors (`rocx actor: a message failed`, with `actor`,
`key` and `error`) and told to the asker, and the actor goes on with its state as it was.

With a database, an actor's state is read from Postgres (`rocx_actors`) by its first turn and
written after each turn that changes it, so it is there after a restart. An actor idle for
`--actor-idle-ms` (15 minutes) is let go: it tells the router, which lets it go if nothing was sent
to it meanwhile, and the next message wakes it as Postgres has it. Without a database, its state is
in its task alone, and it stays awake. An actor may ask another: one that asks itself, or any actor
whose turn waits on its answer up the chain of asks, is refused at once; an ask not answered in
30 s (a cycle through two mailboxes) is given up on, and a message whose asker gave up before its
turn came is dropped, with a warning. Tells and timers are in memory: a restart loses those not yet
handled (a job is for work that must survive one).

### Pages of components

A route that answers `{ status, headers, body: Page(view!) }` has the host render the page for the
request (`render_page` in `host/src/signals.rs`), in the call that answered it: its box runs at
the root (`roc_run`), in a call guarded with the answer's own list of allocations, and the markup it
gives is walked (`host/src/signals.rs`), as the browser's runtime (`web/runtime.js`, its
`renderToString`) renders it, byte for byte (the site's tests compare the two): every hole run once, a memo computed when it is made,
`<Loading>` rendering what is inside it, a failure showing the nearest `<Errored>`, an endpoint a
component reads (`Endpoint.get!`) answered by its route, in-process, and noted. The answer is the
document: `<!doctype html>` first (unless the page's markup begins with one, `Html.doctype`), and
just before `</body>` the answers its reads got (`<script type="application/json"
class="rocx-answers">`) and `<script type="module" data-rocx src="/rocx/start.js">`, which hydrates
it in the browser. It is `text/html; charset=utf-8` unless the answer says otherwise, and its status
is the answer's, or the one the page set as it rendered (`<HttpStatusCode code={404} />`,
`Host.status!`). A HEAD isn't rendered: the answer's status and headers, and the page's box
released. A crash, or a failure no `<Errored>` catches, is a 500 (with the message under `--dev`).
Effects, cleanups and timers (`create_effect!`, `on_settled!`, `on_cleanup!`, `set_interval!`,
`set_timeout!`) don't run on the server, as in Solid: their boxes are let go of, since nothing they
would undo started; `is_pending!` is false. A `<NoHydration>` is markup only the server renders:
written between its own markers with none inside, and left as it is by the browser. A flash the
page read (`Server.flash!`) goes in a script before the answers. The title the last `<Title>`
rendered said (`Host.title!`) goes first in `<head>`, as `<title data-rocx>…</title>` before the
layout's own `<title>` (`titled`, as `web/runtime.js`'s `Runtime.titled`), which hydration passes
over, so the layout's `<head>` hydrates as it rendered. Inside `<title>` and `<textarea>`,
whose content the HTML parser reads as text (RCDATA), holes are written without their comments,
which would show; the browser binds them to the element's text. A read that its middleware
answers with a redirect (a status from 300 to 399 with a `location`: a signed-out visitor sent to
sign in) makes the page that redirect, caught by an `<Errored>` or not, with the cookies it sets
(SolidStart answers a redirect thrown while it renders so). Any other failure fails its
computation; in the root layout, where no boundary is above it (the root `<Errored>` is inside it),
that is a 500, so a layout whose holes read the server puts its own `<Errored>` around them: the
endpoints it reads answer every page's visitors.
Whatever the render made, the page's box and what the answer held are freed when it ends, crash or
not.

### Endpoint reads, as a page renders

A component reads a GET endpoint with `Endpoint.get!` (or `Endpoint.read!`, its refusal a value;
`Endpoint.with_query` adds a query), which asks the host (`Host.fetch!`, `roc_fetch` in
`host/src/signals.rs`). While the host renders a page, a GET of one
of the app's own paths (`/…`) is that request, made in-process and answered by the app's `respond!`
as the browser's GET would be, behind the route's middleware: the page's headers (cookies among
them, `origin` this host), `accept: application/json`, the context the server started with, and its
own guard and allocations. Its answer, whatever its status, is `{"status":…,"body":…}`, kept for the
render, so a URL is asked once, and noted for the page under `GET <url>`, unless it was read inside a
`<NoHydration>`. A crash in it is a 500 (why, under `--dev`), logged; an answer that is a stream of
events, a page or a body from elsewhere isn't one to read, and fails the read. Any other request (a
POST, another site's URL) is a handler's, sent from the browser: the render fails it.
`Host.request!` is the request being answered, whole; `Host.location!` its path and query
(`Router.location!`), and `Host.status!` the status its page is to be answered with
(`<HttpStatusCode>`, for pages of components).

The modules components are written with are the browser's platform's (`web/platform`), copied into
this one by the build (`server/build.mjs`), so the same components compile on both. An endpoint's
handler runs only here, so it may use `Db`, `Job` and the rest: in the browser's copy, `Api` is each
endpoint's method and URL, and a route file has no middleware.

### The log: `Log`

```roc
Log.info!("gate failed", { path: request.path, error: why })   # also debug!, warn!, error!
Log.line!("migrated")                                          # a message alone, at info
```

```
14:03:12 INFO  gate failed error="no session" path=/admin
{"time":"2026-11-21T13:03:12.345Z","level":"info","msg":"gate failed","error":"no session","path":"/admin"}
```

Every line the server writes to stderr is an event: a level, a message and fields. The host's own
lines (`rocx server: http://… (Roc, native)`, stopping, a crash with its `method`, `target` and
`error`, forwarding, a background loop that crashed), the platform's Roc's (jobs, cron, mail,
migrations: `Log.line!` for now) and the app's all go through one formatter in the host.
The fields are any record (`Json.Encodable`), written as JSON; `{}` is none; one record with a
single field has to say its name twice (`{ id: id }`: `{ id }` alone is a block, which is `id`).

The format is the app's to choose: `program.logs`, `{ format: Auto }`, `Pretty` or `Json`
(`App.program` says `Auto`; `{ ..App.program({ … }), logs: { format: Json } }` says otherwise).
`Auto` is `ROCX_LOG` (`pretty` or `json`) if it is set, or else pretty when stderr is a terminal
and JSON when it isn't (a server whose log is collected). The host starts in `Auto`, so what it
logs before the platform starts (a server that can't) follows it, and takes the app's format at
`init_for_host!` (`Host.log_format!`). Pretty: the local time, the level (coloured on a terminal),
the message, then `key=value`, a value quoted when it has a space, a quote, an `=` or a control
character in it, or is empty (objects and lists are their JSON). JSON: `time` (RFC 3339, UTC),
`level` and `msg`, then the fields beside them; a field named `time`, `level` or `msg` is written
`fields.time` (and so on) in both, so it can't take their place. A line is always one line.

Logging is off the request path. `Host.log!` (Roc's level, message and fields' JSON) and the host's
own calls put a record on one queue and return; one thread takes them in order, formats them (Roc's
fields are parsed there), and writes them through a 64 KiB buffer that it flushes whenever the queue
is empty: a line is out at once on a quiet server, and lines go out together on a busy one. One
queue, first in first out, so a request's lines come out in the order it logged them, and whole.
The queue holds 64k events; when it is full, a call that logs waits for room rather than dropping a
line (a log that loses lines when the server is busiest loses the ones most worth reading; one that
grows without bound turns a flood of lines into a server out of memory), which slows callers to
what stderr takes. The queue is flushed before the process exits: after a stop, after a server that
couldn't start, before an abort (a crash outside a guarded call, out of memory), and on a panic
(itself an event, `rocx server: the host panicked`). `--help` prints its usage as it is.

### Plugins: `Plugin` (D-033)

```roc
# main.roc: the header names the package, `plugins` lists what it adds
app [program] { pf: platform "../server/platform/main.roc", acme: "../packages/acme/main.roc" }

import acme.Acme

program = App.program({ context, middleware, crons: [], plugins: [Acme.plugin({ at: "/acme" })] })
```

A plugin is a `Plugin.Value(ctx)`: a name, and what a package adds to the app, every field but the
name defaulting to `[]`. `routes` answer behind the app's middleware, before its own routes (`ctx`
is what that middleware hands on: a plugin's routes get it without knowing its type); `early` paths
are answered before the app, under `/__rocx/`, only with `--dev` or `--debug`; `migrations` are
applied after the platform's and before the app's, recorded as `<plugin>/<name>`; `calls` run in a
call of their own (`Plugin.isolated!("acme.render", input, limit_ms)`), so a crash ends only that;
`loops` run in the background until the server stops (`Plugin.stopping!`); `starts` run after the
migrations (an `Err` stops the server); `checks` run once in the background, what they say logged;
and `needs` (`Env("ACME_KEY")`, `Database`, `Plugin("other")`) are checked at start. Calls, loops
and checks are named `<plugin>.<name>`. A package makes its plugin from options of its own (a
nominal record whose fields without a default are required), and a plugin generic in the app's
context is a function even with none (`Acme.plugin({})`).

At start, every problem with the plugins stops the server, all of them, a line each: a name used
twice or not lowercase letters, digits and `-`; a call, loop or check without the plugin's name
first; an early path outside `/__rocx/`; two routes at one method and path (the app's, which
`rocx build` lists in `Routes.claims`, and a plugin's, or two plugins'); a variable unset, no
database, a plugin not in the list, or needs in a circle. Then the plugins are ordered by their
needs, and the log says what each added (`rocx plugins: acme: 2 routes, 1 migration`).

A package whose modules use the platform names it in its header, as an app does
(`package [Acme] { pf: platform "../../server/platform/main.roc" }`): it must be the same file the
app names. Modules both halves can compile go in a second header beside it, `browser.roc`, which
`rocx build --client` names for the browser's half instead (without one, the browser's half doesn't
see the package, and a page that imports it is told where). `server/test/fixture` is a plugin
package, for the tests.

## How a call runs

Roc runs on threads of its own, as many as the machine has cores (`--roc-threads`, or
`ROCX_ROC_THREADS`, says otherwise), beside tokio's, which answer HTTP and drive every socket and
timer (D-027, `host/src/coroutine.rs`). Each call into Roc (a request and the page it renders, a
stream, an actor's turn, a background loop, the platform's start) is a stackful coroutine on one
of them, with a stack of its own (8 MiB, Roc's default, reserved rather than used, above a guard),
started by whichever of Roc's threads is free and kept on it until it ends. When an effect waits
(Postgres, a socket, another server, a sleep, an actor's answer), the call pauses: its stack stays
as it is, its thread runs other calls, and tokio wakes it when what it waits on is done. So a call
that waits holds no thread, and any number can wait at once: eight requests that each wait 0.3 s on
Postgres take about 0.3 s together, and the tests answer 2,000 requests that each wait a second, on
two threads, in about a second. What the host keeps per call in thread-locals (its context, Roc's
list of allocations and jump target, the page it renders, its sockets) is taken out while it is
paused and put back when it resumes; a call never moves to another thread (compiled code may keep a
thread-local's address across a call).

A stream of events is a loop (`Events.stream(|{ send!, sleep! }| …)`), a call of its own for as
long as it is open: `send!` writes to the response (pausing while the client reads slower than it
writes), `sleep!` pauses, waking early if the client goes, so its next `send!` answers `Err(Gone)`
and `?` ends the loop. An open stream, or a background loop, holds no thread while it waits: the
tests hold 2,000 `events!` streams open on two threads and a request still answers at once. A
channel stream (`/rocx/live`) isn't a call at all: the host keeps it, and Roc runs only for a check
or a hook, a call at a time.

What it costs: Roc that computes for long without an effect (a long pure loop) can't pause, so the
calls on its thread wait for it (new calls go to Roc's other threads, which take them from one
queue). A paused call keeps its stack: only the pages it touched cost memory, a few tens of KiB for
most. Profilers and debuggers see calls on stacks of their own, not threads'. A call that overflows
its stack hits the guard below it and the process ends, as a thread's overflow did; first it says
so on stderr (`rocx server: a call into Roc overflowed its stack (8 MiB): the process ends`, in the
log's format). Logging is the one wait that blocks a thread rather than pausing a call: when the
log's queue is full, a call waits for room (above).

A crash ends the call it happened in, not the server. Roc's ABI says `roc_crashed` must never
return: it may end the process or `longjmp` out of the Roc code that called it. The guard
(`host/src/guard.c`) sets a jump target around every call; `roc_crashed` jumps back to it, and the
request is answered 500 (with the message under `--dev`), a stream ends, or a job runs again later.
What the call had allocated is freed: while a call runs, each allocation is linked into a list; if
the call returns, the answer's strings are copied out and freed, a stream keeps its list until
the call that sends it, and a page keeps its list while it renders, with what its computations make
in it, and frees all of it at the end (a computation that fails may never give back its reference
to the box it ran, in Roc's optimized code: the list frees that box anyway); if a call crashes,
everything in its list is freed. The tests crash 200
requests at once, half after allocating 2,000 strings, and check that Roc holds no allocations
afterwards (`--debug`, `GET /__rocx/allocations`). Calls nest (an isolated call: `Host.isolated!`,
a job inside its worker), each with its own list, jump target and context; the frames a crash skips
are Roc's and a trampoline's, never the host's. What a call holds (a transaction, sockets, rooms) is
given back when it ends. An isolated call is passed strings, which it copies, so a crash frees all
it was given; so is an actor's turn (its kind, key, state and message), a call of its own that its
actor's task starts. An isolated call may be given a time limit
(a job's): the calls it runs share its deadline, and the first effect that waits past it ends the
call as a crash would (`cut_off` in `host/src/hosted.rs`), so the only frame it skips that is the
host's is that effect's own, which holds nothing by then.

At start the host asks the platform's Roc which background loops to run (`roc_background_count`:
the job workers, cron's ticker, and a look at the SMTP server) and runs each, a call of its own,
until the server stops; one that crashes is started again a second later. `Live.next!` in one wakes
with `Gone` when the server stops.

A value Roc makes belongs to its call until the call returns; after that the host owns it and moves
it (a stream to the call that sends it), never sharing it. Roc's reference counts are
atomic in LLVM builds anyway (`ldadd`/`ldaddal` in the app's object code).

Starting, the host takes its address first: a port in use stops the server there (`Address already
in use`, exit 1), before the database, the platform's start or the background loops, so nothing is
left running into a runtime that is shutting down. Stopping (SIGTERM, or ^C): the server stops
listening and taking jobs, and waits up to ten seconds for the requests, streams and jobs still
running.

## Building

`server/build.mjs` builds the host with cargo (the one on PATH, from Nix say, or else `.tools/rust`,
from `just setup`) into `server/platform/targets/<target>/libhost.a`, then the app with `roc build`
(the Roc fork `just setup` links as `.tools/roc-active`), which links the two
into one executable. `arm64mac` and `x64mac` link against the system; `arm64musl` and `x64musl` are
static Linux executables, cross-compiled from macOS: Rust's own musl target supplies `rcrt1.o`,
`libc.a` and `libunwind.a`, and Zig compiles the host's C (and `ring`'s, for TLS). The test app
built `--target=arm64musl` runs in a container against `just db`'s Postgres, every part of it.

`just glue` regenerates `host/src/roc_platform_abi.rs` after a change to the header.

## Running

```
<app> --port 8080 --host 127.0.0.1        where to listen (PORT)
      --static DIR, --file /PATH=FILE     files served as they are
      --context-file FILE                 what respond! is given besides each request
      --database-url URL                  Postgres (DATABASE_URL): Db, migrations, jobs, cron, actors
      --job-workers 4 --job-retry-ms 1000 jobs run at once; the first retry's wait, doubled after
      --actor-idle-ms 900000              an actor idle this long is let go (0: never; kept in Postgres)
      --smtp-url URL --mail-from ADDRESS  (SMTP_URL, MAIL_FROM); none: an outbox
      --kv-max-mb 64                      Kv's limit (KV_MAX_MB): the least recently used goes past it
      --dev                               reload pages on restart, show crashes, the mailbox at /__rocx/mail, Env.dev!
      --debug                             GET /__rocx/allocations, and the mailbox as JSON
      --live-beat-ms 15000                how often a channel stream beats, and its checks run again
      --roc-threads N                     the threads Roc runs on (ROCX_ROC_THREADS; one a core)
```

A request's body may be 16 MiB at most (413 beyond). `ROCX_LOG` (`pretty` or `json`) chooses the
log's format when the app's `program` says `Auto` (above).

## Tests

`server/test/server.test.mjs` builds `server/test/app` and asks it over HTTP: crashes and memory,
bytes each way (every byte there and back, a 16 MiB body, bytes made in Roc), `Forward` (from a
server the test runs: whole, a range, a 304, HEAD, a redirect, 40 MiB with nothing held, errors
not passed on, a body cut short, no answer, no range or cache question the request record doesn't
pass on), streams, pages of components (a whole document with its answers and start.js, `<Loading>`,
`<Errored>`, an endpoint read behind middleware, `<HttpStatusCode>`, HEAD, crashes, effects that
don't run, holes in `<title>` and `<textarea>`, a `<NoHydration>`, a read redirected by its
middleware, no leaks),
endpoint reads (answered in-process as a page renders, with its query, cookies and headers, noted
once and none from a `<NoHydration>`; one its middleware redirects; a handler reading the page's
flash), form actions (a plain form's refusal and result back to its page with a
flash, read there with what was typed and noted for the browser, then let go; a script's and the
runtime's posts answered as they are; a redirect for the runtime), a port in use,
Postgres, migrations, transactions, jobs (at once, later, retried, failing for good, queued in a
transaction, another app's left alone; attempts per kind, a time limit cutting a run off on
Postgres, a socket and another server with nothing left held, keys unique while pending, cancel
and move, listing), the jobs page (behind a guard; its forms; its stream), cron, email (an outbox,
the dev mailbox, forgotten by a restart, and not without `--dev`, and SMTP to a server the test runs),
`Tcp`, roc-pg, the log (JSON with `ROCX_LOG=json` or unset on a pipe, pretty lines with
`ROCX_LOG=pretty`, an app's fields beside `time`, `level` and `msg` and never in their place, a
program's `Pretty` winning over `Auto` and `ROCX_LOG`, 200 requests logging at once with every line
whole and each request's in order, and the queue flushed at a stop), live rooms and topics,
channels (each checked as its stream opens and at every beat, one refused while the rest go on,
what pages say, a subscriber behind its backlog, 40 streams open on two Roc threads), `Kv` (kept,
read, taken once, deleted; a time to live and a counter's window; 200 increments at once; a capped
list; past `--kv-max-mb`; `kv.rs`'s own unit tests, compiled alone), actors
(one message at a time, a crash, asking another, itself or one waiting on it, tells in order,
timers and a cancelled one, a message an actor doesn't take and a kind the app has none of, logged,
a restart, one idle let go and woken as Postgres has it), `Http` (to servers the test runs: redirects, a timeout, a body too large, TLS
that fails), `Env` (from a request and a job), AES-GCM and packages/crypto against Node's, random
bytes, packages/s3 (objects whole and in part, missing ones, a multipart upload of three parts and
an aborted one, presigned URLs Node's fetch uses, `serve!` with a range (and one the app dropped),
an ETag and HEAD, keys S3
refuses, a bucket or S3 that isn't there, a URL that can't be read), the `Set-Cookie` lines cookies make, endpoints
that take and answer `F64`s (and refuse an infinity) and a tag union in a `Try`'s place, what the
docs' platform pages show (`server/test/app/Samples.roc`, which the site's build picks its samples
from: settings, crypto, jobs, `Kv`, cookies, bytes, other servers, forwards and S3), calls that
wait on two
Roc threads (2,000 requests that wait a second each, answered in about a second; 2,000 open
streams beside a request answered at once; waits, crashes, pages, refusals and sockets interleaved,
each answered as its own, nothing left held; a stack overflow that ends the process saying so), and
a stop in the middle of a request. With
`DATABASE_URL` unset, what needs Postgres is skipped; with `STORAGE_URL` unset (a bucket the tests
may write to: rustfs or MinIO in Docker, say, with a bucket made), what needs S3; a
request over the internet runs only with `ROCX_TEST_INTERNET=1`; `ROCX_TEST_OPT=speed` builds the
app optimized.
`site/test/site.test.mjs` runs the docs site on it, in Chromium, and compares its pages with the
browser runtime's own render.

## Not yet

- `Db`'s queries aren't checked at build (rows are decoded by the record each caller annotates);
  roc-pg's are.
- Channels: a change of what a tab subscribes to opens its stream again, so `on_close!` can't tell
  a subscription the page dropped from a tab that went (both are `Gone`); a connection id with
  subscribe and unsubscribe posts would, if reconnects ever cost too much.
- Actors' timers are in memory: durable ones (Orleans' reminders) would be rows, as jobs are.
- A job's time limit cuts it off only at an effect that waits: Roc that loops without one holds
  its worker until it ends.
- The platform's Roc (jobs, cron, mail, migrations) logs with `Log.line!`: a message at
  info, its details in the text, not yet a level and fields of their own.
- Email: no attachments, Cc or Bcc.
- `Http`: HTTP/1.1, a connection a request (none kept alive), no proxy; an answer's body comes into
  Roc whole.
- `Forward`: an upstream's body only, not the other way (a request's body streamed to S3 as it
  comes: an upload is still read whole, 16 MiB at most); one connection a request.
- A stack overflow in Roc still ends the process.
- HTTP/1.1 only, no TLS: put it behind a proxy. `x64musl` and `x64mac` are configured, not yet run.
- Roc nightly-2026-11-18 crashes building an app with no jobs optimized (`--opt=speed`) when the
  platform goes over `program.jobs` (records holding a function) in most places; `main.roc` reads
  the jobs' names in `isolated_for_host!`, where it doesn't. `roc test` on a module with no `expect` (`Migrations.roc`) never ends;
  nor does it on `JobsPage.roc` (`roc check` and both builds are fine), so the page's small helpers
  and their `expect`s are in `AdminHtml.roc`.
- Roc nightly-2026-11-18 traps in optimized wasm builds (`--opt=speed`, `--specialize=yes`) when a
  platform passes a hosted function on as a value. This platform is native, and unaffected; it
  wraps `send!` and `sleep!` in lambdas anyway, so its Roc would build for wasm too.
