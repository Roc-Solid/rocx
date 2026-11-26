// packages/guard's example app over HTTP: the package's middleware, imported (`guard.Guard`), its
// state in the server's memory (`Kv`, D-043). A limit counts each client by its address and
// refuses the sixth try in a minute (a plain form back to its page, with a flash); a flag's
// override, set by an admin, turns maintenance on and off, and outlives a restart in the app's
// database (the package's plugin, D-057); a feature's route is there only for those who have it.
// Run it with `node --test 'packages/guard/example/test/*.test.mjs'`.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer, testSqlite } from "../../../testing/index.mjs";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..");
let built;
let app;
/** The app's database: a SQLite file of the tests' own. */
const db = testSqlite({ prefix: "rocx-guard-" });
before(async () => {
	built = await buildForTests(dir, { client: false });
	app = await startServer(built.server, { database: db.url });
});
after(() => app?.stop());

test("a limit counts each client by its address: the sixth try in a minute is refused, with when to try again", async () => {
	const statuses = [];
	for (let i = 0; i < 6; i++) statuses.push((await app.client().json("/login", {})).status);
	assert.deepEqual(statuses, [200, 200, 200, 200, 200, 429]);
	const refused = await app.client().json("/login", {});
	assert.equal(refused.status, 429);
	assert.ok(Number(refused.headers.get("retry-after")) > 0);
	assert.equal(refused.headers.get("ratelimit-policy"), "5;w=60");
	// A browser's form posted without the runtime goes back to its page, as any refusal does: a 303
	// and a flash of the 429 and when to try again, not a page of text.
	const browser = app.client();
	await browser.get("/");
	const plain = await browser.post("/login");
	assert.equal(plain.status, 303);
	assert.equal(plain.headers.get("location"), "/");
	assert.equal(plain.headers.get("retry-after"), null);
	assert.equal(browser.flash.url, "/login");
	assert.equal(browser.flash.status, 429);
	assert.match(browser.flash.body, /^Too many requests: try again in \d+ s\.$/);
});

test("a client whose address can't be told (an X-Forwarded-For that isn't one, with no proxy in front) isn't let off: every such client shares one count", async () => {
	const statuses = [];
	for (let i = 0; i < 6; i++) statuses.push((await app.client({ headers: { "x-forwarded-for": `not-an-address-${i}` } }).json("/login", {})).status);
	assert.deepEqual(statuses, [200, 200, 200, 200, 200, 429]);
});

test("a flag's override: an admin turns maintenance on (every page 503, but /admin) and resets it", async () => {
	const admin = app.client({ headers: { cookie: "user=ada" } });
	const visitor = app.client();
	assert.equal((await visitor.request("/beta")).status, 404, "the new checkout isn't the visitor's");
	assert.equal((await admin.request("/beta")).status, 200, "ada has it: the code's rule names her");
	assert.equal((await visitor.json("/admin/flags", { name: "maintenance", state: "on" })).status, 403, "for admins only");
	assert.equal((await admin.json("/admin/flags", { name: "maintenance", state: "on" })).status, 200);
	const down = await visitor.request("/flags", { headers: { accept: "application/json" } });
	assert.equal(down.status, 503);
	assert.ok(Number(down.headers.get("retry-after")) > 0);
	assert.equal((await admin.json("/admin/flags", { name: "maintenance", state: "reset" })).status, 200, "/admin is spared");
	assert.equal((await visitor.request("/flags", { headers: { accept: "application/json" } })).status, 200, "the code's rule again");
	// The new checkout on for everyone, then the code's rule again.
	assert.equal((await admin.json("/admin/flags", { name: "new_checkout", state: "on" })).status, 200);
	assert.equal((await visitor.request("/beta")).status, 200);
	assert.equal((await admin.json("/admin/flags", { name: "new_checkout", state: "reset" })).status, 200);
	assert.equal((await visitor.request("/beta")).status, 404);
});

test("a flag's override outlives a restart (D-057): kept in the app's database by the package's plugin, read back at start; a reset one stays reset", async () => {
	const admin = () => app.client({ headers: { cookie: "user=ada" } });
	const visitor = () => app.client();
	assert.equal((await admin().json("/admin/flags", { name: "new_checkout", state: "on" })).status, 200);
	assert.equal((await admin().json("/admin/flags", { name: "maintenance", state: "on" })).status, 200);
	assert.equal((await admin().json("/admin/flags", { name: "maintenance", state: "reset" })).status, 200);
	assert.equal((await visitor().request("/beta")).status, 200);
	assert.deepEqual(
		(await db.query("select name, rule <> '' as kept from guard_flags order by name")).map((row) => ({ ...row })),
		[
			{ name: "maintenance", kept: 0 },
			{ name: "new_checkout", kept: 1 },
		],
		"a row a flag: a reset one's rule is empty",
	);
	await app.stop();
	app = await startServer(built.server, { database: db.url });
	assert.equal((await visitor().request("/beta")).status, 200, "the override on the new checkout, as it was");
	assert.equal((await visitor().request("/flags", { headers: { accept: "application/json" } })).status, 200, "maintenance reset, as it was");
	assert.equal((await admin().json("/admin/flags", { name: "new_checkout", state: "reset" })).status, 200);
	await app.stop();
	app = await startServer(built.server, { database: db.url });
	assert.equal((await visitor().request("/beta")).status, 404, "reset: the code's rule, after a restart too");
});
