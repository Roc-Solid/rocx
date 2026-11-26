// `rocx build <dir> --static <out>` (D-073), end to end: test/static/app built and asked for its
// pages by rocx, written as files under a base (/base/), then served as plain files (nothing answers
// a request) and opened in Chromium, at a directory and at its index.html. rocx's own helpers
// (`page_file`, `under_base`, `links`, the arguments) are tested by its expects (rocx-cli/Static.roc),
// the HTTP client the CLI platform has for it by its unit tests (cli/host/src/http.rs), run here.
//
// Needs the toolchain (`just setup`: Roc, Rust for the server's host, Zig for the browser's) and
// Chromium (web/test/browser.mjs).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { hasRust, hostUnitTests, roc, root, rocxBinary } from "../server/build.mjs";
import { findChrome, launch } from "../web/test/browser.mjs";
import { serve } from "../web/test/serve.mjs";

let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)") || (!findChrome() && "no Chromium (set CHROME)");

const app = join(root, "test", "static", "app");

/** `rocx build` with `args`, from the repo: its exit code, stdout and stderr. The app is a SQLite one
 * (it names no database, D-105), so a Postgres DATABASE_URL in the environment isn't passed on. */
function rocx(...args) {
	const { DATABASE_URL: _postgres, ...env } = process.env;
	const ran = spawnSync(rocxBinary(), ["build", ...args], { cwd: root, env: { ...env, ROC: roc() }, encoding: "utf8" });
	return { status: ran.status, out: ran.stdout, err: ran.stderr };
}

/** Every file under `dir`, by its path there, sorted. */
function files(dir, at = "") {
	return readdirSync(join(dir, at), { withFileTypes: true })
		.flatMap((entry) => (entry.isDirectory() ? files(dir, join(at, entry.name)) : [join(at, entry.name)]))
		.sort();
}

let host;
let copy;
let built;
let site;
let browser;

before(async () => {
	if (skip) return;
	host = mkdtempSync(join(tmpdir(), "rocx-static-"));
	copy = join(host, "base");
	// What the last copy had and this one doesn't is gone: the copy replaces the directory.
	mkdirSync(copy);
	writeFileSync(join(copy, "index.html"), "an older copy");
	writeFileSync(join(copy, "stale.txt"), "from an older copy");
	built = rocx("test/static/app", "--static", relative(root, copy), "--base", "/base/", "--route", "/tags/roc");
	site = await serve(host);
	browser = await launch();
});

after(async () => {
	await browser?.close();
	await site?.close();
	if (host) rmSync(host, { recursive: true, force: true });
});

