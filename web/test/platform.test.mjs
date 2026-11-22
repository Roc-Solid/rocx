// The web platform in Chromium and in Node: the test app (web/test/app, Solid-style components in
// rocx) built on it, against a scripted server (answers after a delay; told which calls fail): the
// profile, mounted; the picks and the echo, rendered by the runtime as the server would
// (`renderToString`, from the answers the server gave their reads) and hydrated; whole documents
// (the docs' demos among them), rendered as the server platform answers a page and hydrated by
// start.js, under a base path too. Builds what it needs
// first: the app through rocx, the browser's copy of it (no <NoHydration>'s children), the host,
// and each app. Needs the toolchain (`just setup`) and Chromium (browser.mjs).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { roc as findRoc, rocxBinary, zig } from "../../server/build.mjs";
import { findChrome, launch } from "./browser.mjs";
import { serve } from "./serve.mjs";
import { Runtime } from "../runtime.js";

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, "..");
const root = join(web, "..");
const out = join(here, "build");
// The compiler `just setup` links (the fork rocx builds with), else $ROC: server/build.mjs's.
const roc = (() => {
	try {
		return findRoc();
	} catch {
		return "";
	}
})();
const skip = ((!roc || spawnSync(roc, ["version"]).status !== 0) && "no roc (run `just setup`, or set ROC)") || (!findChrome() && "no Chromium (set CHROME)");

function run(command, args) {
	const result = spawnSync(command, args, { cwd: root, encoding: "utf8" });
	if (result.status !== 0) throw new Error(`${command} ${args.join(" ")}:\n${result.stdout}${result.stderr}`);
}

/** The app through rocx, and the browser's copy; the host; then each app, the profile from the dev
 * backend and optimized, the others as the server's half (dev backend) or the browser's (for size). */
