#!/usr/bin/env node
// Roc Solid in js-framework-benchmark (krausest/js-framework-benchmark), on this machine, beside the
// frameworks it is compared with. The benchmark is a table of rows and six buttons; its runner opens
// each framework's page in Chrome, clicks, and measures how long until the page has painted (CPU),
// how much memory the page holds (memory), and what the page downloads (sizes).
//
//   node benchmarks/jsframework/run.mjs entries           our two entries, built into the clone
//   node benchmarks/jsframework/run.mjs bench [options]   entries, then the runner, then report
//   node benchmarks/jsframework/run.mjs report <run dir>  a run's results, pooled, into the report
//
//   --rounds=2              how many times the whole suite runs; the second round walks the
//                           frameworks in reverse order, and the report pools all rounds
//   --count=15              iterations of each CPU benchmark (the runner's default)
//   --benchmarks=01_,05_    which benchmarks (prefixes of their ids); all by default
//   --frameworks=keyed/roc-solid,keyed/solid   which entries; all of FRAMEWORKS by default
//
// The clone is JS_FRAMEWORK_BENCHMARK_DIR (~/jsfb/js-framework-benchmark), with its runner
// installed and the other entries built (benchmarks/jsframework/README.md); its server is started
// on JSFB_PORT (8089; never 8080, the user's dev server's), and its runner uses CHROME (by default
// the Chrome for Testing under ~/jsfb/browsers), headless. Our entries are built by
// `rocx build <app> --static` from this checkout (D-073), named by its commit.
//
// A run's raw results stay in benchmarks/jsframework/runs/<stamp>/ (not committed); the pooled
// results go to site/js-framework-benchmark.json (committed: a docs page may read it), with the
// machine (site/machine.mjs), its load and power, Chrome's version and the commits measured.
import { spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir, loadavg } from "node:os";
import { join, relative } from "node:path";
import { rocxBinary } from "../../server/build.mjs";
import { machine } from "../../site/machine.mjs";

const here = import.meta.dirname;
const root = join(here, "..", "..");
const clone = process.env.JS_FRAMEWORK_BENCHMARK_DIR ?? join(homedir(), "jsfb", "js-framework-benchmark");
const port = process.env.JSFB_PORT ?? "8089";
const resultsFile = join(root, "site", "js-framework-benchmark.json");

/** The entries measured, ours first: Solid is the closest relative (signals, no virtual DOM),
 * Leptos the same in Rust and wasm, Joy the other Roc framework (Elm's architecture, a virtual
 * DOM), React the common one, vanillajs the floor. Non-keyed entries are retired upstream (their
 * runner still measures them): ours and Joy's are kept, with vanillajs's from `retired/`. */
export const FRAMEWORKS = ["keyed/roc-solid", "non-keyed/roc-solid", "keyed/vanillajs", "non-keyed/vanillajs", "keyed/solid", "keyed/leptos", "keyed/joy", "non-keyed/joy", "keyed/react-hooks"];

/** The benchmarks, by the prefix of their ids: CPU (01–09), memory (21, 22, 25) and sizes (40,
 * which writes 41, 42 and 43). The runner's other ids are commented out upstream. */
export const BENCHMARKS = ["01_", "02_", "03_", "04_", "05_", "06_", "07_", "08_", "09_", "21_", "22_", "25_", "40_"];

/** What each result is, by its id (webdriver-ts/src/benchmarksCommon.ts's labels). */
export const LABELS = {
	"01_run1k": "create rows",
	"02_replace1k": "replace all rows",
	"03_update10th1k_x16": "partial update",
	"04_select1k": "select row",
	"05_swap1k": "swap rows",
	"06_remove-one-1k": "remove row",
	"07_create10k": "create many rows",
	"08_create1k-after1k_x2": "append rows to large table",
	"09_clear1k_x8": "clear rows",
	"21_ready-memory": "ready memory",
	"22_run-memory": "run memory",
	"25_run-clear-memory": "creating/clearing 1k rows (5 cycles)",
	"41_size-uncompressed": "uncompressed size",
	"42_size-compressed": "compressed size",
	"43_first-paint": "first paint",
};