test("rocx build --static: every page as a file under the base, what a link or a --route answers that isn't a page, 404.html, the app's static/ and rocx/; what the copy lacks said", { skip }, () => {
	assert.equal(built.status, 0, built.err);
	const said = built.err.trimEnd().split("\n");
	assert.match(said[0], /^rocx build --static: 4 pages and 1 file in \S+, for \/base\/ \(\d+\.\d\d s\)$/);
	assert.deepEqual(said.slice(1), [
		"a link on / to /gone answered 404: not in the copy",
		"not in the copy, as only a server answers them: POST /api/notes",
		"not in the copy, as a directory's middleware answers each request as it comes: /account",
		"no page of /drafts/[id] was written: link to one from a page, or name it (--route /drafts/<id>)",
	]);
	assert.deepEqual(files(copy), ["404.html", "about/index.html", "api/hello", "blog/first-post/index.html", "index.html", "robots.txt", "rocx/app.wasm", "rocx/runtime.js", "rocx/start.js", "tags/roc/index.html"]);
	assert.equal(readFileSync(join(copy, "api/hello"), "utf8"), '"hello"', "the endpoint's answer, as it is");
	assert.match(readFileSync(join(copy, "tags/roc/index.html"), "utf8"), /<h1>Tag roc<\/h1>/);
	assert.match(readFileSync(join(copy, "404.html"), "utf8"), /404/);
	assert.ok(!existsSync(`${copy}.building`), "the copy made beside it is in its place");
	for (const page of files(copy).filter((file) => file.endsWith(".html"))) {
		const html = readFileSync(join(copy, page), "utf8");
		assert.deepEqual(html.match(/\s(?:href|src|action)="\/(?!base\/|\/)[^"]*"/g), null, `${page}: every URL under /base/`);
	}
	// The runtime as pages load it: minified (D-075), the same tokens without comments and
	// indentation (rocx-cli/Minify.roc's expects test the tokenizer; the pages below run it).
	const shipped = readFileSync(join(copy, "rocx", "runtime.js"), "utf8");
	const source = readFileSync(join(root, "web", "runtime.js"), "utf8");
	assert.ok(shipped.length < source.length * 0.7, `minified: ${shipped.length} bytes of ${source.length}`);
	assert.ok(!shipped.includes("/**") && !/^\s/m.test(shipped), "no comments, no indentation");
	assert.match(readFileSync(join(copy, "index.html"), "utf8"), /<a href="\/base\/about">About<\/a>/);
	assert.match(readFileSync(join(copy, "index.html"), "utf8"), /<a href="https:\/\/www\.roc-lang\.org">Roc<\/a>/, "another site's link as it is");
});

/** A tab that hydrates strictly (a page that isn't what the app renders throws) and notes when it
 * has (`rocx:ready`). */
async function tab(path) {
	const page = await browser.page();
	await page.beforeEachDocument("window.rocxStrict = true; document.addEventListener('rocx:ready', () => { window.hydrated = true; });");
	await page.goto(`${site.url}${path}`);
	await page.wait("window.hydrated === true");
	return page;
}

test("rocx build --static: the copy, as plain files under /base/, hydrates at a directory and at its index.html; its counter counts, and its links go where the copy has their pages", { skip }, async () => {
	for (const path of ["/base/", "/base/index.html", "/base/about/", "/base/about/index.html", "/base/blog/first-post/", "/base/tags/roc/index.html"]) {
		const page = await tab(path);
		assert.deepEqual(page.errors, [], `${path} threw nothing`);
		assert.deepEqual(page.console, [], `${path} logged nothing`);
		await page.close();
	}
	const page = await tab("/base/index.html");
	await page.click("button");
	await page.wait("document.querySelector('button').textContent.includes('Clicked 1 times')");
	// In place (D-040): the next page's file, from the copy.
	await page.click('a[href="/base/about"]');
	await page.wait("document.querySelector('h1')?.textContent === 'About'");
	assert.equal(await page.eval("location.pathname"), "/base/about");
	await page.click('a[href="/base/"]');
	await page.wait("document.querySelector('h1')?.textContent === 'Static'");
	assert.deepEqual(page.errors, []);
	await page.close();
});

test("rocx build --static refuses: arguments it can't take (exit 2); a copy where the app is, or over a directory that isn't a copy (exit 1)", { skip }, () => {
	assert.equal(rocx("test/static/app", "--static").status, 2);
	assert.equal(rocx("test/static/app", "test/e2e/app", "--static", "dist").status, 2);
	assert.equal(rocx("test/static/app", "--static", "dist", "--base", "base").status, 2);
	assert.equal(rocx("test/static/app", "--static", "dist", "--route", "tags/roc").status, 2);
	assert.equal(rocx("test/static/app", "--static", "dist", "--dev").status, 2);
	const inside = rocx("test/static/app", "--static", "test/static");
	assert.equal(inside.status, 1);
	assert.match(inside.err, /holds the app or this directory/);
	const other = mkdtempSync(join(tmpdir(), "rocx-static-other-"));
	try {
		writeFileSync(join(other, "notes.txt"), "mine");
		const over = rocx("test/static/app", "--static", other);
		assert.equal(over.status, 1);
		assert.match(over.err, /isn't empty and has no index\.html/);
		assert.equal(readFileSync(join(other, "notes.txt"), "utf8"), "mine", "left as it was");
	} finally {
		rmSync(other, { recursive: true, force: true });
	}
});

test("rocx build --static: a server that won't start fails the copy, saying what it said, and leaves the copy before", { skip }, () => {
	const failed = rocx("test/static/app", "--static", relative(root, copy), "--base", "/base/", "--built", "test/static/app/build/static", "--", "--no-such-option");
	assert.equal(failed.status, 1);
	assert.match(failed.err, /the app's server ended \(exit 2\) before it listened/);
	assert.match(failed.err, /unknown argument --no-such-option/);
	assert.ok(existsSync(join(copy, "about", "index.html")), "the copy before is still there");
	assert.ok(!existsSync(`${copy}.building`));
});

test("the CLI host's HTTP client (cli/host/src/http.rs): a body by its length, a chunked one put together, one read to the end, and an answer cut short is an error", { skip: !hasRust() && "no Rust (run `just setup`)" }, () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-http-"));
	try {
		const ran = hostUnitTests("http.rs", join(dir, "http-unit-tests"), join(root, "cli", "host"));
		assert.equal(ran.status, 0, ran.stdout + ran.stderr);
		assert.match(ran.stdout, /test result: ok\. 4 passed/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("rocx build --client --dev: the runtime as it is written, to read and debug; without --dev, minified", { skip }, () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-client-"));
	try {
		assert.equal(rocx("test/static/app", "--client", join(dir, "dev"), "--dev").status, 0);
		assert.equal(readFileSync(join(dir, "dev", "static", "rocx", "runtime.js"), "utf8"), readFileSync(join(root, "web", "runtime.js"), "utf8"));
		assert.equal(rocx("test/static/app", "--client", join(dir, "shipped")).status, 0);
		assert.ok(readFileSync(join(dir, "shipped", "static", "rocx", "runtime.js")).length < readFileSync(join(root, "web", "runtime.js")).length * 0.7);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
