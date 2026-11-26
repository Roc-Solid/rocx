// The docs site, built and served by its server (site/main.roc, native), in a real browser: every
// page comes rendered by the server as the browser's build renders it (byte for byte, outside its
// <NoHydration>s), hydrates strictly without being rendered again or asking for anything, and each
// demo works when used the way a reader would; the static build (site/dist) is every page as the
// server answers it, and works as files alone, under /rocx/ as GitHub Pages serves it, with no
// server to ask. Needs the toolchain (`just setup`: Roc, Zig, Rust) and Chromium (see
// web/test/browser.mjs).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { cpus, loadavg, tmpdir } from "node:os";
import { join } from "node:path";
import { appWasm, build, clientStatic, nativePage, out, pageFile, prerender, roc, root, ROUTES, STATIC_GETS, startServer, underBase } from "../build.mjs";
import { hasRust } from "../../server/build.mjs";
import { platformReference, referenceBlocks as blocks, undocumented } from "../../rocx-cli/rocx.mjs";
import { exampleNames, factsFile as exampleFacts } from "../example-apps.mjs";
import { Runtime } from "../../web/runtime.js";
import { findChrome, launch } from "../../web/test/browser.mjs";
import { serve } from "../../web/test/serve.mjs";

let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)") || (!findChrome() && "no Chromium (set CHROME)");

let dir;
let site;
let browser;
/** This build's wasm, as it was built: the dev build's tests write their own over it. */
let wasm;

before(async () => {
	if (skip) return;
	dir = mkdtempSync(join(tmpdir(), "rocx-site-"));
	await build({ log: () => {} });
	wasm = readFileSync(appWasm);
	[sheet] = readdirSync(join(clientStatic, "rocx")).filter((name) => /^styles-[0-9a-f]{16}\.css$/.test(name));
	await prerender(dir);
	site = await startServer();
	browser = await launch();
});

after(async () => {
	await browser?.close();
	await site?.stop();
	if (dir) rmSync(dir, { recursive: true, force: true });
});

/** The app's stylesheet, as this build wrote it beside start.js: its file's name (`styles-<hash>.css`,
 * named by its content), which every page links. */
let sheet;

/** A tab that hydrates strictly: a page that isn't what the app renders throws, instead of being
 * rendered again with a warning. */
async function strictTab() {
	const tab = await browser.page();
	await tab.send("Page.enable");
	await tab.send("Page.addScriptToEvaluateOnNewDocument", { source: "window.rocxStrict = true;" });
	return tab;
}

/** Until the page is awake: hydrated, and site.js has its demos' inspectors watching. */
const AWAKE = "document.documentElement.hasAttribute('data-hydrated')";

/** A page, awake, strictly. */
async function open(path, url = site.url) {
	const page = await strictTab();
	await page.goto(`${url}${path}`);
	await page.wait(AWAKE);
	return page;
}

/** What a page loads besides itself: its stylesheets (the site's, and the app's: every <style>),
 * its icon and site.js, the audio plugin's script (the player, D-051), and start.js, the runtime
 * and the wasm (under `base`); anything else would be the page asking the server. */
const loads = (base = "/") => ["site.css", `rocx/${sheet}`, "favicon.svg", "site.js", "rocx/plugins/audio/audio.js", "rocx/start.js", "rocx/runtime.js", "rocx/app.wasm"].map((file) => `${base}${file}`);

/** The app's stylesheet in a page's head (under `base`): a file the browser keeps, not inline (D-040). */
const sheetLink = (base = "/") => `<link rel="stylesheet" href="${base}rocx/${sheet}">`;

/** The plugins' scripts every page the site's server renders loads (`renderToString({ scripts })`). */
const SCRIPTS = ["/rocx/plugins/audio/audio.js"];

/** What the page's player was asked to play (the audio plugin's script makes an `Audio` and plays
 * it), noted instead of played: each file's path, volume and rate. */
const LISTEN = `window.played = []; HTMLMediaElement.prototype.play = function () { window.played.push([new URL(this.src).pathname, this.volume, this.playbackRate]); return Promise.resolve(); }`;
const asked = (page) => page.eval("performance.getEntriesByType('resource').map((entry) => new URL(entry.name).pathname)");

const text = (page, selector) => page.eval(`document.querySelector(${JSON.stringify(selector)}).textContent.trim()`);

/**
 * In every document a tab loads, before the page's own scripts: strict, the runtime noted as it
 * wakes, and a snapshot of the page as each navigation in place (D-040) leaves it, taken as
 * `rocx:navigated` is dispatched (before site.js hears it): `<html>`, without the host's elements
 * (`[data-rocx]`: the bootstrap, the plugins' scripts, the runtime's title and announcer), the
 * answers and the flash a document carries, the comments of a text hole's server markup (`<!--x-->`,
 * which the browser doesn't make) and site.js's `data-hydrated`; and its title. `snapshotOf` takes
 * the same of a document the server sent, parsed.
 */
const NAVIGATED = `
	window.rocxStrict = true;
	document.addEventListener("rocx:ready", (event) => { window.runtime = event.detail.runtime; });
	window.snapshotOf = (doc) => {
		const copy = doc.documentElement.cloneNode(true);
		for (const gone of copy.querySelectorAll("[data-rocx], script.rocx-answers, script.rocx-flash")) gone.remove();
		copy.removeAttribute("data-hydrated");
		const walker = doc.createTreeWalker(copy, NodeFilter.SHOW_COMMENT);
		const comments = [];
		for (let node = walker.nextNode(); node; node = walker.nextNode()) if (node.data === "x" || node.data === "/x") comments.push(node);
		for (const node of comments) node.remove();
		copy.normalize();
		return { title: doc.title, html: copy.outerHTML };
	};
	document.addEventListener("rocx:navigated", () => { window.navigated = window.snapshotOf(document); });
`;

/**
 * Every page of the site, reached by navigating in place (from the one before it, starting at the
 * front page, at `url` + `base`), is the page a load renders: the page as the navigation left it is
 * the document it was rendered from, byte for byte outside the host's elements, its title the
 * document's; no load (the window is the same), nothing asked again (strictly), nothing said. The
 * layout is kept all along (D-040's levels: it reads where it is where that is used), so what is
 * compared is a kept layout, patched, beside the page made anew.
 */
async function navigatesLikeLoads(url, base = "") {
	const tab = await browser.page();
	await tab.send("Page.enable");
	await tab.send("Page.addScriptToEvaluateOnNewDocument", { source: NAVIGATED });
	await tab.goto(`${url}${base}/`);
	await tab.wait(AWAKE);
	await tab.eval("window.mark = 'kept'; window.footer = document.querySelector('body > footer.footer')");
	for (const route of ROUTES) {
		const result = await tab.eval(`(async () => {
			window.navigated = null;
			await window.runtime.navigate(${JSON.stringify(route)});
			const { text } = await window.runtime.pages.get(location.href.split("#")[0]).promise;
			return { mark: window.mark, kept: window.footer === document.querySelector('body > footer.footer'), at: location.pathname, navigated: window.navigated, loaded: window.snapshotOf(new DOMParser().parseFromString(text, "text/html")) };
		})()`);
		assert.equal(result.mark, "kept", `${route}: in place, no load`);
		assert.equal(result.kept, true, `${route}: the layout kept (D-040's levels): its footer the same element`);
		assert.equal(result.at, `${base}${route}`, `${route}: its address`);
		assert.equal(result.navigated?.title, result.loaded.title, `${route}: its title`);
		assert.equal(result.navigated.html, result.loaded.html, `${route}: navigated to, the page a load renders`);
	}
	assert.deepEqual(tab.errors, []);
	assert.deepEqual(tab.console, []);
	await tab.close();
}

/** The links written inside another link, which HTML doesn't allow: the browser closes the outer one
 * at the inner one, and what follows spills out of it (a card's text out of the card). */
function linksInLinks(html) {
	const found = [];
	let depth = 0;
	for (const tag of html.replace(/<!--[\s\S]*?-->/g, "").matchAll(/<(\/?)a\b([^>]*)>/gi)) {
		if (tag[1]) depth = Math.max(0, depth - 1);
		else {
			if (depth > 0) found.push(`<a${tag[2]}>`);
			depth++;
		}
	}
	return found;
}

test("every page renders, and hydrates strictly as the server left it, asking for nothing but app.wasm and what it loads", { skip }, async () => {
	for (const route of ROUTES) {
		// As a browser asks (accepting HTML).
		const response = await fetch(`${site.url}${route}`, { headers: { accept: "text/html" } });
		assert.equal(response.status, 200, route);
		const html = await response.text();
		assert.match(html, /^<!doctype html> <html lang="en" data-rocx-transitions>/, route);
		const head = html.slice(0, html.indexOf("</head>"));
		assert.ok(head.includes(sheetLink()), `${route}: the app's stylesheet, linked in its head`);
		assert.doesNotMatch(html, /<style>\/\* /, `${route}: and not inline`);
		// A card that is a link (Feature, PageCards) can't hold one: the browser ends the card at it.
		assert.deepEqual(linksInLinks(html), [], `${route}: no link inside a link`);
		if (route === "/") {
			// Roc Solid's front page is in no part of the docs: it has no sidebar.
			assert.doesNotMatch(html, /<nav class="sidebar[ "]/, "the front page has no sidebar");
		} else {
			assert.match(html, new RegExp(`<a class="current[^"]*" href="${route}" aria-current="page">`), `${route} is the current page in the sidebar`);
			// Each part of the docs has its own sidebar: rocx's pages, the platform's, the ecosystem's or the examples', one part only.
			const sidebar = /<nav class="sidebar[ "][\s\S]*?<\/nav>/.exec(html)[0];
			const under = (home) => route === home || route.startsWith(`${home}/`);
			const inPlatform = under("/platform");
			const inEcosystem = under("/ecosystem");
			const inExamples = under("/examples");
			assert.equal(sidebar.includes('href="/platform/server"'), inPlatform, `${route}: the platform's pages in its sidebar only on the platform's`);
			assert.equal(sidebar.includes('href="/ecosystem/charts"'), inEcosystem, `${route}: the ecosystem's pages in its sidebar only on the ecosystem's`);
			assert.equal(sidebar.includes('href="/examples"'), inExamples, `${route}: the examples' page in its sidebar only on the examples'`);
			assert.equal(sidebar.includes('href="/syntax"'), !inPlatform && !inEcosystem && !inExamples, `${route}: rocx's pages in its sidebar only on rocx's`);
		}
		const page = await open(route);
		// Strictly: markup that wasn't what the app renders would have thrown.
		assert.deepEqual(page.console, [], `${route} logged nothing`);
		assert.deepEqual(page.errors, [], `${route} threw nothing`);
		const fetched = await asked(page);
		assert.ok(fetched.includes("/rocx/app.wasm"), `${route}: every page fetches the wasm`);
		// The flock's birds are an image, and the example apps' pages have screenshots.
		assert.deepEqual(fetched.filter((path) => !loads().includes(path) && path !== "/roc-bird.svg" && !path.startsWith("/shots/")), [], `${route}: and asks for nothing else`);
	}
	const missing = await fetch(`${site.url}/nowhere`, { headers: { accept: "text/html" } });
	assert.equal(missing.status, 404);
	const notFound = await missing.text();
	assert.equal((notFound.match(/<ul class="page-cards[ "]/g) ?? []).length, 1, "the 404 lists the pages");
	assert.match(notFound, /<ul class="page-cards[ "][\s\S]*href="\/syntax"[\s\S]*<\/ul>/, "rocx's, for a path outside the platform's docs");
	const platformMissing = await (await fetch(`${site.url}/platform/nowhere`, { headers: { accept: "text/html" } })).text();
	assert.match(platformMissing, /<ul class="page-cards[ "](?:(?!<\/ul>)[\s\S])*href="\/platform\/database"/, "the platform's, for a path in them");
	assert.doesNotMatch(platformMissing, /<ul class="page-cards[ "](?:(?!<\/ul>)[\s\S])*href="\/syntax"/);
	const ecosystemMissing = await (await fetch(`${site.url}/ecosystem/nowhere`, { headers: { accept: "text/html" } })).text();
	assert.match(ecosystemMissing, /<ul class="page-cards[ "](?:(?!<\/ul>)[\s\S])*href="\/ecosystem\/charts"/, "the ecosystem's, for a path in them");
	assert.doesNotMatch(notFound, /class="pager-(previous|next)"/, "and offers no next page, being none of them");
});

// A part's sidebar is its pages in groups, each under its heading (site/Ui/Nav.roc): the platform's,
// the ecosystem's and the examples' in several, rocx's in one named after the part.
test("the sidebar's groups: each part's pages under its headings, every page of the part in one, the pager going on from one group to the next, and the ecosystem's overview carding its packages by the same groups", { skip }, async () => {
	const html = async (route) => (await fetch(`${site.url}${route}`, { headers: { accept: "text/html" } })).text();
	const groups = (page) => {
		const sidebar = /<nav class="sidebar[ "][\s\S]*?<\/nav>/.exec(page)[0];
		return [...sidebar.matchAll(/<div class="group[ "][\s\S]*?<\/ul>/g)].map(([group]) => ({
			name: /<p class="title[ "][^>]*>(?:<!--[^>]*-->)*([^<]*)</.exec(group)?.[1] ?? "",
			pages: [...group.matchAll(/href="([^"]+)"/g)].map(([, href]) => href),
		}));
	};
	const platform = groups(await html("/platform/actors"));
	assert.deepEqual(platform, [
		{ name: "Overview", pages: ["/platform", "/platform/server", "/platform/http", "/platform/live"] },
		{ name: "State", pages: ["/platform/database", "/platform/actors", "/platform/kv"] },
		{ name: "Other", pages: ["/platform/settings", "/platform/crypto", "/platform/browser", "/platform/reference"] },
	]);
	const ecosystem = groups(await html("/ecosystem/charts"));
	assert.deepEqual(ecosystem.map((group) => group.name), ["", "Pages", "Server", "Tools", "Monitoring"], "the overview under no heading, then the packages by where they work");
	assert.deepEqual(ecosystem[0].pages, ["/ecosystem"]);
	assert.deepEqual(groups(await html("/syntax")).map((group) => group.name), ["rocx"]);
	const examples = groups(await html("/examples"));
	assert.deepEqual(examples, [
		{ name: "Start", pages: ["/examples", "/examples/hello"] },
		{ name: "Apps", pages: ["/examples/tasks", "/examples/journal", "/examples/board", "/examples/quiz", "/examples/uptime", "/examples/notes", "/examples/pomodoro", "/examples/plate"] },
		{ name: "Benchmarks", pages: ["/examples/echo", "/examples/sqlite-vs-turso", "/examples/checkboxes", "/examples/js-framework-benchmark"] },
	]);
	// Each page of a part is in its sidebar once, and the sidebar names no page that isn't there.
	for (const [home, part] of [["/platform", platform], ["/ecosystem", ecosystem], ["/examples", examples]]) {
		const listed = part.flatMap((group) => group.pages);
		assert.deepEqual([...listed].sort(), ROUTES.filter((route) => route === home || route.startsWith(`${home}/`)).sort(), `${home}: every page in one group`);
	}
	// The pager goes through the groups in order: the last of one, then the first of the next.
	assert.match(await html("/platform/live"), /<a class="next[ "][^>]*href="\/platform\/database"/);
	assert.match(await html("/platform/kv"), /<a class="next[ "][^>]*href="\/platform\/settings"/);
	assert.match(await html("/ecosystem"), /<a class="next[ "][^>]*href="\/ecosystem\/charts"/);
	assert.match(await html("/examples/plate"), /<a class="next[ "][^>]*href="\/examples\/echo"/);
	// The ecosystem's overview: a heading for each group of packages, its cards under it.
	const overview = await html("/ecosystem");
	assert.deepEqual([...overview.matchAll(/<h3[^>]*>([^<]*)<\/h3>\s*<ul class="page-cards[ "]/g)].map(([, name]) => name), ["Pages", "Server", "Tools", "Monitoring"]);
	// The page that was "Settings and crypto" is two now.
	assert.equal((await fetch(`${site.url}/platform/secrets`, { headers: { accept: "text/html" } })).status, 404);
});

