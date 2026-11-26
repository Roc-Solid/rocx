// Navigation in place (D-040, phase 1), in Chromium: web/test/nav, a small app of routes (a layout
// and pages: home, A, an item, a guarded page), its server half rendering each page's document as
// the server platform answers a load (`renderToString`, from the answers its reads got), and a
// scripted server that serves them, slowly when told to, or refuses, redirects, crashes. A click on
// a link to one of the app's pages, a handler's `navigate!`, back and forward render the next page
// from its document, without a load; each opt-out is the browser's; whatever isn't an app document
// of this build is loaded. Builds what it needs first (rocx, the host, the two wasms). Needs the
// toolchain (`just setup`) and Chromium (browser.mjs).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { roc as findRoc, rocxBinary, buildWebHost } from "../../server/build.mjs";
import { findChrome, launch } from "./browser.mjs";
import { serve } from "./serve.mjs";
import { Runtime } from "../runtime.js";

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, "..");
const root = join(web, "..");
const out = join(here, "build");
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

/** The app through rocx (and its browser's copy), the host, the server half (with what is inside
 * each <NoHydration>) and the browser's wasm. */
if (!skip) {
	run(rocxBinary(), ["generate", join(here, "nav"), "--client", join(out, "nav-client")]);
	buildWebHost();
	run(roc, ["build", "--target=wasm32", "--opt=dev", `--output=${join(out, "nav-server.wasm")}`, join(here, "nav", "nav_server.roc")]);
	run(roc, ["build", "--target=wasm32", "--opt=size", `--output=${join(out, "nav.wasm")}`, join(out, "nav-client", "main.roc")]);
}

/** A machine slower than the ones these are measured on says so by ROCX_TIME_SCALE (CI sets 3):
 * the waits here, and the runtime's rest before a hover prefetches (`Runtime.REST`, 65 ms, in
 * HEARD), grow by as much, so the DevTools protocol's round trips (a pointer moved, then moved on;
 * moved, then pressed) still fit inside a rest, and a prefetch's request inside a wait. */
const SCALE = Number(process.env.ROCX_TIME_SCALE) || 1;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms * SCALE));

/** The build's id, as rocx build wrote it in Root: every document's bootstrap says it. */
const BUILD = skip ? "" : /^\tbuild = "([0-9a-f]{8})"$/m.exec(readFileSync(join(here, "nav", "Generated", "Root.roc"), "utf8"))[1];

/** Polls `check` until it holds, or fails after `ms`. */
async function until(check, ms = 3000 * SCALE, what = String(check)) {
	for (const end = Date.now() + ms; Date.now() < end; await sleep(20)) if (await check()) return;
	throw new Error(`timed out waiting for ${what}`);
}

/** What the server says of a word (`GET /api/say/<word>`), as JSON. */
const said = (word) => ({ status: 200, body: JSON.stringify(`Said: ${word}`) });

/** The answers the server's reads got as it rendered the pages: `renderToString` answers each GET
 * from them, and records those a page asked for in its document. */
const ANSWERS = ["home", "a", "notes", ...Array.from({ length: 10 }, (_, n) => String(n)), "books", "games", "color-none", "color-red", "color-blue"].map((word) => [`GET /api/say/${word}`, "", JSON.stringify(said(word))]);

