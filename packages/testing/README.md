# testing

Helpers for testing a Roc Solid app. Find things in a page as a person finds them, by role and
name, by text, by label, in a Roc `expect` and from `node:test`. Build the app and start its
server. Ask it as a browser would, read the mail it sent, give each test a database of its own and
run its jobs, and use its pages in a real browser.

```roc
import testing.Dom

expect Dom.parse(Html.to_str(Greeting.view({ name: "Ada" }))).contains(Named("button", "Wave"))
```

```js
const page = await app.client().get("/");
page.dom.getByRole("heading", { name: "Notes" });
```

## How to test a Roc Solid app

**1. Rules and pure components: `expect`s, in Roc.** `roc test main.roc` runs every module's
`expect`s. A pure component (`view`, no `!`) renders to HTML with `Html.to_str`, and `Dom.parse`
reads that HTML. Write the expects beside the component, as you would for any rule:

```roc
app [program] { testing: "../packages/testing/main.roc", pf: platform "../server/platform/main.roc" }
```

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

A failing `expect` is reported at its line in the `.rocx` file under `rocx check -- roc test main.roc`.
When a query finds nothing, `get` says what there is instead (`NotFound("nothing is a button named
\"Save\"; the buttons here: \"Add\", \"Clear all\"")`), and `page.roles()` lists every role and name,
for a `dbg`.

**2. The app, from Node: `node:test` over HTTP.** Build the app as a deploy builds it, start its
server on a port of its own, and ask it as a browser would: a cookie jar, forms, JSON, the
endpoints a page reads, events. Each answer's `dom` holds the same queries, with Testing Library's names.
A markup problem, a type error or a warning makes `buildForTests` throw, with the report at its
`.rocx` line.

```js
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { buildForTests, startServer, links } from "../packages/testing/index.mjs";

let app;
before(async () => {
	const { server, statics } = await buildForTests("."); // rocx build, the wasm, the server
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

`rocx routes <dir>` lists the app's routes, each with its method, path, file and middleware
(`GET /notes`).

`mail()` and `waitForMail` read the dev mailbox's JSON (`/__rocx/mail.json`, which the email
plugin serves under `--debug`: packages/email): the last 100 messages `Email.send!` kept rather
than sent (no `SMTP_URL`), oldest first,
each with an `id`. The server keeps them in its memory (`Kv`), database or not, so each server a
test starts has an empty mailbox, and a restart forgets it.

**3. Its database and its jobs.** `testDatabase()` makes a database of the test's own in the
Postgres at `DATABASE_URL`, and `drop()` removes it. The server runs its migrations into it when it
starts. `settleJobs()` waits until every job that is due has run, and the jobs those queued, and
says how each ended.

```js
import { testDatabase } from "../packages/testing/index.mjs";

const db = await testDatabase();
const app = await startServer(server, { statics, database: db.url });

await app.client().json("/api/welcome", { to: "ada@example.com" });
const ran = await db.settleJobs(); // [{ kind: "welcome", state: "done", … }]
await db.enqueue("nightly", {}); // what a cron does at its time, now
await db.settleJobs({ later: true }); // jobs queued for later, and retries, now: the queue run to its end
const [note] = await db.sql`select body from notes where body = ${"milk"}`;

