// The app, tested as people use it: over HTTP (pages, plain forms, the runtime's posts, the
// endpoints as JSON, the database), then in a real browser. The app is built once (rocx generate, the
// browser's wasm, the server), and started against a SQLite file of the tests' own, which its
// migrations make and seed. Each test that changes things makes a list of its own first, so the
// tests don't lean on each other. No database server is needed.
//
//   node --test 'examples/tasks/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildForTests, startServer, testSqlite, launchBrowser, until, repo } from "../../../packages/testing/index.mjs";

const skip = false;

let db;
let app;
/** Chromium's headless shell, or null when there is none: the browser's tests skip then. */
let browser = null;

before(async () => {
	if (skip) return;
	const built = await buildForTests(join(repo, "examples", "tasks"));
	db = testSqlite();
	app = await startServer(built.server, { statics: built.statics, database: db.url });
	browser = await launchBrowser();
});

after(async () => {
	await browser?.close();
	await app?.stop();
	await db?.drop();
});

/** A list of the test's own, made with the front page's form, as a browser without JavaScript would: its id. */
async function newList(person, name) {
	await person.get("/");
	const made = await person.post("/api", { name });
	assert.equal(made.status, 303);
	const id = /^\/lists\/(\d+)$/.exec(made.location)?.[1];
	assert.ok(id, `a new list's page, not ${made.location}`);
	return id;
}

/** A task added to the list `id` with its form, without JavaScript: its id, from the database. */
async function addTask(person, id, fields) {
	await person.get(`/lists/${id}`);
	const added = await person.post(`/api/lists/${id}`, { due: "", assignee: "", ...fields });
	assert.equal(added.status, 303);
	const [row] = await db.sql`select cast(id as text) as id from tasks where list_id = ${Number(id)} and title = ${fields.title}`;
	return row.id;
}

/** How packages/auth keeps a session's token: its SHA-256, base64url. */
function hashOf(token) {
	return createHash("sha256").update(token).digest("base64url");
}

/** The titles on the list `id`, in its order, as its page shows them: each task's box is named by its title. */
async function titles(person, id, query = "") {
	const page = await person.get(`/lists/${id}${query}`);
	return page.dom.queryAllByRole("checkbox").map((box) => box.name);
}

test("the front page shows the seeded lists, with their counts", { skip }, async () => {
	const page = await app.client().get("/");
	assert.equal(page.status, 200);
	page.dom.getByRole("heading", { level: 1, name: "Your team's lists" });
	const cards = page.dom.getByRole("list", { name: "Lists" });
	assert.ok(cards.text.includes("Website relaunch"));
	assert.ok(cards.text.includes("4 open · 1 done"));
	// The layout's lists, down the side, from GET /api/team.
	page.dom.getByRole("navigation", { name: "Lists" });
	page.dom.getByRole("link", { name: "Office move 3 open" });
	// Its icon, an SVG in a data: URL, as the layout wrote it (Html allows one in <link href>).
	assert.match(page.text, /<link rel="icon" type="image\/svg\+xml" href="data:image\/svg\+xml,%3Csvg [^"]*%3C\/svg%3E">/);
});

test("a list shows its tasks in order, each due day and person, and the open count", { skip }, async () => {
	const page = await app.client().get("/lists/1");
	assert.equal(page.status, 200);
	page.dom.getByRole("heading", { level: 1, name: "Website relaunch" });
	page.dom.getByText("4 open");
	const done = page.dom.getByRole("checkbox", { name: "Pick the hero photo" });
	assert.equal(done.attr("aria-checked"), "true");
	page.dom.getByRole("img", { name: "Jun Park" });
	page.dom.getByText("Tomorrow");
	page.dom.getByText(/^Overdue · /);
	// Its data is its own URL's, as JSON.
	const sheet = await app.client().read("/api/lists/1");
	assert.equal(sheet.name, "Website relaunch");
	assert.deepEqual(
		sheet.tasks.map((task) => task.title),
		["Write the launch announcement", "Proofread the pricing page", "Redirect the old blog URLs", "Pick the hero photo", "Check every page on a phone"],
	);
	// A null due day or assignee (Db.Nullable) is "" in the JSON.
	assert.equal(sheet.tasks[4].assignee, "");
	assert.equal(sheet.tasks[3].due, "");
});

