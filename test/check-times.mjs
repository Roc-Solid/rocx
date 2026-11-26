#!/usr/bin/env node
// How long checking an app takes, for each example app and the docs site: `rocx build` (the .rocx
// files into Roc; the site's `rocx site prepare`), then `rocx check -- roc check --no-cache` of its
// server program and of its browser one (the copy `rocx generate --client` writes; an app of endpoints
// alone has none). With no cache, each check does all of it, the app's modules, the platform's and
// the packages': what a newcomer's first check costs, and the same work every run, so it can be
// compared (a cached check of the same files takes some 20 ms). Each the median of three, in ms.
//
//   node test/check-times.mjs                          every example and the site, as a table
//   node test/check-times.mjs tasks plate              only these
//   node test/check-times.mjs --out times.json         and the numbers as JSON
//   node test/check-times.mjs --baseline before.json   each against an earlier run's: slower by half
//                                                      and by 250 ms or more is a warning
//
// CI (.github/workflows/ci.yml) runs it after `just check`, against the last green master run's
// numbers, whose file carries the last 30 master runs' (`history`); it writes the table into the
// job's summary and warns (it doesn't fail) when a check got slower. Runners vary by a tenth or two
// from run to run, hence the margins.
import { spawnSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { arch, cpus, platform } from "node:os";
import { join } from "node:path";
import { roc, rocxBinary } from "../server/build.mjs";
import { exampleNames, root } from "../site/example-apps.mjs";

const RUNS = 3;
const SLOWER = 1.5;
const AT_LEAST_MS = 250;
const HISTORY = 30;
const COLUMNS = [
	["build", "rocx generate (ms)"],
	["server", "check: server (ms)"],
	["client", "check: browser (ms)"],
];

const args = process.argv.slice(2);
const option = (name) => {
	const at = args.indexOf(`--${name}`);
	return at >= 0 ? args[at + 1] : undefined;
};
const named = args.filter((arg, i) => !arg.startsWith("--") && !args[i - 1]?.startsWith("--"));
const compiler = roc();
const rocx = rocxBinary();
const env = { ...process.env, ROC: compiler };

/** `command`'s wall time in ms, the median of RUNS; it must succeed. */
function median(what, command, commandArgs) {
	const times = [];
	for (let run = 0; run < RUNS; run++) {
		const started = performance.now();
		const done = spawnSync(command, commandArgs, { cwd: root, env, encoding: "utf8" });
		const took = performance.now() - started;
		if (done.status !== 0) {
			process.stderr.write(`${done.stdout}${done.stderr}`);
			throw new Error(`${what} failed (exit ${done.status})`);
		}
		times.push(took);
	}
	return Math.round(times.sort((a, b) => a - b)[Math.floor(RUNS / 2)]);
}

const check = (what, main) => median(what, rocx, ["check", "--", compiler, "check", "--no-cache", main]);

/** An example's three numbers (the browser's absent when it has no browser program). */
function example(name) {
	const dir = join("examples", name);
	const client = join(dir, "build", "client");
	const build = median(`rocx generate ${dir}`, rocx, ["generate", dir, "--client", client]);
	const server = check(`checking ${dir}/main.roc`, join(dir, "main.roc"));
	const browser = existsSync(join(root, client, "main.roc")) ? check(`checking ${client}/main.roc`, join(client, "main.roc")) : undefined;
	return { build, server, ...(browser === undefined ? {} : { client: browser }) };
}

/** The docs site's: `rocx site prepare` writes both its programs. */
function site() {
	const build = median("rocx site prepare", rocx, ["site", "prepare"]);
	return { build, server: check("checking site/main.roc", "site/main.roc"), client: check("checking site/build/client/main.roc", "site/build/client/main.roc") };
}

const names = named.length > 0 ? named : [...exampleNames(), "site"];
const results = {};
for (const name of names) {
	process.stderr.write(`${name}…\n`);
	results[name] = name === "site" ? site() : example(name);
}

const baselineFile = option("baseline");
const baseline = baselineFile && existsSync(baselineFile) ? JSON.parse(readFileSync(baselineFile, "utf8")) : null;
const total = (of) => Object.values(of).reduce((sum, row) => sum + COLUMNS.reduce((rowSum, [key]) => rowSum + (row[key] ?? 0), 0), 0);
const commit = process.env.GITHUB_SHA ?? spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).stdout.trim();
const run = { commit: commit.slice(0, 10), date: new Date().toISOString(), machine: `${platform()} ${arch()}, ${cpus().length} cores`, total: total(results), results };

// Each number against the baseline's: the table's cells, and what got slower.
const slower = [];
const cell = (name, key) => {
	const now = results[name][key];
	if (now === undefined) return "";
	const before = baseline?.results?.[name]?.[key];
	if (before === undefined) return `${now}`;
	if (now > before * SLOWER && now - before >= AT_LEAST_MS) slower.push(`${name}, ${COLUMNS.find(([k]) => k === key)[1]}: ${before} → ${now} ms`);
	const change = Math.round(((now - before) / before) * 100);
	return `${now} (${change > 0 ? "+" : ""}${change}%)`;
};
const lines = [
	`### Checking times (milliseconds, the median of ${RUNS}; no cache: all of the work)`,
	"",
	baseline ? `Against master's ${baseline.commit} (${baseline.date.slice(0, 10)}). ` + `Slower by half and by ${AT_LEAST_MS} ms or more is a warning.` : "No earlier run to compare with.",
	"",
	`| app | ${COLUMNS.map(([, title]) => title).join(" | ")} |`,
	`|---|${COLUMNS.map(() => "--:").join("|")}|`,
	...names.map((name) => `| ${name} | ${COLUMNS.map(([key]) => cell(name, key)).join(" | ")} |`),
	`| **all** | **${run.total} ms**${baseline ? ` (was ${baseline.total})` : ""} | | |`,
];
const history = [...(baseline?.history ?? []), { commit: run.commit, date: run.date, total: run.total }].slice(-HISTORY);
if (history.length > 1) lines.push("", `All of it, the last ${history.length} master runs to this one: ${history.map((each) => each.total).join(", ")} ms.`);
if (slower.length > 0) lines.push("", "**Slower:**", ...slower.map((line) => `- ${line}`));
const table = lines.join("\n");
console.log(table);
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${table}\n`);
if (process.env.GITHUB_ACTIONS) for (const line of slower) console.log(`::warning title=Checking got slower::${line}`);

const out = option("out");
if (out) writeFileSync(out, `${JSON.stringify({ ...run, history }, null, "\t")}\n`);
