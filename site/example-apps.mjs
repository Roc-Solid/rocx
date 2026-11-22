#!/usr/bin/env node
// Measures the example apps for the docs' examples page, into site/example-apps.json (committed): each
// app's browser half (rocx build --client, then its wasm with --opt=size, as `just examples` builds
// it) raw, gzipped and brotli'd, the runtime every page loads beside it, and what the app is made of
// (its pages, endpoints, lines of Roc, expects, node tests, packages, whether it has Postgres). With
// --bench, echo's server too: the build it ships (--opt=speed) under bombardier, as
// examples/echo/bench.sh runs it, with the machine and its load at the time.
//
//   node site/example-apps.mjs               every example; the last benchmark kept
//   node site/example-apps.mjs tasks plate   only these (the others kept as they were)
//   node site/example-apps.mjs --bench       and echo's benchmark again (a minute or so)
//
// The site's build (site/build.mjs) writes site/Generated/ExampleApps.roc from the file, and the page
// (site/routes/examples/+page.rocx) shows it, with when, where and on what it was measured. Building
// a dozen wasm files is minutes, so the site's build doesn't measure; its test checks the file
// names every example the repository has.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { cpus, loadavg, tmpdir } from "node:os";
import { basename, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { buildApp, roc, rocxBinary } from "../server/build.mjs";
import { rocString } from "./reference.mjs";

export const root = join(import.meta.dirname, "..");
export const factsFile = join(root, "site", "example-apps.json");

/** The example apps, as the repository has them: each directory under examples/ with a tracked main.roc. */
export function exampleNames() {
	const listed = spawnSync("git", ["ls-files", "examples/*/main.roc"], { cwd: root, encoding: "utf8" });
	if (listed.status !== 0) throw new Error(`git ls-files failed: ${listed.stderr}`);
	return listed.stdout
		.split("\n")
		.filter(Boolean)
		.map((path) => path.split("/")[1])
		.sort();
}

function run(command, args, options = {}) {
	const done = spawnSync(command, args, { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, ...options });
	if (done.status !== 0) throw new Error(`${command} ${args.join(" ")} failed:\n${done.stdout}\n${done.stderr}`);
	return done.stdout;
}

/** A file's sizes, in bytes: as it is, gzipped (level 9) and brotli'd (quality 11), as the site measures its own. */
export function sizes(bytes) {
	return {
		bytes: bytes.length,
		gzip: gzipSync(bytes, { level: 9 }).length,
		brotli: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length,
	};
}

/** Every file under `dir`, but what a build writes (Generated/, build/, a component's .roc beside its .rocx) and node_modules. */
function sourceFiles(dir) {
	const found = [];
	const walk = (at) => {
		for (const entry of readdirSync(at, { withFileTypes: true })) {
			const path = join(at, entry.name);
			if (entry.isDirectory()) {
				if (!["Generated", "build", "node_modules", ".scratch"].includes(entry.name)) walk(path);
			} else if (!(entry.name.endsWith(".roc") && existsSync(`${path}x`))) {
				found.push(path);
			}
		}
	};
	walk(dir);
	return found;
}

/** What an example is made of, read from its files. */
export function anatomy(name) {
	const dir = join(root, "examples", name);
	const files = sourceFiles(dir);
	const roc = files.filter((file) => /\.rocx?$/.test(file) && !file.includes("/test/"));
	const text = (file) => readFileSync(file, "utf8");
	const routes = files.filter((file) => file.includes("/routes/"));
	const readme = existsSync(join(dir, "README.md")) ? text(join(dir, "README.md")) : "";
	const heading = /^# (.+)$/m.exec(readme)?.[1] ?? name;
	const header = /app \[[^\]]*\] \{([^}]*)\}/.exec(text(join(dir, "main.roc")))?.[1] ?? "";
	return {
		name,
		// "tasks: Acme Tasks" is Acme Tasks; "Pinwheel: a live quiz…" is Pinwheel; "Plate" is Plate.
		title: heading.startsWith(`${name}: `) ? heading.slice(name.length + 2) : heading.split(": ")[0],
		pages: routes.filter((file) => basename(file) === "+page.rocx").length,
		endpoints: routes.filter((file) => basename(file) === "+server.roc").reduce((sum, file) => sum + (text(file).match(/^(get|post|put|patch|delete|channel|events)! =/gm) ?? []).length, 0),
		lines: roc.reduce((sum, file) => sum + text(file).split("\n").filter((line) => line.trim() !== "").length, 0),
		expects: roc.reduce((sum, file) => sum + (text(file).match(/^expect /gm) ?? []).length, 0),
		tests: files.filter((file) => file.endsWith(".test.mjs")).reduce((sum, file) => sum + (text(file).match(/^\s*test\(/gm) ?? []).length, 0),
		packages: [...header.matchAll(/(\w+): "[^"]*packages\/(\w+)\/main\.roc"/g)].map((match) => match[1]).sort(),
		postgres: existsSync(join(dir, "migrations")),
	};
}

/** The example's browser half, built as `just examples` builds it, measured; null for an app of endpoints alone. */
function browserHalf(name, rocx) {
	const client = join(tmpdir(), "rocx-example-apps", name);
	rmSync(client, { recursive: true, force: true });
	run(rocx, ["build", `examples/${name}`, "--client", client], { env: { ...process.env, ROC: roc() } });
	if (!existsSync(join(client, "main.roc"))) return null;
	const wasm = join(client, "static", "rocx", "app.wasm");
	run(roc(), ["build", "--target=wasm32", "--opt=size", `--output=${wasm}`, join(client, "main.roc")]);
	return sizes(readFileSync(wasm));
}

/** The machine, as the page says it: "Apple M5, 10 cores". */
function machine() {
	const model = spawnSync("sysctl", ["-n", "machdep.cpu.brand_string"], { encoding: "utf8" }).stdout?.trim() || cpus()[0]?.model || "an unknown CPU";
	return `${model}, ${cpus().length} cores`;
}

const commit = () => run("git", ["rev-parse", "--short", "HEAD"]).trim();
const today = () => new Date().toISOString().slice(0, 10);

/** Echo's benchmark: its --opt=speed build, POST /echo under bombardier at 1, 16, 64 and 256
 * connections for `seconds` each, after a warm-up, as examples/echo/bench.sh runs it; and Roc's own
 * time on a request, from the answers' server-timing. */
async function bench(rocx, seconds = 10) {
	const out = join(tmpdir(), "rocx-example-apps", "echo-server");
	run(rocx, ["build", "examples/echo"]);
	buildApp(join(root, "examples", "echo", "main.roc"), out, { opt: "speed" });
	const port = 18000 + Math.floor(Math.random() * 900);
	const server = spawn(out, ["--port", String(port), "--host", "127.0.0.1"], { stdio: "ignore" });
	try {
		const url = `http://127.0.0.1:${port}/echo`;
		const post = () => fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: '"hello"' });
		for (let tries = 0; ; tries++) {
			try {
				await post();
				break;
			} catch (error) {
				if (tries > 100) throw error;
				await new Promise((resolve) => setTimeout(resolve, 100));
			}
		}
		const load = loadavg()[0];
		const bombard = (connections, duration) => JSON.parse(run("bombardier", ["-m", "POST", "-H", "content-type: application/json", "-b", '"hello"', "-c", String(connections), "-d", duration, "-l", "-p", "r", "-o", "json", url]));
		bombard(64, "3s");
		const levels = [];
		for (const connections of [1, 16, 64, 256]) {
			const { result } = bombard(connections, `${seconds}s`);
			levels.push({
				connections,
				rps: Math.round(result.rps.mean),
				p50_us: Math.round(result.latency.percentiles["50"]),
				p99_us: Math.round(result.latency.percentiles["99"]),
				errors: result.req1xx + result.req3xx + result.req4xx + result.req5xx + result.others,
			});
		}
		// Roc's own part of a request: the median of the server-timing durations of 200 more, one at a time.
		const roc_us = [];
		for (let i = 0; i < 200; i++) {
			const timing = (await post()).headers.get("server-timing") ?? "";
			const dur = /dur=([\d.]+)/.exec(timing)?.[1];
			if (dur) roc_us.push(Number(dur) * 1000);
		}
		roc_us.sort((a, b) => a - b);
		return {
			app: "echo",
			measured: today(),
			commit: commit(),
			machine: machine(),
			load: `${load.toFixed(1)} → ${loadavg()[0].toFixed(1)}`,
			opt: "speed",
			seconds,
			body: '"hello"',
			roc_us: Math.round(roc_us[Math.floor(roc_us.length / 2)] ?? 0),
			levels,
		};
	} finally {
		server.kill();
	}
}

