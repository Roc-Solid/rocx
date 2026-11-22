// The helpers against a real app (fixture.mjs), built as a deploy builds it (buildForTests) and
// served by its server (startServer): a page found in by role and name, a form's post and its
// flash, an endpoint the page reads, JSON, events, the dev mailbox; with DATABASE_URL, a database of the
// test's own and jobs run to their end; with Chromium, a page hydrated strictly, clicked, typed in,
// and a component's story. Needs the toolchain (`just setup`, and the platforms' hosts built, as
// `just test` builds them).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildForTests, repo, serverBuild } from "../build.mjs";
import { launchBrowser } from "../browser.mjs";
import { testDatabase } from "../postgres.mjs";
import { links, startServer, storyPath } from "../server.mjs";
import { writeFixture } from "./fixture.mjs";

const { nativeTarget, roc } = await serverBuild();
const skip = (() => {
	try {
		roc();
	} catch {
		return "no roc (run `just setup`, or set ROC)";
	}
	if (!existsSync(join(repo, "server", "platform", "targets", nativeTarget(), "libhost.a"))) return "the server's host isn't built (`just test` builds it)";
	if (!existsSync(join(repo, "web", "platform", "targets", "wasm32", "host.wasm"))) return "the browser's host isn't built (`just test` builds it)";
	return false;
})();
const skipDb = skip || (!process.env.DATABASE_URL && "no DATABASE_URL (`just db` starts a Postgres)");

let dir;
let app;
let db;
let browser;

before(async () => {
	if (skip) return;
	dir = writeFixture(mkdtempSync(join(tmpdir(), "rocx-testing-")));
	const built = await buildForTests(dir, { dev: true });
	if (!skipDb) db = await testDatabase();
	app = await startServer(built.server, { statics: built.statics, database: db?.url, flags: ["--mail-from", "Notes <notes@example.com>"] });
	browser = await launchBrowser();
});

after(async () => {
	await browser?.close();
	await app?.stop();
	await db?.drop();
	if (dir) rmSync(dir, { recursive: true, force: true });
});

test("a page, found in by role, name, label and test id; the error page", { skip }, async () => {
	const person = app.client();
	const page = await person.get("/");
	assert.equal(page.status, 200);
	const { getByRole, getByLabelText, getByTestId } = page.dom;
	assert.equal(getByRole("heading", { level: 1, name: "Notes" }).tag, "h1");
	assert.ok(getByRole("region", { name: "Notes" }), "the section, named by its heading");
	assert.equal(getByTestId("count").text, "3 notes", "the endpoint's answer, read as the page rendered");
	assert.equal(getByRole("status", { name: "Count" }).text, "1");
	assert.equal(getByLabelText("New note").attr("name"), "body");
	assert.deepEqual(page.dom.getAllByRole("button").map((button) => button.name), ["Add one", "Add"]);
	const missing = await person.get("/nowhere");
	assert.equal(missing.status, 404);
	assert.equal(missing.dom.getByRole("alert").text, "404 nothing at /nowhere");
});

test("a form posted without the runtime goes back to its page with a flash; the runtime's gets its answer", { skip }, async () => {
	const person = app.client();
	await person.get("/");
	const posted = await person.post("/notes", { body: "  milk " });
	assert.equal(posted.status, 303);
	assert.equal(posted.location, "/", "back to the page it came from");
	assert.deepEqual(person.flash, { url: "/notes", input: "body=++milk+", status: 200, body: '"added milk"' }, "what was typed, as it was sent");
	assert.equal((await posted.follow()).status, 200);
	assert.equal(person.flash, null, "the page it landed on let it go");
	await person.post("/notes", { body: "" });
	assert.deepEqual([person.flash.status, person.flash.body], [400, "a note has words"]);
	const sent = await person.submit("/notes", { body: "eggs" });
	assert.deepEqual([sent.status, sent.json()], [200, "added eggs"]);
	const refused = await person.submit("/notes", { body: "" });
	assert.deepEqual([refused.status, refused.text], [400, "a note has words"]);
});