test("the counter counts, and resets", { skip }, async () => {
	const page = await open("/");
	assert.equal(await text(page, ".counter output"), "3");
	await page.click('.counter [aria-label="One more"]');
	await page.click('.counter [aria-label="One more"]');
	assert.equal(await text(page, ".counter output"), "5");
	await page.click(".counter .reset");
	assert.equal(await text(page, ".counter output"), "0");
	assert.equal(await page.eval("document.querySelector('.counter .reset').disabled"), true);
	await page.click('.counter [aria-label="One less"]');
	// Its own class, then its <style>'s (scoped to it), then the one a signal turned on.
	assert.match(await page.eval("document.querySelector('.counter').className"), /^counter rx-[0-9a-z]{6} negative$/);
	assert.equal(await page.eval("getComputedStyle(document.querySelector('.counter')).display"), "grid", "its <style> applies, from the page's head");
	assert.match(await text(page, '[data-stat="hydrated"]'), /^Awake \d+ ms/);
});

test("the to-do list adds, ticks, filters and removes, moving keyed rows", { skip }, async () => {
	const page = await open("/components");
	const items = () => page.eval("[...document.querySelectorAll('.todos li')].map((li) => li.textContent.replace('×', '').trim())");
	assert.deepEqual(await items(), ["Write the docs", "Build islands", "Ship it"]);
	await page.type(".todos input[type=text]", "Try rocx");
	assert.equal(await page.eval("document.querySelector('.todos button[type=submit]').disabled"), false);
	await page.press("Enter");
	assert.deepEqual(await items(), ["Write the docs", "Build islands", "Ship it", "Try rocx"]);
	assert.equal(await page.eval("document.querySelector('.todos input[type=text]').value"), "", "the draft is cleared");
	await page.click(".todos li:first-child input[type=checkbox]");
	assert.equal(await text(page, ".todos .left"), "2 items left");
	// Removing the first row removes its element; the others keep theirs.
	await page.eval("window.ship = [...document.querySelectorAll('.todos li')][2]");
	await page.click(".todos li:first-child .remove");
	assert.deepEqual(await items(), ["Build islands", "Ship it", "Try rocx"]);
	assert.equal(await page.eval("window.ship === [...document.querySelectorAll('.todos li')][1]"), true, "Ship it's row moved, not rewritten");
	assert.equal(await text(page, '[data-inspect-signals="todos"] li'), "click “×”dropped a row", "the row goes; nothing else changed");
	await page.click(".todos .filters button:nth-child(2)");
	assert.deepEqual(await items(), ["Ship it", "Try rocx"]);
	await page.click(".todos .filters button:nth-child(1)");
	assert.deepEqual(await items(), ["Build islands", "Ship it", "Try rocx"]);
	await page.type(".todos input[type=text]", "scratch");
	await page.press("Escape");
	assert.equal(await page.eval("document.querySelector('.todos input[type=text]').value"), "", "Escape clears the draft");
});

