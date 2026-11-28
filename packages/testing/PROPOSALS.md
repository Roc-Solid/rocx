# packages/testing: proposals

What this package needs from outside `packages/testing/`, written up instead of built (sections 1
and 11 are done): each is a change to the platform, the host, the runtime or the `rocx` CLI.
Everything in the package compiles and passes its tests without them. Each section: the problem,
the options weighed, the recommended change, what in the package waits on it, and how to undo it.

The package as built (README.md) tests a Roc Solid app from outside, as a browser would: the built
server on a port of its own, its pages parsed and found in by role, a Postgres or SQLite database
per test, Chromium and Gecko.
Most of what is below lets a test reach inside instead: a clock it sets, randomness it seeds, effects
it stubs, jobs it runs, requests answered without a socket.

---

## 1. Server-only modules in packages

**Done (D-033), differently.** A package that needs the server names the server platform in its
`main.roc`, and lists what the browser's half may import in a `browser.roc` beside it (as
packages/push does); nothing is copied into an app, and `just check` keeps it so
(`test/no-copies.test.mjs`). So a `TestHooks` module could be this package's own; it waits on
section 2.

---

## 2. A test mode for the server: `--test`, and its control paths

**Problem.** A test can reach a server only as a browser does. It can't set the time, seed the
randomness, stub what the server asks of other servers, run a cron now or empty the mailbox,
because nothing in the platform listens for that.

**How it would fit.** A plugin may answer paths under `/__rocx/` before the app, under a flag
(`Plugin.Early`'s `under`: `[Dev, Debug]` today). The dev mailbox is packages/email's, answered that
way (D-033, D-035), and the jobs plugin's `POST /__rocx/jobs/wake` too. A test mode is the same with
one flag more.

**Options.**
1. One flag, `--test` (`Test` in `under`), under which this package's plugin answers
   `/__rocx/test/*`. Off unless given: a deploy never passes it, and the server logs a warning at
   start when it is on.
2. Each hook its own flag (`--fake-clock`, `--seed`, `--stub-http`): more to remember, and each
   test turns them all on anyway.
3. Hooks in the app (a route file it adds): the clock and randomness are the host's, below any
   route, so the app can't fake them.

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

```roc
# packages/testing: its plugin, for an app's tests
plugin = |{}| { name: "testing", early: [{ method: "POST", path: "/__rocx/test/clock", under: [Test], answer!: clock! }, …] }
```

In the package, `startServer(executable, { test: true })` passes `--test`, and the server it
returns gets `clock`, `stubHttp`, `httpCalls`, `runJobs`, `runCron` (sketched in each section).

**What depends on it.** Sections 3 to 7.

**Undo.** Remove the flag and the plugin; nothing else answers those paths.

---

## 3. A clock a test sets

**Problem.** `Time.now_millis!` is the host's `SystemTime::now()`, and so is the time `Email` dates
a message with, `Cron`'s ticker and the jobs page. A test of "a reminder goes 24 hours later", or
of a page that says "2 minutes ago", has to wait, or can't be written.

**Options.**
1. Under `--test`, the host's `roc_host_now_millis` reads a clock the test sets: frozen at a moment,
   moved on by hand. On SQLite the jobs' times come from Roc (packages/jobs's `Queue.now!`), so they
   move with it. Postgres's `now()` stays real: jobs there are due by the database's clock
   (`run_at <= now()`), so a job queued "in a day" is made due with `settleJobs({ later: true })`
   (today) or `runJobs({ later: true })`.
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
endpoint) can't be tested without that server: a test makes real network calls, or doesn't test
that path. Email needs nothing: with no `SMTP_URL` it is kept in the mailbox already. Files need
nothing either: packages/storage takes `memory:` and `file:` URLs as well as `s3://` (D-047), so a
test gives its server a bucket of its own. packages/stripe's tests point `STRIPE_API_URL` at a
stand-in, which works for any service whose URL is a setting.

**Options.**
1. Under `--test`, `roc_host_http_send` answers from stubs the test registers, and never opens a
   socket: a request no stub answers fails with `HttpErr("no stub for GET https://…: the test server
   makes no requests")`. Every request is recorded for the test to read.