/** Roc for the site: `Examples`, the facts as values the page reads. */
export function examplesModule(facts) {
	const int = (n) => String(Math.round(n));
	const size = (s) => (s ? `[{ bytes: ${int(s.bytes)}, gzip: ${int(s.gzip)}, brotli: ${int(s.brotli)} }]` : "[]");
	const example = (e) =>
		[
			"\t\t{",
			`\t\t\tname: ${rocString(e.name)},`,
			`\t\t\ttitle: ${rocString(e.title)},`,
			`\t\t\tpages: ${int(e.pages)},`,
			`\t\t\tendpoints: ${int(e.endpoints)},`,
			`\t\t\tlines: ${int(e.lines)},`,
			`\t\t\texpects: ${int(e.expects)},`,
			`\t\t\ttests: ${int(e.tests)},`,
			`\t\t\tpkgs: [${e.packages.map(rocString).join(", ")}],`,
			`\t\t\tpostgres: Bool.${e.postgres ? "True" : "False"},`,
			`\t\t\twasm: ${size(e.wasm)},`,
			"\t\t},",
		].join("\n");
	const level = (l) => `{ connections: ${int(l.connections)}, rps: ${int(l.rps)}, p50_us: ${int(l.p50_us)}, p99_us: ${int(l.p99_us)}, errors: ${int(l.errors)} }`;
	const b = facts.bench;
	return [
		"## Written by site/build.mjs from site/example-apps.json, which site/example-apps.mjs measures. Run that",
		"## again (`just example-apps`), not this one.",
		"ExampleApps := [].{",
		"\tSize : { bytes : U64, gzip : U64, brotli : U64 }",
		"\tExample : { name : Str, title : Str, pages : U64, endpoints : U64, lines : U64, expects : U64, tests : U64, pkgs : List(Str), postgres : Bool, wasm : List(Size) }",
		"\tLevel : { connections : U64, rps : U64, p50_us : U64, p99_us : U64, errors : U64 }",
		"\tBench : { measured : Str, commit : Str, machine : Str, load : Str, opt : Str, seconds : U64, roc_us : U64, levels : List(Level) }",
		"",
		"\t## When, at which commit, with which compiler, and on what the sizes were measured.",
		"\tmeasured : { date : Str, commit : Str, roc : Str, machine : Str }",
		`\tmeasured = { date: ${rocString(facts.measured)}, commit: ${rocString(facts.commit)}, roc: ${rocString(facts.roc)}, machine: ${rocString(facts.machine)} }`,
		"",
		"\t## The runtime every page loads beside its app's wasm (web/runtime.js).",
		"\truntime : Size",
		`\truntime = ${size(facts.runtime).slice(1, -1)}`,
		"",
		"\t## The example apps, by name.",
		"\tall : List(Example)",
		"\tall = [",
		...facts.examples.map(example),
		"\t]",
		"",
		"\t## The server's benchmark (echo's), if one was run.",
		"\tbench : List(Bench)",
		b
			? `\tbench = [{ measured: ${rocString(b.measured)}, commit: ${rocString(b.commit)}, machine: ${rocString(b.machine)}, load: ${rocString(b.load)}, opt: ${rocString(b.opt)}, seconds: ${int(b.seconds)}, roc_us: ${int(b.roc_us)}, levels: [${b.levels.map(level).join(", ")}] }]`
			: "\tbench = []",
		"}",
		"",
	].join("\n");
}

