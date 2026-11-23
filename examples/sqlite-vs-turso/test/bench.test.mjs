// sqlite-vs-turso, tested: the benchmark run small (size 1) on each engine it compares, SQLite,
// Turso in MVCC mode (its default) and Turso in WAL mode, each on a file of its own. Every workload
// answers, on the engine asked, with what it did; the transactions' bodies ran at least once each
// (on Turso in MVCC mode a loser runs again, so where eight write one counter they may run more),
// and exactly once each where writes take turns.
// What the workloads wrote is checked by the app itself (a lost write is a 500). No database
// server is needed.
//
//   node --test 'examples/sqlite-vs-turso/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildForTests, startServer, repo } from "../../../packages/testing/index.mjs";

let built;
let dir;

before(async () => {
	built = await buildForTests(join(repo, "examples", "sqlite-vs-turso"));
	dir = mkdtempSync(join(tmpdir(), "rocx-sqlite-vs-turso-"));
});

after(() => {
	if (dir) rmSync(dir, { recursive: true, force: true });
});

/** The workloads a run answers, in its order. */
const workloads = [
	"insert-each",
	"insert-batch",
	"read-point",
	"read-range",
	"aggregate",
	"update-each",
	"json",
	"recursive",
	"concurrent-insert",
	"concurrent-own-rows",
	"concurrent-one-row",
	"concurrent-mixed",
];

const engines = [
	{ name: "SQLite", url: () => `sqlite:${join(dir, "sqlite", "bench.db")}`, engine: "sqlite", mvcc: false },
	{ name: "Turso", url: () => `turso:${join(dir, "turso", "bench.db")}`, engine: "turso", mvcc: true },
	{ name: "Turso in WAL mode", url: () => `turso:${join(dir, "wal", "bench.db")}?mvcc=off`, engine: "turso", mvcc: false },
];

for (const { name, url, engine, mvcc } of engines) {
	test(`on ${name}: every workload answers, timed, on the engine asked; what they wrote checks out`, async () => {
		const app = await startServer(built.server, { database: url() });
		try {
			const answer = await fetch(`${app.url}/bench`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ size: 1 }) });
			const text = await answer.text();
			assert.equal(answer.status, 200, text);
			const report = JSON.parse(text);
			assert.equal(report.engine, engine);
			assert.equal(report.size, 1);
			assert.equal(report.rows, 200);
			assert.match(report.version, /^3\.\d+\.\d+$/);
			assert.deepEqual(
				report.workloads.map((workload) => workload.name),
				workloads,
			);
			for (const workload of report.workloads) {
				assert.ok(workload.ops > 0, `${workload.name} did something`);
				assert.ok(workload.ns > 0, `${workload.name} was timed`);
				assert.equal(workload.callers, workload.name.startsWith("concurrent-") ? 8 : 1, `${workload.name}'s callers`);
			}
			const by = Object.fromEntries(report.workloads.map((workload) => [workload.name, workload]));
			assert.equal(by["insert-batch"].runs, 1, "one transaction, run once");
			assert.ok(by["concurrent-own-rows"].runs >= by["concurrent-own-rows"].ops, "each transaction's body ran");
			const shared = by["concurrent-one-row"];
			if (mvcc) assert.ok(shared.runs >= shared.ops, `eight transactions on one row at once: each ran, a loser again (${shared.runs} runs, ${shared.ops} transactions)`);
			else assert.equal(shared.runs, shared.ops, "writes take turns: each body ran once");
			// Again, on the same file: a run starts from fresh tables.
			const again = await fetch(`${app.url}/bench`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ size: 1 }) });
			assert.equal(again.status, 200, await again.text());
		} finally {
			await app.stop();
		}
	});
}
