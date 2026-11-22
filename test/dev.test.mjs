// `rocx dev`, as the front page's Getting started uses it: on a copy of examples/hello without its
// main.roc, it writes one, builds the app, serves the page and the endpoint (the page hydrated in
// Chromium), builds again and restarts on a save, says where a mistake is in the .rocx file and
// keeps serving the build before, and stops its server when it is stopped. Needs the toolchain
// (`just setup`) and Chromium (web/test/browser.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { hasRust, roc, rocxBinary, zig } from "../server/build.mjs";
import { findChrome, launch } from "../web/test/browser.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const hasRoc = (() => {
	try {
		return spawnSync(roc(), ["version"]).status === 0;
	} catch {
		return false;
	}
})();
const skip =
	(!hasRoc && "no Roc (run `just setup`, or set ROC)") ||
	(spawnSync(zig(), ["version"]).status !== 0 && "no Zig (run `just setup`)") ||
	(!hasRust() && "no Rust (run `just setup`)") ||
	(!findChrome() && "no Chromium (set CHROME)");

/** A port nothing listens on now. */
const freePort = () =>
	new Promise((resolve) => {
		const probe = createServer().listen(0, "127.0.0.1", () => {
			const { port } = probe.address();
			probe.close(() => resolve(port));
		});
	});

/** Until `check` is true, or `seconds` have gone (a first build may build the server's host). */
async function until(check, seconds, what) {
	const deadline = Date.now() + seconds * 1000;
	for (;;) {
		if (await check()) return;
		if (Date.now() > deadline) throw new Error(`waited ${seconds} s for ${what}`);
		await new Promise((done) => setTimeout(done, 100));
	}
}

test("rocx dev: writes main.roc, serves the page and the endpoint, rebuilds on a save, says where a mistake is, and stops its server", { skip, timeout: 15 * 60 * 1000 }, async () => {
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "rocx-dev-")));
	cpSync(join(root, "examples", "hello"), dir, { recursive: true, filter: (path) => !/\/(Generated|build)$/.test(path) });
	rmSync(join(dir, "main.roc"));
	const port = await freePort();
	const url = `http://127.0.0.1:${port}`;
	// In a process group of its own, as a terminal runs it, so Ctrl-C (SIGINT to the group) reaches
	// bin/rocx, the Node beneath it and the server at once.
	const dev = spawn(rocxBinary(), ["dev", dir, "--port", String(port)], { stdio: ["ignore", "pipe", "pipe"], detached: true });
	let said = "";
	dev.stdout.on("data", (chunk) => (said += chunk));
	dev.stderr.on("data", (chunk) => (said += chunk));
	const builds = () => said.match(/^rocx dev: built /gm)?.length ?? 0;
	const page = async () => {
		try {
			return await (await fetch(url, { headers: { accept: "text/html" } })).text();
		} catch {
			return "";
		}
	};
	let browser = null;
	try {
		await until(async () => (await page()).includes("<h1>"), 10 * 60, `the first build:\n${said}`);

		// The program it wrote, on the clone's server platform; the page, server-rendered; the endpoint.
		const main = readFileSync(join(dir, "main.roc"), "utf8");
		assert.match(said, /rocx dev: wrote .*main\.roc, the app's program/);
		assert.match(main, /^app \[program\] \{ pf: platform "[^"]*server\/platform\/main\.roc" \}$/m);
		assert.match(await page(), /<h1>Hello, Roc Solid<\/h1> <button>Clicked <!--x-->0<!--\/x--> times<\/button>/);
		assert.match(await page(), /new EventSource\("\/__reload"\)/, "under --dev: the page reloads when the server is back");
		assert.equal(await (await fetch(`${url}/hello`)).json(), "Hello from the server");

		// The browser's half: the button counts.
		browser = await launch();
		const tab = await browser.page();
		await tab.goto(url);
		await tab.wait("document.querySelector('button')?.textContent === 'Clicked 0 times'");
		await tab.click("button");
		await tab.wait("document.querySelector('button').textContent === 'Clicked 1 times'");

		// A save: built again, the server restarted with it.
		const page_file = join(dir, "routes", "+page.rocx");
		const hello = readFileSync(page_file, "utf8");
		writeFileSync(page_file, hello.replace("Hello, Roc Solid", "Hello again"));
		await until(async () => (await page()).includes("<h1>Hello again</h1>"), 60, `the rebuild:\n${said}`);

		// A mistake: said at its line in the .rocx file; the build before still served.
		const before = builds();
		writeFileSync(page_file, hello.replace("<h1>Hello, Roc Solid</h1>", "<h1>{nobody}</h1>"));
		await until(() => /the server's build failed/.test(said), 60, `the failed build:\n${said}`);
		assert.match(said, /routes\/\+page\.rocx:8:8/, "the report points into the .rocx file");
		assert.equal(builds(), before);
		assert.match(await page(), /<h1>Hello again<\/h1>/);

		// Fixed: served again.
		writeFileSync(page_file, hello);
		await until(async () => (await page()).includes("<h1>Hello, Roc Solid</h1>"), 60, `the build after the fix:\n${said}`);
	} finally {
		await browser?.close();
		const gone = new Promise((done) => (dev.exitCode !== null ? done() : dev.once("exit", done)));
		process.kill(-dev.pid, "SIGINT");
		await gone;
		rmSync(dir, { recursive: true, force: true });
	}
	// Its server went with it: the port is free again.
	await until(async () => (await page()) === "", 10, "the server to stop");
});