test("the shelf comes with its stock, and the bag, another demo, shows what goes in", { skip }, async () => {
	const html = await (await fetch(`${site.url}/components`)).text();
	assert.match(html, /<span class="shelf-name rx-\w+"><!--x-->rocx mug<!--\/x--><\/span>/, "the server renders the shelf with what GET /api/shelf answered");
	assert.match(html, /<p class="bag-title rx-\w+"><!--x-->Ada<!--\/x-->/, "and the bag with who is reading, GET /api/reader");
	assert.match(html, /class="rocx-answers">\[.*"GET \/api\/shelf"/, "the answers beside them, for the browser, under their URLs");
	assert.match(html, /class="rocx-answers">\[.*"GET \/api\/reader"/);
	const page = await open("/components");
	assert.equal(await page.eval("performance.getEntriesByType('resource').filter((entry) => entry.name.includes('/api/')).length"), 0, "the browser read the answers from the page");
	assert.equal(await page.eval("document.querySelectorAll('.shelf li').length"), 3);
	assert.equal(await text(page, ".bag-title"), "Ada's bag");
	assert.equal(await text(page, ".bag-total"), "0 things · 0 €");
	await page.click(".shelf li:nth-child(2) button");
	assert.deepEqual(await page.eval("[...document.querySelectorAll('.bag li')].map((li) => li.textContent)"), ["rocx mug"]);
	assert.equal(await text(page, ".bag-total"), "1 thing · 9 €");
	assert.equal(await text(page, ".shelf li:nth-child(2) button"), "In the bag");
	assert.equal(await page.eval("document.querySelector('.shelf li:nth-child(2) button').disabled"), true);
	await page.click(".shelf li:nth-child(1) button");
	assert.equal(await text(page, ".bag-total"), "2 things · 11 €");
	assert.match(await text(page, '[data-inspect-signals="bag"] li'), /^click “Put in the bag”, in the shelf/, "the shelf's click, as the bag saw it");
	await page.click(".bag button");
	assert.equal(await text(page, ".bag-empty"), "Nothing yet.");
	assert.equal(await page.eval("document.querySelectorAll('.shelf li.taken').length"), 0, "the shelf is shown the emptied bag");
	assert.deepEqual(page.errors, []);
});

test("endpoint reads: what the demos read as the pages render is an endpoint's GET, answered over HTTP too, as JSON in its types", { skip }, async () => {
	const json = async (path, headers = {}) => {
		const answered = await fetch(`${site.url}${path}`, { headers: { accept: "application/json", ...headers } });
		assert.equal(answered.status, 200, path);
		assert.equal(answered.headers.get("content-type"), "application/json", path);
		return answered.json();
	};
	assert.equal(await json("/api/echo/hi%20there"), "Echo: hi there", "a param, decoded");
	assert.deepEqual((await json("/api/shelf")).map((thing) => thing.name), ["Roc bird sticker", "rocx mug", "Lambda pin"]);
	assert.equal(await json("/api/reader"), "Ada");
	assert.deepEqual((await json("/api/planner")).map((plan) => `${plan.id}:${plan.day}`), ["standup:mon", "notes:mon", "review:tue", "dentist:wed", "demo:thu", "groceries:thu"], "the planner's week, with no cookie");
	assert.match(await json("/api/facts"), /^client_brotli=/m, "the layout's data, at a path of its own: the facts the default middleware hands on");
	const calls = await json("/api/calls");
	assert.deepEqual(calls.asked.map(({ method, status }) => `${method} ${status}`), ["GET 200", "POST 200", "POST 400", "POST 400"], "the calls page's data, at its path under /api");
	assert.equal(calls.shouted, "ROCX, 4 bytes");
	assert.equal((await fetch(`${site.url}/api/members`, { headers: { accept: "application/json" } })).status, 401, "the members' data, behind the page's middleware");
	assert.deepEqual(await json("/api/members", { cookie: "member=Ada%20L" }), { member: "Ada L" });
	const posted = await fetch(`${site.url}/api/echo/hi`, { method: "POST", body: "{}" });
	assert.equal(posted.status, 405);
	assert.equal(posted.headers.get("allow"), "GET");
	assert.equal((await fetch(`${site.url}/rocx/call/Demos/Echo.echo`, { method: "POST", body: '"hi"' })).status, 404, "no server functions are left");
});

test("the browser's app is built from a copy of the site in which an endpoint is its method and URL", { skip }, () => {
	const api = readFileSync(join(out, "client", "Generated", "Api.roc"), "utf8");
	assert.match(api, /^\tget_api_echo_message = \|params\| Endpoint\.remote\("GET", "\/api\/echo\/\$\{Server\.encode_segment\(params\.message\)\}"\)$/m);
	assert.doesNotMatch(api, /^import (Api|Calls|Members)\w*Server$/m, "what the handlers do is gone");
	assert.doesNotMatch(readFileSync(join(dir, "rocx", "app.wasm")).toString("latin1"), /Echo: \$/, "and isn't in the wasm");
});

test("the echo comes rendered with the server's answers, hydrates without asking, and a click asks nothing", { skip }, async () => {
	const html = await (await fetch(`${site.url}/calls`, { headers: { accept: "text/html" } })).text();
	assert.match(html, /<output class="echo-answer"><!--x-->Echo: the page, rendered on the server<!--\/x--><\/output>/, "rendered with GET /api/echo/… read on the server");
	const answers = html.slice(html.indexOf('<script type="application/json" class="rocx-answers">'));
	for (const message of ["the page, rendered on the server", "hello", "this site, as files"]) {
		assert.ok(answers.includes(`Echo: ${message}`), `and its answer to "${message}" beside it`);
	}
	const page = await open("/calls");
	const echo = "form.echo";
	await page.eval(`window.output = document.querySelector('${echo} output')`);
	const echoCalls = () =>
		page.eval("performance.getEntriesByType('resource').filter((entry) => new URL(entry.name).pathname.startsWith('/api/echo/')).map((entry) => entry.responseStatus)");
	assert.deepEqual(await echoCalls(), [], "the browser read the server's answers: no request");
	assert.equal(await text(page, `${echo} output`), "Echo: the page, rendered on the server");
	const woke = await text(page, '[data-inspect-signals="echo"] li');
	assert.match(woke, /^hydrated with the page in .* ms/);
	assert.ok(woke.includes("read GET /api/echo/hello from the page: not asked"), woke);
	const fetched = await page.eval("performance.getEntriesByType('resource').map((entry) => new URL(entry.name).pathname).filter((path) => path.endsWith('.wasm'))");
	assert.deepEqual(fetched, ["/rocx/app.wasm"], "the whole site, from one wasm");
	await page.click(`${echo} > button:nth-of-type(2)`);
	await page.wait(`document.querySelector('${echo} output').textContent === 'Echo: hello'`, 3000);
	assert.deepEqual(await echoCalls(), [], "a click reads an answer the page came with");
	assert.equal(await page.eval(`window.output === document.querySelector('${echo} output')`), true, "the server's node, patched");
	assert.deepEqual(await page.eval(`[...document.querySelectorAll('${echo} > button')].map((button) => button.getAttribute('aria-pressed'))`), ["false", "true", "false"]);
	assert.deepEqual(page.console, []);
	assert.deepEqual(page.errors, []);
});

test("Show and For come rendered, hydrate, and say what a click moved and patched", { skip }, async () => {
	const html = await (await fetch(`${site.url}/components`)).text();
	assert.match(html, /<div class="rx-\w+" data-demo="picks" data-flash="yes"><section class="picks rx-\w+">/, "rendered on the server, in its place");
	const page = await open("/components");
	const rows = (list) => page.eval(`[...document.querySelectorAll('.picks .${list} li')].map((li) => li.textContent)`);
	await page.eval("window.roc = document.querySelector('.picks .keyed li')");
	await page.eval("document.querySelector('.picks .reverse').click()");
	await page.wait("document.querySelector('.picks .first').textContent === 'First: Elm'");
	assert.deepEqual(await rows("keyed"), ["0: Elm", "1: Solid", "2: Roc"]);
	assert.deepEqual(await rows("unkeyed"), ["0: Elm", "1: Solid", "2: Roc"]);
	assert.equal(await page.eval("window.roc === document.querySelectorAll('.picks .keyed li')[2]"), true, "the server's row, moved");
	// Two keyed rows move; two indexes, two names by position and the first <Show>'s text change.
	assert.equal(await text(page, '[data-inspect-signals="picks"] li'), "click “Reverse”moved a row ×2patched text in <li> ×4patched text in <p>");
	assert.equal(await page.eval("document.querySelectorAll('.picks .signals-flash-moved').length"), 2, "the moved rows, outlined");
	assert.deepEqual(page.console, []);
	assert.deepEqual(page.errors, []);
});

test("the page is one app: the tally and the picks, far apart, share the store the page provides", { skip }, async () => {
	const html = await (await fetch(`${site.url}/components`)).text();
	assert.match(html, /<div class="rx-\w+" data-demo="tally" data-flash="yes"><aside class="tally rx-\w+"><p class="tally-count rx-\w+"><!--x-->3<!--\/x--> picks<\/p>/, "rendered from the store the page provided");
	assert.equal((html.match(/class="rocx-answers"/g) ?? []).length, 1, "one page's answers");
	const page = await open("/components");
	await page.eval("document.querySelector('.tally-add').click()");
	await page.wait("document.querySelectorAll('.picks .keyed li').length === 4");
	assert.equal(await text(page, ".picks .keyed li:last-child"), "3: Zig", "added by the tally, shown by the picks");
	await page.eval("document.querySelector('.picks .clear').click()");
	await page.wait("document.querySelector('.tally-count').textContent === '0 picks'");
	assert.equal(await text(page, ".tally-names"), "none yet");
	assert.match(await text(page, '[data-inspect-signals="tally"] li'), /^click “Clear”, in the picks/, "the tally's inspector says what the picks' click did to it");
	assert.deepEqual(page.console, []);
	assert.deepEqual(page.errors, []);
});

test("endpoints: a route's +server.rocx answers its methods over HTTP, as JSON, a refusal as its status", { skip }, async () => {
	const ask = async (method, path, body, headers = {}) => {
		const response = await fetch(`${site.url}${path}`, { method, body, headers });
		return { status: response.status, type: response.headers.get("content-type"), allow: response.headers.get("allow"), body: await response.text() };
	};
	const got = await ask("GET", "/api/shout/rocx");
	assert.equal(got.status, 200);
	assert.equal(got.type, "application/json");
	assert.deepEqual(JSON.parse(got.body), { word: "rocx", shouted: "ROCX", bytes: 4 });
	assert.deepEqual(JSON.parse((await ask("GET", `/api/shout/${encodeURIComponent("zażółć")}`)).body).shouted, "ZAżółć", "the param, decoded");
	const json = { "content-type": "application/json" };
	assert.deepEqual(await ask("POST", "/api/shout", '"hi"', json), { status: 200, type: "application/json", allow: null, body: '"HI"' });
	assert.deepEqual(await ask("POST", "/api/shout", '""', json), { status: 400, type: "text/plain; charset=utf-8", allow: null, body: "say something to shout" }, "a refusal, as its status");
	assert.equal((await ask("POST", "/api/shout", "{", json)).status, 400, "a body that isn't JSON");
	assert.equal((await ask("POST", "/api/shout", '"hi"')).status, 415, "JSON that doesn't say so (fetch sends text/plain) isn't read");
	const wrong = await ask("DELETE", "/api/shout");
	assert.equal(wrong.status, 405);
	assert.equal(wrong.allow, "POST");
	assert.equal((await ask("POST", "/api/shout", '"hi"', { origin: "https://elsewhere.example" })).status, 403, "from another site's page");
	assert.equal((await ask("GET", "/api/nothing")).status, 404);
});

test("endpoints: GET /openapi.json is their OpenAPI document, each schema its type's, written down or inferred", { skip }, async () => {
	const response = await fetch(`${site.url}/openapi.json`);
	assert.equal(response.status, 200);
	assert.equal(response.headers.get("content-type"), "application/json");
	const doc = await response.json();
	assert.equal(doc.openapi, "3.2.0");
	assert.deepEqual(Object.keys(doc.paths).sort(), ["/api/calls", "/api/count/{to}", "/api/echo/{message}", "/api/facts", "/api/members", "/api/members/join", "/api/members/leave", "/api/planner", "/api/planner/move", "/api/reader", "/api/shelf", "/api/shout", "/api/shout/{word}"]);
	const answer = (operation) => operation.responses["200"].content["application/json"].schema;
	const word = { type: "object", properties: { bytes: { type: "integer", minimum: 0 }, shouted: { type: "string" }, word: { type: "string" } }, required: ["bytes", "shouted", "word"] };
	assert.deepEqual(answer(doc.paths["/api/shout/{word}"].get), word, "a handler with no annotation: its inferred type");
	assert.deepEqual(doc.paths["/api/shout"].post.requestBody.content["application/json"].schema, { type: "string" });
	assert.deepEqual(doc.paths["/api/members/join"].post.requestBody.content["application/json"].schema, { type: "object", properties: { name: { type: "string" } }, required: ["name"] });
	// A body a form has is listed as a form's too (D-054): URL-encoded and multipart, the same schema.
	const joined = doc.paths["/api/members/join"].post.requestBody.content;
	assert.deepEqual(Object.keys(joined), ["application/json", "application/x-www-form-urlencoded", "multipart/form-data"]);
	assert.deepEqual(joined["application/x-www-form-urlencoded"].schema, joined["application/json"].schema);
	assert.deepEqual(Object.keys(doc.paths["/api/shout"].post.requestBody.content), ["application/json"], "a string isn't a form's body");
	assert.deepEqual(doc.paths["/api/count/{to}"].parameters, [{ name: "to", in: "path", required: true, schema: { type: "integer", minimum: 0 } }], "its param's type, U64 (D-092)");
	assert.deepEqual(doc.paths["/api/shout/{word}"].parameters, [{ name: "word", in: "path", required: true, schema: { type: "string" } }]);
	const events = doc.paths["/api/count/{to}"].get.responses["200"].content["text/event-stream"].itemSchema.oneOf;
	assert.deepEqual(events[0].properties.data.contentSchema.required, ["count", "of", "square"], "each event's data");
	assert.deepEqual(events[1].properties.event, { const: "end" });
	assert.match(doc.paths["/api/shout"].post.description, /what it is sent, shouted/, "the handler's comment");
	assert.equal(doc.paths["/api/shout"].post.summary, "What it is sent, shouted.", "its first sentence, the summary Swagger UI and Scalar list it by");
	assert.equal((await fetch(`${site.url}/openapi.json`, { method: "DELETE" })).status, 405);
	// The site serves a page to read it in too (`Page(Swagger)`): Swagger UI, pinned and checked, the
	// document beside it, and no validator.
	const page = await fetch(`${site.url}/openapi.html`);
	assert.equal(page.status, 200);
	assert.equal(page.headers.get("content-type"), "text/html; charset=utf-8");
	const html = await page.text();
	assert.match(html, /<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/swagger-ui-dist@[0-9.]+\/swagger-ui-bundle\.js" integrity="sha384-[A-Za-z0-9+\/=]+" crossorigin="anonymous"><\/script>/);
	assert.match(html, /SwaggerUIBundle\(\{ url: "openapi\.json", dom_id: "#swagger-ui", validatorUrl: null \}\)/);
});

test("middleware: the site's default around every answer; a route's own guards it and hands on who is asking", { skip }, async () => {
	const ask = async (method, path, { body, headers = {} } = {}) => {
		const response = await fetch(`${site.url}${path}`, { method, body, headers, redirect: "manual" });
		return { status: response.status, location: response.headers.get("location"), cookie: response.headers.get("set-cookie"), sniff: response.headers.get("x-content-type-options"), body: await response.text() };
	};
	const html = { accept: "text/html" };
	// Not a member: a browser is sent to join, a script refused.
	assert.deepEqual([(await ask("GET", "/members", { headers: html })).status, (await ask("GET", "/members", { headers: html })).location], [303, "/members/join"]);
	const refused = await ask("GET", "/api/members", { headers: { accept: "application/json" } });
	assert.equal(refused.status, 401);
	assert.match(refused.body, /members only/);
	assert.equal(refused.sniff, "nosniff", "the default middleware's headers, on a refusal too");
	assert.equal((await ask("GET", "/members/join", { headers: html })).status, 200);
	// Joining: the form's POST sets the cookie and sends you on; a name that is only spaces is refused.
	const form = { "content-type": "application/x-www-form-urlencoded", origin: site.url };
	const joined = await ask("POST", "/api/members/join", { body: "name=Ada+L", headers: form });
	assert.deepEqual([joined.status, joined.location], [303, "/members"]);
	assert.match(joined.cookie, /^member=Ada%20L; Path=\/; HttpOnly; SameSite=Lax/);
	assert.equal((await ask("POST", "/api/members/join", { body: "name=+", headers: form })).status, 400);
	assert.equal((await ask("POST", "/api/members/join", { body: "name=Eve", headers: { ...form, origin: "https://elsewhere.example" } })).status, 403, "the default middleware: another site's form");
	// A member: the page and the endpoint are given the name the middleware read.
	const member = { cookie: "member=Ada%20L" };
	const page = await ask("GET", "/members", { headers: { ...html, ...member } });
	assert.equal(page.status, 200);
	assert.match(page.body, /<h1[^>]*>Welcome, Ada L<\/h1>/);
	assert.deepEqual(JSON.parse((await ask("GET", "/api/members", { headers: member })).body), { member: "Ada L" });
	assert.equal((await ask("GET", "/members/join", { headers: { ...html, ...member } })).location, "/members", "a member isn't sent to join");
	const left = await ask("POST", "/api/members/leave", { headers: { ...form, ...member } });
	assert.deepEqual([left.status, left.location], [303, "/members/join"]);
	assert.match(left.cookie, /^member=; Path=\/; HttpOnly; SameSite=Lax; Max-Age=0/);
});

test("joining, in a browser (D-095): the form is sent with fetch; a name of spaces is refused under it, what was typed kept, with no load; a name sets the cookie and goes on to the members' page in place; Leave comes back", { skip }, async () => {
	const tab = await open("/members/join");
	await tab.eval("window.mark = 'kept'");
	await tab.type(".join input", "   ");
	await tab.click(".join button");
	await tab.wait("document.querySelector('.problem')?.textContent.includes('a member has a name')", 5000);
	assert.equal(await tab.eval("document.querySelector('.join input').value"), "   ", "what was typed, from the submission");
	assert.equal(await tab.eval("window.mark"), "kept", "no load");
	await tab.eval("document.querySelector('.join input').value = ''");
	await tab.type(".join input", "Ada L");
	await tab.click(".join button");
	await tab.wait("location.pathname === '/members' && document.querySelector('h1')?.textContent === 'Welcome, Ada L'", 5000);
	assert.equal(await tab.eval("window.mark"), "kept", "in place");
	// Sent as its button would send it, without a pointer the page's transition may be in front of.
	await tab.eval("document.querySelector('main form').requestSubmit()");
	// The joining page, which a member would be sent on from: the cookie is gone.
	await tab.wait("location.pathname === '/members/join' && document.querySelector('.join') !== null", 5000);
	assert.equal(await tab.eval("window.mark"), "kept");
	assert.deepEqual(tab.errors, []);
	await tab.close();
});

test("middleware, in the server built with --opt=speed as the site ships: every step of each chain runs, and every guarded route refuses", { skip }, async () => {
	// Under --opt=speed, the pinned compiler drops the last step of a chain of three or more effectful
	// closures composed with `then` (test/compiler-bugs/middleware-skipped-opt-speed). The site's
	// chains are two steps at most: its default (same_origin, then headers) around every request, and
	// a route's own inside it. This checks each step ran, in the optimized server every test here uses.
	assert.equal(process.env.ROC_OPT ?? "speed", "speed", "the site's server is built with --opt=speed");
	const headersOf = (response) => ({ sniff: response.headers.get("x-content-type-options"), referrer: response.headers.get("referrer-policy") });
	const both = { sniff: "nosniff", referrer: "same-origin" };
	for (const path of ["/", "/api/shout/rocx", "/nowhere", "/openapi.json"]) assert.deepEqual(headersOf(await fetch(`${site.url}${path}`)), both, `${path}: the default's last step`);
	const elsewhere = await fetch(`${site.url}/api/shout`, { method: "POST", body: '"hi"', headers: { "content-type": "application/json", origin: "https://elsewhere.example" } });
	assert.equal(elsewhere.status, 403, "its first step: another site's page is refused, before the second");
	// An endpoint behind the default alone: given the context it hands on (the build's facts).
	const facts = await fetch(`${site.url}/api/facts`, { headers: { accept: "application/json" } });
	assert.equal(facts.status, 200);
	assert.match(await facts.json(), /^client_brotli=/m);
	assert.deepEqual(headersOf(facts), both);
	// The members' page and its endpoint: behind the route's middleware too.
	const refused = await fetch(`${site.url}/api/members`, { headers: { accept: "application/json" } });
	assert.equal(refused.status, 401, "GET /api/members, without the cookie");
	assert.deepEqual(headersOf(refused), both, "GET /api/members: the default's steps around the route's");
	const member = await fetch(`${site.url}/api/members`, { headers: { accept: "application/json", cookie: "member=Ada%20L" } });
	assert.equal(member.status, 200);
	assert.deepEqual(await member.json(), { member: "Ada L" }, "the name the route's middleware handed on");
	assert.deepEqual(headersOf(member), both);
	// The page reads it as it renders, with the page's cookie: the same name.
	const page = await (await fetch(`${site.url}/members`, { headers: { accept: "text/html", cookie: "member=Ada%20L" } })).text();
	assert.match(page, /Welcome, Ada L/);
	const sent = await fetch(`${site.url}/members/join`, { headers: { accept: "text/html", cookie: "member=Ada%20L" }, redirect: "manual" });
	assert.deepEqual([sent.status, sent.headers.get("location")], [303, "/members"], "the joining page's own: a member is sent on");
});

test("events: an endpoint streams them as it makes them, and lets go of a page that goes", { skip }, async () => {
	const listen = (path) => fetch(`${site.url}${path}`, { headers: { accept: "text/event-stream" } });
	const started = performance.now();
	const response = await listen("/api/count/3");
	assert.equal(response.status, 200);
	assert.equal(response.headers.get("content-type"), "text/event-stream");
	const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
	const first = await reader.read();
	assert.equal(first.value, 'data: {"count":1,"of":3,"square":1}\n\n', "the first event, sent before the rest is made");
	let rest = "";
	for (let read = await reader.read(); !read.done; read = await reader.read()) rest += read.value;
	assert.equal(rest, 'data: {"count":2,"of":3,"square":4}\n\ndata: {"count":3,"of":3,"square":9}\n\nevent: end\ndata: \n\n');
	assert.ok(performance.now() - started >= 850, "300 ms apart, the end after the last");
	const refused = await listen("/api/count/21");
	assert.equal(refused.status, 400);
	assert.equal(await refused.text(), "count to a number from 1 to 20");
	// Its param is a U64 (D-092): a part that isn't one is no route, a 404, and the handler never runs.
	const unread = await listen("/api/count/five");
	assert.equal(unread.status, 404);
	// A page that goes before the end: the server lets go of the stream, and keeps answering.
	const gone = new AbortController();
	const cut = await fetch(`${site.url}/api/count/20`, { headers: { accept: "text/event-stream" }, signal: gone.signal });
	await cut.body.getReader().read();
	gone.abort();
	assert.equal((await fetch(`${site.url}/api/shout/rocx`)).status, 200);
	// The count's component is code only: a copy of the site as files can't stream.
	assert.ok(!(await (await fetch(`${site.url}/calls`, { headers: { accept: "text/html" } })).text()).includes('class="count"'));
});

test("channels: two tabs join the lobby, each greeted by its on_open!; a wave in one is heard in both, and a hand it doesn't take is refused", { skip }, async () => {
	const [one, two] = [await open("/platform/live"), await open("/platform/live")];
	for (const page of [one, two]) {
		await page.click("[data-demo=lobby] .join");
		await page.wait("document.querySelector('[data-demo=lobby] .state')?.textContent.startsWith('In the lobby')", 5000);
		await page.wait("document.querySelector('[data-demo=lobby] .waves li')?.textContent.startsWith('👋 from the lobby, to tab ')", 5000);
	}
	await one.click("[data-demo=lobby] .wave:nth-child(2)");
	const tab = await one.eval("sessionStorage.getItem('rocx-tab').slice(0, 4)");
	for (const page of [one, two]) await page.wait(`[...document.querySelectorAll('[data-demo=lobby] .waves li')].some((li) => li.textContent === '🎉 from ${tab}')`, 5000);
	const refused = await fetch(`${site.url}/rocx/live/send?tab=t1`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify([{ channel: "/api/platform/live/lobby", message: { Wave: "🦆" } }]) });
	assert.deepEqual(await refused.json(), { refused: [{ index: 0, status: 400, why: "wave 👋, 🎉 or 🙌" }] });
	assert.equal((await fetch(`${site.url}/api/platform/live/lobby`)).status, 404, "a channel alone answers no HTTP");
	await two.click("[data-demo=lobby] .leave");
	await two.wait("document.querySelector('[data-demo=lobby] .join') !== null");
	assert.deepEqual([...one.errors, ...two.errors], []);
	assert.deepEqual([...one.console, ...two.console], []);
});

test("endpoints: a demo asks one through Api, and the page asked them as it rendered", { skip }, async () => {
	const page = await open("/calls");
	assert.match(await page.eval("document.querySelector('table.http').textContent"), /GET \/api\/shout\/rocx.*200.*"shouted":"ROCX"/s, "the answers the page got, rendered");
	assert.match(await page.eval("document.querySelector('table.http').textContent"), /POST \/api\/shout\s*""\s*400\s*say something to shout/, "the refusal too");
	await page.click(".shout button:nth-of-type(2)");
	await page.wait("document.querySelector('.shout output').textContent === 'HELLO: 5 bytes'");
	await page.click(".shout button:nth-of-type(1)");
	await page.wait("document.querySelector('.shout output').textContent === 'ROCX: 4 bytes'");
	assert.deepEqual(page.errors, []);
});

test("the planner: a plan dragged to another day moves at once and goes in, the server's week read again taking its place (kept across a reload); one moved with its menu too; the dentist, and a full day, refuse, and the plan goes back saying why", { skip }, async () => {
	const page = await open("/components");
	const plans = (day) => page.eval(`[...document.querySelectorAll('[data-demo=planner] .day[data-day=${day}] .plan:not([inert]) .title')].map((title) => title.textContent)`);
	const status = () => text(page, "[data-demo=planner] .status");
	assert.deepEqual(await plans("mon"), ["Team stand-up", "Release notes"]);
	assert.equal(await status(), "Every move is in.");
	// Dragged to Tuesday: there at once, while the endpoint takes its 800 ms; then in.
	await page.drag("[data-demo=planner] .day[data-day=mon] .plan:nth-child(2)", "[data-demo=planner] .day[data-day=tue]");
	await page.wait("document.querySelector('[data-demo=planner] .status').textContent === '1 move on its way…'", 2000);
	assert.deepEqual(await plans("tue"), ["Release notes", "Review the parser"]);
	assert.deepEqual(await plans("mon"), ["Team stand-up"]);
	await page.wait("document.querySelector('[data-demo=planner] .status').textContent === 'Every move is in.'", 5000);
	assert.deepEqual(await plans("tue"), ["Release notes", "Review the parser"], "the server's week, read again");
	// The week is the server's: a reload shows it, hydrated strictly.
	const again = await open("/components");
	assert.deepEqual(await again.eval("[...document.querySelectorAll('[data-demo=planner] .day[data-day=tue] .plan .title')].map((title) => title.textContent)"), ["Release notes", "Review the parser"]);
	assert.deepEqual(again.console, []);
	// Its menu moves one too (a keyboard's and a touch screen's way): Thursday is full then.
	await page.eval("(() => { const select = document.querySelector('[data-demo=planner] .day[data-day=mon] .plan select'); select.value = 'thu'; select.dispatchEvent(new Event('change', { bubbles: true })); })()");
	await page.wait("document.querySelector('[data-demo=planner] .status').textContent === 'Every move is in.'", 5000);
	assert.deepEqual(await plans("thu"), ["Team stand-up", "Demo day prep", "Groceries"]);
	await page.drag("[data-demo=planner] .day[data-day=tue] .plan:nth-child(1)", "[data-demo=planner] .day[data-day=thu]");
	await page.wait("document.querySelector('[data-demo=planner] .refused span')?.textContent === 'Thursday is full: three plans a day at most.'", 5000);
	assert.deepEqual(await plans("tue"), ["Release notes", "Review the parser"], "refused: back where it was");
	await page.click("[data-demo=planner] .refused button");
	await page.wait("document.querySelector('[data-demo=planner] .refused') === null");
	// The dentist doesn't move.
	await page.drag("[data-demo=planner] .day[data-day=wed] .plan", "[data-demo=planner] .day[data-day=mon]");
	await page.wait("document.querySelector('[data-demo=planner] .refused span')?.textContent.startsWith('The dentist won')", 5000);
	assert.deepEqual(await plans("wed"), ["Dentist, 9:30"]);
	assert.deepEqual(page.errors, []);
	assert.deepEqual(page.console, []);
});

test("the cheat sheet filters as you type", { skip }, async () => {
	const page = await open("/syntax");
	const rows = () => page.eval("document.querySelectorAll('.cheatsheet tbody tr').length");
	const all = await rows();
	assert.ok(all > 20);
	await page.type(".cheatsheet input", "class");
	assert.equal(await rows(), 1);
	await page.type(".cheatsheet input", "zzz");
	assert.equal(await rows(), 0);
	assert.match(await text(page, ".cheatsheet-count"), /nothing matches “classzzz”/);
	await page.eval("document.querySelector('.cheatsheet input').select()");
	await page.press("Backspace");
	assert.equal(await rows(), all);
});

test("the syntax tour: a small component adds and ticks books, its rows kept by key and its if switched", { skip }, async () => {
	const page = await open("/syntax");
	const titles = () => page.eval("[...document.querySelectorAll('.tour li')].map((li) => li.textContent.trim())");
	assert.deepEqual(await titles(), ["Dune", "Emma"]);
	assert.equal(await text(page, ".tour p"), "2 to read");
	// Enter adds a book: a new row, the others kept; nothing typed, nothing added.
	await page.eval("window.dune = document.querySelector('.tour li')");
	await page.click(".tour > input");
	await page.press("Enter");
	await page.type(".tour > input", "Persuasion");
	await page.press("Enter");
	await page.wait("document.querySelectorAll('.tour li').length === 3");
	assert.deepEqual(await titles(), ["Dune", "Emma", "Persuasion"]);
	assert.equal(await page.eval("window.dune === document.querySelector('.tour li')"), true, "the first row kept");
	assert.equal(await page.eval("document.querySelector('.tour > input').value"), "", "the field emptied");
	assert.equal(await text(page, ".tour p"), "3 to read");
	// Ticked off: the memo, then the if's other branch.
	await page.click(".tour li:nth-child(2) input");
	await page.wait("document.querySelector('.tour li:nth-child(2)').classList.contains('done')");
	assert.equal(await text(page, ".tour p"), "2 to read");
	for (const row of [1, 3]) await page.click(`.tour li:nth-child(${row}) input`);
	await page.wait("document.querySelector('.tour p')?.textContent.trim() === 'All read.'");
});

test("an example's card: the .rocx, and its switch shows the Roc rocx wrote in its place, with nothing hydrated", { skip }, async () => {
	const page = await open("/syntax");
	const shown = () => page.eval("[...document.querySelector('.example .sources').querySelectorAll('.rocx, .roc')].filter((part) => part.offsetParent !== null).map((part) => part.className.split(' ')[0])");
	assert.deepEqual(await shown(), ["rocx", "rocx"], "the file's name and its .rocx");
	assert.match(await text(page, ".example .sources > .rocx"), /view : \{ name : Str, link : Str \} -> Html[\s\S]*<p class="greeting">/);
	await page.click(".example .swap");
	assert.deepEqual(await shown(), ["roc", "roc"], "the Roc, under its title");
	assert.match(await text(page, ".example .sources > .roc"), /Html\.element\(/);
	await page.click(".example .swap");
	assert.deepEqual(await shown(), ["rocx", "rocx"], "and back");
	assert.equal(await page.eval("document.querySelectorAll('.example .swap input:checked').length"), 0, "the other examples' switches untouched");
});

test("the escape lab can't be broken", { skip }, async () => {
	const page = await open("/safety");
	const presets = await page.eval("[...document.querySelectorAll('.lab-presets button')].map((b) => b.textContent)");
	for (const [index] of presets.entries()) {
		await page.click(`.lab-presets button:nth-child(${index + 1})`);
		assert.equal(await page.eval("document.querySelectorAll('.lab-live *').length"), 1, `${presets[index]}: one element, the link`);
		const href = await page.eval("document.querySelector('.lab-live a').getAttribute('href')");
		assert.ok(!/^\s*java/i.test(href.replace(/\s/g, "")), `${presets[index]}: href ${href}`);
	}
	// Presets really change the demo: the harmless one's URL goes through as it is.
	await page.click(".lab-presets button:nth-child(5)");
	assert.equal(await page.eval("document.querySelector('.lab-live a').getAttribute('href')"), "https://www.roc-lang.org/?a=1&b=2");
	await page.click(".lab-presets button:nth-child(3)");
	assert.equal(await page.eval("document.querySelector('.lab-live a').getAttribute('href')"), "about:invalid#rocx-unsafe-url");
	assert.equal(await page.eval("document.querySelectorAll('.lab-fields input')[1].value"), " java\tscript:alert(1)");
	await page.eval("document.querySelector('.lab-fields input').select()");
	await page.type(".lab-fields input", '<img src=x onerror="window.pwned = 1">');
	assert.equal(await page.eval("document.querySelectorAll('.lab-live img').length"), 0);
	assert.equal(await page.eval("window.pwned"), undefined);
	assert.match(await text(page, ".lab-markup"), /&lt;img src=x onerror=&quot;window.pwned = 1&quot;&gt;/);
});

/** How many frames a demo ran in `ms` (the runtime's `frame`, as the page tells it: `rocx:frame`). */
async function frames(page, demo, ms) {
	await page.eval(`window.framed = 0; window.counting ??= document.addEventListener("rocx:frame", (e) => { if (e.detail.demo === ${JSON.stringify(demo)}) window.framed++; })`);
	await new Promise((resolve) => setTimeout(resolve, ms));
	return page.eval("window.framed");
}

test("snake: a click starts it, arrows steer without scrolling, Tab leaves, Space pauses time", { skip }, async () => {
	const page = await open("/showcase");
	assert.match(await text(page, ".board .board-title"), /Snake, in Roc/);
	assert.equal(await page.eval("Number(getComputedStyle(document.querySelector('.board-message')).zIndex) > Number(getComputedStyle(document.querySelector('.part.head')).zIndex)"), true, "the message is above the snake");
	assert.equal(await frames(page, "snake", 300), 0, "no frames while the game waits");
	await page.eval("window.head = document.querySelector('.part.head'); window.headX = window.head.style.getPropertyValue('--x')");
	await page.eval(`window.effects = []; document.addEventListener("rocx:effect", (e) => window.effects.push(e.detail))`);
	await page.eval(LISTEN);
	await page.click(".board");
	assert.equal(await page.eval("document.querySelector('.board-message')"), null, "playing: the message is gone");
	assert.equal(await page.eval("document.querySelector('.board').classList.contains('playing')"), true);
	assert.deepEqual(await page.eval("window.effects"), [{ demo: "snake", name: "audio.play", arg: { url: "/sounds/start.wav", volume: 1, rate: 1 } }], "starting plays its sound, once");
	await page.wait("window.played.length === 1");
	assert.deepEqual(await page.eval("window.played"), [["/sounds/start.wav", 1, 1]], "by the audio plugin's player");
	assert.equal(await page.eval("document.querySelector('sound-effect')"), null, "a sound is a call, not an element");
	const sound = await fetch(`${site.url}/sounds/start.wav`);
	assert.equal(sound.status, 200);
	assert.equal(sound.headers.get("content-type"), "audio/wav", "the native server serves sound files as sound");
	assert.ok((await frames(page, "snake", 300)) > 5, "frames while it runs");
	assert.equal(await page.eval("window.head === document.querySelector('.part.head')"), true, "the head is the same element, moved: a row per place");
	assert.notEqual(await page.eval("window.head.style.getPropertyValue('--x')"), await page.eval("window.headX"), "and it moved on");
	const scrolled = await page.eval("scrollY");
	await page.press("ArrowDown");
	await new Promise((resolve) => setTimeout(resolve, 400));
	assert.match(await page.eval("document.querySelector('.part.head').className"), /\bdown\b/);
	assert.equal(await page.eval("scrollY"), scrolled, "the arrow steered, and didn't scroll the page");
	await page.press(" ");
	assert.equal(await text(page, ".board .board-title"), "Paused");
	assert.equal(await frames(page, "snake", 300), 0, "paused: no frames");
	await page.press("Tab");
	assert.equal(await page.eval("document.activeElement.classList.contains('board')"), false, "Tab moved the focus on");
	// A level starts over, ready, at its speed: Easy, Medium and Hard keep one; Impossible speeds up.
	const level = async (name) => {
		await page.eval(`[...document.querySelectorAll('.snake-levels button')].find((b) => b.textContent.trim() === ${JSON.stringify(name)}).click()`);
		await page.wait(`document.querySelector('.snake-levels [aria-pressed="true"]')?.textContent.trim() === ${JSON.stringify(name)}`);
		return text(page, ".snake-stat:nth-child(4) b");
	};
	assert.equal(await level("Easy"), "5.0");
	assert.match(await text(page, ".board .board-title"), /Snake, in Roc/, "ready again");
	assert.equal(await level("Hard"), "10.0");
	assert.equal(await level("Impossible"), "10.0");
	assert.equal(await level("Medium"), "6.7");
});

test("timers: the stopwatch's interval stops with its clear!, the search waits for a pause, and the clock's goes with it", { skip }, async () => {
	const page = await open("/showcase");
	const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
	const timer = (n) => `.timers .timer:nth-child(${n})`;
	const number = async (selector) => Number.parseFloat(await text(page, selector));
	// The clock's interval runs from when the page wakes up; hidden, it stops: no tick is heard.
	await page.wait("Number.parseInt(document.querySelector('.timers .timer:nth-child(3) .timer-note:last-child').textContent) >= 1", 3000);
	await page.click(`${timer(3)} input[type=checkbox]`);
	assert.equal(await page.eval("document.querySelector('.timers .clock')"), null);
	const heard = await text(page, `${timer(3)} .timer-note:last-child`);
	await sleep(1200);
	assert.equal(await text(page, `${timer(3)} .timer-note:last-child`), heard, "no tick once the clock is gone");
	// The stopwatch: Start runs it, Stop clears its interval.
	assert.equal(await text(page, `${timer(1)} .timer-face b`), "0.0");
	await page.click(`${timer(1)} .timer-actions button`);
	await page.wait("Number.parseFloat(document.querySelector('.timers .timer-face b').textContent) >= 0.3", 3000);
	await page.click(`${timer(1)} .timer-actions button`);
	const stopped = await number(`${timer(1)} .timer-face b`);
	await sleep(300);
	assert.equal(await number(`${timer(1)} .timer-face b`), stopped, "stopped: its interval, cleared");
	// The search: keys quicker than the pause clear the last one's timeout, so it runs once.
	await page.type(`${timer(2)} input`, "s");
	await page.type(`${timer(2)} input`, "w");
	assert.equal(await text(page, `${timer(2)} .timer-note`), "Waiting for a pause in the typing…");
	await page.wait("document.querySelector('.timers .timer:nth-child(2) .timer-note').textContent.includes('“sw”')", 3000);
	assert.equal(await text(page, `${timer(2)} .timer-note:nth-of-type(2)`), "2 keys, 1 search");
	assert.deepEqual(await page.eval("[...document.querySelectorAll('.timer-birds li')].map((li) => li.textContent)"), ["swallow", "swan", "swift"]);
	assert.deepEqual(page.errors, []);
});

test("the flock flies, grows and shrinks by its buttons or a number typed, and stops when the sky is empty", { skip }, async () => {
	const page = await open("/showcase");
	const birds = () => page.eval("document.querySelectorAll('.bird').length");
	const field = () => page.eval("document.querySelector('.flock-count').value");
	assert.equal(await birds(), 4);
	assert.equal(await field(), "4");
	const before = await page.eval("[...document.querySelectorAll('.bird')].map((b) => b.getAttribute('style'))");
	const flying = await frames(page, "birds", 300);
	assert.ok(flying > 5, "a frame at a time");
	assert.ok(flying < 100, `one run a frame, not more (${flying} in 300 ms)`);
	const after = await page.eval("[...document.querySelectorAll('.bird')].map((b) => b.getAttribute('style'))");
	assert.ok(before.every((style, i) => style !== after[i]), "every bird moved");
	await page.eval("window.first = document.querySelector('.bird')");
	await page.eval(`window.effects = []; document.addEventListener("rocx:effect", (e) => window.effects.push(e.detail))`);
	await page.click('[aria-label="One more bird"]');
	assert.equal(await birds(), 5);
	assert.equal(await page.eval("window.first === document.querySelector('.bird')"), true, "the others kept their elements");
	const pops = await page.eval("window.effects.filter((e) => e.arg.url === '/sounds/pop.wav')");
	assert.equal(pops.length, 1, "a bird more pops");
	assert.ok(Math.abs(pops[0].arg.rate - 520 / 440) < 1e-9, `at its pitch: 520 Hz, pop.wav played at ${pops[0].arg.rate}`);
	await page.click('[aria-label="Five more birds"]');
	assert.equal(await birds(), 10);
	assert.equal(await field(), "10");
	// Typed: each key resizes the flock; frames don't write over the field, even when it is empty.
	const typed = async (text) => {
		await page.eval("document.querySelector('.flock-count').value = ''");
		await page.type(".flock-count", text);
	};
	await typed("12");
	assert.equal(await birds(), 12);
	await typed("999");
	assert.equal(await birds(), 200, "at most 200");
	assert.equal(await field(), "200", "the field says so");
	await page.eval("document.querySelector('.flock-count').select()");
	await page.press("Backspace");
	await new Promise((resolve) => setTimeout(resolve, 200));
	assert.equal(await field(), "", "the birds fly on, and the field stays as you left it");
	assert.equal(await birds(), 200);
	await page.click('[aria-label="Five birds fewer"]');
	assert.equal(await birds(), 195);
	assert.equal(await field(), "195");
	await typed("1");
	await page.click('[aria-label="One bird fewer"]');
	assert.equal(await birds(), 0);
	assert.match(await text(page, ".arena"), /Empty sky/);
	assert.equal(await frames(page, "birds", 300), 0, "no birds, no frames");
	assert.equal(await page.eval("document.querySelector('[aria-label=\"One bird fewer\"]').disabled"), true);
	assert.equal(await page.eval("document.querySelector('[aria-label=\"Five birds fewer\"]').disabled"), true);
	assert.deepEqual(page.errors, []);
});

test("charts: each glides to other data and stops, Auto gives it more until pressed, bars, slices and dots come and go, and three looks restyle them", { skip }, async () => {
	const page = await open("/ecosystem/charts");
	const demos = ["chart-bar", "chart-stacked", "chart-line", "chart-sparkline", "chart-donut", "chart-scatter", "chart-heatmap"];
	const all = (selector) => `[...document.querySelectorAll(${JSON.stringify(selector)})]`;
	const settled = async (demo) => {
		// A glide is over in well under a second; then no frames at all.
		await new Promise((resolve) => setTimeout(resolve, 900));
		assert.equal(await frames(page, demo, 300), 0, `${demo}: no frames once it is there`);
	};
	const roll = async (demo) => {
		await page.click(`[data-demo="${demo}"] .roll`);
		assert.ok((await frames(page, demo, 150)) > 3, `${demo}: frames while it glides`);
	};

	// Auto is on from the start; pressed, it stops, and the charts stay where they are.
	assert.deepEqual(await page.eval(`${all(".auto")}.map((button) => button.getAttribute("aria-pressed"))`), demos.map(() => "true"));
	for (const demo of demos) await page.click(`[data-demo="${demo}"] .auto`);
	assert.deepEqual(await page.eval(`${all(".auto")}.map((button) => button.getAttribute("aria-pressed"))`), demos.map(() => "false"));
	for (const demo of demos) await settled(demo);

	// Bars: from the server, the most first; another morning glides them, sorted still, each slid to
	// its place; a kind not seen shrinks into the axis, and is gone once it has.
	const heights = () => page.eval(`${all("[data-demo=chart-bar] .bar:not([inert]) rect")}.map((rect) => Number(rect.getAttribute("height")))`);
	const before = await heights();
	assert.ok(before.length >= 4, "a bar for each kind seen, from the server");
	assert.deepEqual(before, [...before].sort((a, b) => b - a), "the most first");
	let going = 0;
	for (let i = 0; i < 6 && !going; i++) {
		await roll("chart-bar");
		going = await page.eval(`${all("[data-demo=chart-bar] .bar[inert]")}.length`);
		if (going) assert.equal(await page.eval(`document.querySelector("[data-demo=chart-bar] .bar[inert] rect").getAnimations().length`), 1, "a bar going plays its transition out");
		await settled("chart-bar");
	}
	assert.ok(going > 0, "a kind not seen shrinks into the axis");
	assert.equal(await page.eval(`${all("[data-demo=chart-bar] .bar[inert]")}.length`), 0, "and then it is gone");
	const sorted = await heights();
	assert.notDeepEqual(sorted, before, "other counts");
	assert.deepEqual(sorted, [...sorted].sort((a, b) => b - a), "the most first, still");
	const xs = await page.eval(`${all("[data-demo=chart-bar] .bar rect")}.map((rect) => Number(rect.getAttribute("x")))`);
	assert.deepEqual(xs, [...xs].sort((a, b) => a - b), "each bar slid to its place, left to right");
	assert.equal(await page.eval(`${all("[data-demo=chart-bar] .bar rect")}.every((rect) => rect instanceof SVGRectElement && rect.getBBox().height > 0)`), true, "a bar made in the browser is SVG, and drawn");

	// The line glides to another day's values, through the frames between.
	const line = () => page.eval(`document.querySelector("[data-demo=chart-line] path.line").getAttribute("d")`);
	const day = await line();
	await page.click("[data-demo=chart-line] .roll");
	await new Promise((resolve) => setTimeout(resolve, 50));
	const between = await line();
	await settled("chart-line");
	assert.notEqual(between, day, "the line moves");
	assert.notEqual(await line(), between, "a frame at a time");
	// The hours along the bottom, one apart (LineChart.evenly), as the demo writes them; pointed at,
	// the hour nearest the pointer: its value over the plot, its hour on the axis, in the ticks' place.
	const across = `${all("[data-demo=chart-line] .ticks .across")}.map((tick) => tick.textContent)`;
	assert.deepEqual(await page.eval(across), ["0:00", "5:00", "10:00", "15:00", "20:00"]);
	await page.eval(`document.querySelector("[data-demo=chart-line] svg").scrollIntoView({ block: "center" })`);
	const plot = await page.eval(`(() => { const box = document.querySelector("[data-demo=chart-line] svg").getBoundingClientRect(); return { x: box.left, y: box.top, width: box.width, height: box.height }; })()`);
	await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: plot.x + (plot.width * (48 + (572 * 14) / 23)) / 640, y: plot.y + plot.height / 2 });
	await page.wait(`document.querySelector("[data-demo=chart-line] .spot").classList.contains("shown")`, 3000);
	assert.equal(await page.eval(`[...document.querySelectorAll("[data-demo=chart-line] .spot text")].at(-1).textContent`), "14:00");
	await page.wait(`getComputedStyle(document.querySelector("[data-demo=chart-line] .ticks .across")).opacity === "0"`, 3000);
	await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: plot.x - 40, y: plot.y - 40 });
	await page.wait(`!document.querySelector("[data-demo=chart-line] .spot").classList.contains("shown")`, 3000);

	// Slices: a slice keeps its colour; one whose language is gone shrinks to nothing, and goes.
	const slices = () => page.eval(`Object.fromEntries(${all("[data-demo=chart-donut] .slice")}.map((slice) => [slice.getAttribute("aria-label").split(":")[0], slice.dataset.slot]))`);
	const colours = await slices();
	assert.deepEqual(Object.keys(colours), ["Roc", "Zig", "Rust", "JavaScript", "CSS"], "a slice a language, from the server");
	let shrank = false;
	for (let i = 0; i < 8 && !shrank; i++) {
		await roll("chart-donut");
		const legend = await page.eval(`${all("[data-demo=chart-donut] .legend li:not([inert]) .name")}.map((name) => name.textContent)`);
		if (!legend.includes("CSS")) {
			assert.equal(await page.eval(`${all("[data-demo=chart-donut] .slice")}.length`), 5, "the slice going is still there, shrinking");
			await settled("chart-donut");
			assert.equal(await page.eval(`${all("[data-demo=chart-donut] .slice")}.length`), 4, "and then it is gone");
			shrank = true;
		} else await settled("chart-donut");
		for (const [language, slot] of Object.entries(await slices())) assert.equal(slot, colours[language], `${language} keeps its colour`);
	}
	assert.ok(shrank, "a project without CSS");
	assert.match(await text(page, "[data-demo=chart-donut] .big"), /^\d+(\.\d)?k?$/, "the total in the middle");

	// Dots: another catch moves them, a dot for each bird caught.
	const dots = () => page.eval(`${all("[data-demo=chart-scatter] .dot")}.map((dot) => dot.getAttribute("cx") + "," + dot.getAttribute("cy"))`);
	const caught = await dots();
	await roll("chart-scatter");
	await settled("chart-scatter");
	assert.notDeepEqual(await dots(), caught, "the dots moved");
	assert.equal(await page.eval(`${all("[data-demo=chart-scatter] .dot")}.every((dot) => dot instanceof SVGCircleElement && dot.getBBox().width > 0)`), true, "a dot made in the browser is SVG, and drawn");

	// Stacked: a part for each source in each month, before and after another half-year.
	const parts = () => page.eval(`${all("[data-demo=chart-stacked] .part:not([inert])")}.length`);
	const months = () => page.eval(`${all("[data-demo=chart-stacked] .column:not([inert])")}.length`);
	assert.equal(await parts(), (await months()) * 3, "three parts a month, from the server");
	await roll("chart-stacked");
	await settled("chart-stacked");
	assert.equal(await parts(), (await months()) * 3, "three parts a month, another half-year");

	// Sparklines glide to another day.
	const sparks = () => page.eval(`${all("[data-demo=chart-sparkline] .sparkline .line")}.map((line) => line.getAttribute("d"))`);
	const spark = await sparks();
	assert.equal(spark.length, 3, "a line a tile");
	await roll("chart-sparkline");
	await settled("chart-sparkline");
	assert.notDeepEqual(await sparks(), spark, "the lines moved");

	// The heatmap's cells take another week's strengths, and the browser fades them: no frames.
	const strengths = () => page.eval(`${all("[data-demo=chart-heatmap] rect.cell")}.map((cell) => cell.style.getPropertyValue("--strength"))`);
	const week = await strengths();
	assert.equal(week.length, 7 * 24, "a cell an hour, a row a day");
	await page.click("[data-demo=chart-heatmap] .roll");
	assert.equal(await frames(page, "chart-heatmap", 300), 0, "no frames: a CSS transition");
	assert.notDeepEqual(await strengths(), week, "another week");

	// Looks: Blueprint outlines thin bars in monospace, Paper sets wide ones in a serif, and makes
	// the donut a pie, with no middle.
	const bar = () =>
		page.eval(`(() => {
			const rect = document.querySelector("[data-demo=chart-bar] .bar rect");
			return { width: Number(rect.getAttribute("width")), fill: getComputedStyle(rect).fillOpacity, font: getComputedStyle(rect.closest("svg")).fontFamily };
		})()`);
	const neon = await bar();
	await page.click("[data-demo=chart-bar] .looks button:nth-child(2)");
	assert.equal(await page.eval(`document.querySelector("[data-demo=chart-bar] .stage").dataset.look`), "blueprint");
	// The chart is kept (its padding is a prop, a getter: D-039), so its bars fade to the look's fill
	// (a CSS transition, 0.15 s) rather than being made anew in it.
	await page.wait(`getComputedStyle(document.querySelector("[data-demo=chart-bar] .bar rect")).fillOpacity === "0.2"`, 2000);
	const blueprint = await bar();
	assert.ok(blueprint.width < neon.width, "thinner bars");
	assert.equal(blueprint.fill, "0.2", "outlined, barely filled");
	assert.match(blueprint.font, /mono/i);
	await page.click("[data-demo=chart-bar] .looks button:nth-child(3)");
	const paper = await bar();
	assert.ok(paper.width > neon.width, "wider bars");
	assert.match(paper.font, /Georgia/);
	assert.equal(await page.eval(`getComputedStyle(document.querySelector("[data-demo=chart-donut] .middle")).display`), "inline", "a ring has a middle");
	await page.click("[data-demo=chart-donut] .looks button:nth-child(3)");
	assert.equal(await page.eval(`getComputedStyle(document.querySelector("[data-demo=chart-donut] .middle")).display`), "none", "a pie has none");

	// Auto again: a new day comes by itself, 3.3 seconds on.
	await page.click("[data-demo=chart-line] .auto");
	const now = await line();
	await new Promise((resolve) => setTimeout(resolve, 3700));
	assert.notEqual(await line(), now, "Auto gave the line another day");
	await page.click("[data-demo=chart-line] .auto");
	assert.deepEqual(page.errors, []);
});