const NAMES = { "roc-solid": "Roc Solid", vanillajs: "vanillajs", solid: "Solid", "react-hooks": "React", leptos: "Leptos", joy: "Joy" };

const said = (command, args, options = {}) => {
	const done = spawnSync(command, args, { encoding: "utf8", ...options });
	return done.status === 0 ? done.stdout.trim() : "";
};

function option(args, name, fallback) {
	const found = args.find((arg) => arg.startsWith(`--${name}=`));
	return found ? found.slice(name.length + 3) : fallback;
}

/** The Chrome the runner drives: CHROME, else the newest Chrome for Testing under ~/jsfb/browsers. */
function chrome() {
	if (process.env.CHROME) return process.env.CHROME;
	const dir = join(homedir(), "jsfb", "browsers", "chrome");
	const builds = existsSync(dir) ? readdirSync(dir).sort() : [];
	for (const build of builds.reverse()) {
		const binary = join(dir, build, "chrome-mac-arm64", "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing");
		if (existsSync(binary)) return binary;
	}
	throw new Error("no Chrome for the runner: set CHROME, or install Chrome for Testing under ~/jsfb/browsers (README.md)");
}

/** This checkout's commit, as an entry's version: `6bc2f1e`, or `6bc2f1e.dirty` with changes. */
function commit() {
	const head = said("git", ["rev-parse", "--short", "HEAD"], { cwd: root }) || "unknown";
	return said("git", ["status", "--porcelain"], { cwd: root }) ? `${head}.dirty` : head;
}

/** Our two entries, built from this checkout into the clone by `rocx build --static`. */
export function entries() {
	if (!existsSync(join(clone, "frameworks"))) throw new Error(`no clone of js-framework-benchmark at ${clone} (JS_FRAMEWORK_BENCHMARK_DIR; README.md says how)`);
	const version = commit();
	for (const kind of ["keyed", "non-keyed"]) {
		const out = join(clone, "frameworks", kind, "roc-solid");
		const built = spawnSync(rocxBinary(), ["build", join(here, kind), "--static", out, "--base", `/frameworks/${kind}/roc-solid/`], { cwd: root, encoding: "utf8" });
		if (built.status !== 0) throw new Error(`rocx build --static (${kind}) failed:\n${built.stderr}${built.stdout}`);
		console.error(built.stderr.trimEnd());
		const name = `js-framework-benchmark-${kind}-roc-solid`;
		writeFileSync(
			join(out, "package.json"),
			`${JSON.stringify(
				{
					name,
					version: "1.0.0",
					description: `Roc Solid (${kind}): written by rocx build --static from Roc-Solid/rocx's benchmarks/jsframework/${kind}`,
					"js-framework-benchmark": { frameworkVersion: version, frameworkHomeURL: "https://github.com/Roc-Solid/rocx", language: "Roc", issues: [] },
					scripts: { "build-prod": "echo Built from the rocx repository: just js-bench entries" },
					license: "MIT",
				},
				null,
				2,
			)}\n`,
		);
		// The benchmark's server lists an entry only when it has a lockfile.
		writeFileSync(join(out, "package-lock.json"), `${JSON.stringify({ name, version: "1.0.0", lockfileVersion: 3, requires: true, packages: { "": { name, version: "1.0.0" } } }, null, 2)}\n`);
	}
	return version;
}

/** The benchmark's server: the entries it lists, or null when it isn't up. */
async function listed() {
	try {
		const answered = await fetch(`http://localhost:${port}/ls`);
		return answered.ok ? await answered.json() : null;
	} catch {
		return null;
	}
}

/** The server up (started here if it isn't: how to stop it, else nothing to stop). */
async function server() {
	if (await listed()) return () => {};
	const child = spawn("npm", ["start"], { cwd: clone, env: { ...process.env, PORT: port }, stdio: "ignore", detached: true });
	for (let i = 0; i < 100 && !(await listed()); i++) await new Promise((resolve) => setTimeout(resolve, 200));
	if (!(await listed())) throw new Error(`the benchmark's server didn't start on ${port}`);
	return () => {
		try {
			process.kill(-child.pid, "SIGTERM");
		} catch {}
	};
}

