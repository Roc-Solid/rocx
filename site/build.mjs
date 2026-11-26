#!/usr/bin/env node
// Builds the docs site. The site is written in rocx and shows rocx on itself: every example is a
// real file under site/examples, shown beside the Roc rocx wrote for it and what it renders; the
// refusals are rocx's own messages, the compiler report is the compiler's, and the sizes and
// timings are measured here, on this build.
//
//   node site/build.mjs             everything, then each page rendered into site/dist (a static site)
//   node site/build.mjs --prepare   steps 1 and 2 only: what `roc check` needs
//   node site/build.mjs --dev       steps 1 to 4 from Roc's dev backend, no measuring
//
// `just dev` (`rocx site dev`, rocx-cli/SiteDev.roc) builds as `--dev` does, in Roc: everything
// from Roc's dev backend, and no measuring, so a save is rebuilt in a fraction of a second instead
// of seconds of LLVM.
//
// The steps, which `rocx site dev` runs too before it starts the server:
//   1 and 2 are rocx's (`rocx site prepare`, rocx-cli/Site.roc), run by `prepare` below:
//   1. .rocx → .roc (rocx build): the pages (site/routes), their components (site/Ui, site/Demos)
//      and the program (site/Generated/App.roc), and the browser's copy of the site
//      (site/build/client), with its main.roc
//   2. site/Generated/Sources.roc: the sources, refusals and report the pages show
//      (rocx-cli/SiteSources.roc); and, before step 1 copies the site,
//      site/Generated/PlatformReference.roc: every module the server platform exposes, read from
//      its source (rocx-cli/SiteReference.roc), for the reference page, and
//      site/Generated/ExampleApps.roc: the example apps' sizes and the server's benchmark, from
//      site/example-apps.json (which site/example-apps.mjs measures), for the examples page, and
//      site/Generated/DbBench.roc: SQLite against Turso, from site/sqlite-vs-turso.json (which
//      site/sqlite-vs-turso.mjs measures), for examples/sqlite-vs-turso's page
//   3. the browser's wasm: the same pages, on the web platform (its Rust host), built from the
//      browser's copy (site/build/client/main.roc) into site/build/client/static/rocx/app.wasm,
//      beside the start.js and runtime.js rocx build put there: a page loads all three from /rocx/
//   4. the server: site/main.roc, every page and endpoint, natively, on the server
//      platform (its Rust host), one executable (site/build/server)
//   5. facts: what the wasm weighs, how long rendering a page takes in it; for the pages, in
//      site/build/context.txt, which the server is started with
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { definitionsOf, findRouteFiles, routeTable } from "../rocx-cli/rocx.mjs";
import { machine } from "./machine.mjs";
import { Runtime } from "../web/runtime.js";
import { buildApp, buildHost, buildWebHost, rocxBinary, start } from "../server/build.mjs";

export const root = join(dirname(fileURLToPath(import.meta.url)), "..");
export const site = join(root, "site");
export const out = join(site, "build");
export const dist = join(site, "dist");
/** The browser's copy of the site (`rocx build --client`), which the browser's app is built from. */
export const client = join(out, "client");

/** The pages, from site/routes (`/`, `/syntax`; `/blog/[slug]` would be one too). */
const pages = () => routeTable(findRouteFiles(join(site, "routes"))).pages;

/** What each of site/routes' files defines (`definitions`), by its path under routes/: one rocx call
 * for them all, made once. */
let routeDefs;
const routeDefinitions = () => {
	if (!routeDefs) {
		const files = findRouteFiles(join(site, "routes"));
		const found = definitionsOf(files.map((file) => readFileSync(join(site, "routes", file), "utf8")));
		routeDefs = new Map(files.map((file, i) => [file, found[i]]));
	}
	return routeDefs;
};

/** Whether a page runs behind a directory's middleware: a `+middleware.roc` in its directory or one
 * above it, but routes/'s, which runs around every request (D-103). */
const guarded = (file) => {
	const dirs = file.split("/").slice(0, -1);
	return dirs.some((_, i) => routeDefinitions().has(`${dirs.slice(0, i + 1).join("/")}/+middleware.roc`));
};

