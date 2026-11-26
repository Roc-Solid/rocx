#!/usr/bin/env node
// Runs examples/sqlite-vs-turso's benchmark for the docs, into site/sqlite-vs-turso.json (committed):
// the app built as it would ship (--opt=speed), then, for each engine it compares (SQLite; Turso,
// its writes at once, MVCC; Turso in WAL mode, its writes taking turns), two servers, each started
// on a fresh file of its own and kept: one asked POST /bench once small to warm up, then `series`
// times in a row at `size`; the other POST /bench/big `bigSeries` times in a row at `orders`. Runs
// in a row on one file are how an app's database lives, written and read for a long time: on
// Turso's MVCC what an earlier run wrote (versions kept in memory) slows later reads, even of
// tables it never touched, so the big run gets a file of its own, and the page shows the first
// run, the first three and all ten (min, average, max). Each run's time for each workload is kept,
// as Roc timed it in the server (Time.now_nanos! around its Db calls), so no HTTP is in it. With
// the machine (site/machine.mjs), its load, the commit, and the engines' versions.
//
//   node site/sqlite-vs-turso.mjs                  size 100 (20,000 items), a million orders, 10 runs of each
//   node site/sqlite-vs-turso.mjs --size 10 --orders 100000 --series 3 --big-series 2
//
// The site's build (`rocx site prepare`, rocx-cli/Site.roc) writes site/Generated/DbBench.roc from
// the file, and the app's page (/examples/sqlite-vs-turso) shows it. It takes a while, so the site's
// build doesn't run it: `just db-bench` does.
import { spawn, spawnSync } from "node:child_process";
import { request } from "node:http";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { loadavg, tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp, roc, rocxBinary } from "../server/build.mjs";
import { machine, machineLine } from "./machine.mjs";

export const root = join(import.meta.dirname, "..");
export const resultsFile = join(root, "site", "sqlite-vs-turso.json");

/** The engines, in the page's order: a key, a label, and the URL of a file in `dir`. */
export const engines = [
	{ key: "sqlite", label: "SQLite", note: "rusqlite, WAL", url: (dir) => `sqlite:${join(dir, "bench.db")}` },
	{ key: "turso", label: "Turso", note: "MVCC, writes at once", url: (dir) => `turso:${join(dir, "bench.db")}` },
	{ key: "turso-wal", label: "Turso, WAL", note: "?mvcc=off, writes take turns", url: (dir) => `turso:${join(dir, "bench.db")}?mvcc=off` },
];

function run(command, args, options = {}) {
	const done = spawnSync(command, args, { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, ...options });
	if (done.status !== 0) throw new Error(`${command} ${args.join(" ")} failed:\n${done.stdout}\n${done.stderr}`);
	return done.stdout;
}

/** turso_core's version, as the host's Cargo.lock pins it. */
function tursoVersion() {
	const lock = readFileSync(join(root, "server", "host", "Cargo.lock"), "utf8");
	return /name = "turso_core"\nversion = "([^"]+)"/.exec(lock)?.[1] ?? "?";
}

/** Starts the server at `executable` on `url`: its origin, and how to stop it. */
async function start(executable, url, cwd) {
	const child = spawn(executable, ["--port", "0", "--database-url", url], { cwd, stdio: ["ignore", "ignore", "pipe"], env: { ...process.env, ROCX_LOG: "pretty", DATABASE_URL: "" } });
	let said = "";
	const origin = await new Promise((resolve, reject) => {
		child.stderr.on("data", (chunk) => {
			said += chunk;
			const listening = /rocx server: (http:\/\/\S+)/.exec(said);
			if (listening) resolve(listening[1]);
		});
		child.on("exit", (code) => reject(new Error(`the server exited (${code}):\n${said}`)));
	});
	const stop = () => new Promise((done) => (child.exitCode !== null ? done() : (child.once("exit", done), child.kill("SIGTERM"))));
	return { origin, stop };
}

/** POST /bench at `size`: the report. */
function bench(origin, size) {
	return posted(origin, "/bench", { size });
}

/** POST `path` with `asked` as JSON: the report. Through node:http, with no time limit (fetch's is 5 minutes). */
function posted(origin, path, asked) {
	const body = JSON.stringify(asked);
	return new Promise((resolve, reject) => {
		const sent = request(`${origin}${path}`, { method: "POST", headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) } }, (answer) => {
			let text = "";
			answer.setEncoding("utf8");
			answer.on("data", (chunk) => (text += chunk));
			answer.on("end", () => (answer.statusCode === 200 ? resolve(JSON.parse(text)) : reject(new Error(`POST ${path} ${body}: ${answer.statusCode} ${text}`))));
		});
		sent.on("error", reject);
		sent.end(body);
	});
}

