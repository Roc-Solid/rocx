# Roc Solid's server platform

Roc compiled to native code, in a Rust host: one executable that answers HTTP, streams events,
renders pages of components, keeps live rooms, channels, actors and values in memory, and runs what
plugins add (jobs and cron, email: packages/jobs, packages/email), with a database beneath all of it:
Postgres, or SQLite in the server's own process (D-045; on Turso's engine too, D-046). The
browser's platform is `web/` (wasm): an app is two programs, one on each, talking over HTTP. The docs site's platform pages (`/platform`)
say all this at more length.

The host (`host/`, Rust) gives Roc general things: HTTP, coroutines that Roc's calls run on (below),
the database (a pool of Postgres connections and one that listens, or SQLite's or Turso's file, its
calls on threads of their own), time zones, TCP and TLS sockets, requests to other
servers, live topics and rooms, channels' streams, background loops that sleep until woken,
isolated calls, actors' mailboxes and timers, a key-value store in memory, the environment, secure
random numbers, AES-GCM, and rendering components. Migrations, plugins and actors' state are the
platform's Roc (`platform/*.roc`), written on those. Files (in S3, a directory beside the server,
or its memory: `packages/storage`, D-047) and the crypto written in Roc (SHA-256, HMAC, HKDF, Base64,
hex: `packages/crypto`, on no platform, D-025) are packages an app names.

```sh
just dev        # the docs site on it: http://localhost:8080, rebuilt on save
just db         # a Postgres in Docker; prints its DATABASE_URL (a SQLite app needs none)
node server/build.mjs app.roc out/app [--opt=speed] [--target=arm64musl]
```

## An app

```roc
app [program] { pf: platform "…/server/platform/main.roc" }

program = {
    respond!,                                   # every request, answered with a Server.Response
    migrations: [{ name: "0001_tables.sql", sql: tables }],   # import "0001_tables.sql" as tables : Str
    actors: [Actor.handler(cart)],              # the kinds of actor (below)
    logs: { format: Auto },                     # the log's format: Auto, Pretty or Json (below)
    plugins: plugins.map(Plugin.running),       # what packages add (below): the jobs plugin too
    routes: [],                                 # the app's own routes, which plugins' mustn't meet
}
```

`respond!` takes the request, a `Server.Request` (its method, path, query, headers, body as the
bytes came, and `peer`, the address of the connection it came on), and what the server was started
with (`--context-file`), and answers with a `Server.Response`. The host hands the request over as
one record of what it knows (`HostRequest` in `platform/main.roc`: method, target, headers, body,
peer; D-041), which the platform makes the `Server.Request`. An app with routes writes none of this
record: `rocx build` writes `Generated/App`, whose `App.program({ context, middleware, openapi,
plugins })` is a program that answers every request with a plugin's route or the app's (pages,
`+server.roc` endpoints and channels) behind its middleware, and lists the kinds of actor its
modules define and its `migrations/*.sql`; `App.jobs` is the kinds of job they define, for the jobs
plugin (`site/main.roc` is a whole app). The
response's body is text; bytes (`Server.bytes`, below); a body the host fetches from elsewhere and
sends on (`Server.forward`, below); a page of components (`Page`), which the host renders (below); or
a stream of `Events`, which the host runs in a call of its own with `{ send!, sleep! }`.
`Server.for_host` hands each over, flattened: `{ status, headers, kind, text, bytes, upstream, page,
feed }`, `kind` 0 for `text`, 1 for the `page` (a box the host runs: `Html.serialize!` of the page's
markup, made once per answer), 2 for the `feed`, 3 for the `bytes`, 4 for the `upstream` (its
method, URL and headers); the boxes an answer doesn't send do nothing, and the host releases them.
`program.actors` lists the app's kinds of actor (`Actor.handler`), so the host can run an actor's
turn when nobody waits on it (a tell, a timer). The platform exposes `Db`, `Kv`, `Live`,
`Actor`, `Log`, `Time`, `Tcp`, `Http` (and `HttpResponse`, its answer), `Env`, `Random`, `AesGcm`
and `Plugin`; the modules components are written with
(`Html`, `Solid`, `Show`, `For`, `Loading`, `Errored`, `Context`, `Call`, `Router`, `Title`,
`HttpStatusCode`, `Transition`, `Submission`, `Submissions`, `Browser`, `Audio`); and HTTP's
(`Server`, `Endpoint`, `Channel`, `Middleware`, `Events`, `OpenApi`). Those last two kinds are the
web platform's too: their source is in `web/platform`, and the build copies them here
(`SHARED_MODULES` in `build.mjs`).

### Endpoints: the contract and its handlers (D-037)