test("the filters are links, and the counts beside them follow the tasks", { skip }, async () => {
	const person = app.client();
	assert.deepEqual(await titles(person, "1", "?show=done"), ["Pick the hero photo"]);
	assert.equal((await titles(person, "1", "?show=open")).length, 4);
	const page = await person.get("/lists/1?show=open");
	assert.equal(page.dom.getByRole("link", { name: "Open 4" }).attr("aria-current"), "page");
	assert.equal(page.dom.getByRole("link", { name: "All 5" }).attr("href"), "/lists/1");
	// "Mine" asks who you are, until you say.
	const mine = await person.get("/lists/1?show=mine");
	mine.dom.getByText("Say who you are (at the top) to see your tasks.");
});

test("a list or a task that isn't there is a 404: the app's error page, as a path no page has is", { skip }, async () => {
	const person = app.client();
	for (const path of ["/lists/999", "/lists/nope", "/tasks/999"]) {
		const missing = await person.get(path);
		assert.equal(missing.status, 404, path);
		missing.dom.getByRole("heading", { name: "There's nothing here" });
		assert.equal(missing.dom.getByRole("link", { name: "Back to your lists" }).attr("href"), "/");
	}
	assert.equal((await person.get("/no/such/page")).status, 404);
	assert.equal((await person.read("/api/lists/999").catch((error) => error.status)), 404);
});

test("adding a task without JavaScript: a plain form, a 303 back, and it is on the list", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "Groceries");
	await person.get(`/lists/${id}`);
	const added = await person.post(`/api/lists/${id}`, { title: "  Buy   milk ", due: "2030-01-15", assignee: "mila" });
	assert.equal(added.status, 303);
	assert.equal(new URL(added.location, app.url).pathname, `/lists/${id}`);
	const page = await added.follow();
	page.dom.getByRole("checkbox", { name: "Buy milk" });
	// The form starts afresh: what an accepted post typed doesn't come back into it.
	assert.equal(page.dom.getByLabelText("New task").attr("value"), "");
	page.dom.getByRole("img", { name: "Mila Novak" });
	page.dom.getByText("Jan 15, 2030");
	// SQLite keeps a boolean as 1 or 0, which is what node:sqlite reads (Db reads `done` as a Bool).
	const [row] = await db.sql`select title, due, assignee, done, position from tasks where list_id = ${Number(id)}`;
	assert.deepEqual(row, { title: "Buy milk", due: "2030-01-15", assignee: "mila", done: 0, position: 0 });
	// Left empty, the optional fields are null in the database.
	await addTask(person, id, { title: "Bread" });
	const [bread] = await db.sql`select due, assignee, position from tasks where title = ${"Bread"}`;
	assert.deepEqual(bread, { due: null, assignee: null, position: 1 });
});

test("a task the form refuses comes back with its issues in place, and what was typed", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "Refusals");
	await person.get(`/lists/${id}`);
	const refused = await person.post(`/api/lists/${id}`, { title: "   ", due: "2026-02-30", assignee: "" });
	assert.equal(refused.status, 303);
	assert.equal(person.flash.status, 422);
	const page = await refused.follow();
	const title = page.dom.getByLabelText("New task");
	assert.equal(title.attr("aria-invalid"), "true");
	page.dom.getByText("Fill this in");
	const due = page.dom.getByLabelText("Due");
	assert.equal(due.attr("value"), "2026-02-30");
	assert.equal(due.attr("aria-invalid"), "true");
	// And nothing was added.
	assert.deepEqual(await db.sql`select id from tasks where list_id = ${Number(id)}`, []);
	// Someone not on the team is refused by the endpoint, which knows the team.
	const nobody = await person.submit(`/api/lists/${id}`, { title: "Hire someone", due: "", assignee: "zed" });
	assert.equal(nobody.status, 422);
	assert.match(nobody.text, /Choose someone on the team/);
	assert.equal(nobody.headers.get("content-type"), "application/json", "a form's issues are JSON, and say so (D-093)");
});

