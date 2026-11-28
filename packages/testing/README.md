# testing

Helpers for testing a Roc Solid app. A test finds things in a page the way a person does: by role
and name, by text, by label. The same queries work in a Roc `expect` and from `node:test`. From
Node, a test can also build the app and start its server, ask it what a browser would, read the
mail it sent, give itself a database of its own, run the app's jobs, and use its pages in a real
browser.

The user guide is the docs site's [Testing page](https://roc-solid.github.io/ecosystem/testing);
this file is the reference.

```roc
import testing.Dom

expect Dom.parse(Html.to_str(Greeting.view({ name: "Ada" }))).contains(Named("button", "Wave"))
```

```js
const page = await app.client().get("/");
page.dom.getByRole("heading", { name: "Notes" });
```

## Installing it

The Roc half (`Dom`) is plain Roc on no platform (`main.roc` is `package [Dom] {}`), so any module
of an app can import it, on either platform. Name it in the app's header:

```roc
app [program] { pf: platform "…/server/platform/main.roc", testing: "…/packages/testing/main.roc" }
```

The JavaScript half is a set of `.mjs` files with no dependencies. Import them by path, all at once
from `index.mjs` or one module at a time:

```js
import { buildForTests, startServer, testSqlite, launchBrowser } from "../packages/testing/index.mjs";
```

They use the Roc Solid repository they are in (or the one `ROCX_ROOT` names): its compiler, its
`bin/rocx`, and its browser driver. The platforms' hosts must be built there (`just test` builds
them). An installed release has no `.mjs` files, so tests from Node need a clone.

## The four ways to test

### 1. Rules and pure components: `expect`s in Roc

A pure component (`view`, no `!`) makes its markup from its props alone, so `Html.to_str` renders it
to HTML and `Dom.parse` reads that HTML. Write the expects beside the component, as you would for any
rule:

```roc
import pf.Html
import testing.Dom

Greeting := [].{
	view : { name : Str, unread : List(Str) } -> Html
	view = |{ name, unread }|
		<section aria-labelledby="hello">
			<h2 id="hello">Hello, {name}</h2>
			<ul aria-label="Unread">{...unread.map(|subject| <li><a href="/mail">{subject}</a></li>)}</ul>
			<label for="note">Say something</label> <input id="note" name="note" />
			<button>Wave</button>
		</section>
}

page = |props| Dom.parse(Html.to_str(Greeting.view(props)))

expect page({ name: "Ada", unread: [] }).text_of(Role("heading")) == Ok("Hello, Ada")
expect page({ name: "Ada", unread: ["Lunch?", "Re: plans"] }).texts(Role("link")) == ["Lunch?", "Re: plans"]
expect page({ name: "Ada", unread: [] }).get(Label("Say something")).map_ok(|input| input.attr("name")) == Ok(Ok("note"))
expect page({ name: "Ada", unread: [] }).contains(Named("button", "Wave"))
```

After `rocx generate` (which writes `Generated/`), `roc test main.roc` runs every module's
`expect`s. Run it as `rocx check -- roc test main.roc` and a failing `expect` is reported at its line
in the `.rocx` file.

When a query finds nothing, `get` says what there is instead, for example
`NotFound("nothing is a button named \"Save\"; the buttons here: \"Add\", \"Clear all\"")`.
`page.roles()` lists every role and name on the page, to print with `dbg`.

`Html.to_str` renders only markup with nothing to run in it. A component with signals (`view!`)
needs the runtime; test it through its story instead (section 4).

### 2. The app over HTTP, from Node