// The admin package (packages/admin): its page, /ecosystem/admin.
test("admin: its page shows the package's own pages, rendered with the page into sandboxed frames, and the statements a list runs", { skip }, async () => {
	const html = await (await fetch(`${site.url}/ecosystem/admin`)).text();
	assert.match(await (await fetch(`${site.url}/ecosystem`)).text(), /<ul class="page-cards[ "](?:(?!<\/ul>)[\s\S])*href="\/ecosystem\/admin"/, "a card on the ecosystem's overview");
	// All of it is the server's: nothing on the page hydrates, so it costs the wasm nothing.
	assert.deepEqual(html.split(/<!--nohydration-->[\s\S]*?<!--\/nohydration-->/).join("").match(/<iframe|<figure|<table/g), null, "every frame, listing and table is inside a <NoHydration>");
	const frames = [...html.matchAll(/<iframe\s[^>]*>/g)].map(([tag]) => tag);
	assert.equal(frames.length, 2, "the list of books, and a book's form");
	const decoded = (text) => text.replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
	const [list, row] = frames.map((tag) => {
		assert.match(tag, /\ssandbox=""/, "sandboxed: no script runs, no form is sent, no link opens");
		return decoded(/\ssrcdoc="([^"]*)"/.exec(tag)[1]);
	});
	// The package's View, from the made-up catalog (site/Demos/AdminPreview.rocx), as a whole document.
	assert.match(list, /^<!doctype html>[\s\S]*<h1>Books<\/h1>[\s\S]*1–6 of 6/);
	// A filter under each column's heading, one of them on; the check's values as a select.
	const filters = /<tr class="filter">([\s\S]*?)<\/tr>/.exec(list)?.[1] ?? "";
	assert.equal(filters.split("<td>").length - 1, 5, "id, title, author_id, state, price");
	assert.match(filters, /name="from.price" value="10"/, "a filter on");
	assert.match(filters, /<select name="f.state" aria-label="State"><option value="">any<\/option><option value="draft">draft<\/option><option value="published">published<\/option><option value="out of print">out of print<\/option><\/select>/, "the check's values, as a filter");
	assert.match(list, /<button class="btn" form="filters"><svg[^>]*>[\s\S]*?<\/svg>Filter<\/button>/);
	// In the platform's admin look: the tables in its sidebar, this one marked; no panel of filters beside the rows.
	assert.match(list, /<aside class="side">[\s\S]*<a href="\/admin\/db\?table=books" aria-current="page">/);
	assert.doesNotMatch(list, /<aside>/, "no panel of filters beside the rows");
	assert.match(row, /<h1>A field guide to clouds<\/h1>/);
	assert.match(row, /Saved\./);
	assert.match(row, /<select[^>]*name="v.author_id"[\s\S]*Ines Hart/, "a foreign key, as a select of the rows it may name");
	// The statements Sql builds for a query, values only as parameters.
	assert.match(decoded(html), /"title" ilike \$1 or "blurb" ilike \$1\) and "state" = \$2 and "price" >= \$3::numeric[\s\S]*-- \$1 = '%cloud%', \$2 = 'published', \$3 = '10'/);
});

