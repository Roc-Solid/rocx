# Roc Solid's server platform

The server platform runs a Roc Solid app as one native executable. Roc compiles the app and the
platform's Roc modules (`platform/*.roc`) to native code, and links them with a Rust host
(`host/`), which answers HTTP with tokio and hyper. The one process answers pages and endpoints,
renders components, streams events, keeps live channels, actors and in-memory values, runs what
plugins add (jobs and cron, email), and talks to the app's database: Postgres, or SQLite in the
server's own process (D-045), optionally on Turso's engine (D-046).

An app is two programs that talk over HTTP: this one, and the browser's (`web/`, Roc compiled to
wasm). Both compile the same components. The modules components and endpoints are written with
(`Html`, `Solid`, `Server`, `Endpoint`…) live in `web/platform`, and `server/build.mjs` copies them
into `server/platform` before each build (`SHARED_MODULES`). Edit them in `web/platform`, never
here.

Read this when you are about to change the server platform: its host, its Roc modules, or how it
builds and runs. For how to use the platform in an app, the docs site's platform pages
(`/platform`) are the place to start; the generated reference (`/platform/reference`) lists every
exposed function.

## Quick start

```sh
just setup                  # the toolchain, once: Zig and Rust (unless PATH's will do), the Roc fork, bin/rocx
just dev                    # the docs site on this platform: http://localhost:8080, rebuilt on save
just db                     # a Postgres in Docker; prints its DATABASE_URL (a SQLite app needs none)
node server/build.mjs app.roc out/app [--opt=speed] [--target=arm64musl] [--specialize=yes]
out/app --port 8080         # --help lists every flag (Running, below)
just test-server            # this platform's tests (DATABASE_URL for the Postgres ones)
```

An app with routes (`routes/`) is usually built and run with `rocx dev <dir>` instead, which writes
its `Generated/` modules first.

## The big picture

### The pieces

The Rust host (`host/src/`):

| File | What it does |
| --- | --- |
| `lib.rs` | The executable's `main`: reads the flags, starts tokio and Roc's threads, runs the start, serves, stops. Also `--describe-sql`. |
| `http.rs` | The HTTP server: the flags (`Config`, `USAGE`), the paths the host answers itself, `--static` and `--file` files, the call into Roc, and sending each kind of answer (text, bytes, a stream, a forward, a stored object). |
| `coroutine.rs` | Roc's threads. Every call into Roc is a stackful coroutine that pauses while an effect waits (D-027). |
| `roc.rs` | Roc's memory (each call's list of allocations), crashes, and the calls into the app (`respond`, `stream`, `init`, `background`, `isolated`, `actor`, `run`). |
| `guard.c` | The jump target around every call into Roc, which `roc_crashed` jumps back to. |
| `preempt.rs` | The watchdog that cuts off Roc that runs past its deadline without ever waiting (D-057). |
| `hosted.rs` | Every hosted function `platform/Host.roc` declares, and how a call waits on a future (`wait`). |
| `signals.rs` | Renders a page of components; answers a page's endpoint reads in-process; writes the final document. |
| `db/` | The database: `mod.rs` (the shared interface), `postgres.rs`, `sqlite.rs`, `turso.rs`, and `check.rs` (`--describe-sql`, D-058). |
| `client.rs` | `Http`: requests to other servers, kept-alive connections, redirects, and the body of a `Forward`. |
| `proxy.rs` | Which proxy an outgoing request takes (plain Rust; its tests compile alone). |
| `tls.rs` | The rustls configuration every outgoing TLS connection uses. |
| `tcp.rs` | `Tcp`: sockets that belong to one call. |
| `live.rs` | `Live`: topics and rooms in memory. |
| `channels.rs` | Channels: the tab's stream `GET /rocx/live` and `POST /rocx/live/send` (D-020, D-057). |
| `actors.rs` | Actors: the router task, one mailbox per awake actor, timers. |
| `kv.rs` | `Kv`: values by key in memory (its tests compile alone). |
| `blobs.rs` | Objects for packages/storage's `file:` and `memory:` buckets (D-047). |
| `files.rs` | Plugins' files and the scripts every page loads (D-050). |
| `memory.rs` | Named values the platform's start sets for its own modules (`Host.store_get!`, `store_set!`). |
| `settings.rs` | What the server was started with, for Roc (`Host.setting!`). |
| `logging.rs` | The log: one queue, one writer thread, pretty or JSON lines. |
| `roc_platform_abi.rs` | Glue generated from `platform/main.roc` (`just glue`). Don't edit it. |

The platform's Roc (`platform/`):

- `main.roc` is the header: what an app must provide (`program`), the entry points the host calls
  (`roc_respond`, `roc_init`, `roc_stream`…: `respond_for_host!`, `init_for_host!` and so on, all
  defined in this file), and the hosted functions. Its `##` comment is the platform's own summary.
- `Host.roc` declares the hosted functions. Apps never import it.
- The server's own exposed modules: `Db`, `Kv`, `Live`, `Actor`, `Log`, `Time`, `Tcp`, `Http`,
  `HttpResponse`, `Env`, `Random`, `AesGcm`, `P256`, `Blobs`, `Plugin`, and `Navigate` (the
  server's `<Navigate>`, which answers with a 303).
- Internal modules: `Migrations` (the platform's tables, and applying migrations), `Plugins`
  (checking, ordering and logging plugins), `ActorTurn` and `ActorTimers` (an actor's turn and its
  durable timers), `FlashStore` (where a form's flash waits), `Setting` (the start's settings).
- The shared modules, copied from `web/platform` (`SHARED_MODULES` in `build.mjs`): `Html`,
  `Solid`, `Store`, `Repeat`, `Loading`, `Errored`, `Call`, `Context`, `Router`, `Search`, `Leave`,
  `HttpStatusCode`, `Transition`, `Title`, `Browser`, `Submission`, `Submissions`, and HTTP's
  `Server`, `Endpoint`, `FormBody`, `Channel`, `Middleware`, `Events`, `OpenApi`. They are
  committed here too, so a fresh clone compiles.

The app: `main.roc` calls `App.program({ … })`, and `rocx build` writes `Generated/App` (the
program: routes, middleware, migrations, actors), `Generated/Routes`, `Generated/Api` (the
contract) and `Generated/Handlers`. `site/main.roc` and `examples/*/main.roc` are real ones.

### How a request flows

1. tokio accepts the connection and hyper serves it over HTTP/1.1 (`http::serve`). The socket gets
   a 20 s deadline for unacknowledged writes, so a vanished client is noticed (Channels, below).
2. The host answers some paths itself, without Roc (`http::answer`, in this order):
   - under `--dev`: the reload stream `/__reload`, its script `/__reload.js`, and
     `POST /__rocx/dev/log` (a phone's dev client's log, D-063);
   - a plugin's file (`files.rs`, D-050), before the app's middleware can refuse it;
   - under `--debug`: `GET /__rocx/plugin-files` and `GET /__rocx/allocations`;
   - the channels' `/rocx/live` and `/rocx/live/send` (`channels.rs`);
   - for `GET` and `HEAD`, a `--file` or a file in a `--static` directory.
3. Anything else goes to Roc (`http::from_roc`). The host drops the `x-rocx-channel` and
   `x-rocx-tab` headers (only the host may send them), reads the body (up to `--max-body`, else
   413), and runs `roc::respond` as a coroutine on one of Roc's threads.
4. In Roc, `respond_for_host!` turns the host's record (`HostRequest`: method, target, headers,
   body, peer) into a `Server.Request`. A plugin's early path (`Plugin.Early`, under its flag)
   answers first. Otherwise `program.respond!` runs. For an app built by rocx, that is
   `Generated/App`: it sets `request.route`, sends a channel's end (`x-rocx-channel: close`)
   straight to the route's `on_close!`, and runs everything else through the platform's cross-site
   check (`Middleware.same_origin`, unless the app says `cross_site: Allowed`), the app's middleware
   (`routes/+middleware.roc`), then the OpenAPI middleware, then a plugin's route or the app's own
   (`Plugin.respond!`, then `Routes.respond!`, which runs the `+middleware.roc` of each directory the
   route is in, outermost first, D-103). `Server.clear_flash` runs on the way out.
5. `Server.for_host` flattens the `Server.Response` for the host. Its `kind` says which body it
   has (table below).
6. Back in the host, in the same call: a handler's `Router.revalidate!` keys become an
   `x-rocx-revalidate` header. A `Page` is rendered there and then (`signals::render_page`), except
   for HEAD. If a read the page made was redirected by its middleware, the page's answer becomes
   that redirect.
7. A crash anywhere in the call is a 500 (`Something went wrong.`, or the message under `--dev`),
   and a `rocx server: Roc crashed` error on the log. The server goes on.
8. The host sends the answer. Text and bytes get a `server-timing` header with Roc's time. Under
   `--dev`, an HTML answer gets the reload script before `</body>`, and any answer without a
   `cache-control` gets `no-store`.

| Body (`Server.Body`) | Made with | `kind` | What the host does |
| --- | --- | --- | --- |
| `Text(Str)` | `Server.response`, `refused`, `redirect`… | 0 | Sends it. |
| `Page({} => Html)` | a route's page | 1 | Renders it in the same call (`signals.rs`). |
| `Events(Events(Str))` | `Server.events` | 2 | Runs the stream as a call of its own (`stream_for_host!`), writing each event as it comes. |
| `Bytes(List(U8))` | `Server.bytes` | 3 | Sends them as they are. |
| `Forward(Upstream)` | `Server.forward` | 4 | Fetches the body from elsewhere and sends it on as it arrives, never through Roc. |
| `Stored(…)` | `Server.stored` | 5 | Sends an object `Blobs` keeps, with ranges and an ETag. |

The boxes an answer doesn't use (the page, the stream) do nothing, and the host releases them.

### How the server starts and stops

1. The file `--env-file` names, if it names one, is read into the environment, in `main`, while
   it is the only thread (`dotenv.rs`, D-088, D-098; Settings, below). A line that isn't a setting,
   or a named file that isn't there, stops the server (exit 2). Then the flags are read
   (`Config::parse`). An unknown flag, or one that is gone (`--migrations`, `--job-workers`,
   `--smtp-url`…), stops the server with a message saying where it went.
2. tokio's runtime starts, then Roc's threads (`coroutine::start`).
3. The host takes its address. A port in use stops the server here (`Address already in use`,
   exit 1), before anything else has started.
4. The host keeps the settings (database URL, `--dev`, `--debug`, the public URL, the context
   file's text) and starts the actors' router.
5. The start runs in Roc, as three calls one after another (`roc::init`, `roc::make_context`,
   `roc::started`):
   - `init_for_host!`: the log takes the app's format; the database opens; the plugins are checked
     (every problem at once stops the server, and so does no database while the app or a plugin
     has tables, outside `--dev` and `--debug`: `no_database!`, D-045); the host learns the kinds
     of actor and the plugins' files and scripts; the migrations run: the platform's, then the
     plugins', then the app's.
   - `context_for_host!`: the app's `init!` makes its context.
   - `started_for_host!`: actors' timers left from the last run are set again, the plugins'
     `starts` run in order, one line names them (`rocx plugins: jobs, email`; what each added at
     debug), and under `--dev` their links go to the host (`Host.dev_links!`, D-111), which lists
     them under its address as it starts to answer.
   An `Err` or a crash in any of them stops the server.
6. The background loops start: the plugins' loops and checks (`roc_background_count`), each a call
   of its own. One that crashes starts again a second later.
7. The host logs what the file set (`rocx server: settings read`, in the app's format now), then
   `rocx server: http://… (Roc, native)`, and answers requests.

Stopping (SIGTERM, or ^C): the server logs `rocx server: stopping`, stops listening, and waits up
to ten seconds for the requests and streams still running. The background loops are told to stop
(`Plugin.stopping!`; `Live.next!` answers `Gone`), and the host waits up to ten seconds for them
too. A job cut short runs again at the next start. The log is flushed before the process exits.

## The app's program

```roc
app [program] { pf: platform "…/server/platform/main.roc" }

program = {
    init!: |started| Ok({ started }),           # the app's context, made once at the start
    respond!,                                   # every request, given the context
    database: Postgres,                         # Postgres, Sqlite(path) or Turso(path)
    migrations: [{ name: "0001_tables.sql", sql: tables }],   # import "0001_tables.sql" as tables : Str
    actors: [Actor.handler(Carts.add)],         # every actor method (Actors, below)
    logs: { format: Auto },                     # Auto, Pretty or Json (The log, below)
    plugins: plugins.map(Plugin.running),       # what packages add (Plugins, below)
    routes: [],                                 # the app's own routes, which plugins' mustn't meet
}
```

`main.roc`'s `requires` section is the authority for these fields. An app with routes never
writes this record. `rocx build` writes `Generated/App`, and the app's `main.roc` calls it:

```roc
program = App.program({
    init!: |_started| Ok({}),
    database: Sqlite("data/plate.db"),          # optional: Sqlite("data/app.db") by default
    cross_site: Refused,                        # optional: Refused by default
    openapi: Page(Swagger),                     # optional: Off by default
    plugins: [Email.plugin({})],                # optional: none by default
})
```

`App.program` fills in the rest: every route behind its directories' middleware (`+middleware.roc`
files under `routes/`, `routes/+middleware.roc` around every request), the migrations in
`migrations/*.sql` (embedded), the actor methods the app's modules define, `logs: { format: Auto }`
and the routes' claims. `App.jobs` lists the kinds of job the modules define, for the jobs plugin.
To change the log format, update the record: `{ ..App.program({ … }), logs: { format: Json } }`.

### `init!` and the app's context

`init!` runs once, when the server starts, after the migrations, so it may read the database. It
is given the text of `--context-file` (empty without one). Its `Err` stops the server.

The context it makes is whatever the app wants to read everywhere: settings, handles, even
functions. The host keeps it boxed for as long as the server runs (D-065) and hands it to every
call that runs the app's code: a request (`respond!`), a job's run, an actor's turn, and a
plugin's calls, loops, starts and checks. Nothing changes it, and Roc's reference counts are
atomic, so calls on every thread share it at once. It is never copied or freed.

A call made while `init!` runs can't have the context yet. If `init!` asks an actor, for example,
the ask is refused with a message saying so; only the platform's own calls run before the context
exists. `server/test/context.test.mjs` checks all of this.

## Endpoints: the contract and its handlers (D-037)

An endpoint is a method in a route's `+server.roc`. `rocx build` turns the route files into two
modules: a contract that both programs share, and the handlers only the server has.

```roc
# routes/b/[board]/+server.roc: every handler is annotated; rocx build copies its types into Api
get! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member } => Try(Board.Data, Endpoint.Refusal)

# Generated/Api.roc, the contract: the same in the browser's copy; any module may import it
get_b_board : { board : Str } -> Endpoint(context, {}, Board.Data)
get_b_board = |params| Endpoint.remote("GET", "/b/${Server.encode_segment(params.board)}")

# Generated/Handlers.roc, the server's alone: what Routes answers with
get_b_board = |params| Endpoint.bind(Api.get_b_board(params), |request, context, {}| BBoardServer.get!({ request, params, context }))

# any module's handler (an MCP server's tools too): in-process, through the route and its middleware
Endpoint.send!(Api.get_b_board({ board: "launch" }), {})
```

**`Generated/Api`** says what each endpoint is: its method, its URL, and the types its handler's
annotation gives (its params, its body, its answer; a channel's `Channel(who, message, said)`;
what `events!` streams). Its context type is left open. It imports the modules those types name,
and no route file. So a store module, a job, an actor or another route can import it and call
`Endpoint.publish!(Api.channel_b_board({ board }), news)` with full types.

`rocx build` refuses, at the handler's line: a handler without an annotation, an annotation it
can't read, and a type defined in the route file itself (Api can't import the route file, so move
the type into a module of its own).

**Typed params (D-092).** A param is `Str` unless the annotation says otherwise:
`params : { id : I64 }` (a number, `Bool`, or a union of tags written out, `[Draft, Live]`, as
well). The router reads the path's part as that type (with `FormBody`, as a form's field), and a
part that doesn't read is no match: a 404, before the route's middleware or handler runs. The type
is the param's directory's: every handler under `routes/monitors/[id]/` that names `id` gives it
the same type, and the pages and layouts there are given it too (`view! = |{ params }|`,
`Paths.monitors_id({ id: 7 })`). Api's and Paths' URLs write it back with `Server.encode_param`,
and `/openapi.json` gives the parameter its type's schema.