/** Where the power comes from now: "mains", "battery", or "" (not a Mac, or pmset said nothing). */
function power() {
	const battery = said("pmset", ["-g", "batt"]);
	return /'AC Power'/.test(battery) ? "mains" : /'Battery Power'/.test(battery) ? "battery" : "";
}

const elapsed = (started) => `${((Date.now() - started) / 60_000).toFixed(1)} min`;

/** Entries, then `rounds` rounds of the runner, then the report. Each round runs the benchmarks
 * one at a time, every framework in turn for each (so a benchmark's frameworks are measured minutes
 * apart, not an hour), the second round in reverse order; its results are kept per round. */
export async function bench(args) {
	if (port === "8080") throw new Error("8080 is the user's dev server's: set JSFB_PORT to another port");
	const rounds = Number(option(args, "rounds", "2"));
	const count = option(args, "count", "");
	const benchmarks = option(args, "benchmarks", BENCHMARKS.join(",")).split(",");
	const frameworks = option(args, "frameworks", FRAMEWORKS.join(",")).split(",");
	const binary = chrome();
	// The runner, patched (runner-trace-start.patch): a trace's events from before it started aren't
	// the measured run's. Without it, Roc Solid's create benchmarks fail ("at most one mousedown").
	if (!readFileSync(join(clone, "webdriver-ts", "dist", "timeline.js"), "utf8").includes("sinceTracingStarted")) {
		throw new Error(`the runner isn't patched: git apply ${relative(clone, join(here, "runner-trace-start.patch"))} in the clone, then npx tsc in webdriver-ts (README.md)`);
	}
	const version = entries();
	const stop = await server();
	const stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, "-");
	const run = join(here, "runs", stamp);
	const started = Date.now();
	try {
		const ls = await listed();
		const missing = frameworks.filter((framework) => !ls.some((entry) => `${entry.type}/${entry.directory}` === framework));
		if (missing.length) throw new Error(`the benchmark's server doesn't list ${missing.join(", ")}: built, with a package-lock.json?`);
		const before = { machine: machine(), load: loadavg()[0], at: new Date().toISOString() };
		const results = join(clone, "webdriver-ts", "results");
		const failures = [];
		// Each benchmark's power source: a laptop on its battery may run slower, so the report says
		// which steps weren't on mains.
		const unplugged = [];
		for (let round = 1; round <= rounds; round++) {
			const order = round % 2 === 1 ? frameworks : [...frameworks].reverse();
			const kept = join(run, "rounds", String(round));
			mkdirSync(kept, { recursive: true });
			rmSync(results, { recursive: true, force: true });
			mkdirSync(results, { recursive: true });
			for (const benchmark of benchmarks) {
				const source = power();
				if (source !== "mains") unplugged.push(`round ${round}, ${benchmark}: ${source || "unknown power"}`);
				console.error(`round ${round}/${rounds}, ${benchmark}: ${order.length} entries (${elapsed(started)} so far${source === "mains" ? "" : `, on ${source || "unknown power"}`})`);
				const flags = ["run", "bench", "--", "--headless", "--chromeBinary", binary, ...(count ? ["--count", count] : []), "--benchmark", benchmark, "--framework", ...order];
				const ran = spawnSync("npm", flags, { cwd: join(clone, "webdriver-ts"), env: { ...process.env, PORT: port }, encoding: "utf8", maxBuffer: 1 << 28 });
				writeFileSync(join(kept, `${benchmark}.log`), `${ran.stdout}\n${ran.stderr}`);
				if (ran.status !== 0) failures.push(`round ${round}, ${benchmark}: the runner exited ${ran.status} (rounds/${round}/${benchmark}.log)`);
			}
			cpSync(results, kept, { recursive: true });
		}
		const after = { machine: machine(), load: loadavg()[0], at: new Date().toISOString() };
		const chromeVersion = said(binary, ["--version"]).replace(/^Google Chrome for Testing\s*/, "");
		const meta = { version, rounds, count: count ? Number(count) : 15, frameworks, chrome: chromeVersion, clone: said("git", ["rev-parse", "--short", "HEAD"], { cwd: clone }), before, after, failures, unplugged, minutes: Number(((Date.now() - started) / 60_000).toFixed(1)) };
		writeFileSync(join(run, "meta.json"), `${JSON.stringify(meta, null, 2)}\n`);
		console.error(`ran in ${elapsed(started)}${failures.length ? `; ${failures.length} failed:\n${failures.join("\n")}` : ""}`);
	} finally {
		stop();
	}
	return report(run);
}