test("a task's body is checked by its form whatever it comes as (D-093): JSON is read by the same rules, and refused with the same issues, as JSON", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "From a script");
	await person.get(`/lists/${id}`);
	const added = await person.json(`/api/lists/${id}`, { title: "  Call   the  printer ", due: "2030-03-01" });
	assert.equal(added.status, 200, added.text);
	const [row] = await db.sql`select title, due, assignee from tasks where id = ${Number(added.json())}`;
	assert.deepEqual(row, { title: "Call the printer", due: "2030-03-01", assignee: null }, "trimmed and collapsed by the form's rules, an assignee left out none");
	const refused = await person.json(`/api/lists/${id}`, { title: " ", due: "2030-02-30", assignee: "mila" });
	assert.equal(refused.status, 422);
	assert.equal(refused.headers.get("content-type"), "application/json");
	assert.deepEqual(refused.json().map((issue) => [issue.field, issue.message]), [["title", "Fill this in"], ["due", "Enter a date, like 2026-01-31"]]);
	// What a form can't say: a record inside a field is a 400, before the rules.
	assert.equal((await person.json(`/api/lists/${id}`, { title: { text: "x" } })).status, 400);
	// The new list's name is checked so too.
	const unnamed = await person.json("/api", { name: "  " });
	assert.equal(unnamed.status, 422);
	assert.deepEqual(unnamed.json().map((issue) => [issue.field, issue.message]), [["name", "Fill this in"]]);
});

test("completing a task without JavaScript: its box is a form, and the list comes back with it done", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "Chores");
	const task = await addTask(person, id, { title: "Water the plants" });
	await person.get(`/lists/${id}?show=open`);
	const ticked = await person.post("/api/tasks/toggle", { id: task, done: "true" });
	assert.equal(ticked.status, 303);
	// Back to the page it came from, filter and all.
	assert.equal(new URL(ticked.location, app.url).search, "?show=open");
	const page = await ticked.follow();
	page.dom.getByText("All done");
	assert.equal((await person.get(`/lists/${id}`)).dom.getByRole("checkbox", { name: "Water the plants" }).attr("aria-checked"), "true");
	// The runtime's post of the same form gets JSON, and the page stays.
	const again = await person.submit("/api/tasks/toggle", { id: task, done: "false" });
	assert.equal(again.status, 200);
	assert.deepEqual(await db.sql`select done from tasks where id = ${Number(task)}`, [{ done: 0 }]);
	// A toggle says where it ends up, so sending it twice is sending it once.
	await person.submit("/api/tasks/toggle", { id: task, done: "false" });
	assert.deepEqual(await db.sql`select done from tasks where id = ${Number(task)}`, [{ done: 0 }]);
	assert.equal((await person.submit("/api/tasks/toggle", { id: "999999", done: "true" })).status, 404);
});

test("moving tasks: up and down with forms, anywhere as JSON, the same way the page shows it", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "Order");
	const [a, , c] = [await addTask(person, id, { title: "A" }), await addTask(person, id, { title: "B" }), await addTask(person, id, { title: "C" })];
	assert.deepEqual(await titles(person, id), ["A", "B", "C"]);
	// C's "Move up" button posts its place: just before B.
	const page = await person.get(`/lists/${id}`);
	const up = page.dom.getByRole("button", { name: "Move up: C" });
	assert.equal(up.attr("value"), "1");
	assert.equal(page.dom.getByRole("button", { name: "Move up: A" }).attr("disabled"), "");
	assert.equal((await person.post("/api/tasks/move", { id: c, to: up.attr("value") })).status, 303);
	assert.deepEqual(await titles(person, id), ["A", "C", "B"]);
	// A drop sends the same record as JSON (an action).
	assert.equal((await person.json("/api/tasks/move", { id: a, to: 2 })).status, 200);
	assert.deepEqual(await titles(person, id), ["C", "B", "A"]);
	const rows = await db.sql`select title, position from tasks where list_id = ${Number(id)} order by position`;
	assert.deepEqual(rows, [{ title: "C", position: 0 }, { title: "B", position: 1 }, { title: "A", position: 2 }]);
});

test("deleting: from the list, the page comes back without it; from its page, back to the list", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "Deletions");
	const first = await addTask(person, id, { title: "Old idea" });
	const second = await addTask(person, id, { title: "Older idea" });
	assert.deepEqual((await person.submit("/api/tasks/delete", { id: first })).json(), id);
	await person.get(`/tasks/${second}`);
	const gone = await person.post("/api/tasks/delete", { id: second });
	assert.equal(gone.status, 303);
	assert.equal(gone.location, `/lists/${id}`);
	(await gone.follow()).dom.getByText("Nothing on this list yet. Add the first task below.");
	// Gone already is no problem: a delete sent twice deletes once.
	assert.equal((await person.submit("/api/tasks/delete", { id: second })).status, 200);
});