test("an endpoint the page reads, an endpoint's JSON, and a stream of events", { skip }, async () => {
	const person = app.client();
	assert.equal(await person.read("/notes"), 3);
	await assert.rejects(person.read("/nothing"), { name: "ReadError", status: 404 });
	const echoed = await person.json("/api/echo", { word: "héllo" });
	assert.deepEqual([echoed.status, echoed.json()], [200, { said: "héllo", length: 6 }]);
	const ticks = await person.events("/api/ticks");
	assert.deepEqual((await ticks.take(4)).map(({ event, data }) => [event, data]), [
		["message", '{"tick":1}'],
		["message", '{"tick":2}'],
		["message", '{"tick":3}'],
		["end", ""],
	]);
});

test("the dev mailbox: what was sent, waited for, and its links", { skip }, async () => {
	const before = (await app.mail()).length;
	assert.equal((await app.client().json("/api/mail", { to: "ada@example.com" })).status, 200);
	const mail = await app.waitForMail({ to: "ada@example.com", subject: "Hello" }, { after: before });
	assert.equal(mail.from, "Notes <notes@example.com>");
	assert.deepEqual(links(mail), ["https://notes.example/hello"]);
	assert.ok(app.logs().some((line) => line.msg === "rocx mail (kept, not sent: no --smtp-url): to ada@example.com: Hello"), "and the server's log said so");
});

test("jobs: queued by an endpoint, or as a cron would, run to their end, with the email they sent", { skip: skipDb }, async () => {
	const person = app.client();
	assert.equal((await person.json("/api/welcome", { to: "ada@example.com" })).status, 200);
	const ran = await db.settleJobs();
	assert.deepEqual(ran.map(({ kind, state, input }) => [kind, state, input]), [["welcome", "done", '{"to":"ada@example.com"}']]);
	const welcome = await app.waitForMail({ to: "ada@example.com", subject: "Welcome" });
	assert.deepEqual(links(welcome), ["https://notes.example/notes"], "its HTML's link");

	const id = await db.enqueue("welcome", { to: "bob@example.com" });
	assert.deepEqual((await db.settleJobs()).map((job) => [job.id, job.state]), [[id, "done"]]);

	// One that fails is tried again later (5 s: the fixture's Job.plugin says `retry_ms`), which a settle doesn't wait for;
	// with `later`, it is tried again now, until its attempts are spent.
	const failing = await db.enqueue("welcome", { to: "nobody" }, { attempts: 3 });
	const first = await db.settleJobs();
	assert.deepEqual(first.map((job) => [job.id, job.state, job.attempts]), [[failing, "queued", 1]]);
	assert.match(first[0].last_error, /^to nobody: /);
	const spent = await db.settleJobs({ later: true });
	assert.deepEqual(spent.map((job) => [job.id, job.state, job.attempts]), [[failing, "failed", 3]]);
	assert.deepEqual((await db.jobs({ kind: "welcome" })).map((job) => job.state), ["done", "done", "failed"]);
});

test("in Chromium: the page hydrates strictly, a click and typing change it, and a story is a page", { skip }, async (t) => {
	if (!browser) return t.skip("no Chromium (set CHROME)");
	const tab = await browser.open(`${app.url}/`);
	try {
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		assert.ok((await tab.requested()).includes("/rocx/app.wasm"));
		await (await tab.getByRole("button", { name: "Add one" })).click();
		const count = await tab.findByText("2");
		assert.deepEqual([count.tag, count.name], ["output", "Count"]);
		const field = await tab.getByLabelText("New note");
		await field.fill("first");
		await field.fill("second");
		assert.equal(await field.value(), "second");
		assert.equal((await tab.findByText("3 notes")).tag, "p");
		await assert.rejects(tab.findByRole("button", { name: "Delete" }, { ms: 100 }), /nothing is a button named "Delete"; the buttons here: "Add one", "Add"/);
	} finally {
		await tab.close();
	}
	const story = await browser.open(`${app.url}${storyPath("Counter", "At ten")}`);
	try {
		assert.equal((await story.getByRole("status", { name: "Count" })).text, "10");
		await (await story.getByRole("button", { name: "Add one" })).click();
		await story.findByText("11");
		assert.deepEqual(story.errors, []);
	} finally {
		await story.close();
	}
});
