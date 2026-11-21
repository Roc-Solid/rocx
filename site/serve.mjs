#!/usr/bin/env node
// The docs site, served: `site/main.roc` on the server platform (server/platform), one native
// executable that answers every page, endpoint and call to a server function, and the files a page
// loads (the site's, and start.js, runtime.js and app.wasm at /rocx/); Node only builds. With
// --watch, a save rebuilds (in a process of its own, so an edit to the build or to rocx itself is
// used at once), the server restarts, and open pages reload when it is back.
//
//   node site/serve.mjs [--watch] [--port 8080] [--database-url URL]
import { spawn } from "node:child_process";
import { existsSync, watch } from "node:fs";
import { basename, join, relative } from "node:path";
import { root, server, serverFlags } from "./build.mjs";
import { SHARED_MODULES } from "../server/build.mjs";

const args = process.argv.slice(2);
const value = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const port = Number(value("--port") || process.env.PORT || 8080);
const watching = args.includes("--watch");
const databaseUrl = value("--database-url") ?? process.env.DATABASE_URL;

let child = null;

/** Everything `just site` builds, from Roc's dev backend, and no measuring: `site/build.mjs --dev`. */
function rebuild() {
	return new Promise((resolve, reject) => {
		const building = spawn(process.execPath, [join(root, "site", "build.mjs"), "--dev"], { stdio: "inherit" });
		building.on("exit", (code) => (code === 0 ? resolve() : reject(new Error("rocx site: the build failed; fix it and save again"))));
	});
}

function start() {
	child = spawn(server, ["--port", String(port), ...serverFlags({ dev: watching, databaseUrl })], { stdio: "inherit" });
	child.on("exit", (code, signal) => {
		if (signal !== "SIGTERM" && !watching) process.exit(code ?? 1);
	});
}

async function restart() {
	if (child && child.exitCode === null) {
		const gone = new Promise((resolve) => child.once("exit", resolve));
		child.kill("SIGTERM");
		await gone;
	}
	start();
}

try {
	await rebuild();
} catch (error) {
	console.error(error.message);
	if (!watching) process.exit(1);
}
start();

if (watching) {
	let timer = null;
	const ignored = (path) => /(^|\/)(build|dist|Generated|target|targets)\//.test(path) || path.endsWith(".tmp");
	// What the build writes itself: a .roc beside its .rocx, the lists of server functions, and the
	// server platform's copies of the modules both platforms have.
	const written = (path) =>
		(path.endsWith(".roc") && existsSync(join(root, `${path}x`))) ||
		basename(path) === "ServerFunctions.roc" ||
		SHARED_MODULES.some((name) => path === `server/platform/${name}.roc`);
	const changed = (path) => {
		if (!path || ignored(path) || written(path)) return;
		if (path === "site/serve.mjs") return console.error("rocx site: site/serve.mjs changed; restart `just dev` to use it");
		if (/(^|\/)test\//.test(path) || !/\.(rocx|roc|zig|rs|c|js|mjs|css|svg|toml)$/.test(path)) return;
		clearTimeout(timer);
		timer = setTimeout(async () => {
			console.error(`rocx site: ${path} changed`);
			try {
				await rebuild();
				await restart();
			} catch (error) {
				console.error(error.message);
			}
		}, 100);
	};
	// Only the directories that exist: watching a missing one throws, and would stop `just dev`.
	for (const dir of ["site", "packages", "web", "src", "bin", "server/platform", "server/host"]) {
		if (!existsSync(join(root, dir))) continue;
		watch(join(root, dir), { recursive: true }, (_, name) => changed(name && relative(root, join(root, dir, name))));
	}
}

// However this process ends (a signal, an error it didn't catch, process.exit), the server it
// started ends with it, so a failed `just dev` doesn't leave the port taken.
process.on("exit", () => child?.kill("SIGTERM"));
for (const signal of ["SIGINT", "SIGTERM"]) {
	process.on(signal, () => {
		child?.kill("SIGTERM");
		process.exit(0);
	});
}
