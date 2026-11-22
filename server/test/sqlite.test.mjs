// The server platform on SQLite (D-045): an app whose program says `database: Sqlite(path)`
// (server/test/sqlite), built natively and run, asked over HTTP. Its file is made where the program
// says, from where the server starts, or at `--database-url sqlite:<path>`; a Postgres URL stops it.
// Parameters are bound as what they are, at their names; rows are read into records (a column
// declared boolean, one declared json, a real, a null); a transaction rolls back on an error, a
// script that fails leaves nothing; writes take turns (each read-then-write in a transaction sees
// the one before) while reads go on beside one; what is notified is heard once its transaction
// commits, and never if it rolls back or crashes; the platform's tables and a plugin's for SQLite
// alone are made, once; an actor's state is kept across a restart; a plugin that needs Postgres is
// refused.
//
// Needs the toolchain (`just setup`: Roc, and Rust for the host); no database server.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp, buildHost, hasRust, roc, root } from "../build.mjs";

let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)");

let dir;
let app;
/** The server most tests ask: started in a directory of its own, with nothing set. */
let server;

/** Starts `executable` in `cwd` (made if missing) with `flags`, DATABASE_URL unset unless `environment` sets it;
 * resolves when it listens, or rejects with its log if it exits first. */
function start(flags = [], { executable = app, cwd = dir, environment = {} } = {}) {
	mkdirSync(cwd, { recursive: true });
	const env = { ...process.env, ROCX_LOG: "pretty", ...environment };
	if (!("DATABASE_URL" in environment)) delete env.DATABASE_URL;
	const child = spawn(executable, ["--port", "0", ...flags], { cwd, stdio: ["ignore", "ignore", "pipe"], env });
	let logged = "";
	return new Promise((resolve, reject) => {
		child.stderr.on("data", (chunk) => {
			logged += chunk;
			const match = /rocx server: (http:\/\/\S+)/.exec(logged);
			if (match) {
				const url = match[1];
				resolve({
					url,
					logged: () => logged,
					text: async (path, options) => (await fetch(`${url}${path}`, options)).text(),
					post: async (path) => (await fetch(`${url}${path}`, { method: "POST" })).text(),
					stop: () => new Promise((done) => (child.exitCode !== null ? done(child.exitCode) : (child.once("exit", done), child.kill("SIGTERM")))),
				});
			}
		});
		child.on("exit", (code) => reject(Object.assign(new Error(`the server exited (${code}):\n${logged}`), { code, logged })));
	});
}

before(async () => {
	if (skip) return;
	dir = mkdtempSync(join(tmpdir(), "rocx-sqlite-"));
	app = join(dir, "app");
	buildHost();
	buildApp(join(root, "server", "test", "sqlite", "main.roc"), app, { opt: process.env.ROCX_TEST_OPT ?? "dev" });
	server = await start([], { cwd: join(dir, "main") });
});

after(async () => {
	await server?.stop();
	if (dir) rmSync(dir, { recursive: true, force: true });
});

test("its file is where the program says, from where the server starts, made with its directory; the app's database is SQLite", { skip }, async () => {
	assert.ok(existsSync(join(dir, "main", "data", "sqlite-test.db")));
	assert.equal(await server.text("/flavor"), "sqlite");
});

test("--database-url sqlite:<path> puts the file elsewhere; DATABASE_URL does too", { skip }, async () => {
	const elsewhere = join(dir, "elsewhere", "kept.db");
	const flagged = await start(["--database-url", `sqlite:${elsewhere}`], { cwd: dir });
	try {
		assert.equal(await flagged.text("/flavor"), "sqlite");
		assert.ok(existsSync(elsewhere));
		assert.ok(!existsSync(join(dir, "data")), "not the program's path");
	} finally {
		await flagged.stop();
	}
	const fromEnv = join(dir, "env", "kept.db");
	const environed = await start([], { cwd: dir, environment: { DATABASE_URL: `sqlite://${fromEnv}` } });
	try {
		assert.ok(existsSync(fromEnv));
	} finally {
		await environed.stop();
	}
});

test("a Postgres URL stops a SQLite app at start, saying which it wants", { skip }, async () => {
	for (const [flags, environment] of [
		[["--database-url", "postgres://nobody@127.0.0.1:1/none"], {}],
		[[], { DATABASE_URL: "postgres://nobody@127.0.0.1:1/none" }],
	]) {
		const refused = await start(flags, { cwd: dir, environment }).then(
			() => assert.fail("it started"),
			(error) => error,
		);
		assert.equal(refused.code, 1);
		assert.match(refused.logged, /the app's database is SQLite \(its program's `database: Sqlite\(\\?"data\/sqlite-test.db\\?"\)`\), and --database-url \(or DATABASE_URL\) isn't a sqlite:<path> one/);
		assert.doesNotMatch(refused.logged, /nobody/, "the URL isn't logged");
	}
});