await app.stop();
await db.drop();
```

An app on SQLite (`database: Sqlite(…)`, D-045) needs no database server: `testSqlite()` is a file
of the test's own in a directory of its own, its `url` (`sqlite:<file>`) for the server, `db.sql`
and `db.query` over Node's own SQLite (`node:sqlite`) beside it, and `drop()` removes the directory.
The server makes the file, and its tables, when it starts. `jobs`, `enqueue` and `settleJobs` are
there too, as for Postgres, but a write from the test's process can't wake the server's job workers
(SQLite tells only its own process), so they ask the server to: `POST /__rocx/jobs/wake`, which the
jobs plugin (packages/jobs) answers under `--debug` (as `startServer` starts it). For that, give
`startServer` the database itself rather than its `url`: it passes the url on, and the database
then knows its server.

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

**4. In a browser.** `launchBrowser()` starts Chromium's headless shell, or gives null when there
is none, so the test can skip. A tab hydrates strictly: a page that isn't what the browser's half
renders throws. You find things in it with the same queries, and use them with real clicks and
keys. `findBy…` looks again until the page shows what it asks for. The tabs of one launch share
their cookies, as one person's browser does: a test of two people at once (two players, two
editors of one board) launches twice, a browser each, as examples/board's does.

```js
const browser = await launchBrowser();
const tab = await browser.open(`${app.url}/`);
await (await tab.getByRole("button", { name: "Add one" })).click();
await tab.findByText("2");
await (await tab.getByLabelText("New note")).fill("milk");
await tab.drag(await tab.getByText("Milk"), await tab.getByRole("list", { name: "Done" }));
assert.deepEqual(tab.errors, []);
```

`launchBrowser({ engine: "gecko" })` starts Gecko instead, headless: `$GECKO`, or Zen, or Firefox,
or the Firefox Playwright keeps (null when there is none). It is driven over WebDriver BiDi, and its
tabs do what Chromium's do, but for a dark screenshot. Each tab it goes to is the shown one, so its
transitions run (a hidden headless tab gets a frame about once a second).

`tab.drag(source, target)` presses `source`'s middle and drops it on `target`'s (elements found, or
CSS selectors): dragstart, drag, dragenter, dragover, then drop if the target takes it (its
dragover's default prevented), or else dragleave; then dragend; each with its coordinates. In
Chromium these are the browser's own drag and drop, through real pointer input. Gecko never ends a
drag that WebDriver's pointer starts, headless or not (Mozilla's bug 1515879), so there `drag` fires
the DOM's own drag events, untrusted, with one `DataTransfer` carried through them, and no pointer or
mouse events. With `{ drop: false }` the drag stays over the target until `tab.finish()` (or
`tab.finish({ cancel: true })`: dragleave and dragend in Gecko, dragend alone in Chromium).

A component with signals can't be rendered by `Html.to_str` (its holes run in the runtime), but its
`<story>` can: `buildForTests(dir, { dev: true })` serves each story as a page, at
`storyPath("Counter", "At ten")`, to fetch or to open.

## `Dom` (Roc)

`Dom.parse(html)` reads HTML into a tree. It reads HTML that closes its elements, as Roc Solid writes
it and a browser serializes it.

| Query | Finds |
|---|---|
| `Role(role)` | elements with that ARIA role: their `role`, or their tag's (`<button>` button, `<a href>` link, `<h2>` heading, `<input type="checkbox">` checkbox, `<ul>` list, `<li>` listitem, `<nav>` navigation, `<output>` status…) |
| `Named(role, name)` | and whose accessible name is `name`: `aria-labelledby`, `aria-label`, a `<label>`, `alt`, the text of a button, a link, a heading or a cell, `title` |
| `Text(text)` | elements whose own text is `text` (Testing Library's `getByText`) |
| `Label(text)` | the control a `<label>` with that text names (by `for`, or inside it), or whose `aria-label` or `aria-labelledby` says it |
| `TestId(id)` | `data-testid="id"` |
| `Tag(tag)`, `Attr(name, value)` | elements by tag, or by an attribute's value, hidden or not |

| Function | |
|---|---|
| `page.get(query)` | `Try(Dom, [NotFound(Str), TooMany(Str)])`: the one element; the error says what there is instead |
| `page.first(query)`, `page.all(query)` | the first; every one, in the page's order |
| `page.contains(query)`, `page.count(query)` | whether it finds any; how many |
| `page.text_of(query)`, `page.texts(query)` | the text of the one; of each |
| `node.text()`, `node.attr(name)`, `node.tag()`, `node.has_class(class)` | what a reader reads (whitespace collapsed); an attribute (`Err(Missing)`); its tag; a class |
| `page.roles()` | every `(role, name)` a reader can reach, for a `dbg` |

A query on an element (`list.count(Role("listitem"))`) looks inside it. Roles, names, text and
labels skip what a reader can't see: `hidden`, `aria-hidden="true"`, `display: none` in a `style`,
`<head>`, `<script>`, `<style>`, `<template>`. Two `Dom`s compare with `==`.

## The JavaScript

| Module | What it gives a test |
|---|---|
| `dom.mjs` | `parse(html)`, `within(node)`: Testing Library's queries, `getByRole(role, { name, level, hidden })`, `getByText`, `getByLabelText`, `getByTestId`, each as `queryBy…` (null), `getAllBy…`, `queryAllBy…`. A name or text is a string, matched whole with its whitespace collapsed, or a RegExp. A node has `text`, `attr(name)`, `role`, `name`, `hasClass`, `elements`. The rules are `Dom.roc`'s. |
| `server.mjs` | `startServer(executable, { statics, database, dev, flags, env })`: the server on a free port, with `--debug`; `database` a URL, or a test's own database (its `url`, and it then knows the server). Its `client()` is a cookie jar: `get`, `post` (a plain form, from the last page), `submit` (as the runtime sends a form), `json`, `put`, `read(path)` (a GET endpoint, as a page reads it), `events(path)`, and `flash` (what a plain post's flash holds, which the server keeps and says with `--debug`: its URL, status and body). Each `Answer` has `status`, `location`, `text`, `json()`, `dom`, `follow()`. Also `mail()`, `waitForMail(match, { after })`, `logs()` (the JSON log), `stop()`; `links(message)`, `until(check)`, `storyPath(module, name)`. |
| `postgres.mjs` | `testDatabase(url, { template })`: a database of the test's own, with `url`, `query`, `` sql`…${value}` `` (values as literals), `jobs`, `enqueue`, `settleJobs`, `drop`. `connect(url)`. A client of its own, over Node's sockets: SCRAM-SHA-256, the simple query protocol, rows as objects of numbers, booleans, JSON and text. |
| `sqlite.mjs` | `testSqlite()`: a SQLite file of the test's own, with `url`, `path`, `query(sql, params)`, `` sql`…${value}` `` (values as parameters: a boolean as 1 or 0, an object as JSON), `jobs`, `enqueue`, `settleJobs` (the workers woken through the server: `POST /__rocx/jobs/wake`), `close`, `drop`, over `node:sqlite`. |
| `browser.mjs` | `launchBrowser({ engine })` (`"chromium"`, or `"gecko"`), `browser.open(url, { strict, cookies, script })`: a `Tab` with the queries (async), `findBy…`, `waitFor(check)`, `dom()`, `text()`, `requested()`, `errors`, `console`, `screenshot()`, `drag(source, target)`, `finish()`. Each `Element` has `click()`, `fill(text)`, `type(text)`, `press(key)`, `value()`, `checked()`, `selector()`. |
| `build.mjs` | `buildForTests(dir, { client, dev, opt })`: `rocx build`, the browser's wasm, the server; `{ server, statics }` |
| `index.mjs` | all of the above |

## Status

Works today, and is tested here. `roc test packages/testing/main.roc` runs `Dom`'s expects.
`node --test 'packages/testing/test/*.test.mjs'` runs these:

- `dom.test.mjs` (HTML parsing and queries) and `server.test.mjs` (the client against a stand-in
  server). They need nothing else.
- `postgres.test.mjs`: the client, and a database of a test's own. It needs `DATABASE_URL`.
- `sqlite.test.mjs`: a SQLite file of a test's own, read and written, and removed. It needs nothing.
- `roc.test.mjs`: an app's expects using `testing.Dom`, and a failing one reported at its `.rocx`
  line. It needs Roc.
- `app.test.mjs`: everything above against a real app it builds (`test/fixture.mjs`), with
  Postgres and Chromium when they are there. It needs the toolchain and the platforms' hosts built.

Waits on a proposal (PROPOSALS.md):

- a clock a test sets, and seeded randomness (a test mode in the server);
- outbound `Http` stubbed (an S3 bucket's requests too, packages/storage), so a test makes no network calls;
- jobs and crons run by a request, without SQL;
- clearing the dev mailbox between tests;
- requests answered in-process from Roc, and `view!` components rendered in a Roc test (`rocx test`);
- server-only test helpers in this package (server-only modules in packages).

Limits, for now:

- Tabs of one browser share cookies: `open` clears them first.
- `Dom.parse` doesn't close elements HTML leaves open (`<p>one<p>two` nests).
- The JavaScript imports the repository (`server/build.mjs`, `web/test/browser.mjs`, and `bin/rocx` through `server/build.mjs`'s `rocxBinary`) by
  path, or from `ROCX_ROOT`.