test("a task's page edits everything about it, and shows a refusal's issues under their fields", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "Edits");
	const task = await addTask(person, id, { title: "Plan the party", due: "2030-03-01", assignee: "jun" });
	const page = await person.get(`/tasks/${task}`);
	assert.equal(page.dom.getByLabelText("Title").attr("value"), "Plan the party");
	assert.equal(page.dom.getByLabelText("Due").attr("value"), "2030-03-01");
	assert.equal(page.dom.getByRole("option", { name: "Jun Park" }).attr("selected"), "");
	// Refused: back to the page, with what was typed and why.
	const refused = await person.post(`/api/tasks/${task}`, { title: "", notes: "Cake!", due: "2030-03-01", assignee: "jun" });
	assert.equal(refused.status, 303);
	const back = await refused.follow();
	assert.equal(back.dom.getByLabelText("Title").attr("aria-invalid"), "true");
	back.dom.getByText("Fill this in");
	assert.equal(back.dom.getByLabelText("Notes").text, "Cake!");
	back.dom.getByRole("alert");
	// Saved: the optional fields left empty are null, the box ticked is done, and back to the list.
	const saved = await person.post(`/api/tasks/${task}`, { title: "Plan the party", notes: "Cake!", due: "", assignee: "", done: "on" });
	assert.equal(saved.status, 303);
	assert.equal(saved.location, `/lists/${id}`);
	const [row] = await db.sql`select notes, due, assignee, done from tasks where id = ${Number(task)}`;
	assert.deepEqual(row, { notes: "Cake!", due: null, assignee: null, done: 1 });
	// With the runtime, the redirect comes back for it to follow.
	const runtime = await person.submit(`/api/tasks/${task}`, { title: "Plan the party", notes: "", due: "", assignee: "" });
	assert.equal(runtime.headers.get("x-rocx-redirect"), `/lists/${id}`);
});

test("who are you: a session, your name at the top, your tasks under Mine, and new tasks yours", { skip }, async () => {
	const person = app.client();
	await person.get("/me");
	const chosen = await person.post("/api/me", { person: "avery" });
	assert.equal(chosen.status, 303);
	// The cookie holds a random token; who it is stays on the server, as the session's user
	// (packages/auth keeps the token's SHA-256).
	const token = person.cookies.get("tasks_session");
	assert.match(token, /^[A-Za-z0-9_-]{43}$/);
	assert.deepEqual(await db.sql`select user_id from auth_sessions where id = ${hashOf(token)}`, [{ user_id: "avery" }]);
	const home = await chosen.follow();
	home.dom.getByRole("heading", { level: 1, name: "Hello, Avery" });
	home.dom.getByRole("link", { name: "Avery Stone Avery" });
	assert.deepEqual(await titles(person, "1", "?show=mine"), ["Write the launch announcement"]);
	const list = await person.get("/lists/2");
	assert.equal(list.dom.getByRole("option", { name: "Avery Stone" }).attr("selected"), "");
	// A cookie that names someone is nobody: only a session's token says who you are.
	const forger = app.client();
	forger.cookies.set("tasks_session", "avery");
	forger.cookies.set("acme-person", "avery");
	(await forger.get("/")).dom.getByRole("heading", { level: 1, name: "Your team's lists" });
	// Picking someone else ends the session you had: its token is nobody's now.
	await person.get("/me");
	await person.post("/api/me", { person: "jun" });
	assert.notEqual(person.cookies.get("tasks_session"), token);
	(await person.get("/")).dom.getByRole("heading", { level: 1, name: "Hello, Jun" });
	const stale = app.client();
	stale.cookies.set("tasks_session", token);
	(await stale.get("/")).dom.getByRole("heading", { level: 1, name: "Your team's lists" });
	// Someone not on the team is refused, and you stay who you were; "I'd rather not say" forgets you.
	await person.get("/me");
	const refused = await person.post("/api/me", { person: "zed" });
	assert.equal(person.flash.status, 400);
	(await refused.follow()).dom.getByText("Pick someone on the team.");
	(await person.get("/")).dom.getByRole("heading", { level: 1, name: "Hello, Jun" });
	const kept = person.cookies.get("tasks_session");
	await person.post("/api/me", { person: "" });
	assert.equal(person.cookies.get("tasks_session"), undefined);
	assert.deepEqual(await db.sql`select user_id from auth_sessions where id = ${hashOf(kept)}`, []);
});