/** The pages a static build writes: those with no params, and none behind middleware, which
 * answers each request as it comes (`/members`: who is asking?). */
export const ROUTES = pages()
	.filter((page) => !page.params.length && !guarded(page.file))
	.map((page) => page.path);


export function roc() {
	// The fork rocx builds with, which `just setup` builds and links (the Justfile says why), as the
	// file it links to: a new pin is a new path. Else $ROC; never the `roc` on PATH, which may lack
	// the fork's fixes.
	const active = join(root, ".tools", "roc-active");
	if (existsSync(active)) return realpathSync(active);
	if (process.env.ROC) return process.env.ROC;
	throw new Error("no Roc compiler: run `just setup` (or set ROC)");
}

function run(command, args, { cwd = root } = {}) {
	const result = spawnSync(command, args, { cwd, encoding: "utf8" });
	if (result.error) throw result.error;
	const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
	if (result.status !== 0) throw new Error(`${basename(command)} ${args.join(" ")} failed:\n${output}`);
	return output;
}

function writeIfChanged(path, content) {
	// An unchanged file stays untouched, so a watcher doesn't see a change and build again.
	if (existsSync(path) && readFileSync(path, "utf8") === content) return;
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, content);
}

// ---- One build at a time ----
//
// Builds share site/build: `just dev`'s watcher, `just site`, `just check` and the tests each write
// it. Two at once mix their output, and `just site` once published a dev build's wasm that a
// rebuild wrote while it was copying site/build into site/dist. So a build holds site/build's lock
// (site/build/building.lock: its process and what it is) while it writes it, and another waits.

const lockFile = join(out, "building.lock");
let held = 0;

const alive = (pid) => {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return error.code === "EPERM";
	}
};

const sleepSync = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/** Takes site/build's lock, waiting while another process (alive) holds it; again in the same
 * process, it only counts. */
function acquire(what) {
	if (held++ > 0) return;
	mkdirSync(out, { recursive: true });
	let told = false;
	for (;;) {
		try {
			writeFileSync(lockFile, JSON.stringify({ pid: process.pid, what }), { flag: "wx" });
			return;
		} catch (error) {
			if (error.code !== "EEXIST") throw error;
		}
		let holder = null;
		try {
			holder = JSON.parse(readFileSync(lockFile, "utf8"));
		} catch {
			// Being written, or gone already; or left half-written by a process that died.
			if (existsSync(lockFile) && Date.now() - statSync(lockFile).mtimeMs > 2000) rmSync(lockFile, { force: true });
		}
		if (holder && !alive(holder.pid)) rmSync(lockFile, { force: true });
		else if (holder && !told) {
			console.error(`rocx site: waiting for the build in process ${holder.pid} (${holder.what}) to finish`);
			told = true;
		}
		sleepSync(200);
	}
}

function release() {
	if (--held > 0) return;
	if (ours()) rmSync(lockFile, { force: true });
}

const ours = () => {
	try {
		return JSON.parse(readFileSync(lockFile, "utf8")).pid === process.pid;
	} catch {
		return false;
	}
};

process.on("exit", () => {
	if (held > 0 && ours()) rmSync(lockFile, { force: true });
});

/** `act()`, holding site/build's lock; it resolves, or returns, as `act` does. */
function exclusive(what, act) {
	acquire(what);
	let result;
	try {
		result = act();
	} catch (error) {
		release();
		throw error;
	}
	if (result instanceof Promise) return result.finally(release);
	release();
	return result;
}

// ---- 2. What the pages show ----
//
// rocx's: `rocx site prepare` (rocx-cli/Site.roc, SiteSources.roc, SiteReference.roc), which `prepare`
// runs.

// ---- 3. The wasm ----

/** How the browser's wasm is built: optimized for size, with lambda sets specialized. For this
 * site it is the smallest of the three, compressed, and about as fast as the others; `just site`
 * measures all three, and the browser platform's page shows them. Unlike the server's (D-064):
 * boxy, this site's wasm is 3.5% bigger with brotli and renders its charts page half as fast. */