test("forms: the page shows what the schema says and the endpoint answers, and the demo checks as it is typed and on Send, asking nothing", { skip }, async () => {
	const page = await open("/ecosystem/forms");
	// Rendered from the package as the site is built: the endpoint's refusal, read back, and each code's English.
	const cells = (table) => page.eval(`[...document.querySelectorAll("#${table} tbody tr")].map((row) => [...row.cells].map((cell) => cell.textContent.trim()))`);
	assert.deepEqual((await cells("forms-answer")).map(([field, code]) => `${field} ${code}`), ["name required", "email not_email", "age too_small", "password too_short", "confirm not_same", "terms unchecked"]);
	assert.deepEqual((await cells("forms-codes")).find(([code]) => code === "TooShort(8)"), ["TooShort(8)", "too_short (min: 8)", "Use at least 8 characters"]);
	assert.deepEqual((await cells("forms-regex")).at(-1).slice(2), ["no", "nowhere"], "the trap, a step per character");

	const issues = (name) => page.eval(`[...document.querySelectorAll("#field-${name}-issues li")].map((li) => li.textContent)`);
	const invalid = (name) => page.eval(`document.querySelector("#field-${name}").getAttribute("aria-invalid")`);
	const leave = (name) => page.eval(`document.querySelector("#field-${name}").blur()`);
	// The schema's attributes, on the inputs.
	assert.equal(await page.eval(`document.querySelector("#field-email").type`), "email");
	assert.equal(await page.eval(`document.querySelector("#field-password").type`), "password");
	assert.equal(await page.eval(`document.querySelector("#field-age").getAttribute("min")`), "18");
	// Typed, and not yet left: nothing said. Left: its issue, and the input says so. Typed on: gone.
	await page.type("#field-email", "ada@");
	assert.deepEqual(await issues("email"), []);
	await leave("email");
	await page.wait(`document.querySelector("#field-email").getAttribute("aria-invalid") === "true"`);
	assert.deepEqual(await issues("email"), ["Enter an email address, like name@example.com"]);
	assert.equal(await page.eval(`document.querySelector("#field-email").getAttribute("aria-describedby")`), "field-email-issues");
	await page.type("#field-email", "Example.com");
	await page.wait(`document.querySelector("#field-email").getAttribute("aria-invalid") === "false"`);
	assert.deepEqual(await issues("email"), []);
	// Send: every issue at its field, and in the summary; nothing read.
	await page.click('[data-demo="forms"] button[type="submit"]');
	await page.wait(`document.querySelector(".issue-summary") !== null`);
	assert.deepEqual(await issues("name"), ["Fill this in"]);
	assert.equal(await invalid("terms"), "true");
	assert.deepEqual(await page.eval(`[...document.querySelectorAll(".issue-summary a")].map((a) => a.getAttribute("href"))`), ["#field-name", "#field-age", "#field-password", "#field-confirm", "#field-terms"]);
	assert.equal(await text(page, ".issue-summary a"), "Name: Fill this in", "each link says which field it is about");
	assert.equal(await text(page, "[data-demo=forms] .read"), "");
	// The rest filled in, the passwords differing: the check across them, once both are there.
	await page.type("#field-name", "  Ada ");
	await page.type("#field-age", "36");
	await page.type("#field-password", "correct horse");
	await page.type("#field-confirm", "correct hose");
	await page.click("#field-terms");
	await page.wait(`document.querySelectorAll("#field-confirm-issues li").length === 1`);
	assert.deepEqual(await issues("confirm"), ["These don't match"]);
	await page.eval(`(() => { const input = document.querySelector("#field-confirm"); input.value = "correct horse"; input.dispatchEvent(new Event("input", { bubbles: true })); })()`);
	// Nothing wrong: the summary goes, and what the form reads shows, trimmed and lowercased.
	await page.wait(`document.querySelector(".issue-summary") === null`);
	assert.equal(await text(page, "[data-demo=forms] .read"), 'It reads: { name: "Ada", email: "ada@example.com", age: 36, terms: Bool.True, passwords: … }');
	assert.equal(await page.eval("location.pathname"), "/ecosystem/forms", "the page stays");
	assert.equal(await page.eval(`document.querySelector("#field-password").getAttribute("value") ?? ""`), "", "a password typed is never written into the page");
	// Start again (`reset!`): every field as it started (empty), nothing said, nothing read, and the
	// inputs the same ones, focus kept.
	await page.eval(`document.querySelector("#field-name").focus()`);
	await page.eval(`document.querySelector("#field-name").dataset.kept = "yes"`);
	await page.eval(`document.querySelector('[data-demo="forms"] .again').click()`);
	await page.wait(`document.querySelector("#field-name").value === ""`);
	assert.deepEqual(await page.eval(`["name", "email", "age", "password", "confirm"].map((name) => document.querySelector("#field-" + name).value)`), ["", "", "", "", ""]);
	assert.equal(await page.eval(`document.querySelector("#field-terms").checked`), false);
	assert.equal(await page.eval(`document.querySelectorAll('[data-demo="forms"] .issues li').length`), 0, "no issue shows");
	assert.equal(await invalid("name"), "false");
	assert.equal(await text(page, "[data-demo=forms] .read"), "");
	assert.equal(await page.eval(`document.querySelector("#field-name").dataset.kept ?? null`), "yes", "the same input");
	assert.deepEqual((await asked(page)).filter((path) => !loads().includes(path)), [], "and asks for nothing");
	assert.deepEqual(page.errors, []);
});

