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
import { roc as findRoc, rocxBinary, zig } from "../../server/build.mjs";
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
	run(rocxBinary(), ["build", join(here, "nav"), "--client", join(out, "nav-client")]);
	mkdirSync(join(web, "platform", "targets", "wasm32"), { recursive: true });
	run(zig(), ["build-obj", join(web, "host", "host.zig"), "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fcompiler-rt", `-femit-bin=${join(web, "platform", "targets", "wasm32", "host.wasm")}`]);
	run(roc, ["build", "--target=wasm32", "--opt=dev", `--output=${join(out, "nav-server.wasm")}`, join(here, "nav", "nav_server.roc")]);
	run(roc, ["build", "--target=wasm32", "--opt=size", `--output=${join(out, "nav.wasm")}`, join(out, "nav-client", "main.roc")]);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The build's id, as rocx build wrote it in Root: every document's bootstrap says it. */
const BUILD = skip ? "" : /^\tbuild = "([0-9a-f]{8})"$/m.exec(readFileSync(join(here, "nav", "Generated", "Root.roc"), "utf8"))[1];

/** What the server says of a word (`GET /api/say/<word>`), as JSON. */
const said = (word) => ({ status: 200, body: JSON.stringify(`Said: ${word}`) });

/** The answers the server's reads got as it rendered the pages: `renderToString` answers each GET
 * from them, and records those a page asked for in its document. */
const ANSWERS = ["home", "a", ...Array.from({ length: 10 }, (_, n) => String(n))].map((word) => [`GET /api/say/${word}`, "", JSON.stringify(said(word))]);

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
 * promise, holds its answer until it settles.
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
	const site = { asked: [], rules: {}, held: {}, live: liveServer(), base, dir: join(dir, base) };
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
		if (at === "/api/leave") {
			await site.held[at];
			return { status: 200, headers: { "content-type": "application/json", "x-rocx-redirect": "/items/3" }, body: JSON.stringify("left") };
		}
		if (at === "/api/wait") {
			await sleep(150);
			return { status: 200, headers: { "content-type": "application/json" }, body: JSON.stringify("now") };
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
	/** The documents asked for (not files or reads), as a navigation (`x-rocx-navigate`) or a load. */
	site.documents = () => site.asked.filter(({ url }) => !/\/rocx\/(start\.js|runtime\.js|app\.wasm|live)|\/api\/|\.css$/.test(url)).map(({ url, navigate }) => `${navigate ? "navigate" : "load"} ${url}`);
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
 * `nav.item`); set before anything runs, in every document, with the page strict. */
const HEARD = `
	window.rocxStrict = true;
	window.heard = [];
	window.rocxEffects = { "nav.tick": ({ n }) => (window.ticks = n), "nav.item": ({ id }) => window.heard.push("item " + id) };
	document.addEventListener("rocx:ready", (event) => { window.ready = event.detail; });
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
		const navigated = await tab.eval(SNAPSHOT);
		// The same page, loaded.
		const loaded = await browser.page();
		await loaded.beforeEachDocument(HEARD);
		await loaded.goto(`${site.url}/a`);
		await loaded.wait("window.ready", 5000);
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
		assert.deepEqual(site.documents(), [], "nothing fetched");
		assert.deepEqual(await plain.eval("window.heard"), [], "not a navigation of the runtime's");
		await plain.eval("history.back()");
		await plain.wait("location.hash === ''");
		assert.equal(await kept(plain), true, "back from it: the browser's too");
		assert.deepEqual(site.documents(), []);
		// A path no page has: loaded, the app's 404 page.
		await plain.click(".to-nowhere");
		await plain.wait("location.pathname === '/nowhere' && window.mark === undefined && window.ready", 5000);
		assert.equal(await plain.eval("document.querySelector('.error h1').textContent"), "404");
		assert.deepEqual(site.documents(), ["load /nowhere"]);
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
