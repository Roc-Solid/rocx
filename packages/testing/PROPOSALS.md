# packages/testing: proposals

What this package needs from outside `packages/testing/`, written up instead of built: each is a
change to the platform, the host, the runtime or the `rocx` CLI. Everything in the package compiles
and passes its tests without them. Each section: the problem, the options weighed, the recommended
change, what in the package waits on it, and how to undo it.

The package as built (README.md) tests a Roc Solid app from outside, as a browser would: the built
server on a port of its own, its pages parsed and found in by role, Postgres per test, Chromium.
Most of what is below lets a test reach inside instead: a clock it sets, randomness it seeds, effects
it stubs, jobs it runs, requests answered without a socket.

---

## 1. Server-only modules in packages

**Problem.** A package can't hold a Roc module that imports the platform (`Middleware`, `Db`, `Job`,
`Http`, `Endpoint`, …). A Roc package may name a platform only if it is the app's exact platform,
and a Roc Solid app is two apps (the browser's half on `web/platform`, the server's on
`server/platform`). `rocx build` copies a package's `components/` into both halves; nothing copies
server-only code. This package would ship a `TestHooks` middleware (section 2's Roc side: a cron run
by name, the mailbox cleared, written in Roc on `Cron.run_now!` and `Job`), and it can't.

**Options.**
1. `rocx build` copies a package's `server/` directory (`.roc` and `.rocx`) into the server half
   only, as it copies `components/` into both: `Generated/<alias>/<Module>.roc`, `pf` the server's
   platform. The browser's copy (`--client`) never gets them.
2. A second package per package that names the server platform (`packages/testing/server/main.roc`:
   `package [...] { pf: platform "../../../server/platform/main.roc" }`), named only in the server
   half's header. `rocx build --client` copies every package of the server's header into the
   browser's `main.roc` today, so it would have to leave out the ones that name a platform, and the
   package's platform path must be the app's, character for character: a published package can't
   know it.
3. Wait for Roc to let a package be generic over its platform (module params, or effects given as
   arguments). Not on Roc's roadmap in a form we can use.

**Recommended: 1.** It is the components mechanism with one directory more and one half fewer.

```
packages/testing/
  main.roc              package [Dom] {}            plain Roc: both halves, roc test
  components/           copied into both halves      (today)
  server/TestHooks.roc  copied into the server half: Generated/testing/TestHooks.roc
```