test("the middleware logs every answer, and refuses a change from another site", { skip }, async () => {
	const stranger = app.client({ origin: "https://elsewhere.example" });
	const refused = await stranger.post("/api/tasks/toggle", { id: "1", done: "true" });
	assert.equal(refused.status, 403);
	await app.client().get("/lists/2");
	await until(() => app.logs().some((line) => line.msg === "answered" && line.path === "/lists/2" && line.status === 200));
	const line = app.logs().find((line) => line.msg === "answered" && line.path === "/lists/2");
	assert.equal(line.method, "GET");
	assert.equal(typeof line.ms, "number");
	assert.ok(app.logs().some((line) => line.msg === "answered" && line.path === "/api/tasks/toggle" && line.status === 403) === false, "same_origin refuses before identify runs");
});

test("seeding is idempotent: running the seed again changes nothing", { skip }, async () => {
	const before = await db.sql`select (select count(*) from people) as people, (select count(*) from lists) as lists, (select count(*) from tasks) as tasks`;
	// The seed is several statements: node:sqlite's exec runs them all (db.query prepares one).
	const { DatabaseSync } = await import("node:sqlite");
	const seeding = new DatabaseSync(db.path, { timeout: 10_000 });
	seeding.exec(readFileSync(join(repo, "examples", "tasks", "migrations", "0002_seed.sql"), "utf8"));
	seeding.close();
	const after = await db.sql`select (select count(*) from people) as people, (select count(*) from lists) as lists, (select count(*) from tasks) as tasks`;
	assert.deepEqual(after, before);
	assert.deepEqual(await db.sql`select name from rocx_migrations where name like '0%' order by name`, [{ name: "0001_tables.sql" }, { name: "0002_seed.sql" }]);
});

// ---- In a browser ----

const noBrowser = "no Chromium (set CHROME, or install Playwright's)";

/** A tab on the list `id`, hydrated strictly: a page that isn't what the browser's half renders throws. */
function openList(id, query = "") {
	return browser.open(`${app.url}/lists/${id}${query}`);
}

/**
 * Waits until nothing on the page is moving: rows glide to their places when the list changes
 * (`transition:move`), and a click aimed at a button that a row is gliding past lands on the row.
 */
function still(tab) {
	return until(async () => (await tab.page.eval("document.getAnimations().length")) === 0, { what: "the page to stop moving" });
}

test("in a browser: ticking a task shows at once, saves, and the counts follow", { skip }, async (t) => {
	if (!browser) return t.skip(noBrowser);
	const person = app.client();
	const id = await newList(person, "Browser chores");
	const task = await addTask(person, id, { title: "Feed the cat" });
	await addTask(person, id, { title: "Walk the dog" });
	const tab = await openList(id);
	await (await tab.getByRole("checkbox", { name: "Feed the cat" })).click();
	await tab.waitFor((dom) => dom.getByRole("checkbox", { name: "Feed the cat" }).attr("aria-checked") === "true");
	await tab.findByText("1 open");
	await until(async () => (await db.sql`select done from tasks where id = ${Number(task)}`)[0].done === 1, { what: "the task done in the database" });
	// Read again once it is in: the layout's count down the side too.
	await tab.findByRole("link", { name: "Browser chores 1 open" });
	assert.deepEqual(tab.errors, []);
	// It went with fetch: the page wasn't loaded again, only read.
	assert.ok((await tab.requested()).includes("/api/tasks/toggle"));
	await tab.close();
});