test("parameters are bound as what they are, at their names; rows are read into records: a declared boolean, json, a real, a null", { skip }, async () => {
	assert.equal(await server.post("/items?name=apple&count=3&done=yes&note=crisp&weight=0.25"), "1");
	assert.equal(await server.post("/items?name=pear"), "2");
	assert.equal(await server.text("/items"), "1 apple 3 done crisp a+b 0.25\n2 pear 0 open - a+b -");
	assert.equal(await server.text("/params/order"), "b a a");
	assert.equal(await server.text("/params/types"), "integer integer text null");
	assert.equal(await server.text("/params/missing"), "the statement uses $2, and 1 parameter was given");
	assert.equal(await server.text("/params/unused"), "parameter $2 was given, and the statement doesn't use it");
	// A boolean SQLite works out is 0 or 1.
	assert.equal(await server.text("/exists?name=apple"), "1");
	assert.equal(await server.text("/exists?name=plum"), "0");
	// `run!` counts what an update changed, and nothing for a table made.
	assert.equal(await server.post("/changed?name=apple"), "0 1");
});

test("a transaction keeps what it wrote when it commits, and nothing when it fails; a script that fails leaves nothing", { skip }, async () => {
	const before = Number(await server.text("/count"));
	assert.equal(await server.post("/tx?name=kept"), "committed");
	assert.equal(await server.post("/tx?name=gone&fail=yes"), "rolled back: on purpose");
	assert.equal(Number(await server.text("/count")), before + 1);
	assert.equal(await server.post("/script/bad"), "failed: no such table: nowhere");
	assert.doesNotMatch(await server.text("/counters"), /half/);
});

test("writes take turns: 40 requests at once, each reading the counter and writing it back one more in a transaction, make it 40 more", { skip }, async () => {
	const at = (counters) => Number(/hits=(\d+)/.exec(counters)[1]);
	const before = at(await server.text("/counters"));
	const bumped = await Promise.all(Array.from({ length: 40 }, () => server.post("/bump?ms=2")));
	assert.deepEqual(
		bumped.map(Number).sort((a, b) => a - b),
		Array.from({ length: 40 }, (_, i) => before + i + 1),
		"each saw the one before",
	);
	assert.equal(at(await server.text("/counters")), before + 40);
});

test("reads go on while a transaction holds the write lock", { skip }, async () => {
	const holding = server.post("/bump?ms=800");
	await new Promise((resolve) => setTimeout(resolve, 150));
	const started = performance.now();
	await server.text("/count");
	const took = performance.now() - started;
	assert.ok(took < 400, `a read took ${Math.round(took)} ms beside a write`);
	await holding;
});

test("what is notified is heard when its transaction commits, at once outside one, and never if it rolls back or crashes", { skip }, async () => {
	const heard = server.text("/listen?ms=1200");
	await new Promise((resolve) => setTimeout(resolve, 200));
	for (const [mode, payload] of [
		["commit", "a"],
		["rollback", "b"],
		["outside", "c"],
		["crash", "d"],
		["commit", "e"],
	]) {
		await fetch(`${server.url}/notify?mode=${mode}&payload=${payload}`, { method: "POST" });
	}
	assert.equal(await heard, "a,c,e");
	assert.match(server.logged(), /a call ended with its transaction open: rolled back/);
});

test("the platform's tables and a plugin's for SQLite are made, a plugin's for Postgres isn't; each recorded once, and a restart applies none again", { skip }, async () => {
	assert.equal(
		await server.text("/tables"),
		["any_flavor", "counters", "flaky", "items", "job_log", "lite_only", "rocx_actors", "rocx_jobs", "rocx_migrations", "scratch"].join("\n"),
	);
	assert.equal(await server.text("/migrated"), ["0001_tables.sql", "jobs/0001_jobs", "lite/0001_lite", "lite/0002_any", "rocx/0001 jobs and actors"].join("\n"));
	assert.match(server.logged(), /migrated: rocx\/0001 jobs and actors[\s\S]*migrated: jobs\/0001_jobs[\s\S]*migrated: lite\/0001_lite[\s\S]*migrated: 0001_tables.sql/);
	const cwd = join(dir, "restarted");
	const first = await start([], { cwd });
	await first.stop();
	const again = await start([], { cwd });
	try {
		assert.doesNotMatch(again.logged(), /migrated:/);
	} finally {
		await again.stop();
	}
});

test("an actor's state is kept in the file: a restart takes it up where it was", { skip }, async () => {
	const cwd = join(dir, "actors");
	const first = await start([], { cwd });
	assert.equal(await first.post("/actors/add?key=k"), "1");
	assert.equal(await first.post("/actors/add?key=k"), "2");
	await first.stop();
	const again = await start([], { cwd });
	try {
		assert.equal(await again.post("/actors/add?key=k"), "3");
	} finally {
		await again.stop();
	}
});