2. A fake server per service, run by the test (as server/test runs an SMTP server, and
   packages/stripe's tests a stand-in for Stripe): works today for a service whose URL is a
   setting, but each test writes its fake, and HTTPS needs a certificate the server trusts.

**Recommended: 1.**

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

**Problem.** A test that queues a job has to wait for a worker to take it. `settleJobs` does that
today over SQL: it makes due what should run, wakes the workers (`pg_notify('rocx_jobs')` on
Postgres, the jobs plugin's `POST /__rocx/jobs/wake` on SQLite) and polls until nothing is due or
running. It works (app.test.mjs), but it needs the database, polls, and can't run a cron by its
name: a cron's input is in the program, not the database, so `enqueue(kind, input)` restates it.

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

## 7. Clearing the dev mailbox in a test

**Status (2026-11-28).** Half done: kept messages have ids (`Kv`'s counter, D-028), and the mailbox
is packages/email's `Mailbox.roc` (D-035).

**Problem.** `POST /__rocx/mail/clear` is answered only under `--dev`, from the mailbox's own page
(same origin), so a test under `--debug` can't empty it between tests. A test says "the mail after
this one" by counting (`waitForMail(match, { after: n })`).

**Recommended.** In `Mailbox.early`, answer the clear under `--debug` (or `--test`) too, without the
same-origin check (it is a test's server). A few lines in packages/email.

```js
await app.clearMail();
const mail = await app.waitForMail({ to: "ada@example.com" });
```

**What depends on it.** `app.clearMail`: not built; `waitForMail`'s `after` is the way today.

**Undo.** Drop `Debug` from the clear's `under`.

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
   A test answers requests in-process, as the host already does for an app's own requests
   (`Host.fetch!`, behind `Call.fetch!`: a page's endpoint reads while it renders, and a handler's
   `Endpoint.send!`, behind the endpoint's middleware, D-103). Each test runs in a transaction
   rolled back after it, its in-process requests on the same connection, so tests share a database
   and leave nothing in it.
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
	request! : Server.Request => Try(Server.Response, Str)   # in-process, as Host.fetch! answers one
	get : Str -> Server.Request
	form : Str, Str, List((Str, Str)) -> Server.Request
	json : Str, Str, Str -> Server.Request
	text : Server.Response -> Str                            # a page rendered as the host renders one
	equal : a, a -> Try({}, Str) where [a.is_eq, a.Inspect]
	ok : Bool -> Try({}, Str)
}
```

**What depends on it.** Nothing built; Dom.roc is ready for it (`Dom.parse` of an answer's text).
It needs section 2 for the clock and stubs. For pages, packages/headless's PROPOSALS.md (4) adds a
test program on the CLI platform that starts the built server and drives Chromium from Roc (D-128).

**Undo.** Remove the field and the flag; `tests` is `[]` in every app.

---

## 9. Rendering a `view!` component in a test

**Problem.** `Html.to_str` renders markup with nothing to run in it, so an `expect` can render a
pure component (`view`) and query it (Dom.roc, today). A component with signals, a hole's `if` or
`match`, a `.map` of rows or an endpoint read (`view!`) needs the runtime: `Html.to_str` crashes on
it, by design.

**Options.**
1. Through its story, today: `rocx generate --dev` serves each `<story>` as a page in the app's layout
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

Since D-128 there is a second way: packages/headless drives Chromium from Roc, over the CLI
platform's `WebSocket`, and its PROPOSALS.md has what this package's browser would need there
(Gecko, drags and touch, these queries in a tab). Whether the browser moves to Roc is open.

**What depends on it.** browser.mjs's `open` (works today, with the shared profile: tests launch a
browser for each person).

**Undo.** Move the file back.

---

## 11. This package's tests in `just test`

**Done.** `just test` runs every package's `roc test` (`packages/*/main.roc`, this one's included)
and `node --test 'packages/testing/test/*.test.mjs'`.

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
   than checked out? Today it is a path into the repository (`../packages/testing/index.mjs`), and
   an installed release has no `.mjs` of any package (`release/pack.sh` leaves them out), so the JS
   half is only in a clone. An npm package `@roc-solid/testing`, the `.mjs` files in the release, or
   a copy that `rocx new` writes, are the choices.