test("in a browser: adding, moving and deleting tasks without leaving the page", { skip }, async (t) => {
	if (!browser) return t.skip(noBrowser);
	const person = app.client();
	const id = await newList(person, "Browser errands");
	await addTask(person, id, { title: "Post the letter" });
	const tab = await openList(id);
	// An empty title is refused by the endpoint, and the issue shows under the field. It shows as
	// soon as the form is sent (the browser's own check, once every issue shows), while the button
	// says "Adding…", disabled, until the endpoint's refusal is in; Enter pressed before that would
	// send nothing (a form whose submit button is disabled isn't sent by Enter), so the next step
	// waits for the button to say "Add" again.
	await (await tab.getByRole("button", { name: "Add" })).click();
	await tab.findByText("Fill this in");
	await tab.findByRole("button", { name: "Add" });
	await (await tab.getByLabelText("New task")).fill("Return the books");
	// Sent with Enter from the title field: the task is added, and the form starts afresh where it
	// is (LiveForm's reset!), the field empty, no issue shown, and focus still in it for the next.
	await (await tab.getByLabelText("New task")).press("Enter");
	await tab.findByRole("link", { name: "Return the books" });
	await until(async () => (await (await tab.getByLabelText("New task")).value()) === "", { what: "the title field emptied" });
	await until(async () => !(await tab.dom()).queryByText("Fill this in"), { what: "the issue gone" });
	assert.equal((await tab.getByLabelText("New task")).attr("aria-invalid"), "false");
	assert.equal(await tab.page.eval("document.activeElement?.id ?? null"), "field-title", "the title field keeps focus");
	await until(async () => (await db.sql`select count(*) as n from tasks where list_id = ${Number(id)}`)[0].n === 2, { what: "the task in the database" });
	await still(tab);
	await (await tab.findByRole("button", { name: "Move up: Return the books" })).click();
	await until(async () => (await tab.dom()).getAllByRole("checkbox")[0]?.name === "Return the books", { what: "the task moved up on the page" });
	await until(async () => (await db.sql`select title from tasks where list_id = ${Number(id)} order by position`)[0]?.title === "Return the books", { what: "the task moved up in the database" });
	await still(tab);
	await (await tab.getByRole("button", { name: "Delete: Post the letter" })).click();
	await until(async () => !(await tab.dom()).queryByRole("link", { name: "Post the letter" }), { what: "the task gone from the page" });
	await until(async () => (await db.sql`select count(*) as n from tasks where list_id = ${Number(id)}`)[0].n === 1, { what: "the task gone from the database" });
	assert.deepEqual(tab.errors, []);
	assert.deepEqual(tab.console.filter((line) => line.type === "error"), []);
	await tab.close();
});