/** A page's markup with its URLs under `base`, as the static build writes it (site/build.mjs's `underBase`). */
const underBase = (html, base) => (base === "/" ? html : html.replace(/(\s(?:href|src|action)=")\/(?!\/)/g, `$1${base}`));

/** A scripted `/rocx/live`, as the server answers it: each stream says its id, then `resync` for each
 * channel it carries; a subscribe or an unsubscribe is told the stream it names. `connects` notes each
 * stream opened, `streams` the open ones. */
function liveServer() {
	const live = { connects: [], streams: [] };
	live.api = (method, path, body, url) => {
		const query = new URL(url, "http://x").searchParams;
		if (path.endsWith("/rocx/live/send")) {
			for (const item of JSON.parse(body)) {
				const stream = live.streams.find((each) => each.id === query.get("stream"));
				if (!stream) continue;
				if (item.subscribe) {
					stream.urls.push(item.channel);
					stream.response.write(`event: resync\ndata: ${item.channel}\n\n`);
				} else if (item.unsubscribe) stream.urls = stream.urls.filter((each) => each !== item.channel);
				else if (item.resync) for (const each of live.streams) if (each.urls.includes(item.channel)) each.response.write(`event: resync\ndata: ${item.channel}\n\n`);
			}
			return { status: 204, body: "" };
		}
		if (!path.endsWith("/rocx/live")) return null;
		return {
			status: 200,
			headers: { "content-type": "text/event-stream", "cache-control": "no-store" },
			stream: (response) => {
				const stream = { id: `s${live.connects.length + 1}`, urls: query.getAll("c"), response };
				live.connects.push([...stream.urls]);
				response.write(`event: hello\ndata: ${stream.id}\n\n`);
				for (const each of stream.urls) response.write(`event: resync\ndata: ${each}\n\n`);
				live.streams.push(stream);
				response.on("close", () => live.streams.splice(live.streams.indexOf(stream), 1));
			},
		};
	};
	return live;
}

/**
 * The app, served: its pages' documents rendered per request by its server half, under `base`;
 * start.js, the runtime and the wasm at `${base}rocx/`; the reads it makes answered. Every request
 * is noted (`asked`: its path and query, and its `x-rocx-navigate`). `rules[path]` (the path without
 * the base) answers a page's request instead (`(request) => answer | null`), and `held[path]`, a
 * promise, holds its answer until it settles. A POST to the notes' or an item's endpoint (D-095) is
 * noted in `posted` (its path and query, its body, and its `x-rocx-submission`), and answered by
 * its note: `away` with a redirect to A (`x-rocx-redirect`), `refuse` with a 409, any other with
 * itself; one to `/nowhere`, a path no endpoint has, with a 303 to A, as a browser's post gets.
 */
async function navSite({ base = "/" } = {}) {
	const server = await Runtime.load(readFileSync(join(out, "nav-server.wasm")));
	const dir = mkdtempSync(join(tmpdir(), "rocx-nav-"));
	const files = join(dir, base, "rocx");
	mkdirSync(files, { recursive: true });
	cpSync(join(web, "start.js"), join(files, "start.js"));
	cpSync(join(web, "runtime.js"), join(files, "runtime.js"));
	cpSync(join(out, "nav.wasm"), join(files, "app.wasm"));
	// The links stay where they are as the page scrolls, so a click on one doesn't scroll it.
	writeFileSync(join(dir, base, "nav.css"), "nav { position: fixed; top: 0; right: 0; width: 12em; font-size: 8px } .tall { height: 3000px } .progress.on { height: 2px; background: blue }");
	const site = { asked: [], posted: [], rules: {}, held: {}, live: liveServer(), base, dir: join(dir, base) };
	site.render = (target) => {
		const rendered = server.renderToString({ path: target, answers: ANSWERS }).html;
		return { status: server.status, html: underBase(rendered, base) };
	};
	const unbased = (path) => (base === "/" ? path : path === base.slice(0, -1) ? "/" : path.startsWith(base) ? `/${path.slice(base.length)}` : null);
	const api = async (method, path, body, url, request) => {
		site.asked.push({ url, navigate: request.headers["x-rocx-navigate"] ?? null });
		const live = site.live.api(method, path, body, url);
		if (live) return live;
		const at = unbased(path);
		if (at === null) return null;
		const word = /^\/api\/say\/(.+)$/.exec(at)?.[1];
		if (word) return { status: 200, headers: { "content-type": "application/json" }, body: JSON.stringify(`Said: ${decodeURIComponent(word)}`) };
		if (at === "/api/poke") return { status: 200, headers: { "content-type": "application/json" }, body: JSON.stringify("poked") };
		if (at === "/api/leave") {
			await site.held[at];
			return { status: 200, headers: { "content-type": "application/json", "x-rocx-redirect": "/items/3" }, body: JSON.stringify("left") };
		}
		if (at === "/api/wait") {
			await sleep(150);
			return { status: 200, headers: { "content-type": "application/json" }, body: JSON.stringify("now") };
		}
		if (method === "POST" && (at === "/notes" || at.startsWith("/items/") || at === "/nowhere")) {
			site.posted.push({ url: `${at}${new URL(url, "http://x").search}`, body, submission: request.headers["x-rocx-submission"] ?? null });
			if (at === "/nowhere") return { status: 303, headers: { location: `${base}a` }, body: "" };
			const note = new URLSearchParams(body).get("note");
			if (note === "refuse") return { status: 409, headers: { "content-type": "text/plain" }, body: "no more notes" };
			const headers = { "content-type": "application/json", ...(note === "away" ? { "x-rocx-redirect": "/a" } : {}) };
			return { status: 200, headers, body: JSON.stringify(note) };
		}
		if (at.startsWith("/rocx/") || at.endsWith(".css")) return null;
		await site.held[at];
		const ruled = site.rules[at]?.(request);
		if (ruled) return ruled;
		const query = new URL(url, "http://x").search;
		const page = site.render(`${at}${query}`);
		return { status: page.status, headers: { "content-type": "text/html; charset=utf-8" }, body: page.html };
	};
	const served = await serve(dir, () => null, api);
	site.url = `${served.url}${base.slice(0, -1)}`;
	site.close = async () => {
		for (const stream of site.live.streams) stream.response.end();
		await served.close();
		rmSync(dir, { recursive: true, force: true });
	};
	/** The documents asked for (not files or reads), as a navigation (`x-rocx-navigate: 1`), a
	 * prefetch (`preload`) or a load. */
	site.documents = () => site.asked.filter(({ url }) => !/\/rocx\/(start\.js|runtime\.js|app\.wasm|live)|\/api\/|\.css$/.test(url)).map(({ url, navigate }) => `${navigate === "preload" ? "preload" : navigate ? "navigate" : "load"} ${url}`);
	return site;
}

let browser;
before(async () => {
	if (!skip) browser = await launch();
});
after(async () => {
	await browser?.close();
});

/** What the page heard: `rocx:navigate` and `rocx:navigated`, and its effects' calls (`nav.tick`,
 * `nav.item`, and the editor's leave listeners', `nav.leave`); set before anything runs, in every
 * document, with the page strict. */
const HEARD = `
	window.rocxStrict = true;
	window.heard = [];
	window.rocxEffects = {
		"nav.tick": ({ n }) => (window.ticks = n),
		"nav.item": ({ id }) => window.heard.push("item " + id),
		"nav.leave": ({ who, to, from, delta, before }) => window.heard.push("leave " + who + " " + to + " from " + from + (delta ? " " + delta : "") + (before ? " after one stopped it" : "")),
	};
	document.addEventListener("rocx:ready", (event) => {
		window.ready = event.detail;
		const runtime = event.detail.runtime.constructor;
		if (${SCALE} !== 1 && !runtime.scaled) (runtime.REST *= ${SCALE}), (runtime.scaled = true);
	});
	document.addEventListener("rocx:navigate", (event) => { window.left = window.scrollY; window.heard.push("navigate " + new URL(event.detail.url).pathname + new URL(event.detail.url).search); });
	document.addEventListener("rocx:navigated", (event) => window.heard.push("navigated " + new URL(event.detail.url).pathname + new URL(event.detail.url).search));
`;

/** A tab on `path`, awake, with a mark on its window that a load would take away. */
async function open(site, path) {
	const tab = await browser.page();
	await tab.beforeEachDocument(HEARD);
	await tab.goto(`${site.url}${path}`);
	await tab.wait("window.ready", 5000);
	await tab.eval("window.mark = 'kept'");
	return tab;
}

/** Whether the page was navigated in place: its mark is still there. */
const kept = (tab) => tab.eval("window.mark === 'kept'");

/** The page as it stands, the way a load and a navigation are compared: `<html>`, without the host's
 * elements (`[data-rocx]`: the bootstrap, the runtime's title and announcer) and the comments a text
 * hole's server markup has (`<!--x-->`), which the browser doesn't make. */
const SNAPSHOT = `(() => {
	const copy = document.documentElement.cloneNode(true);
	for (const host of copy.querySelectorAll("[data-rocx]")) host.remove();
	// Page A's timer (every 30 ms) counts while it runs: its count says when this was taken, not
	// what was rendered (a slower machine's navigated page had ticked once more than its load).
	for (const ticks of copy.querySelectorAll(".ticks")) ticks.textContent = "";
	const walker = document.createTreeWalker(copy, NodeFilter.SHOW_COMMENT);
	const gone = [];
	for (let node = walker.nextNode(); node; node = walker.nextNode()) if (node.data === "x" || node.data === "/x") gone.push(node);
	for (const node of gone) node.remove();
	copy.normalize();
	return copy.outerHTML;
})()`;

test("a click on a link to one of the app's pages renders it in place: no load, its document fetched once as a navigation and nothing else asked (strictly), the address pushed; its title, <Title>, head, regions and attributes the document's, the stylesheet kept; announced, the focus at <body>'s start; the page as a load renders it", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		await tab.eval("window.sheet = document.querySelector('link[rel=stylesheet]'); window.entries = history.length");
		await tab.click(".count");
		await tab.wait("document.querySelector('.count').textContent === 'Clicked 1'");
		site.asked.length = 0;
		await tab.click(".to-a");
		await tab.wait("location.pathname === '/a' && document.querySelector('.a h1')?.textContent === 'A'");
		assert.equal(await kept(tab), true, "no load: the window is the same");
		assert.deepEqual(site.documents(), ["navigate /a"], "its document, fetched once, as a navigation");
		assert.deepEqual(site.asked.map(({ url }) => url).filter((url) => !url.includes("/rocx/live")), ["/a"], "and nothing else: its read came with it (A's channel aside)");
		assert.equal(await tab.eval("history.length - window.entries"), 1, "an entry pushed");
		await tab.wait("window.heard.includes('navigated /a')");
		assert.deepEqual(await tab.eval("window.heard"), ["navigate /a", "navigated /a"]);
		assert.deepEqual(
			await tab.eval("[document.title, [...document.head.querySelectorAll('title')].map((title) => title.textContent).join(' | '), document.querySelector('meta[name=description]').content, document.documentElement.className, document.body.className]"),
			["Page A", "Page A | A · Nav", "A", "a", "a"],
			"the page's <Title>, before the layout's own title, its <meta> and <html>'s and <body>'s classes, as the document has them",
		);
		assert.equal(await tab.eval("window.sheet === document.querySelector('link[rel=stylesheet]') && document.querySelectorAll('link[rel=stylesheet]').length"), 1, "the stylesheet, kept: not loaded again");
		assert.deepEqual(await tab.eval("[document.querySelector('.note').textContent, document.querySelector('.a .said').textContent, document.querySelector('footer.at').textContent]"), ["The layout's note, for A", "Said: a", "/a"], "the layout's <NoHydration>, the document's; the read, from it; where it is");
		assert.equal(await tab.eval("document.querySelector('body > [aria-live]').textContent"), "Page A", "announced");
		assert.equal(await tab.eval("document.activeElement === document.body && !document.body.hasAttribute('tabindex')"), true, "the focus at <body>'s start, as after a load");
		await tab.press("Tab");
		assert.equal(await tab.eval("document.activeElement.className"), "skip", "the next Tab reaches the skip link");
		// Each snapshot once page A has heard its channel's first word (`resync`, as it subscribes):
		// one taken before would differ by when, as a slower machine's load did.
		const settled = "document.querySelector('.a .heard')?.textContent === 'resync'";
		await tab.wait(settled);
		const navigated = await tab.eval(SNAPSHOT);
		// The same page, loaded.
		const loaded = await browser.page();
		await loaded.beforeEachDocument(HEARD);
		await loaded.goto(`${site.url}/a`);
		await loaded.wait("window.ready", 5000);
		await loaded.wait(settled);
		assert.equal(navigated, await loaded.eval(SNAPSHOT), "the page a load renders, byte for byte outside the host's elements");
		// And on: an item, then home, each its own.
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.item h1')?.textContent === 'Item 7'");
		assert.deepEqual(await tab.eval("[document.title, document.querySelector('.item .prose').textContent, document.querySelector('footer.at').textContent]"), ["An item · Nav", "Item 7's prose", "/items/7"], "no <Title>: the layout's own title");
		await tab.click(".to-home");
		await tab.wait("document.querySelector('.home h1') && document.querySelector('.count').textContent === 'Clicked 0'");
		assert.equal(await kept(tab), true);
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await loaded.close();
		await tab.close();
	} finally {
		await site.close();
	}
});

test("<head> reconciled: a stylesheet link that is the same is kept, one that differs is swapped, the new one in before the old one goes", { skip }, async () => {
	const site = await navSite();
	try {
		writeFileSync(join(site.dir, "nav-2.css"), "body { outline: 1px solid red }");
		site.rules["/a"] = () => ({ status: 200, headers: { "content-type": "text/html; charset=utf-8" }, body: site.render("/a").html.replace('href="/nav.css"', 'href="/nav-2.css"') });
		const tab = await open(site, "/");
		await tab.eval("window.sheet = document.querySelector('link[rel=stylesheet]')");
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.item h1')");
		assert.equal(await tab.eval("window.sheet === document.querySelector('link[rel=stylesheet]')"), true, "the same: kept");
		await tab.click(".to-a");
		await tab.wait("document.querySelector('.a h1')");
		await tab.wait("document.querySelectorAll('link[rel=stylesheet]').length === 1");
		assert.equal(await tab.eval("document.querySelector('link[rel=stylesheet]').getAttribute('href') + ' ' + getComputedStyle(document.body).outlineStyle + ' ' + window.sheet.isConnected"), "/nav-2.css solid false", "another: the new one, loaded, and the old one gone");
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("what isn't a navigation in place stays the browser's: modifier keys, a target, download, rel=external, another origin, a path no page has, a file, a place on this page, and <html data-rocx-navigation=\"off\">", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		// After the runtime has decided (on the document), the click is stopped, so the browser does nothing.
		await tab.eval("window.decided = []; window.addEventListener('click', (event) => { window.decided.push(event.defaultPrevented); event.preventDefault(); })");
		// Whether the runtime took the click (it prevented the browser's default); null with no click
		// event at all (Control and a click is the context menu on macOS).
		const decide = async (selector, { modifiers = 0 } = {}) => {
			const { x, y } = await tab.eval(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
			for (const type of ["mousePressed", "mouseReleased"]) await tab.send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1, modifiers });
			await sleep(60);
			const taken = await tab.eval("window.decided.length ? window.decided.pop() : null");
			await tab.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
			return taken;
		};
		assert.equal(await decide(".to-a"), true, "a plain link to a page: taken");
		await tab.wait("location.pathname === '/a'");
		await tab.eval("history.back()");
		await tab.wait("location.pathname === '/' && document.querySelector('.home h1')");
		for (const [selector, how] of [
			[".to-a", { modifiers: 2 }],
			[".to-a", { modifiers: 4 }],
			[".to-a", { modifiers: 8 }],
			[".to-a", { modifiers: 1 }],
			[".to-blank", {}],
			[".to-download", {}],
			[".to-external", {}],
			[".to-elsewhere", {}],
			[".to-nowhere", {}],
			[".to-file", {}],
			[".to-below", {}],
			[".to-top", {}],
		]) {
			assert.notEqual(await decide(selector, how), true, `${selector} ${JSON.stringify(how)}: the browser's`);
		}
		await tab.eval("document.documentElement.setAttribute('data-rocx-navigation', 'off')");
		assert.equal(await decide(".to-a"), false, "navigation in place turned off");
		await tab.eval("document.documentElement.setAttribute('data-rocx-navigation', 'explicit')");
		assert.equal(await decide(".to-a"), false, "explicit: only a link that says so");
		// A place on this page (in a tab whose clicks aren't stopped): the browser scrolls there.
		const plain = await browser.page();
		await plain.beforeEachDocument(HEARD);
		await plain.goto(`${site.url}/`);
		await plain.wait("window.ready", 5000);
		await plain.eval("window.mark = 'kept'");
		site.asked.length = 0;
		await plain.click(".to-below");
		await plain.wait("location.hash === '#below' && window.scrollY > 0");
		assert.equal(await kept(plain), true);
		assert.deepEqual(site.documents().filter((each) => !each.startsWith("preload")), [], "nothing fetched (the link it scrolled into sight is prefetched)");
		assert.deepEqual(await plain.eval("window.heard"), [], "not a navigation of the runtime's");
		await plain.eval("history.back()");
		await plain.wait("location.hash === ''");
		assert.equal(await kept(plain), true, "back from it: the browser's too");
		assert.deepEqual(site.documents().filter((each) => !each.startsWith("preload")), []);
		// A path no page has: loaded, the app's 404 page.
		await plain.click(".to-nowhere");
		await plain.wait("location.pathname === '/nowhere' && window.mark === undefined && window.ready", 5000);
		assert.equal(await plain.eval("document.querySelector('.error h1').textContent"), "404");
		assert.deepEqual(site.documents().filter((each) => !each.startsWith("preload")), ["load /nowhere"]);
		assert.deepEqual(plain.errors, []);
		await plain.close();
		await tab.close();
	} finally {
		await site.close();
	}
});

test("navigate! from a handler that waits for the server and runs again navigates once, after its writes; navigate_with!'s replace takes the entry's place", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		await tab.eval("window.entries = history.length");
		site.asked.length = 0;
		await tab.click(".go");
		await tab.wait("location.pathname === '/a' && document.querySelector('.a h1')", 5000);
		assert.equal(await tab.eval("location.search"), "?after=now", "the handler's second run's, with the server's answer");
		assert.equal(await kept(tab), true);
		assert.deepEqual(site.documents(), ["navigate /a?after=now"], "once");
		assert.deepEqual(await tab.eval("window.heard"), ["navigate /a?after=now", "navigated /a?after=now"]);
		assert.equal(await tab.eval("history.length - window.entries"), 1);
		await tab.click(".home-replacing");
		await tab.wait("document.querySelector('.home h1')");
		assert.equal(await tab.eval("history.length - window.entries"), 1, "replaced, not pushed");
		await tab.eval("history.back()");
		await tab.wait("location.pathname === '/' && location.search === '' && document.querySelector('.home h1') && window.heard.filter((each) => each.startsWith('navigated')).at(-1) === 'navigated /'");
		assert.equal(await kept(tab), true, "back: the entry before, home, in place");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("a submission's redirect (x-rocx-redirect) is followed in place, unless the visitor went to another page while it was on its way", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		await tab.click(".leave");
		await tab.wait("document.querySelector('.item h1')?.textContent === 'Item 3'");
		assert.equal(await tab.eval("location.pathname"), "/items/3");
		assert.equal(await kept(tab), true, "in place");
		await tab.click(".to-home");
		await tab.wait("document.querySelector('.home h1')");
		let release;
		site.held["/api/leave"] = new Promise((resolve) => (release = resolve));
		await tab.click(".leave");
		await sleep(50);
		await tab.click(".to-a");
		await tab.wait("document.querySelector('.a h1')");
		release();
		await sleep(200);
		assert.equal(await tab.eval("location.pathname"), "/a", "the redirect of a submission sent from the page before isn't followed");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("back and forward render the entry's page in place, its scroll restored, its document used again within 10 s and fetched again after; a new entry starts at the top, or at its hash, and noscroll keeps the scroll", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.item h1')");
		await tab.eval("window.scrollTo(0, 600)");
		await tab.click(".to-a");
		await tab.wait("document.querySelector('.a h1')");
		const left = await tab.eval("window.left");
		assert.ok(left >= 590, `scrolled down as it left: ${left}`);
		assert.equal(await tab.eval("window.scrollY"), 0, "a new entry, at the top");
		site.asked.length = 0;
		await tab.eval("history.back()");
		await tab.wait("document.querySelector('.item h1') && window.heard.filter((each) => each.startsWith('navigated')).at(-1) === 'navigated /items/7'");
		assert.equal(await kept(tab), true);
		assert.equal(await tab.eval("window.scrollY"), left, "back: where it was");
		assert.deepEqual(site.documents(), [], "its document, used again: fetched under 10 s ago");
		await tab.eval("history.forward()");
		await tab.wait("document.querySelector('.a h1') && window.heard.filter((each) => each.startsWith('navigated')).at(-1) === 'navigated /a'");
		assert.equal(await tab.eval("window.scrollY"), 0, "forward: where it was");
		assert.deepEqual(site.documents(), []);
		// Older than the cache keeps them for (shortened here): fetched again.
		await tab.eval("window.ready.runtime.constructor.FRESH = 100");
		await sleep(150);
		await tab.eval("history.back()");
		await tab.wait("document.querySelector('.item h1') && window.heard.filter((each) => each.startsWith('navigated')).at(-1) === 'navigated /items/7'");
		assert.deepEqual(site.documents(), ["navigate /items/7"]);
		assert.equal(await tab.eval("window.scrollY"), left);
		// A hash: its element at the top; noscroll: the scroll where it is.
		await tab.click(".to-item-hash");
		await tab.wait("document.querySelector('.item h1')?.textContent === 'Item 8'");
		assert.equal(await tab.eval("location.hash"), "#deep");
		assert.equal(await tab.eval("(() => { const box = document.getElementById('deep').getBoundingClientRect(); return window.scrollY > 2000 && box.top >= 0 && box.bottom <= innerHeight; })()"), true, "at its hash's element (the page's last: as far down as the page goes)");
		await tab.eval("window.scrollTo(0, 300)");
		await tab.click(".to-a-noscroll");
		await tab.wait("document.querySelector('.a h1')");
		assert.equal(await tab.eval("window.scrollY > 0"), true, "noscroll: kept");
		// A reload puts back the scroll of the entry it is on (an item's: nothing comes in above it later).
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.item h1')?.textContent === 'Item 7'");
		await tab.eval("window.scrollTo(0, 250)");
		await tab.send("Page.reload");
		await tab.wait("window.ready", 5000);
		await tab.wait("window.scrollY === 250");
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("is_routing! is true from the click while a slow document is on its way, the old page staying, and false once the page is on screen; a newer navigation overtakes one on its way, which never shows", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		let release;
		site.held["/items/7"] = new Promise((resolve) => (release = resolve));
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.progress').classList.contains('on')");
		assert.equal(await tab.eval("Boolean(document.querySelector('.home h1')) && location.pathname"), "/", "the old page stays, and the address");
		release();
		await tab.wait("document.querySelector('.item h1')");
		assert.equal(await tab.eval("document.querySelector('.progress').classList.contains('on')"), false);
		// Overtaken: the item's document held, A's after it; A's comes first and wins; the item's never shows.
		let releaseItem;
		let releaseA;
		site.held["/items/7"] = new Promise((resolve) => (releaseItem = resolve));
		site.held["/a"] = new Promise((resolve) => (releaseA = resolve));
		await tab.click(".to-home");
		await tab.wait("document.querySelector('.home h1')");
		site.held["/"] = null;
		await tab.eval("window.ready.runtime.constructor.FRESH = 0");
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.progress').classList.contains('on')");
		await tab.click(".to-a");
		await sleep(50);
		releaseItem();
		await sleep(100);
		assert.equal(await tab.eval("Boolean(document.querySelector('.home h1')) && document.querySelector('.progress').classList.contains('on')"), true, "the overtaken one never shows, and one is still on its way");
		releaseA();
		await tab.wait("document.querySelector('.a h1')");
		assert.equal(await tab.eval("location.pathname + ' ' + document.querySelector('.progress').classList.contains('on')"), "/a false");
		await sleep(100);
		assert.equal(await tab.eval("location.pathname"), "/a");
		assert.equal(await kept(tab), true);
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("a middleware's redirect lands on its page, with its address; one to another site, and whatever isn't an app document of this build (a text 401, a crash, a refused fetch, another build), the browser loads", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		await tab.eval("window.entries = history.length");
		site.rules["/guarded"] = () => ({ status: 303, headers: { location: "/items/9" }, body: "" });
		site.asked.length = 0;
		await tab.click(".to-guarded");
		await tab.wait("document.querySelector('.item h1')?.textContent === 'Item 9'");
		assert.equal(await tab.eval("location.pathname"), "/items/9", "the address is where it ended");
		assert.equal(await tab.eval("history.length - window.entries"), 1);
		assert.equal(await kept(tab), true);
		assert.deepEqual(site.documents(), ["navigate /guarded", "navigate /items/9"]);
		const loads = async (rule, check) => {
			site.rules["/guarded"] = rule;
			const page = await open(site, "/");
			site.asked.length = 0;
			await page.click(".to-guarded");
			await page.wait(`location.pathname === '/guarded' && window.mark === undefined && document.readyState === 'complete' && ${check}`, 5000);
			// A request with no answer the browser may send again: once each, in order.
			const documents = site.documents().filter((each, at, all) => each !== all[at - 1]);
			await page.close();
			return documents;
		};
		const text = (status, body) => () => ({ status, headers: { "content-type": "text/plain; charset=utf-8" }, body });
		assert.deepEqual(await loads(text(401, "members only"), "document.body.textContent === 'members only'"), ["navigate /guarded", "load /guarded"], "a text 401: loaded, and shown as the server said it");
		assert.deepEqual(await loads(text(500, "roc crashed"), "document.body.textContent === 'roc crashed'"), ["navigate /guarded", "load /guarded"], "a crash");
		const navigating = (answer) => (request) => (request.headers["x-rocx-navigate"] ? answer(request) : null);
		assert.deepEqual(
			await loads(
				navigating((request) => {
					request.socket.destroy();
					return new Promise(() => {});
				}),
				"document.querySelector('.guarded h1') && window.ready",
			),
			["navigate /guarded", "load /guarded"],
			"a fetch refused (no answer): loaded",
		);
		assert.deepEqual(await loads(navigating(() => ({ status: 200, headers: { "content-type": "text/html; charset=utf-8" }, body: site.render("/guarded").html.replace(`data-build="${BUILD}"`, 'data-build="0badbeef"') })), "document.querySelector('.guarded h1') && window.ready"), ["navigate /guarded", "load /guarded"], "another build's: loaded, which brings its wasm");
		assert.deepEqual(await loads(navigating(() => ({ status: 303, headers: { location: "http://localhost:9/sign-in" }, body: "" })), "document.querySelector('.guarded h1') && window.ready"), ["navigate /guarded", "load /guarded"], "a redirect to another site: the link's URL, loaded");
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("the old page's effects, timers and channel stop with it and the new page's start; a navigation that keeps the set of channels opens no stream again", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/a");
		await tab.wait("window.ticks > 2 && document.querySelector('.heard').textContent === 'resync'");
		assert.deepEqual(site.live.connects, [["/news/nav"]]);
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.item h1') && window.heard.includes('item 7')");
		const ticks = await tab.eval("window.ticks");
		await sleep(150);
		assert.equal(await tab.eval("window.ticks"), ticks, "A's timer, and its effect, stopped");
		await sleep(50);
		assert.equal(site.live.streams.length, 0, "nothing left to hear: the stream closed");
		await tab.click(".to-a");
		await tab.wait("document.querySelector('.a .heard')?.textContent === 'resync' && window.ticks < " + ticks);
		assert.equal(site.live.connects.length, 2, "A again: one stream opened");
		await tab.eval("window.ready.runtime.navigate('/a?again=1')");
		await tab.wait("location.search === '?again=1' && document.querySelector('.a .heard')?.textContent === 'resync'");
		await sleep(100);
		assert.equal(site.live.connects.length, 2, "A to A: the same channels, no stream opened again");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("200 navigations leave no allocation behind", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		// Chrome ignores more than 200 changes of the history in 10 s: the entries stay as they are.
		await tab.eval("history.pushState = history.replaceState = () => {}");
		const round = (n) => tab.eval(`(async () => { const runtime = window.ready.runtime; for (let i = 0; i < ${n}; i++) await runtime.navigate(i % 2 ? "/" : "/items/7"); return [runtime.live(), window.heard.filter((each) => each.startsWith("navigated")).length]; })()`);
		await round(2);
		const [before, was] = await round(2);
		const [after, now] = await round(200);
		assert.equal(now - was, 200, "200 navigations, each to its page");
		assert.equal(await tab.eval("document.querySelector('footer.at').textContent + ' ' + Boolean(document.querySelector('.home h1'))"), "/ true");
		assert.equal(after, before, "as many allocations live as before");
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("under a base (/rocx/, as GitHub Pages serves a project): a link navigates in place, the address under the base, where it is without it, the URLs the runtime writes under it; the page a load renders", { skip }, async () => {
	const site = await navSite({ base: "/rocx/" });
	try {
		const tab = await open(site, "/");
		site.asked.length = 0;
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.item h1')?.textContent === 'Item 7'");
		assert.equal(await kept(tab), true);
		assert.deepEqual([await tab.eval("location.pathname"), await tab.eval("document.querySelector('footer.at').textContent")], ["/rocx/items/7", "/items/7"]);
		assert.deepEqual(site.documents(), ["navigate /rocx/items/7"]);
		assert.equal(await tab.eval("document.querySelector('.to-a').getAttribute('href')"), "/rocx/a", "the runtime writes a link under the base");
		const navigated = await tab.eval(SNAPSHOT);
		const loaded = await browser.page();
		await loaded.beforeEachDocument(HEARD);
		await loaded.goto(`${site.url}/items/7`);
		await loaded.wait("window.ready", 5000);
		assert.equal(navigated, await loaded.eval(SNAPSHOT));
		await tab.click(".to-home");
		await tab.wait("document.querySelector('.home h1') && location.pathname === '/rocx/'");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await loaded.close();
		await tab.close();
	} finally {
		await site.close();
	}
});

// ---- Phase 3: prefetch and View Transitions ----

/** The middle of the element `selector` finds, where the pointer goes. */
const middle = (tab, selector) => tab.eval(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);

/** The pointer moved over the element `selector` finds, and left resting there. */
async function hover(tab, selector) {
	const { x, y } = await middle(tab, selector);
	await tab.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
}

test("prefetch: a link the pointer rests on, one the keyboard focuses and one touched are fetched ahead (x-rocx-navigate: preload), and a click then asks nothing more; one the pointer only passes isn't", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		site.asked.length = 0;
		await hover(tab, ".to-item");
		await hover(tab, ".skip");
		await sleep(150);
		assert.deepEqual(site.documents(), [], "passed over, under 65 ms: nothing");
		await hover(tab, ".to-a");
		await sleep(150);
		assert.deepEqual(site.documents(), ["preload /a"], "rested on: its page, prefetched");
		await tab.click(".to-a");
		await tab.wait("document.querySelector('.a h1')");
		assert.equal(await kept(tab), true);
		assert.deepEqual(site.documents(), ["preload /a"], "the click: one request, the prefetch's");
		await tab.eval("document.activeElement?.blur()");
		site.asked.length = 0;
		for (let presses = 0; presses < 12 && (await tab.eval("document.activeElement?.className")) !== "to-item"; presses++) await tab.press("Tab");
		await sleep(50);
		assert.ok(site.documents().includes("preload /items/7"), `focused by the keyboard: prefetched (${site.documents()})`);
		const { x, y } = await middle(tab, ".to-item-hash");
		await tab.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] });
		await tab.send("Input.dispatchTouchEvent", { type: "touchCancel", touchPoints: [] });
		await sleep(50);
		assert.ok(site.documents().includes("preload /items/8"), `touched: prefetched (${site.documents()})`);
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("prefetch: one older than 10 s (shortened here) is fetched again; a submission's result empties the cache", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		await tab.eval("window.ready.runtime.constructor.FRESH = 300");
		site.asked.length = 0;
		await hover(tab, ".to-a");
		await sleep(400);
		await tab.click(".to-a");
		await tab.wait("document.querySelector('.a h1')");
		assert.deepEqual(site.documents(), ["preload /a", "navigate /a"], "too old: asked again");
		await tab.eval("window.ready.runtime.constructor.FRESH = 10000");
		await tab.click(".to-home");
		await tab.wait("document.querySelector('.home h1')");
		site.asked.length = 0;
		await hover(tab, ".to-item");
		await sleep(150);
		assert.deepEqual(site.documents(), ["preload /items/7"]);
		await tab.click(".poke");
		await tab.wait("window.ready.runtime.pages.size === 0");
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.item h1')");
		assert.deepEqual(site.documents(), ["preload /items/7", "navigate /items/7"], "the data changed: its page asked again");
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("prefetch: data-rocx-preload=\"off\" on a link, or on <html> for the app, never; \"viewport\" as the link comes into sight, once", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		await sleep(100);
		assert.deepEqual(site.documents(), ["load /"], "the link below the fold, not in sight: not yet");
		site.asked.length = 0;
		await hover(tab, ".to-a-off");
		await sleep(150);
		assert.deepEqual(site.documents(), [], "off: not on hover");
		await tab.eval("document.documentElement.setAttribute('data-rocx-preload', 'off')");
		await hover(tab, ".to-item");
		await sleep(150);
		assert.deepEqual(site.documents(), [], "off for the app");
		// The pointer off the links, where scrolling brings none under it: back at the top, a link
		// it still rested on would be hovered again, and prefetched now that it may be.
		await hover(tab, ".home h1");
		await tab.eval("document.documentElement.removeAttribute('data-rocx-preload')");
		await tab.eval("document.querySelector('.to-seen').scrollIntoView()");
		await tab.wait("window.ready.runtime.pages.has(location.origin + '/items/5')");
		await tab.eval("window.scrollTo(0, 0)");
		await tab.eval("document.querySelector('.to-seen').scrollIntoView()");
		await sleep(100);
		assert.deepEqual(site.documents(), ["preload /items/5"], "seen: prefetched, once");
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("View Transitions: a navigation is one only when the app asks (<html data-rocx-transitions>) and the browser has them, never with less motion asked for", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/");
		await tab.eval("window.transitions = 0; window.playing = 0; const original = document.startViewTransition.bind(document); document.startViewTransition = (update) => { window.transitions++; window.playing++; const transition = original(update); const done = () => window.playing--; transition.finished.then(done, done); return transition; }");
		// A transition playing covers the page: the next click once it is over (its `finished`; its
		// animations start only after the new page is in, so none playing yet isn't enough: on a
		// slower machine a click went to the transition's overlay).
		const go = async (selector, check) => {
			await tab.wait("window.playing === 0 && document.getAnimations().length === 0");
			await tab.click(selector);
			await tab.wait(check);
			return tab.eval("window.transitions");
		};
		assert.equal(await go(".to-a", "document.querySelector('.a h1')"), 0, "not asked for");
		await tab.eval("document.documentElement.setAttribute('data-rocx-transitions', '')");
		assert.equal(await go(".to-item", "document.querySelector('.item h1')"), 1, "asked for: one");
		assert.equal(await tab.eval("document.title + ' ' + (window.mark === 'kept')"), "An item · Nav true");
		await tab.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
		assert.equal(await go(".to-home", "document.querySelector('.home h1')"), 1, "less motion asked for: none");
		await tab.send("Emulation.setEmulatedMedia", { features: [] });
		await tab.eval("window.kept = document.startViewTransition; document.startViewTransition = undefined");
		assert.equal(await go(".to-a", "document.querySelector('.a h1')"), 1, "a browser without them: none, and the page all the same");
		await tab.eval("document.startViewTransition = window.kept");
		assert.equal(await go(".to-home", "document.querySelector('.home h1')"), 2);
		// One navigation after another, the next starting before the last's animation is ready (both
		// documents kept, so nothing waits for the server): the last is skipped, its `ready` rejected
		// with an AbortError the runtime hears, and nothing is said.
		await tab.eval(`(async () => { const runtime = window.ready.runtime; await runtime.navigate("/a"); await runtime.navigate("/"); })()`);
		await tab.wait("document.querySelector('.home h1') && document.getAnimations().length === 0");
		assert.equal(await tab.eval("window.transitions"), 4);
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

// ---- Phase 2: kept levels, the query in place, <A>, <Navigate>, GET forms ----

/** What the page is made of, by identity: the shop's layout and the item page's article, as they
 * are now (a level kept is the same element; one made anew is another). */
const MARK = "window.levels = { shop: document.querySelector('.shop'), item: document.querySelector('.item-page') }";

test("kept levels (D-040, phase 2): a layout below the root is kept while its key (its file, its own params) is the same, its signal, a field's text and its region with it, and made anew when it changes; a page is made anew when its params change; links' aria-current follows (D-086); the page as a load renders it", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/shop/books/1");
		await tab.click(".shop-count");
		await tab.click(".item-count");
		await tab.wait("document.querySelector('.shop-count').textContent === 'Shop clicks 1' && document.querySelector('.item-count').textContent === 'Item clicks 1'");
		await tab.eval(`document.querySelector('.shop-input').value = 'kept text'; ${MARK}`);
		const active = "[...document.querySelectorAll('.shop-nav a')].map((a) => [a.className.replace(/rx-\\w+/, '').trim(), a.getAttribute('aria-current')])";
		assert.deepEqual(await tab.eval(active), [["shop-all", "true"], ["shop-one", "page"], ["shop-two", null], ["shop-games", null]], "a link where the page is: aria-current page; one to a path the page is under: true");
		site.asked.length = 0;
		await tab.click(".shop-two");
		await tab.wait("location.pathname === '/shop/books/2' && document.querySelector('.item-page h1')?.textContent === 'Item 2 of books'");
		assert.equal(await kept(tab), true);
		assert.deepEqual(site.documents(), ["navigate /shop/books/2"]);
		assert.deepEqual(
			await tab.eval("[window.levels.shop === document.querySelector('.shop'), window.levels.item === document.querySelector('.item-page'), document.querySelector('.shop-count').textContent, document.querySelector('.shop-input').value, document.querySelector('.item-count').textContent]"),
			[true, false, "Shop clicks 1", "kept text", "Item clicks 0"],
			"the shop's layout kept, its signal and the field's text with it; the page, with new params, made anew",
		);
		assert.deepEqual(await tab.eval(active), [["shop-all", "true"], ["shop-one", null], ["shop-two", "page"], ["shop-games", null]], "the marks follow the navigation (the kept layout's links marked again)");
		assert.deepEqual(await tab.eval("[document.querySelector('.shop-note').textContent, document.querySelector('.note').textContent, document.title]"), ["The shop's note, for books", "The layout's note, for An item in a shop", "An item in a shop · Nav"], "a kept level's regions are the document's; the root layout's title follows the page's meta");
		const navigated = await tab.eval(SNAPSHOT);
		const loaded = await browser.page();
		await loaded.beforeEachDocument(HEARD);
		await loaded.goto(`${site.url}/shop/books/2`);
		await loaded.wait("window.ready", 5000);
		// The layout's counter is its own, kept (1), where a load starts it at 0.
		const fresh = (html) => html.replace("Shop clicks 1", "Shop clicks 0");
		assert.equal(fresh(navigated), await loaded.eval(SNAPSHOT), "with its layouts kept, the page a load renders, byte for byte outside the host's elements (but for the kept layout's own state)");
		await loaded.close();
		// Another shop: the layout's own param changes, so it is made anew, its region the new one's.
		await tab.eval(MARK);
		await tab.click(".shop-games");
		await tab.wait("location.pathname === '/shop/games/1' && document.querySelector('.shop').dataset.cat === 'games'");
		assert.deepEqual(
			await tab.eval("[window.levels.shop === document.querySelector('.shop'), document.querySelector('.shop-count').textContent, document.querySelector('.shop-input').value, document.querySelector('.shop-note').textContent]"),
			[false, "Shop clicks 0", "", "The shop's note, for games"],
		);
		await tab.click(".shop-all");
		await tab.wait("location.pathname === '/shop/games' && document.querySelector('.front h1')?.textContent === 'All of games'");
		assert.deepEqual(await tab.eval(active), [["shop-all", "page"], ["shop-one", null], ["shop-two", null], ["shop-games", null]], "at the link's own path: page");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console.filter((entry) => entry.type === "warning" || entry.type === "error"), []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("the query in place (§7): set! merges into it and \"\" takes a name out, an entry pushed (set_with!'s replace replaces it); no document fetched, the page and its layouts kept, only what read the query reads again; back and forward between such entries in place too", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/shop/books/1?size=s");
		await tab.click(".item-count");
		await tab.wait("document.querySelector('.item-count').textContent === 'Item clicks 1'");
		await tab.eval(`window.entries = history.length; ${MARK}`);
		const page = "[location.search, document.querySelector('.color').textContent, document.querySelector('.query').textContent, document.querySelector('.color-said').textContent, document.querySelector('.item-count').textContent, window.levels.item === document.querySelector('.item-page'), window.levels.shop === document.querySelector('.shop')]";
		const reads = () => site.asked.map(({ url }) => url).filter((url) => !url.includes("/rocx/live"));
		site.asked.length = 0;
		await tab.click(".to-red");
		await tab.wait("document.querySelector('.color-said').textContent === 'Said: color-red'");
		assert.deepEqual(await tab.eval(page), ["?size=s&color=red", "red", "size=s&color=red", "Said: color-red", "Item clicks 1", true, true], "merged, the page kept");
		assert.deepEqual(reads(), ["/api/say/color-red"], "no document: only the read whose URL changed");
		assert.equal(await tab.eval("history.length - window.entries"), 1, "an entry pushed");
		await tab.click(".to-size");
		await tab.wait("location.search === '?size=m&color=red'");
		assert.equal(await tab.eval("history.length - window.entries"), 1, "set_with!'s replace: the entry replaced");
		await tab.click(".to-plain");
		await tab.wait("document.querySelector('.color').textContent === 'none' && document.querySelector('.color-said').textContent === 'Said: color-none'");
		assert.deepEqual(await tab.eval(page), ["?size=m", "none", "size=m", "Said: color-none", "Item clicks 1", true, true], "\"\" takes the name out");
		await tab.eval("history.back()");
		await tab.wait("location.search === '?size=m&color=red' && document.querySelector('.color').textContent === 'red'");
		assert.deepEqual((await tab.eval(page)).slice(4), ["Item clicks 1", true, true], "back: in place too");
		assert.deepEqual(site.documents(), [], "no document asked all along");
		assert.equal(await kept(tab), true);
		// A link to another query of the page, likewise (a plain <a href="?…">).
		await tab.eval("const link = document.createElement('a'); link.className = 'to-green'; link.textContent = 'Green'; link.href = '?color=green'; document.querySelector('.item-page').append(link)");
		await tab.click(".to-green");
		await tab.wait("location.search === '?color=green' && document.querySelector('.color').textContent === 'green'");
		assert.deepEqual(site.documents(), []);
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("a layout that read where it is once, in its body, is made anew by each navigation (§4.3), and the runtime says which; a query change under it fetches the document", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/once/1");
		await tab.click(".once-count");
		await tab.wait("document.querySelector('.once-count').textContent === 'Once clicks 1'");
		await tab.eval("window.remade = []; window.ready.runtime.observer = { remade: ({ level }) => window.remade.push(level) }");
		site.asked.length = 0;
		await tab.click(".once-next");
		await tab.wait("location.pathname === '/once/2' && document.querySelector('.once-n').textContent === 'Once 2'");
		assert.equal(await kept(tab), true);
		assert.deepEqual(await tab.eval("[document.querySelector('.once-path').textContent, document.querySelector('.once-count').textContent, window.remade]"), ["/once/2", "Once clicks 0", ["routes/once/+layout.rocx"]], "made anew, so what it shows is where it is now");
		assert.deepEqual(site.documents(), ["navigate /once/2"]);
		site.asked.length = 0;
		await tab.eval("window.ready.runtime.navigate('?x=1')");
		await tab.wait("location.search === '?x=1' && window.remade.length === 2");
		assert.deepEqual(site.documents(), ["navigate /once/2?x=1"], "a level to make anew: the page's document fetched for it");
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("<Navigate> sends the visitor elsewhere as the page renders: in the browser, a navigation that replaces its entry; a GET form navigates in place to its URL with its fields as the query", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/a");
		await tab.eval("window.entries = history.length");
		site.asked.length = 0;
		await tab.eval("window.ready.runtime.navigate('/away')");
		await tab.wait("location.pathname === '/a' && window.heard.includes('navigated /away') && window.heard.filter((each) => each === 'navigated /a').length === 1", 5000);
		assert.equal(await kept(tab), true);
		assert.deepEqual(site.documents(), ["navigate /away", "navigate /a"]);
		assert.equal(await tab.eval("history.length - window.entries"), 1, "/away's entry replaced by A's");
		await tab.eval("history.back()");
		await tab.wait("location.pathname === '/' || location.pathname === '/a'");
		// A GET form.
		const form = await open(site, "/shop/books/1");
		site.asked.length = 0;
		await form.click(".find-go");
		await form.wait("location.pathname === '/shop/books/2' && location.search === '?color=blue' && document.querySelector('.color').textContent === 'blue'");
		assert.equal(await kept(form), true, "in place");
		assert.deepEqual(site.documents(), ["navigate /shop/books/2?color=blue"]);
		assert.deepEqual(form.errors, []);
		await form.close();
		await tab.close();
	} finally {
		await site.close();
	}
});

test("which forms the runtime sends (D-095): one posting to a path the route table lists an endpoint at (a [param] any one segment), kept by its path; one an asked endpoint's, fields after it; under the site's base only; no other", () => {
	const runtime = Object.create(Runtime.prototype);
	Object.assign(runtime, { app: Runtime.routeTable(JSON.stringify({ pages: [], error: null, posts: ["/notes", "/items/[id]", "/"] })), actions: new Map([["/asked", 1]]), base: "/" });
	const saved = globalThis.location;
	globalThis.location = new URL("http://site.test/notes");
	try {
		const key = (href) => runtime.formKey(new URL(href, location.href));
		assert.equal(key("/notes"), "/notes");
		assert.equal(key(""), "/notes", "no action: the page's own URL, an endpoint's here");
		assert.equal(key("/items/3?star=yes"), "/items/3", "kept by its path: its query is fields (with_fields')");
		assert.equal(key("/items/3/more"), null);
		assert.equal(key("/"), "/");
		assert.equal(key("/asked?id=7"), "/asked", "an endpoint a component asks for, with fields after its URL");
		assert.equal(key("/nowhere"), null, "no endpoint there: the browser's");
		assert.equal(key("http://elsewhere.test/notes"), null, "another site's");
		assert.equal(key("/items/%E0%A4%A"), null, "a path that can't be decoded");
		runtime.base = "/rocx/";
		assert.equal(key("/rocx/notes"), "/notes", "under the site's base");
		assert.equal(key("/rocx"), "/", "the base itself");
		assert.equal(key("/notes"), null, "outside it");
		runtime.app = null;
		assert.equal(key("/rocx/notes"), null, "no route table (an app with no routes/): only what is asked for");
		assert.deepEqual(Runtime.routeTable('{"pages":[],"error":null}').posts, [], "a table written before D-095: no endpoints");
	} finally {
		globalThis.location = saved;
	}
});

test("a form to one of the app's endpoints is sent with fetch though no component reads its submissions (D-095): its result reads the page's reads again, its redirect is followed in place, a refusal is said in the console; a path with a param and fields in its query too; a form into a frame, and one to a path no endpoint has, are the browser's", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/notes");
		const reads = () => site.asked.filter(({ url }) => url === "/api/say/notes").length;
		// A result: sent by the runtime, the page stays, and what it read is read again.
		let before = reads();
		await tab.click(".fine button");
		await until(() => site.posted.length === 1);
		await until(() => reads() > before);
		assert.deepEqual(site.posted[0], { url: "/notes", body: "note=fine", submission: "1" });
		assert.equal(await kept(tab), true, "no load");
		assert.equal(await tab.eval("location.pathname"), "/notes");
		// A param in the endpoint's path, and fields in the form's URL (`with_fields`'s).
		before = reads();
		await tab.click(".item button");
		await until(() => site.posted.length === 2);
		await until(() => reads() > before);
		assert.deepEqual(site.posted[1], { url: "/items/3?star=yes", body: "note=starred", submission: "1" });
		assert.equal(await kept(tab), true);
		// A refusal nothing reads: nothing on the page, and the console says so.
		await tab.click(".refused button");
		await until(() => site.posted.length === 3);
		await until(() => tab.console.length > 0);
		assert.deepEqual(tab.console.map(({ type, text }) => [type, text]), [["warning", "rocx: POST /notes was refused (409: no more notes), and nothing on the page reads its submissions: use_submission! or use_submissions! shows it"]]);
		assert.equal(await kept(tab), true);
		// Into a frame: the browser's, with no x-rocx-submission.
		await tab.click(".framed button");
		await until(() => site.posted.length === 4);
		assert.deepEqual(site.posted[3], { url: "/notes", body: "note=framed", submission: null });
		assert.equal(await kept(tab), true, "the page stays: the frame took the answer");
		// A redirect of the endpoint's own: followed in place.
		await tab.click(".away button");
		await tab.wait("document.querySelector('.a h1') !== null", 5000);
		assert.equal(await tab.eval("location.pathname"), "/a");
		assert.equal(await kept(tab), true, "in place");
		assert.equal(site.posted[4].submission, "1");
		// A path no endpoint has: the browser posts it, and loads where it is sent.
		const other = await open(site, "/notes");
		await other.click(".elsewhere button");
		await other.wait("location.pathname === '/a' && window.ready !== undefined", 5000);
		assert.equal(await kept(other), false, "a load");
		assert.deepEqual(site.posted.at(-1), { url: "/nowhere", body: "note=nowhere", submission: null });
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(other.errors, []);
		await other.close();
		await tab.close();
	} finally {
		await site.close();
	}
});

/** How many `beforeunload` listeners the page has (the runtime's guard, `guardUnload`): every
 * document's `addEventListener` and `removeEventListener` counted. */
const UNLOAD_GUARDS = `
	window.unloadGuards = 0;
	const added = window.addEventListener, removed = window.removeEventListener;
	window.addEventListener = function (type, ...rest) { if (type === "beforeunload") window.unloadGuards++; return added.call(this, type, ...rest); };
	window.removeEventListener = function (type, ...rest) { if (type === "beforeunload") window.unloadGuards--; return removed.call(this, type, ...rest); };
`;

/** The editor's leaves heard (`nav.leave`), and its navigations. */
const leaves = (tab) => tab.eval("window.heard.filter((each) => each.startsWith('leave ') || each.startsWith('navigate '))");

test("use_before_leave!: a link and navigate! stopped while the draft is unsaved (the page and its address stay, nothing fetched), each listener told where it goes and whether one before stopped it; retry! later from the dialog, forced past a second listener, or asking again", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/editor");
		await tab.click(".draft");
		await tab.type(".draft", "Hello");
		await tab.wait("document.querySelector('.state').textContent === 'unsaved'");
		await tab.eval("window.entries = history.length");
		site.asked.length = 0;
		// A link: stopped, and the dialog has the leave.
		await tab.click(".to-a");
		await tab.wait("document.querySelector('.leaving')?.textContent === 'Leave for /a?'");
		assert.deepEqual(await leaves(tab), ["leave editor /a from /editor"], "the listener asked, before anything else");
		assert.deepEqual(await tab.eval("[location.pathname, history.length - window.entries, document.querySelector('.draft').value, document.querySelector('.progress').classList.contains('on')]"), ["/editor", 0, "Hello", false], "the page, its address and its history as they were, no navigation on its way");
		assert.deepEqual(site.documents().filter((each) => each.startsWith("navigate")), [], "no document fetched");
		// Discard: forced, the listener isn't asked again.
		await tab.click(".discard");
		await tab.wait("location.pathname === '/a' && document.querySelector('.a h1')");
		assert.equal(await kept(tab), true, "in place");
		assert.deepEqual(await leaves(tab), ["leave editor /a from /editor", "navigate /a"]);
		assert.equal(await tab.eval("history.length - window.entries"), 1, "its entry pushed, as the link's would have been");
		// The editor again (made anew: its draft empty), navigate! stopped.
		await tab.click(".to-editor");
		await tab.wait("document.querySelector('.editor h1') && document.querySelector('.state').textContent === 'saved'");
		await tab.eval("window.heard.length = 0");
		await tab.type(".draft", "Again");
		await tab.click(".go");
		await tab.wait("document.querySelector('.leaving')?.textContent === 'Leave for /a?'");
		assert.deepEqual(await leaves(tab), ["leave editor /a from /editor"]);
		// A second listener (the strict guard): asked after the editor's, told the editor stopped it.
		await tab.click(".strict");
		await tab.wait("document.querySelector('.strict-on')");
		await tab.click(".to-item");
		await tab.wait("document.querySelector('.leaving')?.textContent === 'Leave for /items/7?'");
		assert.deepEqual(await leaves(tab), ["leave editor /a from /editor", "leave editor /items/7 from /editor", "leave strict /items/7 from /editor after one stopped it"]);
		// Saved, then asked again: the editor lets it go, the strict guard doesn't.
		await tab.click(".save");
		await tab.wait("document.querySelector('.state').textContent === 'saved'");
		await tab.click(".again");
		await tab.wait("window.heard.length === 5");
		assert.deepEqual((await leaves(tab)).slice(3), ["leave editor /items/7 from /editor", "leave strict /items/7 from /editor"]);
		assert.equal(await tab.eval("location.pathname"), "/editor", "still stopped, by the strict guard");
		// Forced: past the strict guard, neither asked.
		await tab.click(".discard");
		await tab.wait("location.pathname === '/items/7' && document.querySelector('.item h1')");
		assert.deepEqual((await leaves(tab)).slice(5), ["navigate /items/7"]);
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("use_before_leave!: back stopped has the address go back where it was (the page never changed); retry! goes back again, forced; forward from a page with no listener isn't asked; forward stopped, and staying", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/a");
		await tab.click(".to-editor");
		await tab.wait("document.querySelector('.editor h1')");
		await tab.eval("window.entries = history.length; window.index = history.state.rocx.index; window.heard.length = 0");
		await tab.type(".draft", "Unsaved");
		await tab.wait("document.querySelector('.state').textContent === 'unsaved'");
		site.asked.length = 0;
		await tab.eval("history.back()");
		await tab.wait("document.querySelector('.leaving')?.textContent === 'Leave for /a?'");
		await tab.wait("location.pathname === '/editor'");
		await sleep(100);
		assert.deepEqual(await leaves(tab), ["leave editor /a from /editor -1"], "asked with how far it went");
		assert.deepEqual(await tab.eval("[location.pathname, history.length - window.entries, history.state.rocx.index - window.index, document.querySelector('.draft').value]"), ["/editor", 0, 0, "Unsaved"], "the address back on the editor's entry, the page as it was");
		assert.deepEqual(site.documents().filter((each) => each.startsWith("navigate")), [], "no document fetched");
		// Discard: back again, the listener not asked.
		await tab.click(".discard");
		await tab.wait("location.pathname === '/a' && document.querySelector('.a h1')");
		assert.equal(await kept(tab), true);
		assert.equal(await tab.eval("history.state.rocx.index - window.index"), -1, "on the entry before");
		assert.deepEqual(await leaves(tab), ["leave editor /a from /editor -1", "navigate /a"]);
		// Forward, to the editor: A has no listener.
		await tab.eval("history.forward()");
		await tab.wait("location.pathname === '/editor' && document.querySelector('.editor h1')");
		assert.deepEqual((await leaves(tab)).slice(2), ["navigate /editor"]);
		// Forward stopped too: from the editor (left saved, to an item), back to it, unsaved.
		await tab.click(".to-item");
		await tab.wait("location.pathname === '/items/7' && document.querySelector('.item h1')");
		await tab.eval("history.back()");
		await tab.wait("location.pathname === '/editor' && document.querySelector('.editor h1')");
		await tab.type(".draft", "More");
		await tab.wait("document.querySelector('.state').textContent === 'unsaved'");
		await tab.eval("window.heard.length = 0");
		await tab.eval("history.forward()");
		await tab.wait("document.querySelector('.leaving')?.textContent === 'Leave for /items/7?'");
		await tab.click(".stay");
		await tab.wait("!document.querySelector('.leaving')");
		await sleep(100);
		assert.deepEqual([await tab.eval("location.pathname"), await tab.eval("document.querySelector('.draft').value"), await leaves(tab)], ["/editor", "More", ["leave editor /items/7 from /editor 1"]], "stayed: the dialog closed, the address back where it was");
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("use_before_leave!: a listener goes with its owner (a component shown, then not; the page navigated from)", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await open(site, "/editor");
		await tab.click(".strict");
		await tab.wait("document.querySelector('.strict-on')");
		await tab.click(".to-a");
		await tab.wait("window.heard.length === 2");
		await sleep(100);
		assert.deepEqual(await leaves(tab), ["leave editor /a from /editor", "leave strict /a from /editor"], "the draft saved: only the strict guard stops it");
		assert.equal(await tab.eval("location.pathname"), "/editor");
		// The strict guard gone: its listener with it.
		await tab.click(".strict");
		await tab.wait("!document.querySelector('.strict-on')");
		await tab.click(".to-a");
		await tab.wait("location.pathname === '/a' && document.querySelector('.a h1')");
		// (The listener's Browser.call! runs after the flush, so after the navigation's start.)
		assert.deepEqual((await leaves(tab)).slice(2).sort(), ["leave editor /a from /editor", "navigate /a"], "the editor's asked, the strict guard's not");
		// The editor's page gone: its listener with it.
		await tab.click(".to-item");
		await tab.wait("location.pathname === '/items/7' && document.querySelector('.item h1')");
		assert.deepEqual((await leaves(tab)).slice(4), ["navigate /items/7"]);
		assert.equal(await tab.eval("window.ready.runtime.leaveListeners.size"), 0, "none left");
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});

test("use_before_leave!: the browser's beforeunload prompt is listened for only while a listener would stop a load (asked ahead, its writes dropped, again as what it read changes); a reload then asks the visitor", { skip }, async () => {
	const site = await navSite();
	try {
		const tab = await browser.page();
		await tab.beforeEachDocument(UNLOAD_GUARDS);
		await tab.beforeEachDocument(HEARD);
		await tab.goto(`${site.url}/editor`);
		await tab.wait("window.ready", 5000);
		await tab.eval("window.mark = 'kept'");
		/** Whether a beforeunload event now is stopped (the browser would ask). */
		const stops = () => tab.eval("!window.dispatchEvent(new Event('beforeunload', { cancelable: true }))");
		await sleep(50);
		assert.deepEqual([await tab.eval("window.unloadGuards"), await stops()], [0, false], "saved: no listener");
		await tab.click(".draft");
		await tab.type(".draft", "Hello");
		await tab.wait("window.unloadGuards === 1");
		assert.equal(await stops(), true, "unsaved: the prompt armed");
		assert.deepEqual(await leaves(tab), [], "asked ahead with its writes dropped: nothing told, no dialog");
		assert.equal(await tab.eval("document.querySelector('.leaving')"), null);
		// A reload: the browser asks (its own dialog), and staying keeps the page.
		const asked = tab.once("Page.javascriptDialogOpening", 5000);
		tab.send("Page.reload").catch(() => {});
		const dialog = await asked;
		assert.equal(dialog.type, "beforeunload");
		await tab.send("Page.handleJavaScriptDialog", { accept: false });
		await sleep(100);
		assert.deepEqual([await kept(tab), await tab.eval("document.querySelector('.draft').value")], [true, "Hello"], "stayed");
		// Saved: no listener again; typing arms it again.
		await tab.click(".save");
		await tab.wait("window.unloadGuards === 0");
		assert.equal(await stops(), false);
		await tab.type(".draft", "!");
		await tab.wait("window.unloadGuards === 1");
		// Left in place (discarded): the listener goes, and the prompt with it.
		await tab.click(".to-a");
		await tab.wait("document.querySelector('.leaving')");
		await tab.click(".discard");
		await tab.wait("location.pathname === '/a' && document.querySelector('.a h1')");
		await tab.wait("window.unloadGuards === 0");
		assert.equal(await stops(), false);
		assert.deepEqual(tab.errors, []);
		await tab.close();
	} finally {
		await site.close();
	}
});