test("guard: its tables are the package's answers, and its limit runs in the browser with a clock moved by hand", { skip }, async () => {
	const page = await open("/ecosystem/guard");
	// Worked out by the package when the page was built.
	const prose = await page.eval("document.querySelector('main').innerText");
	assert.match(prose, /5\s+429, Retry-After: 7\s+429, Retry-After: 67/, "the sixth request at second 5, under each limit");
	assert.match(prose, /Hops\(1\)\s+198\.51\.100\.4/, "behind one proxy, the address it saw");
	assert.match(prose, /Hops\(2\)\s+6\.6\.6\.6/, "claiming two trusts what the client wrote");
	assert.match(prose, /jo\s+8\s+on\s+on/, "jo falls in the quarter");
	assert.match(prose, /cy\s+35\s+off\s+on/, "cy doesn't, but has it in development");
	assert.match(prose, /The new checkout, for ada[\s\S]*The old checkout, for cy/, "<Flagged>, rendered for each");
	assert.match(prose, /content-security-policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'/);

	// The live demo: 5 at once, then one every 12 seconds.
	const demo = "[data-demo=guard-limit]";
	const said = () => page.eval(`[...document.querySelectorAll("${demo} .answers li")].map((li) => (li.classList.contains("refused") ? "refused " : "") + li.textContent.replace(/\\s+/g, " ").trim())`);
	for (let i = 0; i < 6; i++) await page.click(`${demo} .send`);
	const sixth = await said();
	assert.equal(sixth[0], "refused Second 0 429 Too Many Requests, Retry-After: 12", "the sixth is refused");
	assert.equal(sixth[1], "Second 0 200 OK, RateLimit-Remaining: 0", "the fifth was the last");
	await page.click(`${demo} .actions button:nth-child(3)`);
	await page.click(`${demo} .send`);
	assert.equal((await said())[0], "Second 12 200 OK, RateLimit-Remaining: 0", "a token back after 12 seconds");
	// A sliding window starts again, and lets nothing more through until the five weigh less.
	await page.click(`${demo} .kinds button:nth-child(2)`);
	assert.deepEqual(await said(), [], "switching starts again");
	assert.equal(await text(page, `${demo} .clock`), "Second 0 · 5 a minute");
	for (let i = 0; i < 6; i++) await page.click(`${demo} .send`);
	assert.equal((await said())[0], "refused Second 0 429 Too Many Requests, Retry-After: 72");
	await page.click(`${demo} .actions button:nth-child(4)`);
	await page.click(`${demo} .send`);
	assert.equal((await said())[0], "refused Second 60 429 Too Many Requests, Retry-After: 12", "a minute on, last minute's five still weigh");
	assert.equal(await page.eval(`document.querySelectorAll("${demo} .answers li").length`), 6, "the last six answers, no more");
	assert.deepEqual(page.errors, []);
});

test("intl: the picker writes the demo again in the language picked (right to left in Arabic), and n changes every line", { skip }, async () => {
	const page = await open("/ecosystem/intl");
	const demo = "[data-demo=intl]";
	const said = () => page.eval(`[...document.querySelectorAll("${demo} dd")].map((dd) => dd.textContent)`);
	const pick = async (tag) => {
		await page.eval(`(() => { const select = document.querySelector("${demo} select.language"); select.value = ${JSON.stringify(tag)}; select.dispatchEvent(new Event("input", { bubbles: true })); })()`);
		await page.wait(`document.querySelector("${demo} dd").lang === ${JSON.stringify(tag)}`);
	};
	const press = async (button, times, n) => {
		for (let i = 0; i < times; i++) await page.click(`${demo} .${button}`);
		await page.wait(`document.querySelector("${demo} .count").textContent === "n = ${n}"`);
	};

	assert.deepEqual(await said(), ["3,703.5", "€59.97", "3 days ago", "Saturday, November 21, 2026"], "rendered in English");
	await pick("pl");
	assert.deepEqual(await said(), ["3703,5", "59,97\u00a0€", "3 dni temu", "sobota, 21 listopada 2026"], "in Polish, at once");
	await press("more", 2, 5);
	assert.equal((await said())[0], "6172,5");
	await pick("ar");
	assert.equal(await page.eval(`document.querySelector("${demo} dd").dir`), "rtl", "Arabic, right to left");
	assert.equal((await said())[2], "قبل 5 أيام");
	await pick("en");
	await press("fewer", 5, 0);
	assert.deepEqual(await said(), ["0", "€0.00", "today", "Saturday, November 21, 2026"]);
	assert.equal(await page.eval(`document.querySelector("${demo} .fewer").disabled`), true, "no fewer than none");
	// The rest of the page is written by the package as the site is built: the demo's message among it.
	const files = await page.eval(`[...document.querySelectorAll("table.files tbody tr")].map((row) => [...row.cells].map((cell) => cell.textContent))`);
	assert.equal(files.length, 8, "the message at eight counts");
	assert.deepEqual(files.find((row) => row[0] === "22"), ["22", "22 files", "22 Dateien", "22 pliki", "22 ملفًا", "22 件のファイル"]);
	assert.equal(files.find((row) => row[0] === "2")[4], "ملفان", "Arabic's dual");
	assert.equal(await page.eval(`document.querySelectorAll("table.locales tbody tr").length`), 20, "ten locales, twice");
	assert.equal(await page.eval(`document.querySelectorAll(".problems li").length`), 4, "the catalog's four problems");
	assert.deepEqual(page.errors, []);
});

test("markdown: its examples are rendered when the site is built: headings with ids, a table, tasks, a table of contents, raw HTML as text, a javascript: link pointing nowhere, posts from their frontmatter", { skip }, async () => {
	const html = await (await fetch(`${site.url}/ecosystem/markdown`, { headers: { accept: "text/html" } })).text();
	// The first example: a heading with its id, a table's alignment, a tight task list.
	assert.ok(html.includes('<h3 id="a-morning-by-the-river">A morning by the river</h3>'), "a heading, its id from its text");
	assert.ok(html.includes('<th align="right">Seen</th>'), "a table's column, aligned as its delimiter row says");
	assert.ok(html.includes('<li class="task"><input type="checkbox" checked disabled> Binoculars</li>'), "a done task, in a tight list");
	// The table of contents: each heading a link to its id, a reading time.
	for (const id of ["before-you-go", "what-to-bring", "on-the-path", "afterwards"]) {
		assert.ok(html.includes(`href="#${id}"`) && html.includes(`id="${id}"`), `the contents link to #${id}, and it is there`);
	}
	assert.match(html, /\d+ min read · \d+ words/);
	// The hooks: an anchor after a heading, a code block drawn by the site's <Code>, a link to another site in a new tab.
	assert.ok(html.includes('href="#counting-what-you-see" aria-label="Link to this section">#</a>'), "the heading hook's anchor");
	assert.match(html, /<figure class="code[^"]*">\s*<figcaption[^>]*>roc<\/figcaption>/, "the code hook's <Code>, titled with the block's language");
	assert.ok(html.includes('href="https://www.roc-lang.org" target="_blank" rel="noopener"'), "the link hook");
	// Safety: the script as text, never as a script; the javascript: link replaced.
	assert.ok(html.includes("&lt;script&gt;alert(&quot;hello&quot;)&lt;/script&gt;"), "raw HTML shown as text");
	assert.equal(html.includes('<script>alert("hello")'), false, "never as a script");
	assert.ok(html.includes('href="about:invalid#rocx-unsafe-url"'), "the javascript: link points nowhere");
	// The collection: each post's title and tags from its frontmatter; the draft says so.
	assert.ok(html.includes("The heron on the far bank"), "a post's title, from its frontmatter");
	assert.match(html, /2026-11-21 · 1 min · birds, garden · draft/, "a draft's date, reading time and tags");
	// Rendered on the server alone: the browser's copy of the page has none of it (it is all in
	// <NoHydration>), and the page hydrates strictly around what the server rendered.
	assert.doesNotMatch(readFileSync(join(out, "client", "Generated", "EcosystemMarkdownPage.roc"), "utf8"), /Markdown(Demo|Toc|Hooks|Safety|Posts)/);
	const page = await open("/ecosystem/markdown");
	assert.equal(await page.eval("document.querySelectorAll('.markdown').length"), 5);
	assert.deepEqual(page.errors, []);
});

test("mcp: the page shows what its server answered as the site was built, in both eras, and nothing on it hydrates", { skip }, async () => {
	const page = await open("/ecosystem/mcp");
	const exchanges = await page.eval(`[...document.querySelectorAll(".mcp-exchange")].map((exchange) => {
		const [request, answer] = [...exchange.querySelectorAll("figure.code pre")].map((pre) => [...pre.querySelectorAll(".line")].map((line) => line.textContent).join("\\n"));
		return { title: exchange.querySelector("summary").textContent.trim(), request, answer, open: exchange.open };
	})`);
	assert.equal(exchanges.length, 10);
	assert.deepEqual(exchanges.map((exchange) => exchange.open), [true, ...Array(9).fill(false)], "the first one open");
	const answer = (title) => exchanges.find((exchange) => exchange.title.startsWith(title))?.answer ?? "";
	assert.match(answer("An earlier client"), /^200\n[\s\S]*"protocolVersion": "2025-11-25"/);
	assert.match(answer("A current client"), /^200\n[\s\S]*"resultType": "complete"[\s\S]*"supportedVersions": \[\n\s*"2026-07-28"/);
	assert.match(answer("The tools"), /"name": "convert"[\s\S]*"readOnlyHint": true/);
	assert.match(answer("A tool, called"), /"structuredContent": \{\n\s*"fahrenheit": 98\.6/);
	assert.match(answer("A refusal"), /below absolute zero[\s\S]*"isError": true/);
	assert.match(answer("So do arguments"), /Invalid arguments for convert[\s\S]*"isError": true/);
	assert.match(answer("A resource a template"), /"text": "78\.4 °C"/);
	assert.match(answer("One no template has"), /"code": -32602,\n\s*"message": "Resource not found"/);
	assert.match(answer("A prompt"), /Explain the Kelvin scale/);
	assert.match(answer("Nothing is pushed"), /^405\n\nMCP is asked by POST here, not GET$/);
	assert.match(exchanges[3].request, /^POST \/mcp\n[\s\S]*mcp-method: tools\/call\nmcp-name: convert\n\n\{/, "a current request's headers repeat its method and its tool");
	assert.equal(await page.eval("document.querySelectorAll('[data-demo]').length"), 0, "no demo: the page is text, and the build's answers");
	assert.deepEqual(page.errors, []);
});

test("presence: the room in the browser joins, types and leaves at a press, Auto moves the cursors, and the samples come rendered", { skip }, async () => {
	const page = await open("/ecosystem/presence");
	const demo = "[data-demo=presence]";
	const here = async () => Number((await text(page, `${demo} .here`)).split(" ")[0]);
	const typing = () => text(page, `${demo} .typing-indicator`);

	// The samples, rendered at build time: seven faces in four places, the last one "+4".
	assert.equal(await page.eval(`document.querySelectorAll(".sample .avatar-stack .avatar:not(.more)").length`), 3);
	assert.equal(await page.eval(`document.querySelector(".sample .avatar.more").getAttribute("aria-label")`), "and 4 more");
	assert.match(await text(page, ".sample .typing-indicator"), /^Ada Lovelace and Alan Turing are typing…$/);

	// Auto is on from the start; pressed, it stops, and the room changes only at a press.
	assert.equal(await page.eval(`document.querySelector("${demo} .auto").getAttribute("aria-pressed")`), "true");
	await page.click(`${demo} .auto`);
	assert.equal(await page.eval(`document.querySelector("${demo} .auto").getAttribute("aria-pressed")`), "false");
	while ((await here()) > 3) await page.click(`${demo} .leave`);
	while ((await here()) < 3) await page.click(`${demo} .join`);
	assert.equal(await here(), 3);
	const label = await page.eval(`document.querySelector("${demo} .avatar-stack").getAttribute("aria-label")`);
	await page.click(`${demo} .join`);
	assert.equal(await here(), 4, "someone joins");
	assert.notEqual(await page.eval(`document.querySelector("${demo} .avatar-stack").getAttribute("aria-label")`), label, "and the stack says so");

	// Someone types; the line runs out on its own, four seconds on.
	await page.click(`${demo} .type`);
	assert.match(await typing(), / typing…$/, "someone types");
	await page.wait(`document.querySelector("${demo} .typing-indicator").textContent.trim() === ""`, 6000);

	await page.click(`${demo} .leave`);
	assert.equal(await here(), 3, "someone leaves");
	while ((await here()) > 1) await page.click(`${demo} .leave`);
	assert.equal(await page.eval(`document.querySelector("${demo} .leave").disabled`), true, "you never leave");

	// Auto again, with three others here: a tick takes one away at most, and the others' cursors
	// wander over the note.
	for (let i = 0; i < 3; i++) await page.click(`${demo} .join`);
	assert.equal(await here(), 4);
	await page.click(`${demo} .auto`);
	await page.wait(`document.querySelectorAll("${demo} .cursor").length > 0`, 5000);
	await page.click(`${demo} .auto`);

	// Your own pointer over the note (D-055: on:pointermove.point, sent at most 20 times a second):
	// shown as the others see it, "You", where it stopped; gone when it leaves.
	const note = await page.eval(`(() => { const box = document.querySelector("${demo} .live-cursors").getBoundingClientRect(); return { x: box.left, y: box.top, width: box.width, height: box.height }; })()`);
	for (let step = 1; step <= 10; step++) await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: note.x + (note.width * step) / 40, y: note.y + (note.height * step) / 40 });
	const you = `[...document.querySelectorAll("${demo} .cursor")].find((cursor) => cursor.textContent.trim() === "You")`;
	await page.wait(`${you}?.style.getPropertyValue("--x") === "25%"`, 3000);
	assert.equal(await page.eval(`${you}.style.getPropertyValue("--y")`), "25%");
	await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: note.x + note.width + 40, y: note.y - 40 });
	await page.wait(`!${you}`, 3000);
	assert.deepEqual(page.errors, []);
});

test("QR codes: the demo's code follows what is typed and the level picked, says its version and size, and an empty code says the text is too long", { skip }, async () => {
	const page = await open("/ecosystem/qr");
	const demo = "[data-demo=qr]";
	const said = () => page.eval(`document.querySelector("${demo} .qr-demo-said").textContent`);
	const svg = (attribute) => page.eval(`document.querySelector("${demo} svg.qr-code").getAttribute(${JSON.stringify(attribute)})`);
	const path = () => page.eval(`document.querySelector("${demo} path.qr-dark").getAttribute("d")`);
	const type = (text) => page.eval(`(() => { const input = document.querySelector("${demo} input"); input.value = ${JSON.stringify(text)}; input.dispatchEvent(new Event("input", { bubbles: true })); })()`);

	assert.equal(await said(), "Version 3: 29 × 29 modules, the text 40 of the 42 bytes it holds", "the page's address, at Medium");
	assert.equal(await svg("viewBox"), "0 0 37 37", "the code and its quiet zone");
	assert.equal(await svg("role"), "img");
	const first = await path();
	assert.match(first, /^M4 4h7v1h-7z/, "the top left finder's first row, after the quiet zone");
	await type("hi");
	await page.wait(`document.querySelector("${demo} svg.qr-code").getAttribute("viewBox") === "0 0 29 29"`);
	assert.equal(await said(), "Version 1: 21 × 21 modules, the text 2 of the 14 bytes it holds");
	assert.notEqual(await path(), first, "a new code");
	await page.click(`${demo} .high`);
	await page.wait(`document.querySelector("${demo} .qr-demo-said").textContent.includes("of the 7 bytes")`);
	assert.equal(await page.eval(`document.querySelector("${demo} .high").getAttribute("aria-pressed")`), "true");
	await type("x".repeat(1300));
	await page.wait(`document.querySelector("${demo} path.qr-dark").getAttribute("d") === ""`);
	assert.equal(await said(), "1300 bytes: more than a code holds at this level (1273)");
	assert.equal(await svg("aria-label"), "A QR code of the text: the text is too long for a QR code");
	await page.click(`${demo} .low`);
	await page.wait(`document.querySelector("${demo} .qr-demo-said").textContent.startsWith("Version 26")`);
	assert.equal(await svg("viewBox"), "0 0 129 129", "1,300 bytes at Low: version 26, 121 modules a side");
});

