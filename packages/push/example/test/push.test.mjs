// packages/push as a plugin (D-051), on both databases (D-045): its example app, `Push.plugin({})` in
// its plugins, and one route more, /test/store, that runs PushStore's statements one at a time.
// Built for SQLite (always: a file of the test's own) and for Postgres (when DATABASE_URL is set: a
// database of the test's own), each in build/<database>/app, and asked over HTTP: the key, a
// subscription saved and saved again (one row, its new keys), one refused, each statement, a
// broadcast queued as a job a subscription whose attempt reads its row and then fails for want of
// the host's P-256 (PROPOSALS.md), and unsubscribing. And in Chromium, on SQLite, behind a guard
// that refuses every script (`.js`) the app would answer: the plugin's script and service worker
// come all the same, the worker registers at the root with the whole site as its scope, and the
// button subscribes (the browser's push service stood in for, as headless Chromium has none).
//
//   node --test 'packages/push/example/test/*.test.mjs'
//   ROCX_TEST_OPT=speed builds the apps optimized (`--opt=speed`).
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createECDH, randomBytes } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, launchBrowser, startServer, testDatabase, testSqlite, until } from "../../../testing/index.mjs";

const example = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The route the tests add: each of PushStore's statements, as the body's `op` says. */
const storeRoute = `import pf.Server
import pf.Endpoint
import push.PushStore

## POST /test/store: one of PushStore's statements, as the body says (\`op\`), and what it read or
## changed, as text. Written by packages/push's tests into the app they build; the example has none.
post! : { request : Server.Request, params : {}, context : c, body : { op : Str, id : I64, owner : Str, why : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match body.op {
		"find" =>
			match PushStore.find!(body.id) {
				Ok(Found(row)) => Ok("\${row.id.to_str()} \${row.owner} \${row.endpoint}")
				Ok(Missing) => Ok("missing")
				Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(500, why))
			}
		"of_owner" => ids(PushStore.of_owner!(body.owner))
		"everyone" => ids(PushStore.everyone!({}))
		"delivered" => changed(PushStore.delivered!(body.id))
		"refused" => changed(PushStore.refused!(body.id, body.why))
		"remove_id" => changed(PushStore.remove_id!(body.id))
		_ => Err(BadRequest("no such statement: \${body.op}"))
	}

ids : Try(List(I64), [DbErr(Str), BadRow(Str)]) -> Try(Str, Endpoint.Refusal)
ids = |read|
	match read {
		Ok(found) => Ok(Str.join_with(found.map(|id| id.to_str()), " "))
		Err(DbErr(why)) | Err(BadRow(why)) => Err(Status(500, why))
	}

changed : Try(U64, [DbErr(Str)]) -> Try(Str, Endpoint.Refusal)
changed = |done|
	match done {
		Ok(count) => Ok(count.to_str())
		Err(DbErr(why)) => Err(Status(500, why))
	}
`;

/**
 * The example for `database` ("sqlite" or "postgres"), in build/<database>/app: its routes and
 * main.roc (the packages' paths from there, and the program's `database`), and the store's route.
 * With `guarded`, its middleware is a guard that refuses every request for a script (a path ending
 * in `.js`) the app would answer. Its folder.
 */
function app(database, { guarded = false } = {}) {
	const dir = join(example, "build", `${database}${guarded ? "-guarded" : ""}`, "app");
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(dir, { recursive: true });
	cpSync(join(example, "routes"), join(dir, "routes"), { recursive: true });
	let main = readFileSync(join(example, "main.roc"), "utf8")
		.replaceAll('"../', '"../../../../')
		.replace("\tplugins: [", `\tdatabase: ${database === "sqlite" ? 'Sqlite("data/push.db")' : "Postgres"},\n\tplugins: [`);
	assert.match(main, /database: /, "the program's database written");
	if (guarded) {
		main = main.replace("middleware: Middleware.same_origin({}),", 'middleware: Middleware.make(|request, context, next!| if (request.path.ends_with(".js")) Server.response(403, [], "the guard refuses scripts") else next!(request, context)),');
		main = main.replace("import pf.Middleware\n", "import pf.Middleware\nimport pf.Server\n");
		assert.match(main, /the guard refuses scripts/, "the guard written");
	}
	writeFileSync(join(dir, "main.roc"), main);
	mkdirSync(join(dir, "routes", "test", "store"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "store", "+server.roc"), storeRoute);
	return dir;
}

/** A P-256 public key, uncompressed (65 bytes), in base64url: the VAPID key's, or a browser's. */
function p256() {
	const ecdh = createECDH("prime256v1");
	ecdh.generateKeys();
	// The private key as its 32 bytes: Node drops a leading zero (one time in 256), which VAPID's
	// keys may not, and the push plugin's start refuses.
	return { public: ecdh.getPublicKey().toString("base64url"), private: Buffer.from(ecdh.getPrivateKey("hex").padStart(64, "0"), "hex").toString("base64url") };
}

