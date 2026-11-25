// packages/push as a plugin (D-051), on both databases (D-045): its example app, `Push.plugin({})` in
// its plugins, and one route more, /test/store, that runs PushStore's statements one at a time.
// Built for SQLite (always: a file of the test's own) and for Postgres (when DATABASE_URL is set: a
// database of the test's own), each in build/<database>/app, and asked over HTTP: the key, a
// subscription saved and saved again (one row, its new keys), ones refused, each statement,
// unsubscribing, and sending (D-080): a broadcast queued as a job a subscription and delivered to a
// push service of the test's own, which checks each request's VAPID token (RFC 8292) and decrypts
// its message as the browser would (RFC 8291), and answers as a push service might (a subscription
// gone, a refusal). The server runs with `--dev`, which lets a subscription's endpoint be on this
// machine, and with that push service as its HTTPS proxy, which refuses every connection: nothing
// reaches a real push service. A pair of VAPID keys that isn't one stops the server. And in Chromium,
// on SQLite, behind a guard that refuses every script (`.js`) the app would answer: the plugin's
// script and service worker come all the same, the worker registers at the root with the whole site
// as its scope, and the button subscribes (the browser's push service stood in for, as headless
// Chromium has none).
//
//   node --test 'packages/push/example/test/*.test.mjs'
//   ROCX_TEST_OPT=speed builds the apps optimized (`--opt=speed`).
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createDecipheriv, createECDH, createPublicKey, hkdfSync, randomBytes, verify } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
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

/**
 * A push service of the test's own, at `origin`, which plays the browsers subscribed at it too.
 * `subscribe(name)` makes a browser's subscription as a browser does (a P-256 key pair and a 16-byte
 * auth secret, by Node's crypto), its endpoint `<origin>/push/<name>`. A message posted there is
 * checked as a push service checks it (`vapid`: the `Authorization` header's token and key, the
 * token's ES256 signature verified against `vapidPublic`) and decrypted as the browser does
 * (`decrypt`), then kept (`received`), each with its headers; its answer is 201, or what `answers`
 * says for that name. A message that fails a check is answered 400 and kept with its `problem`.
 * It is the server's HTTPS proxy too: every CONNECT is refused, and where to is kept (`connects`).
 */