```roc
# routes/monitors/[id]/+server.roc
get! : { request : Server.Request, params : { id : I64 }, context : {} } => Try(Report.Detail, Endpoint.Refusal)
get! = |{ params, .. }| Status.detail!(params.id).map_err(Store.refused!)

# Generated/Api.roc
get_monitors_id : { id : I64 } -> Endpoint(context, {}, Report.Detail)
get_monitors_id = |params| Endpoint.remote("GET", "/monitors/${Server.encode_param(params.id)}")
```

**`Generated/Handlers`** binds each contract to its handler with `Endpoint.bind`, so the compiler
checks that they agree. It imports every route file. `Generated/Routes` answers requests with these
endpoints. Code that calls an endpoint on the server sends Api's contract with `Endpoint.send!`: the
host answers it in-process (`roc_fetch`, then `in_process`), through the app's `respond!`, so the
endpoint's middleware runs, with the request's headers (cookies, `authorization`), the method, the
body and its `content-type` (D-103). A route file that answers with another route's handler
directly binds it itself, as `site/routes/calls/+server.roc` does:
`Endpoint.bind(Api.x(params), |r, c, b| XServer.post!(…))`.

**An answer of its own (D-106).** A handler's `Ok` is sent as JSON, unless its annotation's answer
is `Server.Response`: then `Ok(response)` is sent as it is, a text, a file, a redirect that sets a
cookie, and its refusals are as any handler's. `Generated/Routes` answers it with
`Endpoint.respond_as_is!` (the rest with `Endpoint.respond!`), and `/openapi.json` gives it any
type and no schema (`OpenApi.as_is`). Its contract's answer is `Server.Response` too, which the
typed client doesn't read: a page links to it, posts a form to it (a redirect is followed, D-095),
or reads a submission's `error!()`, never its `result!()`.

```roc
# routes/api/_verify/[file]/+server.roc: the file a service fetches to check the site is ours
get! : { request : Server.Request, params : { file : Str }, context : c } => Try(Server.Response, Endpoint.Refusal)
get! = |{ params, .. }|
	if params.file == "token.txt" {
		Ok(Server.response(200, [{ name: "content-type", value: "text/plain; charset=utf-8" }], "token=abc"))
	} else {
		Err(NotFound)
	}
```

A handler that answers JSON but sometimes its own (a cookie with its result, a plain form's
redirect) keeps its result's type and answers those with the refusal `Answer(response)`, sent as it
is too.

How endpoints read their bodies and answer forms is under Forms, below.

## The database: `Db`

### Choosing a database (D-045, D-046)

An app names its database in its program and writes its SQL for that database. Nothing is
translated.

| Program says | Where | Notes |
| --- | --- | --- |
| `Sqlite(path)` (the default: `Sqlite("data/app.db")`, D-105) | A file at `path`, relative to where the server starts | Made, with its directory, when missing: the app runs with nothing set. `--database-url sqlite:<path>` puts it elsewhere. |
| `Postgres` | `--database-url`, or `DATABASE_URL` | Without a URL the app has no database, and every statement says so; but if the app or a plugin has tables (migrations), the server doesn't start without one, outside `--dev` and `--debug` (where a line on the log says so). |
| `Turso(path)` | The same, on Turso's engine | `turso:<path>` runs a SQLite app on Turso; `sqlite:<path>` runs a Turso app on SQLite. |

A URL of the wrong kind (a `postgres://` URL for a SQLite app, say) stops the server at start,
saying which kind the app wants. `Db.backend!` answers `Postgres`, `Sqlite` or `None` (Turso
answers `Sqlite`, since its SQL is SQLite's); `Db.engine!` tells SQLite and Turso apart. A package
with SQL for both (packages/jobs) asks `Db.backend!`.

A package says which databases it works with in its plugin's `needs` (`Database` for either,
`Postgres`, or `Sqlite`, which Turso meets), and each of its migrations says which it is for
(`on: Postgres`, `on: Sqlite`, or `Any`, the default). The start refuses a plugin that needs the
other kind, and applies only the migrations for the app's kind.

### The backends

The host has one backend per kind in `host/src/db/`, behind the same functions (`db/mod.rs`).

- **Postgres** (`postgres.rs`): a pool of up to 16 connections (deadpool), opened as they are
  needed, plus one connection that `LISTEN`s for `Db.notify!`. Connections use TLS when the server
  offers it, or when the URL's `sslmode` requires it, checked against the web's certificate
  authorities.
- **SQLite** (`sqlite.rs`): rusqlite, with SQLite compiled in (FTS5 and JSON included), in WAL
  mode. A pool of 8 connections whose calls run on tokio's blocking threads, so a paused call
  holds no Roc thread. Reads go on beside a write. Writes take turns, each waiting up to 10 s for
  the one before. A transaction begins `immediate`, taking the write lock at its start, so two
  transactions never deadlock: keep anything slow (`Http.fetch!`, a sleep) out of one, since it
  holds back every other write. A statement still running at its call's time limit (a job's) is
  interrupted, and its connection closed.
- **Turso** (`turso.rs`, D-046): `turso_core`, SQLite rewritten in Rust, on a file in SQLite's
  format. It mirrors `sqlite.rs`: 8 connections on blocking threads, statements prepared once per
  connection, interruption at the time limit. It drives each statement's steps itself, sleeping
  the delay Turso asks for before retrying a lock. While the server runs, Turso holds an OS lock
  on the file, so no other program (`sqlite3`) can open it. Turso has no FTS5, and no `order by`
  inside an aggregate (`json_group_array(value order by key)`, which examples/board uses).

SQLite is in every host; Postgres and Turso are cargo features of server/host (`postgres`,
`turso`), both on by default. `rocx build --release` and `--image` build the host with the engine
the app's program names alone (D-104), so a release refuses another as it starts.

**Turso writes concurrently (D-049).** Its file is in MVCC mode. `Db.transaction!` begins
`concurrent`, each transaction on its own snapshot. When it loses to another transaction's write
to the same row (`Conflict: …`), the host notes it (`Host.db_conflicted!`) and `transaction!` runs
its body again, after a random pause that grows each time so a slow writer isn't starved. A write
outside a transaction is a concurrent transaction of its own, retried by the host (up to 100
times). A schema change must run exclusive: a statement refused for that (`Exclusive: …`, as a
migration's first run is) makes the call's next transaction begin `immediate`. In MVCC mode the
file is Turso's alone, and SQLite's backend refuses it; start once with `turso:<path>?mvcc=off` to
give it back (writes then take turns, as on SQLite).

### Statements, parameters and rows

```roc
notes : Try(List({ id : I64, body : Str, note : Db.Nullable(Str) }), [DbErr(Str), BadRow(Str)])
notes = Db.all!("select id, body, note from notes where author = $1", [Int(author)])

note : Try({ body : Str }, [NotFound, DbErr(Str), BadRow(Str)])
note = Db.one!("select body from notes where id = $1", [Int(id)])        # the one row, or NotFound

added = Db.run!("insert into notes (body) values ($1)", [Text(body)])     # the rows changed

Db.transaction!(|{}| {
    _ = Db.run!("insert into orders …", […])?
    Job.enqueue!(receipt, { order }, {})?                 # queued only if this commits
    Ok(order)
})
```

Parameters are `$1`, `$2`… on both kinds, each a `Db.Value`: `Null`, `Text(Str)`, `Int(I64)` or
`Bool(Bool)`. They reach the host as JSON.

- Postgres is sent each one as text, and reads it as the type its place in the statement wants
  (`where id = $1` reads `Int(7)` as an integer).
- SQLite binds each as what it is (a `Bool` as 1 or 0), by name.
- On both, a parameter given and unused, or used and not given, is an error.
- A list is one parameter. On Postgres use `Db.array` (an array in Postgres's text form,
  `{"a","b c",NULL}`, each text quoted): `where tag = any($1)`, `tags @> $1`,
  `unnest($1::bigint[])`, given `Db.array(tags.map(|tag| Text(tag)))`. On SQLite, pass JSON text
  and read it with `json_each($1)`.

Rows come back as JSON, and `Json.parse` decodes each into the record the caller annotated, by
column name. `Db.one!` (D-096) reads one row: `NotFound` when the statement reads none, and the
first when it reads several, so a statement that may read several says which with `order by …
limit 1`. A column that may be null is read as `Db.Nullable(a)` (`Null` or `Some(a)`, `null` or
the value in JSON). A null in a column read as a plain value is `BadRow`, naming the column. The
record says what may be null, so the host never asks the catalog (D-022).

| From | Read as |
| --- | --- |
| Postgres | booleans, integers, floats, text, `json`/`jsonb`, `uuid`, timestamps and dates. Anything else needs a cast (`::text`). |
| SQLite and Turso | each value as what it is (an integer or a real a number, text a string). A column declared `boolean` is a `Bool`; one declared `json` is its JSON. A boolean computed in a statement (`exists (…)`) is 0 or 1, an `I64`. Read a blob through `hex(…)`. |

Each function's error is an open union (`[DbErr(Str), ..others]`), so one body can `?` a statement
beside other errors (packages/jobs' `JobErr`, the app's own).

### Transactions and notifications

`Db.transaction!` keeps one connection for the call. What the body writes, and the jobs it queues,
stay only if it returns `Ok`. An `Err`, a failing statement or a crash rolls everything back. A
call that ends with a transaction still open has it rolled back (and logged).

A `Db.transaction!` inside one (an app's helper with a transaction of its own, called in another,
as packages/auth's `admit!` is) is a level of it, a savepoint (D-076). The host keeps a count of the
call's levels and picks the SQL: `savepoint rocx_<n>` to begin one, `release savepoint rocx_<n>`
when its body returns `Ok`, and `rollback to savepoint rocx_<n>` (then `release`) when it returns
`Err` or a statement of it fails. So an inner `Ok` keeps its writes in the level around it, which
commits them or not; an inner `Err` undoes only its own writes and comes back to the body around
it, which may handle it and go on. What a rolled-back level notified is dropped (Postgres drops
it itself), so a job it queued is never queued and wakes nobody. A crash rolls everything back, as
before. All three engines have savepoints: Postgres, SQLite, and Turso in MVCC and WAL
mode. On Postgres a failing statement aborts the transaction until its level rolls back: a level
whose body drops such an error and returns `Ok` can't be released, so the host undoes it and the
inner `transaction!` returns the error.

On Turso's MVCC a level that loses to another's write isn't run again on its own: Turso has rolled
the whole transaction back already. The host marks the transaction broken: every statement after
that fails with the conflict at once (none runs outside the transaction), and so does its commit.
`Host.db_conflicted!` answers false while a transaction is open, so only the outermost
`transaction!` runs its body again, once the error has reached it.

`Db.script!` runs statements with no parameters. `Db.notify!(channel, payload)` tells
`Db.listen!`'s listeners (the live topic `db:<channel>`, read with `Live.next!`) when the call's
transaction commits, never if it (or the level it was told in) rolls back, or at once outside a
transaction. On Postgres it is `pg_notify` (the listening connection publishes what it hears); on
SQLite it is the server's own. This is how the job workers hear that a job was queued.

### Migrations

Migrations are compiled into the executable: `program.migrations` lists them, each a name and its
SQL (`import "migrations/0001_tables.sql" as tables : Str` reads a file at compile time;
`App.program` embeds `migrations/*.sql` for you). At start they run in order:

1. the platform's own tables (`rocx/0001 jobs and actors`, … : actors' state and timers),
2. the plugins' tables, each recorded as `<plugin>/<name>` (the jobs plugin's is `jobs/0001_jobs`),
3. the app's.