/** A browser's subscription at Chrome's push service, as the page posts it. */
function subscription(name) {
	return { endpoint: `https://fcm.googleapis.com/fcm/send/${name}`, keys: { p256dh: p256().public, auth: randomBytes(16).toString("base64url") } };
}

const databases = ["sqlite", ...(process.env.DATABASE_URL ? ["postgres"] : [])];

for (const database of databases) {
	describe(`on ${database === "sqlite" ? "SQLite" : "Postgres"}`, () => {
		const vapid = p256();
		let db;
		let server;
		let client;

		before(async () => {
			const built = await buildForTests(app(database), { client: false, opt: process.env.ROCX_TEST_OPT ?? "dev" });
			db = database === "sqlite" ? testSqlite() : await testDatabase();
			server = await startServer(built.server, {
				database: db.url,
				env: { VAPID_PUBLIC_KEY: vapid.public, VAPID_PRIVATE_KEY: vapid.private, VAPID_SUBJECT: "mailto:push@example.com" },
			});
			client = server.client();
		});

		after(async () => {
			await server?.stop();
			await db?.drop();
		});

		/** Runs one of PushStore's statements on the server: what it said. */
		async function store(op, { id = 0, owner = "", why = "" } = {}) {
			const answer = await client.json("/test/store", { op, id, owner, why });
			assert.equal(answer.status, 200, answer.text);
			return answer.json();
		}

		/** The subscriptions' rows, oldest first. */
		const rows = () => db.sql`select id, endpoint, p256dh, auth, owner, last_sent_at, last_error from push_subscriptions order by id`;

		test("the key, and a subscription saved, saved again with new keys (one row), and one at another service refused", async () => {
			assert.equal(await client.read("/push/key"), vapid.public);
			const first = subscription("ada");
			assert.equal((await client.json("/push/subscribe", first)).status, 200);
			const again = subscription("ada");
			assert.equal((await client.json("/push/subscribe", again)).status, 200);
			const saved = await rows();
			assert.equal(saved.length, 1);
			assert.deepEqual(
				{ endpoint: saved[0].endpoint, p256dh: saved[0].p256dh, auth: saved[0].auth, owner: saved[0].owner },
				{ endpoint: first.endpoint, p256dh: again.keys.p256dh, auth: again.keys.auth, owner: "" },
			);
			const refused = await client.json("/push/subscribe", { ...subscription("x"), endpoint: "https://push.example.com/x" });
			assert.equal(refused.status, 400);
			assert.match(refused.text, /isn't at a browser's push service/);
			assert.equal((await rows()).length, 1);
		});

		test("each of PushStore's statements: find, of_owner, everyone, refused, delivered, remove_id", async () => {
			assert.equal((await client.json("/push/subscribe", subscription("grace"))).status, 200);
			const [ada, grace] = await rows();
			const id = Number(grace.id);
			assert.equal(await store("find", { id }), `${id}  ${grace.endpoint}`);
			assert.equal(await store("find", { id: 999_999 }), "missing");
			assert.equal(await store("of_owner", { owner: "" }), `${ada.id} ${grace.id}`);
			assert.equal(await store("of_owner", { owner: "someone" }), "");
			assert.equal(await store("everyone"), `${ada.id} ${grace.id}`);

			assert.equal(await store("refused", { id, why: "413: the message is too large" }), "1");
			assert.equal((await rows())[1].last_error, "413: the message is too large");
			// Delivered: when, and no error.
			const sent = Date.now();
			assert.equal(await store("delivered", { id }), "1");
			const [, delivered] = await rows();
			assert.equal(delivered.last_error, null);
			assert.notEqual(delivered.last_sent_at, null);
			// On SQLite a moment is milliseconds, given by the server (Postgres's is its own now()).
			if (database === "sqlite") assert.ok(Math.abs(delivered.last_sent_at - sent) < 60_000, `last_sent_at is now: ${delivered.last_sent_at}`);
			// Subscribing again clears a refusal.
			await store("refused", { id, why: "400" });
			assert.equal((await client.json("/push/subscribe", { ...subscription("other"), endpoint: grace.endpoint })).status, 200);
			assert.equal((await rows())[1].last_error, null);

			assert.equal(await store("remove_id", { id }), "1");
			assert.equal(await store("remove_id", { id }), "0");
			assert.equal(await store("everyone"), `${ada.id}`);
		});

		test("a broadcast queues a job a subscription; its attempt reads the row, then fails for want of the host's P-256", async () => {
			assert.equal((await client.json("/push/subscribe", subscription("linus"))).status, 200);
			const announced = await client.json("/push/announce", {});
			assert.equal(announced.status, 200, announced.text);
			assert.equal(announced.json(), "Queued: 2");
			const jobs = () => db.sql`select state, attempts, last_error from rocx_jobs where kind = ${"push.deliver"} order by id`;
			await until(
				async () => {
					const queued = await jobs();
					return queued.length === 2 && queued.every((job) => job.attempts >= 1 && job.last_error);
				},
				{ what: "each delivery tried once" },
			);
			for (const job of await jobs()) assert.match(job.last_error, /the server's host has no P-256 or AES-128-GCM yet/);
		});

		test("unsubscribing forgets the browser's subscription; another's endpoint isn't forgotten", async () => {
			const [ada] = await rows();
			assert.equal((await client.json("/push/unsubscribe", { endpoint: "https://fcm.googleapis.com/fcm/send/nobody" })).status, 200);
			assert.equal((await rows()).length, 2);
			assert.equal((await client.json("/push/unsubscribe", { endpoint: ada.endpoint })).status, 200);
			assert.deepEqual((await rows()).map((row) => row.endpoint), ["https://fcm.googleapis.com/fcm/send/linus"]);
		});
	});
}

/**
 * What the page runs before its own scripts: the browser's push service stood in for (headless
 * Chromium has none: `pushManager.subscribe` would fail), and permission granted, as a click on the
 * browser's prompt would. The service worker is the real one, registered for real.
 */
const standIn = (made) => `
Notification.requestPermission = async () => "granted";
Object.defineProperty(Notification, "permission", { get: () => "granted", configurable: true });
let held = null;
PushManager.prototype.getSubscription = async function () { return held; };
PushManager.prototype.subscribe = async function (options) {
	held = { endpoint: ${JSON.stringify(made.endpoint)}, options, toJSON: () => (${JSON.stringify(made)}), unsubscribe: async () => ((held = null), true) };
	return held;
};`;

describe("in Chromium, behind a guard that refuses every script the app would answer", () => {
	const vapid = p256();
	const made = subscription("chromium");
	let browser;
	let db;
	let server;

	before(async () => {
		browser = await launchBrowser();
		if (!browser) return;
		const built = await buildForTests(app("sqlite", { guarded: true }), { opt: process.env.ROCX_TEST_OPT ?? "dev" });
		db = testSqlite();
		server = await startServer(built.server, {
			database: db,
			statics: built.statics,
			env: { VAPID_PUBLIC_KEY: vapid.public, VAPID_PRIVATE_KEY: vapid.private, VAPID_SUBJECT: "mailto:push@example.com" },
		});
	});

	after(async () => {
		await browser?.close();
		await server?.stop();
		await db?.drop();
	});

	test("the plugin's script and its service worker come past the guard; the worker registers at the site's root, its scope the whole site; the button subscribes, and the server keeps the subscription", async (t) => {
		if (!browser) return t.skip("no Chromium (set CHROME)");
		const refused = await fetch(`${server.url}/elsewhere.js`);
		assert.equal(refused.status, 403, "the guard refuses a script the app would answer");
		assert.equal(await refused.text(), "the guard refuses scripts");
		for (const path of ["/push-sw.js", "/rocx/plugins/push/push.js"]) {
			const got = await fetch(`${server.url}${path}`);
			assert.equal(got.status, 200, `${path}: the plugin's, served before the guard`);
			assert.equal(got.headers.get("content-type"), "text/javascript");
		}
		const tab = await browser.open(`${server.url}/`, { script: standIn(made) });
		assert.equal(await tab.page.eval(`document.querySelector('script[src="/rocx/plugins/push/push.js"]')?.nextElementSibling?.getAttribute("src")`), "/rocx/start.js", "the page loads the plugin's script, just before start.js");
		const button = await tab.findByRole("button", { name: "Turn notifications on" });
		await tab.page.wait("document.querySelector('[data-push-state]').value === 'off'", 5000);
		await button.click();
		await tab.page.wait("document.querySelector('[data-push-state]').value === 'on'", 10_000);
		assert.ok(await tab.findByRole("button", { name: "Turn notifications off" }));
		const registration = await tab.page.eval("navigator.serviceWorker.getRegistration('/').then((r) => r && { scope: new URL(r.scope).pathname, script: new URL(r.active.scriptURL).pathname + new URL(r.active.scriptURL).search })");
		assert.deepEqual(registration, { scope: "/", script: "/push-sw.js?api=%2Fpush" }, "the plugin's root file, the whole site its scope");
		assert.deepEqual(
			(await db.sql`select endpoint, p256dh, auth, owner from push_subscriptions`).map((row) => ({ ...row })),
			[{ endpoint: made.endpoint, p256dh: made.keys.p256dh, auth: made.keys.auth, owner: "" }],
			"posted to the plugin's endpoint, through the app's middleware, and kept",
		);
		await (await tab.findByRole("button", { name: "Turn notifications off" })).click();
		await tab.page.wait("document.querySelector('[data-push-state]').value === 'off'", 10_000);
		assert.deepEqual(await db.sql`select endpoint from push_subscriptions`, [], "unsubscribed: forgotten");
		assert.deepEqual(tab.errors, []);
	});
});
