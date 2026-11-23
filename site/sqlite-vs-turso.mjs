#!/usr/bin/env node
// Runs examples/sqlite-vs-turso's benchmark for the docs, into site/sqlite-vs-turso.json (committed):
// the app built as it would ship (--opt=speed), then, for each engine it compares (SQLite; Turso,
// its writes at once, MVCC; Turso in WAL mode, its writes taking turns), `rounds` rounds, each a
// server started on a fresh file of its own, asked POST /bench once small to warm up, then once at
// `size`. A fresh file each round: on Turso's MVCC, rounds on one file (each deleting every row and
// writing them again) slow down past what one round measures. Each workload's time is the median
// of the rounds, as Roc timed it in the server (Time.now_nanos! around its Db calls), so no HTTP is
// in it. With the machine, its load, the commit, and the engines' versions.
//
//   node site/sqlite-vs-turso.mjs                  size 100 (20,000 items), 3 rounds
//   node site/sqlite-vs-turso.mjs --size 10 --rounds 1
//
// The site's build (site/build.mjs) writes site/Generated/DbBench.roc from the file, and the app's
// page (/examples/sqlite-vs-turso) shows it. It takes a few minutes, so the site's build doesn't run
// it: `just db-bench` does.
import { spawn, spawnSync } from "node:child_process";
import { request } from "node:http";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { cpus, loadavg, tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp, roc, rocxBinary } from "../server/build.mjs";
import { rocString } from "./reference.mjs";

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