if (!skip) {
	run(rocxBinary(), ["build", join(here, "app"), "--client", join(out, "app-client")]);
	mkdirSync(join(web, "platform", "targets", "wasm32"), { recursive: true });
	run(zig(), ["build-obj", join(web, "host", "host.zig"), "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fcompiler-rt", `-femit-bin=${join(web, "platform", "targets", "wasm32", "host.wasm")}`]);
	for (const [name, app, opt] of [
		["app-dev", join(here, "app", "main.roc"), "dev"],
		["app-size", join(here, "app", "main.roc"), "size"],
		["picks", join(here, "app", "picks_app.roc"), "size"],
		["nested", join(here, "app", "nested_app.roc"), "dev"],
		["timers", join(here, "app", "timers_app.roc"), "dev"],
		["props", join(here, "app", "props_app.roc"), "dev"],
		["fades", join(here, "app", "fades_app.roc"), "dev"],
		["echo-server", join(here, "app", "echo_app.roc"), "dev"],
		["echo", join(out, "app-client", "echo_app.roc"), "size"],
		["docs-server", join(here, "app", "docs_app.roc"), "dev"],
		["docs", join(out, "app-client", "docs_app.roc"), "size"],
		["alone", join(here, "app", "alone_app.roc"), "dev"],
		["raw", join(here, "app", "raw_app.roc"), "dev"],
		["document-server", join(here, "app", "document_app.roc"), "dev"],
		["document", join(out, "app-client", "document_app.roc"), "size"],
		["wrapped-server", join(here, "app", "wrapped_app.roc"), "dev"],
		["wrapped", join(out, "app-client", "wrapped_app.roc"), "dev"],
		["titles-server", join(here, "app", "titles_app.roc"), "dev"],
		["titles", join(out, "app-client", "titles_app.roc"), "size"],
		["effects-server", join(here, "app", "effects_app.roc"), "dev"],
		["effects", join(out, "app-client", "effects_app.roc"), "size"],
		["form-server", join(here, "app", "form_app.roc"), "dev"],
		["form", join(out, "app-client", "form_app.roc"), "size"],
		["reads-server", join(here, "app", "reads_app.roc"), "dev"],
		["reads", join(out, "app-client", "reads_app.roc"), "size"],
		["channels-server", join(here, "app", "channels_app.roc"), "dev"],
		["channels", join(out, "app-client", "channels_app.roc"), "size"],
		["pending-server", join(here, "app", "pending_app.roc"), "dev"],
		["pending", join(out, "app-client", "pending_app.roc"), "size"],
		["planner-server", join(here, "app", "planner_app.roc"), "dev"],
		["planner", join(out, "app-client", "planner_app.roc"), "size"],
	]) {
		run(roc, ["build", "--target=wasm32", `--opt=${opt}`, `--output=${join(out, `${name}.wasm`)}`, app]);
	}
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The server: what it answers, how slowly, and which calls fail how many times. */
const server = { delay: 60, fail: {}, name: "Ada", calls: [] };
const json = (value) => ({ status: 200, body: JSON.stringify(value) });

/** The test app's endpoints that its pages read (`Endpoint.get!`): `GET /api/<name>/<arg>`, the
 * arg a path segment. The native server answers them as it renders a page, recording the answers
 * for the browser, and answers the browser's GETs. Here, scripted, as JS. */
const READS = { say: (word) => `Said: ${word}`, echo: (message) => `Echo: ${message}` };

/** A read's answer, as the server gives it: 200 and the answer as JSON, or 404. */
const readAnswer = (name, arg) => (READS[name] ? json(READS[name](arg)) : { status: 404, body: `nothing at /api/${name}` });

/** The GET a read is, as a page's answers script names it (`GET /api/say/hello`). */
const readKey = (name, arg) => `GET /api/${name}/${encodeURIComponent(arg)}`;

/** A read of `path` (`/api/say/hello`, under `base`, decoded), if it is one. */
const readOf = (path, base = "/") => {
	const found = new RegExp(`^${base}api/(\\w+)/(.*)$`).exec(path);
	return found ? { name: found[1], arg: found[2] } : null;
};

/** The answers the server gave the test app's reads as it rendered its pages (`[[name, input,
 * answer]]`, as a page's answers script has them, each answer `{"status":…,"body":…}`): what
 * `renderToString({ answers })` answers each GET from, as the server platform would have. */
const RENDERED = [
	["say", "hello"],
	["say", "quiet"],
	["echo", "the page, rendered on the server"],
].map(([name, arg]) => {
	const answered = readAnswer(name, arg);
	return [readKey(name, arg), "", JSON.stringify({ status: answered.status, body: answered.body })];
});

/** The profile's endpoints, scripted: `GET /api/<name>` (`/api/posts_of/<id>`) and
 * `POST /api/rename`. */
async function answer(method, path, body) {
	const [, name, arg] = /^\/api\/(\w+)(?:\/(.*))?$/.exec(path) ?? [];
	if (!name || READS[name]) return null;
	server.calls.push(name);
	await sleep(name === "rename" ? 20 : server.delay);
	if (server.fail[name] > 0) {
		server.fail[name]--;
		return { status: 500, body: "the database is down" };
	}
	if (name === "current_user") return json({ id: 7, name: server.name });
	if (name === "posts_of") return json(Number(arg) === 7 ? [{ title: "Roc" }, { title: "rocx" }] : []);
	if (name === "friends") return json(["Grace", "Katherine"]);
	if (name === "likes") return json(42);
	if (name === "notifications") return json(3);
	if (name === "rename" && method === "POST") {
		server.name = JSON.parse(body).trim() || server.name;
		return json(server.name);
	}
	return { status: 404, body: `nothing at ${path}` };
}

let browser;
before(async () => {
	if (!skip) browser = await launch();
});
after(async () => {
	await browser?.close();
});

for (const build of ["app-dev.wasm", "app-size.wasm"]) {
	const dir = mkdtempSync(join(tmpdir(), "rocx-signals-"));
	if (!skip) cpSync(join(out, build), join(dir, "app.wasm"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(
		join(dir, "index.html"),
		`<!doctype html><html><body><div id="app"></div><script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/app.wasm"));
window.runtime.mount(document.getElementById("app"));
</script></body></html>`,
	);
	let site;
	const open = async () => {
		if (!site) site = await serve(dir, () => null, answer);
		const page = await browser.page();
		await page.goto(`${site.url}/`);
		return page;
	};
	const text = (page, selector) => page.eval(`document.querySelector(${JSON.stringify(selector)})?.textContent ?? null`);
	const texts = (page, selector) => page.eval(`[...document.querySelectorAll(${JSON.stringify(selector)})].map((e) => e.textContent)`);
	const reset = () => Object.assign(server, { fail: {}, name: "Ada", calls: [] });

	test(`${build}: one spinner until all five answers are in, then all of it`, { skip }, async () => {
		reset();
		const page = await open();
		await page.wait("document.querySelector('.spinner') || document.querySelector('h1')");
		assert.equal(await text(page, ".spinner"), "Loading…", "the fallback first");
		assert.equal(await text(page, "h1"), null, "nothing inside shows while it waits");
		await page.wait("document.querySelector('h1')", 3000);
		assert.equal(await text(page, ".spinner"), null);
		assert.equal(await text(page, "h1"), "Ada");
		assert.equal(await text(page, ".stats"), "42 likes · 3 new");
		assert.deepEqual(await texts(page, ".posts li"), ["Roc", "rocx"]);
		assert.deepEqual(await texts(page, ".friends li"), ["Grace", "Katherine"]);
		assert.deepEqual([...server.calls].sort(), ["current_user", "friends", "likes", "notifications", "posts_of"], "each asked once");
		assert.deepEqual(page.errors, []);
		assert.deepEqual(page.console, []);
	});

	test(`${build}: a click patches the one text that reads the count`, { skip }, async () => {
		reset();
		const page = await open();
		await page.wait("document.querySelector('h1')", 3000);
		await page.eval("window.h1 = document.querySelector('h1'); window.patched = window.runtime.stats.patches");
		for (let i = 0; i < 3; i++) await page.click(".count");
		await page.wait("document.querySelector('.count').textContent === 'Clicked 3 times'");
		assert.equal(await page.eval("window.h1 === document.querySelector('h1')"), true, "the heading is the same node");
		assert.equal(await page.eval("window.runtime.stats.patches - window.patched"), 3, "one patch a click");
		const live = await page.eval("window.runtime.live()");
		for (let i = 0; i < 50; i++) await page.click(".count");
		await page.wait("document.querySelector('.count').textContent === 'Clicked 53 times'");
		assert.equal(await page.eval("window.runtime.live()"), live, "a click leaves no allocation behind");
	});

	test(`${build}: a region fails on its own, and tries again`, { skip }, async () => {
		reset();
		server.fail.friends = 1;
		const page = await open();
		await page.wait("document.querySelector('h1')", 3000);
		await page.wait("document.querySelector('.friends .problem')");
		assert.equal(await text(page, ".friends .problem"), "No friends: GET /api/friends: 500: the database is down Again");
		assert.deepEqual(await texts(page, ".posts li"), ["Roc", "rocx"], "the rest renders");
		await page.click(".friends .problem button");
		await page.wait("document.querySelectorAll('.friends li').length === 2", 3000);
		assert.equal(await text(page, ".friends .problem"), null);
		assert.deepEqual(page.errors, []);
	});

	test(`${build}: a failure outside the regions fails the page, which tries again`, { skip }, async () => {
		reset();
		server.fail.likes = 1;
		const page = await open();
		await page.wait("document.querySelector('.page-problem')", 3000);
		assert.match(await text(page, ".page-problem"), /^The page failed: GET \/api\/likes: 500: the database is down/);
		assert.equal(await text(page, "h1"), null);
		await page.click(".page-problem button");
		await page.wait("document.querySelector('.stats')?.textContent === '42 likes · 3 new'", 3000);
		assert.equal(await text(page, "h1"), "Ada");
	});

	test(`${build}: a handler calls the server and waits for it; the page shows what the server says`, { skip }, async () => {
		reset();
		const page = await open();
		await page.wait("document.querySelector('h1')", 3000);
		await page.type(".rename input", "  Grace Hopper ");
		await page.click(".rename button");
		await page.wait("document.querySelector('h1').textContent === 'Grace Hopper'", 3000);
		assert.equal(server.calls.filter((name) => name === "rename").length, 1, "the command is sent once, though its handler ran twice");
		assert.equal(server.calls.filter((name) => name === "current_user").length, 2, "and who you are is asked again");
		assert.deepEqual(page.errors, []);
	});

	test(`${build}: <For> keeps a row per key and moves it; keyed={Bool.False} keeps rows by position; <Show> switches`, { skip }, async () => {
		reset();
		const page = await open();
		// The profile's answers first: what they render would count as allocations below.
		await page.wait("document.querySelector('h1') && document.querySelectorAll('.friends li').length === 2", 3000);
		await page.wait("document.querySelectorAll('.picks .keyed li').length === 3");
		const keyed = () => texts(page, ".picks .keyed li");
		const unkeyed = () => texts(page, ".picks .unkeyed li");
		assert.deepEqual(await keyed(), ["0: Roc", "1: Solid", "2: Elm"]);
		assert.deepEqual(await unkeyed(), ["0: Roc", "1: Solid", "2: Elm"]);
		assert.equal(await text(page, ".picks .few"), "Three or fewer");
		assert.equal(await text(page, ".picks .first"), "First: Roc");
		await page.eval("window.roc = [...document.querySelectorAll('.picks .keyed li')].find((li) => li.textContent.endsWith('Roc')); window.top0 = document.querySelector('.picks .unkeyed li'); window.few = document.querySelector('.picks .few')");
		await page.click(".picks .reverse");
		await page.wait("document.querySelector('.picks .first').textContent === 'First: Elm'");
		assert.deepEqual(await keyed(), ["0: Elm", "1: Solid", "2: Roc"], "rows moved, their indexes changed");
		assert.equal(await page.eval("window.roc === [...document.querySelectorAll('.picks .keyed li')][2]"), true, "Roc's row is the same element, moved");
		assert.deepEqual(await unkeyed(), ["0: Elm", "1: Solid", "2: Roc"]);
		assert.equal(await page.eval("window.top0 === document.querySelector('.picks .unkeyed li')"), true, "the first position's row stays, its pick changed");
		assert.equal(await page.eval("window.few === document.querySelector('.picks .few')"), true, "<Show> didn't switch: still three");
		// An edit keeps the ids: every keyed row stays, the same element, its name changed.
		await page.eval("window.keyedRows = [...document.querySelectorAll('.picks .keyed li')]");
		await page.click(".picks .shout");
		await page.wait("document.querySelector('.picks .first').textContent === 'First: ELM'");
		assert.deepEqual(await keyed(), ["0: ELM", "1: SOLID", "2: ROC"]);
		assert.equal(await page.eval("window.keyedRows.every((row, i) => row === document.querySelectorAll('.picks .keyed li')[i])"), true, "rows kept by their key, their text patched");
		assert.deepEqual(await unkeyed(), ["0: ELM", "1: SOLID", "2: ROC"]);
		await page.click(".picks .add");
		await page.wait("document.querySelectorAll('.picks .keyed li').length === 4");
		assert.equal(await text(page, ".picks .many"), "More than three");
		assert.equal(await text(page, ".picks .few"), null);
		assert.equal(await page.eval("window.roc === [...document.querySelectorAll('.picks .keyed li')][2]"), true, "rows stay when one is added");
		await page.click(".picks .clear");
		await page.wait("document.querySelector('.picks .keyed .none') !== null");
		assert.deepEqual(await keyed(), ["None"], "the fallback, with no rows");
		assert.deepEqual(await unkeyed(), []);
		assert.equal(await text(page, ".picks .first"), null, "nothing to narrow to");
		await page.click(".picks .add");
		await page.wait("document.querySelector('.picks .first')?.textContent === 'First: Gleam'");
		assert.deepEqual(await keyed(), ["0: Gleam"], "the fallback goes when a row comes");
		const live = await page.eval("window.runtime.live()");
		for (let i = 0; i < 20; i++) await page.click(i % 2 ? ".picks .add" : ".picks .clear");
		await page.wait("document.querySelectorAll('.picks .keyed li').length === 1 && document.querySelector('.picks .keyed .none') === null");
		assert.equal(await page.eval("window.runtime.live()"), live, "rows made and dropped leave nothing behind");
		assert.deepEqual(page.errors, []);
		assert.deepEqual(page.console, []);
	});

	after(async () => {
		await site?.close();
		rmSync(dir, { recursive: true, force: true });
	});
}

test("picks: <For> and <Show> render on the server and hydrate: the server's rows, kept", { skip }, async () => {
	const wasm = readFileSync(join(out, "picks.wasm"));
	const server = await Runtime.load(wasm);
	const { html, answers } = server.renderToString({ path: "/" });
	assert.match(html, /<ol class="keyed"[^>]*><!--for--><!--row--><li><!--x-->0<!--\/x-->: <!--x-->Roc<!--\/x--><\/li><!--\/row-->/);
	assert.match(html, /<!--show--><p class="few">Three or fewer<\/p><!--\/show-->/);
	const dir = mkdtempSync(join(tmpdir(), "rocx-picks-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(join(dir, "picks.wasm"), wasm);
	const page = `<!doctype html><html><body><div id="app">${html}${Runtime.answersScript(answers)}</div>
<script>window.rows = [...document.querySelectorAll(".keyed li")];</script>
<script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/picks.wasm"));
window.runtime.hydrate(document.getElementById("app"));
window.hydrated = true;
</script></body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? page : null));
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.hydrated === true", 3000);
		assert.deepEqual(tab.console, [], "hydrated without a mismatch");
		assert.equal(await tab.eval("window.rows.every((row, i) => row === document.querySelectorAll('.keyed li')[i])"), true, "the server's rows, kept");
		await tab.click(".reverse");
		await tab.wait("document.querySelector('.first').textContent === 'First: Elm'");
		assert.deepEqual(await tab.eval("[...document.querySelectorAll('.keyed li')].map((li) => li.textContent)"), ["0: Elm", "1: Solid", "2: Roc"]);
		assert.equal(await tab.eval("window.rows[0] === document.querySelectorAll('.keyed li')[2]"), true, "a server row, moved");
		await tab.click(".clear");
		await tab.wait("document.querySelector('.keyed .none') !== null");
		await tab.click(".add");
		await tab.wait("document.querySelector('.keyed .none') === null && document.querySelectorAll('.keyed li').length === 1");
		assert.deepEqual(tab.errors, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

test("nested: a <For> in a <For>'s row, and a <For> in a <Show>'s function child, render on the server, hydrate, and follow their signals", { skip }, async () => {
	const wasm = readFileSync(join(out, "nested.wasm"));
	const server = await Runtime.load(wasm);
	const { html, answers } = server.renderToString({ path: "/" });
	assert.match(html, /<h3><!--x-->Fruit<!--\/x--><\/h3> <ol><!--for--><!--row--><li>0: <!--x-->apple<!--\/x--><\/li><!--\/row--><!--row--><li>1: <!--x-->pear<!--\/x--><\/li><!--\/row--><!--\/for--><\/ol>/);
	assert.match(html, /<p class="first">First: <!--x-->Fruit<!--\/x--> <!--for--><!--row--><span class="item"><!--x-->apple<!--\/x--><\/span>/);
	const dir = mkdtempSync(join(tmpdir(), "rocx-nested-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(join(dir, "nested.wasm"), wasm);
	const page = `<!doctype html><html><body><div id="app">${html}${Runtime.answersScript(answers)}</div>
<script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/nested.wasm"));
window.runtime.hydrate(document.getElementById("app"));
window.hydrated = true;
</script></body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? page : null));
	const tab = await browser.page();
	const items = (selector) => tab.eval(`[...document.querySelectorAll(${JSON.stringify(selector)})].map((node) => node.textContent)`);
	try {
		await tab.goto(`${site.url}/`);
		await tab.wait("window.hydrated === true", 3000);
		assert.deepEqual(tab.console, [], "hydrated without a mismatch");
		await tab.click(".add");
		await tab.wait("document.querySelectorAll('.shelves > li:nth-child(2) li').length === 2");
		assert.deepEqual(await items(".shelves > li:nth-child(2) li"), ["0: rye", "1: spelt"], "the inner <For> of a row follows its row's item");
		await tab.click(".swap");
		await tab.wait("document.querySelector('.first').textContent.startsWith('First: Bread')");
		assert.deepEqual(await items(".first .item"), ["rye", "spelt"], "the <For> in the <Show>'s child follows its accessor");
		assert.deepEqual(await items(".shelves h3"), ["Bread", "Fruit"]);
		assert.deepEqual(tab.errors, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

// ---- Timers: the browser's, owned by what started them ----

test("props: a value prop is a getter (D-039): the component is made once and keeps its signals, and only what reads the prop is patched, in a hole, outside one, in a <Show>; read in the body, once; in a pure lambda, by its hole; in an effect and a handler, as they run; rows made once; what a <Show> shows and a fallback made as they show", { skip }, async () => {
	const wasm = readFileSync(join(out, "props.wasm"));
	const server = await Runtime.load(wasm);
	const { html } = server.renderToString({ path: "/" });
	const label = (text, clicks = 0) => `<button class="shows"><!--x-->${text}<!--/x--> <!--x-->${clicks}<!--/x--></button>`;
	assert.ok(html.includes(`<p class="hole"><!--html-->${label("one")}<!--/html--></p>`), "the server renders the label in a hole of the component's");
	assert.ok(html.includes(`<p class="once">${label("one")}</p>`));
	assert.ok(html.includes(`<span class="first">one</span> <span class="joined"><!--x-->a-one,b-one<!--/x--></span>`), "read in the body: static; in a pure lambda: its hole's");
	assert.ok(html.includes(`<li data-id="a">${label("Ada")} <span class="first">Ada</span></li>`));
	assert.ok(html.includes(`<p class="toggled"><!--show-->${label("no one")}<!--/show--></p>`), "a <Show>'s fallback, made as it shows");
	assert.ok(html.includes(`<p class="listed"><!--for--><!--fallback-->${label("none, one")}<!--/fallback--><!--/for--></p>`), "a <For>'s fallback, made as it shows");
	const dir = mkdtempSync(join(tmpdir(), "rocx-props-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(join(dir, "props.wasm"), wasm);
	const page = `<!doctype html><html><body><div id="app">${html}</div>
<script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/props.wasm"));
window.runtime.hydrate(document.getElementById("app"), { strict: true });
window.hydrated = true;
</script></body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? page : null));
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.hydrated === true", 3000);
		assert.deepEqual(tab.console, [], "hydrated strictly, asking for nothing");
		const shown = () => tab.eval(`["p.hole", "p.once", "p.getter", "p.shown", "li[data-id=a] button", "li[data-id=b] button"].map((p) => document.querySelector(p).textContent)`);
		const detail = () => tab.eval(`["span.first", "span.joined", "span.seen", "button.say"].map((p) => document.querySelector(".detail " + p).textContent)`);
		await tab.wait(`document.querySelector(".detail .seen").textContent === "one"`);
		assert.deepEqual(await shown(), ["one 0", "one 0", "one 0", "one 0", "Ada 0", "Bo 0"]);
		for (const button of ["p.hole button", "p.once button", "p.getter button", "p.shown button", "li[data-id=a] button"]) await tab.click(button);
		await tab.wait(`document.querySelector("li[data-id=a] button").textContent === "Ada 1"`);
		assert.deepEqual(await shown(), ["one 1", "one 1", "one 1", "one 1", "Ada 1", "Bo 0"], "each its own clicks");
		// The elements, to see they are kept; and what is patched.
		await tab.eval(`window.kept = ["p.hole button", "p.once button", "p.shown button", "li[data-id=a]", ".detail"].map((p) => document.querySelector(p)); window.patched = []; window.runtime.observer = { patch: ({ node }) => window.patched.push((node.nodeType === 1 ? node : node.parentElement)?.className || node.parentElement?.localName || "detached") }`);
		await tab.click(".set");
		await tab.wait(`document.querySelector("p.once").textContent.startsWith("two")`);
		assert.deepEqual(await shown(), ["two 1", "two 1", "two 1", "two 1", "Ada 1", "Bo 0"], "patched where the label is read, the component kept, its clicks with it (in a hole too)");
		await tab.wait(`document.querySelector(".detail .seen").textContent === "two"`);
		assert.deepEqual(await detail(), ["one", "a-two,b-two", "two", ""], "the body's read is the first; the pure lambda's hole, and the effect, follow");
		assert.deepEqual(await tab.eval(`window.patched.sort()`), ["getter", "joined", "seen", "shows", "shows", "shows", "shows", "shows"], "only what reads the label: six labels (one an accessor's, two in fallbacks), the pure lambda's hole, and what the effect set");
		assert.equal(await tab.eval(`window.kept.every((node, i) => node === document.querySelector(["p.hole button", "p.once button", "p.shown button", "li[data-id=a]", ".detail"][i]))`), true, "the same elements");
		await tab.eval("window.runtime.observer = null");
		await tab.click(".detail .say");
		await tab.wait(`document.querySelector(".detail .say").textContent === "two"`, 2000);
		await tab.click(".rename");
		await tab.wait(`document.querySelector("li[data-id=a] button").textContent === "Ana 1"`);
		assert.equal(await tab.eval(`document.querySelector("li[data-id=a] .first").textContent`), "Ada", "a row's own read, at its top, is once: the row is made once");
		assert.equal(await tab.eval(`window.kept[3] === document.querySelector("li[data-id=a]")`), true, "the row kept; its component patched, its clicks kept");
		// What a <Show> shows, and a fallback, is made when it shows; a value prop in it, a getter, is
		// patched while it shows.
		const part = (p) => tab.eval(`document.querySelector(${JSON.stringify(p)}).textContent.trim()`);
		assert.equal(await part("p.toggled"), "no two 0", "the fallback, its label patched where it is read");
		await tab.click(".toggle");
		await tab.wait(`document.querySelector("p.toggled").textContent.trim() === "two 0"`);
		await tab.click(".again");
		await tab.wait(`document.querySelector("p.toggled").textContent.trim() === "three 0"`);
		await tab.click(".toggle");
		await tab.wait(`document.querySelector("p.toggled").textContent.trim() === "no three 0"`);
		await tab.click(".toggle");
		await tab.wait(`document.querySelector("p.toggled").textContent.trim() === "three 0"`);
		await tab.click("p.toggled button");
		await tab.wait(`document.querySelector("p.toggled").textContent.trim() === "three 1"`);
		assert.equal(await part("p.listed"), "none, three 0");
		await tab.click(".fill");
		await tab.wait(`document.querySelector("p.listed .item")?.textContent === "an item"`);
		await tab.click(".fill");
		await tab.wait(`document.querySelector("p.listed").textContent.trim() === "none, three 0"`);
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	} finally {
		await site.close();
	}
});

test("timers: the server starts none; in the browser they run as handlers, stop with their clear!, and go with what started them", { skip }, async () => {
	const wasm = readFileSync(join(out, "timers.wasm"));
	const server = await Runtime.load(wasm);
	const { html } = server.renderToString({ path: "/" });
	assert.match(html, /<p class="ticker">ticking<\/p>/);
	assert.match(html, /<p class="settled"><!--x-->0<!--\/x--><\/p>/, "on_settled! never runs on the server");
	assert.equal(server.timers.size, 0, "rendering as the server would, no timer is started");
	const before = server.live();
	for (let i = 0; i < 20; i++) server.renderToString({ path: "/" });
	assert.equal(server.live(), before, "the timers' handlers, let go of while rendering");
	const dir = mkdtempSync(join(tmpdir(), "rocx-timers-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(join(dir, "timers.wasm"), wasm);
	const page = `<!doctype html><html><body><div id="app">${html}</div>
<script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/timers.wasm"));
window.runtime.hydrate(document.getElementById("app"));
window.hydrated = true;
</script></body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? page : null));
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.hydrated === true", 3000);
		assert.deepEqual(tab.console, [], "hydrated without a mismatch");
		// on_settled! ran once the timers were on the page, in the browser only, and once.
		await tab.wait("document.querySelector('.settled').textContent === '1'");
		const number = async (selector) => Number(await tab.eval(`document.querySelector(${JSON.stringify(selector)}).textContent`));
		const timers = () => tab.eval("window.runtime.timers.size");
		const kept = () => tab.eval("window.runtime.kept.size");

		// A component's interval runs once it is hydrated, and stops when the <Show> hides it.
		await tab.wait("Number(document.querySelector('.ticks').textContent) >= 3");
		assert.equal(await timers(), 1);
		await tab.click(".toggle");
		await tab.wait("document.querySelector('.ticker') === null");
		assert.equal(await timers(), 0, "the ticker's interval, gone with it");
		const ticks = await number(".ticks");
		await sleep(100);
		assert.equal(await number(".ticks"), ticks, "no tick once the ticker is gone");
		const idle = await kept();

		// A handler's interval, stopped by its clear!.
		await tab.click(".start");
		await tab.wait("Number(document.querySelector('.counted').textContent) >= 3");
		assert.equal(await timers(), 1);
		await tab.click(".stop");
		await tab.wait("window.runtime.timers.size === 0");
		const counted = await number(".counted");
		await sleep(100);
		assert.equal(await number(".counted"), counted, "no tick once it is cleared");
		assert.equal(await kept(), idle, "its handler, let go of");

		// A timeout runs once, and its handler is let go of; one called off never runs.
		await tab.click(".ring");
		assert.equal(await timers(), 1);
		await tab.wait("document.querySelector('.rang').textContent === '1'");
		assert.equal(await timers(), 0);
		assert.equal(await kept(), idle, "a timeout's handler, let go of once it has run");
		await tab.click(".ring");
		await tab.click(".call-off");
		await sleep(150);
		assert.equal(await number(".rang"), 1, "called off: it never rang");
		assert.equal(await kept(), idle);

		// An interval that clears itself, from its own handler.
		await tab.click(".three");
		await tab.wait("document.querySelector('.thrice').textContent === '3'");
		await sleep(100);
		assert.equal(await number(".thrice"), 3, "it stopped itself on its third tick");
		assert.equal(await timers(), 0);
		assert.equal(await kept(), idle);

		// Showing and hiding the ticker again and again leaves nothing behind.
		const live = await tab.eval("window.runtime.live()");
		for (let i = 0; i < 5; i++) {
			await tab.click(".toggle");
			await tab.wait("document.querySelector('.ticker') !== null");
			await sleep(30);
			await tab.click(".toggle");
			await tab.wait("document.querySelector('.ticker') === null");
		}
		assert.equal(await timers(), 0);
		assert.equal(await tab.eval("window.runtime.live()"), live, "every ticker's interval and signals, let go of");
		assert.equal(await number(".settled"), 1, "on_settled! ran once, whatever happened after");
		assert.deepEqual(tab.errors, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});


test("transitions: rows and parts play theirs as they come and go, stay until they have, and nothing plays on load", { skip }, async () => {
	const wasm = readFileSync(join(out, "fades.wasm"));
	const server = await Runtime.load(wasm);
	const { html } = server.renderToString({ path: "/" });
	assert.match(html, /<li><!--x-->a<!--\/x--><\/li>/);
	assert.match(html, /<div class="panel">/);
	assert.doesNotMatch(html, /transition|inert/, "the server writes nothing for them");
	const dir = mkdtempSync(join(tmpdir(), "rocx-fades-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(join(dir, "fades.wasm"), wasm);
	const page = `<!doctype html><html><body><div id="app">${html}</div>
<script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/fades.wasm"));
window.runtime.hydrate(document.getElementById("app"));
window.hydrated = true;
</script></body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? page : null));
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.hydrated === true", 3000);
		assert.deepEqual(tab.console, [], "hydrated without a mismatch");
		const texts = (selector) => tab.eval(`[...document.querySelectorAll(${JSON.stringify(selector)})].map((node) => node.textContent)`);
		const playing = (selector) => tab.eval(`[...document.querySelectorAll(${JSON.stringify(selector)})].map((node) => node.getAnimations().length)`);
		assert.equal(await tab.eval("document.getAnimations().length"), 0, "nothing plays as the page wakes up");

		// A row that comes plays its transition in; the list without any has its row at once.
		await tab.click(".add");
		assert.deepEqual(await texts(".faded li"), ["a", "b", "c", "n0"]);
		assert.deepEqual(await playing(".faded li"), [0, 0, 0, 1], "the new row fades in");
		assert.deepEqual(await playing(".plain li, .inner li"), [0, 0, 0, 0, 0, 0, 0, 0], "a row with no transition in plays none");

		// A row that goes stays, inert, until its transition is over; the plain one goes at once.
		await tab.click(".drop");
		assert.deepEqual(await texts(".plain li"), ["b", "c", "n0"]);
		assert.deepEqual(await texts(".faded li"), ["a", "b", "c", "n0"]);
		assert.deepEqual(await texts(".faded li[inert]"), ["a"]);
		assert.equal(await tab.eval("document.querySelector('.faded li[inert]').getAttribute('aria-hidden')"), "true");
		assert.deepEqual(await playing(".faded li[inert]"), [1]);
		// Meanwhile the list goes on: a row dropped and one added go where they go, around it.
		await tab.click(".drop");
		await tab.click(".add");
		assert.deepEqual(await texts(".faded li:not([inert])"), ["c", "n0", "n1"]);
		assert.deepEqual(await texts(".faded li"), ["a", "b", "c", "n0", "n1"], "the rows going stay where they were");
		await tab.wait("document.querySelectorAll('.faded li').length === 3", 2000);
		assert.deepEqual(await texts(".faded li"), ["c", "n0", "n1"]);
		assert.deepEqual(await texts(".plain li"), ["c", "n0", "n1"]);

		// A part that goes stays until its transition is over, what is in it with it (its list's
		// rows don't play theirs: only the part's own play), while the fallback comes in.
		await tab.wait("document.querySelectorAll('.inner li').length === 3", 4000);
		await tab.click(".toggle");
		assert.equal(await tab.eval("document.querySelector('.panel').hasAttribute('inert')"), true);
		assert.deepEqual(await texts(".panel .inner li"), ["c", "n0", "n1"], "its rows stay with it");
		assert.deepEqual(await playing(".panel, .panel li"), [1, 0, 0, 0], "only the part's own transition plays");
		assert.deepEqual(await texts(".closed"), ["Closed"]);
		assert.deepEqual(await playing(".closed"), [1], "the fallback comes in");
		await tab.wait("document.querySelector('.panel') === null", 1000);

		// It comes back, playing its transition in; the fallback, with none out, goes at once.
		await tab.click(".toggle");
		assert.equal(await tab.eval("document.querySelector('.closed')"), null);
		assert.deepEqual(await playing(".panel"), [1]);
		assert.deepEqual(await texts(".panel .inner li"), ["c", "n0", "n1"]);

		// A computed transition: the one it says as the part goes is the one played.
		await tab.click(".quick");
		await tab.click(".toggle");
		assert.deepEqual(await tab.eval("(({ duration, direction }) => ({ duration, direction }))(document.querySelector('.panel').getAnimations().at(-1).effect.getTiming())"), { duration: 30, direction: "reverse" });
		await tab.wait("document.querySelector('.panel') === null", 1000);
		await tab.click(".toggle");
		await tab.wait("document.querySelector('.panel') !== null");

		// With less motion asked for, none plays: what goes, goes at once.
		await tab.wait("document.getAnimations().length === 0", 2000);
		await tab.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
		await tab.click(".add");
		assert.equal(await tab.eval("document.getAnimations().length"), 0);
		await tab.click(".drop");
		assert.deepEqual(await texts(".faded li"), ["n0", "n1", "n2"]);
		assert.deepEqual(await texts(".inner li"), ["n0", "n1", "n2"]);
		await tab.send("Emulation.setEmulatedMedia", { features: [] });

		// Coming and going again and again leaves nothing behind.
		await tab.wait("window.runtime.leaving.size === 0", 4000);
		const live = await tab.eval("window.runtime.live()");
		for (let i = 0; i < 3; i++) {
			await tab.click(".add");
			await tab.click(".drop");
			await tab.click(".toggle");
			await tab.wait("document.querySelector('.panel') === null", 1000);
			await tab.click(".toggle");
			await tab.wait("document.querySelector('.panel') !== null");
		}
		await tab.wait("document.querySelectorAll('[inert]').length === 0", 4000);
		// A row that went inside a part that went is let go of when its own transition would be over.
		await tab.wait("window.runtime.leaving.size === 0", 5000);
		assert.equal(await tab.eval("window.runtime.live()"), live, "the rows and parts that went, let go of");
		assert.deepEqual(tab.errors, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

test("effects: a handler calls the page's own function once it is done, the page patched; one the page hasn't is told; Audio.play! plays a file", { skip }, async () => {
	const wasm = readFileSync(join(out, "timers.wasm"));
	const dir = mkdtempSync(join(tmpdir(), "rocx-effects-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(join(dir, "timers.wasm"), wasm);
	// Each call notes what it was given, and what the page showed then.
	const page = `<!doctype html><html><body><div id="app"></div>
<script type="module">
import { Runtime } from "/runtime.js";
window.noted = [];
// What the browser is asked to play, instead of playing it.
window.played = [];
HTMLMediaElement.prototype.play = function () {
	window.played.push([new URL(this.src).pathname, this.volume, this.playbackRate, this.preservesPitch]);
	return Promise.resolve();
};
const effects = { noted: (arg) => window.noted.push([arg, document.querySelector(".notes").textContent]) };
window.runtime = await Runtime.load(fetch("/timers.wasm"), { effects });
window.runtime.mount(document.getElementById("app"));
window.mounted = true;
</script></body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? page : null));
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.mounted === true", 3000);
		await tab.click(".note");
		await tab.click(".note");
		await tab.wait("window.noted.length === 2");
		assert.deepEqual(await tab.eval("window.noted"), [[{ count: 1 }, "1"], [{ count: 2 }, "2"]], "given the argument, after the patch");
		await tab.click(".nowhere");
		await sleep(50);
		assert.ok(tab.console.some((entry) => entry.type === "error" && entry.text.includes("no effect is called nowhere")), "one the page hasn't, told on the console");
		// One the runtime wasn't given is looked for on window.rocxEffects.
		await tab.eval("window.rocxEffects = { nowhere: (arg) => (window.found = arg.why) }");
		await tab.click(".nowhere");
		await tab.wait("window.found === 'nothing has it'");
		// A sound file: the runtime's own, with nothing given to it.
		await tab.click(".play");
		await tab.wait("window.played.length === 1");
		assert.deepEqual(await tab.eval("window.played"), [["/beep.wav", 0.5, 2, false]], "the file, at its volume and rate, its pitch moving with it");
		assert.deepEqual(tab.errors, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

// ---- The echo: rendered on the server, hydrated in the browser ----

test("echo: rendered as the server would, from the GET it answered, and hydrated without asking again; typing asks the server", { skip }, async () => {
	const server = await Runtime.load(readFileSync(join(out, "echo-server.wasm")));
	const calls = [];
	const answerCall = async (method, path) => {
		const read = readOf(path);
		if (!read) return null;
		calls.push(read.name);
		await sleep(40);
		return readAnswer(read.name, read.arg);
	};
	assert.match(
		server.renderToString({ path: "/" }).html,
		/<!--errored:failed--><output class="echo-answer failed">599: GET \/api\/echo\/the%20page%2C%20rendered%20on%20the%20server wasn&#39;t answered as the server rendered the page /,
		"rendering as a server, a GET is answered only from the answers it is given: the runtime answers none itself",
	);
	const page = (mismatch = false) => {
		const { html, answers } = server.renderToString({ path: "/", answers: RENDERED });
		assert.deepEqual(answers, [RENDERED[2]], "recorded as the page has it");
		const markup = mismatch ? html.replace("<form", "<div></div><form") : html;
		return `<!doctype html><html><body><div id="app">${markup}${Runtime.answersScript(answers)}</div>
<script>window.output = document.querySelector("output"); window.input = document.querySelector("input");</script>
<script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/echo.wasm"));
window.runtime.hydrate(document.getElementById("app"));
window.hydrated = true;
</script></body></html>`;
	};
	const dir = mkdtempSync(join(tmpdir(), "rocx-echo-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	cpSync(join(out, "echo.wasm"), join(dir, "echo.wasm"));
	const site = await serve(dir, (path) => (path === "/" ? page() : path === "/mismatch" ? page(true) : null), answerCall);
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.hydrated === true", 3000);
		assert.equal(await tab.eval("document.querySelector('output').textContent"), "Echo: the page, rendered on the server");
		assert.deepEqual(calls, [], "the answer came with the page: no request");
		assert.equal(await tab.eval("window.output === document.querySelector('output') && window.input === document.querySelector('input')"), true, "hydrated: the server's nodes, kept");
		assert.equal(await tab.eval("document.querySelector('script.rocx-answers')"), null, "the answers are read, and gone");
		await tab.eval("document.querySelector('input').select()");
		await tab.type("input", "hello & <b>you</b>");
		await tab.wait("document.querySelector('output').textContent === 'Echo: hello & <b>you</b>'", 3000);
		assert.ok(calls.length >= 1 && calls.every((name) => name === "echo"), "typing asks the server");
		assert.equal(await tab.eval("window.output === document.querySelector('output')"), true, "the answer patched the server's node");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		// A page that isn't what the app renders: rendered again, and said so.
		const other = await browser.page();
		await other.goto(`${site.url}/mismatch`);
		await other.wait("window.hydrated === true", 3000);
		assert.equal(await other.eval("document.querySelector('output').textContent"), "Echo: the page, rendered on the server");
		assert.match(other.console.map((entry) => entry.text).join("\n"), /isn't what the app renders/);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

const textOf = (page, selector) => page.eval(`document.querySelector(${JSON.stringify(selector)})?.textContent ?? null`);

// ---- Endpoint reads (D-023): a page's data from a GET endpoint, carried in the page ----

/** What the server answered GET /api/reads?weeks=1 with as it rendered the reads page: noted under
 * the URL, as the server platform notes an endpoint's GET (`[name, input, answer]`). */
const READS_PAGE = [["GET /api/reads?weeks=1", "", JSON.stringify({ status: 200, body: JSON.stringify({ count: 1, weeks: "1" }) })]];

test("endpoint reads: rendered as the server would, from the GET it answered; hydrated strictly without asking again; its events make it read the endpoint's URL again", { skip }, async () => {
	const server = await Runtime.load(readFileSync(join(out, "reads-server.wasm")));
	assert.match(
		server.renderToString({ path: "/reads?weeks=1" }).html,
		/<p class="problem">599: GET \/api\/reads\?weeks=1 wasn&#39;t answered as the server rendered the page<\/p>/,
		"rendering as a server, a GET is answered only from the answers it is given",
	);
	const { html, answers } = server.renderToString({ path: "/reads?weeks=1", answers: READS_PAGE });
	assert.match(html, /<p class="data">count <!--x-->1<!--\/x-->, weeks <!--x-->1<!--\/x--><\/p>/, "the page's query in the GET");
	assert.deepEqual(answers, READS_PAGE, "noted once, as the page has it");
	let count = 1;
	const asked = [];
	const api = async (method, path, body, url, request) => {
		if (path === "/api/reads") {
			asked.push(`${method} ${url} ${request.headers.accept}`);
			await sleep(20);
			return json({ count, weeks: new URL(url, "http://x").searchParams.get("weeks") ?? "" });
		}
		if (path === "/api/changes") {
			asked.push(`${method} ${url}`);
			return {
				status: 200,
				headers: { "content-type": "text/event-stream" },
				stream: (response) => {
					count = 2;
					response.write('data: "changed"\n\n');
					setTimeout(() => response.end(), 50);
				},
			};
		}
		return null;
	};
	const page = (carried) => `<!doctype html><html><body><div id="app">${html}${Runtime.answersScript(carried)}</div>
<script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/reads.wasm"));
try {
	window.runtime.hydrate(document.getElementById("app"), { strict: true });
} catch (error) {
	window.problem = error.message;
}
window.hydrated = true;
</script></body></html>`;
	const dir = mkdtempSync(join(tmpdir(), "rocx-reads-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	cpSync(join(out, "reads.wasm"), join(dir, "reads.wasm"));
	const site = await serve(dir, (path) => (path === "/reads" ? page(READS_PAGE) : path === "/uncarried" ? page([]) : null), api);
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/reads?weeks=1`);
		await tab.wait("window.hydrated === true", 3000);
		assert.equal(await tab.eval("window.problem ?? null"), null, "strictly: nothing asked again");
		assert.equal(await textOf(tab, ".data"), "count 1, weeks 1");
		assert.deepEqual(asked, [], "the answer came with the page: no request");
		// Its events say it changed: refresh! reads the endpoint's own URL, for JSON.
		await tab.click("button");
		await tab.wait("document.querySelector('.data').textContent === 'count 2, weeks 1'", 3000);
		assert.deepEqual(asked, ["GET /api/changes", "GET /api/reads?weeks=1 application/json"]);
		assert.deepEqual(tab.errors, []);
		// A page that didn't carry the GET: hydrating asks again, and strict hydration says so.
		const other = await browser.page();
		await other.goto(`${site.url}/uncarried?weeks=1`);
		await other.wait("window.hydrated === true", 3000);
		assert.equal(await other.eval("window.problem ?? null"), "rocx: hydrating, the page asked the server again for GET /api/reads?weeks=1: the server didn't note it as it rendered the page");
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

// ---- is_pending!: Solid 2.0's isPending, a read revalidating with its old value shown ----

/** A slow endpoint for the pending page: `GET /api/slow?page=N` answers `{ page, version }` after
 * `delay` ms, `version` counting the answers; `fail` fails the next ones (500). Its <Upstream>'s,
 * `GET /api/flaky`, answers `{ n }`, `n` counting its answers, and fails the next `flaky.fail`. */
function slowApi() {
	const slow = { delay: 300, fail: 0, version: 0, asked: [], flaky: { fail: 0, n: 0, asked: 0 } };
	slow.api = async (method, path, body, url) => {
		if (path === "/api/flaky") {
			slow.flaky.asked++;
			await sleep(slow.delay);
			if (slow.flaky.fail > 0) {
				slow.flaky.fail--;
				return { status: 500, body: "the upstream is down" };
			}
			return json({ n: ++slow.flaky.n });
		}
		if (path !== "/api/slow") return null;
		slow.asked.push(`${method} ${url}`);
		await sleep(slow.delay);
		if (slow.fail > 0) {
			slow.fail--;
			return { status: 500, body: "the database is down" };
		}
		return json({ page: Number(new URL(url, "http://x").searchParams.get("page")), version: ++slow.version });
	};
	return slow;
}

/** The pending page's script: the runtime, its `pending` function noting each answer the effect's
 * compute got (`window.seen`), mounted or hydrated (strictly). */
const pendingScript = (how) => `<script type="module">
import { Runtime } from "/runtime.js";
window.seen = [];
window.runtime = await Runtime.load(fetch("/pending.wasm"), { effects: { pending: (answer) => window.seen.push(answer) } });
try {
	${how === "hydrate" ? 'window.runtime.hydrate(document.getElementById("app"), { strict: true });' : 'window.runtime.mount(document.getElementById("app"));'}
} catch (error) {
	window.problem = error.message;
}
window.started = true;
</script>`;

/** Clicks a button and reads the page on the next microtask: after the flush the click started. */
const clickThenRead = (selector, read) =>
	`(() => { document.querySelector(${JSON.stringify(selector)}).click(); return new Promise((resolve) => queueMicrotask(() => resolve(${read}))); })()`;

test("is_pending!: false on the first load (<Loading> shows); a refresh or a new page keeps the old answer, pending from that flush until the new one; a memo that reads it is pending too; a failed read is not, and <Errored> shows; its reader runs only when the answer changes", { skip }, async () => {
	const slow = slowApi();
	const dir = mkdtempSync(join(tmpdir(), "rocx-pending-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	cpSync(join(out, "pending.wasm"), join(dir, "pending.wasm"));
	writeFileSync(join(dir, "index.html"), `<!doctype html><html><body><div id="app"></div>${pendingScript("mount")}</body></html>`);
	const site = await serve(dir, () => null, slow.api);
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.started === true", 3000);
		const state = () =>
			tab.eval(`(() => {
				const q = (selector) => document.querySelector(selector);
				return { outside: q(".outside")?.textContent ?? null, loading: q(".loading")?.textContent ?? null, item: q(".item")?.textContent.trim() ?? null, stale: q(".item")?.classList.contains("stale") ?? null, label: q(".label")?.textContent ?? null, derived: q(".derived")?.textContent ?? null, problem: q(".problem")?.textContent.trim() ?? null };
			})()`);
		// 1. The first load: <Loading>'s fallback, and nothing pending (there is no value yet).
		assert.deepEqual(await state(), { outside: "settled", loading: "Loading…", item: null, stale: null, label: null, derived: null, problem: null });
		await tab.wait("document.querySelector('.item') !== null", 3000);
		assert.deepEqual(await state(), { outside: "settled", loading: null, item: "page 1, version 1", stale: false, label: "page 1, version 1", derived: "derived settled", problem: null });
		assert.deepEqual(await tab.eval("window.seen"), [false], "its value coming in changes no answer: the effect didn't run again");
		// 2. refresh!: pending from the flush the click started, the old answer still shown, and a
		// memo that reads it (4.) pending too.
		assert.equal(await tab.eval(clickThenRead(".refresh", "document.querySelector('.outside').textContent")), "pending", "in the click's flush");
		assert.deepEqual(await state(), { outside: "pending", loading: null, item: "page 1, version 1", stale: true, label: "page 1, version 1", derived: "derived pending", problem: null });
		await tab.wait("document.querySelector('.item').textContent.includes('version 2')", 3000);
		assert.deepEqual(await state(), { outside: "settled", loading: null, item: "page 1, version 2", stale: false, label: "page 1, version 2", derived: "derived settled", problem: null });
		assert.deepEqual(await tab.eval("window.seen"), [false, true, false]);
		// 3. A signal the read's URL depends on: the same, the old page shown until the new one is in.
		assert.equal(await tab.eval(clickThenRead(".next", "document.querySelector('.outside').textContent")), "pending");
		assert.deepEqual(await state(), { outside: "pending", loading: null, item: "page 1, version 2", stale: true, label: "page 1, version 2", derived: "derived pending", problem: null });
		await tab.wait("document.querySelector('.item').textContent.includes('page 2')", 3000);
		assert.deepEqual(await state(), { outside: "settled", loading: null, item: "page 2, version 3", stale: false, label: "page 2, version 3", derived: "derived settled", problem: null });
		// 6. The effect's compute ran once a change of answer, and only then.
		assert.deepEqual(await tab.eval("window.seen"), [false, true, false, true, false]);
		assert.deepEqual(slow.asked, ["GET /api/slow?page=1", "GET /api/slow?page=1", "GET /api/slow?page=2"]);
		// Refreshing again and again: the probes its readers keep go with the runs that made them.
		const kept = await tab.eval("window.runtime.kept.size");
		for (let i = 0; i < 3; i++) {
			await tab.click(".refresh");
			await tab.wait(`document.querySelector('.item').textContent.includes('version ${4 + i}')`, 3000);
			await tab.wait("document.querySelector('.outside').textContent === 'settled'", 3000);
		}
		assert.equal(await tab.eval("window.runtime.kept.size"), kept, "no probe kept beyond its run");
		// 5. A refresh that fails: pending until it does, then not, and <Errored> shows; trying again,
		// the old answer shows, pending, until the new one is in.
		slow.fail = 1;
		await tab.click(".refresh");
		await tab.wait("document.querySelector('.outside').textContent === 'pending'", 3000);
		await tab.wait("document.querySelector('.problem') !== null", 3000);
		assert.deepEqual(await state(), { outside: "settled", loading: null, item: null, stale: null, label: null, derived: null, problem: "GET /api/slow?page=2: 500: the database is down Again" });
		await tab.click(".again");
		await tab.wait("document.querySelector('.item') !== null", 3000);
		assert.deepEqual(await state(), { outside: "pending", loading: null, item: "page 2, version 6", stale: true, label: "page 2, version 6", derived: "derived pending", problem: null });
		await tab.wait("document.querySelector('.outside').textContent === 'settled'", 3000);
		assert.deepEqual(await state(), { outside: "settled", loading: null, item: "page 2, version 7", stale: false, label: "page 2, version 7", derived: "derived settled", problem: null });
		assert.deepEqual(await tab.eval("window.seen"), [false, ...Array(7).fill([true, false]).flat()], "a change of answer a run: two for each of the seven reads again");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a run that waits lets go of what it made: refreshes, new pages and memos made again and again, each run aborted until its read is in, leave no allocation behind", { skip }, async () => {
	const slow = slowApi();
	slow.delay = 20;
	const dir = mkdtempSync(join(tmpdir(), "rocx-aborts-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	cpSync(join(out, "pending.wasm"), join(dir, "pending.wasm"));
	writeFileSync(join(dir, "index.html"), `<!doctype html><html><body><div id="app"></div>${pendingScript("mount")}</body></html>`);
	const site = await serve(dir, () => null, slow.api);
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.started === true", 3000);
		await tab.wait("document.querySelector('.item') !== null", 3000);
		const live = () => tab.eval("window.runtime.live()");
		const aborts = () => tab.eval("window.runtime.stats.aborts");
		const before = await live();
		const aborted = await aborts();
		// The memo's run builds the read's URL, and aborts at the read: 30 times.
		for (let i = 0; i < 30; i++) {
			const version = slow.version;
			await tab.click(i % 3 === 0 ? ".next" : ".refresh");
			await tab.wait(`document.querySelector('.item').textContent.includes('version ${version + 1}')`, 3000);
			await tab.wait("document.querySelector('.outside').textContent === 'settled'", 3000);
		}
		// Made again each time it shows, its memos wait for their first values: the read's, and the
		// memo that reads that one's (`js_memo_get` aborts it), and its hole's.
		for (let i = 0; i < 10; i++) {
			await tab.click(".upstream-toggle");
			await tab.wait("document.querySelector('.doubled') !== null", 3000);
			await tab.click(".upstream-toggle");
			await tab.wait("document.querySelector('.upstream') === null", 3000);
		}
		assert.ok((await aborts()) - aborted >= 60, `runs aborted: ${(await aborts()) - aborted}`);
		assert.equal(await live(), before, "what the aborted runs had made, let go of");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

test("is_pending!: rendered as the server would, false; hydrated strictly, no mismatch and nothing asked; then a refresh is pending", { skip }, async () => {
	const server = await Runtime.load(readFileSync(join(out, "pending-server.wasm")));
	const rendered = [["GET /api/slow?page=1", "", JSON.stringify({ status: 200, body: JSON.stringify({ page: 1, version: 1 }) })]];
	const { html, answers } = server.renderToString({ path: "/", answers: rendered });
	assert.match(html, /<p class="outside"><!--x-->settled<!--\/x--><\/p>/);
	assert.match(html, /<p class="item">\s*page <!--x-->1<!--\/x-->, version <!--x-->1<!--\/x-->\s*<\/p>/, "no stale class");
	assert.match(html, /<p class="derived"><!--x-->derived settled<!--\/x--><\/p>/);
	assert.deepEqual(answers, rendered);
	const slow = slowApi();
	const dir = mkdtempSync(join(tmpdir(), "rocx-pending-hydrate-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	cpSync(join(out, "pending.wasm"), join(dir, "pending.wasm"));
	const page = `<!doctype html><html><body><div id="app">${html}${Runtime.answersScript(rendered)}</div>${pendingScript("hydrate")}</body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? page : null), slow.api);
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.started === true", 3000);
		assert.equal(await tab.eval("window.problem ?? null"), null, "strictly: no mismatch, nothing asked");
		assert.deepEqual(slow.asked, [], "the answer came with the page");
		assert.equal(await textOf(tab, ".outside"), "settled");
		assert.deepEqual(await tab.eval("window.seen"), [false]);
		await tab.click(".refresh");
		await tab.wait("document.querySelector('.item').classList.contains('stale')", 3000);
		assert.equal(await textOf(tab, ".outside"), "pending");
		await tab.wait("document.querySelector('.outside').textContent === 'settled'", 3000);
		assert.match(await textOf(tab, ".item"), /page 1, version 1/, "the slow API's own count: its first answer");
		assert.deepEqual(await tab.eval("window.seen"), [false, true, false]);
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

test("contexts: a context with no default, provided by nothing, fails, and <Errored> says why", { skip }, async () => {
	const wasm = readFileSync(join(out, "alone.wasm"));
	const runtime = await Runtime.load(wasm);
	const { html } = runtime.renderToString({ path: "/" });
	assert.match(html, /<!--errored:failed--><p class="problem">nothing above provides Picks\.picks_context: render this under its provider<\/p>/, "on the server; `{problem}` reads nothing that changes: static, no <!--x-->");
	// In the browser, from the component's body, where the tally asks for its store.
	const dir = mkdtempSync(join(tmpdir(), "rocx-alone-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(join(dir, "alone.wasm"), wasm);
	const page = `<!doctype html><html><body><div id="app"></div><script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/alone.wasm"));
window.runtime.mount(document.getElementById("app"));
</script></body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? page : null));
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("document.querySelector('.problem') !== null", 3000);
		assert.equal(await textOf(tab, ".problem"), "nothing above provides Picks.picks_context: render this under its provider");
		assert.equal(await tab.eval("document.querySelector('.tally')"), null, "and nothing of the tally");
		assert.deepEqual(tab.errors, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

// ---- A doctype and raw text: written as the file has them, adopted without comparing, built ----

test("raw text and a doctype: the server writes them as written; hydrating takes them without comparing; the browser builds them", { skip }, async () => {
	const wasm = readFileSync(join(out, "raw.wasm"));
	const server = await Runtime.load(wasm);
	const { html } = server.renderToString({ path: "/" });
	assert.equal(
		html,
		'<!--app--><!doctype html> <section class="raw plain" title="static" data-some="static"><style>.raw p > b { color: red }</style> <script>window.ran = (window.ran ?? 0) + 1</script> <p>A static hole and a <b><!--x-->hidden<!--/x--></b> one</p> <button class="more">More</button> <!--show--><!--/show--></section><!--/app-->',
		"raw text unescaped; static holes and attributes with no markers; a false class and an empty optional left out",
	);
	const dir = mkdtempSync(join(tmpdir(), "rocx-raw-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	writeFileSync(join(dir, "raw.wasm"), wasm);
	// The style's text tampered with: raw text isn't compared, so the server's stays.
	const hydrated = `<!doctype html><html><body><div id="app">${html.replace("color: red", "color: green")}</div>
<script>window.section = document.querySelector(".raw"); window.style = document.querySelector(".raw style").firstChild;</script>
<script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/raw.wasm"));
window.runtime.hydrate(document.getElementById("app"));
window.hydrated = true;
</script></body></html>`;
	const mounted = `<!doctype html><html><body><div id="app"></div><script type="module">
import { Runtime } from "/runtime.js";
window.runtime = await Runtime.load(fetch("/raw.wasm"));
window.runtime.mount(document.getElementById("app"));
window.mounted = true;
</script></body></html>`;
	const site = await serve(dir, (path) => (path === "/" ? hydrated : path === "/mount" ? mounted : null));
	try {
		const tab = await browser.page();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.hydrated === true", 3000);
		assert.deepEqual(tab.console, [], "hydrated without a mismatch: the doctype the parser dropped, and the style's text, not compared");
		assert.equal(await tab.eval("window.section === document.querySelector('.raw') && window.style === document.querySelector('.raw style').firstChild"), true, "the server's nodes, kept");
		assert.equal(await tab.eval("document.querySelector('.raw style').textContent"), ".raw p > b { color: green }");
		assert.equal(await tab.eval("window.ran"), 1, "the server's script ran once, as the page was read");
		await tab.click(".more");
		await tab.wait("document.querySelector('.raw b').textContent === 'computed'");
		assert.deepEqual(await tab.eval("[...document.querySelectorAll('.raw style')].map((style) => style.textContent)"), [".raw p > b { color: green }", ".later { color: blue }"], "raw text built");
		assert.equal(await tab.eval("document.querySelectorAll('.raw script')[1].textContent"), "window.later = 1");
		assert.equal(await tab.eval("window.later ?? null"), null, "a script the browser builds doesn't run, as in Solid");
		assert.deepEqual(tab.errors, []);
		// Built from nothing: the doctype is the document's (nothing here), the rest as the server's.
		const other = await browser.page();
		await other.goto(`${site.url}/mount`);
		await other.wait("window.mounted === true", 3000);
		assert.equal(
			await other.eval("document.getElementById('app').innerHTML"),
			'<!--app--> <section class="raw plain" title="static" data-some="static"><style>.raw p > b { color: red }</style> <script>window.ran = (window.ran ?? 0) + 1</script> <p>A static hole and a <b>hidden</b> one</p> <button class="more">More</button> <!--show--><!--/show--></section><!--/app-->',
			"the server's markup, but for the doctype and the text hole's comments",
		);
		assert.equal(await other.eval("window.ran ?? null"), null, "nor does one it mounts");
		assert.deepEqual(other.errors, []);
		assert.deepEqual(other.console, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

// ---- A whole document: rendered as the server platform answers a page, hydrated by start.js ----

/** What the document looks like rendered for `/inner/page?x=1`: as the server platform answers it. */
const DOCUMENT_PAGE =
	'<!doctype html> <html lang="en"><head><meta charset="utf-8"> <title>A document</title> <style>.count { color: red }</style> <script>window.ran = (window.ran ?? 0) + 1</script></head> <body class="page"><h1>A document</h1> <p class="at"><!--x-->/inner/page<!--/x--> ? <!--x-->x=1<!--/x--></p> <button class="count">Clicked <!--x-->0<!--/x--> times</button> <!--loading--><output class="said"><!--x-->Said: hello<!--/x--></output><!--/loading--> <button class="again">Again</button> <svg class="dot" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4"></circle></svg> ' +
	'<!--nohydration--><section class="prose"><aside class="aside"><h2>Unhydrated</h2> <p>Words the browser never hydrates.</p></aside> <p class="once">Rendered once: 0, Said: quiet</p></section><!--/nohydration-->' +
	`${Runtime.answersScript([RENDERED[0]])}<script type="module" data-rocx src="/rocx/start.js"></script></body></html>`;

test("a document: renderToString renders it whole, as the server platform answers a page", { skip }, async () => {
	const server = await Runtime.load(readFileSync(join(out, "document-server.wasm")));
	const { html, answers } = server.renderToString({ path: "/inner/page?x=1", answers: RENDERED });
	assert.equal(html, DOCUMENT_PAGE, "the doctype, <html>, holes' comments, and the answers and start.js before </body>; no <!--app-->; the <NoHydration> static, in its markers, with none inside");
	assert.deepEqual(answers, [RENDERED[0]], "what the <NoHydration> read isn't recorded: the browser never reads it");
	const start = '<script type="module" data-rocx src="/rocx/start.js"></script>';
	assert.equal(Runtime.documentOf("<html><body><p>hi</p></body></html>", []), `<!doctype html><html><body><p>hi</p><script type="application/json" class="rocx-answers">[]</script>${start}</body></html>`, "a doctype when the markup has none");
	assert.equal(Runtime.documentOf("<!DOCTYPE html><html>", []), `<!DOCTYPE html><html><script type="application/json" class="rocx-answers">[]</script>${start}`, "no </body>: at the end");
	const before = server.live();
	for (let i = 0; i < 20; i++) server.renderToString({ path: "/inner/page?x=1", answers: RENDERED });
	assert.equal(server.live(), before, "nothing left allocated");
});

test("a document: <NoHydration> is the server's alone: the browser's copy and wasm haven't what is inside, and render the same page from the server's answers and regions", { skip }, async () => {
	const copy = readFileSync(join(out, "app-client", "Document.roc"), "utf8");
	assert.doesNotMatch(copy, /^import Aside$/m, "the import only the region used is gone");
	assert.doesNotMatch(copy, /Aside\.view|Rendered once/);
	assert.match(copy, /Html\.no_hydration\(\[\n(\t*\n)*\t*\]\)/, "a placeholder in its place");
	assert.equal(readFileSync(join(out, "document.wasm")).includes("Words the browser never hydrates"), false, "nor in the browser's wasm");
	assert.equal(readFileSync(join(out, "document-server.wasm")).includes("Words the browser never hydrates"), true, "the server's has it");
	const browser = await Runtime.load(readFileSync(join(out, "document.wasm")));
	const answers = [RENDERED[0]];
	const path = "/inner/page?x=1";
	assert.equal(browser.renderToString({ path, answers }).html, DOCUMENT_PAGE.replace(/<!--nohydration-->.*<!--\/nohydration-->/, "<!--nohydration--><!--/nohydration-->"), "the browser's build leaves the placeholder");
	const { html, answers: recorded } = browser.renderToString({ path, answers, regions: Runtime.regionsOf(DOCUMENT_PAGE) });
	assert.equal(html, DOCUMENT_PAGE, "from the page's answers and regions, the page byte for byte");
	assert.deepEqual(recorded, answers, "each GET answered from the page's, recorded as it has it");
	assert.throws(() => browser.renderToString({ path, answers: [] }), /599: GET \/api\/say\/hello wasn't answered as the server rendered the page/, "a GET the server didn't make");
	assert.throws(() => browser.renderToString({ path, answers, regions: [] }), /the app renders more <NoHydration>s than the page has/);
	assert.throws(() => browser.renderToString({ path, answers, regions: ["a", "b"] }), /the page has 1 <NoHydration> more than the app renders/);
	assert.deepEqual(Runtime.regionsOf('<p><!--nohydration--><b>x</b><!--/nohydration--></p><!--nohydration--><!--/nohydration-->'), ["<b>x</b>", ""]);
	const before = browser.live();
	for (let i = 0; i < 20; i++) browser.renderToString({ path, answers, regions: Runtime.regionsOf(DOCUMENT_PAGE) });
	assert.equal(browser.live(), before, "nothing left allocated");
});

/** Before start.js (`[data-rocx]`, so hydrating passes over it): the server's nodes, noted, and
 * `rocx:ready` heard. */
const NOTE = `<script data-rocx>window.before = { h1: document.querySelector("h1"), at: document.querySelector(".at"), said: document.querySelector(".said"), title: document.querySelector("title"), style: document.querySelector("head style"), prose: document.querySelector(".prose"), once: document.querySelector(".once") }; document.addEventListener("rocx:ready", (event) => { window.ready = event.detail; });</script>`;

/** The document, as the server renders it for `target`, with NOTE before start.js, `after` after it
 * (where the dev reload script goes), and `tamper` applied. */
const documentPage = (render, target, { after = "", tamper = (html) => html } = {}) =>
	tamper(render(target).replace('<script type="module" data-rocx', `${NOTE}<script type="module" data-rocx`).replace("</body>", `${after}</body>`));

/**
 * The document app (or `app`): its server half renders pages (`pages`: path to page), from the
 * answers its reads got (`RENDERED`), and the browser's GETs are answered as the server answers
 * them (`readAnswer`); start.js, the runtime and the browser's wasm are files at
 * `${base}rocx/`, as an app's build would put them (start.js's URL in the page moved there, as the
 * static build does). Every URL asked for is noted. `api` may answer a request first (an
 * endpoint's), as serve's does.
 */
async function withDocument({ base = "/", pages, app = "document", api = () => null }, act) {
	const server = await Runtime.load(readFileSync(join(out, `${app}-server.wasm`)));
	const asked = [];
	const calls = [];
	const answerCall = async (method, path, body, url, request) => {
		asked.push(url);
		const answered = await api(method, path, body, url, request);
		if (answered) return answered;
		const read = readOf(path, base);
		if (!read) return null;
		calls.push(read.name);
		await sleep(30);
		return readAnswer(read.name, read.arg);
	};
	const dir = mkdtempSync(join(tmpdir(), "rocx-document-"));
	const files = join(dir, base, "rocx");
	mkdirSync(files, { recursive: true });
	cpSync(join(web, "start.js"), join(files, "start.js"));
	cpSync(join(web, "runtime.js"), join(files, "runtime.js"));
	cpSync(join(out, `${app}.wasm`), join(files, "app.wasm"));
	const render = (target, headers = []) => server.renderToString({ path: target, headers, answers: RENDERED }).html.replace('src="/rocx/start.js"', `src="${base}rocx/start.js"`);
	const site = await serve(dir, (path, request) => pages[path]?.(render, request) ?? null, answerCall);
	try {
		await act({ site, asked, calls, server });
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
}

/** A tab whose page sets `window.rocxStrict` before anything runs, as a strict test would. */
async function strictTab() {
	const tab = await browser.page();
	await tab.send("Page.enable");
	await tab.send("Page.addScriptToEvaluateOnNewDocument", { source: "window.rocxStrict = true" });
	return tab;
}

const warnings = (tab) => tab.console.filter((entry) => entry.type === "warning").map((entry) => entry.text);

test("a document: start.js hydrates it without asking, the server's nodes kept, the host's [data-rocx] elements passed over", { skip }, async () => {
	const reload = "<script data-rocx>window.reloads = true</script>";
	await withDocument(
		{
			pages: {
				"/inner/page": (render) => documentPage(render, "/inner/page?x=1", { after: reload }),
				"/unmarked": (render) => documentPage(render, "/unmarked", { after: "<script>window.reloads = true</script>" }),
			},
		},
		async ({ site, asked, calls }) => {
			for (const tab of [await browser.page(), await strictTab()]) {
				calls.length = 0;
				await tab.goto(`${site.url}/inner/page?x=1`);
				await tab.wait("window.ready", 3000);
				assert.deepEqual(tab.console, [], "hydrated without a mismatch, strictly too");
				assert.deepEqual(tab.errors, []);
				assert.deepEqual(calls, [], "the answer came with the page: no request");
				assert.equal(await tab.eval("Object.entries(window.before).every(([name, node]) => node.isConnected) && window.before.h1 === document.querySelector('h1') && window.before.said === document.querySelector('.said') && window.before.title === document.querySelector('title')"), true, "the server's nodes, kept");
				assert.equal(await tab.eval("document.querySelector('script.rocx-answers')"), null, "the answers are read, and gone");
				assert.equal(await tab.eval("window.ran"), 1, "<head>'s script ran once, as the page was read");
				assert.equal(await tab.eval("window.reloads && document.querySelectorAll('body > script[data-rocx]').length"), 3, "the host's scripts stay where they are");
				assert.equal(await tab.eval("typeof window.ready.ms === 'number' && window.ready.runtime.stats.patches"), 0, "rocx:ready carries the runtime; nothing needed patching");
				assert.equal(await tab.eval("window.before.prose === document.querySelector('.prose') && document.querySelector('.once').textContent"), "Rendered once: 0, Said: quiet", "the <NoHydration>: the server's nodes, as it sent them");
				await tab.click(".count");
				await tab.wait("document.querySelector('.count').textContent === 'Clicked 1 times'");
				assert.equal(await tab.eval("document.querySelector('.once').textContent"), "Rendered once: 0, Said: quiet", "never patched: the browser never ran it");
				await tab.click(".again");
				await tab.wait("document.querySelector('.said').textContent === 'Said: again'", 3000);
				assert.deepEqual(calls, ["say"], "a new word asks the server");
				assert.equal(await tab.eval("window.before.said === document.querySelector('.said')"), true, "the answer patched the server's node");
				assert.deepEqual(tab.errors, []);
			}
			assert.ok(asked.includes("/rocx/start.js") && asked.includes("/rocx/runtime.js") && asked.includes("/rocx/app.wasm"), asked.join(", "));
			// The same script, not marked as the host's: the app doesn't render it, so it is a mismatch.
			const other = await browser.page();
			await other.goto(`${site.url}/unmarked`);
			await other.wait("window.ready", 3000);
			assert.deepEqual(warnings(other), ["rocx: the page isn't what the app renders (<body> has more than the server's markup says); rendering <body> again"]);
		},
	);
});

test("a document: one that isn't what the app renders is rendered again, <body> only, with a warning; strictly, it throws", { skip }, async () => {
	const extension = (html) => html.replace("<h1>", '<div class="extension"></div><h1>');
	const inHead = (html) => html.replace("</head>", '<style class="extension"></style></head>');
	await withDocument(
		{
			pages: {
				"/": (render) => documentPage(render, "/"),
				"/tampered": (render) => documentPage(render, "/tampered", { tamper: extension }),
				"/head": (render) => documentPage(render, "/head", { tamper: inHead }),
			},
		},
		async ({ site, calls }) => {
			const clean = await browser.page();
			await clean.goto(`${site.url}/`);
			await clean.wait("window.ready", 3000);
			const live = await clean.eval("window.ready.runtime.live()");
			const tab = await browser.page();
			await tab.goto(`${site.url}/tampered`);
			await tab.wait("window.ready", 3000);
			assert.deepEqual(warnings(tab), ["rocx: the page isn't what the app renders (expected <h1>, found DIV); rendering <body> again"]);
			assert.deepEqual(tab.errors, []);
			assert.equal(await tab.eval("document.querySelector('.extension')"), null, "<body> is the app's again");
			assert.equal(await tab.eval("window.before.h1.isConnected || window.before.h1 === document.querySelector('h1')"), false, "rendered anew");
			assert.equal(await tab.eval("window.before.prose === document.querySelector('.prose') && window.before.once === document.querySelector('.once') && document.querySelector('.prose').previousSibling.data"), "nohydration", "but the <NoHydration> is the server's, its nodes kept, in their markers");
			assert.equal(await tab.eval("document.querySelectorAll('.prose').length + document.querySelectorAll('.aside').length"), 2, "once");
			assert.equal(await tab.eval("window.before.title === document.querySelector('title') && window.before.style === document.querySelector('head style')"), true, "<head> is left alone");
			assert.equal(await tab.eval("window.ran"), 1, "and its script didn't run again");
			assert.equal(await tab.eval("document.querySelectorAll('body > script[data-rocx]').length"), 2, "the host's scripts stay");
			assert.equal(await tab.eval("document.querySelector('.said').textContent"), "Said: hello");
			assert.deepEqual(calls, [], "rendered again from the server's answers");
			assert.equal(await tab.eval("document.querySelector('.at').textContent"), "/tampered ? ");
			assert.equal(await tab.eval("document.querySelector('circle').namespaceURI"), "http://www.w3.org/2000/svg", "made inside an <svg>: in its namespace");
			assert.equal(await tab.eval("window.ready.runtime.live()"), live, "what the first try made is let go of");
			await tab.click(".count");
			await tab.wait("document.querySelector('.count').textContent === 'Clicked 1 times'");
			// An extension's node in <head>: <body> rendered again, and <head> stays as it is.
			const head = await browser.page();
			await head.goto(`${site.url}/head`);
			await head.wait("window.ready", 3000);
			assert.deepEqual(warnings(head), [
				"rocx: the page isn't what the app renders (<head> has more than the server's markup says); rendering <body> again",
				"rocx: <head> isn't what the app renders either (<head> has more than the server's markup says); it stays as the server sent it",
			]);
			assert.equal(await head.eval("Boolean(document.querySelector('head .extension')) && window.before.title === document.querySelector('title') && window.ran"), 1, "<head> left alone");
			await head.click(".count");
			await head.wait("document.querySelector('.count').textContent === 'Clicked 1 times'");
			assert.deepEqual(head.errors, []);
			// Strictly, the same tampering throws, and nothing is rendered again.
			const strict = await strictTab();
			await strict.goto(`${site.url}/tampered`);
			for (let i = 0; i < 100 && !strict.errors.length; i++) await sleep(30);
			assert.equal(strict.errors.length, 1);
			assert.match(strict.errors[0], /rocx: the page isn't what the app renders \(expected <h1>, found DIV\)/);
			assert.deepEqual(warnings(strict), []);
			assert.equal(await strict.eval("Boolean(document.querySelector('.extension')) && window.before.h1 === document.querySelector('h1') && (window.ready ?? null)"), null, "nothing rendered again; not ready");
		},
	);
});

test("a document under a base path: start.js fetches nothing outside it, and Router.location! takes the base off", { skip }, async () => {
	await withDocument({ base: "/rocx/", pages: { "/rocx/inner/page": (render) => documentPage(render, "/inner/page?x=1") } }, async ({ site, asked, calls }) => {
		const tab = await strictTab();
		await tab.goto(`${site.url}/rocx/inner/page?x=1`);
		await tab.wait("window.ready", 3000);
		assert.deepEqual(tab.console, []);
		assert.deepEqual(tab.errors, []);
		assert.equal(await tab.eval("document.querySelector('.at').textContent"), "/inner/page ? x=1", "where the page is, as the server saw it");
		assert.equal(await tab.eval("window.ready.runtime.stats.patches"), 0, "the browser agrees: nothing patched");
		const located = await tab.eval(`(() => {
			const runtime = window.ready.runtime;
			const at = (path) => (history.replaceState(null, "", path), runtime.location());
			return [at("/rocx/a/b/?q=1"), at("/rocx/"), at("/rocx"), at("/rocxy/z"), at("/rocx/inner/page?x=1")];
		})()`);
		assert.deepEqual(located, ["/a/b?q=1", "/", "/", "/rocxy/z", "/inner/page?x=1"]);
		await tab.click(".again");
		await tab.wait("document.querySelector('.said').textContent === 'Said: again'", 3000);
		assert.deepEqual(calls, ["say"]);
		assert.deepEqual([...asked].sort(), ["/rocx/api/say/again", "/rocx/inner/page?x=1", "/rocx/rocx/app.wasm", "/rocx/rocx/runtime.js", "/rocx/rocx/start.js"], "everything under /rocx/");
		assert.deepEqual(tab.errors, []);
	});
});

test("a document inside an <Errored>, as a generated root renders it: the host's doctype before the boundary's comment is passed over", { skip }, async () => {
	await withDocument({ app: "wrapped", pages: { "/": (render) => documentPage(render, "/") } }, async ({ site, calls }) => {
		const server = await Runtime.load(readFileSync(join(out, "wrapped-server.wasm")));
		const { html } = server.renderToString({ path: "/", answers: RENDERED });
		assert.ok(html.startsWith('<!doctype html><!--errored--><!doctype html> <html lang="en">') && html.endsWith("</html><!--/errored-->"), html);
		const tab = await strictTab();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.ready", 3000);
		assert.deepEqual(tab.console, []);
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(await tab.eval("[...document.childNodes].map((node) => node.nodeName)"), ["html", "#comment", "HTML", "#comment"], "the doctype, the boundary's comments around <html>");
		assert.equal(await tab.eval("window.before.h1 === document.querySelector('h1') && window.before.said === document.querySelector('.said')"), true, "the server's nodes, kept");
		await tab.click(".again");
		await tab.wait("document.querySelector('.said').textContent === 'Said: again'", 3000);
		assert.deepEqual(calls, ["say"]);
	});
});

// ---- The docs' demos: one document, its parts far apart, sharing a store through a context ----

test("the docs' demos: one document, its parts far apart, hydrated strictly at once without asking; the picks and the tally share a store through a context; rendering it again and again leaves nothing allocated", { skip }, async () => {
	// Before start.js runs (module scripts wait for the page): the server's nodes, noted.
	const note = '<script data-rocx>window.first = [...document.querySelectorAll(".keyed li")]; window.output = document.querySelector("output"); window.count = document.querySelector(".tally-count");</script>';
	await withDocument({ app: "docs", pages: { "/": (render) => documentPage(render, "/", { after: note }) } }, async ({ site, server, calls }) => {
		const { html, answers } = server.renderToString({ path: "/", answers: RENDERED });
		assert.match(html, /<section class="part-tally"><h2>tally<\/h2><p>Static text between the demos\.<\/p><aside class="tally"><p class="tally-count"><!--x-->3<!--\/x--> picks<\/p>/, "the tally, from the store the page made");
		assert.match(html, /<section class="part-picks">.*<!--x-->Roc<!--\/x-->/);
		assert.deepEqual(answers.map(([name]) => name), [readKey("echo", "the page, rendered on the server")], "one page's answers, for every part");
		const tab = await strictTab();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.ready", 3000);
		assert.deepEqual(tab.console, [], "every part hydrated without a mismatch, strictly");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(calls, [], "the echo's answer came with the page");
		assert.equal(await tab.eval("window.first.length === 3 && window.first.every((row, i) => row === document.querySelectorAll('.keyed li')[i]) && window.output === document.querySelector('output') && window.count === document.querySelector('.tally-count')"), true, "the server's nodes, kept, in every part");
		assert.equal(await tab.eval("document.querySelectorAll('.part-tally p').length"), 3, "the static text around a part is the page's");
		// The tally adds a pick: the picks, far away, show it, from the same store.
		await tab.click(".tally-add");
		await tab.wait("document.querySelectorAll('.keyed li').length === 4");
		assert.equal(await textOf(tab, ".keyed li:last-child"), "3: Zig");
		assert.equal(await textOf(tab, ".tally-count"), "4 picks");
		assert.equal(await textOf(tab, ".picks .many"), "More than three");
		// The picks clear: the tally says so.
		await tab.click(".clear");
		await tab.wait("document.querySelector('.tally-count').textContent === '0 picks'");
		assert.equal(await textOf(tab, ".tally-names"), "none yet");
		// And the echo, a third part, still asks its server.
		await tab.eval("document.querySelector('input').select()");
		await tab.type("input", "one app");
		await tab.wait("document.querySelector('output').textContent === 'Echo: one app'", 3000);
		assert.ok(calls.length > 0 && calls.every((name) => name === "echo"));
		assert.deepEqual(tab.errors, []);
		const before = server.live();
		for (let i = 0; i < 50; i++) server.renderToString({ path: "/", answers: RENDERED });
		assert.equal(server.live(), before, "every render's signals, contexts and computations, let go of");
	});
});

// ---- Effects, cleanups and timers ----

/** Polls `check` until it holds, or fails after `ms`. */
async function until(check, ms = 3000, what = String(check)) {
	for (const end = Date.now() + ms; Date.now() < end; await sleep(20)) if (await check()) return;
	throw new Error(`timed out waiting for ${what}`);
}

test("titles: the last <Title> rendered that is still there is the title, put first in <head> by the server, kept by the browser from hydration on, strictly; with none, the layout's own", { skip }, async () => {
	await withDocument({ app: "titles", pages: { "/": (render) => documentPage(render, "/") } }, async ({ site, server }) => {
		const { html } = server.renderToString({ path: "/" });
		assert.match(html, /<head><meta charset="utf-8"> <title data-rocx>Inner 1<\/title><title>The layout&#39;s<\/title><\/head>/, "the last one rendered, first in <head>, the layout's after it");
		assert.match(html, /<!--show--><!--x--><!--\/x--><!--\/show-->.*<p class="inner"><!--x--><!--\/x-->inner<\/p>/s, "where each is, a hole that renders nothing");
		const before = server.live();
		for (let i = 0; i < 10; i++) server.renderToString({ path: "/" });
		assert.equal(server.live(), before, "rendering them again leaves nothing allocated");
		const tab = await strictTab();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.ready", 3000);
		assert.deepEqual(tab.console, [], "hydrated strictly, the <head> as the server rendered it");
		assert.deepEqual(tab.errors, []);
		const title = () => tab.eval("[document.title, [...document.head.querySelectorAll('title')].map((t) => (t.hasAttribute('data-rocx') ? '*' : '') + t.textContent)]");
		await sleep(50);
		assert.deepEqual(await title(), ["Inner 1", ["*Inner 1", "The layout's"]]);
		assert.equal(await tab.eval("window.ready.runtime.stats.patches"), 0, "hydrating patched nothing");
		await tab.click(".more");
		await tab.wait("document.title === 'Inner 2'");
		await tab.click(".toggle-inner");
		await tab.wait("document.title === '2 & counting'");
		assert.deepEqual(await title(), ["2 & counting", ["*2 & counting", "The layout's"]], "the inner one gone, the one before it");
		await tab.click(".toggle-outer");
		await tab.wait("document.title === \"The layout's\"");
		assert.deepEqual(await title(), ["The layout's", ["The layout's"]], "none: the layout's own, the platform's <title> gone");
		await tab.click(".toggle-inner");
		await tab.wait("document.title === 'Inner 2'");
		await tab.click(".toggle-outer");
		await tab.click(".more");
		await tab.wait("document.title === '3 & counting'");
		assert.deepEqual(await title(), ["3 & counting", ["*3 & counting", "The layout's"]], "the outer one, shown again after the inner, is the last rendered");
		assert.deepEqual(tab.console, []);
	});
});

test("effects: one runs once the page is hydrated, and again on a change, after its cleanup; none runs on the server; a page's function its apply calls runs after the patch. A timer counts until its component goes; one an effect's apply starts stops on the effect's cleanup, and when its component goes; a listen started in an effect stops with it", { skip }, async () => {
	const live = { open: 0, closed: 0 };
	// `/live`: an event every 25 ms, until the browser goes.
	const api = (method, path) =>
		path !== "/live"
			? null
			: {
					status: 200,
					headers: { "content-type": "text/event-stream", "cache-control": "no-cache" },
					stream: (response, request) => {
						live.open++;
						let sent = 0;
						const timer = setInterval(() => response.write(`data: ${sent++}\n\n`), 25);
						response.on("close", () => {
							clearInterval(timer);
							live.closed++;
						});
					},
				};
	// What is patched, noted in the page from `rocx:ready` on: how many patches hydrating made, read
	// as start.js tells the page it is done (the effect's first flush is a microtask later), then the
	// element of each patch after it (its class, or its tag). The ticker's interval patches `.mine`
	// and `.ticks` every 20 ms from hydrating on, and the tab is polled every 25 ms, so a count read
	// after polling would race it.
	const noting = `<script data-rocx>document.addEventListener("rocx:ready", ({ detail: { runtime } }) => { window.hydrating = runtime.stats.patches; window.patched = []; runtime.observer = { patch: ({ node }) => { const at = node.nodeType === 1 ? node : node.parentElement; window.patched.push(at?.className || at?.localName || node.nodeName); } }; });</script>`;
	await withDocument({ app: "effects", api, pages: { "/": (render) => documentPage(render, "/", { after: noting }) } }, async ({ site, server }) => {
		const { html } = server.renderToString({ path: "/" });
		assert.match(html, /<title>0 effects<\/title>/, "a hole in <title>, RCDATA, without comments, which would show");
		assert.match(html, /<p class="log"><!--x--><!--\/x--><\/p>/, "on the server, no effect runs");
		assert.match(html, /<p class="ticks"><!--x-->0<!--\/x--><\/p>.*<p class="mine"><!--x-->0<!--\/x--><\/p>/s, "and no timer starts");
		const before = server.live();
		for (let i = 0; i < 10; i++) server.renderToString({ path: "/" });
		assert.equal(server.live(), before, "what they would have run is let go of");
		const tab = await strictTab();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.ready", 3000);
		assert.deepEqual(tab.console, [], "hydrated strictly: the server's log, empty, is what the browser rendered too");
		assert.deepEqual(tab.errors, []);
		await tab.wait("document.querySelector('.log').textContent === 'ran 0'");
		assert.equal(await tab.eval("document.title"), "0 effects", "the title's hole bound to its text, strictly");
		// Read at once, so no tick comes between them.
		const { hydrating, patched, patches } = await tab.eval("({ hydrating: window.hydrating, patched: window.patched, patches: window.ready.runtime.stats.patches })");
		assert.equal(hydrating, 0, "nothing patched in hydrating (the title neither)");
		assert.equal(patched[0], "log", "the first patch is the effect's write to the log: its apply runs in the flush right after hydrating, before any timer can fire");
		assert.deepEqual(patched.filter((at) => at !== "mine" && at !== "ticks"), ["log"], "and the only one but the ticker's timer's");
		assert.equal(patches, hydrating + patched.length, "every patch was noted");
		await tab.eval("window.ready.runtime.observer = null");
		// The page's `seen`, which the effect's apply calls (Browser.call!): it notes what the page shows then.
		await tab.eval("window.seen = []; window.rocxEffects = { seen: ({ count }) => window.seen.push([count, document.querySelector('.log').textContent, document.title]) }");
		await tab.click(".more");
		await tab.wait("document.querySelector('.log').textContent === 'ran 0, cleaned 0, ran 1'");
		assert.equal(await tab.eval("document.title"), "1 effects", "and patched");
		await tab.click(".more");
		await tab.wait("document.querySelector('.log').textContent === 'ran 0, cleaned 0, ran 1, cleaned 1, ran 2'");
		await tab.wait("window.seen.length === 2");
		assert.deepEqual(
			await tab.eval("window.seen"),
			[
				[1, "ran 0, cleaned 0, ran 1", "1 effects"],
				[2, "ran 0, cleaned 0, ran 1, cleaned 1, ran 2", "2 effects"],
			],
			"a Browser.call! in an effect's apply runs once, after the page is patched with what the apply wrote",
		);
		// The ticker's timer counts, in its own text and its parent's; its effect listens.
		await tab.wait("Number(document.querySelector('.mine').textContent) >= 3 && Number(document.querySelector('.ticks').textContent) >= 3", 3000);
		await tab.wait("Number(document.querySelector('.heard').textContent) >= 2", 3000);
		assert.equal(live.open, 1);
		assert.equal(await tab.eval("window.ready.runtime.timers.size"), 1);
		// Pacing: the ticker's effect starts an interval in its apply, never cleared by Roc.
		await tab.click(".pace");
		await tab.wait("Number(document.querySelector('.beats').textContent) >= 3", 3000);
		assert.equal(await tab.eval("window.ready.runtime.timers.size"), 2);
		// Not pacing: the effect runs again, and its last apply's cleanups stop that interval.
		await tab.click(".pace");
		await tab.wait("window.ready.runtime.timers.size === 1", 3000);
		const beaten = await textOf(tab, ".beats");
		await sleep(150);
		assert.equal(await textOf(tab, ".beats"), beaten, "the effect's interval runs no more");
		// Pacing again, then hidden: the ticker goes, its cleanup runs, both its timers stop (its
		// own, and its effect's), its listen stops.
		await tab.click(".pace");
		await tab.wait(`Number(document.querySelector('.beats').textContent) > ${Number(beaten) + 2}`, 3000);
		assert.equal(await tab.eval("window.ready.runtime.timers.size"), 2);
		await tab.click(".toggle");
		await tab.wait("document.querySelector('.mine') === null");
		assert.equal(await textOf(tab, ".log"), "ran 0, cleaned 0, ran 1, cleaned 1, ran 2, ticker gone");
		assert.equal(await tab.eval("window.ready.runtime.timers.size"), 0, "its timers are cleared");
		await until(() => live.closed === 1, 3000, "the stream's request to be aborted");
		const [ticks, heard, beats] = [await textOf(tab, ".ticks"), await textOf(tab, ".heard"), await textOf(tab, ".beats")];
		await sleep(150);
		assert.equal(await textOf(tab, ".ticks"), ticks, "its timer runs no more");
		assert.equal(await textOf(tab, ".beats"), beats, "nor does its effect's");
		assert.equal(await textOf(tab, ".heard"), heard, "nor does its listen's handler");
		// Shown again: a new ticker, new timers (pacing still), a new listen.
		await tab.click(".toggle");
		await tab.wait(`Number(document.querySelector('.ticks').textContent) > ${ticks} && Number(document.querySelector('.heard').textContent) > ${heard} && Number(document.querySelector('.beats').textContent) > ${beats}`, 3000);
		assert.equal(live.open, 2);
		assert.equal(await tab.eval("window.ready.runtime.timers.size"), 2);
		assert.equal(await textOf(tab, ".log"), "ran 0, cleaned 0, ran 1, cleaned 1, ran 2, ticker gone", "the effect above it didn't run again");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	});
});

// ---- Form actions ----

test("forms: after a plain post, the flash is the submission: what was typed and the refusal, rendered on the server and hydrated as they are; with the runtime, the form is sent with fetch, pending until its refusal or its result, the page kept; a redirect of the endpoint's own is followed", { skip }, async () => {
	const posted = [];
	let release = null;
	const api = async (method, path, body, url, request) => {
		if (path !== "/join") return null;
		posted.push({ method, body, headers: request.headers });
		const name = new URLSearchParams(body).get("name") ?? "";
		if (name === "Slow") await new Promise((resolve) => (release = resolve));
		if (name === "Go") return { status: 200, headers: { "x-rocx-redirect": "/next" }, body: "" };
		if (name === "Al") return { status: 409, body: "Al is taken" };
		return { status: 200, headers: { "content-type": "application/json" }, body: JSON.stringify(`Welcome, ${name}`) };
	};
	const flash = encodeURIComponent(JSON.stringify({ url: "/join", input: "name=Al", status: 409, body: "Al is taken" }));
	const pages = {
		"/": (render) => documentPage(render, "/"),
		"/flashed": (render) => documentPage((target) => render(target, [["cookie", `rocx-flash=${flash}`]]), "/flashed"),
		"/next": () => '<!doctype html><html><body><p class="next">Next</p></body></html>',
	};
	await withDocument({ app: "form", api, pages }, async ({ site }) => {
		// After a plain post: the page the endpoint sent the browser back to, its flash in the cookie.
		const tab = await strictTab();
		await tab.goto(`${site.url}/flashed`);
		await tab.wait("window.ready", 3000);
		assert.deepEqual(tab.console, [], "hydrated strictly: the browser renders the flash the server did");
		assert.deepEqual(tab.errors, []);
		assert.equal(await textOf(tab, ".problem"), "Al is taken");
		assert.equal(await textOf(tab, ".typed"), "typed Al");
		assert.equal(await tab.eval("document.querySelector('input').value"), "Al", "what was typed, back in its field");
		assert.equal(await tab.eval("document.querySelector('script.rocx-flash')"), null, "the flash is read, and gone");
		assert.equal(await tab.eval("window.ready.runtime.stats.patches"), 0);
		await tab.eval("window.stayed = true; document.querySelector('input').value = ''");
		// With the runtime: sent with fetch, and the page stays.
		await tab.type("input", "Ada");
		await tab.click("button[type=submit]");
		await tab.wait("document.querySelector('.welcome')?.textContent === 'Welcome, Ada'", 3000);
		assert.equal(await textOf(tab, ".problem"), null, "the flash's refusal gives way to the runtime's submission");
		assert.equal(await textOf(tab, ".typed"), "typed Ada");
		const sent = posted.at(-1);
		assert.equal(sent.body, "name=Ada");
		assert.equal(sent.headers["content-type"], "application/x-www-form-urlencoded");
		assert.equal(sent.headers.accept, "application/json");
		assert.equal(sent.headers["x-rocx-submission"], "1");
		assert.equal(await tab.eval("window.stayed"), true, "no page was loaded");
		// Pending, until the answer is in.
		await tab.eval("document.querySelector('input').value = ''");
		await tab.type("input", "Slow");
		await tab.click("button[type=submit]");
		await tab.wait("document.querySelector('button[type=submit]').textContent === 'Joining…'", 3000);
		assert.equal(await tab.eval("document.querySelector('button[type=submit]').disabled"), true);
		assert.equal(await textOf(tab, ".typed"), "typed Slow", "what is on its way");
		assert.equal(await textOf(tab, ".welcome"), null, "the last result is the last submission's, which is pending");
		await until(() => release !== null);
		release();
		await tab.wait("document.querySelector('.welcome')?.textContent === 'Welcome, Slow'", 3000);
		assert.equal(await tab.eval("document.querySelector('button[type=submit]').textContent + ' ' + document.querySelector('button[type=submit]').disabled"), "Join false");
		// A refusal, sent with fetch.
		await tab.eval("document.querySelector('input').value = ''");
		await tab.type("input", "Al");
		await tab.click("button[type=submit]");
		await tab.wait("document.querySelector('.problem')?.textContent === 'Al is taken'", 3000);
		assert.equal(await textOf(tab, ".welcome"), null);
		assert.equal(await tab.eval("window.stayed"), true);
		// Cleared (a handler): no submission, and no flash either.
		await tab.click(".clear");
		await tab.wait("document.querySelector('.problem') === null");
		assert.equal(await textOf(tab, ".typed"), "nothing typed");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		// A redirect of the endpoint's own (as `Endpoint.respond!` gives the runtime one) is followed.
		await tab.eval("document.querySelector('input').value = ''");
		await tab.type("input", "Go");
		await tab.click("button[type=submit]");
		await tab.wait("location.pathname === '/next' && document.querySelector('.next') !== null", 3000);
		// A page with no flash shows no submission; a form a handler takes isn't the runtime's.
		const fresh = await strictTab();
		await fresh.goto(`${site.url}/`);
		await fresh.wait("window.ready", 3000);
		assert.equal(await textOf(fresh, ".typed"), "nothing typed");
		assert.equal(await textOf(fresh, ".problem"), null);
		const count = posted.length;
		await fresh.eval("document.querySelector('form').addEventListener('submit', (event) => event.preventDefault())");
		await fresh.click("button[type=submit]");
		await sleep(100);
		assert.equal(posted.length, count, "a submit a handler prevented is left alone");
		assert.deepEqual(fresh.errors, []);
	});
});

// ---- Drag and drop (D-029), actions and optimistic values (D-030), moves (D-031) ----

test("a planner: a card dragged to another day (a real drag, in Chromium) moves at once, before the slow endpoint answers, and stays while it is on its way and while the board is read again (is_pending! then), then is the server's, never showing where it was; two on their way at once, each on its own, the refused one back where it was, its refusal readable; cards glide between days (none with less motion asked for); a list with no drop handler takes no drop; a link's click taken over; hydrated strictly, rendered by the browser's build byte for byte, nothing left allocated", { skip }, async () => {
	const server = await Runtime.load(readFileSync(join(out, "planner-server.wasm")));
	/** The server's board: a day holds two cards at most. */
	let board = [
		{ id: "a", title: "Alpha", day: "mon" },
		{ id: "b", title: "Beta", day: "mon" },
		{ id: "c", title: "Gamma", day: "tue" },
		{ id: "d", title: "Delta", day: "wed" },
	];
	const answered = (cards) => [["GET /api/board", "", JSON.stringify(json(cards))]];
	const { html } = server.renderToString({ path: "/", answers: answered(board) });
	assert.match(html, /<li class="card" draggable="true"><!--x-->Alpha<!--\/x--><\/li>/, "the server writes nothing for a handler, a key or a move");
	const client = await Runtime.load(readFileSync(join(out, "planner.wasm")));
	assert.equal(client.renderToString({ path: "/", answers: answered(board) }).html, html, "the browser's build renders the page byte for byte: nothing optimistic on the server");
	// The scripted server: each move waits until the test lets it be answered (`release`), and is
	// refused if its day is full; a read of the board may be held too (`holding`).
	const posted = [];
	const reads = [];
	let holding = null;
	const api = async (method, path, body, url, request) => {
		if (path === "/api/board") {
			const read = { at: posted.length };
			reads.push(read);
			if (holding) await holding;
			return json(board);
		}
		if (path !== "/api/move") return null;
		const move = { body: JSON.parse(body), headers: request.headers, answered: false };
		posted.push(move);
		await new Promise((resolve) => (move.release = resolve));
		move.answered = true;
		const { card, day } = move.body;
		if (board.filter((each) => each.day === day && each.id !== card).length >= 2) return { status: 409, body: `${day} is full` };
		board = board.map((each) => (each.id === card ? { ...each, day } : each));
		return json("moved");
	};
	const page = `<!doctype html><html><head><style>.days { display: flex; gap: 24px } .day { width: 160px; min-height: 120px; margin: 0; padding: 8px; list-style: none } .card { height: 24px; margin: 4px 0 } .tray { min-height: 40px }</style></head><body><div id="app">${html}${Runtime.answersScript(answered(board))}</div>
<script type="module">
import { Runtime } from "/runtime.js";
// What each day shows, each time the page changes: an old value showing again would be in it.
window.seen = [];
const days = () => [...document.querySelectorAll(".day")].map((day) => day.dataset.day + ":" + [...day.querySelectorAll(".card:not([inert])")].map((card) => card.textContent).join(",")).join(" ");
new MutationObserver(() => { const now = days(); if (window.seen.at(-1) !== now) window.seen.push(now); }).observe(document.getElementById("app"), { subtree: true, childList: true, characterData: true });
// Where the drag is, as the page's own listener sees it after the runtime's: accepted or not.
document.addEventListener("dragover", (event) => { window.over = { day: event.target.closest(".day")?.dataset.day ?? event.target.closest("ul")?.className, prevented: event.defaultPrevented, effect: event.dataTransfer.dropEffect }; });
window.drops = 0;
document.addEventListener("drop", () => window.drops++);
window.runtime = await Runtime.load(fetch("/planner.wasm"));
try {
	window.runtime.hydrate(document.getElementById("app"), { strict: true });
} catch (error) {
	window.problem = error.message;
}
window.hydrated = true;
</script></body></html>`;
	const dir = mkdtempSync(join(tmpdir(), "rocx-planner-"));
	cpSync(join(web, "runtime.js"), join(dir, "runtime.js"));
	cpSync(join(out, "planner.wasm"), join(dir, "planner.wasm"));
	const site = await serve(dir, (path) => (path === "/" ? page : null), api);
	try {
		const tab = await browser.page();
		await tab.send("Emulation.setDeviceMetricsOverride", { width: 1000, height: 800, deviceScaleFactor: 1, mobile: false });
		await tab.goto(`${site.url}/`);
		await tab.wait("window.hydrated === true", 3000);
		assert.equal(await tab.eval("window.problem ?? null"), null, "hydrated strictly: the board came with the page");
		assert.deepEqual(reads, [], "nothing asked");
		const day = (name) => tab.eval(`[...document.querySelectorAll('.day[data-day=${name}] .card:not([inert])')].map((card) => card.textContent)`);
		const card = (title) => `[...document.querySelectorAll('.card')].find((card) => card.textContent === ${JSON.stringify(title)} && !card.closest('[inert]'))`;
		const gliding = (title) => tab.eval(`(${card(title)})?.getAnimations().filter((animation) => animation.effect.getKeyframes()[0]?.translate).length ?? -1`);
		const centerOf = (title) => tab.eval(`(() => { const r = (${card(title)}).getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);

		// A drag from Monday, over Tuesday's card (a child of Tuesday's list), and Tuesday itself.
		await tab.drag(".day[data-day=mon] .card", [".day[data-day=tue]", await centerOf("Gamma")], { drop: false });
		assert.equal(await tab.eval("document.querySelector('.over')?.dataset.day ?? null"), "tue", "over Tuesday, its card included: its dragenter ran once, and no dragleave");
		assert.deepEqual(await tab.eval("window.over"), { day: "tue", prevented: true, effect: "move" }, "a drop target: its dragover's default prevented, a move");
		assert.equal(await tab.eval(`(${card("Alpha")}).classList.contains('dragged')`), true, "dragstart ran");
		await tab.finish();
		// Moved at once, while the server hasn't answered.
		await tab.wait(`${card("Alpha")}?.closest('.day').dataset.day === 'tue'`, 2000);
		assert.deepEqual(await day("mon"), ["Beta"]);
		assert.deepEqual(await day("tue"), ["Alpha", "Gamma"], "in the board's order");
		assert.equal(posted.length, 1);
		assert.equal(posted[0].answered, false, "optimistic: the server hasn't answered");
		assert.deepEqual(posted[0].body, { card: "a", day: "tue" }, "the action's arg, as JSON");
		assert.equal(posted[0].headers["content-type"], "application/json");
		assert.equal(posted[0].headers.accept, "application/json");
		assert.equal(posted[0].headers["x-rocx-submission"], "1");
		assert.equal(await textOf(tab, ".pending"), "1 on their way");
		assert.equal(await tab.eval("document.querySelector('.days').classList.contains('stale')"), false, "the board isn't being read again yet: a move on its way is no refresh");
		assert.equal(await tab.eval("document.querySelector('.over')"), null, "the drop left Tuesday: dragleave ran");
		assert.equal(await tab.eval("document.querySelector('.dragged')"), null);
		assert.equal(await gliding("Alpha"), 1, "the card glides from Monday to Tuesday");
		assert.equal(await gliding("Beta"), 1, "Beta, below it on Monday, glides up into its place");
		assert.equal(await gliding("Gamma"), 1, "Gamma, below it on Tuesday now, glides down");
		// Answered: still on its way while the board is read again (held), then the server's.
		let releaseRead;
		holding = new Promise((resolve) => (releaseRead = resolve));
		posted[0].release();
		await until(() => reads.length === 1, 2000, "the board read again");
		await sleep(50);
		assert.deepEqual(await day("tue"), ["Alpha", "Gamma"], "kept while the board is read again");
		assert.equal(await textOf(tab, ".pending"), "1 on their way", "on its way until the page's reads are in");
		assert.equal(await tab.eval("document.querySelector('.days').classList.contains('stale')"), true, "is_pending! of the board while it is read again");
		releaseRead();
		holding = null;
		await tab.wait("document.querySelector('.pending').textContent === '0 on their way'", 2000);
		assert.deepEqual(await day("tue"), ["Alpha", "Gamma"], "the server's board now");
		assert.equal(await tab.eval("document.querySelector('.days').classList.contains('stale')"), false, "and not pending any more");
		assert.deepEqual(await day("mon"), ["Beta"]);
		const seen = await tab.eval("window.seen");
		const moved = seen.findIndex((shown) => /tue:[^ ]*Alpha/.test(shown));
		assert.ok(moved >= 0, "Alpha showed on Tuesday");
		assert.deepEqual(seen.slice(moved).filter((shown) => /mon:[^ ]*Alpha/.test(shown)), [], "and never on Monday again: no flicker of the old board");

		// Two at once: Beta to Wednesday (room for it), then Gamma too (full by then): each its own.
		await tab.drag(`.day[data-day=mon] .card`, ".day[data-day=wed]");
		await tab.wait(`${card("Beta")}?.closest('.day').dataset.day === 'wed'`, 2000);
		await tab.drag(".day[data-day=tue] .card:last-child", ".day[data-day=wed]");
		await tab.wait(`${card("Gamma")}?.closest('.day').dataset.day === 'wed'`, 2000);
		assert.deepEqual(await day("wed"), ["Beta", "Gamma", "Delta"], "both shown at once");
		assert.equal(await textOf(tab, ".pending"), "2 on their way");
		assert.equal(posted.length, 3);
		posted[1].release();
		await tab.wait("document.querySelector('.pending').textContent === '1 on their way'", 2000);
		assert.deepEqual(await day("wed"), ["Beta", "Gamma", "Delta"], "Gamma, still on its way, still shown on the server's board");
		posted[2].release();
		await tab.wait("document.querySelector('.refused .why')?.textContent === 'wed is full'", 2000);
		assert.deepEqual(await day("wed"), ["Beta", "Delta"], "refused: back where the server has it");
		assert.deepEqual(await day("tue"), ["Alpha", "Gamma"]);
		assert.equal(await textOf(tab, ".pending"), "0 on their way");
		assert.equal(await gliding("Gamma"), 1, "and it glides back");
		await tab.click(".dismiss");
		await tab.wait("document.querySelector('.refused') === null");

		// The tray has no drop handler: a drag over it isn't accepted, and its drop never comes.
		const before = posted.length;
		const drops = await tab.eval("window.drops");
		await tab.drag(".day[data-day=wed] .card:last-child", ".tray");
		assert.deepEqual(await tab.eval("({ day: window.over.day, prevented: window.over.prevented })"), { day: "tray", prevented: false }, "its dragover's default isn't prevented");
		assert.equal(await textOf(tab, ".note"), "over the tray", "its dragenter ran");
		await sleep(50);
		assert.equal(await tab.eval("window.drops"), drops, "no drop event: the browser saw no drop target");
		assert.equal(posted.length, before);
		assert.equal(await tab.eval("document.querySelector('.dragged')"), null, "dragend ran");

		// With less motion asked for, nothing glides.
		await tab.wait("document.getAnimations().length === 0", 3000);
		await tab.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
		await tab.drag(".day[data-day=wed] .card:last-child", ".day[data-day=mon]");
		await tab.wait(`${card("Delta")}?.closest('.day').dataset.day === 'mon'`, 2000);
		assert.equal(await tab.eval("document.getAnimations().length"), 0);
		posted.at(-1).release();
		await tab.wait("document.querySelector('.pending').textContent === '0 on their way'", 2000);
		await tab.send("Emulation.setEmulatedMedia", { features: [] });

		// Moving a card there and back leaves nothing allocated behind.
		await tab.wait("document.getAnimations().length === 0", 3000);
		const settled = await tab.eval("window.runtime.live()");
		for (const [from, to] of [["mon", "wed"], ["wed", "mon"]]) {
			await tab.drag(`.day[data-day=${from}] .card:last-child`, `.day[data-day=${to}]`);
			await tab.wait(`${card("Delta")}?.closest('.day').dataset.day === '${to}'`, 2000);
			posted.at(-1).release();
			await tab.wait("document.querySelector('.pending').textContent === '0 on their way'", 2000);
		}
		await tab.wait("document.getAnimations().length === 0", 3000);
		assert.equal(await tab.eval("window.runtime.live()"), settled, "the rows that moved, and the reads read again, let go of");

		// `.prevent`: the link's click is the page's.
		await tab.click(".elsewhere");
		await tab.wait("document.querySelector('.note').textContent === \"the page's\"", 2000);
		assert.equal(await tab.eval("location.pathname"), "/");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	} finally {
		await site.close();
		rmSync(dir, { recursive: true, force: true });
	}
});

// ---- Channels (D-020): the hub, one stream for a tab's subscriptions ----

/**
 * A scripted `/rocx/live` (and `/rocx/live/send`), as the server answers them: each stream sends
 * every channel it carries `resync` (or `refused`, for `/news/beta`), and `live.streams` keeps the
 * open ones, to send them messages or cut them off; `dropping` cuts each new one off once it has
 * resynced. A resync asked for is sent on the tab's open stream. `missing`: no server answers (404).
 */
function liveServer() {
	const live = { connects: [], said: [], streams: [], dropping: false, missing: false };
	const frame = (event, url, said) => `event: ${event}\ndata: ${url}\n${said === undefined ? "" : `data: ${JSON.stringify(said)}\n`}\n`;
	live.send = (url, said) => {
		for (const stream of live.streams) if (stream.urls.includes(url)) stream.response.write(frame("message", url, said));
	};
	live.api = (method, path, body, url) => {
		const query = new URL(url, "http://x").searchParams;
		if (path === "/rocx/live/send") {
			live.said.push({ tab: query.get("tab"), items: JSON.parse(body) });
			for (const item of JSON.parse(body)) {
				if (!item.resync) continue;
				for (const stream of live.streams) if (stream.tab === query.get("tab") && stream.urls.includes(item.channel)) stream.response.write(frame("resync", item.channel));
			}
			return { status: 204, body: "" };
		}
		if (path !== "/rocx/live") return null;
		if (live.missing) {
			live.connects.push({ at: performance.now(), tab: query.get("tab"), urls: query.getAll("c") });
			return { status: 404, body: "not found" };
		}
		return {
			status: 200,
			headers: { "content-type": "text/event-stream", "cache-control": "no-store" },
			stream: (response) => {
				const stream = { tab: query.get("tab"), urls: query.getAll("c"), response, closed: false };
				live.connects.push({ at: performance.now(), tab: stream.tab, urls: stream.urls });
				for (const url of stream.urls) response.write(url === "/news/beta" ? frame("refused", url, { status: 403, why: "Forbidden" }) : frame("resync", url));
				if (live.dropping) return response.end();
				live.streams.push(stream);
				response.on("close", () => {
					stream.closed = true;
					live.streams.splice(live.streams.indexOf(stream), 1);
				});
			},
		};
	};
	return live;
}

test("channels: two components on one channel share one stream with a third's; each hears resync, then what is published, in order; a refused channel is told so and the others go on; what a handler says goes in one post; a new subscriber to an open channel gets a resync without a reconnect; a change of channels reconnects once; a drop, again, a little later each time, with a resync", { skip }, async () => {
	const live = liveServer();
	await withDocument({ app: "channels", api: live.api, pages: { "/": (render) => documentPage(render, "/") } }, async ({ site, server }) => {
		const { html } = server.renderToString({ path: "/" });
		assert.match(html, /<p class="feed first"><!--x--><!--\/x--><\/p>/, "on the server, nothing is subscribed to");
		const before = server.live();
		for (let i = 0; i < 10; i++) server.renderToString({ path: "/" });
		assert.equal(server.live(), before, "and what would have subscribed is let go of");
		const tab = await strictTab();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.ready", 3000);
		assert.deepEqual(tab.console, [], "hydrated strictly");
		const feeds = () => tab.eval("[...document.querySelectorAll('.feed')].map((feed) => feed.className.slice(5) + ': ' + feed.textContent)");
		await tab.wait("document.querySelector('.feed.beta').textContent === 'refused 403' && document.querySelector('.feed.second').textContent === 'resync acme'", 3000);
		assert.deepEqual(await feeds(), ["first: resync acme", "second: resync acme", "beta: refused 403"]);
		assert.equal(live.connects.length, 1, "one stream for the page's three subscriptions");
		const [{ tab: id, urls }] = live.connects;
		assert.deepEqual(urls, ["/news/acme", "/news/beta"], "each channel once, whoever subscribes to it");
		assert.match(id, /^[0-9a-f]{24}$/, "the tab's id");
		assert.equal(await tab.eval("sessionStorage.getItem('rocx-tab')"), id, "kept for the tab");
		// Published: both subscribers hear it, in order; the refused channel hears nothing.
		for (let n = 1; n <= 3; n++) live.send("/news/acme", { title: "news", n });
		await tab.wait("document.querySelector('.feed.second').textContent.endsWith('news 3')", 3000);
		assert.deepEqual(await feeds(), ["first: resync acme, news 1, news 2, news 3", "second: resync acme, news 1, news 2, news 3", "beta: refused 403"]);
		// What a handler says: in one post, in order.
		await tab.click(".say");
		await until(() => live.said.length === 1);
		await sleep(100);
		assert.deepEqual(live.said, [{ tab: id, items: [{ channel: "/news/acme", message: { Hello: "one" } }, { channel: "/news/acme", message: { Hello: "two" } }] }]);
		// The second goes: the first still subscribes, so the stream goes on as it is.
		await tab.click(".toggle");
		await tab.wait("document.querySelector('.feed.second') === null");
		await sleep(100);
		assert.equal(live.connects.length, 1, "the same set: no reconnect");
		// It comes back: a new subscriber to a channel the stream has open asks for its resync.
		await tab.click(".toggle");
		await tab.wait("document.querySelector('.feed.second')?.textContent === 'resync acme'", 3000);
		assert.equal(live.connects.length, 1, "still no reconnect");
		assert.deepEqual(live.said.at(-1).items, [{ channel: "/news/acme", resync: true }]);
		assert.equal(await tab.eval("document.querySelector('.feed.first').textContent"), "resync acme, news 1, news 2, news 3, resync acme", "everyone on the channel hears it");
		// A resync asked for (Endpoint.resync!).
		await tab.click(".resync");
		await tab.wait("document.querySelector('.feed.second').textContent === 'resync acme, resync acme'", 3000);
		// Switching the org: both feeds' effects run again, the set changes: one reconnect.
		await tab.click(".switch");
		await tab.wait("document.querySelector('.feed.second').textContent.endsWith('resync zeta')", 3000);
		await sleep(150);
		assert.equal(live.connects.length, 2, "exactly one reconnect for the change");
		assert.deepEqual(live.connects[1].urls, ["/news/beta", "/news/zeta"]);
		assert.equal(live.connects[1].tab, id, "the same tab");
		assert.equal(live.streams.length, 1, "the old stream is closed");
		assert.equal(await tab.eval("document.querySelector('.feed.beta').textContent"), "refused 403, refused 403", "beta, refused on each stream");
		// Cut off: the hub opens it again, a little later each time it drops at once, and every
		// subscriber hears resync each time.
		await tab.eval("window.ready.runtime.hub.first = 80");
		live.dropping = true;
		const cut = performance.now();
		live.streams[0].response.end();
		await until(() => live.connects.length >= 6, 5000, "four reconnects");
		live.dropping = false;
		await until(() => live.connects.length >= 7, 5000, "a stream that stays");
		const gaps = live.connects.slice(2, 7).map((connect, i) => connect.at - (i ? live.connects[1 + i].at : cut));
		assert.ok(gaps[0] >= 75 && gaps[0] < 400, `the first after ~80 ms: ${gaps.map(Math.round)}`);
		for (let i = 1; i < gaps.length; i++) assert.ok(gaps[i] > gaps[i - 1] * 1.4, `each wait about twice the last: ${gaps.map(Math.round)}`);
		assert.ok(live.connects.every((connect) => connect.tab === id), "one tab throughout");
		await tab.wait("document.querySelector('.feed.first').textContent.split('resync zeta').length === 7", 3000);
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	});
});

test("channels: where no server answers them (a static copy), every subscriber hears Refused(404) and the hub asks once", { skip }, async () => {
	const live = liveServer();
	live.missing = true;
	await withDocument({ app: "channels", api: live.api, pages: { "/": (render) => documentPage(render, "/") } }, async ({ site }) => {
		const tab = await strictTab();
		await tab.goto(`${site.url}/`);
		await tab.wait("window.ready", 3000);
		await tab.wait("[...document.querySelectorAll('.feed')].every((feed) => feed.textContent === 'refused 404')", 3000);
		await tab.click(".switch");
		await tab.click(".say");
		await sleep(400);
		assert.equal(live.connects.length, 1, "asked once, and no more");
		assert.equal(live.said.length, 0, "nothing said where nobody hears");
		assert.equal(await tab.eval("document.querySelector('.feed.first').textContent"), "refused 404, refused 404", "a new subscription is told at once");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	});
});