Each runs once, in a transaction of its own, and is recorded by name in `rocx_migrations`. One
that fails stops the server. Two servers starting at once (a deploy's old and new) take turns: on
Postgres with an advisory lock, on SQLite with its write lock.

### Checked queries: `rocx check --sql` (D-058)

`rocx check --sql <app>` checks an app's SQL against its own database engine:

1. rocx finds each `Db.all!`, `Db.one!` and `Db.run!` whose SQL is a string literal at the call.
2. It builds the app's server (as `rocx dev` builds it) and runs it with `--describe-sql FILE`.
   That answers no HTTP. It runs the platform's start on a scratch database of the app's kind
   (every migration applied), prepares each statement without running it, prints what the engine
   says of each as JSON, and removes the scratch database (`db/check.rs`).
   - SQLite and Turso: a file in a directory of its own under the system's temporary directory.
   - Postgres: a database (`rocx_check_…`) made on the server `--database-url` names and dropped
     after, which needs `CREATEDB`. The check never migrates a database nobody named for it,
     since the app's URL may be a real one. Without `CREATEDB` it fails, saying to grant it or to
     name a database it may migrate (`--sql-database URL`, or `ROCX_SQL_DATABASE`).
3. For each statement the engine gives its error, or its parameters and columns: each column's
   name, type, how the host reads it (`kind`), and, for a column straight from a table, that
   column and whether it is `not null` (from SQLite's column metadata, Turso's plan, or Postgres's
   `pg_attribute`). rocx reports what the engine refused, and a call whose parameter list isn't
   `$1` to `$n`, at the call's line.
4. Then it checks rows with the compiler. For each `Db.all!` or `Db.one!` whose row type rocx can
   read (a binding's annotation, `rows : List(T)` for `all!` and `row : T` or `Try(T, …)` for
   `one!`, or the result type of the function the call is the body of), rocx writes a check app beside a copy of the app's sources (`build/sql/check`), with a
   `DbCheck.Rows(T, Tags)` for each, and runs `roc check`. `packages/dbcheck` reads `T`'s shape
   and refuses a field the statement doesn't return, a type the column's values can't decode
   into, or a plain field over a column that may be null. rocx reports each at the call.

A check app that doesn't compile for another reason fails the check (exit 1), saying what the
compiler said, since its rows weren't all checked. So does a server that can't describe the
statements. rocx counts what it couldn't check: SQL interpolated (`${…}`), SQL in a variable, and
`Db.unchecked(sql)`, which marks a statement on a table the app makes at runtime.
`--engine turso` checks a SQLite app on Turso (`sqlite` the other way). `rocx dev` runs the check
after each build, and `just examples` runs it on every example. `test/check-sql.test.mjs` tests it
on this platform's Postgres test app.

### Time zones, and roc-pg

`Time.offset!(zone, at)` gives an IANA time zone's offset from UTC at a moment (the host's
chrono-tz), which a SQLite app uses to work out a local day, since SQLite knows no zones.