async function main(args) {
	const wanted = args.filter((arg) => !arg.startsWith("--"));
	const names = exampleNames();
	for (const name of wanted) if (!names.includes(name)) throw new Error(`no example ${name} (there are ${names.join(", ")})`);
	const before = existsSync(factsFile) ? JSON.parse(readFileSync(factsFile, "utf8")) : { examples: [] };
	const rocx = rocxBinary();
	const examples = [];
	for (const name of names) {
		const kept = before.examples.find((e) => e.name === name);
		if (wanted.length > 0 && !wanted.includes(name) && kept) {
			examples.push({ ...kept, ...anatomy(name) });
			continue;
		}
		process.stderr.write(`${name}… `);
		const wasm = browserHalf(name, rocx);
		process.stderr.write(wasm ? `${(wasm.brotli / 1024).toFixed(1)} KB brotli\n` : "no browser half\n");
		examples.push({ ...anatomy(name), wasm });
	}
	const facts = {
		measured: today(),
		commit: commit(),
		roc: run(roc(), ["version"]).trim().replace(/^Roc compiler version /, ""),
		machine: machine(),
		runtime: sizes(readFileSync(join(root, "web", "runtime.js"))),
		examples,
		bench: args.includes("--bench") ? await bench(rocx) : before.bench,
	};
	writeFileSync(factsFile, `${JSON.stringify(facts, null, "\t")}\n`);
	console.log(`wrote ${relative(root, factsFile)}`);
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
	main(process.argv.slice(2)).catch((error) => {
		console.error(error.message ?? error);
		process.exit(1);
	});
}