export const CLIENT_OPT = ["--opt=size", "--specialize=yes"];

/** Builds `app` into `output`: beside it first, then moved into its place in one step, so a server
 * serving the one before (`just dev`) serves it whole until it serves the new one whole. */
function wasm(app, output, opts) {
	const building = `${output}.building`;
	run(roc(), ["build", "--target=wasm32", ...opts, `--output=${building}`, app]);
	renameSync(building, output);
}

// ---- 4. Facts ----

const kb = (bytes) => `${(bytes / 1024).toFixed(1)} KB`;

const brotli = (bytes) => brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;

/** Microseconds per call of `act`: the median of five batches, after warming up (the first calls
 * run before the engine optimizes, and one batch can meet a busy machine). */
function time(count, act) {
	for (let i = 0; i < 200; i++) act(i);
	const batches = [];
	for (let batch = 0; batch < 5; batch++) {
		const started = performance.now();
		for (let i = 0; i < count / 5; i++) act(i);
		batches.push(((performance.now() - started) * 1000) / (count / 5));
	}
	return batches.sort((a, b) => a - b)[2];
}

/** The page `measureClient` renders: the front page. */
const MEASURED = "/";

/**
 * The page at `path` as the site's server answers it, and what the browser's build needs to render
 * it the same way (decision D): the answers its reads got, what it has inside each
 * `<NoHydration>`, and the plugins' scripts it loads (D-050), by URL.
 */
export async function nativePage(url, path, headers = {}) {
	const answered = await fetch(`${url}${path}`, { headers: { accept: "text/html", ...headers } });
	const html = await answered.text();
	const script = /<script type="application\/json" class="rocx-answers">(.*?)<\/script>/.exec(html);
	const scripts = [...html.matchAll(/<script type="module" data-rocx src="([^"]*)"><\/script>/g)]
		.map((tag) => tag[1].replace(/&quot;/g, '"').replace(/&amp;/g, "&"))
		.filter((src) => src !== "/rocx/start.js");
	return { path, status: answered.status, html, answers: script ? JSON.parse(script[1]) : [], regions: Runtime.regionsOf(html), scripts };
}

/** Sizes and timings of the browser's wasm, under `prefix`: rendering a page (`page`, as the
 * server answered it), as the server would, with the answers it recorded, runs every component and
 * every hole outside its `<NoHydration>`s once. */
async function measureClient(wasm, prefix, page) {
	const loading = performance.now();
	const runtime = await Runtime.load(wasm);
	const compiled = performance.now() - loading;
	const render = () => runtime.renderToString({ path: page.path, answers: page.answers, regions: page.regions, scripts: page.scripts });
	if (render().html !== page.html) throw new Error(`the browser's build renders ${page.path} other than the server does`);
	return {
		[`${prefix}bytes`]: kb(wasm.length),
		[`${prefix}gzip`]: kb(gzipSync(wasm, { level: 9 }).length),
		[`${prefix}brotli`]: kb(brotli(wasm)),
		[`${prefix}compile_ms`]: compiled.toFixed(1),
		[`${prefix}render_us`]: time(200, render).toFixed(0),
	};
}