async function pushService(vapidPublic) {
	const browsers = new Map();
	const received = [];
	const connects = [];
	const answers = new Map();
	const server = createServer(async (request, response) => {
		const chunks = [];
		for await (const chunk of request) chunks.push(chunk);
		const name = new URL(request.url, origin).pathname.replace(/^\/push\//, "");
		const browser = browsers.get(name);
		if (request.method !== "POST" || !browser) {
			response.writeHead(404).end();
			return;
		}
		try {
			received.push({ name, headers: request.headers, token: vapid(request.headers.authorization, vapidPublic), ...decrypt(Buffer.concat(chunks), browser) });
		} catch (error) {
			received.push({ name, problem: error.message });
			response.writeHead(400).end(error.message);
			return;
		}
		const [status, headers] = answers.get(name) ?? [201, { location: `${origin}/message/${received.length}` }];
		response.writeHead(status, headers).end();
	});
	server.on("connect", (request, socket) => {
		connects.push(request.url);
		socket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	const origin = `http://127.0.0.1:${server.address().port}`;
	return {
		origin,
		received,
		connects,
		answers,
		/** A browser subscribed here, as the page posts its subscription. */
		subscribe(name) {
			const ecdh = createECDH("prime256v1");
			ecdh.generateKeys();
			const auth = randomBytes(16);
			browsers.set(name, { ecdh, auth });
			return { endpoint: `${origin}/push/${name}`, keys: { p256dh: ecdh.getPublicKey().toString("base64url"), auth: auth.toString("base64url") } };
		},
		close: () => new Promise((resolve) => server.close(resolve)),
	};
}

/**
 * A request's VAPID credentials checked (RFC 8292): `Authorization: vapid t=<JWT>, k=<key>`, the key
 * the server's public key, the JWT's ES256 signature (64 bytes, r and s) verified with it. The JWT's
 * header and claims.
 */
function vapid(authorization, vapidPublic) {
	const said = /^vapid t=([\w-]+)\.([\w-]+)\.([\w-]+), k=([\w-]+)$/.exec(authorization ?? "");
	if (!said) throw new Error(`Authorization isn't "vapid t=…, k=…": ${authorization}`);
	const [, header, claims, signature, k] = said;
	if (k !== vapidPublic) throw new Error(`k isn't the server's public key: ${k}`);
	const point = Buffer.from(k, "base64url");
	const key = createPublicKey({ key: { kty: "EC", crv: "P-256", x: point.subarray(1, 33).toString("base64url"), y: point.subarray(33).toString("base64url") }, format: "jwk" });
	const signed = Buffer.from(signature, "base64url");
	if (signed.length !== 64) throw new Error(`the signature is ${signed.length} bytes, not 64`);
	if (!verify("sha256", Buffer.from(`${header}.${claims}`), { key, dsaEncoding: "ieee-p1363" }, signed)) throw new Error("the token's signature doesn't verify");
	return { header: JSON.parse(Buffer.from(header, "base64url")), claims: JSON.parse(Buffer.from(claims, "base64url")) };
}

/**
 * A message's body decrypted as the browser does (RFC 8291 on RFC 8188's aes128gcm): the header (a
 * salt, the record size, the key id: the server's public key for this message), the secret the
 * browser's key shares with that one, the input keys from it and the auth secret, the content key
 * and nonce from those and the salt, one record opened, its padding and delimiter taken off. The
 * header's parts and the data, as text.
 */
function decrypt(body, { ecdh, auth }) {
	const salt = body.subarray(0, 16);
	const recordSize = body.readUInt32BE(16);
	const asPublic = body.subarray(21, 21 + body[20]);
	const sealed = body.subarray(21 + body[20]);
	if (sealed.length > recordSize) throw new Error(`the record is ${sealed.length} bytes, more than the header's ${recordSize}`);
	const ecdhSecret = ecdh.computeSecret(asPublic);
	const info = Buffer.concat([Buffer.from("WebPush: info\0"), ecdh.getPublicKey(), asPublic]);
	const ikm = Buffer.from(hkdfSync("sha256", ecdhSecret, auth, info, 32));
	const key = Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: aes128gcm\0"), 16));
	const nonce = Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from("Content-Encoding: nonce\0"), 12));
	const decipher = createDecipheriv("aes-128-gcm", key, nonce);
	decipher.setAuthTag(sealed.subarray(-16));
	const record = Buffer.concat([decipher.update(sealed.subarray(0, -16)), decipher.final()]);
	let end = record.length - 1;
	while (end >= 0 && record[end] === 0) end--;
	if (record[end] !== 2) throw new Error("the record doesn't end with the last record's delimiter (2)");
	return { salt: salt.toString("base64url"), recordSize, asPublic: asPublic.toString("base64url"), data: record.subarray(0, end).toString() };
}

const databases = ["sqlite", ...(process.env.DATABASE_URL ? ["postgres"] : [])];

for (const database of databases) {
	describe(`on ${database === "sqlite" ? "SQLite" : "Postgres"}`, () => {
		const keys = p256();
		let built;
		let db;
		let push;
		let server;
		let client;

		before(async () => {
			built = await buildForTests(app(database), { client: false, opt: process.env.ROCX_TEST_OPT ?? "dev" });
			db = database === "sqlite" ? testSqlite() : await testDatabase();
			push = await pushService(keys.public);
			server = await startServer(built.server, {
				database: db.url,
				dev: true,
				env: {
					VAPID_PUBLIC_KEY: keys.public,
					VAPID_PRIVATE_KEY: keys.private,
					VAPID_SUBJECT: "mailto:push@example.com",
					// Every https: request through the push service above, which refuses it; http: ones
					// (its endpoints) direct.
					HTTPS_PROXY: push.origin,
					https_proxy: push.origin,
					HTTP_PROXY: "",
					http_proxy: "",
					NO_PROXY: "",
					no_proxy: "",
				},
			});
			client = server.client();
		});

		after(async () => {
			await server?.stop();
			await push?.close();
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

		test("the key, and a subscription saved, saved again with new keys (one row), and one at another service, or with a key off the curve, refused", async () => {
			assert.equal(await client.read("/push/key"), keys.public);
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
			const point = Buffer.from(again.keys.p256dh, "base64url");
			point[64] ^= 1;
			const offCurve = await client.json("/push/subscribe", { ...subscription("x"), keys: { ...again.keys, p256dh: point.toString("base64url") } });
			assert.equal(offCurve.status, 400);
			assert.equal(offCurve.text, "keys.p256dh isn't a point on P-256");
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

		test("unsubscribing forgets the browser's subscription; another's endpoint isn't forgotten", async () => {
			assert.equal((await client.json("/push/subscribe", subscription("linus"))).status, 200);
			const [ada] = await rows();
			assert.equal((await client.json("/push/unsubscribe", { endpoint: "https://fcm.googleapis.com/fcm/send/nobody" })).status, 200);
			assert.equal((await rows()).length, 2);
			assert.equal((await client.json("/push/unsubscribe", { endpoint: ada.endpoint })).status, 200);
			assert.deepEqual((await rows()).map((row) => row.endpoint), ["https://fcm.googleapis.com/fcm/send/linus"]);
			// None left at a real push service: the tests below send to every subscription.
			assert.equal((await client.json("/push/unsubscribe", { endpoint: "https://fcm.googleapis.com/fcm/send/linus" })).status, 200);
			assert.deepEqual(await rows(), []);
		});

		/** The deliveries' jobs, oldest first. */
		const jobs = () => db.sql`select state, attempts, last_error from rocx_jobs where kind = ${"push.deliver"} order by id`;

		test("a broadcast is delivered: a job a subscription, each message encrypted for its browser alone (RFC 8291) and signed for the push service (VAPID, RFC 8292), which answers 201", async () => {
			const browsers = { grace: push.subscribe("grace"), linus: push.subscribe("linus") };
			for (const each of Object.values(browsers)) assert.equal((await client.json("/push/subscribe", each)).status, 200);
			const sent = Math.floor(Date.now() / 1000);
			const announced = await client.json("/push/announce", {});
			assert.equal(announced.status, 200, announced.text);
			assert.equal(announced.json(), "Queued: 2");
			await until(async () => (await jobs()).filter((job) => job.state === "done").length === 2, { ms: 20_000, what: "both deliveries done" });
			assert.deepEqual(push.received.filter((message) => message.problem), [], "every request passed the push service's checks");
			assert.deepEqual(push.received.map((message) => message.name).sort(), ["grace", "linus"]);
			for (const message of push.received) {
				// What the browser decrypted: the notification the service worker shows.
				assert.deepEqual(JSON.parse(message.data), { title: "Hello", body: "A notification from the example", url: "/" });
				// The token: ES256, for the push service's origin, valid for 12 hours from about now.
				assert.deepEqual(message.token.header, { typ: "JWT", alg: "ES256" });
				assert.equal(message.token.claims.aud, push.origin);
				assert.equal(message.token.claims.sub, "mailto:push@example.com");
				assert.ok(Math.abs(message.token.claims.exp - (sent + 12 * 60 * 60)) < 60, `exp is 12 hours on: ${message.token.claims.exp}`);
				// The content coding's header: one record of at most 4096, the server's key for this message.
				assert.equal(message.recordSize, 4096);
				assert.equal(Buffer.from(message.asPublic, "base64url").length, 65);
				assert.equal(message.headers["content-encoding"], "aes128gcm");
				assert.equal(message.headers["content-type"], "application/octet-stream");
				assert.equal(message.headers.urgency, "normal");
				assert.ok(Number(message.headers.ttl) > 86_000 && Number(message.headers.ttl) <= 86_400, `TTL: a day, less the wait: ${message.headers.ttl}`);
			}
			const [one, two] = push.received;
			assert.notEqual(one.asPublic, two.asPublic, "a new ECDH key pair for each message");
			assert.notEqual(one.salt, two.salt, "and a new salt");
			for (const job of await jobs()) assert.deepEqual({ state: job.state, attempts: Number(job.attempts), last_error: job.last_error }, { state: "done", attempts: 1, last_error: null });
			for (const row of await rows()) {
				assert.equal(row.last_error, null);
				assert.notEqual(row.last_sent_at, null, "delivered: when");
			}
			assert.deepEqual(push.connects, [], "nothing went to a push service elsewhere");
		});

		test("the push service's answers: a subscription gone (410) is deleted, a refusal (403) noted on its row, not tried again", async () => {
			const gone = push.subscribe("gone");
			const refusing = push.subscribe("refusing");
			push.answers.set("gone", [410, {}]);
			push.answers.set("refusing", [403, {}]);
			for (const each of [gone, refusing]) assert.equal((await client.json("/push/subscribe", each)).status, 200);
			push.received.length = 0;
			const announced = await client.json("/push/announce", {});
			assert.equal(announced.json(), "Queued: 4");
			await until(async () => (await jobs()).filter((job) => job.state === "done").length === 6, { ms: 20_000, what: "the four deliveries done" });
			assert.deepEqual(push.received.filter((message) => message.problem), []);
			assert.deepEqual(push.received.map((message) => message.name).sort(), ["gone", "grace", "linus", "refusing"], "each sent once");
			const left = await rows();
			assert.deepEqual(left.map((row) => row.endpoint.split("/").pop()), ["grace", "linus", "refusing"], "the gone one deleted");
			assert.match(left[2].last_error, /^the push service answered 403 \(check VAPID_PUBLIC_KEY/);
			assert.deepEqual(push.connects, []);
		});

		test("VAPID keys that aren't a pair stop the server as it starts, saying why", async () => {
			const other = p256();
			await assert.rejects(
				startServer(built.server, { database: db.url, env: { VAPID_PUBLIC_KEY: keys.public, VAPID_PRIVATE_KEY: other.private, VAPID_SUBJECT: "mailto:push@example.com" } }),
				/VAPID_PRIVATE_KEY and VAPID_PUBLIC_KEY aren't a pair/,
			);
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
	const keys = p256();
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
			env: { VAPID_PUBLIC_KEY: keys.public, VAPID_PRIVATE_KEY: keys.private, VAPID_SUBJECT: "mailto:push@example.com" },
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