test("a plugin that needs Postgres stops a SQLite app at start, saying so", { skip }, async () => {
	const at = join(root, "server", "test", "build", "needs-postgres");
	mkdirSync(at, { recursive: true });
	writeFileSync(
		join(at, "main.roc"),
		'app [program] { pf: platform "../../../platform/main.roc" }\n\nimport pf.Plugin\nimport pf.Server\n\nprogram = {\n\trespond!: |_, _| Server.response(200, [], ""),\n\tdatabase: Sqlite("data/needs.db"),\n\tmigrations: [],\n\tactors: [],\n\tlogs: { format: Auto },\n\tplugins: [Plugin.running({ name: "pg-only", needs: [Postgres] })],\n\troutes: [],\n}\n',
	);
	const executable = join(dir, "needs-postgres");
	buildApp(join(at, "main.roc"), executable, { opt: "dev" });
	const refused = await start([], { executable, cwd: join(dir, "needs") }).then(
		() => assert.fail("it started"),
		(error) => error,
	);
	assert.equal(refused.code, 1);
	assert.match(refused.logged, /pg-only: it needs Postgres, and the app's database is SQLite/);
});

// ---- Jobs and cron (packages/jobs on SQLite) ----

/** Waits until `check` (async) is true, or fails after `ms`. */
async function until(check, ms = 5000) {
	const started = performance.now();
	while (!(await check())) {
		if (performance.now() - started > ms) assert.fail(`not within ${ms} ms`);
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
}

test("jobs: queued and run; queued in a transaction, run only if it commits; tried again until it passes", { skip }, async () => {
	assert.equal(await server.post("/jobs/note?said=hello"), "queued");
	assert.equal(await server.post("/jobs/note-tx?said=kept"), "committed");
	assert.equal(await server.post("/jobs/note-tx?said=dropped&fail=yes"), "rolled back: on purpose");
	assert.equal(await server.post("/jobs/flaky?name=f1&fails=2"), "queued");
	await until(async () => (await server.text("/jobs/log")).includes("flaky f1 done"));
	const log = await server.text("/jobs/log");
	assert.match(log, /^note hello$/m);
	assert.match(log, /^note kept$/m);
	assert.doesNotMatch(log, /dropped/);
	assert.match(await server.text("/jobs/list?kind=flaky"), /^\d+ flaky done 3 -$/m, "tried three times");
});

test("jobs: a key is one pending job's; a keyed job is cancelled or moved by it", { skip }, async () => {
	assert.equal(await server.post("/jobs/keyed?key=k1&said=later&in_ms=60000"), "queued");
	assert.equal(await server.post("/jobs/keyed?key=k1&said=again&in_ms=60000"), "exists");
	assert.equal(await server.post("/jobs/keyed?key=k2&said=moved&in_ms=60000"), "queued");
	assert.equal(await server.post("/jobs/cancel?key=k1"), "1");
	assert.equal(await server.post("/jobs/cancel?key=k1"), "0");
	assert.equal(await server.post("/jobs/move?key=k2"), "1");
	await until(async () => /^note moved$/m.test(await server.text("/jobs/log")));
	assert.doesNotMatch(await server.text("/jobs/log"), /later|again/);
	// Canceled, the key is free again.
	assert.equal(await server.post("/jobs/keyed?key=k1&said=free&in_ms=60000"), "queued");
	assert.equal(await server.post("/jobs/cancel?key=k1"), "1");
});

test("jobs: one past its time limit is cut off, its statement interrupted and its transaction rolled back; the next write doesn't wait; retried, it is queued again", { skip }, async () => {
	assert.equal(await server.post("/jobs/slow?said=slow1"), "queued");
	let failed;
	await until(async () => (failed = /^(\d+) slow failed 1 timed out after 300 ms$/m.exec(await server.text("/jobs/list?kind=slow"))) !== null);
	assert.doesNotMatch(await server.text("/jobs/log"), /slow1/, "its write rolled back");
	const started = performance.now();
	assert.match(await server.post("/items?name=after-slow"), /^\d+$/);
	assert.ok(performance.now() - started < 500, "the write lock was let go");
	assert.equal(await server.post(`/jobs/retry?id=${failed[1]}`), "retried");
	await until(async () => new RegExp(`^${failed[1]} slow failed 1 timed out`, "m").test(await server.text("/jobs/list?kind=slow")));
});

test("cron: a schedule each second queues its job, once a second", { skip }, async () => {
	const before = Number(await server.text("/jobs/ticks"));
	await until(async () => Number(await server.text("/jobs/ticks")) >= before + 2, 4000);
	assert.match(await server.text("/jobs/counts"), /^tick done \d+$/m);
});

test("the jobs page shows the queue and the last hour, with no problem", { skip }, async () => {
	const page = await (await fetch(`${server.url}/admin/jobs`)).text();
	assert.match(page, /Finished jobs/);
	assert.doesNotMatch(page, /class="problem"/);
});
