// `rocx dev [dir] [--port 8080] [-- server options…]`: an app (a directory with routes/ in it),
// built and served at http://localhost:8080 under --dev, built again and restarted on each save, its
// open pages reloaded when it is back. bin/rocx runs this (`rocx dev`); it builds with the clone it
// is in: rocx build, the server, and the browser's wasm (when the app has pages), all from Roc's dev
// backend, in well under a second for a small app. An app without a main.roc gets one, the smallest
// program, which is the author's to change after. What follows `--` goes to the server as it is
// (`--database-url URL`, `--context-file FILE`); so does the environment (DATABASE_URL, PORT).
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, statSync, watch, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { buildHost, nativeTarget, roc, rocxBinary, root, zig } from "../server/build.mjs";
import { MARKER } from "./rocx.mjs";

const USAGE = "usage: rocx dev [dir] [--port 8080] [-- server options…]";

const fail = (message) => {
	console.error(message);
	process.exit(2);
};

// ---- What to serve ----

const args = process.argv.slice(2);
const dash = args.indexOf("--");
const own = dash === -1 ? args : args.slice(0, dash);
const passed = dash === -1 ? [] : args.slice(dash + 1);
let port = process.env.PORT || "8080";
const dirs = [];
for (let i = 0; i < own.length; i++) {
	if (own[i] === "--port" && own[i + 1]) port = own[++i];
	else if (own[i].startsWith("-")) fail(USAGE);
	else dirs.push(own[i]);
}
if (dirs.length > 1 || !/^\d+$/.test(port)) fail(USAGE);
if (!existsSync(resolve(dirs[0] ?? "."))) fail(`rocx dev: no directory ${dirs[0]}`);

const app = realpathSync(resolve(dirs[0] ?? "."));
const shown = relative(process.cwd(), app) || ".";
if (!existsSync(join(app, "routes"))) {
	fail(`rocx dev: ${shown} has no routes/: make routes/+page.rocx (the page at /) or routes/hello/+server.roc (an endpoint at /hello)`);
}

const out = join(app, "build");
const client = join(out, "client");
const server = join(out, "server");

// The smallest program, for an app that has none: what every request's middleware starts from
// (nothing), and a middleware that passes each request on to the routes. The platform is the
// clone's, by a path from the app, as Roc wants it.
const main = join(app, "main.roc");
if (!existsSync(main)) {
	const platform = relative(app, join(realpathSync(root), "server", "platform", "main.roc"));
	writeFileSync(
		main,
		[
			"## The app's program, written by `rocx dev` because there was none: it is yours to change.",
			"## `context` is what each request's middleware is given, and `middleware` runs around every",
			"## request (this one passes it on to the routes); App.program also takes `plugins` and `openapi`.",
			`app [program] { pf: platform ${JSON.stringify(platform)} }`,
			"",
			"import pf.Middleware",
			"import Generated/App",
			"",
			"program = App.program({",
			"\tcontext: |_started| {},",
			"\tmiddleware: Middleware.make(|request, context, next!| next!(request, context)),",
			"})",
			"",
		].join("\n"),
	);
	console.error(`rocx dev: wrote ${relative(process.cwd(), main)}, the app's program`);
}

// ---- Building ----

/** `command`, its output shown when it fails (then thrown), and on success only what isn't routine:
 * rocx build's count of the files it wrote, and Roc's line for a build without problems. */
function step(command, commandArgs, what) {
	const result = spawnSync(command, commandArgs, { encoding: "utf8", maxBuffer: 1 << 28 });
	const said = `${result.stdout ?? ""}${result.stderr ?? ""}`;
	if (result.error) throw new Error(`rocx dev: ${what} failed: ${result.error.message}`);
	if (result.status !== 0) throw new Error(`${said.trimEnd()}\nrocx dev: ${what} failed; fix it and save again`);
	if (/^0 errors and 0 warnings found/m.test(said)) return;
	const rest = said.split("\n").filter((line) => line.trim() && !/^rocx: \d+ files? written$/.test(line));
	if (rest.length > 0) console.error(rest.join("\n"));
}

/** `roc build` with `buildArgs`, its reports pointed into the .rocx files (`rocx check`). */
const rocBuild = (buildArgs, what) => step(rocxBinary(), ["check", "--", roc(), "build", ...buildArgs], what);

/** The browser's host, built once (and again when its Zig changes), as site/build.mjs builds it. */
function webHost() {
	const object = join(root, "web", "platform", "targets", "wasm32", "host.wasm");
	const sources = [join(root, "web", "host", "host.zig"), join(root, "web", "host", "roc_platform_abi.zig")];
	if (existsSync(object) && sources.every((source) => statSync(source).mtimeMs <= statSync(object).mtimeMs)) return;
	mkdirSync(dirname(object), { recursive: true });
	step(zig(), ["build-obj", sources[0], "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fcompiler-rt", `-femit-bin=${object}`], "the browser's host");
}

