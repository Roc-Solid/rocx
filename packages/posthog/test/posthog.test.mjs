// packages/posthog against a fake PostHog: the example app (../example) built, started with its key
// and host pointed at an HTTP server here that keeps each batch it is sent, and asked for a 5xx, an
// error it deals with, a page's error and (with DATABASE_URL) a job that fails for good; each must
// arrive as an `$exception` event, grouped, capped, and sent again when PostHog didn't take it.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, launchBrowser, startServer, testDatabase, until } from "../../testing/index.mjs";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "example");

/** A fake PostHog: `POST /batch/` kept in `batches` (each body, parsed), answered `status`. */
async function fakePostHog() {
	const fake = { status: 200, batches: [], url: "", close: () => {} };
	const server = createServer((request, response) => {
		let body = "";
		request.on("data", (chunk) => (body += chunk));
		request.on("end", () => {
			if (request.method === "POST" && request.url === "/batch/") {
				const status = fake.status;
				if (status === 200) fake.batches.push(JSON.parse(body));
				response.writeHead(status, { "content-type": "application/json" }).end(status === 200 ? '{"status":"Ok"}' : "{}");
				return;
			}
			response.writeHead(404).end();
		});
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	fake.url = `http://127.0.0.1:${server.address().port}`;
	fake.close = () => new Promise((resolve) => server.close(resolve));
	return fake;
}

/** Every event the fake was sent so far. */
const events = (fake) => fake.batches.flatMap((batch) => batch.batch);

/** The events whose exception says `value`, once there are `count` (within 5 s). */
async function arrived(fake, value, count = 1) {
	await until(() => events(fake).filter((event) => event.properties.$exception_list[0].value === value).length >= count, { ms: 5000 });
	return events(fake).filter((event) => event.properties.$exception_list[0].value === value);
}

let built;
let fake;
let app;
let db = null;

before(async () => {
	built = await buildForTests(dir, { opt: process.env.ROCX_TEST_OPT ?? "dev" });
	fake = await fakePostHog();
	db = process.env.DATABASE_URL ? await testDatabase() : null;
	app = await startServer(built.server, { database: db?.url, statics: [...built.statics, join(dir, "static")], env: { POSTHOG_KEY: "phc_test", POSTHOG_HOST: fake.url, POSTHOG_RELEASE: "abc123" } });
});

after(async () => {
	await app?.stop();
	await db?.drop();
	await fake?.close();
});

test("the start says where errors go", async () => {
	await until(() => app.logs().some((line) => line.msg?.includes("posthog.reporting") || JSON.stringify(line).includes("errors go to")), { ms: 5000 });
	assert.ok(JSON.stringify(app.logs()).includes(`errors go to ${fake.url}, every 200 ms`), JSON.stringify(app.logs()));
});

test("a 5xx answer arrives as an unhandled ServerError, with its route, who asked and the release", async () => {
	const answer = await app.client({ headers: { "x-user": "ada" } }).get("/boom");
	assert.equal(answer.status, 500);
	const [event] = await arrived(fake, "answered 500: the ledger is locked by job 42");
	assert.equal(event.event, "$exception");
	assert.match(event.uuid, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
	assert.match(event.timestamp, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
	const { properties } = event;
	assert.equal(properties.distinct_id, "ada");
	assert.equal(properties.$process_person_profile, undefined);
	assert.deepEqual(properties.$exception_list[0].mechanism, { handled: false, synthetic: false });
	assert.equal(properties.$exception_list[0].type, "ServerError");
	assert.deepEqual(properties.$exception_list[0].stacktrace.frames[0], { platform: "custom", lang: "roc", function: "GET /boom", filename: "/boom", in_app: true });
	assert.equal(properties.$exception_fingerprint, "server | ServerError | /boom | answered <n>: the ledger is locked by job <n>");
	assert.equal(properties.source, "server");
	assert.equal(properties.status, 500);
	assert.equal(properties.release, "abc123");
	const batch = fake.batches.find((one) => one.batch.includes(event));
	assert.equal(batch.api_key, "phc_test");
	assert.equal(batch.historical_migration, false);
});

test("an error the app dealt with arrives handled, with its fields, from nobody known", async () => {
	const answer = await app.client().get("/refund");
	assert.equal(answer.status, 200);
	const [event] = await arrived(fake, "the payment provider refused a refund");
	const { properties } = event;
	assert.equal(properties.$exception_list[0].mechanism.handled, true);
	assert.equal(properties.$exception_list[0].type, "Error");
	assert.deepEqual(properties.fields, { order: 42, why: "expired card" });
	assert.equal(properties.place, "/refund");
	assert.equal(properties.method, "GET");
	assert.equal(properties.distinct_id, event.uuid);
	assert.equal(properties.$process_person_profile, false);
	assert.equal(properties.$exception_fingerprint, "server | Error | the payment provider refused a refund");
});

test("a page's script, and the errors it sends", async () => {
	const script = await app.client().get("/rocx-errors.js");
	assert.equal(script.status, 200);
	assert.match(script.headers.get("content-type"), /javascript/);
	assert.match(script.text, /sendBeacon/);

	const page = app.client();
	const sent = await page.json("/rocx-errors", { kind: "TypeError", message: "x.map is not a function", stack: "TypeError: x.map is not a function\n    at render (app.js:3:9)", page: "/posts/12" });
	assert.equal(sent.status, 204);
	const [event] = await arrived(fake, "x.map is not a function");
	const { properties } = event;
	assert.equal(properties.source, "browser");
	assert.equal(properties.$exception_list[0].type, "TypeError");
	assert.equal(properties.$exception_list[0].stacktrace.frames[0].lang, "javascript");
	assert.equal(properties.place, "/posts/12");
	assert.match(properties.stack, /at render/);
	assert.equal(properties.$exception_fingerprint, "browser | TypeError | x.map is not a function");

	const junk = await page.request("/rocx-errors", { method: "POST", headers: { "content-type": "application/json" }, body: "not json" });
	assert.equal(junk.status, 400);
	const huge = await page.json("/rocx-errors", { kind: "Error", message: "x".repeat(20_000), stack: "", page: "/" });
	assert.equal(huge.status, 413);
});

test("in a browser, the script sends an error and a rejection nothing caught", async (t) => {
	const browser = await launchBrowser();
	if (!browser) return t.skip("needs Chromium");
	try {
		await browser.open(`${app.url}/`, { strict: false });
		const [error] = await arrived(fake, "Cannot read properties of null (reading 'total')");
		assert.equal(error.properties.source, "browser");
		assert.equal(error.properties.$exception_list[0].type, "TypeError");
		assert.equal(error.properties.place, "/");
		assert.match(error.properties.stack, /broken\.js/);
		const [rejected] = await arrived(fake, "price 12.50 is out of range");
		assert.equal(rejected.properties.$exception_list[0].type, "RangeError");
		assert.equal(rejected.properties.$exception_fingerprint, "browser | RangeError | price <n>.<n> is out of range");
	} finally {
		await browser.close();
	}
});

test("one issue is sent 20 times a minute at most", async () => {
	for (let i = 0; i < 25; i++) assert.equal((await app.client().get("/boom")).status, 500);
	await new Promise((resolve) => setTimeout(resolve, 1000));
	const boom = events(fake).filter((event) => event.properties.$exception_fingerprint.startsWith("server | ServerError | /boom"));
	assert.equal(boom.length, 20);
});

test("what PostHog didn't take is sent again", async () => {
	fake.status = 503;
	await app.client().get("/refund");
	await until(() => app.logs().some((line) => line.msg === "posthog: PostHog didn't take the errors, sent again next time"), { ms: 5000 });
	const before = events(fake).filter((event) => event.properties.$exception_list[0].value === "the payment provider refused a refund").length;
	fake.status = 200;
	const after = await arrived(fake, "the payment provider refused a refund", before + 1);
	assert.equal(after.length, before + 1);
});

test("a job that failed for good arrives as a JobFailed", { skip: !process.env.DATABASE_URL && "needs DATABASE_URL" }, async () => {
	await db.enqueue("charge", { order: 7 }, { attempts: 1 });
	await db.settleJobs();
	const [event] = await arrived(fake, "the card for order 7 was declined");
	const { properties } = event;
	assert.equal(properties.$exception_list[0].type, "JobFailed");
	assert.equal(properties.$exception_list[0].mechanism.handled, false);
	assert.equal(properties.source, "job");
	assert.equal(properties.place, "charge");
	assert.equal(properties.fields.attempts, 1);
	assert.equal(typeof properties.fields.job, "number");
	assert.equal(properties.$exception_fingerprint, "job | charge | the card for order <n> was declined");
});

test("without a key, nothing is kept or sent", async () => {
	const quiet = await startServer(built.server, { env: { POSTHOG_KEY: "", POSTHOG_HOST: fake.url } });
	try {
		await until(() => JSON.stringify(quiet.logs()).includes("off: no POSTHOG_KEY"), { ms: 5000 });
		const count = events(fake).length;
		assert.equal((await quiet.client().get("/boom")).status, 500);
		await new Promise((resolve) => setTimeout(resolve, 600));
		assert.equal(events(fake).length, count);
	} finally {
		await quiet.stop();
	}
});