In a `.rocx` or `.roc` file of the server's, `import testing.TestHooks` is rewritten as a
component's import is (`import ../Generated/testing/TestHooks`). In the browser's copy the import is
dropped with the server-only code that used it (rocx already drops a route file's middleware and a
server function's body, and the imports only they used); an import of a server-only module from
code that runs in the browser is a build error at its line: "`testing.TestHooks` is server-only: use
it in a server function, a route file's middleware or an endpoint". In `src/routes.mjs`, beside the
copy of `components/`:

```js
// packagesOf(app) already finds each package the app's header names, and its directory.
for (const { alias, dir } of packagesOf(app)) {
	copyModules(join(dir, "components"), join(app, "Generated", alias), { halves: ["server", "client"] });
	copyModules(join(dir, "server"), join(app, "Generated", alias), { halves: ["server"] });   // new
}
```

**What depends on it.** `TestHooks` (section 2) would be its first user here; nothing built today.
The other eight package workers each need the same thing; this is this package's version of it.

**Undo.** Delete the second copy; packages keep `main.roc` and `components/`.

---

## 2. A test mode for the server: `--test`, and its control paths

**Status (2026-11-22).** The mailbox is packages/email's now, answered as a plugin's early paths
(`Plugin.Early`, under `--dev` or `--debug`: D-033, D-035), not by the platform's `Outbox`. A test
mode would be the same mechanism with a `Test` flag: a plugin (this package's) giving early paths
under `--test`.

**Problem.** A test can reach a server only as a browser does. It can't set the time, seed the
randomness, stub what the server asks of other servers, run a cron now or empty the mailbox,
because nothing in the platform listens for that. The dev mailbox shows the way: under `--dev` or
`--debug` the platform answers `/__rocx/mail` itself, before the app (`Outbox.serves!`).

**Options.**
1. One flag, `--test`, under which the platform answers `/__rocx/test/*` before the app, as it
   answers the mailbox. Off unless given: a deploy never passes it, and the server logs a warning
   at start when it is on.
2. Each hook its own flag (`--fake-clock`, `--seed`, `--stub-http`): more to remember, and each
   test turns them all on anyway.
3. Hooks in the app (a middleware it mounts, section 1): the clock and randomness are the host's,
   below any middleware, so the app can't fake them.

**Recommended: 1**, with the paths below (sections 3 to 7), all JSON, all under `--test` only:

```
GET  /__rocx/test                      what the hooks are now: { clock, seed, stubs }
POST /__rocx/test/clock                { at: ms } | { advance: ms } | { real: true }    (section 3)
POST /__rocx/test/http                 a stub: { method, url, status, headers, body }  (section 5)
GET  /__rocx/test/http                 the requests the app made, oldest first
POST /__rocx/test/jobs/run             every due job, run now, in this request          (section 6)
POST /__rocx/test/cron/<name>          a schedule's job, queued and run now
POST /__rocx/mail/clear                (under --debug and --test too)                   (section 7)
```

In `server/platform/main.roc`, beside the mailbox:

```roc
respond_for_host! = |given, context| {
	request = { ..Server.from_http(given.method, given.target, given.headers, given.body), peer: given.peer }
	if Outbox.serves!(given.target) {
		Outbox.respond!(request)
	} else if TestMode.serves!(given.target) {    # new: Setting.text!("test") is "1"
		TestMode.respond!(request)
	} else {
		program.respond!(request, context)
	}
}
```

In the package, `startServer(executable, { test: true })` passes `--test`, and the server it
returns gets `clock`, `stubHttp`, `httpCalls`, `runJobs`, `runCron` (sketched in each section).

**What depends on it.** Sections 3 to 7.

**Undo.** Remove the flag and `TestMode`; nothing else answers those paths.

---

## 3. A clock a test sets

**Problem.** `Time.now_millis!` is the host's `SystemTime::now()`, and so is the time `Email` dates
a message with, `Cron`'s ticker and the jobs page. A test of "a reminder goes 24 hours later", or
of a page that says "2 minutes ago", has to wait, or can't be written.

**Options.**
1. Under `--test`, the host's `roc_host_now_millis` reads a clock the test sets: frozen at a moment,
   moved on by hand. Postgres's `now()` stays real: jobs are due by the database's clock
   (`run_at <= now()`), so a job queued "in a day" is made due with `settleJobs({ later: true })`
   (postgres.mjs, today) or `runJobs({ later: true })`.
2. Also move Postgres: `set timezone`-style tricks don't move `now()`; every query of the platform's
   would have to take the time as a parameter. Too wide for what it buys.

**Recommended: 1.**

```rust
// server/host/src/hosted.rs
static TEST_CLOCK: AtomicI64 = AtomicI64::new(-1);   // -1: the real clock

pub extern "C" fn roc_host_now_millis() -> u64 {
    match TEST_CLOCK.load(Ordering::Relaxed) {
        at if at >= 0 => at as u64,
        _ => SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0),
    }
}
```

`--test-clock <ms>` starts it frozen; `POST /__rocx/test/clock` sets it (`{ at }`), moves it
(`{ advance }`) or lets it go (`{ real: true }`). The cron ticker wakes when it moves, so a schedule
whose time has come queues its job. The browser's clock (`Date.now` in the runtime) is the
browser's: a browser test sets it with DevTools' `Emulation.setVirtualTimePolicy`.

```js
const app = await startServer(server, { test: true, clock: Date.parse("2026-01-01T09:00:00Z") });
await app.clock.advance(24 * 3600_000);
```

**What depends on it.** `startServer`'s `clock` option, `app.clock`: not built.

**Undo.** Remove the static and the path; the host reads the system's clock again.

---

## 4. Randomness a test seeds

**Problem.** `Random.bytes!`, `Random.seed_u64!` and the ids `Email` makes are the operating system's
randomness (`ring`'s `SystemRandom`). A test can't predict a token a page shows, or replay a run
that failed.

**Options.**
1. Under `--test` only, `--seed N` makes `roc_host_random_u64` and `roc_host_random_bytes` a
   deterministic stream (ChaCha20 keyed by the seed, one stream per server). Never without `--test`:
   a seeded server's tokens and keys are guessable, so the host refuses `--seed` alone.
2. A seed per request (a header the test sends): two requests at once would still race for the one
   stream; one stream per server, and a test that wants determinism sends one request at a time.

**Recommended: 1.**

```rust
static SEEDED: OnceLock<Mutex<ChaCha20Rng>> = OnceLock::new();   // set by --seed under --test

pub extern "C" fn roc_host_random_u64() -> u64 {
    if let Some(rng) = SEEDED.get() { return rng.lock().unwrap().next_u64(); }
    /* the system's, as now */
}
```

```js
const app = await startServer(server, { test: true, seed: 42 });
```

**What depends on it.** `startServer`'s `seed` option: not built. In plain Roc, a pure generator
seeded by the caller needs nothing (the docs site's `Demos/Random.roc` is one).

**Undo.** Remove the flag; the host reads the system's randomness again.

---

## 5. Outbound requests stubbed: `Http`, and `Storage` through it

**Problem.** An app that asks another server (`Http.fetch!`: a payment provider, an OAuth token
endpoint) or keeps files in S3 (`Storage`, an S3 client written on `Http`) can't be tested without
that server: a test makes real network calls, or doesn't test that path. Email needs nothing: with
no `--smtp-url` it is kept in the mailbox already.

**Options.**
1. Under `--test`, `roc_host_http_send` answers from stubs the test registers, and never opens a
   socket: a request no stub answers fails with `HttpErr("no stub for GET https://…: the test server
   makes no requests")`. Every request is recorded for the test to read. `Storage` goes through it,
   so an S3 stub is a stub of its URLs.
2. A fake server per service, run by the test (as server/test runs an SMTP server): works today
   for a service whose URL is a setting, but each test writes its fake, and HTTPS needs a
   certificate the server trusts.
3. An in-memory bucket for `Storage` (`STORAGE_URL=memory://bucket`), in the host's store
   (`Host.store_get!`/`store_set!`): simpler for files than stubbing S3's XML. Worth doing beside 1.

**Recommended: 1, and 3 for `Storage`.**

```
POST /__rocx/test/http   { "method": "POST", "url": "https://pay.example/charges", "match": "prefix",
                           "status": 201, "headers": [["content-type", "application/json"]],
                           "body": "{\"id\":\"ch_1\"}", "times": 1 }
GET  /__rocx/test/http   [{ "method": "POST", "url": "https://pay.example/charges", "headers": […],
                            "body": "…", "answered": 201 }]
```

```js
await app.stubHttp({ method: "POST", url: "https://pay.example/charges", status: 201, json: { id: "ch_1" } });
// … the test drives the app …
assert.deepEqual((await app.httpCalls()).map((call) => call.url), ["https://pay.example/charges"]);
```

**What depends on it.** `app.stubHttp`, `app.httpCalls`: not built.

**Undo.** Remove the stub table; `Http` goes to the network again under every flag.

---

## 6. Jobs and crons run on demand

**Problem.** A test that queues a job has to wait for a worker to take it. postgres.mjs's
`settleJobs` does that today over SQL: it makes due what should run, wakes the workers
(`pg_notify('rocx_jobs')`) and polls until nothing is due or running. It works (app.test.mjs), but
it needs the database's URL, polls, and can't run a cron by its name: a cron's input is in the
program, not the database, so `enqueue(kind, input)` restates it.

**Options.**
1. `POST /__rocx/test/jobs/run` (under `--test`) takes and runs every due job in the request's own
   call, one after another, the ones they queue too, and answers what ran:
   `[{ id, kind, state, attempts, last_error }]`. `{ later: true }` makes the queued ones due
   first. `POST /__rocx/test/cron/<name>` is `Cron.run_now!(name)`, then the same.
2. Keep SQL (today's `settleJobs`): no platform change, but a poll.

**Recommended: 1, keeping 2** for a server started without `--test`. The workers' loop is
`JobWorker.take!` then `attempt!` then `finish!`; the path runs the same three on the request's
thread until `take!` finds nothing.

```js
const ran = await app.runJobs();                // [{ kind: "welcome", state: "done", … }]
await app.runCron("nightly 0 3 * * *");          // as the schedule would, now
```

**What depends on it.** `app.runJobs`, `app.runCron`: not built; `db.settleJobs` and `db.enqueue`
are the way today.

**Undo.** Remove the paths; `settleJobs` still works.

---

## 7. The dev mailbox, for tests: ids, and clearing it

**Status (2026-11-22).** Messages have ids (`Kv`'s counter, D-028); the mailbox is packages/email's
`Mailbox.roc` (D-035), where clearing under `--debug` would go.

**Problem.** Messages kept in memory (no database) have no `id`, where Postgres's do, so a test
can't say "the mail after this one" except by counting (`waitForMail(match, { after: n })`). And
`POST /__rocx/mail/clear` is answered only under `--dev`, from the mailbox's own page (same origin),
so a test under `--debug` can't empty it between tests.

**Recommended.** The host gives each kept message an id (a counter), as Postgres does; under
`--debug` (or `--test`), `POST /__rocx/mail/clear` is answered without the same-origin check (it is
a test's server). `Outbox.serves!` already decides by flag; a few lines in `Outbox.roc` and
`server/host/src/outbox.rs`.

```js
await app.clearMail();
const mail = await app.waitForMail({ to: "ada@example.com" });
```

**What depends on it.** `app.clearMail`: not built; `waitForMail`'s `after` is the way today.

**Undo.** Drop the counter and the flag check.

---

## 8. Requests answered in-process, from Roc: `rocx test`

**Problem.** Everything above tests from Node, over a socket. A Roc author would rather test an
endpoint, a page or a server function in Roc, beside it, with the types: build a request, answer
it, check the status, the JSON, the page by role. `expect` can't: it is pure, and answering is an
effect (`Routes.respond!`, `Db`, `Job`).

**Options.**
1. Effectful tests in the compiler (`expect!`, run by `roc test` with the platform's effects):
   Roc's to decide; `roc test` would also need the host linked.
2. A test program: `program` gets `tests : List({ name : Str, run! : {} => Try({}, Str) })`
   (default `[]`; `App.program` lists each `test!` the app's modules define, as it lists jobs), and
   the built server runs them with `--run-tests` instead of listening, under section 2's test mode.
   A test answers requests in-process with a new host primitive, `Host.respond_local!`, which
   `Host.call!` already is for one case (a server function called while a page renders:
   `call_route` in `server/host/src/signals.rs` answers it through the app's `respond!`). Each test
   runs in a transaction rolled back after it, its in-process requests on the same connection, so
   tests share a database and leave nothing in it.
3. Node only (today): it works, but the test is in another language, away from the code.

**Recommended: 2**, behind a `rocx test <dir>` that builds the server half with `--dev`, runs its
`--run-tests` against `DATABASE_URL`, and reports failures at the `.rocx` lines (`rocx check`'s
remapping). A sketch, in a server module of the app's:

```roc
import pf.Test
import testing.Dom

Notes := [].{

	adds_a_note = Test.define!(
		"a note posted from the page is added, and the page shows it",
		|| {
			posted = Test.request!(Test.form("POST", "/notes", [("body", "milk")]))?
			Test.equal(posted.status, 303)?
			page = Test.request!(Test.get("/"))?
			Test.ok(Dom.parse(Test.text(page)).contains(Named("listitem", "milk")))
		},
	)
}
```

with, in `server/platform/Test.roc`:

```roc
Test := [].{
	define! : Str, ({} => Try({}, Str)) -> { name : Str, run! : {} => Try({}, Str) }
	request! : Server.Request => Try(Server.Response, Str)   # Host.respond_local!, through program.respond!
	get : Str -> Server.Request
	form : Str, Str, List((Str, Str)) -> Server.Request
	json : Str, Str, Str -> Server.Request
	text : Server.Response -> Str                            # a page rendered as the host renders one
	equal : a, a -> Try({}, Str) where [a.is_eq, a.Inspect]
	ok : Bool -> Try({}, Str)
}
```

**What depends on it.** Nothing built; Dom.roc is ready for it (`Dom.parse` of an answer's text).
It needs section 1 for a package's test helpers, section 2 for the clock and stubs.

**Undo.** Remove the field and the flag; `tests` is `[]` in every app.

---

## 9. Rendering a `view!` component in a test

**Problem.** `Html.to_str` renders markup with nothing to run in it, so an `expect` can render a
pure component (`view`) and query it (Dom.roc, today). A component with signals, an `if`'s part, a
`<For>` or a server function (`view!`) needs the runtime: `Html.to_str` crashes on it, by design.

**Options.**
1. Through its story, today: `rocx build --dev` serves each `<story>` as a page in the app's layout
   (`storyPath(module, name)` in server.mjs); a test fetches it (`client.get`) and queries it, or
   opens it in Chromium (`browser.open`) and uses it. app.test.mjs does both.
2. In section 8's test program: `Test.render! : ({} => Html) => Str`, the host's own renderer (the
   one a page goes through), in-process.
3. A pure renderer that runs holes: impossible, a hole is an effect (`() => Str`).

**Recommended: 1 now, 2 with section 8.**

**What depends on it.** Nothing beyond `storyPath`, which works today.

**Undo.** Nothing to undo for 1.

---

## 10. The browser driver in this package

**Problem.** browser.mjs drives Chromium with `web/test/browser.mjs`, the repository's own test
driver, by path: an app's tests import the repository's test internals. Its tabs share one profile
(cookies, storage), so `browser.open` clears the cookies each time and two tabs can't be two people.
And it can't reach the browser's own DevTools target (`send` is per page), so it can't make a
context per tab.

**Recommended.** Move `web/test/browser.mjs` here as `packages/testing/chrome.mjs`, and have
web/test, site/test and test/e2e import it from here; give `launch()` a browser-level `send`, and
`page({ isolated: true })` a context of its own (`Target.createBrowserContext`, then
`createTarget({ browserContextId })`), so each person in a test has their own cookies. browser.mjs
then opens each tab isolated by default.

**What depends on it.** browser.mjs's `open` (works today, with the shared profile).

**Undo.** Move the file back.

---

## 11. This package's tests in `just test`

**Problem.** `just test` runs `roc test packages/charts/main.roc` and nothing of this package's.

**Recommended.** In the Justfile's `test` recipe:

```
    {{ roc }} test packages/testing/main.roc
    ROC={{ roc }} node --test 'packages/testing/test/*.test.mjs'
```

(app.test.mjs builds a small app and needs the hosts built, which the recipe's earlier steps do;
it uses `DATABASE_URL` and Chromium when they are there, and skips those parts when they aren't.)

**Undo.** Remove the two lines.

---

## Open questions

1. **Does `--test` belong in the shipped server?** Sections 2 to 7 put hooks in every build,
   off unless the flag is given. The other way is a test build of the host (`cargo build
   --features test`), which can't be turned on by mistake but doubles the host builds. The
   recommendation is the flag, with a warning in the log; the user decides.
2. **Should `rocx test` (section 8) be the way a Roc Solid app is tested,** with Node for the
   browser only? That is the larger design question: in-process Roc tests are fast and typed, and
   need the platform work above; the Node helpers here work today.
3. **Where should an app's JS tests import this package from** once Roc Solid is installed rather
   than checked out (`rocx new`)? Today it is a path into the repository
   (`../packages/testing/index.mjs`); an npm package `@roc-solid/testing`, or a copy that
   `rocx new` writes, are the choices.