test("virtual lists: the demo renders only the rows that show, of a hundred thousand or a million, measured once it hydrates and again as it scrolls; the count's buttons change the list", { skip }, async () => {
	const page = await open("/ecosystem/virtual");
	const demo = "[data-demo=virtual]";
	const shown = () => text(page, `${demo} .rows-demo-shown`);
	const rows = () => page.eval(`[...document.querySelectorAll("${demo} .rows-demo-row span:first-child")].map((span) => span.textContent)`);
	const scroll = (top) => page.eval(`document.querySelector("${demo} .rows-demo-list").scrollTop = ${top}`);

	// Measured: 358 pixels of 36-pixel rows show 10, and 4 more are rendered below.
	await page.wait(`document.querySelector("${demo} .rows-demo-shown").textContent.trim() === "Rows 1 to 14 of 100,000 are on the page"`);
	assert.deepEqual(await rows(), Array.from({ length: 14 }, (_, i) => String(i + 1)));

	// Half way down: those rows, and four more each side; none of the first.
	await scroll(36 * 50_000);
	await page.wait(`document.querySelector("${demo} .rows-demo-shown").textContent.trim().startsWith("Rows 49,997 to 50,014 ")`);
	const middle = await rows();
	assert.equal(middle[0], "49,997");
	assert.equal(middle.length, 18);
	assert.equal(await page.eval(`document.querySelector("${demo} .rows-demo-row span:last-child").textContent`), "2,499,700,009", "its square");

	// A million, scrolled to the end: the last row is a million, its square a trillion.
	await page.click(`${demo} .rows-demo-counts button:nth-child(3)`);
	assert.equal(await page.eval(`document.querySelector("${demo} .rows-demo-counts button:nth-child(3)").getAttribute("aria-pressed")`), "true");
	await scroll(36 * 1_000_000);
	await page.wait(`document.querySelector("${demo} .rows-demo-shown").textContent.trim().endsWith("to 1,000,000 of 1,000,000 are on the page")`);
	assert.deepEqual(await page.eval(`[...document.querySelectorAll("${demo} .rows-demo-row")].at(-1).textContent`), "1,000,0001,000,000,000,000");

	// A thousand: the list is shorter, and the box scrolls back within it.
	await page.click(`${demo} .rows-demo-counts button:nth-child(1)`);
	await page.wait(`document.querySelector("${demo} .rows-demo-shown").textContent.trim().endsWith("to 1,000 of 1,000 are on the page")`);
	assert.equal((await rows()).at(-1), "1,000");
	assert.ok((await rows()).length <= 18);
	assert.deepEqual(page.errors, []);
});

test("push: the button's states come from the package, and the notification demo shows what a server would send", { skip }, async () => {
	const page = await open("/ecosystem/push");
	// The states table, rendered on the server by the package's PushState.
	const states = await page.eval(`[...document.querySelectorAll("table tbody tr")].filter((row) => row.cells[0].querySelector("code")?.textContent === "on").map((row) => row.cells[1].textContent)`);
	assert.equal(states.length, 1, "a row for on");
	assert.match(states[0], /^Turn notifications off\. Beside it: Notifications are on in this browser\.$/);
	// The demo: the JSON and its size, the headers, and what Push.notify! would say.
	const demo = (selector) => `[data-demo=push-compose] ${selector}`;
	const read = () => page.eval(`({ size: Number(document.querySelector("${demo(".size")}").textContent), json: document.querySelector("${demo(".json")}").textContent, headers: document.querySelector("${demo(".headers")}").textContent, refused: document.querySelector("${demo(".verdict")}").classList.contains("refused") })`);
	let now = await read();
	assert.equal(now.json, '{"title":"Your export is ready","body":"orders.csv, 3 MB","url":"/exports/17"}');
	assert.equal(now.size, Buffer.byteLength(now.json));
	assert.equal(now.headers, "TTL: 86400\nUrgency: normal");
	assert.equal(now.refused, false);
	await page.click(demo(".urgency button:nth-of-type(4)"));
	await page.click(demo(".ttl button:nth-of-type(1)"));
	await page.type(demo("label:nth-of-type(4) input"), "café");
	await page.type(demo("label:nth-of-type(5) input"), "order 17");
	now = await read();
	assert.equal(now.headers, "TTL: 0\nUrgency: high\nTopic: order 17");
	assert.equal(now.refused, true, "a topic with a space is refused");
	assert.ok(now.json.endsWith(',"tag":"café"}') && now.size === Buffer.byteLength(now.json), "the size is in bytes");
	await page.eval(`document.querySelector("${demo("label:nth-of-type(5) input")}").select()`);
	await page.type(demo("label:nth-of-type(5) input"), "order-17");
	assert.equal((await read()).refused, false);
	assert.equal(await page.eval(`document.querySelector("${demo(".urgency button:nth-of-type(4)")}").getAttribute("aria-pressed")`), "true");
	assert.deepEqual(page.errors, []);
});

// The testing package's page (/ecosystem/testing), read with the package's own queries.
test("testing: the page shows its inbox, and what the package's queries answered as it rendered", { skip }, async () => {
	const { screen, within } = await import("../../packages/testing/dom.mjs");
	const response = await fetch(`${site.url}/ecosystem/testing`, { headers: { accept: "text/html" } });
	assert.equal(response.status, 200);
	const page = screen(await response.text());
	assert.equal(page.getByRole("heading", { level: 1 }).text, "Tests that read a page as a person does");
	const inbox = within(page.getByRole("region", { name: "Ada's inbox" }));
	assert.deepEqual(inbox.getAllByRole("link").map((link) => link.attr("href")), ["/mail/Lunch%3F", "/mail/Re%3A%20the%20plan"]);
	assert.equal(inbox.getByLabelText("To").attr("type"), "email");
	const answers = page.getAllByRole("table").find((table) => within(table).queryByRole("columnheader", { name: "Asked" }));
	assert.deepEqual(
		within(answers)
			.getAllByRole("row")
			.slice(1)
			.map((row) => within(row).getAllByRole("cell").map((cell) => cell.text)),
		[
			['page.get(Role("heading"))', `Ok the <h3>: "Ada's inbox"`],
			['page.get(Named("link", "Lunch?"))', 'Ok the <a>: "Lunch?"'],
			['page.get(Label("To"))', "Ok the <input>"],
			['page.get(TestId("unread"))', 'Ok the <p>: "2 unread"'],
			['page.get(Role("link"))', "TooMany 2 elements are a link"],
			['page.get(Named("button", "Send"))', 'NotFound nothing is a button named "Send"; the buttons here: "Write"'],
		],
	);
	assert.equal(page.getAllByText("site/Demos/TestingInbox.rocx").length, 2, "the component and its expects, each picked from the demo's file");
});

test("navigation in place (D-040): every page reached from the one before, from the front page on, is the page a load renders, byte for byte outside the host's elements, its document fetched once and nothing asked again", { skip }, async () => {
	await navigatesLikeLoads(site.url);
});

test("page transitions: a navigation in place is a View Transition (<html data-rocx-transitions>, D-040), the bar and the sidebar held still (named) and the page fading out and in (site.css); on a narrow screen the sidebar, above the page, changes with it", { skip }, async () => {
	const tab = await open("/components");
	// A laptop's width: the sidebar beside the page, sticky.
	await tab.send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
	const names = () => tab.eval("[document.querySelector('body > header.topbar'), document.querySelector('.frame > nav.sidebar')].map((element) => getComputedStyle(element).viewTransitionName)");
	assert.deepEqual(await names(), ["site-bar", "site-sidebar"]);
	// What each transition animates, once its pseudo-elements are there: each its element and its keyframes.
	await tab.eval(`window.transitions = []; const original = document.startViewTransition.bind(document); document.startViewTransition = (update) => { const transition = original(update); transition.ready.then(() => window.transitions.push(document.getAnimations().map((animation) => animation.effect.pseudoElement + " " + animation.animationName).sort())); return transition; }`);
	const next = await tab.eval("document.querySelector('.pager a.next').pathname");
	await tab.click(".pager a.next");
	await tab.wait(`location.pathname === ${JSON.stringify(next)} && window.transitions.length === 1`);
	const animated = await tab.eval("window.transitions[0]");
	for (const wanted of ["::view-transition-old(root) page-leave", "::view-transition-new(root) page-enter"]) assert.ok(animated.includes(wanted), `${wanted}: ${animated.join(", ")}`);
	for (const held of ["site-bar", "site-sidebar"]) assert.ok(animated.some((animation) => animation.startsWith(`::view-transition-group(${held})`)), `${held} held: ${animated.join(", ")}`);
	await tab.send("Emulation.setDeviceMetricsOverride", { width: 600, height: 900, deviceScaleFactor: 1, mobile: false });
	assert.deepEqual(await names(), ["site-bar", "none"]);
	assert.deepEqual(tab.errors, []);
	assert.deepEqual(tab.console, []);
	await tab.close();
});

test("the static build is every page as the server answers it, and what the pages load", { skip }, async () => {
	for (const [route, file] of [...ROUTES.map((route) => [route, route === "/" ? "index.html" : `${route.slice(1)}/index.html`]), ["/404", "404.html"]]) {
		const answered = await (await fetch(`${site.url}${route}`, { headers: { accept: "text/html" } })).text();
		assert.equal(readFileSync(join(dir, file), "utf8"), answered, route);
	}
	for (const route of STATIC_GETS) {
		assert.equal(readFileSync(join(dir, route.slice(1)), "utf8"), await (await fetch(`${site.url}${route}`)).text(), route);
	}
	for (const asset of ["rocx/start.js", "rocx/runtime.js", "rocx/app.wasm", "site.js"]) {
		assert.ok(readFileSync(join(dir, asset)).length > 0, asset);
	}
	// The app's stylesheet, at the URL every page links: as the server answers it, which says the
	// browser may keep it for good (its name changes with it); start.js, named by nothing, it doesn't.
	const styles = await fetch(`${site.url}/rocx/${sheet}`);
	assert.deepEqual([styles.status, styles.headers.get("content-type"), styles.headers.get("cache-control")], [200, "text/css; charset=utf-8", "public, max-age=31536000, immutable"]);
	const css = await styles.text();
	assert.ok(css.length > 10_000, "every component's <style>");
	assert.equal(readFileSync(join(dir, "rocx", sheet), "utf8"), css, "copied into the static build");
	assert.deepEqual(readdirSync(join(dir, "rocx")).filter((name) => name.endsWith(".css")), [sheet], "and no other build's");
	assert.equal((await fetch(`${site.url}/rocx/start.js`)).headers.get("cache-control"), null);
});

// The platform's reference (/platform/reference) is read from the platform's modules
// (rocx-cli/SiteReference.roc): every effect they expose is on it, and each has a doc comment to say there.

test("the platform reference: every effect the server platform exposes has a doc comment", () => {
	const missing = undocumented(platformReference());
	assert.deepEqual(missing, [], `effects with no \`##\` doc comment above them (write one, in the plain style of the others):\n${missing.join("\n")}`);
});

