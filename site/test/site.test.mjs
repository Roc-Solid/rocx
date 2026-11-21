// The docs site, built and served by its server (site/main.roc, native), in a real browser: every
// page comes rendered by the server as the browser's build renders it (byte for byte, outside its
// <NoHydration>s), hydrates strictly without being rendered again or asking for anything, and each
// demo works when used the way a reader would; the static build (site/dist) is every page as the
// server answers it, and works as files alone, under /rocx/ as GitHub Pages serves it, with no
// server to ask. Needs the toolchain (`just setup`: Roc, Zig, Rust) and Chromium (see
// web/test/browser.mjs).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appWasm, build, nativePage, out, pageFile, prerender, roc, root, ROUTES, STATIC_GETS, startServer, underBase } from "../build.mjs";
import { hasRust } from "../../server/build.mjs";
import { blocks, platformReference, undocumented } from "../../src/reference.mjs";
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
	await prerender(dir);
	site = await startServer();
	browser = await launch();
});

after(async () => {
	await browser?.close();
	await site?.stop();
	if (dir) rmSync(dir, { recursive: true, force: true });
});

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

/** What a page loads besides itself: its stylesheet, its icon and site.js, and start.js, the runtime
 * and the wasm (under `base`); anything else would be the page asking the server. */
const loads = (base = "/") => ["site.css", "favicon.svg", "site.js", "rocx/start.js", "rocx/runtime.js", "rocx/app.wasm"].map((file) => `${base}${file}`);
const asked = (page) => page.eval("performance.getEntriesByType('resource').map((entry) => new URL(entry.name).pathname)");

const text = (page, selector) => page.eval(`document.querySelector(${JSON.stringify(selector)}).textContent.trim()`);