```roc
# routes/b/[board]/+server.roc: every handler annotated; rocx build copies its types into Api
get! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member } => Try(Board.Data, Endpoint.Refusal)

# Generated/Api.roc, the contract: the same in the browser's copy; any module may import it
get_b_board : { board : Str } -> Endpoint(context, {}, Board.Data)
get_b_board = |params| Endpoint.remote("GET", "/b/${Server.encode_segment(params.board)}")

# Generated/Handlers.roc, the server's alone: what Routes answers with, and Endpoint.run! runs
get_b_board = |params| Endpoint.bind(Api.get_b_board(params), |request, context, {}| BBoardServer.get!({ request, params, context }))

# main.roc, or a module only it imports (an MCP server's tools): a handler, without its middleware
Endpoint.run!(Handlers.get_b_board({ board: "launch" }), request, context, {})
```

`Generated/Api` is what an endpoint is: its method, its URL, and the types its handler's
annotation gives (its params, its body, its answer; a channel's `Channel(who, message, said)`; what
`events!` streams), its context any. It imports what those types name and no route file, so a
store, a job, an actor or a route imports it: `Endpoint.publish!(Api.channel_b_board({ board }),
news)`, typed. `rocx build` refuses a handler without an annotation, or one it can't read, or
whose types name a type its route file defines (Api can't import the file: the type goes into a
module of its own), at its line. `Generated/Handlers` binds each contract to its handler (`Endpoint.bind`: the compiler checks
that they agree), and imports every route file: `Generated/Routes` answers with its endpoints,
and `Endpoint.run!` runs one there and then (no HTTP, no middleware: the caller ran its own). Only
what is outside the routes' imports may import it: `main.roc`, a plugin, a module only they
import. `run!` given Api's contract crashes, saying to use Handlers'. A route file that runs
another route's handler binds it itself (`Endpoint.bind(Api.x(params), |r, c, b| XServer.post!(…))`),
as `site/routes/calls/+server.roc` does.

### The database: `Db` (Postgres or SQLite, D-045; Turso, D-046)

An app picks its database in its program, and writes its SQL for it: nothing is translated, and an
app runs on one. `Postgres`, the default, is at `--database-url` (or `DATABASE_URL`), and an app
without one has no database. `Sqlite(path)` is a file in the server's process at `path`, from where
the server starts, made with its directory when missing, so the app runs with nothing set:

```roc
program = App.program({ context: |_| {}, middleware: Middlewares.default, database: Sqlite("data/plate.db") })
```

`--database-url sqlite:<path>` puts a SQLite app's file elsewhere; a URL of the other kind stops the
server as it starts, saying which the app wants. The host has a backend a kind
(`host/src/db/`: `postgres.rs`, `sqlite.rs`, `turso.rs`), behind the same calls. SQLite is rusqlite with SQLite
compiled in (FTS5 and JSON with it), in WAL mode: a pool of 8 connections whose calls run on
tokio's blocking threads, reads beside a write, writes taking turns (each waits up to 10 s for the
one before), a transaction begun `immediate` (it holds the write lock from its start: keep anything
slow out of one), a statement past its call's time limit interrupted and its connection closed. A
package says which it works with in its plugin's `needs` (`Database` for either, `Postgres`,
`Sqlite`), and a migration which it is for (`on: Sqlite`; any by default): the start check refuses a
package that needs the other, and applies the platform's and the plugins' migrations for the app's
kind. `Db.backend!` says which the server has, for a package with SQL for both (packages/jobs).

`Turso(path)` (D-046) is SQLite's SQL on Turso's engine (`turso_core`, SQLite written again in Rust),
a file in SQLite's format: everything above said of SQLite holds, `Db.backend!` answers `Sqlite`, and
`Db.engine!` tells the two apart. The URL picks the engine (`turso:<path>` runs a SQLite app on
Turso, `sqlite:<path>` a Turso app on SQLite). `turso.rs` mirrors `sqlite.rs`: 8 connections on
blocking threads, WAL, a transaction begun `immediate`, a statement interrupted past its time limit,
its statements prepared once per connection; it drives a statement's steps itself, sleeping the
delay Turso asks for before trying a lock again. The server holds a Turso file while it runs (an OS
lock: no `sqlite3` beside it). Turso has no FTS5, nor an `order by` inside an aggregate
(`json_group_array(value order by key)`, which examples/board uses).

Turso writes at once (D-049): its file is in MVCC mode, `Db.transaction!` begins `concurrent` and
runs its body again when it loses to another's write to the same row (`Conflict: …`, noted by the
host and read by `Host.db_conflicted!`; `begin` waits a random pause first, longer each time, so a
slower writer isn't starved), a write outside a transaction is a concurrent one of its
own (tried again by the host), and a schema change runs exclusive (a migration's first run, refused
`Exclusive: …`, makes the next begin `immediate`). In MVCC mode the file is Turso's alone; SQLite's
backend says so, and `turso:<path>?mvcc=off` once gives it back (writes then taking turns).

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

