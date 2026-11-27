// The server platform on SQLite (D-045) and on Turso (D-046), each test once on each: an app whose
// program says `database: Sqlite(path)` (server/test/sqlite), and a copy of it that says
// `Turso(path)` (built into server/test/build/turso), built natively and run, asked over HTTP. Its
// file is made where the program says, from where the server starts, or at `--database-url
// sqlite:<path>` (`turso:<path>`, which runs either app on Turso); a Postgres URL stops it.
// Parameters are bound as what they are, at their names; rows are read into records (a column
// declared boolean, one declared json, a real, a null); a transaction rolls back on an error, a
// script that fails leaves nothing; writes take turns (each read-then-write in a transaction sees
// the one before) while reads go on beside one; what is notified is heard once its transaction
// commits, and never if it rolls back or crashes; the platform's tables and a plugin's for SQLite
// alone are made, once; an actor's state is kept across a restart; a plugin that needs Postgres is
// refused; the jobs plugin's finished jobs are swept as they age; transactions inside transactions
// are savepoints (D-076, nested-checks.mjs), on Turso in WAL mode too.
//
// Needs the toolchain (`just setup`: Roc, and Rust for the host); no database server.
import { describe, test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp, buildHost, hasRust, roc, root } from "../build.mjs";
import { findChrome, findGecko, launch, launchGecko } from "../../web/test/browser.mjs";
import { adminWorks } from "./admin-checks.mjs";
import { nestedTests } from "./nested-checks.mjs";

let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)");

let dir;
/** The app each engine's tests run: SQLite's, and Turso's copy (`Turso(path)`). */
const apps = {};
/** The engines, as the tests name them and as a program says them. */
const engines = { sqlite: { name: "SQLite", tag: "Sqlite" }, turso: { name: "Turso", tag: "Turso" } };

/** Starts `executable` in `cwd` (made if missing) with `flags`, DATABASE_URL unset unless `environment` sets it;
 * resolves when it listens, or rejects with its log if it exits first. */