function machine() {
	const model = spawnSync("sysctl", ["-n", "machdep.cpu.brand_string"], { encoding: "utf8" }).stdout?.trim() || cpus()[0]?.model || "an unknown CPU";
	return `${model}, ${cpus().length} cores`;
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

/** POST /bench at `size`: the report. Through node:http, with no time limit (fetch's is 5 minutes). */
function bench(origin, size) {
	const body = JSON.stringify({ size });
	return new Promise((resolve, reject) => {
		const asked = request(`${origin}/bench`, { method: "POST", headers: { "content-type": "application/json", "content-length": Buffer.byteLength(body) } }, (answer) => {
			let text = "";
			answer.setEncoding("utf8");
			answer.on("data", (chunk) => (text += chunk));
			answer.on("end", () => (answer.statusCode === 200 ? resolve(JSON.parse(text)) : reject(new Error(`POST /bench (size ${size}): ${answer.statusCode} ${text}`))));
		});
		asked.on("error", reject);
		asked.end(body);
	});
}

const median = (values) => {
	const sorted = [...values].sort((a, b) => a - b);
	return sorted[Math.floor(sorted.length / 2)];
};

export async function measure({ size = 100, rounds = 3 } = {}) {
	const rocx = rocxBinary();
	run(rocx, ["build", "examples/sqlite-vs-turso"], { env: { ...process.env, ROC: roc() } });
	const work = mkdtempSync(join(tmpdir(), "rocx-sqlite-vs-turso-"));
	const executable = join(work, "app");
	buildApp(join(root, "examples", "sqlite-vs-turso", "main.roc"), executable, { opt: "speed" });
	const loadBefore = loadavg()[0];
	const reports = {};
	try {
		for (const engine of engines) {
			reports[engine.key] = [];
			for (let round = 0; round < rounds; round++) {
				const dir = join(work, `${engine.key}-${round + 1}`);
				const server = await start(executable, engine.url(dir), work);
				try {
					await bench(server.origin, Math.max(1, Math.floor(size / 10)));
					reports[engine.key].push(await bench(server.origin, size));
				} finally {
					await server.stop();
				}
				process.stderr.write(`${engine.label}: round ${round + 1} of ${rounds}\n`);
			}
		}
	} finally {
		rmSync(work, { recursive: true, force: true });
	}
	const first = reports.sqlite[0];
	const workloads = first.workloads.map((workload, index) => ({
		name: workload.name,
		what: workload.what,
		callers: workload.callers,
		ops: workload.ops,
		results: Object.fromEntries(
			engines.map((engine) => {
				const each = reports[engine.key].map((report) => report.workloads[index]);
				return [engine.key, { ns: median(each.map((w) => w.ns)), runs: median(each.map((w) => w.runs)) }];
			}),
		),
	}));
	const commit = run("git", ["rev-parse", "--short", "HEAD"]).trim();
	return {
		measured: new Date().toISOString().slice(0, 10),
		commit,
		machine: machine(),
		load: `${loadBefore.toFixed(1)} → ${loadavg()[0].toFixed(1)}`,
		opt: "speed",
		size: first.size,
		rows: first.rows,
		rounds,
		engines: engines.map((engine) => ({
			key: engine.key,
			label: engine.label,
			note: engine.note,
			version: engine.key === "sqlite" ? `SQLite ${reports.sqlite[0].version}` : `turso_core ${tursoVersion()}`,
		})),
		workloads,
	};
}

/** site/Generated/DbBench.roc, from the results (or from none: lists empty, the page says so). */
export function dbBenchModule(results) {
	const int = (n) => String(Math.round(n));
	const engine = (e) => `{ key: ${rocString(e.key)}, label: ${rocString(e.label)}, note: ${rocString(e.note)}, version: ${rocString(e.version)} }`;
	const workload = (w, keys) =>
		[
			"\t\t{",
			`\t\t\tname: ${rocString(w.name)},`,
			`\t\t\twhat: ${rocString(w.what)},`,
			`\t\t\tcallers: ${int(w.callers)},`,
			`\t\t\tops: ${int(w.ops)},`,
			`\t\t\tresults: [${keys.map((key) => `{ engine: ${rocString(key)}, ns: ${int(w.results[key].ns)}, runs: ${int(w.results[key].runs)} }`).join(", ")}],`,
			"\t\t},",
		].join("\n");
	const r = results ?? { measured: "", commit: "", machine: "", load: "", opt: "", size: 0, rows: 0, rounds: 0, engines: [], workloads: [] };
	const keys = r.engines.map((e) => e.key);
	return [
		"## Written by site/build.mjs from site/sqlite-vs-turso.json, which site/sqlite-vs-turso.mjs measures. Run",
		"## that again (`just db-bench`), not this one.",
		"DbBench := [].{",
		"\tEngine : { key : Str, label : Str, note : Str, version : Str }",
		"\tResult : { engine : Str, ns : U64, runs : U64 }",
		"\tWorkload : { name : Str, what : Str, callers : U64, ops : U64, results : List(Result) }",
		"",
		"\t## When, at which commit, on what, how big and how many times it was run.",
		"\tmeasured : { date : Str, commit : Str, machine : Str, load : Str, opt : Str, size : U64, rows : U64, rounds : U64 }",
		`\tmeasured = { date: ${rocString(r.measured)}, commit: ${rocString(r.commit)}, machine: ${rocString(r.machine)}, load: ${rocString(r.load)}, opt: ${rocString(r.opt)}, size: ${int(r.size)}, rows: ${int(r.rows)}, rounds: ${int(r.rounds)} }`,
		"",
		"\t## The engines, in the page's order.",
		"\tengines : List(Engine)",
		`\tengines = [${r.engines.map(engine).join(", ")}]`,
		"",
		"\t## Each workload, its median time on each engine.",
		"\tworkloads : List(Workload)",
		"\tworkloads = [",
		...r.workloads.map((w) => workload(w, keys)),
		"\t]",
		"}",
		"",
	].join("\n");
}

/** The results the site has, or none yet. */
export function readResults() {
	return existsSync(resultsFile) ? JSON.parse(readFileSync(resultsFile, "utf8")) : null;
}

if (import.meta.url === `file://${process.argv[1]}`) {
	const argument = (name, fallback) => {
		const at = process.argv.indexOf(name);
		return at >= 0 ? Number(process.argv[at + 1]) : fallback;
	};
	const results = await measure({ size: argument("--size", 100), rounds: argument("--rounds", 3) });
	writeFileSync(resultsFile, `${JSON.stringify(results, null, "\t")}\n`);
	console.log(`wrote ${resultsFile}`);
	for (const workload of results.workloads) {
		const cells = results.engines.map((engine) => `${engine.label} ${(workload.results[engine.key].ns / 1e6).toFixed(1)} ms`);
		console.log(`${workload.name.padEnd(20)} ${cells.join("   ")}`);
	}
}