/** The build's facts; with `compare`, the client built other ways too, for the internals page. */
async function measure({ compare }) {
	const browser = readFileSync(appWasm);
	// The runtime as pages load it: minified by rocx build (not under --dev).
	const runtime = readFileSync(join(clientStatic, "rocx", "runtime.js"));
	// The page the wasm renders, as the server answers it (started with the facts it had last).
	if (!existsSync(context)) writeFileSync(context, lastFacts());
	const running = await startServer();
	let page;
	try {
		page = await nativePage(running.url, MEASURED);
	} finally {
		await running.stop();
	}
	const facts = {
		...(await measureClient(browser, "client_", page)),
		runtime_bytes: kb(runtime.length),
		runtime_gzip: kb(gzipSync(runtime, { level: 9 }).length),
		server_bytes: kb(statSync(server).size),
		roc: run(roc(), ["version"]).trim().replace(/^Roc compiler version /, ""),
		node: process.version,
		built: new Date().toISOString().slice(0, 10),
		// Not a dev build's: `just deploy-pages` publishes only a build that says so.
		dev: "no",
		// What it was measured on (site/machine.mjs), for the pages that show the timings.
		...Object.fromEntries(Object.entries(machine()).map(([key, value]) => [`machine_${key}`, value])),
	};
	// The comparison takes two more builds, so only `node site/build.mjs` makes it; a build that
	// doesn't keeps the last one it finds (marked as such on the page by its own date).
	const saved = join(out, "facts.txt");
	if (compare) {
		for (const [name, opts] of [["size", ["--opt=size"]], ["speed", ["--opt=speed"]]]) {
			const path = join(out, `app-${name}.wasm`);
			wasm(join(client, "main.roc"), path, opts);
			Object.assign(facts, await measureClient(readFileSync(path), `${name}_`, page));
		}
		facts.compared = facts.built;
	} else if (existsSync(saved)) {
		for (const line of readFileSync(saved, "utf8").split("\n")) {
			const [key, ...value] = line.split("=");
			if (/^(size_|speed_|compared$)/.test(key)) facts[key] = value.join("=");
		}
	}
	const text = Object.entries(facts)
		.map(([key, value]) => `${key}=${value}`)
		.join("\n");
	writeFileSync(saved, text);
	return text;
}

/** Steps 1 and 2: the Roc the compiler checks, and the browser's copy of the site. */
export function prepare({ dev = false } = {}) {
	// rocx's (rocx-cli/Site.roc): the platform's reference, the example apps' facts and SQLite against
	// Turso as Roc; rocx build of the site, with the stories for a dev build (the catalog at
	// /__rocx/stories); the server platform's copy of the shared modules; the sources the pages
	// show. This process holds site/build's lock, so rocx doesn't take it (`--no-lock`).
	return exclusive(dev ? "a dev build" : "a build", () => {
		run(rocxBinary(), ["site", "prepare", "--no-lock", ...(dev ? ["--dev"] : [])]);
	});
}

/** The server's executable, and what it is started with. */
export const server = join(out, "server");
export const context = join(out, "context.txt");
/** What a page loads, besides the site's own files: rocx build's start.js and runtime.js, and the
 * browser's wasm beside them (served at /rocx/). */
export const clientStatic = join(client, "static");
export const appWasm = join(clientStatic, "rocx", "app.wasm");

/** How the site's server is started: what it serves besides what Roc answers. */
export function serverFlags({ dev = false, databaseUrl } = {}) {
	return [
		"--static", join(site, "static"),
		"--static", clientStatic,
		"--context-file", context,
		...(databaseUrl ? ["--database-url", databaseUrl] : []),
		...(dev ? ["--dev"] : []),
	];
}

/** Starts the site's server (built) on a free port; resolves when it listens: its URL, what it
 * logged, and how to stop it. */
export function startServer(options = {}, extra = []) {
	return start(server, [...serverFlags(options), ...extra]);
}

/** The facts the last measured build saved, marked as a dev build's: its own wasm, from the dev
 * backend, is neither as small nor as fast as what was measured. */
function lastFacts() {
	const saved = join(out, "facts.txt");
	const measured = existsSync(saved) ? readFileSync(saved, "utf8").split("\n").filter((line) => line && !line.startsWith("dev=")) : [];
	return [...measured, "dev=yes"].join("\n");
}

/**
 * Steps 1 to 5; resolves to the facts the pages are given. With `dev`, everything comes from Roc's
 * dev backend, which builds the whole site in a fraction of a second, where LLVM takes seconds to
 * optimize (every time: its output isn't cached, and Roc hands it the whole program at once). The
 * pages' components then run about half as fast, which editing doesn't notice; the pages show the numbers
 * the last full build measured.
 */
export function build({ log = console.error, compare = false, dev = false } = {}) {
	return exclusive(dev ? "a dev build" : "a build", () => buildUnlocked({ log, compare, dev }));
}