A parameter is `Null`, `Text`, `Int` or `Bool`, named `$1`, `$2`… in both, and goes to the host as
JSON of its kind. Postgres is sent each as text, which it reads as the type its place wants; SQLite
binds each as it is (a `Bool` as 1 or 0), at its name, and a parameter given and unused, or used and
not given, is an error in both. A list is one parameter on Postgres with `Db.array` (a Postgres
array in text, `{"a","b c",NULL}`, each text quoted): `where tag = any($1)`, `tags @> $1`,
`unnest($1::bigint[])`, as `Db.array(tags.map(|tag| Text(tag)))`; on SQLite, JSON text read with
`json_each($1)`. Rows come back as JSON and `Json.parse` decodes each into the record the caller
annotated, by column name: a null is JSON's `null`, any other value itself. A column that may be
null is read as `Db.Nullable(a)` (`Null` or `Some(a)`, matched as a tag union; `null` or the value in
JSON, both ways); a null in a column read as a plain value is `BadRow`, which names the column. The
record says what may be null, so the host asks the catalog nothing (D-022). From Postgres, booleans,
integers, floats, text, `json`/`jsonb`, `uuid`, timestamps and dates are read; anything else asks for
a cast (`::text`). From SQLite, each value as what it is (an integer or a real a number, text a
string), a column declared `boolean` a `Bool` and one declared `json` its JSON; a boolean worked out
in a statement is 0 or 1 (an `I64`), and a blob is read through `hex(…)`.

`Db.transaction!` keeps one connection for the call: what the body writes, and the jobs it queues,
stay only if it returns `Ok`. An `Err`, a failing statement or a crash rolls it all back, and a call
that ends with a transaction open has it rolled back. `Db.script!` runs statements with no
parameters. `Db.notify!(channel, payload)` tells `Db.listen!`'s listeners (the topic
`db:<channel>`, `Live.next!`) when the call's transaction commits, never if it rolls back, or at once
outside one: Postgres's `pg_notify`, or the server's own on SQLite.

**Checked queries** (D-058). `rocx check --sql <app>` checks an app's SQL with its own database
engine. rocx finds each `Db.all!` and `Db.run!` whose SQL is a string literal at the call, and the
app's server (built as `rocx dev` builds it) describes them: `--describe-sql FILE` answers no HTTP,
runs the platform's start on a scratch database of the app's kind (the platform's, the plugins' and
the app's migrations applied to it), prepares each statement without running it, prints what the
engine says of each as JSON, and removes the scratch. For SQLite and Turso that is a file in a
directory of its own under the system's temporary directory; for Postgres a database
(`rocx_check_…`) made on the server `--database-url` (DATABASE_URL) names and dropped after, which
needs `CREATEDB`. The check never migrates a database nobody named for it, since the app's URL may be
something real: without `CREATEDB` it fails, saying to grant it or to name one it may migrate
(`--sql-database URL`, or `ROCX_SQL_DATABASE`). What the engine says of a statement is its error, or
its parameters and its columns: each one's name, type, how the host reads it (`kind`), and, for one
that comes straight from a table's column, that column and whether it is `not null` (SQLite's
column metadata, Turso's plan, Postgres's `pg_attribute`). rocx reports what the engine refused, and a
call whose parameters (a list literal) aren't the statement's `$1` to `$n`, at the call's line, and
counts what it couldn't check: SQL interpolated (`${…}`), in a variable, or `Db.unchecked(sql)`, which
marks a statement on a table the app makes as it runs. Then the rows, by the compiler: for each
`Db.all!` whose row type rocx can read (a binding's annotation, `rows : List(T)`, or the result of the
function whose body the call is), rocx writes a check app beside a copy of the app's sources
(`build/sql/check`), a `DbCheck.Rows(T, Tags)` for each, its string the statement's columns, and
`roc check` compiles it: `packages/dbcheck` reads `T`'s shape through its parser and refuses a field
the statement doesn't return, a type the column's values can't decode into, or a plain field over
a column that may be null, which rocx reports at the call. `--engine turso` checks a SQLite app on
Turso (`sqlite` a Turso app on SQLite); `rocx dev` runs the check after each build, and `just
examples` on every example. The examples' 133 literal statements and 80 rows check clean, in about
a second an app.

**Migrations** are in the executable: `program.migrations` lists them, each a name and its SQL
(`import "migrations/0001_tables.sql" as tables : Str` reads a file when the app is compiled). When
the server starts they are applied in the order listed, each once, each in a transaction (recorded
by name in `rocx_migrations`); two starting at once (a deploy's old server and its new one) take
turns (on Postgres an advisory lock, on SQLite its write lock). The platform's own tables (`rocx_actors`: `rocx/0001`, …) come first,
then the plugins' (each recorded as `<plugin>/<name>`: the jobs plugin's `rocx_jobs` is
`jobs/0001_jobs`), then the app's; one that fails stops the server.