/** Everything, beside what is served, then moved into place together: the server serving the
 * build before keeps serving it whole until it is restarted. The server first: it compiles every
 * page the browser does, from the app's own Generated/, whose reports point into the .rocx files. */
function build() {
	const started = performance.now();
	step(rocxBinary(), ["build", app, "--client", client, "--dev"], "rocx build");
	// The server's host (Rust): built the first time, in a few minutes, then only when it changes.
	try {
		buildHost();
	} catch (error) {
		throw new Error(`${error.message.trimEnd()}\nrocx dev: the server's host didn't build`);
	}
	const built = [server];
	rocBuild([`--target=${nativeTarget()}`, "--opt=dev", `--output=${server}.building`, main], "the server's build");
	// An app of pages has a browser's half (rocx build wrote its main.roc); one of endpoints alone hasn't.
	if (existsSync(join(client, "main.roc"))) {
		webHost();
		const wasm = join(client, "static", "rocx", "app.wasm");
		rocBuild(["--target=wasm32", "--opt=dev", `--output=${wasm}.building`, join(client, "main.roc")], "the browser's build");
		built.push(wasm);
	}
	for (const file of built) renameSync(`${file}.building`, file);
	console.error(`rocx dev: built ${shown} in ${((performance.now() - started) / 1000).toFixed(2)} s`);
}

// ---- Serving ----

let child = null;
let stopping = false;

function start() {
	const statics = ["--static", join(client, "static"), ...(existsSync(join(app, "static")) ? ["--static", join(app, "static")] : [])];
	child = spawn(server, ["--port", port, "--dev", ...statics, ...passed], { stdio: "inherit" });
	child.on("exit", (code, signal) => {
		if (stopping) return;
		console.error(`rocx dev: the server stopped (${signal ?? code}); save a file to build and start it again`);
		child = null;
	});
}

async function restart() {
	if (child && child.exitCode === null && child.signalCode === null) {
		const gone = new Promise((done) => child.once("exit", done));
		stopping = true;
		child.kill("SIGTERM");
		await gone;
		stopping = false;
	}
	start();
}

// However this process ends, the server it started ends with it, so the port isn't left taken: a
// signal (Ctrl-C reaches bin/rocx, this and the server at once), or bin/rocx gone without one.
const stop = () => {
	stopping = true;
	child?.kill("SIGTERM");
	process.exit(0);
};
process.on("exit", () => child?.kill("SIGTERM"));
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, stop);
const parent = process.ppid;
setInterval(() => process.ppid !== parent && stop(), 1000).unref();

try {
	build();
	start();
} catch (error) {
	console.error(error.message);
}

// ---- Watching ----

// What a build writes, or an editor leaves for a moment, is no edit: build/, dist/, Generated/,
// node_modules/, anything hidden, backups and swap files; static/ is served as it is on disk.
const OUTPUT = /^(build|dist|Generated|node_modules|static)$/;
const ignored = (path) => {
	const parts = path.split("/");
	return parts.some((part, i) => part.startsWith(".") || (i < parts.length - 1 && OUTPUT.test(part))) || /(~|\.swp|\.tmp|\.building)$/.test(path);
};
// A .roc file rocx wrote: beside its .rocx (a component), or ending with rocx's marker.
const rocxWrote = (path) => {
	if (!path.endsWith(".roc")) return false;
	if (existsSync(join(app, `${path}x`))) return true;
	try {
		return readFileSync(join(app, path), "utf8").trimEnd().split("\n").pop().startsWith(MARKER);
	} catch {
		return false;
	}
};
// Each file as last seen, its size and time: macOS reports a change of metadata, and an event it
// delivers late, as a change, and a file that is as it was is none.
const stamp = (path) => {
	try {
		const stat = statSync(join(app, path));
		return stat.isFile() ? `${stat.size}:${stat.mtimeMs}` : null;
	} catch {
		return null;
	}
};
const seen = new Map();
const walk = (dir) => {
	for (const entry of readdirSync(join(app, dir), { withFileTypes: true })) {
		const path = dir ? `${dir}/${entry.name}` : entry.name;
		if (ignored(entry.isDirectory() ? `${path}/` : path)) continue;
		if (entry.isDirectory()) walk(path);
		else seen.set(path, stamp(path));
	}
};
walk("");

let timer = null;
let building = false;
let again = false;

async function rebuild(path) {
	if (building) return void (again = true);
	building = true;
	console.error(`rocx dev: ${path} changed`);
	try {
		build();
		await restart();
	} catch (error) {
		console.error(error.message);
	}
	building = false;
	if (again) {
		again = false;
		await rebuild("a file");
	}
}

watch(app, { recursive: true }, (_, name) => {
	const path = name?.split("\\").join("/");
	if (!path || ignored(path) || rocxWrote(path)) return;
	const now = stamp(path);
	// As it was, or a file that came and went (an editor's temporary one).
	if (now === (seen.get(path) ?? null)) return;
	seen.set(path, now);
	clearTimeout(timer);
	timer = setTimeout(() => rebuild(path), 100);
});