async function buildUnlocked({ log, compare, dev }) {
	const started = performance.now();
	prepare({ dev });
	buildWebHost();
	mkdirSync(out, { recursive: true });
	wasm(join(client, "main.roc"), appWasm, dev ? ["--opt=dev"] : CLIENT_OPT);
	buildHost();
	// Optimized, with boxy lowering, as every app's server (D-064).
	buildApp(join(site, "main.roc"), server, { opt: dev ? "dev" : (process.env.ROC_OPT ?? "speed") });
	const facts = dev ? lastFacts() : await measure({ compare });
	writeIfChanged(context, facts);
	log(`rocx site: built in ${((performance.now() - started) / 1000).toFixed(2)} s${dev ? " (dev backend; numbers from the last `just site`)" : ""}`);
	return facts;
}

/** The file a route is written to in dist/. */
export const pageFile = (route) => (route === "/" ? "index.html" : `${route.slice(1)}/index.html`);

/**
 * What the static site's demos ask for besides pages, answered by the server as the site is built
 * and written as files: the words the shout's buttons send (`site/Demos/Shout.rocx`), and the
 * endpoints' OpenAPI document and its page. A copy of the site as files answers these GETs, and
 * nothing else.
 */
export const STATIC_GETS = ["/api/shout/rocx", "/api/shout/hello", "/api/shout/static", "/openapi.json", "/openapi.html"];

/** A page as the server answered it, for a copy served under `base` (`/rocx/`): an attribute's URL
 * that begins with `/` (a link, a script, a stylesheet) begins with the base instead, as
 * `rocx build --static` writes it (rocx-cli/Static.roc's `under_base`). */
export function underBase(html, base) {
	return base === "/" ? html : html.replace(/(\s(?:href|src|action)=")\/(?!\/)/g, `$1${base}`);
}

/**
 * The site as files in `dir`, by `rocx build --static` (D-073) from this build (site/build, made by
 * `build`): every page as the site's server answers it, what the demos ask for (`STATIC_GETS`), the
 * plugins' files and what the pages load. With `base` (`/rocx/`), for a host that serves it under
 * that path (a GitHub Pages project site: `example.github.io/rocx/`). Resolves to what rocx said of
 * the copy, a line each.
 */
export async function prerender(dir, { base = "/" } = {}) {
	// site/dist is what `just deploy-pages` publishes: only `just site` writes it, from its own
	// build, never a dev build's (`just dev`, `site/build.mjs --dev`).
	if (resolve(dir) === resolve(dist) && !/^dev=no$/m.test(existsSync(context) ? readFileSync(context, "utf8") : "")) {
		throw new Error(`rocx site: site/build is a dev build (${relative(root, context)} doesn't say dev=no), and site/dist is published: only \`just site\` writes it`);
	}
	const routes = STATIC_GETS.flatMap((route) => ["--route", route]);
	const ran = spawnSync(rocxBinary(), ["build", site, "--static", dir, "--base", base, "--built", out, ...routes, "--", "--context-file", context], { cwd: root, encoding: "utf8" });
	if (ran.status !== 0) throw new Error(`rocx build --static failed (${ran.status}):\n${ran.stderr}${ran.stdout}`);
	return ran.stderr.trimEnd().split("\n");
}

async function main() {
	const base = process.argv.find((arg) => arg.startsWith("--base="))?.slice("--base=".length) ?? "/";
	// The lock held from the build to the last file in site/dist, so nothing builds in between.
	await exclusive("just site", async () => {
		const facts = await build({ compare: true });
		const built = readFileSync(appWasm);
		const said = await prerender(dist, { base });
		if (!readFileSync(join(dist, "rocx", "app.wasm")).equals(built)) throw new Error("rocx site: site/dist/rocx/app.wasm isn't the wasm this build made: something else wrote site/build meanwhile");
		for (const line of said) console.error(line);
		console.error(facts);
	});
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	if (process.argv.includes("--prepare")) prepare();
	else if (process.argv.includes("--dev")) await build({ dev: true });
	else await main();
}