Postgres connections use TLS when the database offers it (or the URL's `sslmode` asks), checked
against the web's certificate authorities. `Time.offset!(zone, at)` gives an IANA time zone's offset
from UTC at a moment (the host's chrono-tz), which a SQLite app works a local day out from, as SQLite
knows no zones.

**roc-pg** ([niclas-ahden/roc-pg](https://github.com/niclas-ahden/roc-pg)), a Postgres client in
Roc whose queries are checked against a schema when the app is compiled, runs on this platform: it
connects with `Tcp.connect!` and logs in with `Random.seed_u64!`. `examples/roc-pg` uses the same
`schema.sql` as its migration and as what roc-pg checks against; the tests build it and run it.
From cold, checking it takes 0.8 s, a dev build 1.2 s, an optimized one 6.3 s.

### Jobs and cron: packages/jobs (D-034)

Jobs and cron are a package and a plugin, on the platform's general effects (the database and its
notifications, background loops, isolated calls), on Postgres or SQLite: `Job.plugin({ jobs: App.jobs, crons })` adds the
queue's table, its workers and its schedules. The jobs page is packages/admin's (`JobsPage`).
`packages/jobs/README.md` says how they work.

### Email: packages/email (D-035)

Email is a package and a plugin, on the platform's general effects (`Tcp` with TLS, `Kv`, early
paths under `--dev`): `Email.plugin({})` sends over SMTP (`SMTP_URL`, `MAIL_FROM`), or keeps mail
for the dev mailbox at `/__rocx/mail`, and looks at the SMTP server at start.
`packages/email/README.md` says how.

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

### Files: `packages/storage` (D-047), and `Blobs`

Files are a package that names this platform. An app makes a bucket from a URL it keeps in its
environment, whose scheme is the backend: any S3 (`s3://…`: rustfs or MinIO in development, R2 or
AWS in production, each operation a signed request with `Http.send!`), a directory beside the server
(`file:<dir>`), or the server's memory (`memory:`, for tests).

```roc
# main.roc's header: storage: "../packages/storage/main.roc"
bucket = Storage.from_url(Env.var!("STORAGE_URL") ?? "")?
Storage.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?
Storage.serve!(bucket, "videos/${id}", request, { content_type: "video/mp4", cache_control: "private" })   # an answer
```

A directory's and memory's objects are the host's to keep (`host/src/blobs.rs`, the platform's
`Blobs`): put (written to a file of its own, then moved into place, so a crash leaves no half object),
get, a range, head, delete, the keys under a prefix, and parts joined in order (a multipart upload's
end), each under a root, `file:<dir>` or `memory:<name>`; an object's content type and ETag (its MD5)
kept beside it (`<dir>/.storage/`), and a key that would leave its directory (`..`, a leading `/`, an
empty segment) refused. Their files are read and written on tokio's blocking threads.

`Storage.serve!` never brings an object into Roc: from S3 it answers with a `Forward` (below); from a
directory or memory with `Stored` (`Server.stored(root, key, request, headers)`), which the host sends
as it is, with its length, type, ETag and `last-modified`, 206 for the request record's `Range` (one;
416 past the end), 304 for its `If-None-Match`. Signed URLs for a directory or memory are the app's,
answered by the storage plugin's `/__storage` route. `packages/storage/README.md` has the rest: the
URLs, every operation, the errors, signed URLs, and the limits.

### Bytes: `request.body`, `Server.bytes`

```roc
Server.text_of(request)                  # the body as text (UTF-8; U+FFFD where it isn't): JSON, a form
Storage.put!(bucket, "images/${id}", request.body, { content_type: "image/jpeg" })?  # the bytes as they came
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
passed off as whole. packages/storage's `Storage.serve!` is a `Forward` to S3, for an S3 bucket.

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

### Forms: typed bodies, the flash, `Endpoint.respond!`

```roc
# routes/members/join/+server.roc: a form posts { name }
post! = |{ body, .. }| if body.name.trim().is_empty() Err(BadRequest("a member has a name")) else Ok("Welcome, ${body.name}")

# the page it was posted from
Server.flash!({})      # Ok({ url: "/members/join", fields: [{ name: "name", value: "" }], status: 400, body: "a member has a name" })