const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
const median = (xs) => {
	const sorted = [...xs].sort((a, b) => a - b);
	const middle = Math.floor(sorted.length / 2);
	return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
const geomean = (xs) => Math.exp(mean(xs.map(Math.log)));
const round2 = (x) => Math.round(x * 100) / 100;

/** A result file's values: the CPU benchmarks' total time (ms), a memory benchmark's MB, a size
 * benchmark's KB or ms. */
function valuesOf(result) {
	return result.type === "cpu" ? result.values.total.values : result.values.DEFAULT.values;
}

/** The framework an entry's results name (`solid-v1.9.3-keyed`): its directory and kind, from the
 * list in meta.json. */
function entryOf(name, frameworks) {
	return frameworks.find((framework) => {
		const [kind, directory] = framework.split("/");
		return name === `${directory}-${kind}` || (name.startsWith(`${directory}-v`) && name.endsWith(`-${kind}`) && !name.endsWith(`-non-${kind}`));
	});
}

/** A run's rounds pooled: each entry's values for each benchmark (every iteration of every round),
 * their mean, median and spread, each round's median; per entry, the CPU benchmarks' geometric mean
 * and its slowdown against the fastest entry of each benchmark (the official table's measure);
 * written to site/js-framework-benchmark.json and the run's report.md, and printed. */
export function report(run) {
	const meta = JSON.parse(readFileSync(join(run, "meta.json"), "utf8"));
	const pooled = {};
	const versions = {};
	for (const round of readdirSync(join(run, "rounds")).sort()) {
		for (const file of readdirSync(join(run, "rounds", round)).filter((name) => name.endsWith(".json"))) {
			const result = JSON.parse(readFileSync(join(run, "rounds", round, file), "utf8"));
			const entry = entryOf(result.framework, meta.frameworks);
			if (!entry) continue;
			versions[entry] = result.framework;
			const at = ((pooled[entry] ??= {})[result.benchmark] ??= { type: result.type, values: [], rounds: [] });
			at.values.push(...valuesOf(result));
			at.rounds.push(round2(median(valuesOf(result))));
		}
	}
	const ids = Object.keys(LABELS).filter((id) => meta.frameworks.some((entry) => pooled[entry]?.[id]));
	const cpu = ids.filter((id) => Number(id.slice(0, 2)) < 20);
	const results = {};
	for (const entry of meta.frameworks) {
		results[entry] = {};
		for (const id of ids) {
			const at = pooled[entry]?.[id];
			if (!at) continue;
			const sorted = [...at.values].sort((a, b) => a - b);
			const m = mean(at.values);
			results[entry][id] = { mean: round2(m), median: round2(median(at.values)), min: round2(sorted[0]), max: round2(sorted.at(-1)), stddev: round2(Math.sqrt(mean(at.values.map((x) => (x - m) ** 2)))), n: at.values.length, rounds: at.rounds };
		}
	}
	const fastest = Object.fromEntries(cpu.map((id) => [id, Math.min(...meta.frameworks.map((entry) => results[entry][id]?.mean ?? Infinity))]));
	const summary = {};
	for (const entry of meta.frameworks) {
		const has = cpu.filter((id) => results[entry][id]);
		const value = (id) => results[entry][id]?.mean ?? null;
		summary[entry] = {
			cpu_geomean_ms: has.length === cpu.length ? round2(geomean(has.map(value))) : null,
			slowdown: has.length === cpu.length ? round2(geomean(has.map((id) => value(id) / fastest[id]))) : null,
			ready_memory_mb: value("21_ready-memory"),
			run_memory_mb: value("22_run-memory"),
			compressed_kb: value("42_size-compressed"),
			uncompressed_kb: value("41_size-uncompressed"),
			first_paint_ms: value("43_first-paint"),
		};
	}
	const label = (entry) => {
		const [kind, directory] = entry.split("/");
		return `${NAMES[directory] ?? directory} (${kind})`;
	};
	const document = {
		measured: meta.before.at.slice(0, 10),
		commit: meta.version,
		chrome: meta.chrome,
		benchmark: `krausest/js-framework-benchmark ${meta.clone}`,
		headless: true,
		rounds: meta.rounds,
		count: meta.count,
		minutes: meta.minutes,
		machine: meta.before.machine,
		load: `${meta.before.load.toFixed(1)} → ${meta.after.load.toFixed(1)}`,
		power: meta.before.machine.power === meta.after.machine.power ? meta.before.machine.power : `${meta.before.machine.power} → ${meta.after.machine.power}`,
		failures: meta.failures,
		unplugged: meta.unplugged ?? [],
		frameworks: meta.frameworks.map((entry) => ({ entry, name: label(entry), version: versions[entry] ?? "" })),
		benchmarks: ids.map((id) => ({ id, label: LABELS[id] })),
		results,
		summary,
	};
	writeFileSync(resultsFile, `${JSON.stringify(document, null, 1)}\n`);
	const cell = (x, digits = 1) => (x === null || x === undefined ? "–" : x.toFixed(digits));
	const lines = [
		`# js-framework-benchmark, ${document.measured}`,
		"",
		`Roc Solid at ${meta.version}; ${document.benchmark}; Chrome ${meta.chrome}, headless; ${meta.rounds} rounds of ${meta.count} iterations (CPU), the second in reverse order, pooled; ${meta.before.machine.model}, ${meta.before.machine.cpu}, ${document.power}, load ${document.load}; ${meta.minutes} min.`,
		"",
		"| | CPU geomean (ms) | Slowdown vs fastest | Run memory (MB) | Compressed (KB) | Uncompressed (KB) | First paint (ms) |",
		"|---|---|---|---|---|---|---|",
		...meta.frameworks.map((entry) => {
			const s = summary[entry];
			return `| ${label(entry)} | ${cell(s.cpu_geomean_ms)} | ${s.slowdown === null ? "–" : `${s.slowdown.toFixed(2)}×`} | ${cell(s.run_memory_mb)} | ${cell(s.compressed_kb)} | ${cell(s.uncompressed_kb)} | ${cell(s.first_paint_ms)} |`;
		}),
		"",
		"## Each benchmark (mean ± standard deviation; each round's median after the bar)",
		"",
		`| | ${meta.frameworks.map(label).join(" | ")} |`,
		`|---|${meta.frameworks.map(() => "---").join("|")}|`,
		...ids.map((id) => `| ${id} ${LABELS[id]} | ${meta.frameworks.map((entry) => {
			const r = results[entry][id];
			return r ? `${r.mean.toFixed(1)} ± ${r.stddev.toFixed(1)} \\| ${r.rounds.join(", ")}` : "–";
		}).join(" | ")} |`),
		"",
		...(meta.failures.length ? ["## Failures", "", ...meta.failures.map((failure) => `- ${failure}`), ""] : []),
		...(meta.unplugged?.length ? ["## Not on mains", "", ...meta.unplugged.map((step) => `- ${step}`), ""] : []),
	];
	writeFileSync(join(run, "report.md"), `${lines.join("\n")}\n`);
	console.log(lines.join("\n"));
	console.error(`\n${relative(process.cwd(), resultsFile)}, ${relative(process.cwd(), join(run, "report.md"))}`);
	return document;
}

if (process.argv[1] === import.meta.filename) {
	const [command, ...args] = process.argv.slice(2);
	if (command === "entries") console.error(`entries built, version ${entries()}`);
	else if (command === "bench") await bench(args);
	else if (command === "report" && args[0]) report(args[0]);
	else {
		console.error("usage: node benchmarks/jsframework/run.mjs entries | bench [--rounds=2] [--count=15] [--benchmarks=01_,05_] [--frameworks=keyed/roc-solid,…] | report <run dir>");
		process.exit(2);
	}
}