test("the platform reference: the page has every module the server platform exposes, and each effect's type and doc", { skip }, async () => {
	const html = await (await fetch(`${site.url}/platform/reference`, { headers: { accept: "text/html" } })).text();
	const entities = { amp: "&", lt: "<", gt: ">", quot: '"', "#39": "'", "#x27": "'" };
	const squeeze = (text) => text.replace(/\s+/g, " ").trim();
	// What HTML says, as text: its tags gone, its entities read.
	const plain = (part) => squeeze(part.replace(/<[^>]*>/g, "").replace(/&(amp|lt|gt|quot|#39|#x27);/g, (_, name) => entities[name]));
	// A doc's first block, as the page shows it: a paragraph's text, a list's first item, code.
	const opening = (doc) => {
		const [first] = blocks(doc);
		if (first.kind === "Sample") return first.code;
		return (first.kind === "Para" ? first.inlines : first.items[0]).map((piece) => piece.text).join("");
	};
	const missing = [];
	for (const module of platformReference()) {
		if (!html.includes(`id="${module.name}"`)) missing.push(`${module.name}: not on the page`);
		for (const effect of module.effects) {
			const name = `${module.name}.${effect.name}`;
			const at = html.indexOf(`id="${name}"`);
			if (at < 0) {
				missing.push(`${name}: not on the page`);
				continue;
			}
			const ends = ['<div class="effect', "<article", "</section"].map((tag) => html.indexOf(tag, at)).filter((end) => end > 0);
			const shown = plain(html.slice(at, Math.min(...ends)));
			if (!shown.includes(squeeze(`${name} : ${effect.type}`))) missing.push(`${name}: its type isn't shown`);
			if (!effect.doc || !shown.includes(squeeze(opening(effect.doc)).slice(0, 80))) missing.push(`${name}: its doc isn't shown`);
		}
	}
	assert.deepEqual(missing, [], `the reference page misses:\n${missing.join("\n")}`);
});

test("the examples' facts name every example app the repository has (`just example-apps` after adding one)", () => {
	const facts = JSON.parse(readFileSync(exampleFacts, "utf8"));
	assert.deepEqual(facts.examples.map((app) => app.name).sort(), exampleNames());
	for (const app of facts.examples) {
		if (app.wasm) assert.ok(app.wasm.brotli > 0 && app.wasm.brotli < app.wasm.gzip && app.wasm.gzip < app.wasm.bytes, `${app.name}'s sizes`);
	}
	// Echo's benchmark, on each of its endpoints: `just example-apps --bench`.
	assert.deepEqual(facts.bench?.variants?.map((variant) => variant.name), ["simple", "json"], "echo's benchmark, on both endpoints: `just example-apps --bench`");
	for (const variant of facts.bench.variants) assert.ok(variant.levels.length > 0 && variant.roc_us > 0, `echo (${variant.name})'s levels and Roc's time`);
});

test("the examples: an overview with a row for each app, and each app's page with its notes, numbers, screenshots, and echo's benchmark", { skip }, async () => {
	const page = async (path) => (await fetch(`${site.url}${path}`, { headers: { accept: "text/html" } })).text();
	const facts = JSON.parse(readFileSync(exampleFacts, "utf8"));
	const kb = (bytes) => `${(Math.round((bytes / 1024) * 10) / 10).toFixed(1)} KB`;
	// The screenshots site/AppNotes.roc names for each app (`shots: [{ file: "list", … }]`).
	const notes = readFileSync(join(root, "site", "AppNotes.roc"), "utf8");
	const named = (app) => {
		const block = notes.slice(notes.indexOf(`name: "${app}"`), notes.indexOf("\t\t},\n", notes.indexOf(`name: "${app}"`)));
		return [...block.matchAll(/file: "([^"]+)"/g)].map((match) => match[1]);
	};
	const overview = await page("/examples");
	assert.ok(!overview.includes("No notes yet"), "an app has no notes in site/AppNotes.roc");
	for (const app of facts.examples) {
		assert.match(overview, new RegExp(`<th[^>]*scope="row"><a[^>]* href="/examples/${app.name}">${app.title}</a></th>`), `${app.name}'s row`);
		const html = await page(`/examples/${app.name}`);
		assert.match(html, new RegExp(`<h1[^>]*>${app.title}</h1>`), `${app.name}'s page`);
		assert.ok(html.includes(`examples/${app.name}`), `${app.name}'s directory`);
		if (app.wasm) assert.ok(html.includes(kb(app.wasm.brotli)), `${app.name}'s wasm, ${kb(app.wasm.brotli)}`);
		// Every screenshot AppNotes names was taken (`just example-shots`), and is on the page.
		for (const file of named(app.name)) {
			assert.ok(existsSync(join(root, "site", "static", "shots", app.name, `${file}.webp`)), `${app.name}/${file}.webp: run \`just example-shots ${app.name}\``);
			assert.ok(html.includes(`src="/shots/${app.name}/${file}.webp"`), `${app.name}/${file} on its page`);
		}
	}
	const echo = await page("/examples/echo");
	for (const variant of facts.bench.variants) {
		assert.ok(echo.includes(`echo (${variant.name})`), `echo (${variant.name})'s part`);
		for (const level of variant.levels) assert.ok(echo.includes(level.rps.toLocaleString("en-US")), `echo (${variant.name}) at ${level.connections} connections`);
	}
	// What the benchmark sends: the string, and the order, laid out.
	assert.match(echo, /the body <code[^>]*>&quot;hello&quot;<\/code>/, "the string echo (simple) sends");
	assert.ok(echo.includes(JSON.parse(facts.bench.variants[1].body).id), "the order echo (json) sends");
	assert.ok(overview.includes(facts.measured), "when they were measured");
	// The sidebar lists them all, each page's own marked.
	const tasks = await page("/examples/tasks");
	for (const app of facts.examples) assert.ok(tasks.includes(`href="/examples/${app.name}"`), `the sidebar links ${app.name}`);
});

test("sqlite-vs-turso's results: a run count or the switch changes the table where the reader is, the page not taken back to the table's top (each input inside its label, in the bar that stays in sight)", { skip }, async () => {
	const tab = await open("/examples/sqlite-vs-turso");
	await tab.send("Emulation.setDeviceMetricsOverride", { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
	// Down into the middle of the everyday table, its bar stuck below the site's.
	await tab.eval(`(() => { window.series = document.querySelector('input[name="everyday-runs"]').closest('.series'); const table = window.series.querySelector('.view.n10'); scrollTo(0, scrollY + table.getBoundingClientRect().top + table.offsetHeight / 2 - innerHeight / 2); })()`);
	const shown = () => tab.eval("[...window.series.querySelectorAll('.view')].filter((view) => getComputedStyle(view).display !== 'none').map((view) => [...view.classList].find((name) => /^n[0-9]+s?$/.test(name)))");
	const at = await tab.eval("scrollY");
	assert.ok(at > 500, `scrolled into the table: ${at}`);
	assert.deepEqual(await shown(), ["n10"], "ten runs, the first counted");
	// A click where the label is on the screen (tab.click would scroll it to the middle first).
	const press = async (selector) => {
		const { x, y } = await tab.eval(`(() => { const box = window.series.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: box.x + box.width / 2, y: box.y + box.height / 2 }; })()`);
		await tab.clickAt(x, y);
		await tab.eval("new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)))");
	};
	for (const [selector, view, focused] of [
		[".skip-label", "n10s", "skip"],
		[".buttons .l3", "n3s", "p3"],
		[".skip-label", "n3", "skip"],
		[".buttons .l1", "n1", "p1"],
		[".buttons .l10", "n10", "p10"],
	]) {
		await press(selector);
		assert.deepEqual(await shown(), [view], `${selector}: its table`);
		assert.equal(await tab.eval("scrollY"), at, `${selector}: the page where it was`);
		assert.equal(await tab.eval(`document.activeElement.classList.contains(${JSON.stringify(focused)})`), true, `${selector}: its input focused, for the keyboard`);
	}
	assert.deepEqual(tab.errors, []);
	assert.deepEqual(tab.console, []);
	await tab.close();
});

test("the static build for GitHub Pages: files alone, under /rocx/, every page hydrates strictly as the browser's build renders it, and its demos work", { skip }, async () => {
	// As example.github.io/rocx/ would serve it: the site's files under /rocx/, and nothing to answer a request.
	const host = mkdtempSync(join(tmpdir(), "rocx-site-pages-"));
	const files = join(host, "rocx");
	await prerender(files, { base: "/rocx/" });
	const pages = await serve(host);
	const runtime = await Runtime.load(readFileSync(join(files, "rocx", "app.wasm")));
	try {
		for (const route of [...ROUTES, "/404"]) {
			const html = readFileSync(join(files, route === "/404" ? "404.html" : pageFile(route)), "utf8");
			assert.deepEqual(html.match(/\s(?:href|src|action)="\/(?!rocx\/|\/)[^"]*"/g), null, `${route}: every URL under /rocx/`);
			assert.ok(html.slice(0, html.indexOf("</head>")).includes(sheetLink("/rocx/")), `${route}: the app's stylesheet under /rocx/ too`);
			// The file is what the browser's build renders (decision D), its URLs under the base too,
			// byte for byte outside its <NoHydration>s, from the answers and regions it has.
			const answers = JSON.parse(/<script type="application\/json" class="rocx-answers">(.*?)<\/script>/.exec(html)[1]);
			const rendered = runtime.renderToString({ path: route, answers, regions: Runtime.regionsOf(html), scripts: SCRIPTS }).html;
			assert.equal(outsideRegions(rendered, (part) => underBase(part, "/rocx/")), html, `${route}, as files`);
		}
		const styles = await fetch(`${pages.url}/rocx/rocx/${sheet}`);
		assert.deepEqual([styles.status, styles.headers.get("content-type")], [200, "text/css"], "the app's stylesheet, at the URL the pages link");
		for (const route of ROUTES) {
			const page = await open(`/rocx${route}`, pages.url);
			assert.ok(await page.eval("getComputedStyle(document.body).fontFamily !== ''"), `${route}: its stylesheet`);
			if (route === "/") assert.equal(await page.eval("getComputedStyle(document.querySelector('.counter')).display"), "grid", "and the app's: the counter's <style>");
			assert.deepEqual(page.console, [], `${route} logged nothing`);
			assert.deepEqual(page.errors, [], `${route} threw nothing`);
			assert.deepEqual((await asked(page)).filter((path) => !loads("/rocx/").includes(path) && path !== "/rocx/roc-bird.svg" && !path.startsWith("/rocx/shots/")), [], `${route}: asked for nothing else`);
		}
		// A sound, played from the copy under /rocx/: the player puts its URL under the base, and the
		// file is there.
		const snake = await open("/rocx/showcase", pages.url);
		await snake.eval(LISTEN);
		await snake.click(".board");
		await snake.wait("window.played.length === 1");
		assert.deepEqual(await snake.eval("window.played"), [["/rocx/sounds/start.wav", 1, 1]], "the sound under the base");
		assert.equal((await fetch(`${pages.url}/rocx/sounds/start.wav`)).status, 200, "and there, as a file");
		assert.equal((await fetch(`${pages.url}/rocx/rocx/plugins/audio/audio.js`)).status, 200, "the player, copied at its URL under the base");
		assert.deepEqual(snake.errors, []);
		// The lobby, asked once where no server answers channels: it says so.
		const live = await open("/rocx/platform/live", pages.url);
		await live.click("[data-demo=lobby] .join");
		await live.wait("document.querySelector('[data-demo=lobby] .state')?.textContent.startsWith('No lobby here')", 5000);
		await new Promise((resolve) => setTimeout(resolve, 300));
		assert.deepEqual((await asked(live)).filter((path) => path.startsWith("/rocx/rocx/live")).length, 1, "asked once");
		assert.ok(!(await asked(live)).some((path) => !path.startsWith("/rocx/")), "nothing outside /rocx/");
		assert.deepEqual(live.errors, []);
		// The planner's move, where no server answers it: shown at once, then back, saying why.
		const planner = await open("/rocx/components", pages.url);
		await planner.drag("[data-demo=planner] .day[data-day=mon] .plan:nth-child(2)", "[data-demo=planner] .day[data-day=tue]");
		await planner.wait("document.querySelector('[data-demo=planner] .refused span')?.textContent.startsWith('No server answers moves here')", 5000);
		assert.equal(await planner.eval("document.querySelectorAll('[data-demo=planner] .day[data-day=mon] .plan:not([inert])').length"), 2, "back on Monday");
		assert.deepEqual(planner.errors, []);
		const page = await open("/rocx/calls", pages.url);
		await page.click("form.echo > button:nth-of-type(3)");
		await page.wait("document.querySelector('form.echo output').textContent === 'Echo: this site, as files'");
		await page.click(".shout button:nth-of-type(3)");
		await page.wait("document.querySelector('.shout output').textContent === 'STATIC: 6 bytes'");
		const fetched = await asked(page);
		assert.ok(fetched.includes("/rocx/rocx/app.wasm") && fetched.includes("/rocx/api/shout/static"), fetched.join(" "));
		assert.ok(!fetched.some((path) => !path.startsWith("/rocx/")), "nothing outside /rocx/");
		assert.deepEqual(page.errors, []);
		assert.equal(JSON.parse(readFileSync(join(files, "openapi.json"), "utf8")).openapi.slice(0, 2), "3.");
		// Navigating in place (D-040), as files under /rocx/: each page the file a load gets, the
		// URLs the runtime writes under the base as the file has them.
		await navigatesLikeLoads(pages.url, "/rocx");
	} finally {
		await pages.close();
		rmSync(host, { recursive: true, force: true });
	}
});

/** `html` with `change` made to what is outside its `<NoHydration>`s (inside them, it is as it is). */
function outsideRegions(html, change) {
	return html
		.split(/(<!--nohydration-->[\s\S]*?<!--\/nohydration-->)/)
		.map((part, i) => (i % 2 ? part : change(part)))
		.join("");
}

test("pages: the server renders each as the browser's build renders it, byte for byte outside its <NoHydration>s", { skip }, async () => {
	// The browser's build (app.wasm), rendering as a server would, from the answers the native page
	// recorded, with what the page has inside each <NoHydration> (decision D). A call the page didn't
	// record would be a failure: the two sides drifted.
	const runtime = await Runtime.load(wasm);
	const member = { cookie: "member=Ada%20L" };
	for (const [path, headers] of [...ROUTES.map((route) => [route, {}]), ["/nowhere", {}], ["/members", member]]) {
		const page = await nativePage(site.url, path, headers);
		assert.deepEqual(page.scripts, SCRIPTS, `${path}: the audio plugin's script, before start.js`);
		const rendered = runtime.renderToString({ path, headers: Object.entries(headers), answers: page.answers, regions: page.regions, scripts: SCRIPTS });
		assert.equal(rendered.html, page.html, path);
		assert.equal(runtime.status, page.status, `${path}: its status`);
	}
	// The prose is the server's alone: the docs' pages are mostly <NoHydration>.
	const showcase = await nativePage(site.url, "/showcase");
	assert.ok(showcase.regions.join("").length > showcase.html.length / 2, "the showcase's prose and listings, in its regions");
});

test("pages: rendering them again and again leaves nothing allocated", { skip }, async () => {
	const debugged = await startServer({}, ["--debug"]);
	try {
		const live = async () => Number(await (await fetch(`${debugged.url}/__rocx/allocations`)).text());
		await fetch(`${debugged.url}/components`);
		const settled = await live();
		for (let i = 0; i < 50; i++) await Promise.all(["/components", "/calls", "/showcase", "/"].map((path) => fetch(`${debugged.url}${path}`).then((answer) => answer.text())));
		assert.equal(await live(), settled);
	} finally {
		await debugged.stop();
	}
});

// The dev build's last: they build the site again, from Roc's dev backend, with the stories, over
// what the tests above use.

test("the dev build (`just dev`) rebuilds fast, and every page still wakes up and works", { skip }, async (t) => {
	// Two seconds, on a machine with a core for each thing it runs. On a busier one (other builds,
	// other tests: a load average near or above its cores) each process gets a share of a core, and
	// the build takes longer by as much, so the limit grows with load / cores, the higher of the two
	// readings around the build. The load average is a minute's, and lags behind a burst of builds
	// (a run took 3.6 s at loads of 13 to 23 on 10 cores, where load / cores allowed 3.1 s), so a
	// busy machine gets half as much again: 2 s × 1.5 × load / cores. Below two thirds of a core's
	// load each, a quiet machine, the limit stays two seconds, so a rebuild that got slower still
	// fails there; retrying, or comparing with another build, would hide it on a quiet one as well.
	// (The build blocks this process, so the load can't be read while it runs.) A machine slower
	// than the ones this is measured on says so by ROCX_TIME_SCALE, which multiplies the limit: CI
	// sets it (.github/workflows/ci.yml; its runners' Roc caches start cold, in a VM: 4.4 s there).
	const cores = cpus().length;
	const busy = () => loadavg()[0] / cores;
	const busyBefore = busy();
	const started = performance.now();
	const facts = await build({ dev: true, log: () => {} });
	const took = performance.now() - started;
	const scale = Number(process.env.ROCX_TIME_SCALE) || 1;
	const limit = 2000 * scale * Math.max(1, 1.5 * busyBefore, 1.5 * busy());
	t.diagnostic(`a dev rebuild took ${Math.round(took)} ms; load average ${loadavg()[0].toFixed(1)} on ${cores} cores; the limit ${Math.round(limit)} ms${scale === 1 ? "" : ` (ROCX_TIME_SCALE=${scale})`}`);
	assert.ok(took < limit, `a rebuild while editing takes well under two seconds (${Math.round(limit)} ms on a machine this busy): it took ${Math.round(took)} ms`);
	assert.match(facts, /^dev=yes$/m);

	const devDir = mkdtempSync(join(tmpdir(), "rocx-site-dev-"));
	await prerender(devDir);
	const devSite = await serve(devDir);
	try {
		for (const route of ROUTES) {
			const page = await open(route, devSite.url);
			assert.deepEqual(page.console, [], `${route} logged nothing`);
			assert.deepEqual(page.errors, [], `${route} threw nothing`);
			assert.match(await page.eval("document.querySelector('.footer').textContent"), /A development build/);
		}
		const page = await open("/", devSite.url);
		await page.click('.counter [aria-label="One more"]');
		assert.equal(await text(page, ".counter output"), "4");
	} finally {
		await devSite.close();
		rmSync(devDir, { recursive: true, force: true });
	}
});

test("stories: a dev build has the catalog, and each story in the site's frame; the site's own build has none", { skip }, async () => {
	assert.equal((await fetch(`${site.url}/__rocx/stories`, { headers: { accept: "text/html" } })).status, 404, "the site as it is published has no stories");
	await build({ dev: true, log: () => {} });
	const dev = await startServer({ dev: true });
	try {
		const catalog = await (await fetch(`${dev.url}/__rocx/stories`)).text();
		const stories = JSON.parse(/const STORIES = (\[.*\]);/.exec(catalog)[1]);
		const ids = stories.map((story) => story.id);
		const drafts = ["today", "midnight", "paper", "neon", "swiss", "phosphor", "pastel"];
		for (const id of ["Ui/Callout/tip", "Ui/Code/roc", "Ui/Heading/section", ...drafts.map((draft) => `stories/Landing/${draft}`)]) {
			assert.ok(ids.includes(id), `the catalog has ${id}`);
		}
		for (const story of stories) {
			const answer = await fetch(`${dev.url}/__rocx/stories/${story.id}`, { headers: { accept: "text/html" } });
			assert.equal(answer.status, 200, story.id);
			const html = await answer.text();
			assert.match(html, /<div class="frame[^"]*\blanding\b/, `${story.id}: in the front page's frame`);
			// Before the page, nothing of the site's: the story is in <main>, and a story of the bar has one.
			assert.doesNotMatch(html.slice(0, html.indexOf('<main id="content"')), /class="topbar[ "]/, `${story.id}: and nothing around it`);
		}
		assert.equal((await fetch(`${dev.url}/__rocx/stories/Ui/Callout/nothing`)).status, 404);
		// The drafts of the front page, each with its counter: it wakes up and counts, as on the page.
		// One tab, as a person goes from one to the next: each page held open is a stream (the dev
		// server's reload) and one of the six connections a browser makes to a host.
		const tab = await strictTab();
		for (const id of drafts.map((draft) => `stories/Landing/${draft}`)) {
			await tab.goto(`${dev.url}/__rocx/stories/${id}`);
			await tab.wait(AWAKE);
			await tab.click('.counter [aria-label="One more"]');
			assert.equal(await text(tab, ".counter output"), "4", `${id}: its counter counts`);
			assert.deepEqual(tab.errors, [], `${id} threw nothing`);
		}
		// Side by side, every frame loads and wakes up: only the catalog holds the dev server's stream.
		const page = await browser.page();
		await page.goto(`${dev.url}/__rocx/stories#side/stories/Landing.rocx#Landing`);
		await page.wait("document.querySelectorAll('.cell iframe').length === 7");
		await page.wait("[...document.querySelectorAll('.cell iframe')].every((frame) => frame.contentDocument?.documentElement.hasAttribute('data-hydrated'))", 15000);
		assert.deepEqual(await page.eval("[...document.querySelectorAll('.cell header a')].map((a) => a.textContent)"), ["Today", "Midnight", "Paper", "Neon", "Swiss", "Phosphor", "Pastel"]);
		assert.deepEqual(page.errors, [], "the catalog threw nothing");
	} finally {
		await dev.stop();
	}
});