# routes/orders/+server.roc: a form's fields, read by the body's types (D-038)
# item=tea&count=2&gift=on&toppings=milk&toppings=honey&size=Large
post! : { …, body : { item : Str, count : U64, gift : Bool, toppings : List(Str), size : [Small, Large] } } => …
```

An endpoint's body is one type however it is sent: JSON (an action, a script) is read as JSON,
strictly; a form's fields (a plain form, or the runtime's) by the body's types (`FormBody`). A
number is read from its text (spaces around it dropped); a `Bool` is `on`, `true` or `1`, or
`false`, `0` or empty, and missing (a box left unticked) is false; a `List` is every value its name
has, in order, and missing is `[]`; a tag with no payload is the one its text names (a `<select>`).
A `Str` is the text as typed. A `Str` or a number that is missing (a number left empty too), or
text that isn't its type, is a 400 naming the field (`the field count needs a whole number, 0 or
more, not "two"`). A field a non-list has twice is its last value (a hidden default before a
checkbox); a field the body has and the record doesn't is let be. `Endpoint.remote` makes the
reader, where `Generated/Api` gives the contract its types, and `bind` keeps it (`Endpoint.local`
makes one too); a function generic in its arg as JSON alone (packages/mcp's tools) makes its
endpoints with `Endpoint.local_json`, which reads a form's fields as strings. The browser's
submissions read a form the runtime sent with the same reader (`input!`, `pending_inputs!`).

A form a browser posts without the runtime (a plain `<form method="post">`: a form's body,
`application/x-www-form-urlencoded`, from a page, `accept: text/html`) would get a page of JSON, or
of text, from its endpoint. `Endpoint.respond!` sends neither: for its result, its refusal, or a
body it can't read (400), it answers `Server.flash_back!`: a 303 to the page the form was posted
from (`Referer`, when it is this site's; `/` otherwise), with a flash: the URL it posted to, the
form's body as posted (however long), the status and the body. The flash is kept in the server's
memory (the store `Kv` uses) for a minute, under a random id, and the cookie `rocx-flash` holds
only that id (`Path=/; HttpOnly; SameSite=Lax; Max-Age=60`). With `--debug` or `--dev` the 303 also
says what the flash holds but the fields (`x-rocx-flash`: its URL, status and body), for tests
(packages/testing's `flash`). An answer of the endpoint's own (`Err(Answer(…))`: a redirect that
sets a cookie) is sent as it is.
The page the browser lands on reads it with `Server.flash!({})`, or as its form's submission
(`Router.use_submission!(endpoint)`, which is the flash when it is that endpoint's): what was typed,
and the result or the refusal. The first read while a page renders takes it from the store, so a
flash is read once (a replayed cookie finds nothing); the host keeps it for the page's other reads,
and notes it in `<script type="application/json" class="rocx-flash">`, before the answers, so the
browser renders it as the server did. A password is never sent back: `Html` leaves the `value` out
of an `<input type="password">`, whatever a component gives it, and the note leaves out each field
the page has as one. `App.program` lets the cookie go with that page (`Server.clear_flash`: a
browser's next GET of a page clears it, read or not), so a reload doesn't show it again; an app
that writes its own program calls `Server.clear_flash(request, answer)` itself.

With the runtime, a form whose page reads its submission is sent with `fetch` instead
(`x-rocx-submission: 1`, `accept: application/json`): it gets the endpoint's result as JSON, or its
refusal, and an answer of the endpoint's own that redirects comes back as 200 with
`x-rocx-redirect` (fetch would follow a 303 before the runtime could read it), its cookies kept,
for the runtime to go there. A script's post (JSON, or a form not for a page) gets the endpoint's
answer as always. So does an action (`Router.use_action!`, D-030): the browser's runtime sends its
arg as JSON, with `x-rocx-submission: 1`, and a result has it read the page's reads again
(`Endpoint.get!`'s GETs); the server sees plain requests, and an endpoint that answers one with its
own `Err(Answer(…))` (a cookie set along with its JSON, as the docs site's planner keeps a reader's
week) is sent as it is. A handler that answers each its own way asks
`Endpoint.posted_by(request)`: `PlainForm`, `Runtime` (a form the runtime sent, or an action) or
`Other` (a script). examples/tasks' delete sends a plain form to the list, and gives the runtime the
list's id.

### Settings: `Env`

```roc
key = Env.var!("APP_SECRET")                                # Try(Str, [NotFound])
link = "${Env.public_url!({})}/unsubscribe?token=${token}"  # PUBLIC_URL, or where it listens
if (Env.dev!({})) dev_sign_in else Server.refused(404, "No page here.")     # started with --dev
```

`Env.var!` reads the server's environment: the app's secrets and what differs between machines,
read alike in a request, a job or a schedule (twelve-factor; Phoenix's `runtime.exs`). The context
file stays for what a request is given. `Env.dev!` says whether the server was started with
`--dev`. `Env.public_url!` is where the app is, for the links it sends (Running, below). The platform's own settings stay flags or their variables (`DATABASE_URL`, …); a plugin
reads its own (`SMTP_URL`, for packages/email).

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
Kv.swap!("guard:login/7", was, next, {})?                           # Err(Changed): another changed it; read again
state = Kv.take!("oauth:${given}")?                                 # good once
Kv.push!("email:mailbox", message, { keep: 100 })                    # a capped list, newest first
Kv.list!("email:mailbox")?
```

