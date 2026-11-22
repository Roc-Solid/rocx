// The server platform (server/platform, server/host): a small app on it (server/test/app), built
// natively and run, asked over HTTP. A crash is a 500 and the server goes on, leaving nothing
// allocated; a body is the bytes as they came, and an answer may be bytes; a forwarded answer is
// fetched from a server this file runs and sent on as it comes, ranges and all; a page of
// components is rendered whole, a document with the answers its endpoint reads got; a stream is a loop,
// sent as it runs and stopped when its client goes; Postgres reads rows into records, in
// transactions that roll back on an error or a crash; jobs run, retry and fail for good, and are
// queued only if their transaction commits; a kind says how many times its jobs are tried and how
// long each may take; a key is one pending job's, by which it is cancelled or moved; jobs are
// listed and acted on, and the jobs page shows them behind the app's guard; cron queues its jobs;
// email is kept in the dev mailbox (in memory: Kv), or sent over SMTP (to
// a server this file runs); live rooms count who is in them; actors answer one message at a time,
// take tells and timers, log what they do not take, and keep their state across a restart (and an
// idle spell); `Http` asks servers this file runs (redirects, a timeout,
// a body too large, TLS that fails); `Env` reads the environment from a request and a job; AES-GCM
// seals as Node's does, and packages/crypto's SHA-256, HMAC, HKDF and Base64 agree with Node's;
// packages/s3 keeps objects in S3, whole and in parts, serves them streamed, and signs URLs Node's
// fetch uses;
// cookies are set as their options say; a stop lets the request being answered finish.
//
// ROCX_TEST_OPT=speed builds the app optimized (`--opt=speed`) instead.
//
// Needs the toolchain (`just setup`: Roc, and Rust for the host). What needs Postgres runs when
// DATABASE_URL is set (`just db` starts one: postgres://rocx:rocx@127.0.0.1:55432/rocx); the tests
// empty the app's tables and the platform's job queue. What needs S3 runs when STORAGE_URL is set
// (a bucket the tests may write to: rustfs or MinIO in Docker, say, with a bucket made,
// `s3://KEY:SECRET@127.0.0.1:9000/BUCKET?style=path&tls=no`); its objects are under a run's own
// prefix.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createCipheriv, createDecipheriv, createHash, createHmac, hkdfSync, randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer as createHttpServer } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp, buildHost, hasRust, hostUnitTests, roc, root } from "../build.mjs";
import { testDatabase } from "../../packages/testing/postgres.mjs";


let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)");
const database = process.env.DATABASE_URL;
const skipDb = skip || (!database && "no DATABASE_URL (`just db` starts a Postgres)");
const skipInternet = skip || (!process.env.ROCX_TEST_INTERNET && "needs the internet (set ROCX_TEST_INTERNET=1)");
const storage = process.env.STORAGE_URL;
const skipStorage = skip || (!storage && "no STORAGE_URL (an S3 bucket the tests may write to)");
/** What every server this file starts finds in its environment (`Env.var!`). */
const SETTING = "from the environment ✓";

let dir;
let app;
let server;
/** What Roc holds once the server has started: its background loops' own state (the schedules
 * the cron ticker keeps, say). Everything else a call makes is let go of when it ends. */
let baseline = 0;
/** The SMTP server the app's email goes to (this file runs it): every server started with a
 * database shares one job queue, so each sends a job's email to the same place. */
let smtp;
/** Where the email plugin sends: the SMTP server above, from the tests (its environment variables). */
const mailEnv = () => ({ SMTP_URL: `smtp://127.0.0.1:${smtp.port}`, MAIL_FROM: "Rocx Tests <tests@rocx.example>" });
/** A different run's names each time: jobs, notes and actors from runs before don't count. */
const run = `t${Date.now().toString(36)}`;

/** Starts the app (or another executable) with `flags` (and `--debug`, unless `debug` is false),
 * and `environment` besides this process's (an empty variable counts as unset); resolves when it
 * listens. */
async function start(flags = [], executable = app, environment = {}, { debug = true } = {}) {
	// `ROCX_LOG` unset (empty) unless given: stderr is a pipe, so the log is JSON.
	// FIXTURE_KEY: the fixture plugin needs it set (`needs: [Env("FIXTURE_KEY")]`).
	const env = { ...process.env, ROCX_LOG: "", ROCX_TEST_SETTING: SETTING, FIXTURE_KEY: "set", ...environment };
	const child = spawn(executable, ["--port", "0", ...(debug ? ["--debug"] : []), "--context-file", join(dir, "context.txt"), ...flags], { stdio: ["ignore", "ignore", "pipe"], env });
	let logged = "";
	const url = await new Promise((resolve, reject) => {
		child.stderr.on("data", (chunk) => {
			logged += chunk;
			const match = /rocx server: (http:\/\/\S+) /.exec(logged);
			if (match) resolve(match[1]);
		});
		child.on("exit", (code) => reject(new Error(`the server exited (${code}):\n${logged}`)));
	});
	return {
		url,
		child,
		logged: () => logged,
		get: (path, options) => fetch(`${url}${path}`, options),
		text: async (path, options) => (await fetch(`${url}${path}`, options)).text(),
		stop: () => new Promise((resolve) => (child.exitCode !== null ? resolve(child.exitCode) : (child.once("exit", resolve), child.kill("SIGTERM")))),
	};
}

// The app's migrations are in it (`program.migrations`, its .sql files embedded).
// A failed job waits 20 ms for its second attempt: the app's jobs plugin says so (`retry_ms`).
const dbFlags = () => (database ? ["--database-url", database] : []);

before(async () => {
	if (skip) return;
	dir = mkdtempSync(join(tmpdir(), "rocx-server-"));
	app = join(dir, "app");
	buildHost();
	buildApp(join(root, "server", "test", "app", "main.roc"), app, { opt: process.env.ROCX_TEST_OPT ?? "dev" });
	writeFileSync(join(dir, "context.txt"), "facts=yes");
	smtp = await smtpServer();
	// A short beat, so the channel tests see a stream's re-checks soon (`--live-beat-ms`).
	server = await start([...dbFlags(), "--live-beat-ms", "300"], app, mailEnv());
	if (database) assert.equal(await server.text("/reset", { method: "POST" }), "ready");
	// The loops settle (a worker's first look at the queue), then what they hold is the baseline.
	const allocations = async () => Number(await server.text("/__rocx/allocations"));
	for (let previous = -1; ; ) {
		await new Promise((resolve) => setTimeout(resolve, 200));
		baseline = await allocations();
		if (baseline === previous) break;
		previous = baseline;
	}
});

after(async () => {
	await server?.stop();
	await smtp?.close();
	if (dir) rmSync(dir, { recursive: true, force: true });
});

const get = (path, options) => server.get(path, options);
const text = (path, options) => server.text(path, options);
const post = (path, body) => text(path, { method: "POST", body });
const live = async () => Number(await text("/__rocx/allocations"));
/** What Roc holds once the background loops have settled (a worker's look at the queue allocates
 * for a moment): the same count twice, 200 ms apart. */
const steady = async () => {
	for (let previous = -1; ; ) {
		const now = await live();
		if (now === previous) return now;
		previous = now;
		await new Promise((resolve) => setTimeout(resolve, 200));
	}
};
const until = async (check, ms = 5000) => {
	const started = performance.now();
	for (;;) {
		const value = await check();
		if (value) return value;
		if (performance.now() - started > ms) return value;
		await new Promise((resolve) => setTimeout(resolve, 20));
	}
};

/** The events on a server's log so far, each line parsed: with `ROCX_LOG` unset and stderr a pipe,
 * the log is JSON, an object a line (a line still arriving isn't one yet). */
function events(of = server) {
	const lines = of.logged().split("\n");
	return lines.slice(0, -1).map((line) => JSON.parse(line));
}

/** Whether `event` has these fields: a value as it is, or text a RegExp matches. */
const has = (event, fields) => Object.entries(fields).every(([key, value]) => (value instanceof RegExp ? typeof event[key] === "string" && value.test(event[key]) : event[key] === value));

/** Waits for an event on the server's log with these fields (`has`). */
async function logsEvent(fields, of = server) {
	await until(() => events(of).some((event) => has(event, fields)));
	assert.ok(
		events(of).some((event) => has(event, fields)),
		`an event with ${JSON.stringify(fields, (_, value) => (value instanceof RegExp ? String(value) : value))}:\n${of.logged()}`,
	);
}

/** Waits for the server's log to say `pattern` (it comes down a pipe of its own, and may arrive a
 * moment after the answer that followed it). */
async function logs(pattern, of = server) {
	await until(() => pattern.test(of.logged()));
	assert.match(of.logged(), pattern);
}

/** A stream's events as they come: `next()` resolves to the next `data:` (null once it ends). */
async function listen(path, signal) {
	const response = await get(path, { headers: { accept: "text/event-stream" }, signal });
	const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
	let buffered = "";
	return {
		response,
		async next() {
			for (;;) {
				const end = buffered.indexOf("\n\n");
				if (end >= 0) {
					const event = buffered.slice(0, end);
					buffered = buffered.slice(end + 2);
					if (event.startsWith("event: end")) return null;
					return event.replace(/^data: /, "");
				}
				const read = await reader.read();
				if (read.done) return null;
				buffered += read.value;
			}
		},
	};
}

// ---- Requests, crashes, streams ----

test("Roc answers: the request's method, path, query, body and the server's context", { skip }, async () => {
	const home = await get("/");
	assert.equal(home.status, 200);
	assert.equal(home.headers.get("content-type"), "text/plain; charset=utf-8");
	assert.match(home.headers.get("server-timing"), /natively/);
	assert.equal(await home.text(), "Hello from Roc, natively.");
	assert.equal(await text("/echo?a=1&b=2"), "GET /echo?a=1&b=2 ");
	assert.equal(await post("/echo", "zażółć ✓"), "POST /echo zażółć ✓");
	assert.equal(await text("/context"), "facts=yes");
	assert.equal((await get("/nowhere")).status, 404);
	assert.ok(Number(await text("/now")) > 1_700_000_000_000, "Time.now_millis!");
	assert.equal(await text("/log"), "logged");
	await logs(/a line from Roc/);
});

// ---- The log ----

/** A pretty line: the local time, the level (as wide as each other), the message and its fields. */
const PRETTY = /^\d\d:\d\d:\d\d (DEBUG|INFO |WARN |ERROR) \S/;

/** What the platform may say as a server starts, whatever a test does: a migration applied, jobs a
 * stop cut short queued again, a look at S3 (`STORAGE_URL`). */
// A plugin's own lines (what each added; the fixture's check, logged in the background) too.
const STARTING = /^\S+\s+(rocx server: migrated:|rocx jobs:|rocx storage:|rocx plugins:|fixture\.look:|email\.smtp:)/;

/** Waits for a stopped server's stderr to end: everything it wrote, read. */
const ended = (of) => new Promise((resolve) => (of.child.stderr.readableEnded ? resolve() : of.child.stderr.once("end", resolve)));

test("the log, with ROCX_LOG unset and stderr not a terminal, is JSON: every line an object with time, level and msg, the host's and Roc's; Log.line! is a message at info", { skip }, async () => {
	assert.equal(await text("/log"), "logged");
	await logsEvent({ msg: "a line from Roc" });
	const all = events();
	assert.ok(all.length > 0);
	for (const event of all) {
		assert.deepEqual(Object.keys(event).slice(0, 3), ["time", "level", "msg"], JSON.stringify(event));
		assert.match(event.time, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/, "RFC 3339, UTC");
		assert.ok(["debug", "info", "warn", "error"].includes(event.level), event.level);
	}
	// Not necessarily first: on a new database, a migration's line comes before it, and a job a stop
	// cut short is said to be queued again.
	assert.ok(all.some((event) => /^rocx server: http:\/\/127\.0\.0\.1:\d+ \(Roc, native\)$/.test(event.msg)), "the host's own lines too");
	const line = all.find((event) => event.msg === "a line from Roc");
	assert.deepEqual(Object.keys(line), ["time", "level", "msg"], "no fields");
	assert.equal(line.level, "info");
	// A value of ROCX_LOG it doesn't know is said, and the format guessed.
	const unknown = await start([], app, { ROCX_LOG: "loud" });
	await unknown.stop();
	await ended(unknown);
	const [first] = events(unknown);
	assert.deepEqual({ ...first, time: "" }, { time: "", level: "warn", msg: "rocx server: ROCX_LOG is pretty or json; the log's format is guessed instead", ROCX_LOG: "loud" });
});