function start(flags = [], { executable, cwd = dir, environment = {} } = {}) {
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

/** The fixture's copy for Turso, in server/test/build/turso: its program says `Turso(…)`, its paths
 * one directory deeper, its migrations beside it. */
function tursoCopy() {
	const from = join(root, "server", "test", "sqlite");
	const at = join(root, "server", "test", "build", "turso");
	rmSync(at, { recursive: true, force: true });
	mkdirSync(at, { recursive: true });
	cpSync(join(from, "migrations"), join(at, "migrations"), { recursive: true });
	const source = readFileSync(join(from, "main.roc"), "utf8")
		.replaceAll('"../../platform/main.roc"', '"../../../platform/main.roc"')
		.replaceAll('"../../../packages/', '"../../../../packages/')
		.replace('database: Sqlite("data/sqlite-test.db")', 'database: Turso("data/sqlite-test.db")');
	assert.match(source, /database: Turso\("data\/sqlite-test.db"\)/);
	writeFileSync(join(at, "main.roc"), source);
	return join(at, "main.roc");
}

before(() => {
	if (skip) return;
	dir = mkdtempSync(join(tmpdir(), "rocx-sqlite-"));
	buildHost();
	const opt = process.env.ROCX_TEST_OPT ?? "dev";
	apps.sqlite = join(dir, "app-sqlite");
	buildApp(join(root, "server", "test", "sqlite", "main.roc"), apps.sqlite, { opt });
	apps.turso = join(dir, "app-turso");
	buildApp(tursoCopy(), apps.turso, { opt });
});

after(() => {
	if (dir) rmSync(dir, { recursive: true, force: true });
});

for (const [engine, { name, tag }] of Object.entries(engines)) {
	describe(`on ${name}`, () => {
		/** The server most tests ask: started in a directory of its own, with nothing set. */
		let server;
		/** Where this engine's servers start. */
		let home;
		/** Starts this engine's app (`start`), in a directory under `home`. */
		const run = (flags = [], { cwd = home, ...rest } = {}) => start(flags, { executable: apps[engine], cwd, ...rest });

		before(async () => {
			if (skip) return;
			home = join(dir, engine);
			server = await run([], { cwd: join(home, "main") });
		});

		after(async () => {
			await server?.stop();
		});

		suite({ engine, name, tag, run, server: () => server, home: () => home });
	});
}

/** The tests, for one engine: `run` starts its app, `server()` the one most ask, `home()` where its servers start. */
function suite({ engine, name, tag, run, server, home }) {
	/** The other engine, whose URL runs this app too. */
	const other = engine === "sqlite" ? "turso" : "sqlite";

	test(`its file is where the program says, from where the server starts, made with its directory; its SQL is SQLite's, its engine ${name}`, { skip }, async () => {
		assert.ok(existsSync(join(home(), "main", "data", "sqlite-test.db")));
		assert.equal(await server().text("/flavor"), "sqlite");
		assert.equal(await server().text("/engine"), engine);
	});

	test(`--database-url ${engine}:<path> puts the file elsewhere; DATABASE_URL does too; ${other}:<path> runs it on ${engines[other].name}`, { skip }, async () => {
		const elsewhere = join(home(), "elsewhere", "kept.db");
		const flagged = await run(["--database-url", `${engine}:${elsewhere}`]);
		try {
			assert.equal(await flagged.text("/engine"), engine);
			assert.ok(existsSync(elsewhere));
			assert.ok(!existsSync(join(home(), "data")), "not the program's path");
		} finally {
			await flagged.stop();
		}
		const fromEnv = join(home(), "env", "kept.db");
		const environed = await run([], { environment: { DATABASE_URL: `${engine}://${fromEnv}` } });
		try {
			assert.ok(existsSync(fromEnv));
		} finally {
			await environed.stop();
		}
		const crossed = await run(["--database-url", `${other}:${join(home(), "crossed", "kept.db")}`]);
		try {
			assert.equal(await crossed.text("/flavor"), "sqlite");
			assert.equal(await crossed.text("/engine"), other);
			assert.equal(await crossed.post("/items?name=crossed"), "1");
		} finally {
			await crossed.stop();
		}
	});

	if (engine === "turso") {
		test("its file is Turso's while in MVCC mode: SQLite refuses it, saying how to give it back; ?mvcc=off gives it back", { skip }, async () => {
			const cwd = join(home(), "handed");
			const file = join(cwd, "data", "sqlite-test.db");
			const first = await run([], { cwd });
			assert.equal(await first.post("/items?name=on-turso"), "1");
			await first.stop();
			const refused = await run(["--database-url", `sqlite:${file}`], { cwd }).then(
				() => assert.fail("SQLite opened Turso's MVCC file"),
				(error) => error,
			);
			assert.match(refused.logged, /Turso's file, in its MVCC mode \(D-049\), which SQLite can't read: start the server once with --database-url turso:.*\?mvcc=off/);
			const walled = await run(["--database-url", `turso:${file}?mvcc=off`], { cwd });
			assert.equal(await walled.text("/engine"), "turso");
			await walled.stop();
			const onSqlite = await run(["--database-url", `sqlite:${file}`], { cwd });
			try {
				assert.equal(await onSqlite.text("/engine"), "sqlite");
				assert.match(await onSqlite.text("/items"), /^1 on-turso /);
			} finally {
				await onSqlite.stop();
			}
		});
	}

	test(`a Postgres URL stops a ${name} app at start, saying which it wants`, { skip }, async () => {
		for (const [flags, environment] of [
			[["--database-url", "postgres://nobody@127.0.0.1:1/none"], {}],
			[[], { DATABASE_URL: "postgres://nobody@127.0.0.1:1/none" }],
		]) {
			const refused = await run(flags, { environment }).then(
				() => assert.fail("it started"),
				(error) => error,
			);
			assert.equal(refused.code, 1);
			assert.match(
				refused.logged,
				new RegExp(`the app's database is ${name} \\(its program's \`database: ${tag}\\(\\\\?"data/sqlite-test.db\\\\?"\\)\`\\), and --database-url \\(or DATABASE_URL\\) isn't a sqlite:<path> or turso:<path> one`),
			);
			assert.doesNotMatch(refused.logged, /nobody/, "the URL isn't logged");
		}
	});

	test("parameters are bound as what they are, at their names; rows are read into records: a declared boolean, json, a real, a null; one row read alone (Db.one!), or NotFound", { skip }, async () => {
		assert.equal(await server().post("/items?name=apple&count=3&done=yes&note=crisp&weight=0.25"), "1");
		assert.equal(await server().post("/items?name=pear"), "2");
		assert.equal(await server().text("/items"), "1 apple 3 done crisp a+b 0.25\n2 pear 0 open - a+b -");
		// One row (Db.one!, D-096): the one there is, a null as Db.Nullable; the first of several, in the statement's order; or NotFound.
		assert.equal(await server().text("/items/one?name=pear"), "2 pear -");
		assert.equal(await server().text("/items/newest"), "pear", "the first of the two, newest first");
		assert.equal(await server().text("/items/one?name=plum"), "none");
		assert.equal(await server().text("/params/order"), "b a a");
		assert.equal(await server().text("/params/types"), "integer integer text null");
		assert.equal(await server().text("/params/missing"), "the statement uses $2, and 1 parameter was given");
		assert.equal(await server().text("/params/unused"), "parameter $2 was given, and the statement doesn't use it");
		// A boolean worked out in a statement is 0 or 1.
		assert.equal(await server().text("/exists?name=apple"), "1");
		assert.equal(await server().text("/exists?name=plum"), "0");
		// `run!` counts what an update changed, and nothing for a table made.
		assert.equal(await server().post("/changed?name=apple"), "0 1");
	});

	test("a transaction keeps what it wrote when it commits, and nothing when it fails; a script that fails leaves nothing", { skip }, async () => {
		const before = Number(await server().text("/count"));
		assert.equal(await server().post("/tx?name=kept"), "committed");
		assert.equal(await server().post("/tx?name=gone&fail=yes"), "rolled back: on purpose");
		assert.equal(Number(await server().text("/count")), before + 1);
		assert.match(await server().post("/script/bad"), /^failed: .*no such table: nowhere$/);
		assert.doesNotMatch(await server().text("/counters"), /half/);
	});

	test(`40 requests at once, each reading the counter and writing it back one more in a transaction, make it 40 more: ${engine === "turso" ? "each that lost to another's write ran again" : "writes take turns"}`, { skip }, async () => {
		const at = (counters) => Number(/hits=(\d+)/.exec(counters)[1]);
		const before = at(await server().text("/counters"));
		const bumped = await Promise.all(Array.from({ length: 40 }, () => server().post("/bump?ms=2")));
		assert.deepEqual(
			bumped.map(Number).sort((a, b) => a - b),
			Array.from({ length: 40 }, (_, i) => before + i + 1),
			"each saw the one before",
		);
		assert.equal(at(await server().text("/counters")), before + 40);
	});

	test(
		engine === "turso"
			? "writes go on at once (MVCC): a transaction writing one row doesn't wait for one writing another; two writing the same row both land, the later run again"
			: "a transaction writing one row waits for one writing another to end: writes take turns",
		{ skip },
		async () => {
			const holding = server().post("/bump?name=slow&ms=800");
			await new Promise((resolve) => setTimeout(resolve, 150));
			const started = performance.now();
			assert.match(await server().post("/bump?name=quick"), /^\d+$/);
			const took = performance.now() - started;
			if (engine === "turso") assert.ok(took < 400, `a write beside another took ${Math.round(took)} ms`);
			else assert.ok(took > 400, `a write beside another took ${Math.round(took)} ms: it should have waited its turn`);
			await holding;
			// Two at once on one row: the one that commits second lost (on Turso) and ran again.
			const at = (counters) => Number(new RegExp("same=(\\d+)").exec(counters)?.[1] ?? 0);
			const before = at(await server().text("/counters"));
			const both = await Promise.all([server().post("/bump?name=same&ms=300"), server().post("/bump?name=same&ms=300")]);
			assert.deepEqual(both.map(Number).sort((a, b) => a - b), [before + 1, before + 2], "each saw the other's");
			assert.equal(at(await server().text("/counters")), before + 2);
		},
	);

	test("reads go on while a transaction holds the write lock", { skip }, async () => {
		const holding = server().post("/bump?ms=800");
		await new Promise((resolve) => setTimeout(resolve, 150));
		const started = performance.now();
		await server().text("/count");
		const took = performance.now() - started;
		assert.ok(took < 400, `a read took ${Math.round(took)} ms beside a write`);
		await holding;
	});

	test("what is notified is heard when its transaction commits, at once outside one, and never if it rolls back or crashes", { skip }, async () => {
		const heard = server().text("/listen?ms=1200");
		await new Promise((resolve) => setTimeout(resolve, 200));
		for (const [mode, payload] of [
			["commit", "a"],
			["rollback", "b"],
			["outside", "c"],
			["crash", "d"],
			["commit", "e"],
		]) {
			await fetch(`${server().url}/notify?mode=${mode}&payload=${payload}`, { method: "POST" });
		}
		assert.equal(await heard, "a,c,e");
		assert.match(server().logged(), /a call ended with its transaction open: rolled back/);
	});

	test("the platform's tables and a plugin's for SQLite are made, a plugin's for Postgres isn't; each recorded once, and a restart applies none again", { skip }, async () => {
		assert.equal(
			await server().text("/tables"),
			["admin_authors", "admin_books", "any_flavor", "counters", "flaky", "items", "job_log", "lite_only", "nested_marks", "rocx_actor_timers", "rocx_actors", "rocx_jobs", "rocx_migrations", "scratch"].join("\n"),
		);
		assert.equal(await server().text("/migrated"), ["0001_tables.sql", "0002_admin.sql", "0003_nested.sql", "jobs/0001_jobs", "lite/0001_lite", "lite/0002_any", "rocx/0001 jobs and actors", "rocx/0002 actor timers"].join("\n"));
		assert.match(server().logged(), /migrated  migration="rocx\/0001 jobs and actors"[\s\S]*migrated  migration=jobs\/0001_jobs[\s\S]*migrated  migration=lite\/0001_lite[\s\S]*migrated  migration=0001_tables.sql/);
		const cwd = join(home(), "restarted");
		const first = await run([], { cwd });
		await first.stop();
		const again = await run([], { cwd });
		try {
			assert.doesNotMatch(again.logged(), /rocx server: migrated/);
		} finally {
			await again.stop();
		}
	});

	test("an actor's state is kept in the file: a restart takes it up where it was", { skip }, async () => {
		const cwd = join(home(), "actors");
		const first = await run([], { cwd });
		assert.equal(await first.post("/actors/add?key=k"), "1");
		assert.equal(await first.post("/actors/add?key=k"), "2");
		await first.stop();
		const again = await run([], { cwd });
		try {
			assert.equal(await again.post("/actors/add?key=k"), "3");
		} finally {
			await again.stop();
		}
	});

	test("an actor's timer outlives a restart (D-057): set before a stop, told after the start, once; a cancelled one never", { skip }, async () => {
		const cwd = join(home(), "timers");
		const first = await run([], { cwd });
		let again;
		try {
			assert.match(await first.post("/actors/later?key=t&by=5&ms=1500"), /^\d+$/);
			const cancelled = await first.post("/actors/later?key=t&by=7&ms=1500");
			assert.equal(await first.post(`/actors/cancel?timer=${cancelled}`), "cancelled");
			assert.equal(await first.text("/actors/timers?key=t"), "1");
			await first.stop();
			again = await run([], { cwd });
			assert.equal(await again.text("/actors/count?key=t"), "0", "not yet");
			const told = async () => {
				for (const started = Date.now(); Date.now() - started < 5000; await new Promise((resolve) => setTimeout(resolve, 50))) {
					if ((await again.text("/actors/count?key=t")) === "5") return true;
				}
				return false;
			};
			assert.equal(await told(), true, "told after the start");
			await new Promise((resolve) => setTimeout(resolve, 300));
			assert.equal(await again.text("/actors/count?key=t"), "5", "once");
			assert.equal(await again.text("/actors/timers?key=t"), "0", "its row went");
		} finally {
			await first.stop();
			await again?.stop();
		}
	});

	test(`a plugin that needs Postgres stops a ${name} app at start, saying so`, { skip }, async () => {
		const at = join(root, "server", "test", "build", `needs-postgres-${engine}`);
		mkdirSync(at, { recursive: true });
		writeFileSync(
			join(at, "main.roc"),
			`app [program] { pf: platform "../../../platform/main.roc" }\n\nimport pf.Plugin\nimport pf.Server\n\nprogram = {\n\tinit!: |started| Ok(started),\n\trespond!: |_, _| Server.response(200, [], ""),\n\tdatabase: ${tag}("data/needs.db"),\n\tmigrations: [],\n\tactors: [],\n\tlogs: { format: Auto },\n\tplugins: [Plugin.running({ name: "pg-only", needs: [Postgres] })],\n\troutes: [],\n}\n`,
		);
		const executable = join(home(), "needs-postgres");
		buildApp(join(at, "main.roc"), executable, { opt: "dev" });
		const refused = await start([], { executable, cwd: join(home(), "needs") }).then(
			() => assert.fail("it started"),
			(error) => error,
		);
		assert.equal(refused.code, 1);
		assert.match(refused.logged, new RegExp(`pg-only: it needs Postgres, and the app's database is ${name}`));
	});

	// ---- Jobs and cron (packages/jobs on SQLite's SQL) ----

	test("jobs: queued and run; queued in a transaction, run only if it commits; tried again until it passes", { skip }, async () => {
		assert.equal(await server().post("/jobs/note?said=hello"), "queued");
		assert.equal(await server().post("/jobs/note-tx?said=kept"), "committed");
		assert.equal(await server().post("/jobs/note-tx?said=dropped&fail=yes"), "rolled back: on purpose");
		assert.equal(await server().post("/jobs/flaky?name=f1&fails=2"), "queued");
		await until(async () => (await server().text("/jobs/log")).includes("flaky f1 done"));
		const log = await server().text("/jobs/log");
		assert.match(log, /^note hello$/m);
		assert.match(log, /^note kept$/m);
		assert.doesNotMatch(log, /dropped/);
		assert.match(await server().text("/jobs/list?kind=flaky"), /^\d+ flaky done 3 -$/m, "tried three times");
	});

	test("jobs: a key is one pending job's; a keyed job is cancelled or moved by it", { skip }, async () => {
		assert.equal(await server().post("/jobs/keyed?key=k1&said=later&in_ms=60000"), "queued");
		assert.equal(await server().post("/jobs/keyed?key=k1&said=again&in_ms=60000"), "exists");
		assert.equal(await server().post("/jobs/keyed?key=k2&said=moved&in_ms=60000"), "queued");
		assert.equal(await server().post("/jobs/cancel?key=k1"), "1");
		assert.equal(await server().post("/jobs/cancel?key=k1"), "0");
		assert.equal(await server().post("/jobs/move?key=k2"), "1");
		await until(async () => /^note moved$/m.test(await server().text("/jobs/log")));
		assert.doesNotMatch(await server().text("/jobs/log"), /later|again/);
		// Canceled, the key is free again.
		assert.equal(await server().post("/jobs/keyed?key=k1&said=free&in_ms=60000"), "queued");
		assert.equal(await server().post("/jobs/cancel?key=k1"), "1");
	});

	test("jobs: one past its time limit is cut off, its statement interrupted and its transaction rolled back; the next write doesn't wait; retried, it is queued again", { skip }, async () => {
		assert.equal(await server().post("/jobs/slow?said=slow1"), "queued");
		let failed;
		await until(async () => (failed = /^(\d+) slow failed 1 timed out after 300 ms$/m.exec(await server().text("/jobs/list?kind=slow"))) !== null);
		assert.doesNotMatch(await server().text("/jobs/log"), /slow1/, "its write rolled back");
		const started = performance.now();
		assert.match(await server().post("/items?name=after-slow"), /^\d+$/);
		assert.ok(performance.now() - started < 500, "the write lock was let go");
		assert.equal(await server().post(`/jobs/retry?id=${failed[1]}`), "retried");
		await until(async () => new RegExp(`^${failed[1]} slow failed 1 timed out`, "m").test(await server().text("/jobs/list?kind=slow")));
	});

	test("cron: a schedule each second queues its job, once a second", { skip }, async () => {
		const before = Number(await server().text("/jobs/ticks"));
		await until(async () => Number(await server().text("/jobs/ticks")) >= before + 2, 4000);
		assert.match(await server().text("/jobs/counts"), /^tick done \d+$/m);
	});

	test(`the jobs page shows the queue and the last hour, with no problem, and names ${name}`, { skip }, async () => {
		const page = await (await fetch(`${server().url}/admin/jobs`)).text();
		assert.match(page, /Finished jobs/);
		assert.doesNotMatch(page, /class="problem"/);
		assert.match(page, new RegExp(`The queue, in ${name}`));
	});

	// The jobs page's script (packages/admin's AdminHtml), in a browser: once, on SQLite, in
	// Chromium and in Gecko (Zen or Firefox).
	for (const [browserName, find, open] of [
		["Chromium", findChrome, launch],
		["Gecko", findGecko, launchGecko],
	]) {
		const browserSkip = skip || (engine !== "sqlite" && "once, on SQLite") || (!find() && `no ${browserName}`);
		test(`the jobs page answers its own links and forms in place, as View Transitions, in ${browserName}: the sidebar held, a page fading through, a drawer sliding in and out; Back and Forward; its stream kept open; none with less motion asked for; a link elsewhere loads its page`, { skip: browserSkip }, async () => {
			await inPlace(open, server());
		});
	}

	test("jobs: finished ones are swept once older than the plugin keeps them (done an hour, failed and canceled two), every half second; queued ones never", { skip }, async () => {
		const minutes = 60_000;
		const aged = [
			["done", 90, "done-old"],
			["done", 30, "done-young"],
			["failed", 180, "failed-old"],
			["failed", 90, "failed-young"],
			["canceled", 180, "canceled-old"],
			["canceled", 90, "canceled-young"],
			["queued", 180, "queued-old"],
		];
		for (const [state, age, key] of aged) assert.equal(await server().post(`/jobs/aged?state=${state}&age=${age * minutes}&key=${key}`), "added");
		const left = async () => (await server().text("/jobs/aged")).split("\n").filter(Boolean);
		await until(async () => (await left()).length === 4, 3000);
		assert.deepEqual(await left(), ["done-young", "failed-young", "canceled-young", "queued-old"]);
	});

	// ---- Transactions inside transactions (D-076) ----

	nestedTests({ test, server, engine, skip });

	if (engine === "turso") {
		describe("in WAL mode (?mvcc=off)", () => {
			/** The app on Turso with its file in WAL mode, where writes take turns as on SQLite. */
			let walled;
			before(async () => {
				if (skip) return;
				const cwd = join(home(), "wal");
				walled = await run(["--database-url", `turso:${join(cwd, "data", "wal.db")}?mvcc=off`], { cwd });
			});
			after(async () => {
				await walled?.stop();
			});
			nestedTests({ test, server: () => walled, engine: "turso-wal", skip, prefix: "in WAL mode: " });
		});
	}

	test(`packages/admin on ${name}: its catalog read from SQLite's pragmas, a check's values and a foreign key as choices, a row created, found, changed and deleted, a boolean written as 1 or 0 and read back`, { skip }, async () => {
		await adminWorks(server().url);
	});

	test(`--describe-sql (D-058): ${name} describes each statement on a scratch file made from the program's migrations and removed after, never the program's, nor a Postgres URL in the environment: parameters, each column's declared type, how the host reads it, the table column it comes from and whether that is not null (none for an expression); or ${name}'s error`, { skip }, async () => {
		const cwd = join(home(), "described");
		mkdirSync(cwd, { recursive: true });
		const list = join(cwd, "statements.json");
		writeFileSync(
			list,
			JSON.stringify([
				"select id, name, done, note, meta, weight, count + 1 as more from items where id = $1 and name = $2",
				"select missing from items",
				"insert into items (name) values ($1) returning id",
			]),
		);
		const scratches = () => readdirSync(tmpdir()).filter((name) => name.startsWith("rocx-check-"));
		const before = scratches();
		// A Postgres URL in the environment (as a shell after `just db` has) is no SQLite app's: left alone.
		const env = { ...process.env, ROCX_LOG: "json", DATABASE_URL: "postgres://nobody@127.0.0.1:9/nowhere" };
		const ran = spawnSync(apps[engine], ["--describe-sql", list], { cwd, env, encoding: "utf8" });
		assert.equal(ran.status, 0, ran.stderr);
		const said = JSON.parse(ran.stdout);
		assert.equal(said.engine, engine);
		const [read, wrong, inserted] = said.statements;
		assert.deepEqual(read.params, ["$1", "$2"]);
		assert.deepEqual(
			read.columns.map(({ name, type, kind, table, column, not_null }) => [name, type?.toLowerCase() ?? null, kind, table, column, not_null]),
			[
				["id", "integer", "integer", "items", "id", true],
				["name", "text", "text", "items", "name", true],
				["done", "boolean", "boolean", "items", "done", true],
				["note", "text", "text", "items", "note", false],
				["meta", "json", "json", "items", "meta", false],
				["weight", "real", "real", "items", "weight", false],
				["more", null, null, null, null, null],
			],
		);
		assert.match(wrong.error, /no such column: missing/);
		assert.deepEqual(inserted.columns.map(({ name, not_null }) => [name, not_null]), [["id", true]]);
		assert.ok(!existsSync(join(cwd, "data")), "the program's file isn't made");
		assert.deepEqual(scratches(), before, "the scratch file's directory is gone");
	});
}

/** The jobs page of `server` in a browser `open` launches (`launch`, `launchGecko`): its links, a
 * job's drawer, Escape, Back and Forward, and a form, each answered in place as a View Transition of
 * its kind (AdminHtml's script and stylesheet); with less motion asked for, none (where the browser
 * can be asked: Chromium); and a link to another path loaded whole. */
async function inPlace(open, server) {
	const browser = await open();
	try {
		const tab = await browser.page();
		// A desktop's width: on a narrow screen the sidebar is above the page and changes with it.
		if (tab.send) await tab.send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
		else await tab.bidi("browsingContext.setViewport", { context: tab.context, viewport: { width: 1280, height: 900 } });
		// Before the page's own script: each stream it opens, each form it posts, and each transition,
		// its kind (`html[data-moving]`) and what it animates once its pseudo-elements are there.
		await tab.beforeEachDocument(`
			window.streams = 0; const Source = window.EventSource; window.EventSource = class extends Source { constructor(...args) { super(...args); window.streams++; } };
			window.posts = []; const fetched = window.fetch; window.fetch = (url, init = {}) => { if (init.method === "POST") window.posts.push(String(init.body)); return fetched(url, init); };
			window.transitions = []; window.playing = 0; const original = document.startViewTransition.bind(document);
			document.startViewTransition = (update) => {
				const transition = original(update), kind = document.documentElement.dataset.moving;
				window.playing++; const done = () => window.playing--; transition.finished.then(done, done);
				transition.ready.then(() => window.transitions.push({ kind, animated: document.getAnimations().map((animation) => animation.effect.pseudoElement + " " + animation.animationName).sort() }), () => window.transitions.push({ kind, skipped: true }));
				return transition;
			};`);
		await tab.goto(`${server.url}/admin/jobs`);
		await tab.eval("window.marker = 'kept'");
		await tab.wait("document.documentElement.dataset.live === 'on'");
		// A transition playing covers the page: each step waits for it to end, and for its fetch.
		const settled = () => tab.wait("window.playing === 0 && !('going' in document.documentElement.dataset)");
		const last = () => tab.eval("window.transitions.at(-1)");
		const has = (transition, wanted) => assert.ok(transition.animated.some((animation) => animation.startsWith(wanted)), `${wanted}: ${transition.animated.join(", ")}`);

		// Another state, from the sidebar: a page; the sidebar held, the rest fading out and in.
		await tab.click('.side-nav a[href="/admin/jobs?state=done"]');
		await tab.wait("location.search === '?state=done' && document.querySelector('main h1').textContent === 'Done jobs'");
		await settled();
		assert.equal(await tab.eval("window.marker"), "kept", "in place, not a page loaded whole");
		assert.equal(await tab.eval("document.title"), "Done jobs");
		assert.equal(await tab.eval("document.querySelector('.side-nav a[aria-current=page]').getAttribute('href')"), "/admin/jobs?state=done", "the sidebar says where");
		assert.equal(await tab.eval("document.activeElement === document.querySelector('main h1')"), true, "its heading has the focus");
		const page = await last();
		assert.equal(page.kind, "page");
		has(page, "::view-transition-old(root) admin-fade-out");
		has(page, "::view-transition-new(root) admin-enter");
		has(page, "::view-transition-group(admin-side)");

		// A job, in a drawer: it slides in, the list stays where it was scrolled to.
		// (Four jobs at least: the schedule queues one each second, and the stream brings them in.)
		await tab.wait("document.querySelectorAll('table.jobs tbody tr').length >= 4", 10000);
		await tab.eval("scrollTo(0, 200)");
		const { x, y } = await tab.center("table.jobs tbody tr:nth-child(4) a.row-link");
		const scrolled = await tab.eval("scrollY");
		await tab.clickAt(x, y);
		await tab.wait("document.querySelector('.drawer') && new URLSearchParams(location.search).has('id')");
		await settled();
		const opened = await tab.eval("location.pathname + location.search");
		const drawer = await last();
		assert.equal(drawer.kind, "drawer");
		has(drawer, "::view-transition-new(admin-drawer) admin-drawer-in");
		has(drawer, "::view-transition-new(root) admin-fade-in");
		assert.ok(!drawer.animated.some((animation) => animation.includes("admin-side")), `the sidebar the page's, under the scrim with it: ${drawer.animated.join(", ")}`);
		assert.equal(await tab.eval("scrollY"), scrolled, "the list behind it where it was");
		assert.equal(await tab.eval("document.activeElement === document.querySelector('.drawer')"), true, "the drawer has the focus");
		assert.equal(await tab.eval("document.title"), `Job #${new URLSearchParams(opened.split("?")[1]).get("id")} · Jobs`);

		// Escape closes it: it slides out, and the link to it has the focus.
		await tab.press("Escape");
		await tab.wait("!document.querySelector('.drawer') && location.search === '?state=done'");
		await settled();
		const closed = await last();
		assert.equal(closed.kind, "drawer");
		has(closed, "::view-transition-old(admin-drawer) admin-drawer-out");
		assert.ok(!closed.animated.some((animation) => animation.includes("admin-side")), closed.animated.join(", "));
		assert.equal(await tab.eval("document.activeElement.getAttribute('href')"), opened, "the link to the job it showed");

		// Back and Forward: each address's page, fetched.
		await tab.eval("history.back()");
		await tab.wait(`location.pathname + location.search === ${JSON.stringify(opened)} && document.querySelector('.drawer')`);
		await settled();
		await tab.eval("history.back()");
		await tab.wait("location.search === '?state=done' && !document.querySelector('.drawer')");
		await settled();
		await tab.eval("history.back()");
		await tab.wait("location.search === '' && document.querySelector('main h1').textContent === 'Jobs'");
		await settled();
		await tab.eval("history.forward()");
		await tab.wait("location.search === '?state=done' && document.querySelector('main h1').textContent === 'Done jobs'");
		await settled();
		await tab.eval("history.back()");
		await tab.wait("location.search === '' && document.querySelector('main h1').textContent === 'Jobs'");
		await settled();

		// A form, posted in place: back where it was sent from, the same address, so no new entry.
		const entries = await tab.eval("history.length");
		await tab.click(".schedule form.act button");
		await tab.wait("window.posts.length === 1");
		await settled();
		assert.match(await tab.eval("window.posts[0]"), /^action=run_schedule&name=[^&]+&back=$/);
		assert.equal((await last()).kind, "same");
		assert.equal(await tab.eval("location.search"), "");
		assert.equal(await tab.eval("history.length"), entries, "replaced, not pushed");

		assert.equal(await tab.eval("window.marker"), "kept", "every step in place");
		assert.equal(await tab.eval("window.streams"), 1, "one stream, open all along");
		assert.equal(await tab.eval("document.documentElement.dataset.live"), "on");

		// Less motion asked for (Chromium's DevTools protocol emulates it): still in place, with no transition.
		if (tab.send) await tab.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
		const transitions = await tab.eval("window.transitions.length");
		await tab.click('.side-nav a[href="/admin/jobs?state=failed"]');
		await tab.wait("location.search === '?state=failed' && document.querySelector('main h1').textContent === 'Failed jobs'");
		if (tab.send) assert.equal(await tab.eval("window.transitions.length"), transitions, "none");
		assert.equal(await tab.eval("window.marker"), "kept");

		// On a narrow screen the sidebar is above the page, scrolling away with it: not held, so it changes with it.
		assert.equal(await tab.eval("getComputedStyle(document.querySelector('.side')).viewTransitionName"), "admin-side");
		if (tab.send) await tab.send("Emulation.setDeviceMetricsOverride", { width: 600, height: 900, deviceScaleFactor: 1, mobile: false });
		else await tab.bidi("browsingContext.setViewport", { context: tab.context, viewport: { width: 600, height: 900 } });
		await tab.wait("getComputedStyle(document.querySelector('.side')).viewTransitionName === 'none'");

		// The link back to the app is another page's: loaded whole, as it was.
		await tab.click(".side-nav a.back");
		await tab.wait("location.pathname === '/' && window.marker === undefined");
		assert.deepEqual(tab.errors, []);
	} finally {
		await browser.close();
	}
}


/** Waits until `check` (async) is true, or fails after `ms`. */
async function until(check, ms = 5000) {
	const started = performance.now();
	while (!(await check())) {
		if (performance.now() - started > ms) assert.fail(`not within ${ms} ms`);
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
}