test("in a browser: a change the server refuses is undone, says why, and Dismiss reads the list again", { skip }, async (t) => {
	if (!browser) return t.skip(noBrowser);
	const person = app.client();
	const id = await newList(person, "Browser refusals");
	const task = await addTask(person, id, { title: "Someone else's task" });
	const tab = await openList(id);
	// Deleted in another tab, then ticked in this one: the server says there's no such task.
	assert.equal((await person.json("/api/tasks/delete", { id: task })).status, 200);
	await (await tab.getByRole("checkbox", { name: "Someone else's task" })).click();
	const alert = await tab.findByRole("alert");
	assert.match(alert.text, /that task isn't there any more/);
	assert.equal((await tab.getByRole("checkbox", { name: "Someone else's task" })).attr("aria-checked"), "false");
	await still(tab);
	await (await tab.getByRole("button", { name: "Dismiss" })).click();
	await until(async () => !(await tab.dom()).queryByRole("alert"), { what: "the alert gone" });
	await tab.findByText("Nothing on this list yet. Add the first task below.");
	assert.deepEqual(tab.errors, []);
	await tab.close();
});

test("in a browser: a task's page starts filled in with the task, checks it as it is typed, and saves", { skip }, async (t) => {
	if (!browser) return t.skip(noBrowser);
	const person = app.client();
	const id = await newList(person, "Browser edits");
	const task = await addTask(person, id, { title: "Wrap the gifts", due: "2030-12-20", assignee: "jun" });
	const tab = await browser.open(`${app.url}/tasks/${task}`);
	// Hydrated strictly over the server's page: the form the browser makes starts with the task too
	// (LiveForm.filled!).
	assert.equal(await (await tab.getByLabelText("Title")).value(), "Wrap the gifts");
	assert.equal(await (await tab.getByLabelText("Due")).value(), "2030-12-20");
	// Emptied and left: the same check the endpoint makes shows under it, before anything is sent.
	await (await tab.getByLabelText("Title")).fill("");
	await (await tab.getByLabelText("Notes")).focus();
	await tab.findByText("Fill this in");
	await (await tab.getByLabelText("Title")).fill("Wrap the presents");
	await until(async () => !(await tab.dom()).queryByText("Fill this in"), { what: "the issue gone as it is typed" });
	await (await tab.getByRole("button", { name: "Save" })).click();
	await until(async () => new URL(await tab.page.eval("location.href")).pathname === `/lists/${id}`, { what: "back on the list" });
	const [row] = await db.sql`select title, due, assignee from tasks where id = ${Number(task)}`;
	assert.deepEqual(row, { title: "Wrap the presents", due: "2030-12-20", assignee: "jun" });
	assert.deepEqual(tab.errors, []);
	assert.deepEqual(tab.console.filter((line) => line.type === "error"), []);
	await tab.close();
});

test("in a browser: leaving a task's page with changes not saved asks first (use_before_leave!): Cancel is stopped and the question shows, Keep editing stays, Leave without saving goes; a reload would be the browser's to ask", { skip }, async (t) => {
	if (!browser) return t.skip(noBrowser);
	const person = app.client();
	const id = await newList(person, "Browser drafts");
	const task = await addTask(person, id, { title: "Bake the bread" });
	const tab = await browser.open(`${app.url}/tasks/${task}`);
	/** Whether a load now would ask (the browser's beforeunload prompt). */
	const loadAsks = () => tab.page.eval("!window.dispatchEvent(new Event('beforeunload', { cancelable: true }))");
	const here = async () => new URL(await tab.page.eval("location.href")).pathname;
	assert.equal(await loadAsks(), false, "nothing typed: a load wouldn't ask");
	await (await tab.getByLabelText("Title")).fill("Bake the sourdough");
	await until(loadAsks, { what: "a load asking, once the title differs" });
	await (await tab.getByRole("link", { name: "Cancel" })).click();
	const question = await tab.findByRole("alertdialog");
	assert.match(question.text, /changes that aren't saved/);
	assert.equal(await here(), `/tasks/${task}`, "still on the task");
	await (await tab.getByRole("button", { name: "Keep editing" })).click();
	await until(async () => !(await tab.dom()).queryByRole("alertdialog"), { what: "the question gone" });
	assert.equal(await (await tab.getByLabelText("Title")).value(), "Bake the sourdough", "what was typed, still there");
	// Typed back as it was: nothing to ask about.
	await (await tab.getByLabelText("Title")).fill("Bake the bread");
	await until(async () => !(await loadAsks()), { what: "a load not asking again" });
	await (await tab.getByLabelText("Title")).fill("Bake rolls");
	await (await tab.getByRole("link", { name: "Cancel" })).click();
	await (await tab.findByRole("button", { name: "Leave without saving" })).click();
	await until(async () => (await here()) === `/lists/${id}`, { what: "on the list" });
	assert.equal(await loadAsks(), false, "the task's page gone, and its question with it");
	const [row] = await db.sql`select title from tasks where id = ${Number(task)}`;
	assert.equal(row.title, "Bake the bread", "nothing saved");
	assert.deepEqual(tab.errors, []);
	assert.deepEqual(tab.console.filter((line) => line.type === "error"), []);
	await tab.close();
});

test("in a browser: deleting from a task's page, the runtime sends the form (D-095), the task's page isn't read again, and the page goes on to the list, in place, asking nothing of a change typed", { skip }, async (t) => {
	if (!browser) return t.skip(noBrowser);
	const person = app.client();
	const id = await newList(person, "Browser deletions");
	const task = await addTask(person, id, { title: "Sweep the yard" });
	await addTask(person, id, { title: "Rake the leaves" });
	const tab = await browser.open(`${app.url}/tasks/${task}`);
	// The error page (a 404 for the task's page read again) never shows on the way.
	await tab.page.eval("window.mark = 'kept'; window.erred = false; new MutationObserver(() => { if (document.querySelector('section.error')) window.erred = true; }).observe(document.documentElement, { childList: true, subtree: true })");
	// A change typed and not saved: a task that is gone asks nothing of it.
	await (await tab.getByLabelText("Title")).fill("Sweep the porch");
	await (await tab.getByRole("button", { name: "Delete this task" })).click();
	await until(async () => new URL(await tab.page.eval("location.href")).pathname === `/lists/${id}`, { what: "on the list" });
	assert.equal(await tab.page.eval("window.mark"), "kept", "in place: no load");
	await tab.findByRole("link", { name: "Rake the leaves" });
	assert.equal((await tab.dom()).queryByRole("link", { name: "Sweep the yard" }), null, "the task gone from the list");
	assert.equal((await db.sql`select count(*) as n from tasks where id = ${Number(task)}`)[0].n, 0, "and from the database");
	assert.equal(await tab.page.eval("window.erred"), false, "the task's page wasn't read again: no 404 on the way");
	assert.equal((await tab.dom()).queryByRole("alertdialog"), null, "no question about the change typed");
	assert.deepEqual(tab.errors, []);
	assert.deepEqual(tab.console.filter((line) => line.type === "error" || line.type === "warning"), []);
	await tab.close();
});