test("ROCX_LOG=json: the server's lines and an app's events, with their fields beside time, level and msg (a field can't take their place), each a line of JSON", { skip }, async () => {
	const json = await start([], app, { ROCX_LOG: "json" });
	assert.equal(await json.text("/log/fields?run=r1"), "logged");
	assert.equal((await json.get("/crash")).status, 500);
	await json.stop();
	await ended(json);
	const lines = json.logged().trimEnd().split("\n");
	const all = lines.map((line) => JSON.parse(line));
	for (const event of all) {
		assert.deepEqual(Object.keys(event).slice(0, 3), ["time", "level", "msg"]);
		assert.match(event.time, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
		assert.ok(Math.abs(Date.parse(event.time) - Date.now()) < 60_000, "now");
	}
	const without = (event) => ({ ...event, time: undefined });
	const find = (msg) => without(all.find((event) => event.msg === msg));
	assert.ok(all.some((event) => /^rocx server: http:\/\/127\.0\.0\.1:\d+ \(Roc, native\)$/.test(event.msg)));
	assert.deepEqual(find("an event from Roc"), {
		time: undefined,
		level: "info",
		msg: "an event from Roc",
		count: 3,
		"fields.level": "not the level",
		"fields.msg": "not the message",
		note: "two words",
		ok: true,
		path: "/log/fields",
	});
	assert.deepEqual(find("a warning from Roc"), { time: undefined, level: "warn", msg: "a warning from Roc", run: "r1" });
	assert.deepEqual(find("an error from Roc"), { time: undefined, level: "error", msg: "an error from Roc" }, "{} is no fields");
	assert.deepEqual(find("a detail from Roc"), { time: undefined, level: "debug", msg: "a detail from Roc", nested: { list: [1, 2] } });
	assert.deepEqual(find("rocx server: Roc crashed"), { time: undefined, level: "error", msg: "rocx server: Roc crashed", method: "GET", target: "/crash", error: "on purpose" });
	assert.deepEqual(without(all.at(-1)), { time: undefined, level: "info", msg: "rocx server: stopping" });
});

test("ROCX_LOG=pretty: a line each, the local time, the level (no colour: stderr isn't a terminal), the message and key=value fields, quoted where they need it", { skip }, async () => {
	const pretty = await start([], app, { ROCX_LOG: "pretty" });
	assert.equal(await pretty.text("/log/fields?run=r1"), "logged");
	assert.equal((await pretty.get("/crash")).status, 500);
	await pretty.stop();
	await ended(pretty);
	const lines = pretty.logged().trimEnd().split("\n");
	for (const line of lines) {
		assert.match(line, PRETTY);
		assert.doesNotMatch(line, /\x1b/, "no colour");
		assert.throws(() => JSON.parse(line));
	}
	const [hours, minutes, seconds] = lines[0].slice(0, 8).split(":").map(Number);
	const now = new Date();
	const apart = Math.abs(hours * 3600 + minutes * 60 + seconds - (now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds()));
	assert.ok(Math.min(apart, 86_400 - apart) < 60, `the local time: ${lines[0].slice(0, 8)}, now ${now.toTimeString()}`);
	// The lines this test made: not the platform's own at a start (a migration, a job queued again).
	const shown = lines.map((line) => line.slice(9)).filter((line) => !STARTING.test(line));
	assert.match(shown[0], /^INFO  rocx server: http:\/\/127\.0\.0\.1:\d+ \(Roc, native\)$/);
	assert.deepEqual(shown.slice(1), [
		'INFO  an event from Roc count=3 fields.level="not the level" fields.msg="not the message" note="two words" ok=true path=/log/fields',
		"WARN  a warning from Roc run=r1",
		"ERROR an error from Roc",
		'DEBUG a detail from Roc nested="{\\"list\\":[1,2]}"',
		'ERROR rocx server: Roc crashed method=GET target=/crash error="on purpose"',
		"INFO  rocx server: stopping",
	]);
});

test("a program's `logs: { format: Pretty }` wins over what Auto would guess (JSON, stderr a pipe), and over ROCX_LOG", { skip }, async () => {
	const executable = join(dir, "pretty");
	buildApp(join(root, "server", "test", "pretty", "main.roc"), executable, { opt: process.env.ROCX_TEST_OPT ?? "dev" });
	for (const environment of [{}, { ROCX_LOG: "json" }]) {
		const pretty = await start([], executable, environment);
		assert.equal(await pretty.text("/hello"), "logged");
		await pretty.stop();
		await ended(pretty);
		const shown = pretty
			.logged()
			.trimEnd()
			.split("\n")
			.map((line) => (assert.match(line, PRETTY), line.slice(9)))
			.filter((line) => !STARTING.test(line));
		assert.match(shown[0], /^INFO  rocx server: http:\/\/127\.0\.0\.1:\d+ \(Roc, native\)$/, JSON.stringify(environment));
		assert.deepEqual(shown.slice(1), ['INFO  an event from Roc note="two words" target=/hello', "INFO  rocx server: stopping"]);
	}
});

test("the log is written off the request path, in order: 200 requests at once, logging 5 lines each, every line there, whole, each request's in the order it logged them", { skip }, async () => {
	const runs = Array.from({ length: 200 }, (_, i) => `${run}-p${i}`);
	const answers = await Promise.all(runs.map((each) => text(`/log/burst?run=${each}&lines=5`)));
	assert.deepEqual(new Set(answers), new Set(["logged 5"]));
	const ours = () => events().filter((event) => event.msg === "burst" && event.run.startsWith(`${run}-p`));
	await until(() => ours().length >= 1000);
	// `events` parses every line: one interleaved with another wouldn't be JSON.
	const seen = new Map(runs.map((each) => [each, []]));
	for (const event of ours()) seen.get(event.run).push(event.line);
	for (const [each, lines] of seen) assert.deepEqual(lines, [1, 2, 3, 4, 5], each);
});

test("what is logged just before a stop is written before the process exits: the log's queue is flushed", { skip }, async () => {
	const stopping = await start([], app);
	assert.equal(await stopping.text(`/log/burst?run=${run}-stop&lines=20000`), "logged 20000");
	assert.equal(await stopping.stop(), 0);
	await ended(stopping);
	const all = events(stopping);
	const lines = all.filter((event) => event.msg === "burst").map((event) => event.line);
	assert.equal(lines.length, 20000, "every line");
	assert.deepEqual(lines, Array.from({ length: 20000 }, (_, i) => i + 1), "in order");
	assert.equal(all.at(-1).msg, "rocx server: stopping", "and the stop after them");
});

test("a crash, an overflow, or a crash after allocating is a 500; the server goes on, holding nothing", { skip }, async () => {
	for (const path of ["/crash", "/overflow?x", "/big"]) {
		const response = await get(path);
		assert.equal(response.status, 500, path);
		assert.equal(await response.text(), "Something went wrong.", "the crash isn't shown outside dev");
	}
	await logsEvent({ level: "error", msg: "rocx server: Roc crashed", method: "GET", target: "/crash", error: "on purpose" });
	await logs(/Integer subtraction overflowed/);
	assert.equal(await text("/overflow"), "0", "the same route, not overflowing");
	const answers = await Promise.all(Array.from({ length: 200 }, (_, i) => get(i % 2 ? `/big?${i}` : "/overflow?x").then((r) => r.status)));
	assert.deepEqual(new Set(answers), new Set([500]));
	assert.equal(await text("/"), "Hello from Roc, natively.");
	// The background loops (workers, the cron ticker) allocate for a moment now and then: wait for them to settle.
	assert.equal(await until(async () => (await live()) === baseline), true, `every crash freed what its call had allocated: ${await live()} allocations, ${baseline} once started`);
});

test("a stream is a loop: each event sent as it is made, then `end`; it stops when its client goes", { skip }, async () => {
	const started = performance.now();
	const response = await get("/count");
	assert.equal(response.headers.get("content-type"), "text/event-stream");
	assert.equal(await response.text(), "data: 1\n\ndata: 2\n\ndata: 3\n\nevent: end\ndata: \n\n");
	assert.ok(performance.now() - started >= 30, "it slept between them");
	assert.equal(await text("/list"), "data: a\n\ndata: b\n\ndata: c\n\nevent: end\ndata: \n\n", "Events.from_list, a loop too");

	// What Roc holds once the background loops settle (they allocate for a moment now and then).
	const settled = async () => (await until(async () => (await live()) === baseline)) && baseline;
	const before = await settled();
	assert.equal(before, baseline, "nothing held before the stream");
	const gone = new AbortController();
	const ticks = await listen("/ticks", gone.signal);
	assert.equal(await ticks.next(), "tick 0");
	assert.equal(await ticks.next(), "tick 1");
	gone.abort();
	assert.equal(await until(async () => (await live()) === before), true, "the stream the client left was released");

	const crashed = await get("/stream-crash");
	assert.equal(await crashed.text(), "data: step 0\n\ndata: step 1\n\n", "a crash ends the stream");
	await logsEvent({ level: "error", msg: "rocx server: a stream crashed", error: /a stream's third step/ });
	assert.equal(await settled(), before, "and frees all it held, from before it began too");
});

test("an open stream holds up nothing else: many sleep at once, and pages are answered meanwhile", { skip }, async () => {
	const streams = await Promise.all(Array.from({ length: 50 }, () => get("/count")));
	assert.equal(await text("/"), "Hello from Roc, natively.", "answered while fifty streams sleep");
	const sent = await Promise.all(streams.map((response) => response.text()));
	assert.deepEqual(new Set(sent), new Set(["data: 1\n\ndata: 2\n\ndata: 3\n\nevent: end\ndata: \n\n"]));
});

// ---- Calls that wait hold no thread (D-027): each call into Roc is a coroutine on one of a few
// threads of Roc's own, and pauses while an effect waits. Two threads make the point. ----

/** `ask(i)` for `count` requests, all of them at once, but connecting a hundred every few
 * milliseconds: a listen queue holds 128 connections not yet accepted (macOS's `somaxconn`), and
 * one past that is reset. */
async function atOnce(count, ask) {
	const asked = [];
	for (let i = 0; i < count; i++) {
		if (i > 0 && i % 100 === 0) await new Promise((resolve) => setTimeout(resolve, 5));
		asked.push(ask(i));
	}
	return Promise.all(asked);
}

/** Starts the app on two Roc threads (`ROCX_ROC_THREADS=2`), with `flags`; and what Roc holds once
 * it has settled (its background loops' own). */
async function onTwoThreads(flags = []) {
	const two = await start(flags, app, { ROCX_ROC_THREADS: "2" });
	const allocations = async () => Number(await two.text("/__rocx/allocations"));
	let settled = -1;
	for (let previous = -2; settled !== previous; ) {
		previous = settled;
		await new Promise((resolve) => setTimeout(resolve, 200));
		settled = await allocations();
	}
	return { ...two, allocations, settled };
}

test("many calls wait at once on two Roc threads: 2,000 requests that each wait 1 s are all answered in about 1 s (blocking a thread each, they took 2,000 threads)", { skip }, async () => {
	const two = await onTwoThreads();
	try {
		const started = performance.now();
		const statuses = await atOnce(2000, () => two.get("/wait?ms=1000").then((response) => response.status));
		const took = performance.now() - started;
		assert.deepEqual(new Set(statuses), new Set([200]));
		assert.ok(took < 1800, `2,000 waits of 1 s took ${Math.round(took)} ms on two threads`);
		assert.equal(await until(async () => (await two.allocations()) === two.settled), true, "and nothing is left held");
	} finally {
		await two.stop();
	}
	const refused = await start([], app, { ROCX_ROC_THREADS: "none" }).catch((error) => error);
	assert.match(String(refused), /ROCX_ROC_THREADS needs a number above 0/, "a count that isn't one stops the server");
});

test("streams hold no thread: 2,000 open streams on two Roc threads, waiting, and a request is answered promptly meanwhile; they end when their clients go", { skip }, async () => {
	const two = await onTwoThreads();
	const gone = new AbortController();
	try {
		const streams = await atOnce(2000, () => two.get("/wait/stream?ms=30000", { headers: { accept: "text/event-stream" }, signal: gone.signal }));
		const readers = streams.map((response) => response.body.pipeThrough(new TextDecoderStream()).getReader());
		const first = await Promise.all(readers.map((reader) => reader.read().then((read) => read.value)));
		assert.deepEqual(new Set(first), new Set(["data: open\n\n"]), "every stream is open, and waiting");
		const started = performance.now();
		assert.equal(await two.text("/"), "Hello from Roc, natively.");
		assert.equal(await two.text("/wait?ms=50"), "waited");
		const took = performance.now() - started;
		assert.ok(took < 500, `a request and a wait of 50 ms took ${Math.round(took)} ms beside 2,000 streams`);
		gone.abort();
		assert.equal(await until(async () => (await two.allocations()) === two.settled, 10000), true, `the streams their clients left were released: ${await two.allocations()} allocations, ${two.settled} once started`);
	} finally {
		gone.abort();
		await two.stop();
	}
});

test("calls taking turns on two Roc threads keep their own state: waits, then crashes, refusals, pages, TCP and crashes that don't wait, interleaved, each answered as its own; nothing left held", { skip }, async () => {
	const tcpServer = createServer((socket) => {
		socket.setEncoding("utf8");
		let buffered = "";
		socket.on("data", (chunk) => {
			buffered += chunk;
			const end = buffered.indexOf("\n");
			if (end >= 0) socket.write(`${buffered.slice(0, end).toUpperCase()}\nend`);
		});
	});
	await new Promise((resolve) => tcpServer.listen(0, "127.0.0.1", resolve));
	const port = tcpServer.address().port;
	const two = await onTwoThreads(["--dev"]);
	try {
		const ms = () => 1 + Math.floor(Math.random() * 30);
		const asks = Array.from({ length: 600 }, (_, id) => {
			switch (id % 6) {
				case 0:
					return two.get(`/wait/crash?id=${id}&ms=${ms()}`).then(async (response) => [response.status, await response.text(), [500, `Roc crashed: crash ${id} after waiting`]]);
				case 1:
					return two.text(`/wait/page?id=${id}&ms=${ms()}`).then((html) => {
						const holes = [/class="waited"><!--x-->([^<]*)</, /class="refused"><!--x-->[^<]*: 409: ([^<]*)</, /class="after"><!--x-->([^<]*)</].map((hole) => hole.exec(html)?.[1]);
						return [200, holes.join(" | "), [200, `waited ${id} | refused ${id} | after ${id}`]];
					});
				case 2:
					return two.get(`/wait/page?id=${id}&ms=${ms()}&crash=yes`).then(async (response) => [response.status, await response.text(), [500, `Roc crashed: crash ${id} as it rendered`]]);
				case 3:
					return two.get(`/wait/tcp?id=${id}&ms=${ms()}&port=${port}`, { method: "POST" }).then(async (response) => [response.status, await response.text(), [200, `${id} end`]]);
				case 4:
					return two.get(`/big?${id}`).then(async (response) => [response.status, await response.text(), [500, `Roc crashed: after allocating ${2000 + String(id).length} strings`]]);
				default:
					return two.get(`/overflow?${"x".repeat(1 + (id % 5))}`).then(async (response) => [response.status, (await response.text()).includes("Integer subtraction overflowed"), [500, true]]);
			}
		});
		for (const [status, said, [expectedStatus, expected]] of await Promise.all(asks)) {
			assert.equal(status, expectedStatus, String(said));
			assert.equal(said, expected);
		}
		for (const id of [0, 6, 300, 594]) {
			await logsEvent({ level: "error", msg: "rocx server: Roc crashed", target: new RegExp(`^/wait/crash\\?id=${id}&`), error: `crash ${id} after waiting` }, two);
		}
		assert.equal(await until(async () => (await two.allocations()) === two.settled), true, `every call let go of what it held: ${await two.allocations()} allocations, ${two.settled} once started`);
	} finally {
		await two.stop();
		await new Promise((resolve) => tcpServer.close(resolve));
	}
});

test("a call that overflows its stack (8 MiB) ends the process, which says so on stderr first", { skip }, async () => {
	const deep = await start([], app, { ROCX_ROC_THREADS: "2" });
	const ended = new Promise((resolve) => deep.child.once("exit", (code, signal) => resolve({ code, signal })));
	await deep.get("/deep?n=100000000").catch(() => "gone");
	const { signal } = await ended;
	assert.ok(["SIGSEGV", "SIGBUS"].includes(signal), `ended by ${signal}`);
	assert.match(deep.logged(), /a call into Roc overflowed its stack \(8 MiB\): the process ends/);
	assert.equal(await (await get("/deep?n=1000")).text(), String(deep1000()), "a stack not so deep is fine");
});

/** What `/deep?n=1000` answers (`deep` in the app). */
function deep1000() {
	let below = 0;
	for (let n = 1; n <= 1000; n++) below = below > 1000 ? below - 1000 : below + 7;
	return below;
}

test("a body over 16 MiB is refused before Roc sees it", { skip }, async () => {
	const response = await get("/echo", { method: "POST", body: "x".repeat((16 << 20) + 1) });
	assert.equal(response.status, 413);
	assert.equal(await text("/"), "Hello from Roc, natively.");
});

// ---- Bytes ----

test("bytes: a body is the bytes as they came (16 MiB of them at most), read as text only when asked; an answer of bytes is sent as they are", { skip }, async () => {
	// Every byte, most of them not UTF-8, there and back.
	const every = Uint8Array.from({ length: 4096 }, (_, i) => (i * 7 + 255) % 256);
	const echoed = await get("/bytes/echo", { method: "POST", body: every, headers: { "content-type": "application/octet-stream" } });
	assert.equal(echoed.status, 200);
	assert.equal(echoed.headers.get("content-type"), "application/octet-stream");
	assert.deepEqual(new Uint8Array(await echoed.arrayBuffer()), every);
	// Read as text (`Server.text_of`), a byte that isn't UTF-8 is U+FFFD.
	assert.equal(await post("/echo", Uint8Array.from([0x68, 0x69, 0xc3, 0xa9, 0xff])), "POST /echo hié\uFFFD");

	// A part of exactly 16 MiB, as a video upload in parts may send them, gets to Roc whole.
	const part = randomBytes(16 << 20);
	const sha = createHash("sha256").update(part).digest("hex");
	assert.equal(await text("/bytes/sha", { method: "POST", body: part }), `${16 << 20} ${sha}`);

	// Bytes made in Roc, sent as they are, with their length; a HEAD gets the headers alone.
	const counted = await get("/bytes/counting?size=300000");
	assert.equal(counted.headers.get("content-length"), "300000");
	assert.deepEqual(new Uint8Array(await counted.arrayBuffer()), Uint8Array.from({ length: 300000 }, (_, i) => i % 256));
	const head = await get("/bytes/counting?size=300000", { method: "HEAD" });
	assert.equal(head.status, 200);
	assert.equal(head.headers.get("content-type"), "application/octet-stream");
	assert.equal((await head.arrayBuffer()).byteLength, 0);

	assert.equal(await until(async () => (await live()) === baseline), true, `the bodies, each way, were let go of: ${await live()} allocations, ${baseline} once started`);
});

test("endpoints: a body is read when it says it is JSON or a form; an upload of any other type is the handler's to read, as it came", { skip }, async () => {
	const part = randomBytes(5 * MiB);
	for (const type of ["video/mp4", "application/octet-stream", undefined]) {
		const uploaded = await get("/endpoint/upload", { method: "PUT", body: part, headers: type ? { "content-type": type } : {} });
		assert.equal(uploaded.status, 200, `${type}: ${uploaded.status}`);
		assert.deepEqual(await uploaded.json(), { size: 5 * MiB, sha: sha256(part) }, `a PUT of ${type ?? "no type"}`);
	}
	const shout = (body, type) => get("/endpoint/shout", { method: "POST", body, headers: type ? { "content-type": type } : {} });
	assert.equal(await (await shout('{"word":"hi"}', "application/json")).json(), "HI");
	assert.equal(await (await shout('{"word":"hi"}', "application/vnd.rocx+json; charset=utf-8")).json(), "HI", "a type ending +json");
	assert.equal(await (await shout("word=hi+there", "application/x-www-form-urlencoded")).json(), "HI THERE");
	const plain = await shout('{"word":"hi"}', "text/plain");
	assert.equal(plain.status, 415, "JSON that doesn't say so isn't read");
	assert.equal(await plain.text(), "POST /endpoint/shout reads JSON (application/json) or a form, not text/plain");
	assert.equal((await shout('{"word":', "application/json")).status, 400, "JSON that isn't");
	assert.equal(await until(async () => (await live()) === baseline), true, `the uploads were let go of: ${await live()} allocations, ${baseline} once started`);
});

// ---- Forward ----

/** A server for `Server.forward` to fetch from (this file runs it): `/file`, 3 MiB with ranges, an
 * ETag and a last-modified time; `/big`, 40 MiB, made as it is sent; `/moved`, a redirect to
 * `/file`; `/missing` and `/broken`, a 404 and a 500 whose bodies mustn't be passed on; `/cut`, a
 * body that stops short of its length. `asked` is each request it was sent. */
async function upstreamServer() {
	const file = randomBytes(3 * MiB);
	const etag = '"v1"';
	const modified = new Date(Date.UTC(2026, 10, 21)).toUTCString();
	const chunk = randomBytes(MiB);
	const bigSha = createHash("sha256");
	for (let i = 0; i < 40; i++) bigSha.update(chunk);
	const asked = [];
	const server = createHttpServer((request, response) => {
		asked.push({ method: request.method, url: request.url, headers: request.headers });
		const own = { "content-type": "application/octet-stream", etag, "last-modified": modified, "accept-ranges": "bytes", "x-upstream": "its own" };
		if (request.url === "/file") {
			if (request.headers["if-none-match"] === etag) return response.writeHead(304, { etag }).end();
			const range = /^bytes=(\d+)-(\d+)$/.exec(request.headers.range ?? "");
			if (range && Number(range[1]) >= file.length) return response.writeHead(416, { "content-range": `bytes */${file.length}` }).end("<Error>bucket rocx-secret</Error>");
			const [start, end] = range ? [Number(range[1]), Math.min(Number(range[2]), file.length - 1)] : [0, file.length - 1];
			const headers = { ...own, "content-length": end - start + 1, ...(range ? { "content-range": `bytes ${start}-${end}/${file.length}` } : {}) };
			return response.writeHead(range ? 206 : 200, headers).end(request.method === "HEAD" ? undefined : file.subarray(start, end + 1));
		}
		if (request.url === "/big") {
			response.writeHead(200, { ...own, "content-length": 40 * MiB });
			let sent = 0;
			const more = () => {
				while (sent < 40) {
					sent++;
					if (!response.write(chunk)) return response.once("drain", more);
				}
				response.end();
			};
			return more();
		}
		if (request.url === "/moved") return response.writeHead(302, { location: "/file" }).end();
		if (request.url === "/missing") return response.writeHead(404, { "content-type": "application/xml" }).end("<Error><Code>NoSuchKey</Code><BucketName>rocx-secret</BucketName></Error>");
		if (request.url === "/broken") return response.writeHead(500, { "content-type": "text/plain" }).end("stack trace, rocx-secret");
		if (request.url === "/cut") {
			response.writeHead(200, { ...own, "content-length": MiB });
			return response.write(chunk.subarray(0, 1000), () => setTimeout(() => response.socket.destroy(), 20));
		}
		response.writeHead(404).end();
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	return { url: `http://127.0.0.1:${server.address().port}`, file, etag, modified, bigSha: bigSha.digest("hex"), asked, close: () => new Promise((resolve) => (server.closeAllConnections(), server.close(resolve))) };
}

test("forward: a body fetched from another server and sent on as it comes, never through Roc: its status, length, ranges and ETag, with the answer's headers", { skip }, async () => {
	const upstream = await upstreamServer();
	const at = (path) => `/forward?url=${encodeURIComponent(upstream.url + path)}`;
	try {
		const whole = await get(at("/file"), { headers: { cookie: "member=Ada", "x-mine": "mine" } });
		assert.equal(whole.status, 200);
		assert.deepEqual(Buffer.from(await whole.arrayBuffer()), upstream.file);
		assert.equal(whole.headers.get("content-length"), String(3 * MiB));
		assert.equal(whole.headers.get("etag"), upstream.etag);
		assert.equal(whole.headers.get("last-modified"), upstream.modified);
		assert.equal(whole.headers.get("accept-ranges"), "bytes");
		assert.equal(whole.headers.get("content-type"), "video/mp4", "the answer's own, in place of upstream's");
		assert.equal(whole.headers.get("cache-control"), "private, max-age=60");
		assert.equal(whole.headers.get("set-cookie"), "seen=1");
		assert.equal(whole.headers.get("x-upstream"), null, "of upstream's headers, only what says what the body is");
		const sent = upstream.asked.at(-1);
		assert.equal(sent.headers["x-rocx"], "yes", "the upstream's headers, as Roc gave them");
		assert.equal(sent.headers.cookie, undefined, "the request's own stay here");
		assert.equal(sent.headers["x-mine"], undefined);

		const part = await get(at("/file"), { headers: { range: "bytes=100-199" } });
		assert.equal(part.status, 206, "a range, passed on");
		assert.equal(part.headers.get("content-range"), `bytes 100-199/${3 * MiB}`);
		assert.equal(part.headers.get("content-length"), "100");
		assert.deepEqual(Buffer.from(await part.arrayBuffer()), upstream.file.subarray(100, 200));
		const same = await get(at("/file"), { headers: { "if-none-match": upstream.etag } });
		assert.equal(same.status, 304, "If-None-Match, passed on");
		assert.equal(same.headers.get("etag"), upstream.etag);
		assert.equal((await same.arrayBuffer()).byteLength, 0);
		const head = await get(at("/file"), { method: "HEAD" });
		assert.equal(head.status, 200);
		assert.equal(head.headers.get("content-length"), String(3 * MiB), "a HEAD: the length, and no body");
		assert.equal((await head.arrayBuffer()).byteLength, 0);
		// The range and cache questions are the request record's to pass on (`Server.passed_on`), not
		// the host's: a forward that passes none sends none, whatever the client asked.
		const bare = await get(`${at("/file")}&bare=1`, { headers: { range: "bytes=100-199", "if-none-match": upstream.etag } });
		assert.equal(bare.status, 200, "no range, no If-None-Match: the whole file");
		assert.equal((await bare.arrayBuffer()).byteLength, 3 * MiB);
		const unasked = upstream.asked.at(-1);
		assert.equal(unasked.headers.range, undefined, "the host adds no range of its own");
		assert.equal(unasked.headers["if-none-match"], undefined);
		assert.equal(unasked.headers["x-rocx"], "yes");
		const moved = await get(at("/moved"));
		assert.equal(moved.status, 200, "a redirect, followed");
		assert.equal((await moved.arrayBuffer()).byteLength, 3 * MiB);

		// 40 MiB: more than a request may send, and more than `Http` reads into Roc.
		const big = await get(at("/big"));
		assert.equal(big.headers.get("content-length"), String(40 * MiB));
		assert.equal(sha256(Buffer.from(await big.arrayBuffer())), upstream.bigSha);
		assert.equal(await until(async () => (await live()) === baseline), true, `Roc held none of it: ${await live()} allocations, ${baseline} once started`);
	} finally {
		await upstream.close();
	}
});

test("forward: an error upstream is its status and reason, never its body; a body cut short isn't passed off as whole; no answer is a 502, logged without the URL's query", { skip }, async () => {
	const upstream = await upstreamServer();
	const at = (path) => `/forward?url=${encodeURIComponent(upstream.url + path)}`;
	try {
		const missing = await get(at("/missing"));
		assert.equal(missing.status, 404);
		assert.equal(missing.headers.get("content-type"), "text/plain; charset=utf-8");
		assert.equal(await missing.text(), "Not Found", "nothing upstream said");
		assert.equal(missing.headers.get("cache-control"), null, "nor the answer's headers, which describe the body it would have been");
		const past = await get(at("/file"), { headers: { range: `bytes=${3 * MiB}-${3 * MiB + 9}` } });
		assert.equal(past.status, 416);
		assert.equal(past.headers.get("content-range"), `bytes */${3 * MiB}`);
		assert.equal(await past.text(), "Range Not Satisfiable");
		const broken = await get(at("/broken"));
		assert.equal(broken.status, 500);
		assert.equal(await broken.text(), "Internal Server Error");
		await logsEvent({ level: "warn", msg: "rocx server: forwarded an error", method: "GET", target: /^\/forward\?url=/, upstream: /^http:\/\/127\.0\.0\.1:\d+\/broken$/, status: 500 });
		assert.ok(!events().some((event) => has(event, { msg: "rocx server: forwarded an error", upstream: /\/missing$/ })), "a 404 is the client's to hear about, not the log's");

		await assert.rejects(get(at("/cut")).then((response) => response.arrayBuffer()), "a body that stops short ends the connection, not the body");

		const nowhere = await get(`/forward?url=${encodeURIComponent("http://127.0.0.1:9/file?X-Amz-Signature=sesame")}`);
		assert.equal(nowhere.status, 502);
		assert.equal(await nowhere.text(), "Bad Gateway");
		await logsEvent({ level: "error", msg: "rocx server: forwarding failed", upstream: "http://127.0.0.1:9/file" });
		assert.ok(
			events().every((event) => !/forward/.test(event.msg) || !/sesame/.test(`${event.upstream} ${event.error}`)),
			"the upstream's query (a presigned URL's signature) never logged",
		);
		const refused = await get(`/forward?url=${encodeURIComponent("ftp://127.0.0.1/file")}`);
		assert.equal(refused.status, 502, "a URL that isn't http's");
		assert.equal(await until(async () => (await live()) === baseline), true, `nothing held: ${await live()} allocations, ${baseline} once started`);
	} finally {
		await upstream.close();
	}
});

test("a port in use: the server says so and exits, having started nothing (no job workers, no schedules), so nothing panics on its way out", { skip: skipDb }, async () => {
	const port = new URL(server.url).port;
	const child = spawn(app, ["--port", port, "--context-file", join(dir, "context.txt"), ...dbFlags()], { stdio: ["ignore", "ignore", "pipe"], env: { ...process.env, ROCX_LOG: "", ROCX_TEST_SETTING: SETTING, FIXTURE_KEY: "set", ...mailEnv() } });
	let logged = "";
	child.stderr.on("data", (chunk) => (logged += chunk));
	const code = await new Promise((resolve) => child.on("exit", resolve));
	// What the loops would have logged, had they started, comes a moment later.
	await new Promise((resolve) => setTimeout(resolve, 300));
	assert.equal(code, 1, logged);
	const said = logged.trimEnd().split("\n").map((line) => JSON.parse(line));
	assert.ok(said.some((event) => has(event, { level: "error", msg: "rocx server: can't start", error: /^127\.0\.0\.1:\d+: Address already in use/ })), logged);
	assert.doesNotMatch(logged, /panicked|Tokio|error connecting/, logged);
	assert.equal(await text("/"), "Hello from Roc, natively.", "the server on that port goes on");
});

// ---- Postgres ----

test("migrations: the platform's tables, then the app's (embedded in it), in order, each once", { skip: skipDb }, async () => {
	// The server this file started applied whatever this database hadn't seen; a second start
	// applies nothing.
	const again = await start(dbFlags(), app, mailEnv());
	assert.doesNotMatch(again.logged(), /migrated:/);
	assert.equal(await again.text("/tx/notes?run=nothing"), "", "the app's tables are there");
	assert.equal(await again.stop(), 0);
});

test("Postgres: statements with parameters, rows decoded into records, nulls as Db.Nullable(a)", { skip: skipDb }, async () => {
	assert.equal(await post("/notes", "first"), "added 1");
	assert.equal(await post("/notes?noted", "second"), "added 1");
	assert.equal(await text("/notes"), "1 first -\n2 second a note");
	assert.equal(await text("/note"), "first", "Int(1) read as the bigint its place wants");
	const unmarked = await get("/nullable");
	assert.equal(unmarked.status, 500);
	assert.match(await unmarked.text(), /`maybe` is null in a row; a column that may be null is read as Db\.Nullable\(a\)/);
	const marked = await get("/nullable-marked");
	assert.equal(marked.status, 500);
	assert.match(await marked.text(), /column `maybe\?`: a name doesn't say whether it may be null any more: call it `maybe`, and read it as `Db\.Nullable\(a\)` if it may be/);
	assert.deepEqual(JSON.parse(await text("/nullables")), [
		{ n: 1, tags: ["x", "y"], doc: { a: null } },
		{ n: null, tags: null, doc: null },
	], "a null is null, a value is itself, nested too, read and written back");
	const bad = await get("/bad-sql");
	assert.equal(bad.status, 500);
	assert.equal(await bad.text(), '42P01: relation "nowhere" does not exist');
});

test("Postgres: a list as one parameter (Db.array), text or bigint, with = any, @> and unnest; quotes, backslashes, commas, braces, empty text, NULL as text, unicode and nulls as they were", { skip: skipDb }, async () => {
	const answer = await get("/arrays");
	const said = await answer.text();
	assert.equal(answer.status, 200, said);
	const arrays = JSON.parse(said);
	const awkward = ["plain", "two words", "a,b", "{braces}", 'say "hi"', "back\\slash", "", "NULL", "zażółć ✓ 日本"];
	assert.deepEqual(
		arrays.unnested,
		[...awkward, null].map((v, i) => ({ i: i + 1, v })),
		"each text back as it was, in order, and a null a null (unnest($1::text[]))",
	);
	assert.deepEqual(arrays.found, ["", "a,b", "back\\slash", "two words"], "= any($1), $1 read as text[]");
	assert.deepEqual(arrays.contains, [{ yes: true, no: false }], "@> $1");
	assert.deepEqual(arrays.numbers, [{ total: 39999999999, nulls: 1, hit: true, miss: false, holds: true }], "bigint arrays: unnest, = any, @>");
	assert.deepEqual(arrays.flags, [{ all: false, count: 2 }], "booleans");
	assert.deepEqual(arrays.empty, [{ n: 0, none: true }], "an empty list");
	assert.match(arrays.uncast, /^42725: function unnest\(unknown\) is not unique/, "unnest($1) alone: Postgres can't tell which array, so it takes a cast");
});

test("Postgres: effects wait on their own threads, so eight 0.3 s queries take about 0.3 s", { skip: skipDb }, async () => {
	const started = performance.now();
	const answers = await Promise.all(Array.from({ length: 8 }, () => text("/sleep")));
	const took = performance.now() - started;
	assert.deepEqual(new Set(answers), new Set(["slept"]));
	assert.ok(took < 1000, `took ${took.toFixed(0)} ms`);
});

test("transactions: Ok commits all, an Err rolls back, a crash or a failing statement rolls back", { skip: skipDb }, async () => {
	const tx = `${run}tx`;
	assert.equal(await post(`/tx/commit?run=${tx}`), "committed");
	assert.equal((await get(`/tx/rollback?run=${tx}`, { method: "POST" })).status, 409);
	assert.equal((await get(`/tx/crash?run=${tx}`, { method: "POST" })).status, 500);
	await logs(/a call ended with its transaction open: rolled back/);
	const failing = await get(`/tx/failing-statement?run=${tx}`, { method: "POST" });
	assert.equal(failing.status, 500);
	assert.match(await failing.text(), /relation "nowhere" does not exist/);
	assert.equal(await text(`/tx/notes?run=${tx}`), `committed ${tx}\nalso committed ${tx}`, "only what committed");
	// The connections went back to the pool clean: nothing is stuck in a transaction.
	const after = await Promise.all(Array.from({ length: 20 }, () => text(`/tx/notes?run=${tx}`)));
	assert.deepEqual(new Set(after), new Set([`committed ${tx}\nalso committed ${tx}`]));
});

// ---- Jobs, cron ----

/** A job's state once its worker has recorded how it went: a job writes its log as it runs, and the
 * worker marks it done just after, so the log can be there a moment before the state is. */
const finished = (job) =>
	until(async () => {
		const state = await text(`/jobs/state?run=${job}`);
		return !state.startsWith("running") && !state.startsWith("queued") && state;
	});

/** What the platform applied before jobs were a package (D-034), as master had it: its first
 * migration (the queue and actors' state) and its second (job keys, cancelling, the outbox), word
 * for word; and its third, which dropped the outbox. */
const PLATFORM_BEFORE_D034 = [
	[
		"rocx/0001 jobs and actors",
		"create table rocx_jobs (\n    id bigserial primary key,\n    kind text not null,\n    input text not null,\n    state text not null default 'queued' check (state in ('queued', 'running', 'done', 'failed')),\n    attempts int not null default 0,\n    max_attempts int not null default 5,\n    run_at timestamptz not null default now(),\n    locked_at timestamptz,\n    finished_at timestamptz,\n    last_error text,\n    unique_key text unique,\n    created_at timestamptz not null default now()\n);\ncreate index rocx_jobs_ready on rocx_jobs (run_at, id) where state = 'queued';\ncreate table rocx_actors (\n    kind text not null,\n    key text not null,\n    state text not null,\n    updated_at timestamptz not null default now(),\n    primary key (kind, key)\n);",
	],
	[
		"rocx/0002 job keys, cancelling, the outbox",
		"alter table rocx_jobs drop constraint rocx_jobs_unique_key_key;\ncreate unique index rocx_jobs_pending_key on rocx_jobs (unique_key) where state in ('queued', 'running');\nalter table rocx_jobs drop constraint rocx_jobs_state_check;\nalter table rocx_jobs add constraint rocx_jobs_state_check check (state in ('queued', 'running', 'done', 'failed', 'canceled'));\ncreate index rocx_jobs_listed on rocx_jobs (state, kind, id);\ncreate table rocx_outbox (\n    id bigserial primary key,\n    sent_at timestamptz not null default now(),\n    from_address text not null,\n    to_address text not null,\n    subject text not null,\n    text text not null,\n    html text not null,\n    raw text not null\n);",
	],
	["rocx/0003 the dev mailbox in memory", "drop table if exists rocx_outbox"],
];

test("jobs: a database the platform migrated before jobs were a package (D-034) keeps its queue: nothing made again, its jobs where they were, a due one run, a key still one pending job's", { skip: skipDb }, async () => {
	const db = await testDatabase();
	let moved;
	try {
		// The database as the platform left it: its migrations applied and recorded, and a queue with
		// a job due, one keyed for later, one failed and one done.
		await db.query("create table rocx_migrations (name text primary key, applied_at timestamptz not null default now())");
		for (const [name, sql] of PLATFORM_BEFORE_D034) {
			await db.query(sql);
			await db.query(`insert into rocx_migrations (name) values ('${name.replaceAll("'", "''")}')`);
		}
		const marker = `${run}kept`;
		await db.query(
			`insert into rocx_jobs (kind, input, state, run_at, unique_key, attempts, last_error, finished_at) values
				('note', '{"run":"${marker}","said":"from before"}', 'queued', now(), null, 0, null, null),
				('note', '{"run":"${marker}","said":"later"}', 'queued', now() + interval '1 hour', 'later:${marker}', 0, null, null),
				('flaky', '{"run":"${marker}","fails":9}', 'failed', now(), null, 5, 'failed before', now()),
				('note', '{"run":"${marker}","said":"done"}', 'done', now(), null, 1, null, now())`,
		);
		moved = await start(["--database-url", db.url]);
		const migrated = events(moved)
			.map((event) => event.msg)
			.filter((msg) => msg.startsWith("rocx server: migrated:"));
		assert.ok(migrated.includes("rocx server: migrated: jobs/0001_jobs"), migrated.join("\n"));
		assert.ok(!migrated.some((msg) => msg.includes("rocx/")), "the platform's own, not again");
		// The job that was due runs; the rest are as they were.
		assert.equal(await until(() => moved.text(`/jobs/log?run=${marker}`)), `note: ${marker} from before`);
		// The worker marks it done just after it ran.
		const state = async () => (await db.query(`select state from rocx_jobs where input like '%${marker}%from before%'`))[0]?.state;
		assert.equal(await until(async () => ((await state()) === "done" ? "done" : "")), "done", "and is done");
		const rows = await db.query(`select input::json->>'said' as said, state, attempts, unique_key, last_error from rocx_jobs where input like '%${marker}%' order by id`);
		assert.deepEqual(
			rows.map((row) => [row.said, row.state, row.attempts, row.unique_key, row.last_error]),
			[
				["from before", "done", 1, null, null],
				["later", "queued", 0, `later:${marker}`, null],
				[null, "failed", 5, null, "failed before"],
				["done", "done", 1, null, null],
			],
		);
		// The key is still one pending job's, and a queued job can still be canceled.
		await assert.rejects(db.query(`insert into rocx_jobs (kind, input, unique_key) values ('note', '{}', 'later:${marker}')`), /rocx_jobs_pending_key/);
		assert.equal(await moved.text(`/jobs/cancel?key=later:${marker}`, { method: "POST" }), "1");
		assert.deepEqual(await db.query(`select state from rocx_jobs where unique_key = 'later:${marker}'`), [{ state: "canceled" }]);
	} finally {
		await moved?.stop();
		await db.drop();
	}
});

test("jobs: one queued runs at once, one queued for later runs later, in the background", { skip: skipDb }, async () => {
	const now = `${run}now`;
	const started = performance.now();
	assert.equal(await post(`/jobs/note?run=${now}`, "hello"), "queued");
	assert.equal(await until(() => text(`/jobs/log?run=${now}`)), `note: ${now} hello`);
	assert.ok(performance.now() - started < 500, "a worker woke when it was queued");
	assert.equal(await finished(now), "done 1 ");

	const later = `${run}later`;
	const queued = performance.now();
	assert.equal(await post(`/jobs/later?run=${later}`), "queued");
	assert.equal(await text(`/jobs/log?run=${later}`), "", "not yet");
	assert.equal(await until(() => text(`/jobs/log?run=${later}`)), `note: ${later} later`);
	const took = performance.now() - queued;
	assert.ok(took >= 400 && took < 1000, `ran ${took.toFixed(0)} ms after it was queued, for 400`);
});

test("jobs: one that fails runs again, a little later each time, and one that always crashes fails for good", { skip: skipDb }, async () => {
	const flaky = `${run}flaky`;
	assert.equal(await post(`/jobs/flaky?run=${flaky}&fails=2`), "queued");
	assert.equal(await until(() => text(`/jobs/log?run=${flaky}`)), `flaky: ${flaky} done`);
	assert.equal(await finished(flaky), "done 3 ", "the third attempt");
	await logs(/flaky #\d+ failed \(attempt 1 of 5\), again in 20 ms: not yet \(try 1\)/);
	await logs(/again in 40 ms: not yet \(try 2\)/);

	const crashing = `${run}crash`;
	assert.equal(await post(`/jobs/crash?run=${crashing}`), "queued");
	const failed = await until(async () => {
		const state = await text(`/jobs/state?run=${crashing}`);
		return state.startsWith("failed") && state;
	});
	assert.equal(failed, "failed 5 crashed: a job that always crashes");
	await logs(/crash #\d+ failed for good after 5 attempts/);
	assert.equal(await text("/"), "Hello from Roc, natively.", "crashing jobs didn't stop the server");
});

test("jobs: queued in a transaction, a job is there only if the transaction commits; one body `?`s Db, Job and the app's own error, and its caller matches each", { skip: skipDb }, async () => {
	const kept = `${run}kept`;
	assert.equal(await post(`/jobs/commit?run=${kept}`), "queued");
	assert.equal(await until(() => text(`/jobs/log?run=${kept}`)), `note: ${kept} committed`);
	const dropped = `${run}dropped`;
	const refused = await get(`/jobs/rollback?run=${dropped}`, { method: "POST" });
	assert.equal(refused.status, 409);
	assert.equal(await refused.text(), "Refused", "the app's own error");
	const statement = await get(`/jobs/rollback?run=${dropped}&how=statement`, { method: "POST" });
	assert.equal(statement.status, 500);
	assert.equal(await statement.text(), 'DbErr: 42P01: relation "nowhere" does not exist', "a statement's error, from Db.run!");
	const queue = await get(`/jobs/rollback?run=${dropped}&how=queue`, { method: "POST" });
	assert.equal(queue.status, 500);
	assert.match(await queue.text(), /^JobErr: 25P02: current transaction is aborted/, "the queue's error, from Job.enqueue!");
	await new Promise((resolve) => setTimeout(resolve, 300));
	assert.equal(await text(`/jobs/state?run=${dropped}`), "", "never queued");
	assert.equal(await text(`/jobs/log?run=${dropped}`), "");
	assert.equal(await text(`/tx/notes?run=${dropped}`), "", "nor the notes written before");
});

test("jobs: a job of a kind the app doesn't list (another app's, sharing the database) is left alone", { skip: skipDb }, async () => {
	const foreign = `${run}foreign`;
	assert.equal(await post(`/jobs/foreign?run=${foreign}`), "queued");
	await new Promise((resolve) => setTimeout(resolve, 500));
	assert.equal(await text(`/jobs/state?run=${foreign}`), "queued 0 ", "still queued, never attempted");
	assert.equal(await text(`/jobs/foreign?run=${foreign}`, { method: "DELETE" }), "1");
});

test("cron: a job every second, queued by its schedule and run by a worker", { skip: skipDb }, async () => {
	const first = Number(await text("/jobs/ticks"));
	await new Promise((resolve) => setTimeout(resolve, 2200));
	const then = Number(await text("/jobs/ticks"));
	assert.ok(then - first >= 2 && then - first <= 3, `${then - first} ticks in 2.2 s`);
});

/** The jobs a list of the app's (`/jobs/list?…`) shows: `id kind state tried/attempts key error` each. */
const jobRows = async (query) => {
	const said = await text(`/jobs/list?${query}`);
	return said === "" ? [] : said.split("\n").map((line) => {
		const [id, kind, state, tried, key, ...error] = line.split(" ");
		return { id: Number(id), kind, state, tried, key, error: error.join(" ") };
	});
};

test("jobs: a kind says how many times its jobs are tried: one tried twice fails for good after two", { skip: skipDb }, async () => {
	const twice = `${run}twice`;
	assert.equal(await post(`/jobs/twice?run=${twice}`), "queued");
	assert.equal(await finished(twice), `failed 2 fails every time (${twice})`);
	await logs(/twice #\d+ failed \(attempt 1 of 2\), again in 20 ms/);
	await logs(/twice #\d+ failed for good after 2 attempts/);
});

test("jobs: a time limit cuts a run off at its next wait (Postgres, another server, a socket), whatever it does with the error; tried again, then failed; nothing left held", { skip: skipDb }, async () => {
	const settled = async () => (await until(async () => (await live()) === baseline)) && baseline;
	const before = await settled();
	// Another server that answers in 3 s, and one that never says anything.
	const node = await httpServer();
	const sockets = [];
	const silent = createServer((socket) => sockets.push(socket));
	await new Promise((resolve) => silent.listen(0, "127.0.0.1", resolve));
	try {
		const started = performance.now();
		const ways = { db: "", http: `${node.url}/slow`, tcp: String(silent.address().port) };
		for (const [on, url] of Object.entries(ways)) {
			assert.equal(await post(`/jobs/slow?run=${run}slow${on}&on=${on}&url=${encodeURIComponent(url)}`), "queued");
		}
		for (const on of Object.keys(ways)) {
			assert.equal(await finished(`${run}slow${on}`), "failed 2 timed out after 300 ms", on);
			assert.equal(await text(`/jobs/log?run=${run}slow${on}`), "", `${on}: cut off, it never went on to write`);
		}
		const took = performance.now() - started;
		assert.ok(took < 3000, `three jobs, two runs of 300 ms each, at once: ${took.toFixed(0)} ms`);
		await logs(/slow #\d+ failed \(attempt 1 of 2\), again in 20 ms: timed out after 300 ms/);
		await logs(/slow #\d+ failed for good after 2 attempts: timed out after 300 ms/);
		// In time, it is done.
		assert.equal(await post(`/jobs/slow?run=${run}quick&on=none`), "queued");
		assert.equal(await finished(`${run}quick`), "done 1 ");
		assert.equal(await text(`/jobs/log?run=${run}quick`), `slow: ${run}quick finished`);
		// Postgres stopped the statements it was cut off in, and the pool is whole.
		assert.equal(await until(async () => (await text("/jobs/sleepers")) === "0"), true, "the statements were cancelled");
		const answers = await Promise.all(Array.from({ length: 20 }, () => text("/sleep")));
		assert.deepEqual(new Set(answers), new Set(["slept"]));
		assert.equal(await settled(), before, "what the runs allocated was freed");
	} finally {
		for (const socket of sockets) socket.destroy();
		await Promise.all([node.close(), new Promise((resolve) => silent.close(resolve))]);
	}
});

test("jobs: a key is one pending job's: a second is refused while the first waits, and taken again once it is canceled or done", { skip: skipDb }, async () => {
	const keyed = `${run}keyed`;
	const key = `${run}:one`;
	assert.equal(await post(`/jobs/keyed?run=${keyed}&key=${key}&in=60000`, "first"), "queued");
	assert.equal(await post(`/jobs/keyed?run=${keyed}&key=${key}&in=60000`, "second"), "exists", "a pending job has the key");
	assert.equal(await post(`/jobs/keyed?run=${keyed}&key=${key}other&in=60000`, "other"), "queued", "another key");
	assert.equal(await post(`/jobs/cancel?key=${key}`), "1");
	assert.equal(await post(`/jobs/cancel?key=${key}`), "0", "nothing queued has it now");
	assert.equal(await post(`/jobs/keyed?run=${keyed}&key=${key}`, "third"), "queued", "free again once canceled");
	assert.equal(await until(() => text(`/jobs/log?run=${keyed}`)), `note: ${keyed} third`);
	await until(async () => (await jobRows(`kind=note&state=done&limit=5`)).some((row) => row.key === key));
	assert.equal(await post(`/jobs/keyed?run=${keyed}&key=${key}`, "fourth"), "queued", "and once done");
	assert.equal(await until(async () => (await text(`/jobs/log?run=${keyed}`)).endsWith("fourth") && "yes"), "yes");
	assert.equal(await post(`/jobs/cancel?key=${key}other`), "1");
	const states = (await text(`/jobs/state?run=${keyed}`)).split("\n").map((line) => line.split(" ")[0]);
	assert.deepEqual(states, ["canceled", "canceled", "done", "done"], "the second never queued");
});

test("jobs: one queued with a key is moved to another time by it", { skip: skipDb }, async () => {
	const moved = `${run}moved`;
	assert.equal(await post(`/jobs/keyed?run=${moved}&key=${moved}&in=60000`, "moved"), "queued");
	const asked = performance.now();
	assert.equal(await post(`/jobs/move?key=${moved}&in=300`), "1");
	assert.equal(await until(() => text(`/jobs/log?run=${moved}`)), `note: ${moved} moved`);
	const took = performance.now() - asked;
	assert.ok(took >= 300 && took < 1500, `ran ${took.toFixed(0)} ms after it was moved to 300 ms from then`);
	assert.equal(await post(`/jobs/move?key=${moved}&in=300`), "0", "done: nothing queued has the key");
});

test("jobs: listed newest first, by state and kind, a page at a time; one read by its id; counted", { skip: skipDb }, async () => {
	for (const n of [1, 2, 3]) assert.equal(await post(`/jobs/keyed?run=${run}list&key=${run}list${n}&in=60000`, `list ${n}`), "queued");
	assert.equal(await post(`/jobs/cancel?key=${run}list2`), "1");
	const queued = await jobRows("state=queued&kind=note");
	assert.deepEqual(queued.map((row) => row.key), [`${run}list3`, `${run}list1`]);
	assert.ok(queued.every((row) => row.state === "queued" && row.tried === "0/5" && row.error === "-"));
	const [newest] = await jobRows("kind=note&limit=1");
	assert.equal(newest.key, `${run}list3`);
	const [next] = await jobRows(`kind=note&limit=1&before=${newest.id}`);
	assert.equal(next.key, `${run}list2`, "the next page");
	assert.equal(next.state, "canceled");
	assert.ok((await jobRows("state=canceled")).some((row) => row.key === `${run}list2`));
	assert.equal((await jobRows("state=failed&kind=note")).length, 0);
	assert.ok((await jobRows("kind=twice")).every((row) => row.kind === "twice" && row.tried === "2/2"));
	assert.equal(await text(`/jobs/get?id=${newest.id}`), `${newest.id} note queued 0/5 ${run}list3 -`);
	assert.equal((await get("/jobs/get?id=999999999")).status, 404);
	const counts = (await text("/jobs/counts")).split("\n");
	assert.ok(counts.some((line) => /^note queued \d+$/.test(line)) && counts.includes("twice failed 1"), counts.join(", "));
	for (const n of [1, 3]) assert.equal(await post(`/jobs/cancel?key=${run}list${n}`), "1");
});

test("the jobs page, as a plugin (JobsPage.plugin, packages/admin): behind the app's guard; a link back to the app; the states, the last hour, failures, kinds, schedules and jobs; retry, cancel and run now as forms; one job in a drawer; its stream of changes", { skip: skipDb }, async () => {
	const admin = { "x-admin": "yes" };
	const page = (query = "", init = {}) => get(`/admin/jobs${query}`, { ...init, headers: { ...admin, ...init.headers }, redirect: "manual" });
	const form = (fields, headers = {}) => page("", { method: "POST", body: new URLSearchParams(fields).toString(), headers: { "content-type": "application/x-www-form-urlencoded", ...headers } });

	const listed = await page();
	assert.equal(listed.status, 200);
	assert.equal(listed.headers.get("content-type"), "text/html; charset=utf-8");
	const html = await listed.text();
	assert.match(html, /<h1>Jobs<\/h1>/);
	assert.match(html, /<div class="shell" data-events="\/admin\/jobs\?events=1" data-now="\d+">/);
	assert.match(html, /<nav class="side-nav" aria-label="Jobs"><a class="back" href="\/"><svg[^>]*>.*?<\/svg><span class="label">Acme Tests<\/span><\/a><a href="\/admin\/jobs" aria-current="page">/, "the link back to the app, first in the sidebar (`back`)");
	assert.match(html, /<a class="metric" href="\/admin\/jobs" aria-current="page"><span class="metric-label">All<\/span><strong>\d+<\/strong><\/a>/);
	assert.match(html, /<h2>Finished jobs<\/h2>/, "the last hour");
	assert.match(html, /<div class="bars" role="img" aria-label="In the last hour: \d+ done, \d+ done after a retry, [1-9]\d* failed">/, "its bars, the jobs that failed above among them, not an error");
	assert.match(html, /<h2>Failures<\/h2>/, "the latest failures");
	assert.match(html, /<a class="kind-name" href="\/admin\/jobs\?kind=twice"><code>twice<\/code><\/a><span class="kind-meta">2 attempts · no time limit<\/span>/, "a kind, its attempts and time limit");
	assert.match(html, /kind=slow"><code>slow<\/code><\/a><span class="kind-meta">2 attempts · 300 ms limit<\/span>/);
	assert.match(html, /kind=tick"><code>tick<\/code><\/a><form[\s\S]*?<span class="cron"><code>\* \* \* \* \* \*<\/code>every second<\/span><span class="next">next <time datetime="\d+" title="[^"]+ UTC">(in \d+ s|now)<\/time><\/span>/, "a schedule, in words, and when it runs next");

	// The failed job of a kind tried twice, with its last error and a Retry button.
	const failed = await (await page("?state=failed&kind=twice")).text();
	const [, id] = /href="\/admin\/jobs\?state=failed&amp;kind=twice&amp;id=(\d+)"><strong>twice<\/strong><span>#\d+<\/span><\/a><span class="err" title="fails every time [^"]*">[^<]*<\/span><\/td><td><span class="state state-failed">failed<\/span><\/td><td class="n"><span class="tries">2<small> of 2<\/small><\/span><\/td>/.exec(failed) ?? [];
	assert.ok(id, failed);
	assert.match(failed, new RegExp(`fails every time \\(${run}twice\\)`));
	assert.match(failed, new RegExp(`<input type="hidden" name="action" value="retry"><input type="hidden" name="id" value="${id}"><input type="hidden" name="back" value="state=failed&amp;kind=twice"><button>Retry</button>`));
	const one = await (await page(`?state=failed&kind=twice&id=${id}`)).text();
	assert.match(one, new RegExp(`<p class="eyebrow">Job #${id}</p><h2 id="job-title"><code>twice</code></h2>`), "in a drawer over the list");
	assert.match(one, /<a class="icon-btn" href="\/admin\/jobs\?state=failed&amp;kind=twice" data-close/, "closed back to the list");
	assert.match(one, /<dt>Tried<\/dt><dd>2 of 2 times<\/dd>/);
	assert.match(one, new RegExp(`<h3>Input <small>JSON</small></h3><pre class="json">\\{\n  <span class="j-key">&quot;run&quot;</span>: <span class="j-str">&quot;${run}twice&quot;</span>\n\\}</pre>`));
	assert.match(one, new RegExp(`<h3>Last error</h3><pre class="problem">fails every time \\(${run}twice\\)</pre>`));
	assert.equal((await page("?id=999999999")).status, 404, "a job that isn't there");

	// Retry: back where it was, and it runs again (and fails again, twice).
	const retried = await form({ action: "retry", id, back: "state=failed&kind=twice" });
	assert.equal(retried.status, 303);
	assert.equal(retried.headers.get("location"), "/admin/jobs?state=failed&kind=twice");
	const forGood = () => server.logged().split(`twice #${id} failed for good after 2 attempts`).length - 1;
	assert.equal(await until(() => forGood() === 2), true, "tried twice more, then failed for good again");
	assert.equal(await text(`/jobs/get?id=${id}`), `${id} twice failed 2/2 - fails every time (${run}twice)`);
	const again = await form({ action: "retry", id: "999999999" });
	assert.equal(again.status, 404);
	const done = (await jobRows("state=done&kind=note&limit=1"))[0];
	const refused = await form({ action: "retry", id: String(done.id) });
	assert.equal(refused.status, 409);
	assert.match(await refused.text(), new RegExp(`job #${done.id} is done: it can&#39;t be retried`));

	// Cancel, and run now.
	assert.equal(await post(`/jobs/keyed?run=${run}page&key=${run}page1&in=60000`, "canceled"), "queued");
	assert.equal(await post(`/jobs/keyed?run=${run}page&key=${run}page2&in=60000`, "run now"), "queued");
	const [second, first] = await jobRows(`state=queued&kind=note&limit=2`);
	assert.deepEqual([first.key, second.key], [`${run}page1`, `${run}page2`]);
	const queuedPage = await (await page("?state=queued")).text();
	assert.match(queuedPage, new RegExp(`name="id" value="${second.id}"><input type="hidden" name="back" value="state=queued"><button>Run now</button>`));
	assert.equal((await form({ action: "cancel", id: String(first.id), back: "state=queued" })).headers.get("location"), "/admin/jobs?state=queued");
	assert.equal(await text(`/jobs/get?id=${first.id}`), `${first.id} note canceled 0/5 ${run}page1 -`);
	assert.equal((await form({ action: "run_now", id: String(second.id) })).headers.get("location"), "/admin/jobs");
	assert.equal(await until(() => text(`/jobs/log?run=${run}page`)), `note: ${run}page run now`);

	// A schedule's job, now.
	const ticksBefore = (await jobRows("kind=tick")).filter((row) => row.key === "-").length;
	assert.equal((await form({ action: "run_schedule", name: "tick * * * * * *" })).status, 303);
	assert.equal((await jobRows("kind=tick")).filter((row) => row.key === "-").length, ticksBefore + 1, "queued, with no key");
	assert.equal((await form({ action: "run_schedule", name: "nope" })).status, 409);

	// Another site's page can't post to it, whatever the app's guard lets through.
	assert.equal((await form({ action: "retry", id }, { origin: "https://evil.example" })).status, 403);

	// Its stream says when something changed.
	const gone = new AbortController();
	const response = await get("/admin/jobs?events=1", { headers: { ...admin, accept: "text/event-stream" }, signal: gone.signal });
	assert.equal(response.headers.get("content-type"), "text/event-stream");
	const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
	await new Promise((resolve) => setTimeout(resolve, 100));
	assert.equal(await post(`/jobs/note?run=${run}stream`, "x"), "queued");
	const { value } = await reader.read();
	assert.ok(value === "data: changed\n\n" || value === "data: quiet\n\n", value);
	gone.abort();
});

test("the jobs page's guard refuses whom it refuses, whatever they ask for: GET, its stream, a form; its answer is the guard's own", { skip }, async () => {
	for (const [path, init] of [
		["/admin/jobs", {}],
		["/admin/jobs?events=1", { headers: { accept: "text/event-stream" } }],
		["/admin/jobs?id=1", {}],
		["/admin/jobs", { method: "POST", body: "action=retry&id=1", headers: { "content-type": "application/x-www-form-urlencoded" } }],
	]) {
		const refused = await get(path, { ...init, redirect: "manual" });
		assert.equal(refused.status, 403, `${init.method ?? "GET"} ${path}`);
		assert.match(await refused.text(), /admins only/, "the guard's answer, not the page's");
	}
	assert.equal((await get("/admin/jobs", { method: "PUT" })).status, 403, "every method at its path is the plugin's, behind the guard");
	assert.equal((await get("/admin/jobs", { method: "PUT", headers: { "x-admin": "yes" } })).status, 405, "and the page answers GET and POST");
});

test("the jobs page mounted by the app itself (JobsPage.respond!), at its own path, behind its own guard", { skip: skipDb }, async () => {
	assert.equal((await get("/admin/mounted")).status, 403);
	const mounted = await get("/admin/mounted?state=failed", { headers: { "x-admin": "yes" } });
	assert.equal(mounted.status, 200);
	const html = await mounted.text();
	assert.match(html, /<div class="shell" data-events="\/admin\/mounted\?events=1" data-now="\d+">/);
	assert.doesNotMatch(html, /class="back"/, "no link back unless the app gives one");
});

test("JobsPage.plugin without a guard doesn't compile: the record is missing the field guard (the hint lists the fields left out, defaulted ones too)", { skip }, () => {
	const at = join(root, "server", "test", "build", "guardless");
	mkdirSync(at, { recursive: true });
	writeFileSync(
		join(at, "main.roc"),
		'app [program] { pf: platform "../../../platform/main.roc", admin: "../../../../packages/admin/main.roc" }\n\nimport pf.Plugin\nimport pf.Server\nimport admin.JobsPage\n\nprogram = {\n\trespond!: |_, _, _, _, _| Server.response(200, [], ""),\n\tmigrations: [],\n\tactors: [],\n\tlogs: { format: Auto },\n\tplugins: [Plugin.running(JobsPage.plugin({ at: "/admin/jobs" }))],\n\troutes: [],\n}\n',
	);
	const checked = spawnSync(roc(), ["check", join(at, "main.roc")], { encoding: "utf8" });
	assert.notEqual(checked.status, 0);
	assert.match(checked.stdout + checked.stderr, /This record is missing these fields:\n - back\n - guard\n/);
});

// ---- Email ----

test("email: without an SMTP server, kept in the outbox and logged", { skip }, async () => {
	// A server of its own, with no SMTP server (and no database: it needs none).
	const plain = await start();
	try {
		assert.equal(await plain.text(`/mail?to=ada@example.com&run=${run}`, { method: "POST", body: "Hi there" }), "sent");
		const outbox = JSON.parse(await plain.text("/__rocx/mail"));
		const { id, at, raw, ...kept } = outbox.at(-1);
		assert.deepEqual(kept, { from: "rocx <rocx@localhost>", to: "ada@example.com", subject: `Hello ${run}`, text: "Hi there", html: "<p>Hi there</p>" });
		assert.ok(id >= 1 && Math.abs(at - Date.now()) < 60_000, "an id, and when");
		assert.match(raw, new RegExp(`^Subject: Hello ${run}\r$`, "m"), "the message as SMTP would carry it");
		assert.deepEqual(JSON.parse(await plain.text("/__rocx/mail.json")), outbox);
		await logs(new RegExp(`email \\(kept, not sent: no SMTP_URL\\): to ada@example.com: Hello ${run}`), plain);
		const refused = await plain.get("/mail?to=not-an-address", { method: "POST", body: "x" });
		assert.equal(refused.status, 500);
		assert.match(await refused.text(), /^to not-an-address: /);
	} finally {
		await plain.stop();
	}
});

/** An SMTP server that takes every message and keeps it: just enough of the protocol. */
async function smtpServer() {
	const received = [];
	const server = createServer((socket) => {
		socket.setEncoding("utf8");
		let buffered = "";
		let data = null;
		let envelope = { from: "", to: [] };
		socket.write("220 rocx-test ESMTP\r\n");
		socket.on("data", (chunk) => {
			buffered += chunk;
			for (;;) {
				if (data !== null) {
					const end = buffered.indexOf("\r\n.\r\n");
					if (end < 0) return;
					data += buffered.slice(0, end);
					buffered = buffered.slice(end + 5);
					received.push({ ...envelope, data });
					data = null;
					envelope = { from: "", to: [] };
					socket.write("250 queued\r\n");
					continue;
				}
				const end = buffered.indexOf("\r\n");
				if (end < 0) return;
				const line = buffered.slice(0, end);
				buffered = buffered.slice(end + 2);
				const verb = line.slice(0, 4).toUpperCase();
				if (verb === "EHLO" || verb === "HELO") socket.write("250-rocx-test\r\n250 8BITMIME\r\n");
				else if (verb === "MAIL") (envelope.from = line), socket.write("250 ok\r\n");
				else if (verb === "RCPT") envelope.to.push(line), socket.write("250 ok\r\n");
				else if (verb === "DATA") (data = ""), socket.write("354 go on\r\n");
				else if (verb === "QUIT") socket.end("221 bye\r\n");
				else socket.write("250 ok\r\n");
			}
		});
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	return { port: server.address().port, received, close: () => new Promise((resolve) => server.close(resolve)) };
}

test("email: over SMTP, from a request and from a job, as text and HTML", { skip }, async () => {
	const before = smtp.received.length;
	assert.equal(await post(`/mail?to=grace@example.com&run=${run}`, "Hello & welcome"), "sent");
	assert.equal(smtp.received.length, before + 1);
	const sent = smtp.received.at(-1);
	assert.equal(sent.from, "MAIL FROM:<tests@rocx.example>");
	assert.deepEqual(sent.to, ["RCPT TO:<grace@example.com>"]);
	assert.match(sent.data, /^From: "Rocx Tests" <tests@rocx\.example>\r$/m);
	assert.match(sent.data, /^To: grace@example\.com\r$/m);
	assert.match(sent.data, new RegExp(`^Subject: Hello ${run}\\r$`, "m"));
	assert.match(sent.data, /^Date: \w{3}, \d{1,2} \w{3} \d{4} \d\d:\d\d:\d\d \+0000\r$/m);
	assert.match(sent.data, /^Message-ID: <[0-9a-f.]+@rocx>\r$/m);
	assert.match(sent.data, /Content-Type: multipart\/alternative/);
	assert.match(sent.data, /Hello & welcome/);
	assert.match(sent.data, /<p>Hello & welcome<\/p>/);
	if (database) {
		assert.equal(await post(`/jobs/mail?to=lin@example.com&run=${run}mail`), "queued");
		assert.equal(await until(() => smtp.received.some((mail) => mail.data.includes(`From a job ${run}mail`))), true, "the job sent it");
		const fromJob = smtp.received.find((mail) => mail.data.includes(`From a job ${run}mail`));
		assert.match(fromJob.data, new RegExp(`^Subject: From a job ${run}mail\\r$`, "m"));
		assert.match(fromJob.data, /Content-Type: text\/plain/);
	}
	// (A server with no SMTP server keeps what it sends in its own mailbox; this one sent it.)
	const kept = JSON.parse(await text("/__rocx/mail")).filter((mail) => mail.to === "grace@example.com" || mail.to === "lin@example.com");
	assert.equal(kept.length, 0, "nothing kept: it was sent");
	// A subject and a body that aren't ASCII: an encoded word, and base64.
	assert.equal(await post(`/mail?to=grace@example.com&run=zażółć${run}`, "Grüße"), "sent");
	const encoded = smtp.received.at(-1).data;
	assert.match(encoded, /^Subject: =\?utf-8\?b\?[A-Za-z0-9+\/=]+\?=\r$/m);
	assert.match(encoded, /Content-Transfer-Encoding: base64/);
	// An SMTP server that isn't there is an error, not a crash.
	const nowhere = await start([], app, { SMTP_URL: "smtp://127.0.0.1:9" });
	try {
		const failed = await nowhere.get("/mail?to=ada@example.com", { method: "POST", body: "x" });
		assert.equal(failed.status, 500);
		assert.match(await failed.text(), /^email to ada@example\.com: /);
	} finally {
		await nowhere.stop();
	}
});

test("the dev mailbox: under --dev, each email kept is a page (headers, text, its HTML sandboxed, the raw message), in memory: gone after a restart; not without --dev", { skip }, async () => {
	// A server with no SMTP server, under --dev: database or not, its mail is in its memory (Kv).
	const flags = ["--dev"];
	let dev = await start(flags);
	try {
		assert.equal(await dev.text(`/mail?to=ada@example.com&run=${run}box`, { method: "POST", body: "Hi <b>there</b>" }), "sent");
		const listed = await dev.get("/__rocx/mail", { headers: { accept: "text/html" } });
		assert.equal(listed.headers.get("content-type"), "text/html; charset=utf-8");
		const list = await listed.text();
		const [, id] = new RegExp(`<a class="row-link" href="/__rocx/mail/(\\d+)"><strong>Hello ${run}box</strong></a>`).exec(list) ?? [];
		assert.ok(id, list);
		assert.match(list, /<td>rocx &lt;rocx@localhost&gt;<\/td><td>ada@example\.com<\/td>/);
		assert.match(list, /data-events="\/__rocx\/mail\?events"/);
		assert.match(list, /kept rather than sent/);
		const json = await dev.get("/__rocx/mail", { headers: { accept: "application/json" } });
		assert.equal(json.headers.get("content-type"), "application/json");
		assert.ok((await json.json()).some((mail) => mail.subject === `Hello ${run}box`));

		const message = await (await dev.get(`/__rocx/mail/${id}`)).text();
		assert.match(message, new RegExp(`<h1>Hello ${run}box</h1>`));
		assert.match(message, /<dt>To<\/dt><dd>ada@example\.com<\/dd>/);
		assert.match(message, /<iframe sandbox="allow-popups allow-popups-to-escape-sandbox" referrerpolicy="no-referrer" srcdoc="&lt;base target=&quot;_blank&quot;&gt;&lt;p&gt;Hi &lt;b&gt;there&lt;\/b&gt;&lt;\/p&gt;"><\/iframe>/, "its HTML, escaped into a sandboxed frame");
		assert.match(message, /<h2>Text<\/h2><pre>Hi &lt;b&gt;there&lt;\/b&gt;<\/pre>/);
		assert.match(message, new RegExp(`<pre>Date: .+\\r\\nFrom: &quot;rocx&quot; &lt;rocx@localhost&gt;\\r\\nTo: ada@example.com\\r\\nSubject: Hello ${run}box\\r\\n`), "the raw message");
		assert.doesNotMatch(message, /<b>there/, "nothing of the email's is markup on the page");
		assert.equal((await dev.get("/__rocx/mail/999999999")).status, 404);

		// Its stream says when mail comes.
		const gone = new AbortController();
		const response = await dev.get("/__rocx/mail?events", { headers: { accept: "text/event-stream" }, signal: gone.signal });
		const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
		await new Promise((resolve) => setTimeout(resolve, 100));
		assert.equal(await dev.text(`/mail?to=grace@example.com&run=${run}box2`, { method: "POST", body: "again" }), "sent");
		assert.equal((await reader.read()).value, "data: changed\n\n");
		gone.abort();

		// Cleared.
		const cleared = await dev.get("/__rocx/mail/clear", { method: "POST", redirect: "manual" });
		assert.equal(cleared.status, 303);
		assert.equal(cleared.headers.get("location"), "/__rocx/mail");
		assert.match(await dev.text("/__rocx/mail"), /No mail yet/);
		assert.equal((await dev.get("/__rocx/mail/clear", { method: "POST", headers: { origin: "https://evil.example" } })).status, 403);

		// Kept in memory: a restart forgets it.
		assert.equal(await dev.text(`/mail?to=ada@example.com&run=${run}box3`, { method: "POST", body: "once more" }), "sent");
		await dev.stop();
		dev = await start(flags);
		assert.match(await dev.text("/__rocx/mail"), /No mail yet/);
	} finally {
		await dev.stop();
	}

	// With neither --dev nor --debug, the app answers those paths; with --debug alone, only the JSON.
	const plain = await start([], app, {}, { debug: false });
	try {
		for (const path of ["/__rocx/mail", "/__rocx/mail.json", `/__rocx/mail/1`]) {
			const answer = await plain.get(path);
			assert.equal(answer.status, 404, path);
			assert.equal(await answer.text(), `No page at ${path}.`);
		}
	} finally {
		await plain.stop();
	}
	const debug = await start([]);
	try {
		const answer = await debug.get("/__rocx/mail", { headers: { accept: "text/html" } });
		assert.equal(answer.headers.get("content-type"), "application/json");
		assert.equal((await debug.get("/__rocx/mail/1")).status, 404);
	} finally {
		await debug.stop();
	}
});

test("what was a flag of the server's and is a plugin's now is refused, saying where it went: jobs' workers and retries, email's SMTP server and sender", { skip }, async () => {
	for (const [flag, value, said] of [
		["--job-workers", "2", /--job-workers is gone: jobs are a plugin \(packages\/jobs, D-034\)/],
		["--job-retry-ms", "20", /--job-retry-ms is gone: jobs are a plugin/],
		["--smtp-url", "smtp://127.0.0.1:9", /--smtp-url is gone: email is a plugin \(packages\/email, D-035\), which reads SMTP_URL and MAIL_FROM/],
		["--mail-from", "a@b.example", /--mail-from is gone: email is a plugin/],
	]) {
		const refused = await start([flag, value]).then(
			() => assert.fail(`${flag} was taken`),
			(error) => error.message,
		);
		assert.match(refused, said, flag);
	}
});

// ---- Plugins: what a package adds to an app (server/test/fixture) ----

test("plugins: a plugin's route answers in the app, with the app's context and its own pattern as the route; its call runs in a call of its own, a crash ending only that; its loop ran, its start kept, its check logged; the log says what each added, in the order their needs put them", { skip }, async () => {
	assert.equal(await text("/fixture/context"), "/fixture/context: the app's context, facts=yes");
	assert.equal(await text("/fixture/notes/42"), "note 42 at /fixture/notes/[id]");
	assert.equal((await server.get("/fixture/context", { method: "HEAD" })).status, 200, "GET answers HEAD");
	assert.equal(await text("/fixture/shout?word=quiet"), "QUIET");
	const crashed = await server.get("/fixture/shout?word=crash");
	assert.equal(crashed.status, 500);
	assert.equal(await crashed.text(), "crashed: the fixture's call crashed");
	assert.equal(await text("/fixture/shout?word=again"), "AGAIN", "the server goes on");
	assert.equal(await text("/fixture/state"), "started, 1 beat");
	assert.equal(await text("/second"), "second");
	assert.equal(await text("/third", { method: "POST" }), "third POST", "a route for every method");
	assert.equal(await text("/"), "Hello from Roc, natively.", "the app's own routes, after the plugins'");
	const said = events().map((event) => event.msg);
	assert.deepEqual(
		said.filter((msg) => msg.startsWith("rocx plugins:")),
		[
			"rocx plugins: jobs: 1 migration, 1 call, 5 loops, 1 start",
			"rocx plugins: email: 4 early routes, 1 start, 1 check",
			"rocx plugins: jobs-page: 1 route",
			"rocx plugins: fixture: 5 routes, 1 early route, 1 migration, 1 call, 1 loop, 1 start, 1 check",
			"rocx plugins: second: 1 route",
			"rocx plugins: third: 1 route",
		],
		"listed jobs, email, the jobs page, fixture, third, second: third needs second, so it comes after it",
	);
	assert.ok(said.includes("fixture.look: the fixture looked"), "the check, run once after the start");
});

test("plugins: an early path is answered before the app, only under the flag it names (--dev)", { skip }, async () => {
	const answer = await server.get("/__rocx/fixture");
	assert.equal(answer.status, 404, "without --dev, the path is the app's");
	assert.equal(await answer.text(), "No page at /__rocx/fixture.");
	const dev = await start(["--dev"]);
	try {
		assert.equal(await dev.text("/__rocx/fixture"), "early /__rocx/fixture");
	} finally {
		await dev.stop();
	}
});

test("plugins: a plugin's table, applied after the platform's and before the app's, recorded under the plugin's name", { skip: skipDb }, async () => {
	assert.equal(await text("/fixture/migrated"), "fixture/0001_notes");
	const order = events()
		.map((event) => event.msg)
		.filter((msg) => msg.startsWith("rocx server: migrated:"));
	if (order.length > 0) {
		// A fresh database: the first start applied them all, in order.
		const at = (name) => order.findIndex((msg) => msg.endsWith(name));
		assert.ok(at("rocx/0001 jobs and actors") < at("fixture/0001_notes") && at("fixture/0001_notes") < at("0001_tables.sql"), order.join("\n"));
	}
});

test("plugins: what stops the server at start, every problem a line: a route the app has, two plugins at one path, a loop without the plugin's name first, an early path outside /__rocx/, a variable unset, a plugin not in the list, needs in a circle, a name twice, a name that isn't one", { skip }, async () => {
	const executable = join(dir, "refused");
	buildApp(join(root, "server", "test", "refused", "main.roc"), executable, { opt: process.env.ROCX_TEST_OPT ?? "dev" });
	const refused = await start([], executable, { REFUSED_UNSET: "" }).then(
		() => assert.fail("it started"),
		(error) => error.message,
	);
	const line = refused.split("\n").find((each) => each.includes("can't start"));
	assert.ok(line, refused);
	assert.equal(
		JSON.parse(line).error,
		[
			"clash: the loop beat is named clash.beat, with the plugin's name first",
			"clash: the early path /mail is under /__rocx/, where the app's paths never are",
			"auth needs the email plugin, which isn't in plugins",
			"two plugins are called two",
			"plugin \"Bad Name\": a plugin's name is lowercase letters, digits and -",
			"GET /x: routes/x/+page.rocx, and the clash plugin",
			"POST /y/[id]: the one plugin, and the two plugin",
			"left needs right, which needs left",
			"one: REFUSED_UNSET isn't set",
		].join("\n"),
	);
});

// ---- TCP ----

test("tcp: a connection to another server, a line and exactly so many bytes each way; one left open is closed when its call ends", { skip }, async () => {
	const closed = [];
	const tcpServer = createServer((socket) => {
		socket.setEncoding("utf8");
		let buffered = "";
		socket.on("data", (chunk) => {
			buffered += chunk;
			const end = buffered.indexOf("\n");
			if (end >= 0 && buffered.startsWith("left open")) return;
			if (end >= 0) socket.write(`${buffered.slice(0, end).toUpperCase()}\nend`);
		});
		socket.on("close", () => closed.push(buffered));
	});
	await new Promise((resolve) => tcpServer.listen(0, "127.0.0.1", resolve));
	const port = tcpServer.address().port;
	try {
		assert.equal(await post(`/tcp?port=${port}`, "hello, server"), "HELLO, SERVER end");
		assert.equal(await post(`/tcp-left-open?port=${port}`), "written");
		assert.equal(await until(() => closed.some((said) => said.startsWith("left open"))), true, "closed when the request's call ended");
		const refused = await get("/tcp?port=9", { method: "POST", body: "x" });
		assert.equal(refused.status, 500);
		assert.match(await refused.text(), /^127\.0\.0\.1:9: /, "a server that isn't there is an error");
	} finally {
		await new Promise((resolve) => tcpServer.close(resolve));
	}
});

// ---- HTTP: requests to other servers ----

/** An HTTP server for the app to ask: what it was asked, bytes, redirects, a slow answer, large
 * ones. `https` with a self-signed certificate (`tls`: its key and certificate). */
async function httpServer(tls) {
	const answer = async (request, response) => {
		const chunks = [];
		for await (const chunk of request) chunks.push(chunk);
		const body = Buffer.concat(chunks);
		const { pathname, searchParams } = new URL(request.url, "http://x");
		const redirect = (status, location) => ((response.statusCode = status), response.setHeader("location", location), response.end());
		response.setHeader("x-from", "node");
		if (pathname === "/hello") return response.end("hello");
		if (pathname === "/missing") return (response.statusCode = 404), response.end("not here");
		if (pathname === "/echo") return response.end(JSON.stringify({ method: request.method, url: request.url, headers: request.headers, raw: request.rawHeaders, body: body.toString() }));
		if (pathname === "/json") return response.setHeader("content-type", "application/json"), response.end('{"tomorrow":"sunny","high":21}');
		if (pathname === "/json-wrong") return response.setHeader("content-type", "application/json"), response.end('{"tomorrow":"sunny","high":"warm"}');
		if (pathname === "/bytes") return response.end(Buffer.concat([body, Buffer.from([0, 255])]));
		if (pathname === "/redirect") return redirect(302, "chain/one");
		if (pathname === "/chain/one") return redirect(301, "/hello");
		if (pathname === "/see-other") return redirect(303, "/echo");
		if (pathname === "/away") return redirect(302, searchParams.get("to"));
		if (pathname === "/loop") return redirect(302, "/loop");
		if (pathname === "/slow") return void setTimeout(() => response.end("late"), 3000);
		if (pathname === "/big") return response.end("x".repeat(1000));
		if (pathname === "/big-chunked") {
			for (let i = 0; i < 10; i++) response.write("y".repeat(100));
			return response.end();
		}
		response.statusCode = 500;
		response.end(`nothing at ${pathname}`);
	};
	const server = tls ? createHttpsServer(tls, answer) : createHttpServer(answer);
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	return {
		url: `${tls ? "https" : "http"}://127.0.0.1:${server.address().port}`,
		close: () => new Promise((resolve) => (server.closeAllConnections(), server.close(resolve))),
	};
}

/** A self-signed certificate, made with openssl (none if there's no openssl). */
function selfSigned() {
	const [key, cert] = [join(dir, "tls-key.pem"), join(dir, "tls-cert.pem")];
	const made = spawnSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1"], { stdio: "ignore" });
	return made.status === 0 ? { key: readFileSync(key), cert: readFileSync(cert) } : null;
}

/** The app asks `url` with `Http.fetch!` (`/http`, with `options`: method, send, type, query, timeout,
 * max, follow): its answer's status, its `location` and `x-from`, and its body; or why there was none.
 * `route` asks through another route of the app's: `/http/old`, the deprecated API's. */
const ask = (url, options = {}, body, route = "/http") => {
	const query = new URLSearchParams({ url, ...options });
	return get(`${route}?${query}`, { method: "POST", body });
};

/** What `/echo` saw of a request the app made (`ask`'s answer, after its first line). */
const echoed = async (answer) => JSON.parse((await answer.text()).split("\n").slice(1).join("\n"));

test("http: a GET and a POST to another server, any status an answer, bytes each way", { skip }, async () => {
	const node = await httpServer();
	try {
		assert.equal(await (await ask(`${node.url}/hello`)).text(), "200 - node\nhello");
		assert.equal(await (await ask(`${node.url}/missing`)).text(), "404 - node\nnot here", "a 404 is an answer");
		const posted = await ask(`${node.url}/echo`, { method: "POST", send: "json" });
		assert.equal(posted.status, 200);
		const seen = await echoed(posted);
		assert.equal(seen.method, "POST");
		assert.equal(seen.body, '{"a":1}');
		assert.equal(seen.headers["content-type"], "application/json");
		assert.equal(seen.headers["content-length"], "7");
		assert.equal(seen.headers["x-rocx"], "yes");
		assert.equal(seen.headers.authorization, "Bearer sesame");
		assert.equal(seen.headers.host, node.url.replace("http://", ""));
		for (const method of ["PUT", "PATCH", "DELETE", "OPTIONS", "PURGE"]) {
			assert.equal((await echoed(await ask(`${node.url}/echo`, { method }))).method, method, `${method}, as written`);
		}
		assert.equal(await post(`/http/bytes?url=${encodeURIComponent(`${node.url}/bytes`)}`), "0,255,13,10,128,0,255", "bytes sent and read as they are");
		const nowhere = await ask("http://127.0.0.1:9/");
		assert.equal(nowhere.status, 502);
		assert.match(await nowhere.text(), /^no answer: 127\.0\.0\.1:9: /, "a server that isn't there: no answer");
		assert.equal(await (await ask("ftp://example.com/")).text(), "no answer: ftp://example.com/: only http and https URLs");
	} finally {
		await node.close();
	}
});

test("http: fetch!(url, {}) is a GET with no body, redirects followed; ok is a 2xx", { skip }, async () => {
	const node = await httpServer();
	try {
		const seen = JSON.parse((await post(`/http/plain?url=${encodeURIComponent(`${node.url}/echo`)}`)).split("\n").slice(1).join("\n"));
		assert.equal(seen.method, "GET");
		assert.equal(seen.url, "/echo", "no query added");
		assert.equal(seen.body, "");
		assert.equal(seen.headers["content-type"], undefined, "no body, no content-type");
		assert.deepEqual(Object.keys(seen.headers).sort(), ["host"], "nothing but the host");
		assert.equal(await post(`/http/plain?url=${encodeURIComponent(`${node.url}/redirect`)}`), "200 ok\nhello", "a redirect followed, two of them");
		assert.equal(await post(`/http/plain?url=${encodeURIComponent(`${node.url}/missing`)}`), "404 not ok\nnot here", "a 404 is an answer, not ok");
		assert.equal(await post(`/http/plain?url=${encodeURIComponent(`${node.url}/nothing`)}`), "500 not ok\nnothing at /nothing");
		assert.equal(await post(`/http/plain?url=${encodeURIComponent(`${node.url}/big`)}`), `200 ok\n${"x".repeat(1000)}`, "within the default 64 MiB");
	} finally {
		await node.close();
	}
});

test("http: query pairs, percent-encoded, after a ? or after the URL's own query with an &", { skip }, async () => {
	const node = await httpServer();
	try {
		const pairs = "city=S%C3%A3o%20Paulo&a%26b=c%3Dd%20%E2%9C%93";
		assert.equal((await echoed(await ask(`${node.url}/echo`, { query: "yes" }))).url, `/echo?${pairs}`);
		assert.equal((await echoed(await ask(`${node.url}/echo?x=1`, { query: "yes" }))).url, `/echo?x=1&${pairs}`, "the URL's query kept, the pairs after an &");
		assert.equal((await echoed(await ask(`${node.url}/echo?`, { query: "yes" }))).url, `/echo?${pairs}`, "a URL ending in ? takes the pairs as they are");
		const read = Object.fromEntries(new URL(`http://x${(await echoed(await ask(`${node.url}/echo?x=1`, { query: "yes" }))).url}`).searchParams);
		assert.deepEqual(read, { x: "1", city: "São Paulo", "a&b": "c=d ✓" }, "read back as they were given");
	} finally {
		await node.close();
	}
});

test("http: each body's content-type, and a content-type header that overrides it", { skip }, async () => {
	const node = await httpServer();
	try {
		const json = await echoed(await ask(`${node.url}/echo`, { method: "POST", send: "json" }));
		assert.equal(json.headers["content-type"], "application/json");
		assert.equal(json.body, '{"a":1}');
		const form = await echoed(await ask(`${node.url}/echo`, { method: "POST", send: "form" }));
		assert.equal(form.headers["content-type"], "application/x-www-form-urlencoded");
		assert.deepEqual(Object.fromEntries(new URLSearchParams(form.body)), { name: "Ada Lovelace", says: "a&b=c ✓" });
		const text = await echoed(await ask(`${node.url}/echo`, { method: "POST", send: "text" }, "héllo ✓"));
		assert.equal(text.headers["content-type"], "text/plain; charset=utf-8");
		assert.equal(text.body, "héllo ✓");
		assert.equal(text.headers["content-length"], String(Buffer.byteLength("héllo ✓")));
		const bytes = await echoed(await ask(`${node.url}/echo`, { method: "POST", send: "bytes" }));
		assert.equal(bytes.headers["content-type"], undefined, "bytes: no content-type, as fetch sends a Uint8Array");
		assert.equal(bytes.headers["content-length"], "5");
		const given = await echoed(await ask(`${node.url}/echo`, { method: "POST", send: "json", type: "application/merge-patch+json" }));
		assert.equal(given.headers["content-type"], "application/merge-patch+json", "a content-type given wins, in any case");
		const types = given.raw.filter((name, i) => i % 2 === 0 && name.toLowerCase() === "content-type");
		assert.equal(types.length, 1, "and is the only one sent");
		assert.equal(given.body, '{"a":1}');
	} finally {
		await node.close();
	}
});

test("http: res.json() reads a body as a type, and is an error when it isn't that", { skip }, async () => {
	const node = await httpServer();
	try {
		assert.equal(await post(`/http/json?url=${encodeURIComponent(`${node.url}/json`)}`), "sunny 21");
		assert.match(await post(`/http/json?url=${encodeURIComponent(`${node.url}/json-wrong`)}`), /^not JSON of that shape: /, "a field of another type");
		assert.match(await post(`/http/json?url=${encodeURIComponent(`${node.url}/hello`)}`), /^not JSON of that shape: /, "not JSON at all");
		assert.equal(await post("/http/json?url=http%3A%2F%2F127.0.0.1%3A9%2F"), "no answer");
	} finally {
		await node.close();
	}
});

test("http: the deprecated API (send!, send_request!, get, post_json, post_form, with_header, header, text) still answers", { skip }, async () => {
	const node = await httpServer();
	const old = (url, options = {}, body) => ask(url, options, body, "/http/old");
	try {
		assert.equal(await (await old(`${node.url}/hello`)).text(), "200 - node\nhello");
		assert.equal(await (await old(`${node.url}/missing`)).text(), "404 - node\nnot here");
		const seen = await echoed(await old(`${node.url}/echo`, { method: "POST" }, '{"a":1}'));
		assert.equal(seen.method, "POST");
		assert.equal(seen.body, '{"a":1}');
		assert.equal(seen.headers["content-type"], "application/json");
		assert.equal(seen.headers["x-rocx"], "yes");
		assert.equal(seen.headers.authorization, "Bearer sesame");
		assert.equal(await (await old(`${node.url}/redirect`)).text(), "200 - node\nhello", "redirects followed, as Http.defaults says");
		assert.equal(await (await old(`${node.url}/redirect`, { follow: "no" })).text(), "302 chain/one node\n", "or not");
		assert.equal(await (await old(`${node.url}/slow`, { timeout: 200 })).text(), "timed out");
		assert.equal(await (await old(`${node.url}/big`, { max: 500 })).text(), "too large");
		assert.equal(await (await old(`${node.url}/big`, { max: 500, method: "HEAD" })).text(), "200 - node\n");
		const form = JSON.parse((await post(`/http/old/form?url=${encodeURIComponent(`${node.url}/echo`)}`)).split("\n").slice(1).join("\n"));
		assert.equal(form.headers["content-type"], "application/x-www-form-urlencoded");
		assert.deepEqual(Object.fromEntries(new URLSearchParams(form.body)), { name: "Ada Lovelace", says: "a&b=c ✓" });
		assert.equal(await post(`/http/old/bytes?url=${encodeURIComponent(`${node.url}/bytes`)}`), "0,255,13,10,128,0,255");
		assert.match(await (await old("http://127.0.0.1:9/")).text(), /^no answer: 127\.0\.0\.1:9: /);
	} finally {
		await node.close();
	}
});

test("http: redirects followed (relative ones, a 303 as a GET, no credentials to another origin) or not; a loop ends", { skip }, async () => {
	const [node, other] = await Promise.all([httpServer(), httpServer()]);
	try {
		assert.equal(await (await ask(`${node.url}/redirect`)).text(), "200 - node\nhello", "302 to a relative path, then 301 to an absolute one");
		assert.equal(await (await ask(`${node.url}/redirect`, { follow: "no" })).text(), "302 chain/one node\n", "not followed: the redirect is the answer");
		const seen = await echoed(await ask(`${node.url}/see-other`, { method: "POST", send: "json" }));
		assert.equal(seen.method, "GET", "a 303 after a POST is a GET");
		assert.equal(seen.body, "");
		assert.equal(seen.headers["content-type"], undefined, "without the body's headers");
		assert.equal(seen.headers.authorization, "Bearer sesame", "credentials go on to the same origin");
		const away = await echoed(await ask(`${node.url}/away?to=${encodeURIComponent(`${other.url}/echo`)}`));
		assert.equal(away.headers.host, other.url.replace("http://", ""));
		assert.equal(away.headers["x-rocx"], "yes");
		assert.equal(away.headers.authorization, undefined, "but not to another");
		const loop = await ask(`${node.url}/loop`);
		assert.equal(loop.status, 502);
		assert.match(await loop.text(), /more than 20 redirects/);
	} finally {
		await Promise.all([node.close(), other.close()]);
	}
});

test("http: a timeout, a body too large, TLS that fails: errors, not answers", { skip }, async () => {
	const tls = selfSigned();
	const [node, secure] = await Promise.all([httpServer(), tls && httpServer(tls)]);
	try {
		const started = performance.now();
		const slow = await ask(`${node.url}/slow`, { timeout: 200 });
		assert.equal(slow.status, 504);
		assert.equal(await slow.text(), "timed out");
		assert.ok(performance.now() - started < 2000, "given up after 200 ms, not after the 3 s it takes");
		assert.equal(await (await ask(`${node.url}/big`, { max: 500 })).text(), "too large", "its content-length says so");
		assert.equal(await (await ask(`${node.url}/big-chunked`, { max: 500 })).text(), "too large", "chunked: refused as it passes the limit");
		assert.equal(await (await ask(`${node.url}/big`, { max: 1000 })).text(), `200 - node\n${"x".repeat(1000)}`, "the limit itself fits");
		assert.equal(await (await ask(`${node.url}/big`, { max: 500, method: "HEAD" })).text(), "200 - node\n", "a HEAD's content-length is no body to refuse");
		const plain = await ask(node.url.replace("http:", "https:") + "/hello");
		assert.equal(plain.status, 502);
		assert.match(await plain.text(), /^no answer: TLS with 127\.0\.0\.1: /, "TLS to a server that doesn't speak it");
		if (secure) {
			const untrusted = await ask(`${secure.url}/hello`);
			assert.equal(untrusted.status, 502);
			assert.match(await untrusted.text(), /^no answer: TLS with 127\.0\.0\.1: invalid peer certificate: UnknownIssuer/, "a certificate no authority signed");
		}
		assert.equal(await text("/"), "Hello from Roc, natively.");
	} finally {
		await Promise.all([node.close(), secure?.close()]);
	}
});

test("http: a request over the internet, over TLS checked against the web's authorities", { skip: skipInternet }, async () => {
	const answer = await (await ask("https://example.com/")).text();
	assert.match(answer, /^200 /);
	assert.match(answer, /Example Domain/);
});

// ---- The environment, AES-GCM, random bytes ----

test("env: a variable read from a request, and whether the server runs under --dev", { skip }, async () => {
	assert.equal(await text("/env?name=ROCX_TEST_SETTING"), `found ${SETTING}`);
	assert.equal(await text("/env?name=ROCX_TEST_NOTHING"), "not found");
	assert.equal(await text("/env/dev"), "not dev");
	// A server of its own (with no database: its workers would take this file's jobs).
	const dev = await start(["--dev"]);
	try {
		assert.equal(await dev.text("/env/dev"), "dev");
	} finally {
		await dev.stop();
	}
});

test("env: a variable read from a job", { skip: skipDb }, async () => {
	const job = `${run}env`;
	assert.equal(await post(`/jobs/env?run=${job}&name=ROCX_TEST_SETTING`), "queued");
	assert.equal(await until(() => text(`/jobs/log?run=${job}`)), `env: ${job} ${SETTING}, not dev`);
});

test("aes-gcm: what Roc seals Node opens, and back; a wrong key, a change or a key not 32 bytes is refused", { skip }, async () => {
	const list = (bytes) => [...bytes].join(",");
	const key = randomBytes(32);
	const seal = (under, plaintext) => get(`/aes/seal?key=${list(under)}`, { method: "POST", body: plaintext });
	const open = async (under, sealed) => {
		const response = await get(`/aes/open?key=${list(under)}`, { method: "POST", body: list(sealed) });
		return `${response.status} ${await response.text()}`;
	};
	const sealed = Buffer.from((await (await seal(key, "a secret ✓")).text()).split(",").map(Number));
	assert.equal(sealed.length, 12 + Buffer.byteLength("a secret ✓") + 16, "the nonce, the ciphertext, the tag");
	const decipher = createDecipheriv("aes-256-gcm", key, sealed.subarray(0, 12));
	decipher.setAuthTag(sealed.subarray(-16));
	assert.equal(Buffer.concat([decipher.update(sealed.subarray(12, -16)), decipher.final()]).toString(), "a secret ✓", "Node opens it");
	assert.equal(await open(key, sealed), "200 a secret ✓", "and so does Roc");
	const again = Buffer.from((await (await seal(key, "a secret ✓")).text()).split(",").map(Number));
	assert.notDeepEqual(again, sealed, "a fresh nonce each time");

	const nonce = randomBytes(12);
	const cipher = createCipheriv("aes-256-gcm", key, nonce);
	const ciphertext = Buffer.concat([cipher.update("sealed by Node"), cipher.final()]);
	assert.equal(await open(key, Buffer.concat([nonce, ciphertext, cipher.getAuthTag()])), "200 sealed by Node");

	assert.equal(await open(randomBytes(32), sealed), "400 Forged", "another key");
	const changed = Buffer.from(sealed);
	changed[14] ^= 1;
	assert.equal(await open(key, changed), "400 Forged", "a byte changed");
	assert.equal(await open(key, sealed.subarray(0, 20)), "400 Forged", "too short to be sealed");
	assert.equal(await open(randomBytes(16), sealed), "400 BadKey");
	const short = await seal(randomBytes(16), "x");
	assert.equal(short.status, 400);
	assert.equal(await short.text(), "BadKey");
});

test("random: so many bytes from the operating system, different each time", { skip }, async () => {
	const bytes = async (count) => {
		const said = await text(`/random?count=${count}`);
		return said === "" ? [] : said.split(",").map(Number);
	};
	const [one, two] = await Promise.all([bytes(32), bytes(32)]);
	assert.equal(one.length, 32);
	assert.equal(two.length, 32);
	assert.notDeepEqual(one, two);
	assert.deepEqual(await bytes(0), []);
	const many = await bytes(4096);
	assert.equal(many.length, 4096);
	assert.ok(many.every((byte) => byte >= 0 && byte <= 255));
	assert.ok(new Set(many).size > 200, "spread over every value a byte has");
});

test("crypto in Roc, compiled: SHA-256, HMAC, HKDF, Base64 and Hex agree with Node's", { skip }, async () => {
	// Keys and bodies each side of SHA-256's 64-byte block.
	for (const [keyLength, body] of [[20, ""], [64, "abc"], [65, "zażółć ✓ ".repeat(7)], [131, "x".repeat(1000)]]) {
		const key = randomBytes(keyLength);
		const said = await text(`/crypto?key=${key.toString("hex")}`, { method: "POST", body });
		assert.deepEqual(
			said.split("\n"),
			[
				createHash("sha256").update(body).digest("hex"),
				createHmac("sha256", key).update(body).digest("hex"),
				Buffer.from(hkdfSync("sha256", key, "salt", "info", 42)).toString("hex"),
				Buffer.from(body).toString("base64"),
				Buffer.from(body).toString("base64url"),
				"decoded",
				"verified",
			],
			`a ${keyLength}-byte key, a ${Buffer.byteLength(body)}-byte body`,
		);
	}
});

// ---- Storage: S3 ----

/** A key of this run's own, `%`-encoded for the query. */
const keyed = (name) => encodeURIComponent(`${run}/${name}`);
/** The app's storage route `path`: its status and its text. */
const stored = async (path, init) => {
	const response = await get(path, init);
	return [response.status, await response.text()];
};
const md5 = (bytes) => createHash("md5").update(bytes).digest("hex");
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const MiB = 1 << 20;

test("samples: what the docs show (Samples.roc) runs as they say: settings, crypto, cookies, bytes, requests to other servers and forwards", { skip }, async () => {
	assert.equal(await text("/samples/origin"), "http://localhost:8080", "no ORIGIN: the default");
	const refused = await get("/samples/dev", { method: "POST", body: "ada", redirect: "manual" });
	assert.deepEqual([refused.status, await refused.text()], [404, "No page here."], "not under --dev");
	const [token, digest] = (await text("/samples/token?of=abc")).split(" ");
	assert.match(token, /^[A-Za-z0-9_-]{43}$/, "32 random bytes, URL-safe");
	assert.equal(digest, sha256(Buffer.from("abc")), "a token's digest");
	const until = 1_900_000_000_000;
	const link = await text(`/samples/link?member=ada&until=${until}`);
	assert.match(link, new RegExp(`^ada\\.${until}\\.[A-Za-z0-9_-]{43}$`));
	const check = async (at, now) => {
		const answer = await get(`/samples/link/check?link=${encodeURIComponent(at)}&now=${now}`);
		return [answer.status, await answer.text()];
	};
	assert.deepEqual(await check(link, until - 1), [200, "ada"]);
	assert.deepEqual(await check(link, until + 1), [410, "Expired"]);
	assert.deepEqual(await check(link.replace("ada.", "eve."), 0), [403, "BadLink"], "another member's name, under ada's signature");
	const kept = await post("/samples/seal", "an API token");
	assert.match(kept, /^[0-9a-f]+$/);
	assert.equal(kept.length, 2 * (12 + Buffer.byteLength("an API token") + 16), "nonce, ciphertext and tag, as hex");
	assert.notEqual(await post("/samples/seal", "an API token"), kept, "a fresh nonce each time");
	assert.equal(await post("/samples/unseal", kept), "an API token");
	assert.equal(await post("/samples/unseal", kept.replace(/.$/, (last) => (last === "0" ? "1" : "0"))), "Forged");
	const cookies = (await get("/samples/cookies")).headers.getSetCookie();
	assert.deepEqual(cookies, [
		"__Host-session=token; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax",
		`review=review; Path=/review; Expires=${new Date(1_795_000_000_000).toUTCString()}; HttpOnly; SameSite=Strict`,
		"__Host-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax",
	]);
	const bytes = Buffer.from([0, 255, 13, 10, 128]);
	assert.equal(await text("/samples/digest", { method: "POST", body: bytes }), sha256(bytes), "the bytes as they came");
	// Another server: a forecast asked with a token, an order sent as JSON and cancelled, a preview
	// not following a redirect, a file sent on.
	const asked = [];
	const other = createHttpServer(async (request, response) => {
		const chunks = [];
		for await (const chunk of request) chunks.push(chunk);
		const body = Buffer.concat(chunks).toString();
		asked.push({ method: request.method, url: request.url, authorization: request.headers.authorization, type: request.headers["content-type"], body });
		if (request.url.startsWith("/forecast?")) return response.writeHead(200, { "content-type": "application/json" }).end('{"tomorrow":"sunny"}');
		if (request.method === "POST" && request.url === "/shop/orders") return response.writeHead(201, { "content-type": "application/json" }).end('{"id":"o-17"}');
		if (request.method === "DELETE" && request.url === "/shop/orders/o-17") return response.writeHead(204).end();
		if (request.url === "/moved") return response.writeHead(302, { location: "/elsewhere" }).end();
		response.writeHead(404).end();
	});
	await new Promise((resolve) => other.listen(0, "127.0.0.1", resolve));
	const upstream = await upstreamServer();
	try {
		const api = `http://127.0.0.1:${other.address().port}`;
		assert.equal(await text(`/samples/forecast?api=${encodeURIComponent(api)}&city=${encodeURIComponent("São Paulo")}`), "sunny", "its JSON, read as a record");
		assert.deepEqual(asked.at(-1), { method: "GET", url: "/forecast?city=S%C3%A3o%20Paulo", authorization: "Bearer none", type: undefined, body: "" }, "the city in the URL's query, the token (none set) in a header");
		assert.equal(await text(`/samples/forecast?api=${encodeURIComponent(`${api}/nowhere`)}&city=x`), "refused: 404");
		assert.equal(await text(`/samples/forecast?api=${encodeURIComponent(`${api}/moved`)}&city=x`), "refused: 404", "a 404 at the end of a redirect followed");
		assert.equal(await post(`/samples/order?shop=${encodeURIComponent(`${api}/shop`)}&token=t0k`), "ordered and cancelled o-17");
		assert.deepEqual(asked.slice(-2), [
			{ method: "POST", url: "/shop/orders", authorization: "Bearer t0k", type: "application/json", body: '{"count":2,"item":"tea"}' },
			{ method: "DELETE", url: "/shop/orders/o-17", authorization: "Bearer t0k", type: undefined, body: "" },
		], "the order as JSON, then a DELETE with the same token (a record update of one Http.Init)");
		assert.equal(await post(`/samples/order?shop=${encodeURIComponent(`${api}/closed`)}&token=t0k`), "no order id", "a 404's body isn't an order's JSON");
		assert.equal(await text(`/samples/preview?url=${encodeURIComponent(`${api}/moved`)}`), "302 /elsewhere", "a redirect, the answer");
		const part = await get(`/samples/cdn?url=${encodeURIComponent(`${upstream.url}/file`)}`, { headers: { range: "bytes=10-19", cookie: "session=secret" } });
		assert.equal(part.status, 206, "the range, passed on");
		assert.deepEqual(Buffer.from(await part.arrayBuffer()), upstream.file.subarray(10, 20));
		assert.equal(part.headers.get("cache-control"), "public, max-age=86400");
		assert.equal(upstream.asked.at(-1).headers.cookie, undefined, "the request's cookies stay here");
	} finally {
		await new Promise((resolve) => (other.closeAllConnections(), other.close(resolve)));
		await upstream.close();
	}
});

test("samples: what the docs show of storage runs as they say: an avatar kept, described, taken; a video in parts; a link to upload with; a video served, in part or whole", { skip: skipStorage }, async () => {
	const member = `${run}-ada`;
	assert.deepEqual(await stored(`/samples/avatar?member=${member}`, { method: "PUT", body: "a picture", headers: { "content-type": "image/png" } }), [200, "saved"]);
	assert.deepEqual(await stored(`/samples/avatar?member=${member}`), [200, "9 bytes of image/png"]);
	assert.deepEqual(await stored(`/samples/avatar/take?member=${member}`, { method: "POST" }), [200, "a picture"]);
	assert.deepEqual(await stored(`/samples/avatar?member=${member}`), [404, "NotFound"], "taken: gone");
	const key = keyed("samples/clip.mp4");
	const clip = Buffer.from(Array.from({ length: 50_000 }, (_, i) => (i * 7) % 256));
	assert.deepEqual(await stored(`/samples/parts?key=${key}`, { method: "POST", body: clip }), [200, "saved"], "one part, the last, of any size");
	const partly = await get(`/samples/video?key=${key}`, { headers: { range: "bytes=100-199" } });
	assert.equal(partly.status, 206);
	assert.deepEqual(Buffer.from(await partly.arrayBuffer()), clip.subarray(100, 200));
	const whole = await get(`/samples/video/whole?key=${key}`, { headers: { range: "bytes=100-199" } });
	assert.equal(whole.status, 200, "the range dropped");
	assert.deepEqual(Buffer.from(await whole.arrayBuffer()), clip);
	const [status, url] = await stored(`/samples/upload-link?key=${keyed("samples/upload.txt")}`);
	assert.equal(status, 200, url);
	assert.equal((await fetch(url, { method: "PUT", body: "sent by the browser" })).status, 200, "uploaded straight to S3");
	assert.deepEqual(await stored(`/storage/get?key=${keyed("samples/upload.txt")}`), [200, "sent by the browser"]);
	for (const each of [key, keyed("samples/upload.txt")]) assert.deepEqual(await stored(`/storage/delete?key=${each}`, { method: "POST" }), [200, "deleted"]);
});

test("storage: an object kept, read whole, in part and described, replaced, and deleted", { skip: skipStorage }, async () => {
	assert.deepEqual(await stored("/storage/check"), [200, "S3 answers, and the bucket is there"]);
	const key = keyed("notes/a b+ł?.txt");
	const said = "Hello, storage ✓";
	const size = Buffer.byteLength(said);
	assert.deepEqual(await stored(`/storage/put?key=${key}&type=${encodeURIComponent("text/plain; charset=utf-8")}`, { method: "POST", body: said }), [200, "stored"]);
	assert.deepEqual(await stored(`/storage/get?key=${key}`), [200, said], "a key with a space, a plus, a question mark and a ł");
	assert.deepEqual(await stored(`/storage/head?key=${key}`), [200, `${size} text/plain; charset=utf-8 ${md5(said)}`], "its size, type and ETag");
	assert.deepEqual(await stored(`/storage/range?key=${key}&offset=7&length=7`), [200, `${size} storage`]);
	assert.deepEqual(await stored(`/storage/range?key=${key}&offset=15&length=100`), [200, `${size} ✓`], "fewer at its end");
	assert.deepEqual(await stored(`/storage/range?key=${key}&offset=0&length=0`), [200, `${size} `], "no bytes, and the size");
	const past = await stored(`/storage/range?key=${key}&offset=${size}&length=1`);
	assert.deepEqual(past, [502, past[1]]);
	assert.match(past[1], /^S3Err 416 InvalidRange: /, "past its end: S3's own refusal");
	const every = Array.from({ length: 256 }, (_, byte) => byte).join(",");
	assert.deepEqual(await stored(`/storage/put?key=${key}&as=numbers&type=application/octet-stream`, { method: "POST", body: every }), [200, "stored"], "replaced");
	assert.deepEqual(await stored(`/storage/get?key=${key}&as=numbers`), [200, every], "every byte, as it was");
	assert.deepEqual(await stored(`/storage/range?key=${key}&offset=254&length=2&as=numbers`), [200, "256 254,255"]);
	assert.deepEqual(await stored(`/storage/delete?key=${key}`, { method: "POST" }), [200, "deleted"]);
	assert.deepEqual(await stored(`/storage/get?key=${key}`), [404, "NotFound"]);
	assert.deepEqual(await stored(`/storage/delete?key=${key}`, { method: "POST" }), [200, "deleted"], "deleting what isn't there");
	assert.deepEqual(await stored("/storage/get?key="), [503, "StorageErr an object's key can't be empty"], "not the bucket itself");
});

test("storage: an object that isn't there is NotFound, read whole, in part, or described", { skip: skipStorage }, async () => {
	const key = keyed("never-kept");
	assert.deepEqual(await stored(`/storage/get?key=${key}`), [404, "NotFound"]);
	assert.deepEqual(await stored(`/storage/range?key=${key}&offset=0&length=10`), [404, "NotFound"]);
	assert.deepEqual(await stored(`/storage/range?key=${key}&offset=0&length=0`), [404, "NotFound"]);
	assert.deepEqual(await stored(`/storage/head?key=${key}`), [404, "NotFound"]);
});

test("storage: a multipart upload, parts of 5 MiB and a last smaller one sent at once, is one object", { skip: skipStorage }, async () => {
	const key = keyed("videos/1");
	const [status, upload] = await stored(`/storage/start?key=${key}&type=video/mp4`, { method: "POST" });
	assert.equal(status, 200, upload);
	const part = (number, size, fill) => stored(`/storage/part?key=${key}&upload=${encodeURIComponent(upload)}&number=${number}&size=${size}&fill=${fill}`, { method: "POST" });
	const sizes = [5 * MiB, 5 * MiB, 1000];
	const sent = await Promise.all(sizes.map((size, at) => part(at + 1, size, at + 1)));
	const bytes = Buffer.concat(sizes.map((size, at) => Buffer.alloc(size, at + 1)));
	for (const [at, [partStatus, etag]] of sent.entries()) {
		assert.equal(partStatus, 200, etag);
		assert.equal(etag, md5(Buffer.alloc(sizes[at], at + 1)), "each part's ETag, without its quotes");
	}
	const listed = [3, 1, 2].map((number) => `${number} ${sent[number - 1][1]}`).join("\n");
	assert.deepEqual(await stored(`/storage/finish?key=${key}&upload=${encodeURIComponent(upload)}`, { method: "POST", body: listed }), [200, "finished"], "listed in any order");
	const [, head] = await stored(`/storage/head?key=${key}`);
	assert.match(head, new RegExp(`^${bytes.length} video/mp4 [0-9a-f]{32}-3$`), "its size, its type, and a multipart ETag");
	assert.deepEqual(await stored(`/storage/range?key=${key}&offset=${5 * MiB - 2}&length=4&as=numbers`), [200, `${bytes.length} 1,1,2,2`], "a range across two parts");
	assert.deepEqual(await stored(`/storage/sha?key=${key}`), [200, sha256(bytes)], "read whole in Roc");
	const [, url] = await stored(`/storage/signed?key=${key}&method=GET&expires=60`);
	const fetched = await fetch(url);
	assert.equal(fetched.status, 200);
	assert.equal(sha256(Buffer.from(await fetched.arrayBuffer())), sha256(bytes), "and by Node's fetch, from a presigned URL");
	const again = await part(4, 10, 4);
	assert.deepEqual(again, [404, "NotFound"], "a part for an upload that is finished");
	assert.deepEqual(await stored(`/storage/delete?key=${key}`, { method: "POST" }), [200, "deleted"]);
});

test("storage: S3's refusals of an upload say its code; an aborted upload is gone, and makes nothing", { skip: skipStorage }, async () => {
	const key = keyed("videos/2");
	const [, upload] = await stored(`/storage/start?key=${key}&type=video/mp4`, { method: "POST" });
	const id = encodeURIComponent(upload);
	const part = (number, size) => stored(`/storage/part?key=${key}&upload=${id}&number=${number}&size=${size}&fill=9`, { method: "POST" });
	const [[, first], [, second]] = await Promise.all([part(1, 1000), part(2, 1000)]);
	const finish = (body) => stored(`/storage/finish?key=${key}&upload=${id}`, { method: "POST", body });
	const small = await finish(`1 ${first}\n2 ${second}`);
	assert.equal(small[0], 502);
	assert.match(small[1], /^S3Err 400 EntityTooSmall: /, "a part but the last under 5 MiB");
	const wrong = await finish("1 0123456789abcdef0123456789abcdef");
	assert.equal(wrong[0], 502);
	assert.match(wrong[1], /^S3Err 400 InvalidPart: /, "an ETag that isn't the part's");
	assert.deepEqual(await stored(`/storage/abort?key=${key}&upload=${id}`, { method: "POST" }), [200, "aborted"]);
	assert.deepEqual(await part(3, 10), [404, "NotFound"], "no such upload any more");
	assert.deepEqual(await finish(`1 ${first}`), [404, "NotFound"]);
	assert.deepEqual(await stored(`/storage/abort?key=${key}&upload=${id}`, { method: "POST" }), [200, "aborted"], "aborting it again");
	assert.deepEqual(await stored(`/storage/get?key=${key}`), [404, "NotFound"], "no object was made");
});

test("storage: presigned URLs, a PUT and a GET made by Node's fetch; a changed one is refused; a week at most", { skip: skipStorage }, async () => {
	const key = keyed("signed/a file ✓.txt");
	const [status, putUrl] = await stored(`/storage/signed?key=${key}&method=PUT&expires=60`);
	assert.equal(status, 200, putUrl);
	assert.match(putUrl, /X-Amz-Expires=60&X-Amz-SignedHeaders=host&X-Amz-Signature=[0-9a-f]{64}$/);
	assert.equal((await fetch(putUrl, { method: "PUT", body: "sent by Node", headers: { "content-type": "text/plain" } })).status, 200);
	assert.deepEqual(await stored(`/storage/get?key=${key}`), [200, "sent by Node"], "what the presigned PUT sent");
	const [, getUrl] = await stored(`/storage/signed?key=${key}&method=GET&expires=60`);
	const got = await fetch(getUrl);
	assert.equal(got.status, 200);
	assert.equal(await got.text(), "sent by Node");
	assert.equal((await fetch(getUrl.replace(/.$/, (last) => (last === "0" ? "1" : "0")))).status, 403, "a signature changed");
	assert.equal((await fetch(putUrl, { method: "DELETE" })).status, 403, "another method than the one signed");
	assert.deepEqual(await stored(`/storage/signed?key=${key}&method=GET&expires=0`), [400, "BadExpiry"]);
	assert.deepEqual(await stored(`/storage/signed?key=${key}&method=GET&expires=604801`), [400, "BadExpiry"]);
	assert.equal((await stored(`/storage/signed?key=${key}&method=GET&expires=604800`))[0], 200, "a week");
	assert.deepEqual(await stored(`/storage/delete?key=${key}`, { method: "POST" }), [200, "deleted"]);
});

test("storage: serve! answers with an object the server streams from S3: whole, a range, 304 for its ETag, HEAD, 404; without a bucket, the docs' sample a 500", { skip: skipStorage }, async () => {
	const key = keyed("served/clip.mp4");
	const bytes = Buffer.from(Array.from({ length: 70_000 }, (_, i) => (i * 13 + 7) % 256));
	assert.deepEqual(await stored(`/storage/put?key=${key}&type=application/octet-stream`, { method: "POST", body: bytes }), [200, "stored"], "the bytes as they came");
	const served = await get(`/storage/serve?key=${key}&type=video/mp4&cache=${encodeURIComponent("private, max-age=60")}`);
	assert.equal(served.status, 200);
	assert.deepEqual(Buffer.from(await served.arrayBuffer()), bytes);
	assert.equal(served.headers.get("content-type"), "video/mp4");
	assert.equal(served.headers.get("cache-control"), "private, max-age=60");
	assert.equal(served.headers.get("content-length"), "70000");
	const etag = served.headers.get("etag");
	assert.equal(etag, `"${md5(bytes)}"`);
	const part = await get(`/storage/serve?key=${key}`, { headers: { range: "bytes=69990-69999" } });
	assert.equal(part.status, 206);
	assert.equal(part.headers.get("content-range"), "bytes 69990-69999/70000");
	assert.equal(part.headers.get("content-type"), "application/octet-stream", "S3's, with none given");
	assert.equal(part.headers.get("cache-control"), null);
	assert.deepEqual(Buffer.from(await part.arrayBuffer()), bytes.subarray(69_990));
	const same = await get(`/storage/serve?key=${key}`, { headers: { "if-none-match": etag } });
	assert.equal(same.status, 304);
	const whole = await get(`/storage/serve?key=${key}&whole=1`, { headers: { range: "bytes=69990-69999" } });
	assert.equal(whole.status, 200, "a range the app dropped from the request record isn't asked for");
	assert.deepEqual(Buffer.from(await whole.arrayBuffer()), bytes);
	const head = await get(`/storage/serve?key=${key}`, { method: "HEAD" });
	assert.equal(head.status, 200);
	assert.equal(head.headers.get("content-length"), "70000");
	assert.equal((await head.arrayBuffer()).byteLength, 0);
	const missing = await get(`/storage/serve?key=${keyed("never-kept")}`);
	assert.equal(missing.status, 404);
	assert.equal(await missing.text(), "Not Found", "not S3's XML");
	const none = await start([], app, { DATABASE_URL: "", STORAGE_URL: "" });
	try {
		const answered = await none.get(`/samples/video?key=${key}`);
		assert.deepEqual([answered.status, await answered.text()], [500, "Something went wrong."]);
		await logs(/no storage/, none);
		await logs(/no S3 URL/, none);
	} finally {
		await none.stop();
	}
});

test("storage: keys S3 doesn't take are refused, with its code; a bucket that isn't there, S3 that isn't, a URL that can't be read, or none, say so", { skip: skipStorage }, async () => {
	// The tests' own STORAGE_URL, changed: s3://KEY:SECRET@HOST/BUCKET?… (the secret may hold a `/` or an `@`).
	const [, key, secret, rest] = /^s3:\/\/([^:]*):(.*)@([^@]*)$/.exec(storage);
	const [place, query] = rest.split("?");
	const [authority] = place.split("/");
	const variants = {
		secret: `s3://${key}:wrong-secret@${rest}`,
		key: `s3://nobody:${secret}@${rest}`,
		bucket: `s3://${key}:${secret}@${authority}/no-such-bucket-${run}?${query ?? ""}`,
		port: `s3://${key}:${secret}@127.0.0.1:9/bucket?style=path&tls=no`,
		typo: `s3://${key}:${secret}@${rest}&stlye=path`,
	};
	const servers = Object.fromEntries(
		await Promise.all(Object.entries(variants).map(async ([name, url]) => [name, await start([], app, { DATABASE_URL: "", STORAGE_URL: url })])),
	);
	const none = await start([], app, { DATABASE_URL: "", STORAGE_URL: "" });
	try {
		const ask = async (of, path, init) => {
			const response = await of.get(path, init);
			return [response.status, await response.text()];
		};
		const put = (of) => ask(of, `/storage/put?key=${keyed("refused")}&type=text/plain`, { method: "POST", body: "no" });
		const secretPut = await put(servers.secret);
		assert.equal(secretPut[0], 502);
		assert.match(secretPut[1], /^S3Err 403 SignatureDoesNotMatch: /, "a wrong secret");
		assert.match((await ask(servers.secret, "/storage/check"))[1], /^S3Err 403 SignatureDoesNotMatch: /, "check! says so too");
		assert.deepEqual(await ask(servers.secret, `/storage/head?key=${keyed("refused")}`), [502, "S3Err 403 : HTTP 403, no body"], "a HEAD's refusal has no body to say why");
		const keyPut = await put(servers.key);
		assert.match(keyPut[1], /^S3Err 403 InvalidAccessKeyId: /, "a key S3 doesn't know");
		assert.match((await ask(servers.key, "/storage/check"))[1], /^S3Err 403 InvalidAccessKeyId: /);
		assert.match((await ask(servers.bucket, `/storage/get?key=${keyed("x")}`))[1], /^S3Err 404 NoSuchBucket: /, "NoSuchBucket is not NotFound");
		assert.match((await ask(servers.bucket, "/storage/check"))[1], /^S3Err 404 NoSuchBucket: /, "check! tells a missing bucket from a missing object");
		assert.match((await put(servers.port))[1], /^StorageErr PUT .+: no answer from S3: 127\.0\.0\.1:9: /);
		assert.match((await ask(servers.port, "/storage/check"))[1], /^StorageErr GET rocx-storage-check: no answer from S3: /);
		assert.deepEqual(await put(servers.typo), [503, "StorageErr the S3 URL: stlye isn't one of its parameters (region, style, tls)"]);
		assert.deepEqual(await put(none), [503, "StorageErr no storage: no S3 URL (s3://KEY:SECRET@HOST/BUCKET?region=…)"]);
		assert.doesNotMatch(Object.values(servers).map((each) => each.logged()).join(""), new RegExp(secret.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), "the secret never logged");
	} finally {
		await Promise.all([...Object.values(servers), none].map((each) => each.stop()));
	}
});

// ---- The key-value store: Kv ----

/** The app's kv route `path`: its status and its text. */
const kv = async (path, of = server) => {
	const response = await of.get(`/kv/${path}`);
	return [response.status, await response.text()];
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("kv: the store's own unit tests (kv.rs, compiled alone): expiry, eviction, atomic increments from many threads", { skip }, () => {
	const ran = hostUnitTests("kv.rs", join(dir, "kv-unit-tests"));
	assert.equal(ran.status, 0, ran.stdout + ran.stderr);
	assert.match(ran.stdout, /test result: ok\. 6 passed/);
});

test("kv: a value kept, read, taken once, deleted; a JSON number reads back as an I64, a string doesn't", { skip }, async () => {
	const key = `${run}-kv-a`;
	assert.deepEqual(await kv(`set?key=${key}&value=${encodeURIComponent("Hello, ✓")}`), [200, "set"]);
	assert.deepEqual(await kv(`get?key=${key}`), [200, "Hello, ✓"]);
	assert.match((await kv(`count?key=${key}`))[1], /^BadValue /, "a string isn't an I64");
	assert.deepEqual(await kv(`take?key=${key}`), [200, "Hello, ✓"]);
	assert.deepEqual(await kv(`take?key=${key}`), [404, "NotFound"], "taken once");
	await kv(`set?key=${key}&value=again`);
	assert.deepEqual(await kv(`delete?key=${key}`), [200, "deleted"]);
	assert.deepEqual(await kv(`get?key=${key}`), [404, "NotFound"]);
	assert.deepEqual(await kv(`delete?key=${key}`), [200, "deleted"], "deleting what isn't there");
	assert.deepEqual(await kv(`increment?key=${key}-n&by=41`), [200, "41"]);
	assert.deepEqual(await kv(`count?key=${key}-n`), [200, "41"], "a counter is a JSON number");
});

test("kv: a value's time to live; add lets one in until it expires; a counter's window", { skip }, async () => {
	const key = `${run}-kv-t`;
	await kv(`set?key=${key}&value=soon&ttl=150`);
	assert.deepEqual(await kv(`get?key=${key}`), [200, "soon"]);
	assert.deepEqual(await kv(`add?key=${key}-claim&value=me&ttl=150`), [200, "added"]);
	assert.deepEqual(await kv(`add?key=${key}-claim&value=you`), [409, "Exists"]);
	assert.deepEqual(await kv(`increment?key=${key}-n&ttl=150`), [200, "1"]);
	assert.deepEqual(await kv(`increment?key=${key}-n&ttl=150`), [200, "2"], "the window's own deadline");
	await sleep(250);
	assert.deepEqual(await kv(`get?key=${key}`), [404, "NotFound"], "expired");
	assert.deepEqual(await kv(`add?key=${key}-claim&value=you`), [200, "added"], "free again");
	assert.deepEqual(await kv(`increment?key=${key}-n&ttl=150`), [200, "1"], "a new window");
	assert.match((await kv(`increment?key=${key}-claim`))[1], /^NotAnInteger /);
});

test("kv: 200 increments at once all count, and each gets its own number", { skip }, async () => {
	const key = `${run}-kv-race`;
	const answers = await Promise.all(Array.from({ length: 200 }, () => kv(`increment?key=${key}`)));
	assert.deepEqual(
		answers.map(([, said]) => Number(said)).sort((a, b) => a - b),
		Array.from({ length: 200 }, (_, at) => at + 1),
	);
	const claims = await Promise.all(Array.from({ length: 50 }, (_, at) => kv(`add?key=${key}-claim&value=${at}`)));
	assert.equal(claims.filter(([status]) => status === 200).length, 1, "one add gets in");
});

test("samples: what the docs show of Kv runs as they say: five tries a minute, a sign-in's state good once", { skip }, async () => {
	const address = `${run}-203.0.113.7`;
	const tries = [];
	for (let at = 0; at < 7; at++) tries.push(await text(`/samples/try?address=${address}`, { method: "POST" }));
	assert.deepEqual(tries, ["go on", "go on", "go on", "go on", "go on", "wait", "wait"]);
	assert.equal(await text(`/samples/try?address=${address}-other`, { method: "POST" }), "go on", "another address, its own count");
	const state = await text("/samples/sign-in", { method: "POST" });
	assert.match(state, /^[A-Za-z0-9_-]{22}$/);
	const back = async () => {
		const answer = await get(`/samples/sign-in/back?state=${state}`);
		return [answer.status, await answer.text()];
	};
	assert.deepEqual(await back(), [200, "signed in"]);
	assert.deepEqual(await back(), [400, "UnknownState"], "good once");
});

test("kv: a capped list, newest first", { skip }, async () => {
	const key = `${run}-kv-l`;
	for (const each of ["a", "b", "c", "d"]) await kv(`push?key=${key}&value=${each}&keep=3`);
	assert.deepEqual(await kv(`list?key=${key}`), [200, "d,c,b"]);
	assert.deepEqual(await kv(`list?key=${key}-none`), [200, ""], "none is empty");
});

test("kv: past --kv-max-mb, the least recently used values go, a value just read stays", { skip }, async () => {
	const small = await start(["--kv-max-mb", "1"]);
	try {
		const key = (at) => `${run}-kv-full-${at}`;
		for (let at = 0; at < 8; at++) await kv(`set?key=${key(at)}&size=100000`, small);
		await kv(`get?key=${key(0)}`, small);
		for (let at = 8; at < 16; at++) await kv(`set?key=${key(at)}&size=100000`, small);
		const kept = await Promise.all(Array.from({ length: 16 }, async (_, at) => (await kv(`get?key=${key(at)}`, small))[0] === 200));
		assert.equal(kept[0], true, "read since: used recently");
		assert.equal(kept[1], false, "the least recently used went");
		assert.equal(kept[15], true, "the newest stays");
		assert.ok(kept.filter(Boolean).length <= 10, `about 1 MiB of 100 kB values: ${kept.filter(Boolean).length} kept`);
	} finally {
		await small.stop();
	}
});

// ---- Cookies ----

test("cookies: Set-Cookie as each option says; with_cookie and without_cookie as they were", { skip }, async () => {
	const answer = await get("/cookies", { redirect: "manual" });
	assert.equal(answer.status, 303);
	assert.deepEqual(answer.headers.getSetCookie(), [
		"plain=a%20b%3Bc; Path=/; HttpOnly; SameSite=Lax",
		"__Host-session=token; Path=/; Max-Age=2592000; Secure; HttpOnly; SameSite=Lax",
		`until=1; Path=/; Expires=${new Date(1_795_000_000_000).toUTCString()}; SameSite=Strict`,
		"shared=x; Path=/docs; Domain=example.com; Secure; HttpOnly; SameSite=None",
		"__Host-session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax",
		"plain=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0",
	]);
});

// ---- roc-pg ----

test("roc-pg, a Postgres client in Roc, works on the platform's Tcp and Random: a query checked when the app was built", { skip: skipDb }, async (t) => {
	// The example fetches roc-pg from GitHub when it is first built (Roc keeps it after that).
	const example = join(dir, "roc-pg");
	try {
		buildApp(join(root, "server", "examples", "roc-pg", "main.roc"), example);
	} catch (error) {
		if (/download|fetch|network|resolve|connect/i.test(error.message)) return t.skip("roc-pg couldn't be downloaded");
		throw error;
	}
	writeFileSync(join(dir, "database-url.txt"), database);
	const pg = await start(["--database-url", database, "--context-file", join(dir, "database-url.txt")], example);
	try {
		assert.equal(await pg.text("/"), "3 Earth");
		assert.equal(await pg.text("/"), "3 Earth", "and again, a new connection a request");
	} finally {
		await pg.stop();
	}
});

// ---- Live ----

test("live: a room counts the streams in it, and each hears when another comes or goes", { skip }, async () => {
	const ada = new AbortController();
	const grace = new AbortController();
	const first = await listen("/online", ada.signal);
	assert.equal(await first.next(), "1");
	const second = await listen("/online", grace.signal);
	assert.equal(await second.next(), "2");
	assert.equal(await first.next(), "2", "the first heard the second come");
	assert.equal(await text("/online/count"), "2");
	grace.abort();
	assert.equal(await first.next(), "1", "and go");
	ada.abort();
	assert.equal(await until(async () => (await text("/online/count")) === "0"), true, "a stream that ends leaves its room");
});

test("live: what is published on a topic reaches every stream listening to it", { skip }, async () => {
	const gone = new AbortController();
	const [one, two] = await Promise.all([listen("/shouts", gone.signal), listen("/shouts", gone.signal)]);
	assert.equal(await one.next(), "listening");
	assert.equal(await two.next(), "listening");
	assert.equal(await post("/shout", "hello, all"), "shouted");
	assert.equal(await one.next(), "hello, all");
	assert.equal(await two.next(), "hello, all");
	gone.abort();
});

// ---- Channels (D-020): one stream per tab, at /rocx/live, held by the host ----

/** A tab's stream of its channels (`GET /rocx/live?tab=…&c=…`), as `of` answers it: `next()`
 * resolves to its next event, `{ event, url, said }` (`said` parsed), or `": beat"` for a beat (with
 * `beats`), or null once it ends. */
async function channelStream(urls, { tab = "", cookie = "", signal, of = server, beats = false } = {}) {
	const query = [...(tab ? [`tab=${tab}`] : []), ...urls.map((url) => `c=${encodeURIComponent(url)}`)].join("&");
	const response = await of.get(`/rocx/live?${query}`, { headers: { accept: "text/event-stream", cookie }, signal });
	const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
	let buffered = "";
	return {
		response,
		async next() {
			for (;;) {
				const end = buffered.indexOf("\n\n");
				if (end >= 0) {
					const block = buffered.slice(0, end);
					buffered = buffered.slice(end + 2);
					if (block.startsWith(":")) {
						if (beats && block === ": beat") return block;
						continue;
					}
					const lines = block.split("\n");
					const field = (name) => lines.filter((line) => line.startsWith(`${name}: `)).map((line) => line.slice(name.length + 2));
					const [url, ...rest] = field("data");
					return { event: field("event")[0], url, said: rest.length ? JSON.parse(rest.join("\n")) : null };
				}
				const read = await reader.read();
				if (read.done) return null;
				buffered += read.value;
			}
		},
	};
}

/** A member of `org`, as the test app's middleware reads them, until `until` (ms) if given. */
const memberOf = (name, org, until) => `member=${name}; org=${org}${until ? `; until=${until}` : ""}`;

/** Says things on channels, as a tab's hub posts them (`POST /rocx/live/send`): the answer. */
const say = (items, { tab = "", cookie = "", of = server } = {}) =>
	of.get(`/rocx/live/send${tab ? `?tab=${tab}` : ""}`, { method: "POST", headers: { "content-type": "application/json", cookie }, body: JSON.stringify(items) });

test("channels: one stream carries a tab's channels, each checked as it opens: one refused is told so and the rest go on; one let in hears resync, then its on_open! messages, then what is published with its own params, in order; beats", { skip }, async () => {
	const gone = new AbortController();
	const tab = `${run}t1`;
	const stream = await channelStream(["/news/acme", "/news/beta", "/clock", "/nowhere", "/news/acme"], { tab, cookie: memberOf("ada", "acme"), signal: gone.signal, beats: true });
	assert.equal(stream.response.status, 200);
	assert.equal(stream.response.headers.get("content-type"), "text/event-stream");
	assert.deepEqual(await stream.next(), { event: "resync", url: "/news/acme", said: null }, "its check let it in (twice named, once subscribed)");
	assert.deepEqual(await stream.next(), { event: "message", url: "/news/acme", said: { n: 0, title: "welcome, ada (a tab)" } }, "on_open!'s, before anything published");
	assert.deepEqual(await stream.next(), { event: "refused", url: "/news/beta", said: { status: 403, why: "Forbidden" } }, "another org's: refused, by its own check");
	assert.deepEqual(await stream.next(), { event: "resync", url: "/clock", said: null });
	assert.deepEqual(await stream.next(), { event: "refused", url: "/nowhere", said: { status: 404, why: "no channel at /nowhere" } });
	// Published for another org first: only acme's comes.
	assert.equal(await text("/news/publish?org=beta&title=theirs&n=1", { method: "POST" }), "published");
	for (let n = 1; n <= 3; n++) assert.equal(await text(`/news/publish?org=acme&title=ours&n=${n}`, { method: "POST" }), "published");
	for (let n = 1; n <= 3; n++) assert.deepEqual(await stream.next(), { event: "message", url: "/news/acme", said: { n, title: "ours" } }, "its params' only, in the order published");
	assert.equal(await text("/clock/publish", { method: "POST" }), "published");
	const tick = await stream.next();
	assert.equal(tick.url, "/clock");
	assert.ok(tick.said > 1_700_000_000_000);
	assert.equal(await stream.next(), ": beat", "the stream beats (--live-beat-ms), checking its channels again");
	gone.abort();
	// The host's ask, from anyone else, is no ask: a request with x-rocx-channel is answered as any.
	const forged = await get("/news/acme", { headers: { cookie: memberOf("ada", "acme"), "x-rocx-channel": "open", "x-rocx-tab": tab } });
	assert.equal(forged.status, 404);
	assert.doesNotMatch(await forged.text(), /who/);
	assert.equal((await get("/rocx/live/send")).status, 405);
	assert.equal((await get("/rocx/live?c=%2Fclock", { method: "POST" })).status, 405);
	await logsEvent({ msg: "channel closed", channel: "/news/acme", who: "ada", tab, why: "gone" });
});

test("channels: what a page says goes to its channel's receive!, through the same check, a post at a time; what is refused says why; a tab's ask for a resync sends resync and on_open!'s again on its own stream", { skip }, async () => {
	const gone = new AbortController();
	const tab = `${run}t2`;
	const cookie = memberOf("grace", "acme");
	const stream = await channelStream(["/news/acme"], { tab, cookie, signal: gone.signal });
	assert.equal((await stream.next()).event, "resync");
	assert.equal((await stream.next()).said.title, "welcome, grace (a tab)");
	const answer = await say(
		[
			{ channel: "/news/acme", message: { Hello: "hi" } },
			{ channel: "/news/acme", message: "Fail" },
			{ channel: "/news/beta", message: { Hello: "hi" } },
			{ channel: "/clock", message: 1 },
			{ message: 1 },
			{ channel: "/news/acme", message: { Nope: 1 } },
			{ channel: "/news/acme" },
		],
		{ tab, cookie },
	);
	assert.equal(answer.status, 200);
	const { refused } = await answer.json();
	assert.deepEqual(refused.slice(0, 4), [
		{ index: 1, status: 400, why: "not that" },
		{ index: 2, status: 403, why: "Forbidden" },
		{ index: 3, status: 404, why: "/clock takes nothing pages say" },
		{ index: 4, status: 400, why: 'which channel? ("channel": its URL)' },
	]);
	assert.equal(refused[4].index, 5);
	assert.match(refused[4].why, /^\/news\/acme can't read what was said/, "what isn't the channel's `said`");
	assert.deepEqual(refused[5], { index: 6, status: 400, why: "say a message, or ask for a resync" });
	assert.equal(refused.length, 6, "the hello was taken");
	assert.deepEqual(await stream.next(), { event: "message", url: "/news/acme", said: { n: 0, title: "grace says hi" } }, "receive! published it");
	const all = await say([{ channel: "/news/acme", message: { Hello: "again" } }], { tab, cookie });
	assert.equal(all.status, 204, "nothing refused");
	assert.deepEqual((await stream.next()).said, { n: 0, title: "grace says again" });
	// Signed out: the channel's middleware refuses what is said, as it would anything.
	assert.deepEqual((await (await say([{ channel: "/news/acme", message: { Hello: "x" } }])).json()).refused, [{ index: 0, status: 401, why: "sign in" }]);
	assert.equal((await get("/rocx/live/send", { method: "POST", body: "[]", headers: { "content-type": "text/plain" } })).status, 415, "JSON only: a form from elsewhere can't post it");
	assert.equal((await say({ channel: "/news/acme" })).status, 400, "a list");
	// The tab asks for a resync: its stream checks the channel again, then resync and on_open!'s.
	assert.equal((await say([{ channel: "/news/acme", resync: true }], { tab, cookie })).status, 204);
	assert.deepEqual(await stream.next(), { event: "resync", url: "/news/acme", said: null });
	assert.equal((await stream.next()).said.title, "welcome, grace (a tab)");
	gone.abort();
	await logsEvent({ msg: "channel closed", who: "grace", tab, why: "gone" });
});

test("channels: a check that starts failing ends its subscription at the next beat (ended, and why), and on_close! is told it was refused; the stream goes on", { skip }, async () => {
	const gone = new AbortController();
	const tab = `${run}t3`;
	const lapses = Date.now() + 700;
	const stream = await channelStream(["/news/acme", "/clock"], { tab, cookie: memberOf("cy", "acme", lapses), signal: gone.signal });
	assert.equal((await stream.next()).event, "resync");
	assert.equal((await stream.next()).event, "message");
	assert.equal((await stream.next()).url, "/clock");
	const ended = await stream.next();
	assert.deepEqual(ended, { event: "ended", url: "/news/acme", said: "the session has ended" });
	assert.ok(Date.now() >= lapses && Date.now() < lapses + 2000, "at the first beat (300 ms) after it lapsed");
	await logsEvent({ msg: "channel closed", channel: "/news/acme", who: "cy", tab, why: "refused: the session has ended" });
	await text("/news/publish?org=acme&title=late&n=9", { method: "POST" });
	assert.equal(await text("/clock/publish", { method: "POST" }), "published");
	assert.equal((await stream.next()).url, "/clock", "the stream goes on, without the ended channel");
	gone.abort();
	assert.equal(await until(async () => (await live()) === baseline), true, `the streams' checks and hooks held nothing: ${await live()} allocations, ${baseline} once started`);
});

test("channels: a subscriber behind its channel's backlog hears resync (and on_open!'s) instead of what it missed; latest-wins messages replace each other, with no resync", { skip }, async () => {
	const flood = async (latest) => {
		const gone = new AbortController();
		const response = await get(`/rocx/live?tab=${run}t4&c=%2Fnews%2Facme`, { headers: { accept: "text/event-stream", cookie: memberOf("dee", "acme") }, signal: gone.signal });
		const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
		let text_ = "";
		while (!text_.includes("welcome")) text_ += (await reader.read()).value;
		// 2000 of 4 KB each, published while the stream isn't read: far more than its backlog and buffers.
		assert.equal(await text(`/news/flood?org=acme&count=2000&size=4000${latest ? "&latest=yes" : ""}`, { method: "POST" }), "flooded");
		// Read until the last comes (the stream beats meanwhile, so it is never quiet for long).
		const last = /"n":2000[,}].*\n\n/;
		const deadline = Date.now() + 10_000;
		while (!last.test(text_) && Date.now() < deadline) {
			const read = await Promise.race([reader.read(), new Promise((resolve) => setTimeout(() => resolve(null), deadline - Date.now()))]);
			if (!read) break;
			assert.equal(read.done, false, `the stream goes on:\n${text_.slice(-300)}`);
			text_ += read.value;
		}
		gone.abort();
		// Whole events only: the last may still be arriving.
		const events = text_.split("\n\n").slice(0, -1).filter((block) => block.startsWith("event: "));
		const messages = events.filter((block) => block.startsWith("event: message")).map((block) => JSON.parse(block.split("\n")[2].slice(6)).n);
		return { resyncs: events.filter((block) => block.startsWith("event: resync")).length, messages };
	};
	const ordered = await flood(false);
	assert.equal(ordered.resyncs, 2, "the first, and one for falling behind");
	assert.ok(ordered.messages.length < 1500, `what it missed isn't sent (${ordered.messages.length})`);
	assert.equal(ordered.messages.at(-1), 2000, "and it hears on from where it is");
	const skips = ordered.messages.filter((n) => n > 0);
	assert.ok(skips.every((n, i) => i === 0 || n > skips[i - 1]), "in order");
	const latest = await flood(true);
	assert.equal(latest.resyncs, 1, "no resync for latest-wins messages");
	assert.ok(latest.messages.length < 1000, `the older ones replaced (${latest.messages.length})`);
	assert.equal(latest.messages.at(-1), 2000, "the newest comes");
});

test("channels: an open stream holds no thread: with 2 of them for Roc, 40 streams stay open, each hears what is published, and requests answer at once; so do 8 events! streams, whose calls pause while they wait (D-027)", { skip }, async () => {
	const few = await start(["--roc-threads", "2", "--live-beat-ms", "200"], app, { DATABASE_URL: "" });
	const gone = new AbortController();
	try {
		const streams = await Promise.all(Array.from({ length: 40 }, (_, i) => channelStream(["/news/acme"], { tab: `${run}p${i}`, cookie: memberOf(`m${i}`, "acme"), signal: gone.signal, of: few })));
		for (const stream of streams) assert.equal((await stream.next()).event, "resync");
		for (const stream of streams) assert.equal((await stream.next()).said.title.startsWith("welcome"), true);
		// Beats come and go, each checking every channel again, in a call of its own.
		await new Promise((resolve) => setTimeout(resolve, 500));
		for (let i = 0; i < 20; i++) {
			const started = performance.now();
			assert.equal(await few.text("/"), "Hello from Roc, natively.");
			assert.ok(performance.now() - started < 1000, `answered in ${Math.round(performance.now() - started)} ms`);
		}
		assert.equal(await few.text("/news/publish?org=acme&title=all&n=7", { method: "POST" }), "published");
		for (const stream of streams) assert.deepEqual((await stream.next()).said, { n: 7, title: "all" });
		gone.abort();
		// An events! stream is a call that pauses while it waits: 8 of them hold neither thread.
		const held = new AbortController();
		const shouts = await Promise.all(Array.from({ length: 8 }, () => few.get("/shouts", { headers: { accept: "text/event-stream" }, signal: held.signal })));
		assert.ok(shouts.every((response) => response.status === 200));
		const waited = await Promise.race([few.text("/").then(() => "answered"), new Promise((resolve) => setTimeout(() => resolve("waiting"), 700))]);
		assert.equal(waited, "answered", "a request is answered beside them");
		held.abort();
		const refused = await start(["--blocking-threads", "8"], app, { DATABASE_URL: "" }).catch((error) => error);
		assert.match(String(refused), /--blocking-threads is gone/, "the old cap is refused, saying what to use");
	} finally {
		gone.abort();
		await few.stop();
	}
});

// ---- Actors ----
// ---- Actors ----

test("actors: one message at a time per key, a crash leaves the state as it was, and one may ask another", { skip }, async () => {
	const key = `${run}a`;
	assert.equal(await post(`/actors/count/${key}?by=5`), "5");
	assert.equal(await post(`/actors/count/${key}?by=2`), "7");
	assert.equal(await text(`/actors/count/${key}`), "7");
	assert.equal(await text(`/actors/count/${run}b`), "0", "another key, its own state");
	// A hundred at once: each sees the one before it.
	const replies = await Promise.all(Array.from({ length: 100 }, () => post(`/actors/count/${key}?by=1`)));
	assert.deepEqual(replies.map(Number).sort((a, b) => a - b), Array.from({ length: 100 }, (_, i) => 8 + i));
	assert.equal(await text(`/actors/count/${key}`), "107");
	const boom = await get(`/actors/boom?run=${key}`, { method: "POST" });
	assert.equal(boom.status, 500);
	assert.equal(await boom.text(), `counter ${key} crashed: an actor that crashed`);
	assert.equal(await text(`/actors/count/${key}`), "107", "the state before the crash");
	assert.equal(await post(`/actors/relay?run=${key}`), "107", "an actor asking another");
	const itself = await get(`/actors/self?run=${key}`, { method: "POST" });
	assert.equal(itself.status, 500);
	assert.match(await itself.text(), /asked itself: it would wait for its own answer forever/);
});

test("actors: a crash in receive!, or an actor asking itself, again and again, lets go of everything the turn made (built with --opt=dev, and with ROCX_TEST_OPT=speed)", { skip }, async () => {
	const key = `${run}crashes`;
	assert.equal(await post(`/actors/count/${key}?by=1`), "1");
	for (let i = 0; i < 25; i++) {
		const [boom, itself] = await Promise.all([get(`/actors/boom?run=${key}`, { method: "POST" }), get(`/actors/self?run=${key}`, { method: "POST" })]);
		assert.deepEqual([boom.status, itself.status, await boom.text()], [500, 500, `counter ${key} crashed: an actor that crashed`]);
		await itself.text();
	}
	assert.equal(await text(`/actors/count/${key}`), "1", "the state as it was");
	assert.equal(await until(async () => (await live()) === baseline), true, `${await live()} allocations, ${baseline} once started`);
});

test("actors: many asks answered, and relayed from one actor to another, leave nothing allocated, and free nothing twice", { skip }, async () => {
	const key = `${run}asks`;
	for (let i = 0; i < 25; i++) await Promise.all([post(`/actors/count/${key}?by=1`), post(`/actors/relay?run=${key}`), text(`/actors/count/${key}`)]);
	assert.equal(await text(`/actors/count/${key}`), "25");
	assert.equal(await until(async () => (await live()) === baseline), true, `${await live()} allocations, ${baseline} once started: neither more (held) nor fewer (freed twice)`);
});

test("actors: a tell is handled after the messages before it, and an ask after tells sees them all", { skip }, async () => {
	const key = `${run}told`;
	for (let i = 0; i < 20; i++) assert.equal(await post(`/actors/tell?run=${key}&by=1`), "told");
	assert.equal(await text(`/actors/count/${key}`), "20");
	const told = await Promise.all(Array.from({ length: 30 }, () => post(`/actors/tell?run=${key}&by=1`)));
	assert.deepEqual(new Set(told), new Set(["told"]));
	assert.equal(await until(async () => (await text(`/actors/count/${key}`)) === "50"), true, "every tell handled, none twice");
});

test("actors: one that asks an actor whose turn waits on it is refused at once, rather than waiting 30 s", { skip }, async () => {
	const started = performance.now();
	const cycle = await get(`/actors/cycle?run=${run}cycle`, { method: "POST" });
	assert.equal(cycle.status, 500);
	assert.match(await cycle.text(), new RegExp(`bouncer ${run}cycle asked mirror ${run}cycle, whose turn waits on its answer: it would wait forever`));
	assert.ok(performance.now() - started < 5000, "at once");
});

test("actors: a message an actor doesn't take, or a kind the app has none of, is an error on the log and to its asker, not a crash: the actor goes on as it was", { skip }, async () => {
	const key = `${run}stale`;
	assert.equal(await post(`/actors/count/${key}?by=3`), "3");
	const wrong = await get(`/actors/wrong?run=${key}`, { method: "POST" });
	assert.equal(wrong.status, 500);
	assert.match(await wrong.text(), new RegExp(`^counter ${key}: a message it doesn't take: `));
	assert.equal(await post(`/actors/wrong-tell?run=${key}`), "told");
	await logsEvent({ level: "error", msg: "rocx actor: a message failed", actor: "counter", key, error: /a message it doesn't take/ });
	const failures = () => events().filter((event) => event.msg === "rocx actor: a message failed" && event.key === key).length;
	assert.equal(await until(async () => failures() === 2), true, `the ask's, and the tell's: ${failures()}`);
	assert.equal(await text(`/actors/count/${key}`), "3", "as it was");
	assert.equal(await post(`/actors/count/${key}?by=1`), "4", "and goes on");
	const ghost = await get(`/actors/ghost?run=${key}`, { method: "POST" });
	assert.equal(ghost.status, 500);
	assert.match(await ghost.text(), /^no kind of actor is called ghost/);
	await logsEvent({ level: "error", msg: "rocx actor: a message failed", actor: "ghost", key });
	assert.equal(await until(async () => (await live()) === baseline), true, `${await live()} allocations, ${baseline} once started`);
});

test("actors: timers: a tell later (tell_after!), one cancelled before it fires (cancel!), and an actor's own (after!), each tick setting the next until it stops", { skip }, async () => {
	const key = `${run}later`;
	assert.match(await post(`/actors/later?run=${key}&by=5&ms=100`), /^\d+$/);
	assert.equal(await text(`/actors/count/${key}`), "0", "not yet");
	const timer = await post(`/actors/later?run=${key}&by=7&ms=150`);
	assert.equal(await post(`/actors/cancel?timer=${timer}`), "cancelled");
	assert.equal(await until(async () => (await text(`/actors/count/${key}`)) === "5"), true, "the first fired");
	await new Promise((resolve) => setTimeout(resolve, 300));
	assert.equal(await text(`/actors/count/${key}`), "5", "the cancelled one never did");
	const ticks = `${run}ticks`;
	assert.equal(await post(`/actors/tick/start?run=${ticks}&ms=20`), "0");
	assert.equal(await until(async () => Number(await text(`/actors/tick?run=${ticks}`)) >= 5), true, "it ticks");
	const stopped = Number(await post(`/actors/tick/stop?run=${ticks}`));
	await new Promise((resolve) => setTimeout(resolve, 200));
	assert.equal(Number(await text(`/actors/tick?run=${ticks}`)), stopped, "and stops");
	assert.equal(await until(async () => (await live()) === baseline), true, `${await live()} allocations, ${baseline} once started`);
});

test("actors: their state is in Postgres, there after a restart", { skip: skipDb }, async () => {
	const key = `${run}kept`;
	assert.equal(await post(`/actors/count/${key}?by=41`), "41");
	const restarted = await start(dbFlags(), app, mailEnv());
	try {
		assert.equal(await restarted.text(`/actors/count/${key}`, { method: "POST" }), "42");
	} finally {
		assert.equal(await restarted.stop(), 0);
	}
});

test("actors: one idle for --actor-idle-ms is let go, and the next message wakes it as Postgres has it; one awake keeps the state it has", { skip: skipDb }, async () => {
	const idle = await start([...dbFlags(), "--actor-idle-ms", "200"], app, mailEnv());
	try {
		const key = `${run}idle`;
		const ask = (path) => idle.text(path, { method: "POST" });
		assert.equal(await ask(`/actors/count/${key}?by=1`), "1");
		// Awake: Postgres changed behind its back changes nothing it has.
		assert.equal(await ask(`/actors/poke?run=${key}&count=100`), "poked");
		assert.equal(await ask(`/actors/count/${key}?by=1`), "2");
		// Idle for longer than 200 ms: let go, and read again when a message wakes it.
		await new Promise((resolve) => setTimeout(resolve, 700));
		assert.equal(await ask(`/actors/poke?run=${key}&count=100`), "poked");
		assert.equal(await idle.text(`/actors/count/${key}`), "100");
		assert.equal(await ask(`/actors/count/${key}?by=1`), "101");
	} finally {
		assert.equal(await idle.stop(), 0);
	}
});

// ---- Components the server renders, and the endpoints they read ----

/** A GET a page read as the server rendered it, as the page's answers script has it. */
const carried = (url, status, body) => [`GET ${url}`, "", JSON.stringify({ status, body })];

/** The probe as the server renders it on its page: `member` is what its read of `GET
 * /probe/member` (behind `members_only`) renders, inside its <Errored>. */
const probe = (member) =>
	'<div class="probe big" title="count 41"><p><!--x-->42<!--/x--></p><p><!--x-->82<!--/x--></p><p><!--x-->HELLO<!--/x--></p>' +
	"<ul><!--for--><!--row--><li><!--x-->0 ada<!--/x--></li><!--/row--><!--row--><li><!--x-->1 grace<!--/x--></li><!--/row--><!--/for--></ul>" +
	'<!--show--><p class="small">small</p><!--/show-->' +
	'<!--errored:failed--><p class="failed"><!--x-->nothing above provides Probe.missing: render this under its provider<!--/x--></p><!--/errored-->' +
	'<input disabled value="a &amp; b">' +
	member +
	'<p class="at"><!--x-->/probe ? from=probe<!--/x--></p>' +
	// The native walker's raw text, doctype, `class_if` and `optional` (an empty one left out, an unsafe URL replaced).
	'<!doctype html><style class="on s">p > b { content: "&" }</style><a href="about:invalid#rocx-unsafe-url" rel="next">&lt;a &amp; b&gt;</a>' +
	"</div>";

test("pages of components: signals, memos, a keyed <For>, a <Show>, an <Errored> that catches, every kind of attribute, raw text and a doctype, as the browser's runtime renders them", { skip }, async () => {
	const shouted = carried("/probe/shout/hello", 200, '"HELLO"');
	const refused = carried("/probe/member", 401, "members only");
	assert.equal(
		await text("/probe?from=probe"),
		`<!doctype html><html><body>${probe('<!--errored:failed--><p class="refused"><!--x-->GET /probe/member: 401: members only<!--/x--></p><!--/errored-->')}<p>after</p>` +
			`<script type="application/json" class="rocx-answers">${JSON.stringify([shouted, refused])}</script><script type="module" data-rocx src="/rocx/start.js"></script></body></html>`,
		"its reads' answers before </body>, the refused one too, so the browser fails where the server did",
	);
});

test("endpoint reads: a read while the server renders is answered by the endpoint's route, in-process, behind its middleware, and noted for the page", { skip }, async () => {
	const page = await text("/probe?from=probe", { headers: { cookie: "member=Ada" } });
	assert.ok(page.includes(probe('<!--errored--><p class="member"><!--x-->member Ada, GET /probe/member<!--/x--></p><!--/errored-->')), page);
	const answers = [carried("/probe/shout/hello", 200, '"HELLO"'), carried("/probe/member", 200, '"member Ada, GET /probe/member"')];
	assert.ok(
		page.endsWith(`<script type="application/json" class="rocx-answers">${JSON.stringify(answers)}</script><script type="module" data-rocx src="/rocx/start.js"></script></body></html>`),
		"its answer, byte for byte what the browser would get, beside the page",
	);
});

test("endpoints: what a page reads is answered over HTTP too, behind its middleware; JSON both ways (F64s, a tag union, nominal types); and /rocx/call/ is gone", { skip }, async () => {
	const shouted = await get("/probe/shout/psst", { headers: { accept: "application/json" } });
	assert.equal(shouted.status, 200);
	assert.equal(shouted.headers.get("content-type"), "application/json");
	assert.equal(await shouted.text(), '"PSST"');
	const member = await get("/probe/member", { headers: { cookie: "member=Grace" } });
	assert.equal(member.status, 200);
	assert.equal(await member.text(), '"member Grace, GET /probe/member"', "its handler ran, given the request and what the middleware handed on");
	const refused = await get("/probe/member");
	assert.equal(refused.status, 401, "refused: the middleware's status");
	assert.equal(await refused.text(), "members only");
	const posted = (path, body) => get(path, { method: "POST", body, headers: { "content-type": "application/json" } });
	const measured = await posted("/probe/measure", '{"seconds":1.5,"parts":4}');
	assert.deepEqual([measured.status, await measured.text()], [200, '{"each":0.375,"seconds":1.5}'], "F64s, each way, as JSON numbers");
	const infinite = await posted("/probe/measure", '{"seconds":1.5,"parts":0}');
	assert.equal(infinite.status, 500, "an answer with a number JSON can't write");
	assert.equal(await infinite.text(), "POST /probe/measure's answer: it holds a number JSON can't write (an F64 that is NaN or an infinity)");
	assert.deepEqual([await (await posted("/probe/length", '"Roc"')).text(), await (await posted("/probe/length", '""')).text()], ['{"Ok":3}', '{"Err":"Empty"}'], "a tag union in Try's place, as JSON");
	const awarded = await posted("/probe/award", '{"badge":{"name":"gold"},"points":1.25}');
	assert.deepEqual(
		[awarded.status, await awarded.text()],
		[200, '{"badge":{"name":"gold"},"holder":{"badge":{"name":"admin"},"name":"Ada","since":0.5},"points":2.5}'],
		"a nominal type with a derived encoder beside other fields, and an F64, in the context, the body and the answer",
	);
	assert.equal((await get("/rocx/call/Probe.shout", { method: "POST", body: '"x"' })).status, 404, "no server functions: nothing answers /rocx/call/");
});

test("components and endpoint reads: rendering, reading, failing and crashing again and again leaves nothing allocated", { skip }, async () => {
	await text("/probe?from=probe");
	for (let i = 0; i < 50; i++) {
		await Promise.all([
			text("/probe?from=probe"),
			text("/probe?from=probe", { headers: { cookie: "member=Ada" } }),
			text("/probe/shout/x"),
			text("/probe/member"),
			post("/probe/measure", '{"seconds":1,"parts":0}'),
		]);
	}
	// The background loops (workers, the cron ticker) allocate for a moment now and then, so a single
	// sample may catch one: wait for them to settle back to what they held once started.
	assert.equal(await until(async () => (await live()) === baseline), true, `${await live()} allocations, ${baseline} once started`);
});

// ---- Pages of components ----

/** The answers script and the script that starts the browser's side, as the host puts them just
 * before `</body>`. */
const scripts = (answers) => `<script type="application/json" class="rocx-answers">${answers}</script><script type="module" data-rocx src="/rocx/start.js"></script>`;

/** The test app's `document!` as the host renders it: `member` is what its read of `GET
 * /probe/member` (behind `members_only`) renders, inside its <Errored>; `answers`, the GETs the
 * render recorded. */
const documentPage = (member, answers) =>
	'<!doctype html><html lang="en"><head><title>A page</title></head><body>' +
	'<p class="count"><!--x-->1<!--/x--></p>' +
	'<!--loading--><p class="shouted"><!--x-->PAGE<!--/x--></p><!--/loading-->' +
	'<!--errored:failed--><p class="failed"><!--x-->nothing above provides Probe.missing: render this under its provider<!--/x--></p><!--/errored-->' +
	member +
	'<p class="at"><!--x-->/page ? from=test<!--/x--></p>' +
	scripts(answers) +
	"</body></html>";

const shoutAnswer = carried("/probe/shout/page", 200, '"PAGE"');

test("pages of components: rendered whole, every hole once, a doctype first, the answers and start.js before </body>", { skip }, async () => {
	const answer = await get("/page?from=test");
	assert.equal(answer.status, 200);
	assert.equal(answer.headers.get("content-type"), "text/html; charset=utf-8", "a page is HTML unless it says otherwise");
	assert.equal(answer.headers.get("x-page"), "yes", "the answer's own headers");
	assert.equal(
		await answer.text(),
		documentPage('<!--errored:failed--><p class="refused"><!--x-->GET /probe/member: 401: members only<!--/x--></p><!--/errored-->', JSON.stringify([shoutAnswer, carried("/probe/member", 401, "members only")])),
		"<Loading> renders what is inside it, a memo is computed as it is made, an <Errored> catches its failure; the refusal is among the answers",
	);
});

test("pages of components: an endpoint behind its middleware, read as the page renders, is answered by its route and noted for the page", { skip }, async () => {
	assert.equal(
		await text("/page?from=test", { headers: { cookie: "member=Ada" } }),
		documentPage('<!--errored--><p class="member"><!--x-->member Ada, GET /probe/member<!--/x--></p><!--/errored-->', JSON.stringify([shoutAnswer, carried("/probe/member", 200, '"member Ada, GET /probe/member"')])),
	);
});

test("pages of components: <HttpStatusCode code={404}/> is the answer's status; a page's own doctype isn't written twice", { skip }, async () => {
	const gone = await get("/page-gone");
	assert.equal(gone.status, 404);
	assert.equal(await gone.text(), `<!doctype html><html><body><h1>Not here</h1>${scripts("[]")}</body></html>`);
});

test("pages of components: HEAD isn't rendered: the answer's status and headers, no body", { skip }, async () => {
	const head = await get("/page", { method: "HEAD" });
	assert.equal(head.status, 200);
	assert.equal(head.headers.get("content-type"), "text/html; charset=utf-8");
	assert.equal(head.headers.get("x-page"), "yes");
	assert.equal(await head.text(), "");
	const crashing = await get("/page-crash", { method: "HEAD" });
	assert.equal(crashing.status, 200, "a page that would crash, not rendered");
	assert.equal((await get("/page-crash")).status, 500, "the same page, rendered");
	await logsEvent({ msg: "rocx server: Roc crashed", method: "GET", target: "/page-crash", error: /^a page that crashed/ });
	assert.ok(!events().some((event) => has(event, { method: "HEAD", target: "/page-crash" })));
});

test("pages of components: one that crashes, as it is made or as it renders, or fails with no <Errored> around it, is a 500 (with why under --dev)", { skip }, async () => {
	for (const path of ["/page-crash", "/page-mount-crash", "/page-unhandled"]) {
		const response = await get(path);
		assert.equal(response.status, 500, path);
		assert.equal(response.headers.get("content-type"), "text/plain; charset=utf-8");
		assert.equal(await response.text(), "Something went wrong.", "the crash isn't shown outside dev");
	}
	await logsEvent({ msg: "rocx server: Roc crashed", method: "GET", target: "/page-mount-crash", error: /^a page that crashed as it was made, after 317 strings/ });
	await logsEvent({ msg: "rocx server: Roc crashed", method: "GET", target: "/page-unhandled", error: /^nothing above provides Probe\.missing: render this under its provider \(with no <Errored> around it\)/ });
	const dev = await start(["--dev"]);
	try {
		const crashed = await dev.get("/page-crash");
		assert.equal(crashed.status, 500);
		assert.equal(await crashed.text(), "Roc crashed: a page that crashed");
		const page = await dev.text("/page-gone");
		assert.ok(page.endsWith(`${scripts("[]")}<script data-rocx>if(window.top===window){let gone=false;const at=new EventSource("/__reload");at.onerror=()=>{gone=true};at.onopen=()=>{if(gone)location.reload()}}</script></body></html>`), page);
	} finally {
		await dev.stop();
	}
});

test("pages of components: rendering, calling, failing, crashing and HEAD, 50 rounds, leave nothing allocated", { skip }, async () => {
	for (let i = 0; i < 50; i++) {
		await Promise.all([
			text("/page?from=test"),
			text("/page?from=test", { headers: { cookie: "member=Ada" } }),
			text("/page-gone"),
			text("/page-crash"),
			text("/page-mount-crash"),
			text("/page-unhandled"),
			text("/page", { method: "HEAD" }),
			text("/page-crash", { method: "HEAD" }),
		]);
	}
	assert.equal(await until(async () => (await live()) === baseline), true, `${await live()} allocations, ${baseline} once started`);
});

test("pages of components: an effect, a cleanup and a timer don't run on the server: what they would write isn't written, and nothing is left held", { skip }, async () => {
	const page = await get("/page-effects");
	assert.equal(page.status, 200);
	assert.equal(await page.text(), `<!doctype html><html><body><p class="said"><!--x-->not run<!--/x--></p>${scripts("[]")}</body></html>`);
	const before = await steady();
	for (let i = 0; i < 20; i++) await text("/page-effects");
	assert.equal(await until(async () => (await live()) === before), true, `${await live()} allocations, ${before} before`);
});

test("pages of components: a hole in <title> or <textarea> (RCDATA, read as text) is written without comments, which would show", { skip }, async () => {
	assert.equal(
		await text("/page-rcdata"),
		`<!doctype html><html><head><title>2 notes</title></head><body><textarea>&lt;b&gt;2&lt;/b&gt;</textarea><p><!--x-->2<!--/x--></p>${scripts("[]")}</body></html>`,
	);
});

test("pages of components: a <NoHydration> is static markup between its markers, with none inside; what it reads isn't recorded; a handler inside is refused", { skip }, async () => {
	assert.equal(
		await text("/page-region"),
		`<!doctype html><html><body><p class="count"><!--x-->3<!--/x--></p><!--nohydration--><p>3 &amp; QUIET</p>many<ul><li>ada</li><li>grace</li></ul><i>nothing above provides Probe.missing: render this under its provider</i><b>made once</b>nested<!--/nohydration--><p class="loud"><!--x-->PAGE<!--/x--></p>${scripts(JSON.stringify([carried("/probe/shout/page", 200, '"PAGE"')]))}</body></html>`,
	);
	const refused = await get("/page-region-handler");
	assert.equal(refused.status, 500);
	await logsEvent({ msg: "rocx server: Roc crashed", method: "GET", target: "/page-region-handler", error: "rocx: <button on:click> is inside <NoHydration>, which the browser never hydrates, so its handler would never run: render what has it outside <NoHydration>" });
	const before = await steady();
	for (let i = 0; i < 20; i++) await Promise.all([text("/page-region"), text("/page-region-handler")]);
	assert.equal(await until(async () => (await live()) === before), true, `${await live()} allocations, ${before} before`);
});

test("pages of components: a read its middleware redirects (a signed-out visitor), made as the page renders, makes the page that redirect, its cookies kept; nothing is left held", { skip }, async () => {
	const out = await get("/page-gated", { redirect: "manual" });
	assert.equal(out.status, 303, "not a 500: the gate's redirect");
	assert.equal(out.headers.get("location"), "/login");
	assert.equal(out.headers.get("set-cookie"), "session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0");
	assert.equal(out.headers.get("x-page"), "yes", "the page's own headers kept");
	assert.equal(out.headers.get("content-type"), null, "but not its type: there is no page");
	assert.equal(await out.text(), "");
	const signed = await get("/page-gated", { headers: { cookie: "member=Ada" } });
	assert.equal(signed.status, 200);
	assert.match(await signed.text(), /<header><!--x-->signed in as Ada<!--\/x--><\/header>/);
	const before = await steady();
	for (let i = 0; i < 20; i++) await text("/page-gated");
	assert.equal(await until(async () => (await live()) === before), true, `${await live()} allocations, ${before} before`);
});

// ---- Form actions: a plain form's post, back to its page with a flash ----

/** A form posted as a browser posts one without the runtime: its fields, for a page. */
const plainPost = (path, fields, headers = {}) =>
	get(path, { method: "POST", redirect: "manual", body: new URLSearchParams(fields).toString(), headers: { "content-type": "application/x-www-form-urlencoded", accept: "text/html,application/xhtml+xml,*/*;q=0.8", ...headers } });

/** The `rocx-flash` cookie an answer sets, as a request sends it back (`name=value`). */
const flashOf = (answer) => (answer.headers.get("set-cookie") ?? "").split(";")[0];

// ---- Endpoint reads (D-023): a page's data from a GET endpoint, read as the server renders it ----

/** What a page carries for the browser in its answers script: `[name, input, answer]`s. */
const answersOf = (html) => JSON.parse(/<script type="application\/json" class="rocx-answers">(.*?)<\/script>/s.exec(html)[1]);

test("endpoint reads: a page reads a GET endpoint as the server renders it, in-process, with the page's query, cookies and headers, and notes the answer under its URL, once, none from a <NoHydration>; nothing is left held", { skip }, async () => {
	// A reload's conditions and a range are the page's: the in-process GET doesn't carry them.
	const html = await text("/reads?weeks=1", { headers: { cookie: "member=Ada", "x-probe": "7", accept: "text/html", "if-none-match": '"v1"', range: "bytes=0-9" } });
	assert.match(html, /<p class="data"><!--x-->1 Ada 7<!--\/x--><\/p>/, "the page's query, its cookie and its header, as the in-process GET carried them");
	assert.match(html, /<p class="pending"><!--x-->settled<!--\/x--><\/p>/, "is_pending!: the server renders final values");
	assert.match(html, /<p class="missing"><!--x-->Not found<!--\/x--><\/p>/, "a refusal, as a value (read!)");
	assert.match(html, /<p class="refused"><!--x-->GET \/reads\/missing: 404: Not found<!--\/x--><\/p>/, "and as a failure the <Errored> shows (get!)");
	assert.match(html, /<p class="static">region<\/p>/, "read inside the <NoHydration> too");
	const answers = answersOf(html);
	assert.deepEqual(
		answers.map(([name, input]) => [name, input]),
		[
			["GET /reads?weeks=1", ""],
			["GET /reads/missing", ""],
		],
		"under the URL, its query and all; /reads/missing once, though two holes read it; nothing the <NoHydration> read",
	);
	const [data, missing] = answers.map(([, , answer]) => JSON.parse(answer));
	assert.equal(data.status, 200);
	assert.deepEqual(JSON.parse(data.body), { weeks: "1", member: "Ada", probe: "7" }, "the answer as the browser's GET would get it");
	assert.deepEqual(missing, { status: 404, body: "Not found" }, "a refusal noted too, so the browser fails as the server did");
	// The same URL, asked for JSON, is the endpoint; for HTML, the page.
	const asked = await get("/reads?weeks=1", { headers: { cookie: "member=Ada", "x-probe": "7", accept: "application/json" } });
	assert.equal(asked.headers.get("content-type"), "application/json");
	assert.deepEqual(await asked.json(), { weeks: "1", member: "Ada", probe: "7" });
	// Without the cookie, the page reads as nobody, and still renders.
	assert.match(await text("/reads", { headers: { accept: "text/html" } }), /<p class="data"><!--x--> nobody <!--\/x--><\/p>/);
	const before = await steady();
	for (let i = 0; i < 20; i++) await text("/reads?weeks=2", { headers: { cookie: "member=Ada", accept: "text/html" } });
	assert.equal(await until(async () => (await live()) === before), true, `${await live()} allocations, ${before} before`);
});

test("endpoint reads: one its middleware redirects (a signed-out visitor), made as the page renders, makes the page that redirect, its cookies kept (D-019)", { skip }, async () => {
	const out = await get("/reads-gated", { redirect: "manual" });
	assert.equal(out.status, 303, "not a 500, nor the <Errored>'s fallback: the gate's redirect");
	assert.equal(out.headers.get("location"), "/login");
	assert.equal(out.headers.get("set-cookie"), "session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0");
	assert.equal(out.headers.get("x-page"), "yes", "the page's own headers kept");
	assert.equal(await out.text(), "");
	const signed = await get("/reads-gated", { headers: { cookie: "member=Ada", accept: "text/html" } });
	assert.equal(signed.status, 200);
	const html = await signed.text();
	assert.match(html, /<header><!--x-->member Ada<!--\/x--><\/header>/);
	assert.deepEqual(answersOf(html).map(([name]) => name), ["GET /reads/member"]);
});

test("endpoint reads: a handler that reads the flash (Server.flash!) reads the page's, when the page reads it as it renders; the page lets it go", { skip }, async () => {
	const refused = await plainPost("/flash/join", { name: "Al" }, { referer: `${server.url}/reads-flash` });
	assert.equal(refused.headers.get("location"), "/reads-flash");
	const page = await get("/reads-flash", { headers: { cookie: flashOf(refused), accept: "text/html" } });
	assert.equal(page.status, 200);
	const html = await page.text();
	assert.match(html, /<p class="flash"><!--x-->\/flash\/join 409 Al is taken<!--\/x--><\/p>/, "the in-process GET carried the page's cookie");
	assert.deepEqual(answersOf(html), [["GET /reads/flash", "", JSON.stringify({ status: 200, body: JSON.stringify("/flash/join 409 Al is taken") })]], "noted under the URL, so the browser reads what the server did");
	assert.equal(page.headers.get("set-cookie"), "rocx-flash=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax", "the page's answer lets it go: a reload doesn't show it again");
	assert.match(await text("/reads-flash", { headers: { accept: "text/html" } }), /<p class="flash"><!--x-->no flash<!--\/x--><\/p>/);
});

test("form actions: a plain form's refusal goes back to the page it came from, with a flash: the page reads it (Server.flash!, use_submission!) with what was typed, notes it for the browser, and lets it go", { skip }, async () => {
	const host = new URL(server.url).host;
	const refused = await plainPost("/flash/join", { name: "Al" }, { referer: `${server.url}/flash/page?from=form#top` });
	assert.equal(refused.status, 303, "not the refusal itself: the browser goes back");
	assert.equal(refused.headers.get("location"), "/flash/page?from=form", "to the page it came from (this site's), its fragment dropped");
	const cookie = refused.headers.get("set-cookie");
	assert.match(cookie, /^rocx-flash=[^;]+; Path=\/; Max-Age=60; HttpOnly; SameSite=Lax$/);
	const kept = JSON.parse(decodeURIComponent(flashOf(refused).slice("rocx-flash=".length)));
	assert.deepEqual(kept, { url: "/flash/join", input: "name=Al", status: 409, body: "Al is taken" }, "where it posted, what was typed, and the refusal");
	// The page the browser lands on: the flash and the submission, rendered, and noted for the browser.
	const page = await get("/flash/page?from=form", { headers: { cookie: `a=1; ${flashOf(refused)}`, accept: "text/html" } });
	assert.equal(page.status, 200);
	const html = await page.text();
	assert.match(html, /<p class="flash">\/flash\/join 409 name=Al<\/p>/);
	assert.match(html, /<input name="name" value="Al">/, "what was typed, back in its field");
	assert.match(html, /<p class="problem">Al is taken<\/p><p class="welcome"><\/p><p class="typed">Al<\/p><p class="pending">not pending<\/p>/);
	assert.ok(html.includes(`<script type="application/json" class="rocx-flash">${JSON.stringify(JSON.stringify(kept))}</script><script type="application/json" class="rocx-answers">[]</script>`), "noted for the browser, before the answers");
	assert.equal(page.headers.get("set-cookie"), "rocx-flash=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax", "and let go: a reload doesn't show it again");
	// Without one: none.
	const plain = await text("/flash/page", { headers: { accept: "text/html" } });
	assert.match(plain, /<p class="flash">no flash<\/p>/);
	assert.match(plain, /<p class="problem"><\/p><p class="welcome"><\/p><p class="typed">\(nothing\)<\/p>/);
	assert.doesNotMatch(plain, /rocx-flash/);
	// A flash for another endpoint isn't this submission's, though the page still sees it.
	const other = encodeURIComponent(JSON.stringify({ url: "/elsewhere", input: "name=Bo", status: 400, body: "no" }));
	const elsewhere = await text("/flash/page", { headers: { cookie: `rocx-flash=${other}`, accept: "text/html" } });
	assert.match(elsewhere, /<p class="flash">\/elsewhere 400 name=Bo<\/p>.*<p class="problem"><\/p><p class="welcome"><\/p><p class="typed">\(nothing\)<\/p>/s);
	assert.ok(host);
});

test("form actions: a plain form's result goes back with a flash too; a body it can't read is a refusal; a referrer from elsewhere, or none, goes to /", { skip }, async () => {
	const welcomed = await plainPost("/flash/join", { name: "Ada Lovelace" }, { referer: `${server.url}/flash/page` });
	assert.equal(welcomed.status, 303);
	assert.equal(welcomed.headers.get("location"), "/flash/page");
	const page = await text("/flash/page", { headers: { cookie: flashOf(welcomed), accept: "text/html" } });
	assert.match(page, /<p class="problem"><\/p><p class="welcome">Welcome, Ada Lovelace<\/p><p class="typed">Ada Lovelace<\/p>/);
	const unread = await plainPost("/flash/join", { nickname: "Al" }, { referer: "https://evil.example/flash/page" });
	assert.equal(unread.status, 303);
	assert.equal(unread.headers.get("location"), "/", "another site's page isn't where it goes");
	const kept = JSON.parse(decodeURIComponent(flashOf(unread).slice("rocx-flash=".length)));
	assert.equal(kept.status, 400);
	assert.match(kept.body, /^POST \/flash\/join can't read its body/);
	assert.equal((await plainPost("/flash/join", { name: "" })).headers.get("location"), "/", "no referrer");
	// What a cookie can't hold: the fields are left out, the refusal kept.
	const long = await plainPost("/flash/join", { name: "", notes: "x".repeat(5000) }, { referer: `${server.url}/flash/page` });
	const trimmed = JSON.parse(decodeURIComponent(flashOf(long).slice("rocx-flash=".length)));
	assert.deepEqual([trimmed.input, trimmed.status, trimmed.body], ["", 400, "a member has a name"]);
});

test("form actions: a script's post, or the runtime's, gets the endpoint's answer, not a flash; a redirect of the endpoint's own comes to the runtime as 200 and x-rocx-redirect, its cookie kept", { skip }, async () => {
	const json = await get("/flash/join", { method: "POST", body: JSON.stringify({ name: "Al" }), headers: { "content-type": "application/json", accept: "text/html" } });
	assert.equal(json.status, 409, "JSON isn't a plain form");
	assert.equal(await json.text(), "Al is taken");
	const script = await get("/flash/join", { method: "POST", body: "name=Al", headers: { "content-type": "application/x-www-form-urlencoded" } });
	assert.equal(script.status, 409, "nor is a form a script posts, accepting anything");
	const runtime = { "content-type": "application/x-www-form-urlencoded", accept: "application/json", "x-rocx-submission": "1" };
	const refused = await get("/flash/join", { method: "POST", body: "name=Al", headers: runtime });
	assert.equal(refused.status, 409);
	assert.equal(refused.headers.get("set-cookie"), null);
	assert.equal(await refused.text(), "Al is taken");
	const welcomed = await get("/flash/join", { method: "POST", body: "name=Ada", headers: runtime });
	assert.equal(welcomed.status, 200);
	assert.equal(await welcomed.json(), "Welcome, Ada");
	const away = await get("/flash/away", { method: "POST", body: "", redirect: "manual", headers: runtime });
	assert.equal(away.status, 200, "fetch would follow a 303 before the runtime could read it");
	assert.equal(away.headers.get("x-rocx-redirect"), "/members");
	assert.equal(away.headers.get("location"), null);
	assert.equal(away.headers.get("set-cookie"), "member=Ada; Path=/; HttpOnly; SameSite=Lax");
	const plain = await plainPost("/flash/away", {});
	assert.equal(plain.status, 303, "a plain form gets the endpoint's own answer as it is");
	assert.equal(plain.headers.get("location"), "/members");
	const flashed = encodeURIComponent(JSON.stringify({ url: "/flash/join", input: "name=Al", status: 409, body: "Al is taken" }));
	const before = await steady();
	for (let i = 0; i < 20; i++) await text("/flash/page", { headers: { cookie: `rocx-flash=${flashed}`, accept: "text/html" } });
	assert.equal(await until(async () => (await live()) === before), true, `${await live()} allocations, ${before} before`);
});

// ---- Stopping, memory ----

test("a stop lets the request being answered finish, then the server exits", { skip: skipDb }, async () => {
	const stopping = await start(dbFlags(), app, mailEnv());
	const slow = stopping.get("/sleep");
	await new Promise((resolve) => setTimeout(resolve, 50));
	const exited = stopping.stop();
	const answer = await slow;
	assert.equal(answer.status, 200);
	assert.equal(await answer.text(), "slept");
	assert.equal(await exited, 0);
	await logs(/rocx server: stopping/, stopping);
	await assert.rejects(fetch(`${stopping.url}/`), "it listens no more");
});

test("after all of it, Roc holds no allocations it shouldn't: only what its background loops held from the start", { skip }, async () => {
	assert.equal(await until(async () => (await live()) === baseline), true, `${await live()} allocations, ${baseline} once started`);
});