Values by key, kept in the server's memory for as long as `ttl_ms` says (0, the default: until it
stops), never written anywhere: for what is cheap to lose and read on every request. A value is kept
as JSON and read back as the type its reader asks for. Each operation is atomic, and a new counter's
or list's time to live starts with it (later increments and pushes don't move it). The host keeps one
map behind one lock (`host/src/kv.rs`; nothing is awaited while it is held), expired entries going at
the next operation; past `--kv-max-mb` (64) the least recently read or written go, never the one
just written. Keys name their owner first, by convention (`email:mailbox`).

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
method `CHANNEL`, typed with its `Channel(who, message, said)`, copied from `channel!`'s annotation), and
pages subscribe to it with `Endpoint.subscribe!` (web/README.md). Api imports no route file (D-037),
so a job, an actor or a store module imports `Generated/Api` and publishes by name, typed: what it
publishes must be the channel's `message`. The module that defines that type can't import Api too
(Api imports it): `rocx build` says so, and to move the type into a module of its own. Its hooks,
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
- A tab has one stream: a new stream for a tab ends the tab's old one first (`event: replaced`, for
  a page still reading it: a duplicated tab, which takes an id of its own), and waits for its
  `on_close!`s (10 s at the most) before its own checks run, so a tab's hooks come in order, an old
  subscription's end before a new one's start.
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

With a database, an actor's state is read from it (`rocx_actors`) by its first turn and
written after each turn that changes it, so it is there after a restart. An actor idle for
`--actor-idle-ms` (15 minutes) is let go: it tells the router, which lets it go if nothing was sent
to it meanwhile, and the next message wakes it as the database has it. Without a database, its state is
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
A read that isn't 200 fails what read it, and the nearest `<Errored>` shows its fallback. One that
no `<Errored>` of the page's catches reaches the root one rocx writes, whose fallback is the app's
`+error.rocx`, answered with the refusal's status when it is a 4xx (`Errored.status_of`: a
`NotFound` is the page's 404, as a path no page has is), else 500. A boundary of the page's own that
catches it shows its fallback, and the page is answered as it is (200, unless that fallback says
otherwise with `<HttpStatusCode>`), as in the browser.
`Host.request!` is the request being answered, whole; `Host.location!` its path and query
(`Router.location!`), and `Host.status!` the status its page is to be answered with
(`<HttpStatusCode>`, for pages of components).

The modules components are written with are the browser's platform's (`web/platform`), copied into
this one by the build (`server/build.mjs`), so the same components compile on both. An endpoint's
handler runs only here, so it may use `Db`, `Job` and the rest: `Api` is the contract in both copies
(each endpoint's method, URL and types), its handlers are `Generated/Handlers`', which only the
server has, and in the browser's copy a route file has no middleware.

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
`error`, forwarding, a background loop that crashed), the platform's Roc's and its plugins', and the
app's all go through one formatter in the host. The platform's and the plugins' say what happened in
a message that doesn't change, and the rest in fields (D-056): `rocx server: migrated`
(`migration`), `rocx plugins: added` (`plugin`, `adds`), a plugin's check (its message, `check`:
`email.smtp`), and packages/jobs's and packages/email's (`rocx jobs: a job failed, and runs again`,
a warning with `kind`, `id`, `attempt`, `of`, `again_in_ms` and `error`; `rocx jobs: a job failed for
good`, an error; `rocx cron: a schedule's job wasn't queued`; `email: kept, not sent (no SMTP_URL)`,
with `to` and `subject`).
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

