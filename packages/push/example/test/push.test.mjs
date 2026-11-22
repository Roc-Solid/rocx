// packages/push's server half on both databases (D-045): its example app, with the glue copied in
// as the README says (server/Push.roc, server/PushStore.roc, and the migration for the app's
// database), and one route more, /test/store, that runs PushStore's statements one at a time.
// Built for SQLite (always: a file of the test's own) and for Postgres (when DATABASE_URL is set: a
// database of the test's own), each in build/<database>/app, and asked over HTTP: the key, a
// subscription saved and saved again (one row, its new keys), one refused, each statement, a
// broadcast queued as a job a subscription whose attempt reads its row and then fails for want of
// the host's P-256 (PROPOSALS.md), and unsubscribing.
//
//   node --test 'packages/push/example/test/*.test.mjs'
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createECDH, randomBytes } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer, testDatabase, testSqlite, until } from "../../../testing/index.mjs";

const example = join(dirname(fileURLToPath(import.meta.url)), "..");
const push = join(example, "..");

/** The route the tests add: each of PushStore's statements, as the body's `op` says. */
const storeRoute = `import pf.Server
import pf.Endpoint
import ../../../PushStore

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
 * The example as an app copies push in, for `database` ("sqlite" or "postgres"), in
 * build/<database>/app: its routes and main.roc (the packages' paths from there, and the program's
 * `database`), the glue, the migration for that database, and the store's route. Its folder.
 */
function app(database) {
	const dir = join(example, "build", database, "app");
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(join(dir, "migrations"), { recursive: true });
	cpSync(join(example, "routes"), join(dir, "routes"), { recursive: true });
	const main = readFileSync(join(example, "main.roc"), "utf8")
		.replaceAll('"../', '"../../../../')
		.replace("\tplugins: [", `\tdatabase: ${database === "sqlite" ? 'Sqlite("data/push.db")' : "Postgres"},\n\tplugins: [`);
	assert.match(main, /database: /, "the program's database written");
	writeFileSync(join(dir, "main.roc"), main);
	for (const module of ["Push.roc", "PushStore.roc"]) cpSync(join(push, "server", module), join(dir, module));
	const migration = database === "sqlite" ? "0001_push_subscriptions_sqlite.sql" : "0001_push_subscriptions.sql";
	cpSync(join(push, "migrations", migration), join(dir, "migrations", "0001_push_subscriptions.sql"));
	mkdirSync(join(dir, "routes", "test", "store"), { recursive: true });
	writeFileSync(join(dir, "routes", "test", "store", "+server.roc"), storeRoute);
	return dir;
}

/** A P-256 public key, uncompressed (65 bytes), in base64url: the VAPID key's, or a browser's. */
function p256() {
	const ecdh = createECDH("prime256v1");
	ecdh.generateKeys();
	return { public: ecdh.getPublicKey().toString("base64url"), private: ecdh.getPrivateKey().toString("base64url") };
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
			const built = await buildForTests(app(database), { client: false });
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
