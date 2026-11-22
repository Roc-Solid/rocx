// Acme Tasks, tested as people use it: over HTTP (pages, plain forms, the runtime's posts, the
// endpoints as JSON, the database), then in a real browser. The app is built once (rocx build, the
// browser's wasm, the server), and started against a database of the tests' own, which its
// migrations make and seed. Each test that changes things makes a list of its own first, so the
// tests don't lean on each other.
//
//   DATABASE_URL=postgres://… node --test 'examples/tasks/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildForTests, startServer, testDatabase, launchBrowser, until, repo } from "../../../packages/testing/index.mjs";

const database = process.env.DATABASE_URL;
const skip = database ? false : "needs DATABASE_URL (a Postgres the tests may make databases in: `just db`)";

let db;
let app;
/** Chromium's headless shell, or null when there is none: the browser's tests skip then. */
let browser = null;

before(async () => {
	if (skip) return;
	const built = await buildForTests(join(repo, "examples", "tasks"));
	db = await testDatabase(database);
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
	const made = await person.post("/", { name });
	assert.equal(made.status, 303);
	const id = /^\/lists\/(\d+)$/.exec(made.location)?.[1];
	assert.ok(id, `a new list's page, not ${made.location}`);
	return id;
}

/** A task added to the list `id` with its form, without JavaScript: its id, from the database. */
async function addTask(person, id, fields) {
	await person.get(`/lists/${id}`);
	const added = await person.post(`/lists/${id}`, { due: "", assignee: "", ...fields });
	assert.equal(added.status, 303);
	const [row] = await db.sql`select id::text from tasks where list_id = ${Number(id)} and title = ${fields.title}`;
	return row.id;
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
	const sheet = await app.client().read("/lists/1");
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

test("a list or a task that isn't there is a 404", { skip }, async () => {
	const person = app.client();
	assert.equal((await person.get("/lists/999")).status, 404);
	assert.equal((await person.get("/lists/nope")).status, 404);
	const task = await person.get("/tasks/999");
	assert.equal(task.status, 404);
	task.dom.getByRole("heading", { name: "There's no such task" });
	assert.equal((await person.get("/no/such/page")).status, 404);
	assert.equal((await person.read("/lists/999").catch((error) => error.status)), 404);
});

test("adding a task without JavaScript: a plain form, a 303 back, and it is on the list", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "Groceries");
	await person.get(`/lists/${id}`);
	const added = await person.post(`/lists/${id}`, { title: "  Buy   milk ", due: "2030-01-15", assignee: "mila" });
	assert.equal(added.status, 303);
	assert.equal(new URL(added.location, app.url).pathname, `/lists/${id}`);
	const page = await added.follow();
	page.dom.getByRole("checkbox", { name: "Buy milk" });
	page.dom.getByRole("img", { name: "Mila Novak" });
	page.dom.getByText("Jan 15, 2030");
	const [row] = await db.sql`select title, due::text, assignee, done, position from tasks where list_id = ${Number(id)}`;
	assert.deepEqual(row, { title: "Buy milk", due: "2030-01-15", assignee: "mila", done: false, position: 0 });
	// Left empty, the optional fields are null in Postgres.
	await addTask(person, id, { title: "Bread" });
	const [bread] = await db.sql`select due, assignee, position from tasks where title = ${"Bread"}`;
	assert.deepEqual(bread, { due: null, assignee: null, position: 1 });
});

