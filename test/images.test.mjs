// enhanced:src (D-125), end to end: test/images/app's page names photos the server makes smaller
// copies of. The first page shows each photo's src alone and queues it; once its copies are made,
// the page names them (srcset, sizes, the photo's size), and they are served as files the browser
// keeps for good. A photo in static/ and one a route answers a signed-out visitor get copies; one a
// route refuses, one that isn't there and one that isn't a photo never do. The images directory is
// read again as the server starts, a changed file's old copies aren't its, and a static build's
// server (--images-wait) has them on its first page; and in a browser, another photo in an
// enhanced:src drops what the server wrote for the last. How copies are made, kept and swept is
// server/host/src/images.rs's unit tests'; what rocx writes for enhanced:src is
// test/transpile.test.mjs's.
//
// Needs the toolchain (`just setup`: Roc, Rust for the server's host, Zig for the browser's), and
// Chromium for the last test.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hasRust, roc, root } from "../server/build.mjs";
import { buildForTests, launchBrowser, startServer, until } from "../packages/testing/index.mjs";

let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)");

const app = join(root, "test", "images", "app");

/** The page's `<img id="…">`'s attributes, by name. */
function img(html, id) {
	const tag = new RegExp(`<img id="${id}"([^>]*)>`).exec(html);
	assert.ok(tag, `the page has <img id="${id}">: ${html}`);
	return Object.fromEntries([...tag[1].matchAll(/([a-z-]+)="([^"]*)"/g)].map(([, name, value]) => [name, value]));
}

/** A `srcset`'s candidates: each URL and its width. */
function candidates(srcset) {
	return srcset.split(", ").map((candidate) => {
		const [url, width] = candidate.split(" ");
		return { url, width: Number(width.replace(/w$/, "")) };
	});
}

let server;
let built;
/** Where the servers run: `data/images` is under it. */
let cwd;
/** The app's static/, copied, so a test can change a photo. */
let statics;
const servers = [];

async function started(options = {}) {
	const started = await startServer(server, { cwd: options.cwd ?? cwd, statics: [options.statics ?? statics, ...built.statics], flags: options.flags ?? [] });
	servers.push(started);
	return started;
}

/** The page, once `ready(html)` holds (each photo is made in the background, a moment after). */
async function pageWhen(running, ready, what) {
	let html = "";
	await until(async () => {
		html = await (await fetch(`${running.url}/`)).text();
		return ready(html);
	}, { ms: 30_000, what });
	return html;
}

before(async () => {
	if (skip) return;
	built = await buildForTests(app);
	server = built.server;
	cwd = mkdtempSync(join(tmpdir(), "rocx-images-"));
	statics = join(cwd, "static");
	cpSync(join(app, "static"), statics, { recursive: true });
});

after(async () => {
	for (const running of servers) await running.stop();
	if (cwd) rmSync(cwd, { recursive: true, force: true });
});

test("the first page shows each photo's src, and queues it; the next, once made, its copies", { skip }, async () => {
	const running = await started();
	const first = await (await fetch(`${running.url}/`)).text();
	const shown = img(first, "static");
	assert.equal(shown.src, "/photo.jpg");
	assert.equal(shown.srcset, undefined, "nothing made yet: the photo's src alone");
	assert.equal(shown.loading, "lazy");
	assert.equal(shown.decoding, "async");
	assert.equal(img(first, "plain").srcset, undefined);

	const html = await pageWhen(running, (page) => img(page, "static").srcset && img(page, "route").srcset, "both photos' copies");
	const photo = img(html, "static");
	assert.equal(photo.src, "/photo.jpg", "the src stays the photo's");
	assert.equal(photo.sizes, "100vw");
	assert.equal(photo.width, "1000");
	assert.equal(photo.height, "600");
	const copies = candidates(photo.srcset);
	assert.deepEqual(copies.map((copy) => copy.width), [160, 320, 640, 960, 1000]);
	for (const copy of copies) assert.match(copy.url, new RegExp(`^/rocx/images/[0-9a-f]{16}-${copy.width}\\.webp$`));

	// The route's photo (400 by 300, its width written as 200): its height in its shape, and the
	// width the page shows it at as its sizes.
	const routed = img(html, "route");
	assert.equal(routed.src, "/photos/one");
	assert.equal(routed.width, "200");
	assert.equal(routed.height, "150");
	assert.equal(routed.sizes, "(max-width: 200px) 100vw, 200px", "the window's width, at most the written width");
	assert.deepEqual(candidates(routed.srcset).map((copy) => copy.width), [160, 320, 400]);

	// A plain src is left as written.
	assert.equal(img(html, "plain").srcset, undefined);

	// A copy: WebP, its width, kept by the browser for good.
	const copy = await fetch(`${running.url}${copies[2].url}`);
	assert.equal(copy.status, 200);
	assert.equal(copy.headers.get("content-type"), "image/webp");
	assert.equal(copy.headers.get("cache-control"), "public, max-age=31536000, immutable");
	const bytes = Buffer.from(await copy.arrayBuffer());
	assert.equal(bytes.subarray(0, 4).toString("latin1"), "RIFF");
	assert.equal(bytes.subarray(8, 12).toString("latin1"), "WEBP");
	assert.ok(bytes.length < readFileSync(join(statics, "photo.jpg")).length, "a 640-pixel copy is smaller than the 1000-pixel JPEG");

	// A name the server has no copy by.
	assert.equal((await fetch(`${running.url}/rocx/images/0123456789abcdef-160.webp`)).status, 404);
});

test("a photo a route refuses a signed-out visitor, one that isn't there, and one that isn't a photo get no copies", { skip }, async () => {
	const running = await started();
	await pageWhen(running, (page) => img(page, "static").srcset && img(page, "route").srcset, "the made photos");
	// Asked again, and again: each was tried once, and is remembered.
	for (let n = 0; n < 3; n++) {
		const html = await (await fetch(`${running.url}/`)).text();
		for (const id of ["private", "missing", "text"]) {
			const shown = img(html, id);
			assert.equal(shown.srcset, undefined, `${id} has no copies`);
			assert.equal(shown.width, undefined);
		}
	}
	assert.ok(existsSync(join(cwd, "data", "images")));
});

test("the images directory is its own index: a server started again has the copies on its first page", { skip }, async () => {
	const kept = readdirSync(join(cwd, "data", "images"));
	assert.ok(kept.some((name) => name.endsWith(".txt")), `a photo's .txt: ${kept}`);
	const running = await started();
	const first = await (await fetch(`${running.url}/`)).text();
	assert.ok(img(first, "static").srcset, "the static photo's copies, read from the directory");
});

test("a changed photo's old copies aren't its: its src alone, then its own copies", { skip }, async () => {
	const running = await started();
	const before = img(await (await fetch(`${running.url}/`)).text(), "static");
	assert.ok(before.srcset);
	// Another photo at the same path: the route's PNG, 400 by 300.
	writeFileSync(join(statics, "photo.jpg"), readFileSync(join(app, "photos", "one.png")));
	const changed = img(await (await fetch(`${running.url}/`)).text(), "static");
	assert.equal(changed.srcset, undefined, "the old photo's copies aren't the new one's");
	const html = await pageWhen(running, (page) => img(page, "static").srcset, "the new photo's copies");
	const now = img(html, "static");
	assert.equal(now.width, "400");
	assert.equal(now.height, "300");
	assert.notEqual(candidates(now.srcset)[0].url, candidates(before.srcset)[0].url);
	cpSync(join(app, "static", "photo.jpg"), join(statics, "photo.jpg"));
});

test("a static build's server (--images-wait) has every photo's copies on its first page", { skip }, async () => {
	const fresh = mkdtempSync(join(tmpdir(), "rocx-images-wait-"));
	try {
		const running = await started({ cwd: fresh, flags: ["--images-wait"] });
		const first = await (await fetch(`${running.url}/`)).text();
		assert.ok(img(first, "static").srcset, "made as the page rendered");
		assert.ok(img(first, "route").srcset);
		assert.equal(img(first, "private").srcset, undefined);
		await running.stop();
	} finally {
		rmSync(fresh, { recursive: true, force: true });
	}
});

test("in the browser, another photo in an enhanced:src drops the copies and the size the server wrote for the last; a page reached in place has them from its document", { skip }, async () => {
	const running = await started();
	await pageWhen(running, (page) => img(page, "switched").srcset && img(page, "route").srcset, "both photos' copies");
	const browser = await launchBrowser();
	if (!browser) return;
	try {
		const tab = await browser.open(`${running.url}/`);
		const attributes = async () => JSON.parse(await tab.page.eval(`JSON.stringify(Object.fromEntries([...document.getElementById("switched").attributes].map((a) => [a.name, a.value])))`));
		const hydrated = await attributes();
		assert.ok(hydrated.srcset, "the server's copies, kept as the page hydrates");
		assert.equal(hydrated.width, "1000");
		await (await tab.getByRole("button", { name: "Another photo" })).click();
		await tab.waitFor(async () => (await attributes()).src === "/photos/one");
		const now = await attributes();
		assert.deepEqual(
			Object.keys(now).sort(),
			["alt", "decoding", "id", "loading", "src"],
			"the last photo's srcset, sizes, width and height are gone; what the markup says stays",
		);
		assert.deepEqual(tab.errors, []);

		// In place (D-040): the photos' page made by the runtime, given what the server wrote from its
		// document.
		const away = await browser.open(`${running.url}/elsewhere`);
		await (await away.getByRole("link", { name: "The photos" })).click();
		await away.waitFor(async () => (await away.page.eval(`Boolean(document.getElementById("static"))`)));
		const arrived = JSON.parse(await away.page.eval(`JSON.stringify(Object.fromEntries(["static", "route", "switched", "missing"].map((id) => { const image = document.getElementById(id); return [id, { srcset: image.getAttribute("srcset"), sizes: image.getAttribute("sizes"), width: image.getAttribute("width"), height: image.getAttribute("height") }]; })))`));
		assert.ok(arrived.static.srcset, "the static photo's copies, from the document");
		assert.equal(arrived.static.sizes, "100vw");
		assert.equal(arrived.static.width, "1000");
		assert.equal(arrived.static.height, "600");
		assert.equal(arrived.route.sizes, "(max-width: 200px) 100vw, 200px");
		assert.equal(arrived.route.width, "200", "as the markup writes it");
		assert.equal(arrived.route.height, "150");
		assert.ok(arrived.switched.srcset);
		assert.equal(arrived.missing.srcset, null);
		assert.equal(await away.page.eval("location.pathname"), "/");
		assert.deepEqual(away.errors, []);
	} finally {
		await browser.close();
	}
});