[roc-pg](https://github.com/niclas-ahden/roc-pg), a Postgres client written in Roc that checks its
queries against a schema at compile time, runs on this platform: it connects with `Tcp.connect!`
and logs in with `Random.seed_u64!`. `server/examples/roc-pg` uses the same `schema.sql` as its
migration and as what roc-pg checks against; `server.test.mjs` builds and runs it (it downloads
roc-pg on its first build).

## Jobs, cron and email: plugins

Jobs, cron and email are packages, each a plugin built on the platform's general effects. They are
not part of the platform.

- **Jobs and cron** (packages/jobs, D-034): `Job.plugin({ jobs: App.jobs, crons })` adds the
  queue's table, its workers (background loops), its schedules, and a sweep of finished jobs
  (`jobs.sweep`: at start and every hour, done ones a week after they finished, failed and
  canceled ones after 30 days; `keep_done_ms`, `keep_failed_ms`, `sweep_ms`), on Postgres or
  SQLite. They use the database and its notifications, background loops, and isolated calls with
  time limits. A job is queued with `Job.enqueue!(kind, input, {})`, the options a record with
  defaults (`{ when: At(ms) }`, `{ key, … }` for `enqueue_keyed!`). The jobs page is
  packages/admin's (`JobsPage.plugin`). See `packages/jobs/README.md`.
- **Email** (packages/email, D-035): `Email.plugin({})` sends over SMTP (`SMTP_URL`, `MAIL_FROM`)
  on `Tcp` with TLS. Without an SMTP server it keeps mail in `Kv` only under `--dev` (the dev
  mailbox at `/__rocx/mail`, an early path) or `--debug` (for tests); anywhere else its start
  fails, so the server doesn't start rather than lose every email (D-079). It checks the SMTP
  server once the server has started. See `packages/email/README.md`.

## Requests to other servers: `Http`

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

# through a proxy this request names (else HTTPS_PROXY / HTTP_PROXY, unless NO_PROXY says)
res = Http.fetch!(url, { proxy: Via("http://user:secret@proxy.internal:3128") })?

# an answer as it comes, its head and then each chunk: a model's words, passed on as they arrive
Http.fetch_chunks!(url, { method: Post, body: Http.json(prompt), timeout_ms: 0 }, {}, |{}, received|
    match received {
        Head(res) => if (res.ok) Ok({}) else Err(Refused(res.status))
        Chunk(bytes) => send!(Str.from_utf8_lossy(bytes))
    })?
```

### `Http.fetch!`

`Http.fetch!(url, init)` works like JavaScript's `fetch`, but waits for the whole answer (D-024).
Every field of `init` (an `Http.Init`) has a default, so `{}` is a GET:

| Field | Default | Meaning |
| --- | --- | --- |
| `method` | `Get` | `Get`, `Post`, `Put`, `Patch`, `Delete`, `Head`, `Options`, `Other(Str)` |
| `headers` | `[]` | `(name, value)` pairs |
| `query` | `[]` | pairs, percent-encoded onto the URL (after an `&` if it has a query already) |
| `body` | `Empty` | `Http.json(value)`, `Http.form(pairs)`, `Http.plain_text(text)`, `Http.bytes(list)` |
| `timeout_ms` | 30 000 | from connecting to the body's last byte; 0 for none |
| `max_bytes` | 64 MiB | the most the body may be; 0 for any |
| `redirect` | `Follow` | or `Manual`: a redirect is the answer |
| `proxy` | `FromEnv` | or `Direct`, or `Via(url)` (below) |

The body helpers set a `content-type` unless `headers` has one: `application/json`,
`application/x-www-form-urlencoded`, `text/plain; charset=utf-8`, and none for bytes. Annotate a
record you build on as `Http.Init`, so record updates (`{ ..authed, … }`) type-check.

Any status is an answer: `Ok(HttpResponse)`, with `res.status`, `res.ok` (2xx), `res.headers`
(names in lower case), `res.header(name)` (any case), `res.text()` (UTF-8, lossy), `res.json()`
(the type wanted, or `Err(InvalidJson(why))`) and `res.bytes()`. An `Err` means there was no
answer:

- `HttpErr(why)`: the address, the connection, TLS, HTTP itself, or a header with a line break;
- `TimedOut`: no whole answer in time;
- `TooLarge`: a body over `max_bytes`, refused by its `content-length` or as it passes the limit.

### Streaming an answer: `Http.fetch_chunks!`

`Http.fetch_chunks!(url, init, start, step!)` makes the same request but never holds the body
whole. It calls `step!` with `Head(res)` first (status and headers, body empty), then with
`Chunk(bytes)` for each part of the body as it arrives. Each call gets what `step!` answered last
(`start` first); its answer after the last chunk is the result. An `Err` from `step!`, or a crash
in it, ends the request and closes its connection (`Err(Stopped(why))`). `timeout_ms` runs from
the request to the body's last byte, and `max_bytes` counts every chunk, so set both to 0 for a
long stream. The host keeps the open body for the call, as it keeps `Tcp` sockets (D-056).

### How the host makes requests

`host/src/client.rs` uses hyper's HTTP/1.1 client over rustls, checked against `webpki-roots`. The
call pauses while it waits, as for `Db` and `Tcp`.

- **Redirects** are followed as `fetch` follows them, at most 20: a relative `location` against
  the URL that answered; a 303 (or a 301 or 302 to a POST) becomes a GET without its body;
  `authorization` and `cookie` are not sent on to another origin.
- **Headers:** `host` and `content-length` are added unless given. Nothing is decompressed: send
  `accept-encoding` and you get the body as the server sent it. An answer to a HEAD has no body.
- **Kept-alive connections** (D-056): a pool of idle connections per place (scheme, host, port,
  and the proxy on the way), at most 32 idle per place, any number open at once. An idle one is
  kept 30 s, or a second less than its server says (`keep-alive: timeout=5`). A connection goes
  back to the pool once its body has been read to the end. A body dropped part-read (over
  `max_bytes`) is drained if the rest has arrived, else its connection is closed. When a kept
  connection turns out to be closed by its server, the request is made again once on a new one,
  if it was never sent or may be sent twice (GET, HEAD, OPTIONS, TRACE, PUT, DELETE, or a request
  with an `idempotency-key`), as Go's client does. `Server.forward` uses the same pool.
- **Proxies** (D-056, `proxy.rs`): `FromEnv` reads the environment as Go does: `HTTPS_PROXY` for an
  `https` URL, `HTTP_PROXY` for an `http` one (lower case too, upper case first). It never proxies
  `localhost`, a loopback address, or a host `NO_PROXY` names (a comma list of `*`, addresses,
  ranges such as `10.0.0.0/8`, `example.com` for it and its subdomains, `.example.com` for the
  subdomains only, each with an optional `:port`). `Direct` uses no proxy; `Via(url)` uses that
  proxy for every host, loopback too. A proxy URL is `http://` or `https://` (TLS to the proxy),
  with optional percent-encoded credentials sent as `proxy-authorization`; `host:port` alone means
  `http://`. Anything else (`socks5://`) is an `HttpErr`, never a silent bypass. An `http` request
  goes to the proxy whole (absolute URL in the request line); an `https` request goes through a
  `CONNECT` tunnel with TLS to the server inside it, so the proxy sees none of it. A refused tunnel
  is `HttpErr("the proxy … refused a tunnel to host:443: HTTP/1.1 407 …")`.

### The deprecated API

The API from before `fetch!` (`Http.Request`, `Response`, `Opts`, `defaults`, `send!`,
`send_request!`, `get`, `post_form`, `post_json`, `with_header`, `header`, `text`) still works and
is `fetch!` underneath. It will go in a later release. packages/storage's S3 client still uses
`Http.send!`.

## Files: packages/storage and `Blobs` (D-047)

Files are a package (`packages/storage`) that names this platform. An app makes a bucket from a
URL in its environment; the URL's scheme picks the backend:

- `s3://…`: any S3 (rustfs or MinIO in development, R2 or AWS in production), each operation a
  signed request over `Http`;
- `file:<dir>`: a directory beside the server;
- `memory:`: the server's memory, for tests.

```roc
# main.roc's header: storage: "../packages/storage/main.roc"
bucket = Storage.from_url(Env.var!("STORAGE_URL") ?? "")?
Storage.put!(bucket, "images/${id}", bytes, { content_type: "image/jpeg" })?
Storage.serve!(bucket, "videos/${id}", request, { content_type: "video/mp4", cache_control: "private" })   # an answer
```

The host keeps `file:` and `memory:` objects (`host/src/blobs.rs`, the platform's `Blobs`): put,
get, a range, head, delete, the keys under a prefix, and joining parts in order (a multipart
upload's end). A put is written to a temporary file and then renamed into place, so a crash never
leaves half an object. Each object's content type and ETag (its MD5) are kept beside it, in
`<dir>/.storage/`. A key that would leave its root (`..`, a leading `/`, an empty segment) is
refused. File operations run on tokio's blocking threads.

`Storage.serve!` never brings an object into Roc. From S3 it answers with a `Forward` (below). From
a directory or memory it answers with `Stored` (`Server.stored(root, key, request, headers)`),
which the host sends as it is: with its length, type, ETag and `last-modified`; 206 for one
`Range` (416 past the end); 304 for a matching `If-None-Match`. Signed URLs for a directory or
memory are answered by the storage plugin's `/__storage` route. `packages/storage/README.md` has
the rest: URLs, operations, errors, signed URLs and limits.

## Bodies as bytes: `request.body` and `Server.bytes`

```roc
Server.text_of(request)                  # the body as text (UTF-8; U+FFFD where it isn't): JSON, a form
Storage.put!(bucket, "images/${id}", request.body, { content_type: "image/jpeg" })?  # the bytes as they came
Server.bytes(200, [{ name: "content-type", value: "image/jpeg" }], cover)       # sent as they are
```

A request's body is `List(U8)`, never decoded on the way, so an upload is exactly the bytes the
client sent. `Server.text_of` reads it as text.

An endpoint reads its body only when the request says it is JSON (`application/json`, or a type
ending `+json`) or a form. For an upload of any other type (or none), the handler is given `{}` and
reads `request.body` itself. A body of another type sent to a handler that wants an arg is a 415.

`Server.request!({})`, the request a page or endpoint is answering, comes from the host as text,
so its body is `text_of`'s. A `Bytes` answer is sent as it is; `Server.body_text` reads one as
text. Bytes are held whole in memory, so send a very large answer as a `Forward` instead.

## Bodies from elsewhere: `Server.forward`

```roc
upstream = { method: "GET", url: "https://cdn.example/videos/41.mp4", headers: Server.passed_on(request) }
Server.forward(upstream, [{ name: "content-type", value: "video/mp4" }, { name: "cache-control", value: "private" }])
```

A `Forward` answer's body never passes through Roc. The host makes the request (`client.rs`'s
`open`, redirects followed) and sends the answer on as it arrives, so a 500 MB video costs Roc
nothing and starts at once.

- **Status and headers:** upstream's status is the answer's (200, 206 for a range, 304, 404…), with
  upstream's `content-type`, `content-length`, `content-range`, `accept-ranges`, `etag` and
  `last-modified`. The answer's own headers are added, or replace those. The answer's own status
  is ignored.
- **What upstream is sent:** `upstream.headers`, and nothing else. The host passes on nothing of
  the request: its cookies, range and cache questions stay here. `Server.passed_on(request)` gives
  the request's `Range`, `If-Range`, `If-None-Match` and `If-Modified-Since` for you to pass on; an
  app that changes the request record (drops a range that doesn't fit) changes what is asked.
- **HEAD** gets the headers and no body.
- **Errors:** an error upstream (400 or more) is answered with its status and reason (`Not Found`)
  as text, never with upstream's body (S3's XML names the bucket) nor the answer's headers; a 416
  keeps its `content-range`. Upstream not answering, a URL that isn't `http` or `https`, or a
  redirect that can't be followed is a 502; no head within 30 s is a 504. These are logged without
  the URL's query (a presigned URL's signature is there), as is an upstream error other than 404
  or 416.
- **Once the body flows,** each piece may take up to 60 s. If upstream stops short, the client's
  connection is closed, so a cut body is never passed off as whole.

## Cookies: `Server.set_cookie`

```roc
Server.set_cookie(answer, "__Host-session", token, { ..Server.cookie_defaults, secure: Bool.True, max_age_s: 30 * 86_400 })
Server.set_cookie(answer, "review", token, { ..Server.cookie_defaults, expires_ms: link.expires })   # until then
Server.clear_cookie(answer, "__Host-session", { ..Server.cookie_defaults, secure: Bool.True })
Server.with_cookie(answer, "member", name)               # set_cookie with cookie_defaults
```

`Server.CookieOpts` holds `Set-Cookie`'s attributes:

- `max_age_s` (`Max-Age`) and `expires_ms` (`Expires`, milliseconds since the epoch), each left out
  at 0. With neither, the cookie ends when the browser closes.
- `secure`, `http_only`, `same_site` (`Lax`, `Strict`, `None`), `path` and `domain` (each left out
  when empty).

`Server.cookie_defaults` is `Path=/`, `HttpOnly`, `SameSite=Lax`, this host only, until the browser
closes, over HTTP too. A `__Host-` cookie needs `secure`, `path: "/"` and no domain, and
`SameSite=None` needs `secure`: browsers drop cookies that break these rules. Give `clear_cookie`
the path, domain and `secure` the cookie was set with. Values are `%XX`-encoded, and
`Server.cookie(request, name)` decodes them. These functions are shared with the browser platform
(`web/platform/Server.roc`).

## Forms: typed bodies, files and the flash

```roc
# routes/members/join/+server.roc: a form posts { name }
post! = |{ body, .. }| if body.name.trim().is_empty() Err(BadRequest("a member has a name")) else Ok("Welcome, ${body.name}")

# the page it was posted from
Server.flash!({})      # Ok({ url: "/members/join", fields: [{ name: "name", value: "" }], status: 400, body: "a member has a name" })

# routes/orders/+server.roc: a form's fields, read by the body's types (D-038)
# item=tea&count=2&gift=on&toppings=milk&toppings=honey&size=Large
post! : { …, body : { item : Str, count : U64, gift : Bool, toppings : List(Str), size : [Small, Large] } } => …
```

### Typed bodies (D-038)

An endpoint's body has one type however it is sent. JSON (an action, a script) is read as JSON,
strictly. A form's fields (a plain form, or one the browser runtime sent) are read by the body's
types (`FormBody`):

- a number is read from its text (surrounding spaces dropped);
- a `Bool` is `on`, `true` or `1`, or `false`, `0` or empty; a missing one (an unticked box) is
  false;
- a `List` is every value its name has, in order; missing is `[]`;
- a tag without a payload is the one its text names (a `<select>`);
- a `Str` is the text as typed.

A missing `Str` or number (an empty number too), or text that isn't its type, is a 400 naming the
field (`the field count needs a whole number, 0 or more, not "two"`). A non-list field sent twice
takes its last value (a hidden default before a checkbox). Fields the record doesn't have are
ignored.

`Endpoint.remote` makes the form reader where `Generated/Api` gives the contract its types, and
`bind` keeps it (`Endpoint.local` makes one too). A function generic in its arg as JSON alone
(packages/mcp's tools) makes its endpoints with `Endpoint.local_json`, which reads a form's fields
as strings. In the browser, submissions read a form the runtime sent with the same reader
(`input!`, `pending_inputs!`).

### Checked bodies (D-093)

A route file may name the rules its method's body is read with, beside the handler: a value of
another module's with `parse(fields)` and `json_schema()`, which packages/forms' `Form(a)` is.

```roc
# routes/signup/+server.roc
## What POST /signup is sent: an account, read and checked by the form.
post_body = Signup.form

post! : { request : Server.Request, params : {}, context : c, body : Signup.Account } => Try({ welcome : Str }, Endpoint.Refusal)
post! = |{ body, .. }| Ok({ welcome: "Welcome, ${body.name}" })
```

`Generated/Api` makes the contract `Endpoint.checked(Endpoint.remote("POST", "/signup"),
Signup.form)` (in both copies, importing `Signup`, so the platform never depends on packages/forms),
and then:

- a form's fields (URL-encoded or multipart, with the URL's) or a JSON object's (text, numbers and
  yes-or-no as written, a list's items each a value, `null` none) are given to the rules, and what
  they read is the handler's `body`; a JSON body that isn't an object of such fields is a 400;
- what doesn't pass is refused before the handler runs: a 422 whose body is the issues as JSON,
  `application/json` (a plain form's comes back to its page in the flash, as any refusal does);
- in the browser, a submission to it is read with the same rules (`input!`, `pending_inputs!`:
  nothing for one that doesn't pass);
- `/openapi.json` documents the body with `rules.json_schema()`, as JSON, URL-encoded and
  multipart.

The body's type is the rules' record, the endpoint's arg, so it is a type JSON reads and writes (a
forms `Date` is its text; a `Try(x, [Missing])` field is one JSON may leave out). `Endpoint.send!`
and an action send it as JSON, which the rules read again. `post_body` must be `Module.name` (Api
copies it, and imports no route file), and only `post!`, `put!` and `patch!` have one; rocx build
says so at its line. A handler refuses what only it can check with the same shape:
`Err(Issues.refusal(issues))`, the platform's `Json(422, json)` refusal, sent as `application/json`.

### Files and fields in the URL (D-054)

A form with files (`multipart/form-data`: a form with an `<input type="file">`, or an action given
a file the page has) is read the same way: its text parts are fields, and a file's field holds the
file's name. `Server.file(request, "photo")` gives the file (`Server.Upload`: field, name, type and
bytes), `Server.files(request)` gives all of them, and `Storage.put_upload!(bucket, key, upload)`
stores one.

A form's URL query counts as fields too, before the body's (`Endpoint.with_fields`, Solid Router's
`action.with`: `/todos/toggle?id=7`). For a non-list field both have, the body's wins.

A file is part of the request body, read whole: over `--max-body` (16 MiB by default) it is a 413,
`the request's body is too large`, before Roc sees it.

A handler says which of the page's reads its result should refresh with
`Router.revalidate!(keys)` (Solid Router's revalidate keys). The host puts them in the answer's
`x-rocx-revalidate` header for the browser runtime. Without it, the runtime refreshes every GET the
page read.

```roc
# routes/photos/+server.roc: a title and a photo, from a form with a file
post! : { request : Server.Request, params : {}, context : c, body : { title : Str, photo : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ request, body, .. }|
	match Server.file(request, "photo") {
		Ok(upload) =>
			match Storage.put_upload!(bucket, "photos/${upload.name}", upload) {
				Ok({}) => {
					Router.revalidate!([Endpoint.url_of(Api.get_photos({}))])
					Ok(body.title)
				}
				Err(_) => Err(Status(503, "the photo wasn't kept"))
			}
		Err(NoFile) => Err(BadRequest("no photo"))
	}
```

### Plain forms and the flash

A plain `<form method="post">` posted without the runtime (a form body, from a page,
`accept: text/html`) would otherwise land on a page of JSON or text. So `Endpoint.respond!` answers
it with `Server.flash_back!` instead, for a result, a refusal, or a body it can't read (400):

1. A 303 back to the page the form came from (`Referer`, when it is this site's; `/` otherwise).
2. A flash: the URL posted to, the form's body as posted (however long), the status and the body.
   It is kept in the server's memory (the store `Kv` uses) for one minute, under a random id. The
   cookie `rocx-flash` holds only that id (`Path=/; HttpOnly; SameSite=Lax; Max-Age=60`).
3. Under `--debug` or `--dev`, the 303 also has `x-rocx-flash`: the flash's URL, status and body,
   never the fields, for tests (packages/testing's `flash`).

An answer of the endpoint's own (a handler's `Ok` whose answer is `Server.Response`, D-106, or
`Err(Answer(…))`: a redirect that sets a cookie, say) is sent as it is.

The page the browser lands on reads the flash with `Server.flash!({})`, or as its form's
submission (`Router.use_submission!(endpoint)`, which reads the flash when it is for that
endpoint): what was typed, and the result or refusal. The first read during a render takes the
flash from the store, so a replayed cookie finds nothing. The host keeps it for the page's other
reads and writes it into `<script type="application/json" class="rocx-flash">`, before the
answers, so the browser renders what the server did.

Passwords never come back: `Html` never writes a `value` into an `<input type="password">`, and the
page's note of the flash leaves out every field the page has as a password input.

`App.program` clears the flash cookie on the browser's next GET of a page (`Server.clear_flash`),
read or not, so a reload doesn't show it again. An app that writes its own program calls
`Server.clear_flash(request, answer)` itself.

### Forms the runtime sends, actions and scripts

With the browser runtime, a form posting to one of the app's endpoints is sent with `fetch`
(`x-rocx-submission: 1`, `accept: application/json`), whether its page reads its submission or not
(D-095). It gets the endpoint's result as JSON, or its refusal. An endpoint's own redirect comes back as 200 with `x-rocx-redirect` (fetch would follow a
303 before the runtime could read it), its cookies kept, and the runtime goes there.

An action (`Router.use_action!`, D-030) is sent by the runtime as JSON with
`x-rocx-submission: 1`; on success the runtime re-reads the page's reads. The server sees plain
requests, and an endpoint's own answer (`Ok` of `Server.Response`, or `Err(Answer(…))`: JSON with a
cookie, as the docs site's planner keeps a reader's week) is sent as it is. A script's post (JSON, or a form not from a page) gets the
endpoint's answer as always.

A handler that must answer each kind its own way asks `Endpoint.posted_by(request)`: `PlainForm`
(a form posted with no JavaScript, or before the runtime is there), `Runtime` (a form the runtime
sent, or an action) or `Other` (a script). examples/tasks' delete does this: a plain form is sent to
the list, and the runtime gets the list's id, which the task's own page goes to.

## Settings: `Env`

```roc
key = Env.var!("APP_SECRET")                                # Try(Str, [NotFound])
link = "${Env.public_url!({})}/unsubscribe?token=${token}"  # PUBLIC_URL, or where it listens
if (Env.dev!({})) dev_sign_in else Server.refused(404, "No page here.")     # started with --dev
```

`Env.var!` reads the server's environment: the app's secrets and whatever differs between machines,
read the same way in a request, a job or a schedule (twelve-factor; Phoenix's `runtime.exs`).

**`--env-file`** (D-088, D-098): as it starts, before anything else (its own settings, the log's,
the app's), the server reads the file `--env-file FILE` names (which must be there) into its
environment, so a key kept there (`ANTHROPIC_API_KEY`, `STRIPE_SECRET_KEY`, `SMTP_URL`,
`DATABASE_URL`) is read as if the shell had exported it, by the app and by every plugin. A variable
the environment already has keeps its value: the file is the default, the environment says
otherwise. `rocx dev` names the `.env` in the folder it runs in, when there is one, for its server
and its SQL check. Without the flag no file is read, a `.env` beside the server neither: a server
started by a test, by CI or in production has the environment it was given and nothing else, with
nothing for a harness to turn off. A flag, and no variable, names the file, as a variable would
reach every server started under it. The lines are dotenv's: `NAME=value`, `export
NAME=value`, `# comments`, a value in single quotes as it is, in double quotes with `\n`, `\t`, `\r`,
`\"` and `\\`, either over several lines; no `${NAME}` expansion. A line that isn't a setting stops the
server, saying which. The log names what was set and what the environment kept, never a value
(`rocx server: settings read`, as the server listens, in the app's log format). Keep `.env` out of
git: the repository's `.gitignore`, and `rocx new`'s, list it. The context file is for what
`init!` is given. `Env.dev!` says whether the server was started with `--dev`, and `Env.debug!`
with `--debug` (as tests start it). `Env.public_url!` is where the app is, for links it sends
(Running, below). The platform's own settings stay flags or their variables (`DATABASE_URL`, …); a
plugin reads its own (`SMTP_URL`, for packages/email).

## Time: `Time`

`Time.now_millis!` and `Time.now_nanos!` (D-026) read the clock. `Time.sleep!(ms)` waits: the call
pauses and holds no thread (D-027), so a request that waits on purpose (a retry's pause, a demo's
slow endpoint) holds up only itself. A job's time limit ends its wait. `Time.offset!(zone, at)`
is under The database, above.

## Sockets and randomness: `Tcp`, `Random`

`Tcp.connect!(host, port)` (or `connect_tls!`, or `start_tls!` on an open socket) opens a socket
for the call. `write_bytes!`, `read_exactly!`, `read_up_to!` and `read_until!` use it, and the call
pauses while each waits: 10 s at most to connect, 60 s for each read or write. The host uses
tokio's sockets, and tokio-rustls for TLS, checked against `webpki-roots`.

A socket belongs to its call. The host keeps it in a table of the thread the call runs on, taken
out while the call is paused, so nothing about it is locked or shared, and its id means nothing
to another call. A socket the call leaves open is closed when the call ends.

`Random.seed_u64!` and `Random.bytes!(count)` are the operating system's randomness (`ring`). If
the system gives none, the call crashes rather than make a key from anything weaker.

## Crypto: `AesGcm`, `P256`, and `packages/crypto`

```roc
sealed = AesGcm.seal!(app_key, plaintext)?                         # nonce ++ ciphertext ++ tag
opened = AesGcm.open!(app_key, sealed)                             # Try(List(U8), [BadKey, Forged])
signature = P256.sign!(private_key, public_key, message)?          # ES256: 64 bytes, r ++ s
{ public_key, secret } = P256.ecdh!(peer)?                         # a key pair for this call alone
{ public_key, private_key } = P256.generate!({})                   # a new pair: 65 and 32 bytes
record = AesGcm.seal_with_nonce!(key, nonce, plaintext)?           # ciphertext ++ tag
```

`AesGcm` is the host's (`ring`'s AES-256-GCM): a 32-byte key (`BadKey` otherwise) and a fresh random
12-byte nonce for each seal. Its output is Web Crypto's with the nonce in front, so each can open
the other's. Make the key with `Random.bytes!`, or derive it from the app's secret with HKDF.

`P256` is the elliptic curve P-256, also `ring`'s, as much as Web Push needs (packages/push, D-080):
ES256 signatures by a key pair (the private key's 32-byte scalar, the public key's 65-byte
uncompressed point; `BadKey` unless they are a pair), and ECDH with a key pair the host makes for
one call and forgets, answering its public key and the 32-byte shared secret (`BadKey` unless the
peer's key is on the curve). `P256.generate!` makes a pair to keep, in those two forms (D-097: the
push plugin's VAPID keys under `--dev`). `AesGcm.seal_with_nonce!` is AES-GCM with the caller's
12-byte nonce, for a protocol that derives its own (RFC 8188's `aes128gcm`): AES-128 under a 16-byte
key, AES-256 under a 32-byte one, the ciphertext then the tag. Anything else should use `seal!`: a
nonce used twice under one key gives the key away.

The rest is pure Roc, so it is a package on no platform (`packages/crypto`, D-025), which a page in
the browser may use too: `Sha256`, `Hmac` (HMAC-SHA256, and HMAC-SHA1 for TOTP, with a
constant-time comparison), `Hkdf`, `Base64` (both alphabets, strict), `Base32` (an authenticator
app's secret), `Hex`, and `Sha1` (for TOTP alone: D-081), each checked by `expect`s against
published vectors (NIST, RFC 2202, RFC 4231, RFC 4648, RFC 5869).

## Values in memory: `Kv`

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

`Kv` keeps values by key in the server's memory, for `ttl_ms` milliseconds (0, the default: until
the server stops). Nothing is written to disk, so use it for what is cheap to lose and read on
every request: rate limits, caches, one-time tokens, the dev mailbox. A value is kept as JSON and
read back as the type its reader asks for. Each operation is atomic. A new counter's or list's
time to live starts when it is made; later increments and pushes don't extend it. By convention a
key starts with its owner (`email:mailbox`).

The host keeps one map behind one lock (`host/src/kv.rs`), and nothing is awaited while the lock
is held. Expired entries go at the next operation. Past `--kv-max-mb` (64 MiB by default) the
least recently read or written entries go, never the one just written.

## Live topics and rooms: `Live`

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

Topics carry messages (`Live.publish!`) to every call listening (`Live.listen!`, then
`Live.next!`). Rooms count who is in them (`Live.join!`, `Live.count!`), and tell those listening
`join` and `leave`. What a call joins or listens to lasts until the call ends: for a stream, until
its client goes or it crashes. Each topic keeps a backlog of 256 messages; a listener further
behind misses the oldest. It is all in the server's memory (`live.rs`): there is one server, so
there is no broker. Channels are built on these topics.

## Channels (D-020, D-057)

A channel is a stream of live messages for a page, guarded by a route. The page subscribes with
`Endpoint.subscribe!` (see `web/README.md` for the browser's side).

```roc
# routes/org/[org]/news/+server.roc: behind the route's middleware, which hands on who is asking
channel! : { request : Server.Request, params : { org : Str }, context : Member } => Try(Channel(Str, News, [Hello(Str)]), Endpoint.Refusal)
channel! = |{ params, context, .. }| if context.org == params.org Ok(Channel.allow(context.name)) else Err(Forbidden)

receive! = |{ who, said, channel, .. }|        # what a page says: Endpoint.say!(channel, Hello("hi"))
    match said {
        Hello(words) => Ok(Endpoint.publish!(channel, { title: "${who} says ${words}" }))
    }
on_open! = |{ who, .. }| [{ title: "welcome, ${who}" }]   # sent first, after each Resync
on_close! = |{ who, tab, why, .. }| Log.info!("left", { who, tab })   # why: Dropped, Gone, or Refused(why)

# anywhere on the server: a request, a job, an actor
Endpoint.publish!(Api.channel_org_org_news({ org: "acme" }), { title: "Launch" })
Endpoint.publish_latest!(Api.channel_rooms_room({ room }), member, cursor)   # only the newest per key
```

### A channel route

A route's `channel!` is its check: it answers who the subscriber is (`Channel.allow(who)`), or a
refusal. Its type is `Channel(who, message, said)`. `rocx build` puts it in `Generated/Api` as
`Api.channel_<path>(params)` (method `CHANNEL`), typed from `channel!`'s annotation. Because Api
imports no route file (D-037), a job, an actor or a store module can import `Generated/Api` and
publish by name, typed: what it publishes must be the channel's `message`. The module that defines
that type can't import Api too (Api imports it); `rocx build` says so, and says to move the type
into a module of its own.

The route's hooks are all optional. Each is given the path's params, `who`, the tab's id and the
channel:

- `receive!`: what pages say (`Endpoint.say!`), after the same middleware and check;
- `on_open!`: messages sent first, each time a page subscribes (and after each resync);
- `on_close!`: told when a subscription ends, outside the middleware, and why:
  - `Dropped`: the page no longer subscribes (the component or effect that subscribed went), while
    the tab stays;
  - `Gone`: the tab's stream went (the tab closed or reloaded, its network went, the server
    stopped);
  - `Refused(why)`: the check, run again at a beat, now refuses.

### The tab's stream: `/rocx/live`

The host answers the tab's stream itself, on the async side, holding no Roc thread
(`host/src/channels.rs`): `GET /rocx/live?tab=<id>&c=<url>&c=<url>…`, as server-sent events. Roc
runs only briefly, one call at a time, for a check or a hook.

- **Hello.** The stream says its id first (`event: hello`): 192 random bits, the stream's alone,
  bound to its tab.
- **Opening a channel.** Each channel's check is a request the host makes of the app for the
  channel's own path, with the stream's headers (its cookies), `accept: application/json` and
  `x-rocx-channel: open`, behind the app's middleware and the route's, as a GET would be. A refused
  channel is `event: refused`, and the stream goes on for the others. One let in is
  `event: resync`, then its `on_open!` messages, then whatever is published on it. Its topics are
  listened to before the check runs, so nothing published meanwhile is missed (a message may come
  twice around a resync; a subscriber re-reads its data on `Resync` anyway).
- **Changing what a stream carries** (D-057). The page's hub posts
  `{"channel":"<url>","subscribe":true}` or `{"channel":"<url>","unsubscribe":true}` to
  `POST /rocx/live/send?tab=<id>&stream=<id>`. The stream opens the channel (check, `resync`,
  `on_open!`) or drops it (`on_close!` told `Dropped`, nothing more sent). The post's request
  headers (the tab's cookies as they are now) are used for that check and every later beat, so a
  page that signs in without a reload reaches the channels a member may. Hooks come in order on
  one stream: a channel dropped and subscribed again in one post hears its end before its start.
  A post naming no open stream of its tab (none, a wrong id, another tab's, one that ended) is
  refused with 404, and the hub opens a new stream.
- **Beats.** Every `--live-beat-ms` (15 s) the stream sends `: beat` and runs each channel's check
  again (`x-rocx-channel: check`). One that now refuses is `event: ended`, and its `on_close!` is
  told `Refused(why)`. A server error (500) at a beat ends nothing.
- **What pages say.** `POST /rocx/live/send?tab=<id>&stream=<id>` takes a JSON list of
  `{"channel":"<url>","message":…}` (each goes to the route's `receive!`, after its middleware and
  check: `x-rocx-channel: receive`), `{"channel":"<url>","resync":true}` (the stream resyncs that
  channel), and the subscribes and unsubscribes above. It answers 204, or 200 with
  `{"refused":[{"index":…,"status":…,"why":…}]}`. It takes JSON only, so another site's form can't
  send it without a preflight, and a post whose `Origin` isn't this host (as
  `Middleware.same_origin` reads it) is refused with 403, since the app's middleware never sees it.
- **A subscription's end** (dropped by the page, the client gone, the server stopping, or refused
  at a beat) is a request with `x-rocx-channel: close`, its body who the check said and why.
  `Generated/App` answers it outside the middleware, with the route's `on_close!`.
- **One stream per tab.** A new stream for a tab (the hub's, after a drop) first ends the tab's old
  one (`event: replaced`, for a page still reading it: a duplicated browser tab, which then takes
  an id of its own), and waits up to 10 s for its `on_close!`s before running its own checks. So a
  tab's hooks come in order: an old subscription's end before a new one's start.
- **Headers.** The host drops `x-rocx-channel` and `x-rocx-tab` from every request it is sent, so
  only the host can ask these questions.
- **Middleware.** `/rocx/live` never reaches the app's middleware, so an auth middleware has nothing
  to let through. Each channel's check runs behind its own directories' middleware instead.
- **Limits.** A stream carries at most 64 channels; a post at most 256 items and 1 MiB.

### Order, backlog and lost clients

- A channel's messages arrive in the order they were published: `Live`'s order per topic, one queue
  per stream. Messages are published on the `Live` topic `channel:<url>`.
- A subscriber that falls behind its topic's backlog (256 messages) gets `resync` (and `on_open!`'s
  messages) instead of what it missed.
- `publish_latest!` messages are a topic of their own, `latest:<url>`. A subscriber that falls
  behind gets only the newest per key, never a resync. They aren't ordered with the others.
- When a client's network goes away, the host notices through a 20 s deadline on unacknowledged
  writes (`TCP_USER_TIMEOUT` on Linux, `TCP_RXT_CONNDROPTIME` on macOS). A beat's write then ends
  the stream about 35 s after the client vanished, and `on_close!` is told `Gone`.

## Actors: `Actor`

An actor is state that outlives a request, changed one turn at a time. Use one when many requests
must update the same thing in order (a cart, a quota, a game room) without locks.

```roc
Carts := [].{
    State : { items : List(Str) }

    # The kind (D-068): its name (its actors' state is kept under it) and a new cart.
    name = |{}| "cart"
    initial = |_member| { items: [] }

    # Its methods' type, once: the kind, the app's context (its init!'s), the key, the state.
    Method(input, reply) : Actor.Method(Carts, {}, Str, Carts.State, input, reply)

    add : Carts.Method(Str, U64)
    add = Actor.method("add", |{ state, input, .. }| { state: { items: state.items.append(input) }, reply: state.items.len() + 1 })

    clear : Carts.Method({}, {})
    clear = Actor.method("clear", |{ .. }| { state: { items: [] }, reply: {} })
}

count = Carts.add.ask!(member, "a book")?        # waits for the reply: a U64
Carts.clear.tell!(member, {})                    # doesn't
timer = Carts.clear.tell_after!(member, 60_000, {})
Actor.cancel!(timer)
```

### Kinds and methods

A kind of actor is a type of the app's (D-068) with `name` (unique in the app) and `initial` (the
state of a new actor, from its key). `Actor.Kind` is a where alias: nothing declares it, and any
type with those two is a kind. Its methods are values (D-066), each `Actor.method(name, run!)` and
annotated with its kind's `Method`, which says whose method it is. You call a method on the
method: `ask!` (wait for the reply), `tell!` (don't), `tell_after!` (later).

A kind names its methods' type once, as `Carts.Method` above, with the app's context second. A
package doesn't know the app's context, so its alias keeps it as a parameter
(`Method(context, input, reply)`), written `_` where it is used (`Otel.Method(_, …)`).

### Keys (D-067)

A key is any type with `to_str`, which names its actor (in the host, the log and the database),
and `from_quote`, which reads that back (`Actor.Keyed`). `Str` has both. A type of the app's adds
them, and `from_quote` also lets a string literal be a key, checked when the app is built. A turn
is given the key as it is typed (`me.key()`), and so is `initial`, so an actor matches on its key
rather than parsing it:

```roc
Key := [YouTube, Instagram(Str)].{
    to_str = |key| match key { YouTube => "youtube"  Instagram(id) => "instagram:${id}" }
    from_quote = |written| …                           # Try(Key, [BadQuotedBytes(Str)])
}

Quota.reserve.ask!(Instagram(account), { units: 1, limit })   # a post's id here doesn't compile
Quota.reserve.ask!("youtube", { units: 1, limit })            # a literal, read when the app is built
```

### How turns run

An actor is a kind and a key. Nobody makes or ends one: a call to any key finds it as its last turn
left it, or new (`initial(key)`). A turn of a method is given `{ me, context, state, input }` and
answers `{ state, reply }`. An actor takes one turn at a time, whichever method each is, in the
order the messages came.

In the host (`host/src/actors.rs`), one task, the router, owns the table of awake actors and the
timers, and passes every ask, tell and timer to its actor's mailbox. Each awake actor is a task of
its own that runs its turns one after another, each a call into Roc (`actor_for_host!`). Nothing is
locked: the router's table is its alone, and the tasks talk over unbounded `tokio::sync::mpsc`
channels and `oneshot`s. So an actor takes what one sender sends it in the order it was sent, and
a hundred asks at once each see the state the one before left.

A method is given the actor itself (`me`): its key (`me.key()`), and its own timers
(`me.after!(ms, method, input)`, for a method of its own kind; another kind's doesn't compile). A
timer that repeats is one that sets the next.

`rocx build` lists the methods an app's modules define (`Actor.method`, at the top of a module's
block) in `program.actors`, and checks that each kind's name (`name = |{}| "…"`) is its own. Two
methods of one kind with one name stop the server at start, and the host refuses a call to a kind
the app doesn't have.

A call crosses to the host as the method's name and its input as JSON; replies and state are JSON
too. These are logged as errors (`rocx actor: a message failed`, with `actor`, `key` and `error`)
and told to the asker, and the actor goes on with its state unchanged:

- an input the method doesn't take (a caller built against an older kind, say);
- a method its kind doesn't have, or a kind the app has none of;
- a crash in the method.

An actor may ask another. An ask that would wait on itself (the actor asks itself, or any actor up
its chain of asks) is refused at once. An ask not answered in 30 s (a cycle through two mailboxes)
is given up on, and a message whose asker gave up before its turn came is dropped, with a warning.

### State and timers across restarts

With a database, an actor's state is read from `rocx_actors` on its first turn and written after
each turn that changes it, so it survives a restart. An actor idle for `--actor-idle-ms` (15
minutes; 0 for never) tells the router, which lets it go if nothing was sent to it meanwhile; the
next message wakes it as the database has it. Without a database, its state lives in its task
alone, and it stays awake.

Tells are in memory: a restart loses those not yet handled. Use a job for work that must survive a
restart.

Timers survive a restart when there is a database (D-057, like Orleans' reminders). Each is a row of
`rocx_actor_timers` (its number, whom it tells what, and when):

- `tell_after!` and `after!` write the row at once, in a call of their own, outside any transaction
  the caller has open (as a tell is sent at once).
- The row is deleted once the turn that handled the timer has ended, however it ended, so a
  message that crashes its actor isn't told again after every restart.
- The platform's start sets every row it finds again, for the time it has left (now, if that has
  passed). The host keeps the waiting timers.
- So a timer's message is told at least once: a server killed during its turn, or before its row
  was deleted, tells it again after the restart.
- A timer's number is random (63 bits), so one kept in an actor's state still names its timer
  after a restart.
- `Actor.cancel!` stops a timer that is waiting, or one that has fired but whose turn hasn't come
  (its message is dropped), and deletes its row.

Without a database, timers are in memory, and a restart loses them.

## Rendering pages of components

A route that answers `{ status, headers, body: Page(view!) }` has the host render the page, in the
same call that answered it (`render_page` in `host/src/signals.rs`). The page's box runs at the
root (`roc_run`), under the answer's own list of allocations, and gives its markup as JSON
(`Html.serialize!`). The host walks that markup exactly as the browser runtime's `renderToString`
does (`web/runtime.js`), byte for byte; the site's tests compare the two.

While rendering:

- Every hole runs once, with no tracking. A memo is computed when it is made.
- `<Loading>` renders what is inside it; nothing waits.
- A failure shows the nearest `<Errored>`'s fallback.
- An endpoint a component reads (`Endpoint.read!`) is answered in-process and noted (next section).
- Effects, cleanups and timers (`create_effect!`, `on_settled!`, `on_cleanup!`, `set_interval!`,
  `set_timeout!`) don't run, as in Solid. Their boxes are let go of, since nothing they would undo
  started. `is_pending!` is false.
- A `<NoHydration>` is static markup between its own markers, with no markers inside. The browser
  leaves it as it is. A handler inside one is refused (500), since it would never run.
- Inside `<title>` and `<textarea>` (RCDATA, which the HTML parser reads as text), holes are
  written without their comments, which would show. The browser binds them to the element's text.
- `<HttpStatusCode code={404} />` sets the answer's status (`Host.status!`). `<Navigate href>`
  makes the answer a 303 to `href`.
- A name markup can't have is never written (D-079): a tag that isn't an ASCII letter then
  letters, digits and `-`; an attribute name that isn't an ASCII letter then letters, digits, `-`,
  `_`, `.` and `:`, or that starts with `on` (an inline handler); a `<script>` whose children
  aren't the text a `.rocx` file wrote (`Html.source_text`). What isn't plain is left out (an
  element with what is inside it, or the attribute), the page renders around it, and the render
  logs one warning, `rocx server: markup named what a page can't have, which wasn't written`, with
  its `path` and the `names` (`plain_tag`, `plain_attribute`, `written_element` in `signals.rs`).

The answer is the whole document (`signals.rs`'s `document`, `titled` and `headed`):

- `<!doctype html>` first, unless the markup begins with one (`Html.doctype`);
- the last `<Title>` rendered (`Host.title!`) as `<title data-rocx>…</title>`, first in `<head>`
  (before the layout's own `<title>`), which hydration passes over, so the layout's `<head>`
  hydrates as it rendered;
- the `<Meta>`, `<Link>` and `<Style>` elements the page rendered (`Host.head!`), before
  `</head>`, a later one with an earlier one's key taking its place;
- just before `</body>`: the flash the page read (`class="rocx-flash"`), the answers its reads
  got (`<script type="application/json" class="rocx-answers">`), each plugin's script, and
  `<script type="module" data-rocx src="/rocx/start.js">` (with the build's id when the root told
  it, `Router.app!`), which hydrates the page in the browser.

It is `text/html; charset=utf-8` unless the answer says otherwise. Its status is the answer's, or
the one the page set while rendering. A HEAD isn't rendered: it gets the answer's status and
headers, and the page's box is released. A crash, or a failure no `<Errored>` catches, is a 500
(with the message under `--dev`). Whatever happened, the page's box and everything the render
held are freed when it ends.

### Endpoint reads while rendering

A component reads a GET endpoint with `endpoint.read!()` (or `endpoint.send!({})`, which gives a
refusal as a value; `endpoint.with_query(query)` adds a query). That asks the host (`Host.fetch!`, `roc_fetch` in
`signals.rs`).

While the host renders a page, a GET of one of the app's own paths (`/…`) is made in-process:
`respond!` answers it as it would the browser's GET, behind the route's middleware. The request
carries the page's headers (cookies included) except its conditions and range, `origin` set to
this host, and `accept: application/json`; it has its own guard and allocations.

- Its answer, whatever its status, is kept as `{"status":…,"body":…}` for the rest of the render,
  so a URL is asked once. It is noted for the page under `GET <url>`, unless it was read inside a
  `<NoHydration>`.
- A crash in it is a 500 (why, under `--dev`), logged.
- An answer that is a stream of events, a page or a body from elsewhere can't be read, and fails
  the read.
- Any other request (a POST, another site's URL) belongs to a browser handler: the render fails it.

A read that isn't 200 fails what read it, and the nearest `<Errored>` shows its fallback. If no
`<Errored>` of the page's catches it, it reaches the root one rocx writes, whose fallback is the
app's `+error.rocx`. That page is answered with the refusal's status when it is a 4xx
(`Errored.status_of`: a `NotFound` is the page's 404, as for a path no page has), else 500. A
boundary of the page's own that catches it shows its fallback, and the page is answered normally
(200, unless that fallback says otherwise with `<HttpStatusCode>`), as in the browser.

A read that its middleware answers with a redirect (a status from 300 to 399 with a `location`: a
signed-out visitor sent to sign in) makes the whole page that redirect, with the cookies it sets,
whether an `<Errored>` catches it or not (SolidStart does the same, D-019). In the root layout no
boundary is above the layout's own holes (the root `<Errored>` is inside it), so a failed read
there is a 500: a layout whose holes read the server should put its own `<Errored>` around them,
since those endpoints answer every page's visitors.

`Host.request!` is the request being answered, whole; `Host.location!` its path and query
(`Router.location!`); `Host.status!` the status its page is to be answered with.

An endpoint's handler runs only on the server, so it may use `Db`, `Job` and the rest. In the
browser's copy of the app, `Api` is the same contract, there are no handlers
(`Generated/Handlers` is the server's alone), and route files have no middleware.

## The log: `Log`

```roc
Log.info!("gate failed", { path: request.path, error: why })   # also debug!, warn!, error!
Log.line!("migrated")                                          # a message alone, at info
```

```
14:03:12 info  gate failed  error="no session" path=/admin
{"time":"2026-11-21T13:03:12.345Z","level":"info","msg":"gate failed","error":"no session","path":"/admin"}
```

Pretty (D-111): the local time, the level in lower case, the message, then two spaces and the
fields. At a terminal the time and the fields' names are dimmed and the level coloured (debug
grey, info cyan, warn yellow, error a bold red), so the message and the values stand out.

Under `--dev`, the server lists the places to open under its address as it starts: the app's
stories, its OpenAPI document, and what each plugin adds (`Plugin.Link`: the mailbox, the sign-in
page, the jobs page) and what the app names itself (`App.program({ links })`). A path is the
server's; a whole URL is listed as it is. In JSON it is one event, `rocx server: links`, a link a
field.

```
10:36:32 info  rocx plugins: jobs, email, auth
10:36:32 info  rocx server: http://127.0.0.1:8080 (Roc, native)
               ➜ Stories   http://127.0.0.1:8080/__rocx/stories
               ➜ OpenAPI   http://127.0.0.1:8080/openapi.html
               ➜ Mailbox   http://127.0.0.1:8080/__rocx/mail
               ➜ Sign in   http://127.0.0.1:8080/sign-in
```

Every line the server writes to stderr is an event: a level, a message and fields. The host's own
lines, the platform's Roc, its plugins and the app all go through one formatter in the host
(`logging.rs`). Fields are any record (`Json.Encodable`), written as JSON; `{}` is none. A record
with a single field must name it twice (`{ id: id }`), because `{ id }` alone is a block whose
value is `id`.

The platform and plugins log a fixed message and put the details in fields (D-056), so the lines
can be searched:

| Message | Level | Fields |
| --- | --- | --- |
| `rocx server: http://… (Roc, native)` | info | (the address is in the message) |
| `rocx server: settings read` | info | `file`, `set`, `kept` (names, never values: `--env-file`'s, D-088) |
| `rocx server: no database, so these tables aren't made, and what reads them fails` | warn | `tables` (under `--dev` or `--debug`) |
| `rocx server: Roc crashed` | error | `method`, `target`, `error` |
| `rocx server: migrated` | info | `migration` |
| `rocx plugins: <names>` | info | (the plugins started, in their order, in the message; one that adds nothing but links isn't named) |
| `rocx plugins: added` | debug | `plugin`, `adds` |
| `rocx server: links` | info | a link a field, its label its name (under `--dev`, D-111) |
| `rocx actor: a message failed` | error | `actor`, `key`, `error` |
| `rocx jobs: a job failed, and runs again` | warn | `kind`, `id`, `attempt`, `of`, `again_in_ms`, `error` |
| `rocx jobs: a job failed for good` | error | `kind`, `id`, `attempts`, `error` |
| `rocx jobs: finished jobs swept` | info | `count`, `keep_done_ms`, `keep_failed_ms` |
| `rocx cron: a schedule's job wasn't queued` | error | `cron`, `error` |
| `email: kept, not sent (no SMTP_URL)` | info | `to`, `subject` |

A plugin's check logs its message with `check` (`email.smtp`). Grep `host/src` and
`server/platform` for `"rocx ` to find the rest.

### The format

The app chooses it in `program.logs`: `{ format: Auto }`, `Pretty` or `Json`. `App.program` says
`Auto`; override it with `{ ..App.program({ … }), logs: { format: Json } }`.

- `Auto` is `ROCX_LOG` (`pretty` or `json`) if it is set; otherwise pretty when stderr is a
  terminal, and JSON when it isn't (a server whose log is collected).
- The host starts in `Auto`, so what it logs before the platform starts (a server that can't start)
  follows it. It takes the app's format in `init_for_host!` (`Host.log_format!`).
- **Pretty:** the local time, the level (coloured on a terminal), the message, then `key=value`. A
  value is quoted when it has a space, a quote, an `=` or a control character, or is empty; objects
  and lists are written as JSON.
- **JSON:** `time` (RFC 3339, UTC), `level` and `msg`, then the fields beside them.
- In both, a field named `time`, `level` or `msg` is written as `fields.time` (and so on), so it
  can't replace the line's own. A line is always one line.

### Off the request path

`Host.log!` and the host's own calls put a record on one queue and return at once. One writer
thread takes the records in order, formats them (parsing Roc's fields there), and writes them
through a 64 KiB buffer, which it flushes whenever the queue is empty. So a line is out at once on a
quiet server, and lines go out together on a busy one. With one first-in-first-out queue, a
request's lines come out in the order it logged them, and whole.

The queue holds 64k events. When it is full, a call that logs waits for room rather than dropping a
line. A log that loses lines when the server is busiest loses the ones most worth reading, and one
that grows without bound turns a flood of lines into a server out of memory. Waiting slows callers
to what stderr can take. The queue is flushed before the process exits: after a stop, after a
server that couldn't start, before an abort (a crash outside a guarded call, out of memory), and on
a panic (itself an event, `rocx server: the host panicked`). `--help` prints its usage as plain
text.

## Plugins: `Plugin` (D-033)

A plugin is what a package adds to an app, as one value the app lists.

```roc
# main.roc: the header names the package, `plugins` lists what it adds
app [program] { pf: platform "../server/platform/main.roc", acme: "../packages/acme/main.roc" }

import acme.Acme

program = App.program({ init!, middleware, plugins: [Acme.plugin({ at: "/acme" })] })
```

### What a plugin adds

A plugin is a `Plugin.Value(context, ctx)`: a name, plus any of these fields (each defaults to
`[]`). `context` is the app's context (its `init!`'s); `ctx` is what the app's middleware hands a
route. A plugin knows the type of neither.

| Field | What it is |
| --- | --- |
| `routes` | Answered behind the app's middleware, before the app's own routes, given `ctx`. |
| `early` | Paths under `/__rocx/`, answered before the app, only under `--dev` or `--debug` (as each says). |
| `files` | Served as they are, before anything else, the app's middleware included (D-050, below). |
| `scripts` | Paths of the plugin's own files that every rendered page loads. |
| `migrations` | Applied after the platform's and before the app's, recorded as `<plugin>/<name>`; each says which database it is for (`on`). |
| `calls` | Named functions run in a call of their own (`Plugin.isolated!("acme.render", input, limit_ms)`), so a crash ends only that call. |
| `loops` | Background loops, run until the server stops (`Plugin.stopping!`); one that crashes starts again a second later. |
| `starts` | Run after every migration and the app's `init!`; an `Err` stops the server. |
| `checks` | Run once in the background after the start; what they say is logged (an `Err` as a warning). |
| `needs` | Checked at start: `Env("ACME_KEY")`, `Database`, `Postgres`, `Sqlite`, `Plugin("other")`. |

Calls, loops and checks are named `<plugin>.<name>`, and are given the app's context. A package
makes its plugin from options of its own (a nominal record whose fields without a default are
required). A plugin generic in the app's context is a function even with no options
(`Acme.plugin({})`).

### Checks at start

At start, every problem with the plugins is collected, and any of them stops the server, a line
each (`Plugins.roc`):

- a name used twice, or not made of lowercase letters, digits and `-`;
- a call, loop or check not named `<plugin>.<name>`;
- an early path outside `/__rocx/`;
- two routes at one method and path (the app's, which `rocx build` lists in `Routes.claims`, and a
  plugin's, or two plugins');
- an unset variable, no database (or the other kind), a plugin not in the list, or needs in a
  circle;
- a file whose path isn't relative, a root file under `rocx/` or `__rocx/`, two files at one place,
  a root file where a route is, or a script that isn't one of the plugin's files.

Then the plugins are ordered by their needs (the list's order breaks ties), and the log names them
on one line (`rocx plugins: jobs, acme`), and at debug says what each added (`rocx plugins: added
plugin=acme adds="2 routes, 2 files, 1 script, 1 migration"`). A plugin's `links` (D-111) are the
places it adds that a person may want to open: under `--dev` the server lists them under its
address.

### Files and scripts (D-050)

A file is a `Plugin.File`, `{ path, at : [Plugin, Root], content_type, body : List(U8) }`, its bytes
embedded at build time (`import "static/acme-sw.js" as worker : List(U8)`). It is served at
`/rocx/plugins/<plugin>/<path>`, or at `/<path>` with `at: Root` (a service worker, whose scope is
where it is; `/.well-known/…`).

The start hands each file to the host once (`Host.plugin_file!`). The host serves it before
anything else, without calling into Roc: `GET` and `HEAD`, with its type, an ETag of its bytes (304
when `If-None-Match` has it), and `cache-control: no-cache` (`no-store` under `--dev`); any other
method is a 405. So an app's guard never blocks it.

Every page the host renders has a `<script type="module" data-rocx src="…">` for each script, after
the answers and before `start.js`, so a script has registered its effects
(`window.rocxEffects["acme.ping"]`, which `Browser.call!` finds) before the page wakes. Under
`--debug`, `GET /__rocx/plugin-files` lists the files (each URL, type, and whether it is a script):
`site/build.mjs` reads it to copy them into a static copy of a site.

### Packages that use the platform

A package whose modules use the platform names it in its header, as an app does
(`package [Acme] { pf: platform "../../server/platform/main.roc" }`). It must be the same file the
app names. Modules both halves can compile go in a second header beside it, `browser.roc`, which
`rocx build --client` names for the browser's half instead. Without one, the browser's half doesn't
see the package, and a page that imports it is told where. `server/test/fixture` is a plugin
package, for the tests.

## How a call runs

### Coroutines on Roc's threads (D-027)

Roc runs on threads of its own, one per core unless `--roc-threads` (or `ROCX_ROC_THREADS`) says
otherwise. tokio's threads, beside them, answer HTTP and drive every socket and timer
(`host/src/coroutine.rs`).

Each call into Roc (a request and the page it renders, a stream, an actor's turn, a background
loop, the platform's start) is a stackful coroutine with a stack of its own: 8 MiB, Roc's default,
reserved rather than used, above a 256 KiB guard. Whichever Roc thread is free starts it (they take
new calls from one queue), and it stays on that thread until it ends.

When an effect waits (Postgres, a socket, another server, a sleep, an actor's answer), the call
pauses: its stack stays as it is, its thread runs other calls, and the thread resumes it when the
future it waits on is done (`hosted::wait`). So a call that waits holds no thread, and any number
can wait at once: eight requests that each wait 0.3 s on Postgres take about 0.3 s together, and
the tests answer 2,000 requests that each wait a second, on two Roc threads, in about a second.

What the host keeps per call in thread-locals (its context, Roc's list of allocations, the jump
target, the page it renders, its sockets) is taken out while the call is paused and put back when
it resumes. A call never moves to another thread, because compiled code may keep a thread-local's
address across a call.

The costs:

- Roc that computes for a long time without an effect can't pause, so other calls on its thread
  wait for it (new calls go to the other threads). A call with a time limit is cut off anyway
  (below).
- A paused call keeps its stack, but only the pages it touched cost memory: a few tens of KiB for
  most.
- Profilers and debuggers see calls on their own stacks, not threads'.
- A call that overflows its stack hits the guard and the process ends, as a thread's overflow
  would. First it says so on stderr (`rocx server: a call into Roc overflowed its stack (8 MiB):
  the process ends`, in the log's format).
- Logging is the one wait that blocks a thread instead of pausing a call: when the log's queue is
  full, the call waits for room.

### Streams

A stream of events is a loop (`Events.stream(|{ send!, sleep! }| …)`), a call of its own for as
long as it is open. `send!` writes to the response, pausing while the client reads slower than it
writes. `sleep!` pauses, waking early if the client goes, so the next `send!` answers `Err(Gone)`
and `?` ends the loop. An open stream, or a background loop, holds no thread while it waits: the
tests hold 2,000 streams open on two threads and a request still answers at once.

A channel stream (`/rocx/live`) isn't a call at all: the host holds it, and Roc runs only for a
check or a hook.

### Crashes and memory

A crash ends the call it happened in, not the server. Roc's ABI says `roc_crashed` must never
return: it may end the process, or `longjmp` out of the Roc code that called it. The host does the
second. The guard (`host/src/guard.c`) sets a jump target around every call, and `roc_crashed`
jumps back to it. Then the request is answered 500 (with the message under `--dev`), a stream ends,
an actor's turn fails, or a job runs again later.

What the call allocated is freed (`host/src/roc.rs`). While a call runs, each allocation is linked
into the call's list.

- If the call returns, the answer's strings are copied out and freed. A stream keeps its list
  until the call that sends it; a page keeps its list while it renders (what its computations make
  goes in it too) and frees all of it at the end. A computation that fails may never give back its
  reference to the box it ran (in Roc's optimized code), so the list frees that box anyway.
- If the call crashes, everything in its list is freed.

The tests crash 200 requests at once, half after allocating 2,000 strings, and check that Roc holds
no allocations afterwards (`--debug`, `GET /__rocx/allocations`).

Calls nest (an isolated call, `Host.isolated!`; a job inside its worker), each with its own list,
jump target and context. The frames a crash skips are Roc's and a trampoline's, never the host's.
What a call holds (a transaction, sockets, rooms) is given back when it ends. An isolated call is
passed strings, which it copies, so a crash frees everything it was given; so is an actor's turn
(its kind, key, state and message), a call of its own that its actor's task starts.

An isolated call may have a time limit (a job's). The calls it runs share its deadline, and the
first effect that waits past it ends the call as a crash would (`cut_off` in
`host/src/hosted.rs`). The only host frame that skips is that effect's own, which holds nothing by
then.

### Cutting off Roc that never waits (D-057)

Roc that loops without an effect is cut off at its deadline too, in every build
(`host/src/preempt.rs`):

1. Each Roc thread keeps the deadline of the call running on it (none while it is paused).
2. A watchdog thread signals a thread whose call is past its deadline (SIGURG, with
   `pthread_kill`, to that thread alone), every few milliseconds until the call ends.
3. Each thread also has an "in Roc" flag. The guard's trampoline sets it once the jump target is
   set. Every function Roc calls in the host clears it on entry and restores it on return: its
   first line is `let _host = preempt::host();` (`roc_alloc` and its kin, every hosted function,
   the `RocHost` callbacks). `server/test/host-entries.test.mjs` fails on a function that lacks it.
4. The signal handler looks at where the thread was. With the flag set and the thread in the
   executable's own code (not a library's), it is in Roc's code, or in code that holds nothing a
   crash wouldn't. The handler makes the thread call into the host there, as `roc_crashed` would
   be called, and the call ends as a crash ends, skipping only Roc's frames.
5. Anywhere else (a hosted function, the allocator, a library, where a lock may be held) it only
   notes the deadline. The call ends at the next allocation Roc asks for (which only Roc's code
   calls), or at the next signal that finds it in Roc's code.

The tests cut off two jobs that loop forever without an effect (one on numbers alone, one making
and dropping text) within their time limit, with nothing left held, in a dev build and an optimized
one, and check that a parent process trapping SIGURG hears none.

### Background loops

At start the host asks the platform's Roc how many background loops to run
(`roc_background_count`): the plugins' loops and checks (the jobs plugin's workers, its
schedules' loop and its sweep of finished jobs, the email plugin's look at the SMTP server). Each runs as a call of its own until
the server stops; one that crashes is started again a second later (`rocx server: a background
loop crashed, and starts again in a second`). `Live.next!` in a loop answers `Gone` when the
server stops.

### Who owns a value

A value Roc makes belongs to its call until the call returns. After that the host owns it and
moves it (a stream to the call that sends it), never sharing it. Roc's reference counts are atomic
in LLVM builds anyway (`ldadd`/`ldaddal` in the app's object code), which is what lets every call
share the app's context.

## Building

`server/build.mjs` builds the host with cargo into `server/platform/targets/<target>/libhost.a`
(first copying the shared modules from `web/platform`), then the app with `roc build`, which links
the two into one executable:

```sh
node server/build.mjs <app.roc> <output> [--opt=dev|speed] [--target=arm64mac|x64mac|arm64musl|x64musl] [--specialize=yes]
```

- **Toolchain:** cargo is the one on `PATH` (from Nix, say), or else `.tools/rust` from
  `just setup`. Roc is the fork `just setup` links as `.tools/roc-active`, or else `$ROC`; never
  the `roc` on `PATH`, which may lack the fork's fixes.
- **Targets:** `arm64mac` and `x64mac` link against the system. `arm64musl` and `x64musl` are
  static Linux executables, cross-compiled from macOS: Rust's musl target supplies `rcrt1.o`,
  `libc.a` and `libunwind.a`, and Zig compiles the host's C (`guard.c`, and `ring`'s C for TLS).
  The test app built for `arm64musl` has run in a container against `just db`'s Postgres, and CI
  builds and tests every app for it, natively, on Linux arm64 runners (D-069).
- **`--opt`:** `dev` (the default) or `speed`.
- **`--specialize` (D-064):** an optimized build uses boxy lowering (`--specialize=no`) unless you
  pass `--specialize=yes` (`specialize: true` to `buildApp` or packages/testing's
  `buildForTests`), or set `ROCX_SPECIALIZE=yes` for every build. Specialized, Roc inlines every
  closure of a lambda set into the function that calls through it. An app's pages all sit behind
  one such call, so that function's stack frame grows with the app: with the Roc nightly, the docs
  site's reached 12.4 MB, past the 8 MiB a render runs on (`test/compiler-bugs/huge-frame-opt-speed`).
  Boxy calls a closure through a pointer: the site's largest frame is 28 KiB, pages render as fast,
  and builds take a fraction of the time. At the fork's pin 4674b5973d, a specialized site's
  largest frame is down to 264 KiB (TODO.md); whether specialization becomes the default again is
  D-064's to decide.

An app with routes is built to deploy with `rocx build <dir> --release <out> [--target …]`
(D-078), which needs no Node: the browser's copy and its wasm, then the server's host when it
changed and the app on it, optimized for speed (boxy, as below), into `<out>/server`, with what it
serves in `<out>/static`. `--opt speed|size|dev` (D-111) builds both programs at that level instead
(the server's default is `speed`, the wasm's `size`); `rocx dev` builds both at `dev` unless its
`--opt` says another.

`just glue` regenerates `host/src/roc_platform_abi.rs` after a change to `platform/main.roc`'s
header (with the other platforms' glue).

## Running

```
<app> --port 8080 --host 127.0.0.1        where to listen (PORT)
      --static DIR, --file /PATH=FILE     files served as they are
      --context-file FILE                 what the app's init! is given, once, as it starts
      --env-file FILE                     settings for the environment, read as it starts (none without it: a .env here isn't read unless named); the environment wins
      --database-url URL                  the database (DATABASE_URL): postgres://…, or sqlite:<path> (turso:<path>) for a SQLite (Turso) app's file elsewhere
      --actor-idle-ms 900000              an actor idle this long is let go (0: never; kept in the database)
      --kv-max-mb 64                      the key-value store's limit (KV_MAX_MB): the least recently used goes past it
      --max-body 16MiB                    the most a request's body may be (MAX_BODY): bytes, or KiB, MiB, GiB; 413 beyond
      --public-url https://app.example    where the app is, for links it sends (PUBLIC_URL; else where it listens)
      --dev                               reload pages on restart, show crashes, plugins' dev pages (/__rocx/mail)
      --debug                             GET /__rocx/allocations and /__rocx/plugin-files, and plugins' debug paths
      --live-beat-ms 15000                how often a channel stream beats, and its checks run again
      --roc-threads N                     the threads Roc runs on (ROCX_ROC_THREADS; one a core)
      --describe-sql FILE                 answer no HTTP: describe each statement FILE lists (a JSON array of SQL) on a scratch
                                          database the program's migrations are applied to, print what the database says, exit
      --sql-database URL                  for --describe-sql, a database it may migrate, in place of a scratch one (ROCX_SQL_DATABASE)
```

This is the host's own `--help` (`USAGE` in `http.rs`). Some details:

- **`--dev`** also makes `Env.dev!` true, adds `x-rocx-flash` to a flash's 303, and sends
  `cache-control: no-store` on answers that set none.
- **`--debug`** also adds `x-rocx-flash`. A plugin's early path names the flags it answers under
  (`--dev`, `--debug` or both: the jobs plugin's `POST /__rocx/jobs/wake` answers under either).
- **Static files.** `--static` and `--file` serve files for `GET` and `HEAD`, typed by their
  extension (`text/css; charset=utf-8`, `text/javascript`, `application/wasm`, …), with
  `cache-control: no-store` under `--dev`. A file directly under `/rocx/` whose name ends in `-`
  and 16 hex digits before its extension is one rocx build named by its content (the app's
  stylesheet, `/rocx/styles-0123456789abcdef.css`, beside `start.js`). Another content gets another
  name, so it is answered with `cache-control: public, max-age=31536000, immutable` and the browser
  never asks again (D-040). Other files say nothing about caching.
- **`--max-body`** (D-056): 16 MiB unless it, or `MAX_BODY`, says otherwise: a number of bytes, or
  of KiB, MiB or GiB (`64MiB`). 0 or anything unreadable stops the server. The host reads a body
  whole before Roc runs, so this is the most any request holds in memory.
- **Proxies.** Requests to other servers go through `HTTPS_PROXY` and `HTTP_PROXY` when they are
  set, except to a host `NO_PROXY` names (`Http`, above).
- **`ROCX_LOG`** (`pretty` or `json`) chooses the log's format when the program says `Auto`.
- **The public URL** (`Env.public_url!`) is `--public-url` or `PUBLIC_URL` (an `http://` or
  `https://` URL, its trailing `/` dropped; anything else stops the server), for an app behind a
  proxy. Without either, it is where the server listens (`http://127.0.0.1:8080`, or the port the
  system gave `--port 0`; an all-interfaces address becomes loopback). It is never taken from a
  request's `Host`, which whoever asks controls.
- **Exit codes:** 2 for a flag the host can't read (or `--help`) and for an `--env-file` it can't
  read (a line that isn't a setting, a file that isn't there), 1 for a server that can't start
  (a port in use, a migration that fails, a plugin problem, no database while the app or a plugin
  has tables, `init!`'s `Err`).

## Tests

`just test-server` runs this platform's tests, then packages/testing's, packages/posthog's, the
guard, push, auth, stripe and ai examples' (each against an app it builds), and `rocx new`'s
template's (`templates/test`); a `.env` here reaches none of their servers, which aren't given one. Run
one file with `node --test server/test/server.test.mjs`. They skip what they can't run:

- without Roc or Rust (`just setup`), everything;
- without `DATABASE_URL` (`just db`), what needs Postgres;
- without `STORAGE_URL` (an S3 bucket the tests may write to: rustfs or MinIO in Docker, with a
  bucket made), packages/storage on S3; the `file:` and `memory:` tests always run;
- without `ROCX_TEST_INTERNET=1`, the request over the internet.

`ROCX_TEST_OPT=speed` builds the test apps optimized (boxy, as an app ships; with
`ROCX_SPECIALIZE=yes`, specialized).

**`server/test/server.test.mjs`** builds `server/test/app` (and the smaller apps beside it) and asks
it over HTTP:

- **Calls and memory:** crashes and overflows as 500s with nothing held; calls that wait on two
  Roc threads (2,000 requests that wait a second each, answered in about a second; 2,000 open
  streams beside a request answered at once; waits, crashes, pages, refusals and sockets
  interleaved, each answered as its own); a stack overflow that ends the process, saying so; a
  port in use; a stop in the middle of a request; and, at the end, no allocations left but the
  background loops'.
- **Bodies:** bytes both ways (every byte value, a 16 MiB body, bytes made in Roc); `--max-body` and
  `MAX_BODY` (the limit itself and one byte more, with and without a length; sizes it refuses);
  typed bodies (D-038), multipart forms and files (D-054); `F64`s and a tag union in a `Try` as
  JSON, and an infinity refused.
- **`Forward`:** from a server the test runs: whole, a range, a 304, HEAD, a redirect, 40 MiB with
  nothing held, errors not passed on, a body cut short, no answer, and no range or cache question
  the request record doesn't pass on.
- **Pages of components:** a whole document with its answers and `start.js`; `<Loading>`,
  `<Errored>`, an endpoint read behind middleware, `<HttpStatusCode>`, HEAD, crashes, effects that
  don't run, holes in `<title>` and `<textarea>`, a `<NoHydration>`, a read redirected by its
  middleware, the dev reload script, names markup can't have left out (D-079), and no leaks.
- **Endpoint reads:** answered in-process while a page renders, with its query, cookies and
  headers, noted once and never from a `<NoHydration>`; one its middleware redirects; a handler
  reading the page's flash.
- **Forms:** a plain form's refusal and result back to its page with a flash, read there with what
  was typed and noted for the browser, then let go; passwords never coming back; a flash gone after
  a minute; a script's and the runtime's posts answered as they are; a redirect for the runtime.
- **The database:** Postgres statements, `Db.one!`, `Db.array`, `Db.Nullable`, waits on their own,
  migrations, transactions, and transactions inside them (`nested-checks.mjs`, shared with the
  SQLite tests); an app with tables and no database refused at start, or started with a line on the
  log under `--debug`;
  `--describe-sql` on Postgres (a scratch database, `--sql-database`, `CREATEDB`); a SQLite or
  Turso URL refused for a Postgres app; packages/admin's tables admin (`admin-checks.mjs`, shared
  with the SQLite tests); roc-pg (`server/examples/roc-pg`).
- **Plugins:** the fixture plugin package's (`server/test/fixture`) route with the app's context,
  early path, files and scripts (served before an app that refuses everything,
  `server/test/refusing`), table, call, loop, start, check and need; an app whose plugins break
  every rule refused at start with the whole message (`server/test/refused`); old flags refused,
  saying where they went.
- **Jobs and cron** through packages/jobs's plugin: at once, later, retried, failing for good,
  queued in a transaction, another app's left alone, attempts per kind, time limits cutting a run
  off (at Postgres, a socket and another server, and in Roc that never waits, with SIGURG kept to
  the server's thread), keys unique while pending, cancel and move, listing, a database migrated
  before jobs were a package; the jobs page (behind a guard, its forms, its stream); cron.
- **Email** through packages/email's plugin: the outbox, the dev mailbox (in memory, only under
  `--dev`), a server with no `SMTP_URL` refused at start without `--dev` or `--debug` (D-079), and
  SMTP to a server the test runs.
- **`Tcp`, `Http`, `Env`, crypto, random:** sockets; `Http.fetch!` against servers the test runs
  (redirects, timeouts, size limits, failing TLS, kept connections, a kept connection closed under
  a GET and under a POST, proxies named and from the environment, `fetch_chunks!`, the deprecated
  API), `proxy.rs`'s own unit tests; `Env` from a request and a job, the public URL; AES-GCM and
  packages/crypto against Node's; AES-GCM with the caller's nonce against RFC 8291's and RFC 8188's
  records; P-256's new pairs, ES256 signatures and ECDH, which Node checks; random bytes.
- **The log:** JSON when `ROCX_LOG=json` or unset on a pipe, pretty lines with `ROCX_LOG=pretty`, an
  app's fields beside `time`, `level` and `msg` and never in their place, a program's `Pretty`
  (`server/test/pretty`) winning over `Auto` and `ROCX_LOG`, 200 requests logging at once with
  every line whole and in order, the queue flushed at a stop, and the platform's and plugins' own
  events.
- **Live and channels:** rooms and topics; channels checked as their stream opens and at every beat,
  one refused while the rest go on, what pages say, a subscriber behind its backlog, 40 streams on
  two Roc threads, subscribes and unsubscribes over a stream by its id, `Dropped` and `Gone` in
  order, the post's cookies kept for the beats, a post from another site or naming a wrong stream
  refused.
- **`Kv`:** kept, read, taken once, deleted; time to live and a counter's window; 200 increments at
  once; a capped list; eviction past `--kv-max-mb`; `kv.rs`'s own unit tests.
- **Actors:** one message at a time, a crash, asking another, itself or one waiting on it, tells in
  order, timers and a cancelled one, bad inputs, methods and kinds logged, state across a restart,
  an idle actor let go and woken, timers across a restart (told once), a timer cancelled after it
  fired while its actor was busy, and nothing left allocated.
- **Storage:** packages/storage on memory, on a directory and on S3 (objects whole and in part,
  missing ones, multipart uploads, signed URLs, `serve!` with ranges, 416, ETags and HEAD, a
  directory kept across a restart, keys that would leave it, a signed link expired, S3 errors).
- **The docs' samples:** `server/test/app/Samples.roc`, which the site's build picks its platform
  pages' samples from (settings, crypto, jobs, `Kv`, cookies, bytes, other servers, forwards and
  storage), run as the pages say.

**`server/test/context.test.mjs`** builds `server/test/context`: the app's context made once,
shared by every request (many at once, and across a pause), whole after a crash, read by a stream
after its request ended, given to a job, an actor's turn and a plugin's call, loop, start and check;
an actor `init!` asks refused; and `init!`'s `Err` stopping the server.

**`server/test/sqlite.test.mjs`** builds `server/test/sqlite`, an app on SQLite, and needs no
database server: its file where the program or `--database-url` says, a Postgres URL refused, typed
parameters and rows, transactions and a failing script, 40 read-then-write transactions at once
that each see the one before, a read beside a held write, notifications on commit only, the
platform's and a plugin's tables made once, actors' state and timers across a restart, a plugin
that needs Postgres refused, jobs (in a transaction, retried, keyed, cut off at their time limit
with the statement interrupted and the transaction rolled back), cron, the jobs page,
packages/admin, and transactions inside transactions (`nested-checks.mjs`: on Turso in WAL mode
too, and a level that loses to another's write on Turso's MVCC).

**`server/test/envfile.test.mjs`** builds `server/test/envfile`, an app that answers
`GET /env/<NAME>`, and starts it in directories of its own (D-088, D-098): `--env-file`'s file read
into its environment, the environment's own value winning, no file without the flag (a `.env` where
it starts neither, `ROCX_ENV_FILE` neither), the log's line naming what was set and kept in the
app's format, a bad line or a missing named file stopping the server; and `dotenv.rs`'s own parser
tests.

**`server/test/host-entries.test.mjs`** builds nothing: it reads the host's sources and checks that
every function Roc can call (the glue's runtime and hosted symbols, every exported function, the
`RocHost` callbacks) begins with `let _host = preempt::host();` (D-057).

Elsewhere: `site/test/site.test.mjs` runs the docs site on this platform, in Chromium, and compares
its pages with the browser runtime's own render; `test/check-sql.test.mjs` covers
`rocx check --sql`.

## Not yet

- `rocx check --sql` (D-058) checks only SQL written as a string literal at the call: SQL put
  together (`${…}`) or passed in a variable isn't checked, nor a row whose type rocx can't read from
  an annotation. A column from the outer side of a `left join` is taken as its table's `not null`
  says, and SQLite doesn't type an expression, so neither is checked for nulls (sqlx reads the
  statement's plan for these).
- Actors' timers survive a restart, but are all set again at start, each a task in memory: an app
  with millions of far-off timers would want them read a window at a time.
- `Http`: HTTP/1.1 only (no HTTP/2), no SOCKS proxy, and a request's own body is sent whole (an
  answer's may come in chunks: `fetch_chunks!`).
- `Forward`: an upstream's body only, not the other way. An upload is still read whole (16 MiB at
  most unless `--max-body` says more) rather than streamed to S3 as it comes.
- A stack overflow in Roc still ends the process.
- The server speaks HTTP/1.1 only, with no TLS: put it behind a proxy. `x64musl` and `x64mac` are
  configured, but haven't been run.
- `roc test` on a module with no `expect` (`Migrations.roc`) never ends, and neither does it on
  `JobsPage.roc` (packages/admin; `roc check` and both builds are fine), so the page's small helpers
  and their `expect`s are in `AdminHtml.roc`.
- `stream_for_host!` wraps `send!` and `sleep!` in lambdas: a hosted function passed on as a value
  trapped in optimized wasm builds with Roc nightly-2026-11-18. This platform is native and
  unaffected, but the wrapping keeps its Roc buildable for wasm.