/** Each workload of the first report, with each engine's time and runs in every report, in order (`of` picks the list). */
function series(reports, of) {
	return of(reports.sqlite[0]).map((workload, index) => ({
		name: workload.name,
		what: workload.what,
		callers: workload.callers,
		ops: workload.ops,
		results: Object.fromEntries(
			engines.map((engine) => {
				const each = reports[engine.key].map((report) => of(report)[index]);
				return [engine.key, { ns: each.map((w) => w.ns), runs: each.map((w) => w.runs) }];
			}),
		),
	}));
}

/** `count` runs in a row of `ask` (its index given), each logged with how long it took: the reports. */
async function inARow(label, count, ask) {
	const reports = [];
	for (let i = 0; i < count; i++) {
		const started = performance.now();
		reports.push(await ask(i));
		process.stderr.write(`${label}: run ${i + 1} of ${count}, ${((performance.now() - started) / 1000).toFixed(1)} s\n`);
	}
	return reports;
}

export async function measure({ size = 100, orders = 1000000, runs = 10, bigRuns = runs } = {}) {
	const rocx = rocxBinary();
	run(rocx, ["generate", "examples/sqlite-vs-turso"], { env: { ...process.env, ROC: roc() } });
	const work = mkdtempSync(join(tmpdir(), "rocx-sqlite-vs-turso-"));
	const executable = join(work, "app");
	buildApp(join(root, "examples", "sqlite-vs-turso", "main.roc"), executable, { opt: "speed" });
	const loadBefore = loadavg()[0];
	const reports = {};
	const bigs = {};
	try {
		for (const engine of engines) {
			const server = await start(executable, engine.url(join(work, engine.key)), work);
			try {
				await bench(server.origin, Math.max(1, Math.floor(size / 10)));
				reports[engine.key] = await inARow(`${engine.label}, everyday`, runs, () => bench(server.origin, size));
			} finally {
				await server.stop();
			}
			const big = await start(executable, engine.url(join(work, `${engine.key}-big`)), work);
			try {
				bigs[engine.key] = await inARow(`${engine.label}, a million rows`, bigRuns, () => posted(big.origin, "/bench/big", { orders }));
			} finally {
				await big.stop();
			}
		}
	} finally {
		rmSync(work, { recursive: true, force: true });
	}
	const first = reports.sqlite[0];
	return {
		measured: new Date().toISOString().slice(0, 10),
		commit: run("git", ["rev-parse", "--short", "HEAD"]).trim(),
		machine: machine(),
		load: `${loadBefore.toFixed(1)} → ${loadavg()[0].toFixed(1)}`,
		opt: "speed",
		size: first.size,
		rows: first.rows,
		orders: bigs.sqlite[0].orders,
		customers: bigs.sqlite[0].customers,
		runs,
		bigRuns,
		engines: engines.map((engine) => ({
			key: engine.key,
			label: engine.label,
			note: engine.note,
			version: engine.key === "sqlite" ? `SQLite ${reports.sqlite[0].version}` : `turso_core ${tursoVersion()}`,
		})),
		workloads: series(reports, (report) => report.workloads),
		big: series(bigs, (report) => report.workloads),
	};
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const argument = (name, fallback) => {
		const at = process.argv.indexOf(name);
		return at >= 0 ? Number(process.argv[at + 1]) : fallback;
	};
	process.stderr.write(`on ${machineLine()}\n`);
	const runs = argument("--series", 10);
	const results = await measure({ size: argument("--size", 100), orders: argument("--orders", 1000000), runs, bigRuns: argument("--big-series", runs) });
	writeFileSync(resultsFile, `${JSON.stringify(results, null, "\t")}\n`);
	console.log(`wrote ${resultsFile}`);
	const average = (values) => values.reduce((sum, v) => sum + v, 0) / values.length;
	for (const workload of [...results.workloads, ...results.big]) {
		const cells = results.engines.map((engine) => {
			const ns = workload.results[engine.key].ns;
			return `${engine.label} ${(ns[0] / 1e6).toFixed(1)} → ${(average(ns) / 1e6).toFixed(1)} ms`;
		});
		console.log(`${workload.name.padEnd(24)} ${cells.join("   ")}`);
	}
}