`buildForTests` builds the app the way a deploy does, and `startServer` starts its server on a port
of its own. A client then asks it what a browser would: pages with a cookie jar, forms, JSON, the
endpoints a page reads, and events. Each answer's `dom` has the same queries, with Testing Library's
names. A markup problem, a type error or a warning makes `buildForTests` throw, with the report at
its `.rocx` line. Its server is built quickly (`--opt=dev`) unless `opt` says otherwise, or
`ROCX_TEST_OPT=speed` does: then it is optimized as a release's is, where some compiler bugs show
that a dev build hides (`just examples-release` runs every example's tests so).

```js
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { buildForTests, startServer, links } from "../packages/testing/index.mjs";

let app;
before(async () => {
	const { server, statics } = await buildForTests("."); // rocx generate, the wasm, the server
	app = await startServer(server, { statics });
});
after(() => app.stop());

test("a note posted from the page", async () => {
	const person = app.client();
	const page = await person.get("/");
	assert.equal(page.dom.getByTestId("count").text, "3 notes");
	page.dom.getByLabelText("New note");

	const posted = await person.post("/notes", { body: "milk" }); // a plain form, from that page
	assert.equal(posted.status, 303);
	assert.deepEqual(person.flash, { url: "/notes", status: 200, body: '"added milk"' }); // what the page it lands on reads
	await posted.follow();

	assert.equal(await person.read("/notes"), 3); // an endpoint, read as a page reads it
	const ticks = await person.events("/api/ticks"); // an endpoint's events!
	assert.deepEqual(await ticks.take(1), [{ event: "message", data: '{"tick":1}', id: null }]);
});

test("a welcome is mailed", async () => {
	await app.client().json("/api/mail", { to: "ada@example.com" });
	const mail = await app.waitForMail({ to: "ada@example.com", subject: /^Hello/ });
	assert.deepEqual(links(mail), ["https://notes.example/hello"]);
});
```

A form can be sent two ways. `post` sends it as a browser does without the runtime: the endpoint
answers with a 303 back to the page, and a flash that holds its result. `client.flash` reads that
flash; the server keeps it and, under `--debug` (which `startServer` passes), says what it holds in
an `x-rocx-flash` header. `submit` sends the form as the runtime does once the page has hydrated,
and gets the endpoint's answer directly.

`mail()` and `waitForMail` read the dev mailbox's JSON, `/__rocx/mail.json`, which the email plugin
(packages/email) serves under `--debug`. When no `SMTP_URL` is set, `Email.send!` keeps each message
there instead of sending it (under `--debug` or `--dev`; a server with neither doesn't start without
one): the last 100, oldest first, each `{ id, at, from, to, cc, bcc, reply_to, headers, subject,
text, html, raw }`. `to` and `reply_to` are as the app wrote them (`to` may name several), `cc` and
`bcc` are lists, `headers` the app's own as `{ name, value }`s, and `raw` the message as SMTP would
carry it, in which no header names the Bcc (so a test can check that it doesn't). `waitForMail`
matches a list's field when one of its items does: `waitForMail({ bcc: "archive@example.com" })`.
They live in the server's memory (`Kv`), with or without a database, so each server a test starts
begins with an empty mailbox, and a restart forgets it.

`rocx routes --server`, in the app's folder, lists its endpoints, each with its method, path and
middleware, which helps when writing requests by hand.

### 3. Its database and its jobs

`testDatabase()` makes a database of the test's own in the Postgres at `DATABASE_URL`, and `drop()`
removes it. The server runs its migrations into it when it starts. `settleJobs()` waits until every
job that is due has run, along with the jobs those queued, and says how each ended.

```js
import { testDatabase } from "../packages/testing/index.mjs";

const db = await testDatabase();
const app = await startServer(server, { statics, database: db.url });

await app.client().json("/api/welcome", { to: "ada@example.com" });
const ran = await db.settleJobs(); // [{ kind: "welcome", state: "done", … }]
await db.enqueue("nightly", {}); // what a cron does at its time, now
await db.settleJobs({ later: true }); // retries and jobs queued for later, now: the queue run to its end
const [note] = await db.sql`select body from notes where body = ${"milk"}`;

await app.stop();
await db.drop();
```

An app on SQLite needs no database server. An app whose program names no database is on SQLite at
`data/app.db`, from where the server starts (D-105), so a test without a database of its own writes
there. `testSqlite()` makes a database file in a new temporary directory instead. Its `url`
(`sqlite:<file>`) is for the server; `db.sql` and `db.query` read and write the same file through
Node's own SQLite (`node:sqlite`); `drop()` removes the directory. The server makes the file and its tables when it starts.

`jobs`, `enqueue` and `settleJobs` work as they do for Postgres, with one difference. On SQLite a
write from the test's process can't wake the server's job workers (SQLite tells only its own
process), so the test asks the server to wake them: `POST /__rocx/jobs/wake`, which the jobs plugin
(packages/jobs) answers under `--debug`. For that, give `startServer` the database itself rather
than its `url`. It passes the URL on, and the database learns which server to ask.

```js
import { testSqlite } from "../packages/testing/index.mjs";

const db = testSqlite();
const app = await startServer(server, { statics, database: db }); // db.url, and db learns the server
const [{ count }] = await db.sql`select count(*) as count from foods where source = ${"usda"}`;
await db.enqueue("nightly", {}); // the workers woken through the server
const ran = await db.settleJobs();
await app.stop();
await db.drop();
```

### 4. In a browser

`launchBrowser()` starts Chromium's headless shell: `$CHROME`, or the one Playwright keeps in its
cache. It answers `null` when there is none, so the test can skip, and the run says so once on the
console (`rocx tests: no Chromium headless shell, so the tests that need it skip …`). In CI (`CI`
set, as GitHub Actions sets it), or with `ROCX_BROWSERS=required`, a missing browser is an error
instead, so a CI whose browser install broke fails rather than passing with its browser tests
skipped. Install the browsers in CI (`npx playwright install --with-deps --only-shell chromium
firefox`), or set `ROCX_BROWSERS=optional` where the browser tests may skip. `browser.open(url)`
opens a tab and waits for the page to hydrate, strictly: a page that isn't what the browser's half
renders throws. The tab has the same queries, and its elements are used with real clicks and keys.
`findBy…` looks again until the page shows what it asks for.

The tabs of one browser share their cookies, as one person's browser does. To test two people at
once (two players, two editors of one board), launch two browsers, as examples/board's tests do.

```js
const browser = await launchBrowser();
const tab = await browser.open(`${app.url}/`);
await (await tab.getByRole("button", { name: "Add one" })).click();
await tab.findByText("2");
await (await tab.getByLabelText("New note")).fill("milk");
await tab.drag(await tab.getByText("Milk"), await tab.getByRole("list", { name: "Done" }));
assert.deepEqual(tab.errors, []);
```

`launchBrowser({ engine: "gecko" })` starts a Gecko browser instead, headless: `$GECKO`, Zen,
Firefox, or the Firefox Playwright keeps (`null` when there is none). It is driven over WebDriver
BiDi, and its tabs do everything Chromium's do except take a dark screenshot. Each tab it goes to is
made the shown one, so its transitions run (a hidden headless tab gets about one frame a second).

`tab.drag(source, target)` presses `source`'s middle and drops it on `target`'s (each an element the
tab found, or a CSS selector). It fires dragstart, drag, dragenter and dragover; then drop if the
target accepts it (its dragover's default prevented), or else dragleave; then dragend; each with its
coordinates. In Chromium these are the browser's own drag and drop, through real pointer input.
Gecko never ends a drag that WebDriver's pointer starts, headless or not (Mozilla's bug 1515879), so
there `drag` fires the DOM's own drag events, untrusted, with one `DataTransfer` carried through
them, and no pointer or mouse events. With `{ drop: false }` the drag stays over the target until
`tab.finish()`, or `tab.finish({ cancel: true })` (dragleave and dragend in Gecko, dragend alone in
Chromium).

`tab.touchDrag(source, target)` drags by touch, as on a phone. A finger goes down on `source`'s
middle and is held 400 ms (`{ hold }`; the runtime starts a drag of its own after a quarter second
held still, and `hold: 0` is a swipe, which scrolls instead). It then moves to `target`'s middle a
frame at a time, and lifts. It is real touch input in both engines (touch events, and the pointer
events the browser makes of them): the DevTools protocol's `Input.dispatchTouchEvent` in Chromium,
WebDriver's touch actions in Gecko. With `{ lift: false }` the finger stays down on the target until
`tab.lift()`, so a test can look at the page mid-drag.

A component with signals can't be rendered by `Html.to_str`, since its holes run in the runtime, but
its `<story>` can be tested. `buildForTests(dir, { dev: true })` serves each story as a page, at
`storyPath("Counter", "At ten")`, to fetch or to open.

## `Dom` (Roc)

`Dom.parse(html)` reads HTML into a tree. It expects HTML that closes its elements, as Roc Solid
writes it and a browser serializes it: void elements (`<br>`, `<input>`) need no end tag, and an end
tag closes the elements still open inside it.

### Queries

`Dom.Query` is one of these:

| Query | Finds |
|---|---|
| `Role(role)` | elements with that ARIA role: their `role` attribute's, or their tag's (`<button>` button, `<a href>` link, `<h2>` heading, `<input type="checkbox">` checkbox, `<ul>` list, `<li>` listitem, `<nav>` navigation, `<output>` status…) |
| `Named(role, name)` | elements with that role whose accessible name is `name`. The name is `aria-labelledby`, `aria-label`, a `<label>`, `alt`, the text of a button, a link, a heading or a cell, or `title` |
| `Text(text)` | elements whose own text (not their children's) is `text`, as Testing Library's `getByText` |
| `Label(text)` | the control a `<label>` with that text names (by `for`, or by wrapping it), or whose `aria-label` or `aria-labelledby` says it |
| `TestId(id)` | elements with `data-testid="id"` |
| `Tag(tag)`, `Attr(name, value)` | elements by tag, or by an attribute's value, hidden or not |

Text is compared as a reader sees it: whitespace collapsed, and trimmed. `Role`, `Named`, `Text` and
`Label` skip what a reader can't see: an element with `hidden`, `aria-hidden="true"`, or
`display: none` or `visibility: hidden` in its `style`, and everything inside it; `<head>`,
`<script>`, `<style>`, `<template>`, `<noscript>`, and `<input type="hidden">`.

### Functions

| Function | Answers |
|---|---|
| `Dom.parse(html)` | `Dom`: the document, or a fragment of one |
| `node.get(query)` | `Try(Dom, [NotFound(Str), TooMany(Str)])`: the one element, or an error that says what there is instead, or how many matched |
| `node.first(query)` | `Try(Dom, [NotFound(Str)])`: the first match |
| `node.all(query)` | `List(Dom)`: every match, in the page's order |
| `node.contains(query)`, `node.count(query)` | whether anything matches; how many do |
| `node.text_of(query)` | `Try(Str, [NotFound(Str), TooMany(Str)])`: the text of the one match |
| `node.texts(query)` | `List(Str)`: the text of each match (a list's items, a column's cells) |
| `node.text()` | what a reader reads in it, without `<script>`, `<style>` and `<template>`, whitespace collapsed |
| `node.attr(name)` | `Try(Str, [Missing])`; `""` for an attribute written bare, as `checked` |
| `node.tag()` | its tag name in lower case; `""` for text, a comment or the document |
| `node.has_class(class)` | whether `class` is one of its classes |
| `node.roles()` | `List((Str, Str))`: the role and accessible name of every element a reader can reach, in order (Testing Library's `logRoles`) |

A query on an element (`list.count(Role("listitem"))`) looks only inside that element. Two `Dom`s
compare with `==`: their tags, their attributes in order, their text and their comments.

## The JavaScript

| Module | What it gives a test |
|---|---|
| `dom.mjs` | `parse(html)`, `within(node)` and `screen(html)` (`within(parse(html))`): Testing Library's queries, `getByRole(role, { name, level, hidden })`, `getByText`, `getByLabelText`, `getByTestId`, each also as `queryBy…` (null for none), `getAllBy…` and `queryAllBy…` (`[]` for none). `getBy…` and `queryBy…` throw a `QueryError` when more than one matches; `getBy…` and `getAllBy…` throw one, saying what there is instead, when none does. A name or text is a string, matched whole with its whitespace collapsed, or a `RegExp`. A `Node` has `tag`, `text`, `attr(name)`, `role`, `name`, `hasClass(name)` and `elements`. The rules are `Dom.roc`'s. Also `roles(node)`, `isHidden(node)`, `normalize(text)`, `decode(text)`, `serialize(node)`. |
| `server.mjs` | `startServer(executable, options)`: the server on a free port, resolved once it listens. Options: `statics` (directories it serves), `database` (a URL, or a test's own database: its `url`, and the database then knows the server), `dev` (`--dev`), `debug` (`--debug`, on by default), `context` (`--context-file`), `flags`, `env` (added to the environment; `ROCX_LOG` is `json` unless it says otherwise), `cwd`. A `Server` has `url`, `client()`, `mail()` (each message's `to`, `cc`, `bcc`, `reply_to`, `headers`, …), `waitForMail(match, { after, ms })` (a list's field matches when one item does), `logs()` (the JSON log, parsed) and `stop()`. A `Client` is one person's cookie jar: `get` (a page), `post` (a plain form, from the last page), `submit` (as the runtime sends a form), `json(path, value, method)`, `put(path, bytes)`, `read(path)` (a GET endpoint, as a page reads it; a `ReadError` unless 200), `events(path)` (an `Events` stream: `next()`, `take(n)`, `close()`, or `for await`), `request(path, { method, headers, body })`, `cookies` and `flash`. Each `Answer` has `status`, `headers`, `location`, `text`, `bytes`, `json()`, `dom` and `follow()`. Also `links(message)`, `until(check, { ms })` and `storyPath(module, name)`. |
| `postgres.mjs` | `testDatabase(url = DATABASE_URL, { template, prefix })`: a database of the test's own (with `template`, a copy of that database), with `url`, `name`, `query(text)`, `` sql`…${value}` `` (values written as literals), `jobs({ kind, state })`, `enqueue(kind, input, { key, attempts })`, `settleJobs({ later, ms })`, `close()` and `drop()`. `connect(url)` opens one connection with the same methods. A client of its own, over Node's sockets: the simple query protocol; SCRAM-SHA-256, MD5 or a clear-text password; rows as objects of numbers, booleans, JSON and text. |
| `sqlite.mjs` | `testSqlite({ prefix })`: a SQLite file of the test's own, with `url`, `path`, `query(sql, params)`, `` sql`…${value}` `` (values as parameters: a boolean as 1 or 0, a date as ISO text, an object as JSON), `jobs`, `enqueue`, `settleJobs` (the workers woken through the server), `close()` and `drop()`, over `node:sqlite`. |
| `browser.mjs` | `launchBrowser({ engine })` (`"chromium"` or `"gecko"`; `null` when there is none, said once on the console; an error where browsers are required), `findChrome()`, `findGecko()` (the same), `browsersRequired()` (`ROCX_BROWSERS=required`, or `CI` set unless `ROCX_BROWSERS=optional`). `browser.open(url, { strict, cookies, script, timeout })` and `browser.close()`. A `Tab` has the queries (async), `findBy…` and `findAllBy…` (`(query, options, { ms })`), `waitFor(check, { ms })`, `goto(url)`, `dom()`, `text()`, `requested()`, `errors`, `console`, `screenshot({ width, height, full, dark })`, `drag(source, target, { drop })`, `finish({ cancel })`, `touchDrag(source, target, { hold, lift })`, `lift()` and `close()`. Each `Element` has `tag`, `text`, `role`, `name`, `attr(name)`, `click()`, `focus()`, `fill(text)`, `type(text)`, `press(key)`, `value()`, `checked()` and `selector()`. |
| `build.mjs` | `buildForTests(dir, { out, client, dev, opt, specialize })`: `rocx generate`, the browser's wasm and the server, into `out` (`<dir>/build/test`); answers `{ server, statics }`. `client: false` skips the browser's half; `dev: true` adds the stories; `opt` is the server's optimization (`"dev"`, or `"speed"`, built without lambda-set specialization unless `specialize` or `ROCX_SPECIALIZE=yes`), by default `ROCX_TEST_OPT`, else `"dev"`. Also `repo`, the repository it uses. |
| `index.mjs` | everything above |

## Status

Everything above works today, and is tested here. `roc test packages/testing/main.roc` runs `Dom`'s
expects. `node --test 'packages/testing/test/*.test.mjs'` (part of `just test`) runs:

- `dom.test.mjs` (HTML parsing and queries) and `server.test.mjs` (the client against a stand-in
  server). They need nothing else.
- `postgres.test.mjs`: the client, and a database of a test's own. It needs `DATABASE_URL`.
- `sqlite.test.mjs`: a SQLite file of a test's own, read, written and removed. It needs nothing.
- `roc.test.mjs`: an app's expects using `testing.Dom`, and a failing one reported at its `.rocx`
  line. It needs Roc.
- `build.test.mjs`: `buildForTests` throwing on a type error, and on a warning alone. It needs the
  toolchain and the server's host built.
- `browser.test.mjs`: `tab.drag` in each browser there is; and no browser, skipped outside CI and
  an error in it (it needs nothing).
- `app.test.mjs`: everything above against a real app it builds (`test/fixture.mjs`), with
  Postgres when it is there, and Chromium and Gecko (required in CI, as above). It needs the
  toolchain and the platforms' hosts built.

Not yet. Each of these needs a change outside the package, written up in `PROPOSALS.md`:

- a clock a test sets, and seeded randomness (a test mode for the server);
- outbound `Http` requests answered by stubs (an S3 bucket's requests too, packages/storage), so a
  test makes no network calls;
- jobs and crons run on request, by name, without SQL;
- clearing the dev mailbox between tests (today, `waitForMail`'s `after` skips the messages already
  there);
- requests answered in-process from Roc, and `view!` components rendered in a Roc test (`rocx test`);
- helpers in this package that run inside the server under test;
- a browser driven from Roc. packages/headless (D-128) drives Chromium from Roc already, over the CLI
  platform's `WebSocket`; Gecko, drags, touch and these queries in its tabs are in its
  PROPOSALS.md.

Limits:

- The tabs of one browser share cookies, so `open` clears them first.
- `Dom.parse` doesn't close elements that HTML lets you leave open: `<p>one<p>two` nests.
- The JavaScript imports the repository by path (`server/build.mjs`, `web/test/browser.mjs`, and
  `bin/rocx` through `server/build.mjs`'s `rocxBinary`), from its own place or from `ROCX_ROOT`.