test("a task the form refuses comes back with its issues in place, and what was typed", { skip }, async () => {
	const person = app.client();
	const id = await newList(person, "Refusals");
	await person.get(`/lists/${id}`);
	const refused = await person.post(`/lists/${id}`, { title: "   ", due: "2026-02-30", assignee: "" });
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
	const nobody = await person.submit(`/lists/${id}`, { title: "Hire someone", due: "", assignee: "zed" });
	assert.equal(nobody.status, 422);
	assert.match(nobody.text, /Choose someone on the team/);
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
	assert.deepEqual(await db.sql`select done from tasks where id = ${Number(task)}`, [{ done: false }]);
	// A toggle says where it ends up, so sending it twice is sending it once.
	await person.submit("/api/tasks/toggle", { id: task, done: "false" });
	assert.deepEqual(await db.sql`select done from tasks where id = ${Number(task)}`, [{ done: false }]);
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
	assert.equal((await person.json("/api/tasks/move", { id: a, to: "2" })).status, 200);
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
	const refused = await person.post(`/tasks/${task}`, { title: "", notes: "Cake!", due: "2030-03-01", assignee: "jun" });
	assert.equal(refused.status, 303);
	const back = await refused.follow();
	assert.equal(back.dom.getByLabelText("Title").attr("aria-invalid"), "true");
	back.dom.getByText("Fill this in");
	assert.equal(back.dom.getByLabelText("Notes").text, "Cake!");
	back.dom.getByRole("alert");
	// Saved: the optional fields left empty are null, the box ticked is done, and back to the list.
	const saved = await person.post(`/tasks/${task}`, { title: "Plan the party", notes: "Cake!", due: "", assignee: "", done: "on" });
	assert.equal(saved.status, 303);
	assert.equal(saved.location, `/lists/${id}`);
	const [row] = await db.sql`select notes, due, assignee, done from tasks where id = ${Number(task)}`;
	assert.deepEqual(row, { notes: "Cake!", due: null, assignee: null, done: true });
	// With the runtime, the redirect comes back for it to follow.
	const runtime = await person.submit(`/tasks/${task}`, { title: "Plan the party", notes: "", due: "", assignee: "" });
	assert.equal(runtime.headers.get("x-rocx-redirect"), `/lists/${id}`);
});

test("who are you: a cookie, your name at the top, your tasks under Mine, and new tasks yours", { skip }, async () => {
	const person = app.client();
	await person.get("/me");
	const chosen = await person.post("/me", { person: "avery" });
	assert.equal(chosen.status, 303);
	assert.equal(person.cookies.get("acme-person"), "avery");
	const home = await chosen.follow();
	home.dom.getByRole("heading", { level: 1, name: "Hello, Avery" });
	home.dom.getByRole("link", { name: "Avery Stone Avery" });
	assert.deepEqual(await titles(person, "1", "?show=mine"), ["Write the launch announcement"]);
	const list = await person.get("/lists/2");
	assert.equal(list.dom.getByRole("option", { name: "Avery Stone" }).attr("selected"), "");
	// Someone not on the team is refused; "I'd rather not say" forgets you.
	await person.get("/me");
	const refused = await person.post("/me", { person: "zed" });
	assert.equal(person.flash.status, 400);
	(await refused.follow()).dom.getByText("Pick someone on the team.");
	await person.post("/me", { person: "" });
	assert.equal(person.cookies.get("acme-person"), undefined);
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
	const before = await db.sql`select (select count(*) from people)::int as people, (select count(*) from lists)::int as lists, (select count(*) from tasks)::int as tasks`;
	await db.query(readFileSync(join(repo, "examples", "tasks", "migrations", "0002_seed.sql"), "utf8"));
	const after = await db.sql`select (select count(*) from people)::int as people, (select count(*) from lists)::int as lists, (select count(*) from tasks)::int as tasks`;
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
	await until(async () => (await db.sql`select done from tasks where id = ${Number(task)}`)[0].done === true, { what: "the task done in the database" });
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
	// An empty title is refused by the endpoint, and the issue shows under the field.
	await (await tab.getByRole("button", { name: "Add" })).click();
	await tab.findByText("Fill this in");
	await (await tab.getByLabelText("New task")).fill("Return the books");
	// The issue shows as the form is sent; the button is "Adding…" until the refusal is in.
	await (await tab.findByRole("button", { name: "Add" })).click();
	await tab.findByRole("link", { name: "Return the books" });
	// The form starts afresh for the next one.
	await until(async () => (await (await tab.getByLabelText("New task")).value()) === "", { what: "the title field emptied" });
	await until(async () => (await db.sql`select count(*)::int as n from tasks where list_id = ${Number(id)}`)[0].n === 2, { what: "the task in the database" });
	await still(tab);
	await (await tab.findByRole("button", { name: "Move up: Return the books" })).click();
	await until(async () => (await tab.dom()).getAllByRole("checkbox")[0]?.name === "Return the books", { what: "the task moved up on the page" });
	await until(async () => (await db.sql`select title from tasks where list_id = ${Number(id)} order by position`)[0]?.title === "Return the books", { what: "the task moved up in the database" });
	await still(tab);
	await (await tab.getByRole("button", { name: "Delete: Post the letter" })).click();
	await until(async () => !(await tab.dom()).queryByRole("link", { name: "Post the letter" }), { what: "the task gone from the page" });
	await until(async () => (await db.sql`select count(*)::int as n from tasks where list_id = ${Number(id)}`)[0].n === 1, { what: "the task gone from the database" });
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