program = App.program({ context, middleware, plugins: [Acme.plugin({ at: "/acme" })] })
```

A plugin is a `Plugin.Value(ctx)`: a name, and what a package adds to the app, every field but the
name defaulting to `[]`. `routes` answer behind the app's middleware, before its own routes (`ctx`
is what that middleware hands on: a plugin's routes get it without knowing its type); `early` paths
are answered before the app, under `/__rocx/`, only with `--dev` or `--debug`; `files` are served
as they are, before anything else (the app's middleware among it), and `scripts` (some of them)
load on every page (D-050, below); `migrations` are
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
database, a plugin not in the list, or needs in a circle; a file whose path isn't relative, a file at
the root under `rocx/` or `__rocx/`, two files at one place, a file at the root where a route is,
or a script that is none of the plugin's files. Then the plugins are ordered by their needs, and the
log says what each added (`rocx plugins: added plugin=acme adds="2 routes, 2 files, 1 script, 1 migration"`).

**Files and scripts** (D-050). A file is a `Plugin.File`, `{ path, at : [Plugin, Root],
content_type, body : List(U8) }`, its bytes embedded when the app is built (`import
"static/acme-sw.js" as worker : List(U8)`). It is at `/rocx/plugins/<plugin>/<path>`, or at
`/<path>` with `at: Root` (a service worker, whose scope is where it is; `/.well-known/…`). The
start hands each to the host once (`Host.plugin_file!`), which serves it before anything else, no
call into Roc: `GET` and `HEAD`, with its type, an ETag of its bytes (304 when `If-None-Match` has
it) and `cache-control: no-cache` (`no-store` under `--dev`); any other method, 405. So an app's
guard never meets it. `scripts` are paths of the plugin's own files: every page the host renders
has a `<script type="module" data-rocx src="…">` for each, after the answers and before start.js,
so a script has registered its effects (`window.rocxEffects["acme.ping"]`, which `Browser.call!`
finds) before the page wakes. Under `--debug`, `GET /__rocx/plugin-files` lists the files (each
URL, type, and whether it is a script): what a static copy of a site copies (site/build.mjs).

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
the plugins' loops and checks: the jobs plugin's workers and its schedules' loop, the email
plugin's look at the SMTP server) and runs each, a call of its own,
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
      --database-url URL                  the database (DATABASE_URL): postgres://…, or sqlite:<path> (turso:<path>) for a SQLite (Turso) app's file elsewhere
      --actor-idle-ms 900000              an actor idle this long is let go (0: never; kept in the database)
      --kv-max-mb 64                      Kv's limit (KV_MAX_MB): the least recently used goes past it
      --max-body 16MiB                    the most a request's body may be (MAX_BODY): bytes, or KiB, MiB, GiB
      --public-url https://app.example    where the app is, for links it sends (PUBLIC_URL; else where it listens)
      --dev                               reload pages on restart, show crashes, plugins' dev pages, Env.dev!
      --debug                             GET /__rocx/allocations and /__rocx/plugin-files, and plugins' debug paths
      --live-beat-ms 15000                how often a channel stream beats, and its checks run again
      --roc-threads N                     the threads Roc runs on (ROCX_ROC_THREADS; one a core)
      --describe-sql FILE                 no HTTP: describe each statement FILE lists (a JSON array of SQL) on a scratch
                                          database the program's migrations are applied to, print what the database says, exit
      --sql-database URL                  for --describe-sql, a database it may migrate, in place of a scratch one (ROCX_SQL_DATABASE)
```