test("every page renders, and hydrates strictly as the server left it, asking for nothing but app.wasm and what it loads", { skip }, async () => {
	for (const route of ROUTES) {
		const response = await fetch(`${site.url}${route}`);
		assert.equal(response.status, 200, route);
		const html = await response.text();
		assert.match(html, /^<!doctype html> <html lang="en">/, route);
		if (route === "/") {
			// Roc Solid's front page is in no part of the docs: it has no sidebar.
			assert.doesNotMatch(html, /<nav class="sidebar[ "]/, "the front page has no sidebar");
		} else {
			assert.match(html, new RegExp(`<a class="current[^"]*" href="${route}" aria-current="page">`), `${route} is the current page in the sidebar`);
			// Each part of the docs has its own sidebar: rocx's pages, the platform's or the ecosystem's, one part only.
			const sidebar = /<nav class="sidebar[ "][\s\S]*?<\/nav>/.exec(html)[0];
			const under = (home) => route === home || route.startsWith(`${home}/`);
			const inPlatform = under("/platform");
			const inEcosystem = under("/ecosystem");
			assert.equal(sidebar.includes('href="/platform/server"'), inPlatform, `${route}: the platform's pages in its sidebar only on the platform's`);
			assert.equal(sidebar.includes('href="/ecosystem/charts"'), inEcosystem, `${route}: the ecosystem's pages in its sidebar only on the ecosystem's`);
			assert.equal(sidebar.includes('href="/syntax"'), !inPlatform && !inEcosystem, `${route}: rocx's pages in its sidebar only on rocx's`);
		}
		const page = await open(route);
		// Strictly: markup that wasn't what the app renders would have thrown.
		assert.deepEqual(page.console, [], `${route} logged nothing`);
		assert.deepEqual(page.errors, [], `${route} threw nothing`);
		const fetched = await asked(page);
		assert.ok(fetched.includes("/rocx/app.wasm"), `${route}: every page fetches the wasm`);
		// The flock's birds are an image.
		assert.deepEqual(fetched.filter((path) => !loads().includes(path) && path !== "/roc-bird.svg"), [], `${route}: and asks for nothing else`);
	}
	const missing = await fetch(`${site.url}/nowhere`, { headers: { accept: "text/html" } });
	assert.equal(missing.status, 404);
	const notFound = await missing.text();
	assert.equal((notFound.match(/<ul class="page-cards[ "]/g) ?? []).length, 1, "the 404 lists the pages");
	assert.match(notFound, /<ul class="page-cards[ "][\s\S]*href="\/syntax"[\s\S]*<\/ul>/, "rocx's, for a path outside the platform's docs");
	const platformMissing = await (await fetch(`${site.url}/platform/nowhere`, { headers: { accept: "text/html" } })).text();
	assert.match(platformMissing, /<ul class="page-cards[ "](?:(?!<\/ul>)[\s\S])*href="\/platform\/postgres"/, "the platform's, for a path in them");
	assert.doesNotMatch(platformMissing, /<ul class="page-cards[ "](?:(?!<\/ul>)[\s\S])*href="\/syntax"/);
	const ecosystemMissing = await (await fetch(`${site.url}/ecosystem/nowhere`, { headers: { accept: "text/html" } })).text();
	assert.match(ecosystemMissing, /<ul class="page-cards[ "](?:(?!<\/ul>)[\s\S])*href="\/ecosystem\/charts"/, "the ecosystem's, for a path in them");
	assert.doesNotMatch(notFound, /class="pager-(previous|next)"/, "and offers no next page, being none of them");
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
	assert.equal(await page.eval("getComputedStyle(document.querySelector('.counter')).display"), "flex", "its <style> applies, from the page's head");
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
	assert.match(html, /<span class="shelf-name rx-\w+"><!--x-->rocx mug<!--\/x--><\/span>/, "the server renders the shelf with what its server function answered");
	assert.match(html, /<p class="bag-title rx-\w+"><!--x-->Ada<!--\/x-->/, "and the bag with who is reading");
	assert.match(html, /class="rocx-answers">\[.*"Demos\/Shelf\.stock"/, "the answers beside them, for the browser");
	const page = await open("/components");
	assert.equal(await page.eval("performance.getEntriesByType('resource').filter((entry) => entry.name.includes('/rocx/call/')).length"), 0, "the browser read the answers from the page");
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

test("server functions: the server answers a call with POST, from this site, in the function's types", { skip }, async () => {
	const call = (name, body, { method = "POST", headers = {} } = {}) => fetch(`${site.url}/rocx/call/${name}`, { method, headers, body: method === "POST" ? body : undefined });
	const answered = await call("Demos/Echo.echo", '"hi"');
	assert.equal(answered.status, 200);
	assert.equal(answered.headers.get("content-type"), "application/json");
	assert.equal(await answered.text(), '"Echo: hi"');
	assert.equal((await call("Demos/Echo.nope", '"hi"')).status, 404);
	assert.equal((await call("Demos/Echo.echo", "7")).status, 400, "input of the wrong type");
	const got = await call("Demos/Echo.echo", "", { method: "GET" });
	assert.equal(got.status, 405);
	assert.equal(got.headers.get("allow"), "POST");
	assert.equal((await call("Demos/Echo.echo", '"hi"', { headers: { origin: "https://elsewhere.example" } })).status, 403, "another site's page: the middleware refuses it");
});

test("the browser's app is built from a copy of the site in which a server function is its name", { skip }, () => {
	const echo = readFileSync(join(out, "client", "Demos", "Echo.roc"), "utf8");
	assert.match(echo, /^\techo! = Server\.remote\("Demos\/Echo\.echo"\)$/m);
	assert.doesNotMatch(echo, /Echo: /, "what it does is gone");
	assert.equal(echo.split("\n").length, readFileSync(join(root, "site", "Demos", "Echo.roc"), "utf8").split("\n").length, "line for line");
	assert.ok(readFileSync(join(dir, "rocx", "app.wasm")).includes("Demos/Echo.echo"), "the wasm has its name, to call it");
});

test("the echo comes rendered with the server's answers, hydrates without asking, and a click asks nothing", { skip }, async () => {
	const html = await (await fetch(`${site.url}/calls`)).text();
	assert.match(html, /<output class="echo-answer"><!--x-->Echo: the page, rendered on the server<!--\/x--><\/output>/, "rendered with echo! called on the server");
	const answers = html.slice(html.indexOf('<script type="application/json" class="rocx-answers">'));
	for (const message of ["the page, rendered on the server", "hello", "this site, as files"]) {
		assert.ok(answers.includes(`Echo: ${message}`), `and its answer to "${message}" beside it`);
	}
	const page = await open("/calls");
	const echo = "form.echo";
	await page.eval(`window.output = document.querySelector('${echo} output')`);
	const echoCalls = () =>
		page.eval("performance.getEntriesByType('resource').filter((entry) => new URL(entry.name).pathname === '/rocx/call/Demos/Echo.echo').map((entry) => entry.responseStatus)");
	assert.deepEqual(await echoCalls(), [], "the browser read the server's answers: no request");
	assert.equal(await text(page, `${echo} output`), "Echo: the page, rendered on the server");
	const woke = await text(page, '[data-inspect-signals="echo"] li');
	assert.match(woke, /^hydrated with the page in .* ms/);
	assert.ok(woke.includes('read Demos/Echo.echo("hello") from the page: not asked'), woke);
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
	assert.equal((await ask("POST", "/rocx/call/Demos/Echo.echo", '"hi"', { origin: "https://elsewhere.example" })).status, 403, "a server function too");
	assert.equal((await ask("GET", "/api/nothing")).status, 404);
});

test("endpoints: GET /openapi.json is their OpenAPI document, each schema its type's, written down or inferred", { skip }, async () => {
	const response = await fetch(`${site.url}/openapi.json`);
	assert.equal(response.status, 200);
	assert.equal(response.headers.get("content-type"), "application/json");
	const doc = await response.json();
	assert.equal(doc.openapi, "3.2.0");
	assert.deepEqual(Object.keys(doc.paths).sort(), ["/api/count/{to}", "/api/shout", "/api/shout/{word}", "/members", "/members/join", "/members/leave"]);
	const answer = (operation) => operation.responses["200"].content["application/json"].schema;
	const word = { type: "object", properties: { bytes: { type: "integer", minimum: 0 }, shouted: { type: "string" }, word: { type: "string" } }, required: ["bytes", "shouted", "word"] };
	assert.deepEqual(answer(doc.paths["/api/shout/{word}"].get), word, "a handler with no annotation: its inferred type");
	assert.deepEqual(doc.paths["/api/shout"].post.requestBody.content["application/json"].schema, { type: "string" });
	assert.deepEqual(doc.paths["/members/join"].post.requestBody.content["application/json"].schema, { type: "object", properties: { name: { type: "string" } }, required: ["name"] });
	assert.deepEqual(doc.paths["/api/count/{to}"].parameters, [{ name: "to", in: "path", required: true, schema: { type: "string" } }]);
	const events = doc.paths["/api/count/{to}"].get.responses["200"].content["text/event-stream"].itemSchema.oneOf;
	assert.deepEqual(events[0].properties.data.contentSchema.required, ["count", "of", "square"], "each event's data");
	assert.deepEqual(events[1].properties.event, { const: "end" });
	assert.match(doc.paths["/api/shout"].post.description, /what it is sent, shouted/, "the handler's comment");
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
	const refused = await ask("GET", "/members", { headers: { accept: "application/json" } });
	assert.equal(refused.status, 401);
	assert.match(refused.body, /members only/);
	assert.equal(refused.sniff, "nosniff", "the default middleware's headers, on a refusal too");
	assert.equal((await ask("GET", "/members/join", { headers: html })).status, 200);
	// Joining: the form's POST sets the cookie and sends you on; a name that is only spaces is refused.
	const form = { "content-type": "application/x-www-form-urlencoded", origin: site.url };
	const joined = await ask("POST", "/members/join", { body: "name=Ada+L", headers: form });
	assert.deepEqual([joined.status, joined.location], [303, "/members"]);
	assert.match(joined.cookie, /^member=Ada%20L; Path=\/; HttpOnly; SameSite=Lax/);
	assert.equal((await ask("POST", "/members/join", { body: "name=+", headers: form })).status, 400);
	assert.equal((await ask("POST", "/members/join", { body: "name=Eve", headers: { ...form, origin: "https://elsewhere.example" } })).status, 403, "the default middleware: another site's form");
	// A member: the page and the endpoint are given the name the middleware read.
	const member = { cookie: "member=Ada%20L" };
	const page = await ask("GET", "/members", { headers: { ...html, ...member } });
	assert.equal(page.status, 200);
	assert.match(page.body, /<h1[^>]*>Welcome, Ada L<\/h1>/);
	assert.deepEqual(JSON.parse((await ask("GET", "/members", { headers: member })).body), { member: "Ada L" });
	assert.equal((await ask("GET", "/members/join", { headers: { ...html, ...member } })).location, "/members", "a member isn't sent to join");
	const left = await ask("POST", "/members/leave", { headers: { ...form, ...member } });
	assert.deepEqual([left.status, left.location], [303, "/members/join"]);
	assert.match(left.cookie, /^member=; Path=\/; HttpOnly; SameSite=Lax; Max-Age=0/);
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
	const call = (name, headers = {}) => fetch(`${site.url}/rocx/call/${name}`, { method: "POST", body: "{}", headers });
	const elsewhere = await call("Facts.facts", { origin: "https://elsewhere.example" });
	assert.equal(elsewhere.status, 403, "its first step: another site's page is refused, before the second");
	// A server function behind the default alone: given the context it hands on (the build's facts).
	const facts = await call("Facts.facts");
	assert.equal(facts.status, 200);
	assert.match(JSON.parse(await facts.text()), /^client_brotli=/m);
	// The members' page, its endpoint and its server function: behind the route's middleware too.
	for (const [method, path] of [["GET", "/members"], ["POST", "/rocx/call/Generated/MembersPage.member"]]) {
		const refused = await fetch(`${site.url}${path}`, { method, body: method === "POST" ? "{}" : undefined, headers: { accept: "application/json" } });
		assert.equal(refused.status, 401, `${method} ${path}, without the cookie`);
		assert.deepEqual(headersOf(refused), both, `${method} ${path}: the default's steps around the route's`);
	}
	const member = await call("Generated/MembersPage.member", { cookie: "member=Ada%20L" });
	assert.equal(member.status, 200);
	assert.equal(await member.text(), '"Ada L"', "the name the route's middleware handed on");
	assert.deepEqual(headersOf(member), both);
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
	// A page that goes before the end: the server lets go of the stream, and keeps answering.
	const gone = new AbortController();
	const cut = await fetch(`${site.url}/api/count/20`, { headers: { accept: "text/event-stream" }, signal: gone.signal });
	await cut.body.getReader().read();
	gone.abort();
	assert.equal((await fetch(`${site.url}/api/shout/rocx`)).status, 200);
	// The count's component is code only: a copy of the site as files can't stream.
	assert.ok(!(await (await fetch(`${site.url}/calls`)).text()).includes('class="count"'));
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
	await page.click(".board");
	assert.equal(await page.eval("document.querySelector('.board-message')"), null, "playing: the message is gone");
	assert.equal(await page.eval("document.querySelector('.board').classList.contains('playing')"), true);
	assert.deepEqual(await page.eval("window.effects"), [{ demo: "snake", name: "rocx:audio", arg: { url: "/sounds/start.wav", volume: 1, rate: 1 } }], "starting plays its sound, once");
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
});

// The platform's reference (/platform/reference) is read from the platform's modules
// (src/reference.mjs): every effect they expose is on it, and each has a doc comment to say there.

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
			// The file is what the browser's build renders (decision D), its URLs under the base too,
			// byte for byte outside its <NoHydration>s, from the answers and regions it has.
			const answers = JSON.parse(/<script type="application\/json" class="rocx-answers">(.*?)<\/script>/.exec(html)[1]);
			const rendered = runtime.renderToString({ path: route, answers, regions: Runtime.regionsOf(html) }).html;
			assert.equal(outsideRegions(rendered, (part) => underBase(part, "/rocx/")), html, `${route}, as files`);
		}
		for (const route of ROUTES) {
			const page = await open(`/rocx${route}`, pages.url);
			assert.ok(await page.eval("getComputedStyle(document.body).fontFamily !== ''"), `${route}: its stylesheet`);
			assert.deepEqual(page.console, [], `${route} logged nothing`);
			assert.deepEqual(page.errors, [], `${route} threw nothing`);
			assert.deepEqual((await asked(page)).filter((path) => !loads("/rocx/").includes(path) && path !== "/rocx/roc-bird.svg"), [], `${route}: asked for nothing else`);
		}
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
		const rendered = runtime.renderToString({ path, headers: Object.entries(headers), answers: page.answers, regions: page.regions });
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

test("the dev build (`just dev`) rebuilds fast, and every page still wakes up and works", { skip }, async () => {
	const started = performance.now();
	const facts = await build({ dev: true, log: () => {} });
	assert.ok(performance.now() - started < 2000, "a rebuild while editing takes well under two seconds");
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