A request's body may be 16 MiB at most (413 beyond), or what `--max-body` (`MAX_BODY`) says: a
number of bytes, or of KiB, MiB or GiB (`64MiB`); 0 or anything else stops the server (D-056). The
host reads it whole before Roc runs, so it is the most any request holds in memory. `ROCX_LOG` (`pretty` or `json`) chooses the
log's format when the app's `program` says `Auto` (above). `Env.public_url!` is the app's public URL,
for the links it sends: `--public-url` or `PUBLIC_URL` (an `http://` or `https://` URL; its `/` at the
end dropped; anything else stops the server), as behind a proxy; without either, where the server
listens (`http://127.0.0.1:8080`, the port the system gave `--port 0`; an address that is all of the
machine's is its loopback). Never a request's `Host`, which whoever asks writes.

## Tests

`server/test/server.test.mjs` builds `server/test/app` and asks it over HTTP: crashes and memory,
bytes each way (every byte there and back, a 16 MiB body, bytes made in Roc), `--max-body` and
`MAX_BODY` (the limit itself and a byte more, said or chunked; sizes it refuses), `Forward` (from a
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
Postgres, migrations, transactions, plugins (a fixture plugin package's route with the app's
context, early path, table, call, loop, start, check and need; an app whose plugins break every rule
refused at start, the whole message), jobs through packages/jobs's plugin (at once, later, retried,
failing for good, queued in a transaction, another app's left alone; attempts per kind, a time
limit cutting a run off on Postgres, a socket and another server with nothing left held, keys
unique while pending, cancel and move, listing; a database the platform migrated before jobs were
a package, its jobs where they were), the jobs page (behind a guard; its forms; its stream), cron,
email through packages/email's plugin (an outbox, the dev mailbox, forgotten by a restart, and not
without `--dev`, and SMTP to a server the test runs; the old flags refused),
`Tcp`, roc-pg, the log (JSON with `ROCX_LOG=json` or unset on a pipe, pretty lines with
`ROCX_LOG=pretty`, an app's fields beside `time`, `level` and `msg` and never in their place, a
program's `Pretty` winning over `Auto` and `ROCX_LOG`, 200 requests logging at once with every line
whole and each request's in order, the queue flushed at a stop, and the platform's and plugins'
own events with their levels and fields: a job's failures, migrations, plugins, a check, mail
kept), live rooms and topics,
channels (each checked as its stream opens and at every beat, one refused while the rest go on,
what pages say, a subscriber behind its backlog, 40 streams open on two Roc threads), `Kv` (kept,
read, taken once, deleted; a time to live and a counter's window; 200 increments at once; a capped
list; past `--kv-max-mb`; `kv.rs`'s own unit tests, compiled alone), actors
(one message at a time, a crash, asking another, itself or one waiting on it, tells in order,
timers and a cancelled one, a message an actor doesn't take and a kind the app has none of, logged,
a restart, one idle let go and woken as the database has it), `Http` (to servers the test runs: redirects, a timeout, a body too large, TLS
that fails), `Env` (from a request and a job), AES-GCM and packages/crypto against Node's, random
bytes, packages/storage on memory, on a directory and on S3 when there is one (objects whole and in
part, missing ones, a multipart upload of three parts and an aborted one, signed URLs Node's fetch
uses, `serve!` with a range (and one the app dropped), a 416, an ETag and HEAD; a directory's files
kept across a restart and keys that would leave it refused; memory forgotten by one, and a signed
link expired; keys S3 refuses, a bucket or S3 that isn't there, a URL that can't be read), the `Set-Cookie` lines cookies make, endpoints
that take and answer `F64`s (and refuse an infinity) and a tag union in a `Try`'s place, what the
docs' platform pages show (`server/test/app/Samples.roc`, which the site's build picks its samples
from: settings, crypto, jobs, `Kv`, cookies, bytes, other servers, forwards and storage), calls that
wait on two
Roc threads (2,000 requests that wait a second each, answered in about a second; 2,000 open
streams beside a request answered at once; waits, crashes, pages, refusals and sockets interleaved,
each answered as its own, nothing left held; a stack overflow that ends the process saying so), and
a stop in the middle of a request. With
`DATABASE_URL` unset, what needs Postgres is skipped; with `STORAGE_URL` unset (an S3 bucket the
tests may write to: rustfs or MinIO in Docker, say, with a bucket made), storage's S3 runs; a
request over the internet runs only with `ROCX_TEST_INTERNET=1`; `ROCX_TEST_OPT=speed` builds the
app optimized.
`server/test/sqlite.test.mjs` builds `server/test/sqlite`, an app whose database is SQLite, and needs
no database server: its file where the program says or `--database-url` does, a Postgres URL refused,
typed parameters and rows, transactions and a failing script, 40 read-then-write transactions at
once that each see the one before, a read beside a held write, notifications heard on commit only,
the platform's and a plugin's SQLite tables made once, an actor's state across a restart, a plugin
that needs Postgres refused; jobs (in a transaction, retried, keyed, cut off at their time limit with
the statement interrupted and the transaction rolled back), cron, and the jobs page.
`site/test/site.test.mjs` runs the docs site on it, in Chromium, and compares its pages with the
browser runtime's own render.

## Not yet

- `rocx check --sql` (D-058) checks only SQL written as a string at the call: SQL put together
  (`${…}`) or passed in a variable isn't checked, nor a row whose type rocx can't read from an
  annotation. A column from the outer side of a `left join` is taken as its table's `not null`
  says, and SQLite doesn't type an expression, so neither is checked for nulls there (sqlx reads
  the statement's plan for these).
- Channels: a change of what a tab subscribes to opens its stream again, so `on_close!` can't tell
  a subscription the page dropped from a tab that went (both are `Gone`); a connection id with
  subscribe and unsubscribe posts would, if reconnects ever cost too much.
- Actors' timers are in memory: durable ones (Orleans' reminders) would be rows, as jobs are.
- A job's time limit cuts it off only at an effect that waits: Roc that loops without one holds
  its worker until it ends.
- `Http`: HTTP/1.1, a connection a request (none kept alive), no proxy; an answer's body comes into
  Roc whole.
- `Forward`: an upstream's body only, not the other way (a request's body streamed to S3 as it
  comes: an upload is still read whole, 16 MiB at most unless `--max-body` says more); one connection a request.
- The OpenAPI document (`Api.openapi`) gives each endpoint's body as JSON only, though an
  endpoint reads the same fields from a form (`application/x-www-form-urlencoded`), as a plain
  form posts them without JavaScript (examples/journal's reactions take both).
- A stack overflow in Roc still ends the process.
- HTTP/1.1 only, no TLS: put it behind a proxy. `x64musl` and `x64mac` are configured, not yet run.
- `roc test` on a module with no `expect` (`Migrations.roc`) never ends; nor does it on
  `JobsPage.roc` (packages/admin; `roc check` and both builds are fine), so the page's small helpers
  and their `expect`s are in `AdminHtml.roc`.
- Roc nightly-2026-11-18 traps in optimized wasm builds (`--opt=speed`, `--specialize=yes`) when a
  platform passes a hosted function on as a value. This platform is native, and unaffected; it
  wraps `send!` and `sleep!` in lambdas anyway, so its Roc would build for wasm too.
