// Through the real compiler: the fixture page (pure components, in an app on the web platform)
// builds, its `expect`s pass, and a mistake in it is reported at the .rocx line, with the .rocx code
// quoted; the routes fixture's links are checked, and its pages served natively; an app whose route
// files are components (test/e2e/app) is built by rocx build, served natively and hydrated in Chromium. Needs Roc:
// the one `just setup` links, else $ROC; the app, the toolchain (`just setup`) and Chromium (web/test/browser.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildApp, buildHost, hasRust, roc as findRoc, rocxBinary, start, syncShared, zig } from "../server/build.mjs";
import { findChrome, launch } from "../web/test/browser.mjs";
import { testDatabase } from "../packages/testing/postgres.mjs";
import { Runtime } from "../web/runtime.js";

const here = dirname(fileURLToPath(import.meta.url));
const rocx = rocxBinary();
// The compiler `just setup` links (the fork rocx builds with), else $ROC: server/build.mjs's. Never
// the `roc` on PATH, which may lack the fork's fixes.
const roc = (() => {
	try {
		return findRoc();
	} catch {
		return "";
	}
})();
const hasRoc = roc !== "" && spawnSync(roc, ["version"]).status === 0;

/** A copy of the fixture beside it, so that the platform's path (../../../web/platform) still holds. */
function fixtureCopy(edit = (source) => source) {
	const dir = mkdtempSync(join(here, "e2e", "run-"));
	cpSync(join(here, "e2e", "fixture"), dir, { recursive: true });
	writeFileSync(join(dir, "Page.rocx"), edit(readFileSync(join(dir, "Page.rocx"), "utf8")));
	return dir;
}

const run = (...args) => spawnSync(rocx, args, { encoding: "utf8" });

test("the fixture page compiles and its expects pass", { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" }, () => {
	const dir = fixtureCopy();
	try {
		assert.equal(run("build", dir).status, 0);
		const checked = run("check", "--", roc, "test", join(dir, "main.roc"));
		assert.equal(checked.status, 0, checked.stdout);
		assert.match(checked.stdout, /All \(\d+\) tests passed/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a type error is reported at the .rocx line, quoting the .rocx code", { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" }, () => {
	const dir = fixtureCopy((source) => source.replace("<a href={post.link}>{post.title}</a>", "<a href={post.link}>{post.status}</a>"));
	try {
		assert.equal(run("build", dir).status, 0);
		const line = readFileSync(join(dir, "Page.rocx"), "utf8").split("\n").findIndex((l) => l.includes("{post.status}</a>")) + 1;
		const checked = run("check", "--", roc, "check", join(dir, "main.roc"));
		assert.notEqual(checked.status, 0);
		assert.match(checked.stdout, new RegExp(`Page\\.rocx:${line}:\\d+`));
		assert.match(checked.stdout, /<a href=\{post\.link\}>\{post\.status\}<\/a>/, "the .rocx line is quoted");
		assert.doesNotMatch(checked.stdout, /Html\.element\("a"/, "not the generated one");
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a markup error stops the build at its line", () => {
	const dir = fixtureCopy((source) => source.replace("</ul>", "</ol>"));
	try {
		const built = run("build", dir);
		assert.equal(built.status, 1);
		assert.match(built.stderr, /Page\.rocx:\d+:\d+: <ul> is closed by <\/ol>/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("lint refuses Html.source_text in hand-written Roc", () => {
	const dir = mkdtempSync(join(here, "e2e", "run-"));
	try {
		writeFileSync(join(dir, "Sneaky.roc"), 'x = Html.source_text("<script>")\n');
		assert.equal(run("lint", dir).status, 1);
		writeFileSync(join(dir, "Sneaky.roc"), 'x = "calls Html.source_text(…)" # Html.source_text\ny =\n\t\\\\ Html.source_text\n');
		assert.equal(run("lint", dir).status, 0, "a mention in a string or a comment is not a call");
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a file that mentions the marker isn't taken for one rocx wrote", () => {
	const dir = mkdtempSync(join(here, "e2e", "run-"));
	try {
		const source = 'docs = "# rocx: generated from X.rocx"\nx = 1\n';
		writeFileSync(join(dir, "Docs.roc"), source);
		assert.equal(run("build", dir).status, 0);
		assert.equal(readFileSync(join(dir, "Docs.roc"), "utf8"), source, "not deleted as stale");
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

// ---- Routes: test/e2e/routes, an app of pages (+page.rocx), layouts and an error page, all components ----

/** A copy of the routed fixture, beside it, `edit` given each route file's path and source. It is an
 * app on the server platform, whose copies of the modules both platforms have are brought up to date. */
function routesCopy(edit = (path, source) => source) {
	syncShared();
	const dir = mkdtempSync(join(here, "e2e", "run-"));
	cpSync(join(here, "e2e", "routes"), dir, { recursive: true });
	const page = join(dir, "routes", "blog", "[slug]", "+page.rocx");
	writeFileSync(page, edit(page, readFileSync(page, "utf8")));
	return dir;
}

test("routes: each route file a module, its page in Root, a path for every page, a function of its params", { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" }, () => {
	const dir = routesCopy();
	try {
		const built = run("build", dir);
		assert.equal(built.status, 0, built.stderr);
		assert.match(readFileSync(join(dir, "Generated", "BlogSlugPage.roc"), "utf8").split("\n")[2], /^BlogSlugPage := \[\]\.\{$/, "the module's line, on the route file's blank line");
		assert.match(readFileSync(join(dir, "Generated", "BlogSlugPage.roc"), "utf8"), /^import Paths$/m, "its imports, from where rocx wrote it");
		assert.match(readFileSync(join(dir, "Generated", "Root.roc"), "utf8"), /Html\.component\(\|\| BlogSlugPage\.view!\(\{ params: \|\| params \}\)\)/, "Root renders the page, given its params (a getter, D-039)");
		const checked = run("check", "--", roc, "test", join(dir, "main.roc"));
		assert.equal(checked.status, 0, checked.stdout);
		assert.match(checked.stdout, /All \(\d+\) tests passed/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("routes: a link with the wrong params doesn't compile, and is reported at the route file's line", { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" }, () => {
	const dir = routesCopy((path, source) => source.replace('Paths.blog_slug({ slug: "other" })', 'Paths.blog_slug({ slg: "other" })'));
	try {
		assert.equal(run("build", dir).status, 0);
		const checked = run("check", "--", roc, "check", join(dir, "main.roc"));
		assert.notEqual(checked.status, 0);
		assert.match(checked.stdout, /routes\/blog\/\[slug\]\/\+page\.rocx:8:\d+/);
		assert.match(checked.stdout, /<a href=\{Paths\.blog_slug\(\{ slg: "other" \}\)\}>The other one<\/a>/, "the route file's line, quoted");
		assert.match(checked.stdout, /\{ slug: Str \}/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("routes: a route file with no blank line before its definitions builds, its module's line on the first one's, and a mistake in it is still reported at its line", { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" }, () => {
	const dir = routesCopy((path, source) => source.replace("import ../../../Generated/Paths\n\n", "import ../../../Generated/Paths\n"));
	try {
		const built = run("build", dir);
		assert.equal(built.status, 0, built.stderr);
		assert.equal(readFileSync(join(dir, "Generated", "BlogSlugPage.roc"), "utf8").split("\n")[3], "BlogSlugPage := [].{ view! = |{ params: params! }|");
		const tested = run("check", "--", roc, "test", join(dir, "main.roc"));
		assert.equal(tested.status, 0, tested.stdout);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
	const wrong = routesCopy((path, source) => source.replace("import ../../../Generated/Paths\n\n", "import ../../../Generated/Paths\n").replace('Paths.blog_slug({ slug: "other" })', 'Paths.blog_slug({ slg: "other" })'));
	try {
		assert.equal(run("build", wrong).status, 0);
		const checked = run("check", "--", roc, "check", join(wrong, "main.roc"));
		assert.notEqual(checked.status, 0);
		assert.match(checked.stdout, /routes\/blog\/\[slug\]\/\+page\.rocx:7:\d+/);
	} finally {
		rmSync(wrong, { recursive: true, force: true });
	}
	// An endpoint with no blank line after its imports: its module's line before its first definition
	// (the annotation rocx build copies into Api), and a mistake in it at its column there.
	const endpoint = routesCopy();
	try {
		mkdirSync(join(endpoint, "routes", "feed"));
		writeFileSync(join(endpoint, "routes", "feed", "+server.roc"), "import pf.Server\nimport pf.Endpoint\nget! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)\nget! = |_| Ok(nobody)\n");
		const built = run("build", endpoint);
		assert.equal(built.status, 0, built.stderr);
		assert.equal(readFileSync(join(endpoint, "Generated", "FeedServer.roc"), "utf8").split("\n")[2], "FeedServer := [].{ get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)");
		const checked = run("check", "--", roc, "check", join(endpoint, "main.roc"));
		assert.notEqual(checked.status, 0);
		assert.match(checked.stdout, /routes\/feed\/\+server\.roc:4:15\n\nNothing is named nobody in this scope\.\n\nget! = \|_\| Ok\(nobody\)\n {14}\^{6}/, `the endpoint's line and column, quoted:\n${checked.stdout}`);
	} finally {
		rmSync(endpoint, { recursive: true, force: true });
	}
});

test("routes: a directory that isn't a path's part is refused", () => {
	const other = routesCopy();
	try {
		cpSync(join(other, "routes", "blog"), join(other, "routes", "Blog Posts"), { recursive: true });
		const built = run("build", other);
		assert.equal(built.status, 1);
		assert.match(built.stderr, /a directory is a path's part in lower case/);
	} finally {
		rmSync(other, { recursive: true, force: true });
	}
});

// ---- An app of components: test/e2e/app, its route files components (`import pf.Html`, `view!`) ----

const root = join(here, "..");
const appSkip = (!hasRoc && "no Roc (run `just setup`, or set ROC)") || (spawnSync(zig(), ["version"]).status !== 0 && "no Zig (run `just setup`)") || (!hasRust() && "no Rust (run `just setup`)") || (!findChrome() && "no Chromium (set CHROME)");

/** The web platform's host, built if it isn't, or is older than its sources. */
function webHost() {
	const object = join(root, "web", "platform", "targets", "wasm32", "host.wasm");
	const sources = [join(root, "web", "host", "host.zig"), join(root, "web", "host", "roc_platform_abi.zig")];
	if (existsSync(object) && sources.every((source) => statSync(object).mtimeMs >= statSync(source).mtimeMs)) return;
	mkdirSync(dirname(object), { recursive: true });
	const built = spawnSync(zig(), ["build-obj", sources[0], "-target", "wasm32-freestanding", "-O", "ReleaseSmall", "-fcompiler-rt", `-femit-bin=${object}`], { encoding: "utf8" });
	assert.equal(built.status, 0, built.stderr);
}

/** A tab that hydrates strictly (a page that isn't what the app renders throws) and notes `rocx:ready`. */
async function strictTab(browser) {
	const tab = await browser.page();
	await tab.send("Page.enable");
	await tab.send("Page.addScriptToEvaluateOnNewDocument", { source: 'window.rocxStrict = true; document.addEventListener("rocx:ready", (event) => { window.ready = event.detail; });' });
	return tab;
}

/** What a page asked the server for besides itself: each path, in order. */
const asked = (tab) => tab.eval('performance.getEntriesByType("resource").map((entry) => new URL(entry.name).pathname)');

test("an app of components: rocx build writes its Root, Routes and App, its server serves it, and each page hydrates in Chromium", { skip: appSkip }, async () => {
	syncShared();
	const dir = mkdtempSync(join(here, "e2e", "run-"));
	cpSync(join(here, "e2e", "app"), dir, { recursive: true });
	const client = join(dir, "build", "client");
	const servers = [];
	let browser = null;
	try {
		// rocx build writes the program; the author wrote main.roc, the route files and their modules.
		// A dev build: the stories too (Counter's and Badge's), which change no page of the app's.
		const built = run("build", dir, "--client", client, "--dev");
		assert.equal(built.status, 0, built.stderr);
		assert.ok(!existsSync(join(dir, "Generated", "ServerFunctions.roc")), "no server functions (D-023): rocx writes no ServerFunctions");
		const app = readFileSync(join(dir, "Generated", "App.roc"), "utf8");
		assert.match(app, /^\tjobs = \[Job\.handler\(Jobs\.welcome\)\]$/m, "the job, found in Jobs.roc: App.jobs, for the jobs plugin");
		assert.match(app, /\t\tmigrations: \[\{ name: "0001_e2e_notes\.sql", sql: m0001_e2e_notes \}, \{ name: "0002_e2e_note_index\.sql", sql: m0002_e2e_note_index \}\],/, "the migrations, in order");
		assert.ok(existsSync(join(client, "static", "rocx", "start.js")) && existsSync(join(client, "static", "rocx", "runtime.js")), "what a page loads, beside where the wasm goes");
		// The browser's half, from the main.roc rocx wrote; the server's, natively (optimized, as it ships).
		webHost();
		const wasm = spawnSync(roc, ["build", "--target=wasm32", "--opt=size", `--output=${join(client, "static", "rocx", "app.wasm")}`, join(client, "main.roc")], { encoding: "utf8" });
		assert.equal(wasm.status, 0, `${wasm.stdout}${wasm.stderr}`);
		buildHost();
		buildApp(join(dir, "main.roc"), join(dir, "build", "server"), { opt: "speed" });
		writeFileSync(join(dir, "build", "started.txt"), "e2e");
		const flags = ["--static", join(client, "static"), "--context-file", join(dir, "build", "started.txt")];
		const server = await start(join(dir, "build", "server"), flags);
		servers.push(server);

		// As the server answers: a page, 200; a path no page has, the error page, 404 (text for a client
		// that doesn't take HTML); a page that fails, the error page inside the layout, 500; a page
		// behind its route file's middleware, refused without a cookie, its endpoint's answer in it with one.
		const get = async (path, headers = {}) => {
			const response = await fetch(`${server.url}${path}`, { headers: { accept: "text/html", ...headers } });
			return { status: response.status, app: response.headers.get("x-app"), html: await response.text() };
		};
		const home = await get("/");
		assert.equal(home.status, 200);
		assert.equal(home.app, "e2e", "the app's default middleware ran");
		assert.match(home.html, /^<!doctype html> <html lang="en"><head><meta charset="utf-8"> <title>Home<\/title><\/head> <body><nav>.*<span class="badge">e2e<\/span><\/nav> <main><!--errored--><section class="home"><h1>Home<\/h1> <span class="badge">pure<\/span> <button class="count" type="button">Clicked <!--x-->1<!--\/x--><\/button> <!--nohydration--><aside class="note">Prose the browser never hydrates, with a <span class="badge">badge<\/span> in it\.<\/aside><!--\/nohydration--><\/section><!--\/errored--><\/main> <footer class="at"><!--x-->\/<!--\/x--><\/footer><script type="application\/json" class="rocx-answers">\[\]<\/script><script type="module" data-rocx src="\/rocx\/start\.js"><\/script><\/body><\/html>$/);
		const post = await get("/posts/hello");
		assert.match(post.html, /<head><meta charset="utf-8"> <title data-rocx>Post hello<\/title><title>A post<\/title><\/head>.*<main><!--errored--><div class="posts" data-slug="hello"><article class="post"><!--x--><!--\/x--> <h1>Post <!--x-->hello<!--\/x--><\/h1> <a href="\/posts\/other">/, "its param, in the page (a getter, D-039: a hole of its own) and its layout; the root layout's <Errored> around both; the page's <Title> first in <head>, before the layout's");
		// A route file's own components, defined below its page: one with a signal, a pure one.
		const local = await get("/local");
		assert.equal(local.status, 200);
		assert.match(local.html, /<title data-rocx>Local 0<\/title><title>Local<\/title>.*<section class="local"><!--x--><!--\/x--> <p class="board rx-[a-z0-9]+"><!--x-->0<!--\/x--><\/p> <span class="tag">its own<\/span> <button class="bump" type="button">Bump<\/button><\/section>/, "a route file's own components, its <style> scoping its Board");
		const missing = await get("/nope");
		assert.equal(missing.status, 404);
		assert.match(missing.html, /<title>Not here<\/title>.*<main><section class="error"><h1><!--x-->404<!--\/x--><\/h1> <p class="problem"><!--x-->nothing at \/nope<!--\/x--><\/p><\/section><\/main> <footer class="at"><!--x-->\/nope<!--\/x--><\/footer>/);
		const text = await fetch(`${server.url}/nope`);
		assert.deepEqual([text.status, text.headers.get("content-type"), await text.text()], [404, "text/plain; charset=utf-8", "nothing at /nope"]);
		const broken = await get("/broken");
		assert.equal(broken.status, 500);
		assert.match(broken.html, /<title>Broken<\/title>.*<main><!--errored:failed--><section class="error"><h1><!--x-->500<!--\/x--><\/h1> <p class="problem"><!--x-->nothing above provides Generated\/BrokenPage\.missing[^<]*<!--\/x--><\/p><\/section><!--\/errored--><\/main>/, "the error page, inside the layout");
		assert.deepEqual([(await get("/members")).status, (await get("/members")).html], [401, "members only"]);
		// The jobs page, a plugin's page: behind the app's middleware (its header), then its guard.
		assert.deepEqual(await get("/admin/jobs"), { status: 401, app: "e2e", html: "members only" }, "the guard refuses a stranger");
		const jobsPage = await get("/admin/jobs", { cookie: "member=Ada" });
		assert.equal(jobsPage.app, "e2e");
		assert.match(jobsPage.html, /<body class="rocx-admin">/, "the jobs page, in the admin look (no database here, so it says why)");
		const member = await get("/members", { cookie: "member=Ada" });
		assert.equal(member.status, 200);
		assert.match(member.html, /<p class="who"><!--x-->Welcome, Ada<!--\/x--><\/p>/, "its endpoint, read as the page renders, answered by its route behind the file's middleware, in-process");
		const carried = JSON.parse(/<script type="application\/json" class="rocx-answers">(.*?)<\/script>/s.exec(member.html)[1]);
		assert.deepEqual(carried, [["GET /members", "", JSON.stringify({ status: 200, body: JSON.stringify("Welcome, Ada") })]], "and recorded, once, though read twice");
		assert.match(member.html, /<!--nohydration--><p class="again">Welcome, Ada, said once<\/p><!--\/nohydration-->/, "read inside a <NoHydration> too: the browser never reads it there");
		// A component's story is the app's page: Root renders it in the root layout, with the front
		// page's meta; the catalog lists every story; one that isn't there is 404.
		const catalog = await get("/__rocx/stories");
		assert.equal(catalog.status, 200);
		assert.deepEqual(JSON.parse(/const STORIES = (\[.*\]);/.exec(catalog.html)[1]).map((story) => story.id), ["Counter/at-ten", "Ui/Badge/label"]);
		const story = await get("/__rocx/stories/Counter/at-ten");
		assert.equal(story.status, 200);
		assert.match(story.html, /<title>Home<\/title>.*<main><!--errored--><button class="count" type="button">Clicked <!--x-->10<!--\/x--><\/button><!--\/errored--><\/main> <footer class="at"><!--x-->\/__rocx\/stories\/Counter\/at-ten<!--\/x--><\/footer>/);
		assert.match((await get("/__rocx/stories/Ui/Badge/label")).html, /<main><!--errored--><span class="badge">story<\/span><!--\/errored--><\/main>/);
		assert.equal((await get("/__rocx/stories/Counter/nothing")).status, 404);
		const answered = await fetch(`${server.url}/members`, { headers: { accept: "application/json", cookie: "member=Grace" } });
		assert.deepEqual([answered.status, await answered.text()], [200, '"Welcome, Grace"'], "the same endpoint, over HTTP, for JSON");
		assert.equal((await fetch(`${server.url}/members`, { headers: { accept: "application/json" } })).status, 401);

		// A <NoHydration>'s children, and the import only they used, are the server's alone.
		const wasmBytes = readFileSync(join(client, "static", "rocx", "app.wasm"));
		assert.equal(wasmBytes.includes("Prose the browser never hydrates"), false, "not in the browser's wasm");
		assert.doesNotMatch(readFileSync(join(client, "Generated", "RootPage.roc"), "utf8"), /^import \.\.\/Ui\/Note$/m, "nor imported by its copy of the page");

		// The same pages, rendered by the browser's half in Node, from the answers the native page
		// recorded (nothing is answered that the page didn't record): byte for byte outside each
		// <NoHydration>, and inside it the native page's own, which only the server renders.
		const runtime = await Runtime.load(wasmBytes);
		for (const [path, headers, native, regions] of [["/", [], home, 1], ["/posts/hello", [], post, 0], ["/local", [], local, 0], ["/nope", [], missing, 0], ["/broken", [], broken, 0], ["/members", [["cookie", "member=Ada"]], member, 1], ["/__rocx/stories/Counter/at-ten", [], story, 0]]) {
			const answers = JSON.parse(/<script type="application\/json" class="rocx-answers">(.*?)<\/script>/.exec(native.html)[1]);
			assert.equal(Runtime.regionsOf(native.html).length, regions, `${path}'s <NoHydration>s`);
			assert.equal(runtime.renderToString({ path, headers, answers, regions: Runtime.regionsOf(native.html) }).html, native.html, path);
			assert.equal(runtime.status, native.status, `${path}'s <HttpStatusCode>`);
		}

		// In Chromium, strictly: each page hydrates from what came with it, asking for nothing but
		// start.js, the runtime and the wasm, all under /rocx/; a click is the app's.
		browser = await launch();
		const loads = ["/rocx/start.js", "/rocx/app.wasm", "/rocx/runtime.js"];
		for (const [path, check] of [
			["/", "document.querySelector('.home .badge').textContent === 'pure' && document.title === 'Home' && document.querySelector('.home .note').textContent === 'Prose the browser never hydrates, with a badge in it.'"],
			["/posts/hello", "document.querySelector('.post h1').textContent === 'Post hello' && document.querySelector('.posts').dataset.slug === 'hello' && document.title === 'Post hello'"],
			["/local", "document.querySelector('.local .board').textContent === '0' && document.querySelector('.local .tag').textContent === 'its own' && document.title === 'Local 0'"],
			["/nope", "document.querySelector('.error h1').textContent === '404' && performance.getEntriesByType('navigation')[0].responseStatus === 404"],
			["/broken", "document.querySelector('main .error h1').textContent === '500' && document.querySelector('.broken') === null && performance.getEntriesByType('navigation')[0].responseStatus === 500"],
			["/__rocx/stories/Counter/at-ten", "document.querySelector('main .count').textContent === 'Clicked 10' && document.title === 'Home'"],
		]) {
			const tab = await strictTab(browser);
			await tab.goto(`${server.url}${path}`);
			await tab.wait("window.ready", 5000);
			assert.deepEqual(tab.errors, [], path);
			assert.deepEqual(tab.console.filter((entry) => entry.type === "warning" || entry.type === "error"), [], path);
			assert.equal(await tab.eval(check), true, path);
			assert.deepEqual((await asked(tab)).sort(), [...loads].sort(), `${path}: nothing asked of the server`);
			assert.equal(await tab.eval("document.querySelector('footer.at').textContent"), path, "where it is, as the browser sees it");
			if (path === "/" || path === "/posts/hello" || path.startsWith("/__rocx/stories/")) {
				const before = await tab.eval("document.querySelector('.count').textContent");
				await tab.click(".count");
				await tab.wait(`document.querySelector('.count').textContent !== ${JSON.stringify(before)}`);
				assert.equal(await tab.eval("window.ready.runtime.stats.patches > 0 && document.querySelector('.count').textContent"), path === "/" ? "Clicked 2" : "Clicked 11");
			} else if (path === "/local") {
				await tab.click(".bump");
				await tab.wait("document.querySelector('.local .board').textContent === '1' && document.title === 'Local 1'");
				assert.equal(await tab.eval("[...document.head.querySelectorAll('title')].map((title) => title.textContent).join(' | ')"), "Local 1 | Local", "the page's <Title>, kept by the browser, before the layout's own");
			} else assert.equal(await tab.eval("window.ready.runtime.stats.patches"), path === "/broken" ? 3 : 0, "a boundary that failed on the server is built again: its inside runs again, and fails again, and the error page's two holes that read its props (getters, D-039) are made with it");
		}
		const tab = await strictTab(browser);
		await tab.goto(`${server.url}/`);
		await tab.eval("document.cookie = 'member=Ada; path=/'");
		await tab.goto(`${server.url}/members`);
		await tab.wait("window.ready", 5000);
		assert.deepEqual(tab.errors, []);
		assert.equal(await tab.eval("document.querySelector('.who').textContent + ' | ' + document.querySelector('.again').textContent"), "Welcome, Ada | Welcome, Ada, said once");
		assert.deepEqual((await asked(tab)).sort(), [...loads].sort(), "the endpoint's answer came with the page");

		// Under --dev, the reload script the server adds is marked as the host's, so hydrating passes over it.
		const dev = await start(join(dir, "build", "server"), [...flags, "--dev"]);
		servers.push(dev);
		const reloaded = await strictTab(browser);
		await reloaded.goto(`${dev.url}/posts/hello`);
		await reloaded.wait("window.ready", 5000);
		assert.deepEqual(reloaded.errors, []);
		assert.deepEqual(await reloaded.eval("[...document.querySelectorAll('body > script[data-rocx]')].map((script) => new URL(script.src).pathname)"), ["/rocx/start.js", "/__reload.js"], "start.js, and the reload script after it, a file (the answers are read, and gone)");
	} finally {
		await browser?.close();
		for (const server of servers) await server.stop();
		rmSync(dir, { recursive: true, force: true });
	}
});

test("an app of components: rocx build refuses a job outside its module's block, two jobs with one name, and a page with the html package's Html", { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" }, () => {
	const attempt = (edit) => {
		const dir = mkdtempSync(join(here, "e2e", "run-"));
		cpSync(join(here, "e2e", "app"), dir, { recursive: true });
		try {
			edit(dir);
			return run("build", dir);
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	};
	const outside = attempt((dir) => writeFileSync(join(dir, "Loose.roc"), 'import jobs.Job\n\nloose = Job.define("loose", |{}| Ok({}))\n\nLoose := [].{}\n'));
	assert.equal(outside.status, 1);
	assert.match(outside.stderr, /Loose\.roc:3: the job "loose" is defined outside its module's block: define it at the top of `Loose := \[\]\.\{ … \}`/);
	const twice = attempt((dir) => writeFileSync(join(dir, "Again.roc"), 'import jobs.Job\n\nAgain := [].{\n\twelcome = Job.define("welcome", |{}| Ok({}))\n}\n'));
	assert.equal(twice.status, 1);
	assert.match(twice.stderr, /Jobs\.roc:\d+: there is a job called "welcome" already \(Again\.roc:4\)/);
	const old = attempt((dir) => {
		mkdirSync(join(dir, "routes", "old"));
		writeFileSync(join(dir, "routes", "old", "+page.rocx"), "import html.Html\n\nview = |_| <p>Old</p>\n");
	});
	assert.equal(old.status, 1);
	assert.match(old.stderr, /routes\/old\/\+page\.rocx:1:8: import html\.Html: markup is components, written with the platform's Html, which the server renders and the browser hydrates: import pf\.Html/);
});

test("routes, served natively: each page in its layouts, a param a page's, a path no page has the error page's; /.well-known/… is routed, an upload reaches its put! as the bytes it was, and respond! answers every other method", { skip: (!hasRoc && "no Roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)") }, async () => {
	const dir = routesCopy();
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	put(
		"routes/.well-known/oauth-authorization-server/+server.roc",
		'import pf.Server\nimport pf.Endpoint\n\n## Who issues the tokens.\nget! : { request : Server.Request, params : {}, context : c } => Try({ issuer : Str }, Endpoint.Refusal)\nget! = |_| Ok({ issuer: "https://roc-solid.example" })\n',
	);
	put(
		"routes/uploads/[name]/+server.roc",
		"import pf.Server\nimport pf.Endpoint\nimport crypto.Sha256\n\n## An upload, as it came.\nput! : { request : Server.Request, params : { name : Str }, context : c, body : {} } => Try({ name : Str, size : U64, sha : Str }, Endpoint.Refusal)\nput! = |{ request, params, .. }| Ok({ name: params.name, size: request.body.len(), sha: Sha256.hex(request.body) })\n",
	);
	put(
		"routes/mcp/+server.roc",
		'import pf.Server\n\n## Every method, as it comes.\nrespond! : { request : Server.Request, params : {}, context : Str } => Server.Response\nrespond! = |{ request, context, .. }| Server.response(200, [{ name: "content-type", value: "text/plain" }], "${request.method} ${Server.text_of(request)} ${context}")\n',
	);
	// An app that serves its endpoints' OpenAPI document (`Document`: no page), as a program it writes
	// itself does: `OpenApi.respond` first, then the routes.
	put(
		"main.roc",
		'app [program] { pf: platform "../../../server/platform/main.roc", crypto: "../../../packages/crypto/main.roc" }\n\nimport pf.Server\nimport pf.OpenApi\nimport Generated/Api\nimport Generated/Routes\n\nprogram = {\n\trespond!: |request, context| {\n\t\tmatch OpenApi.respond(request, Document, Api.openapi) {\n\t\t\tOk(served) => served\n\t\t\tErr(NotHere) => Routes.respond!(request, context)\n\t\t}\n\t},\n\tmigrations: [],\n\tactors: [],\n\tlogs: { format: Auto },\n\tplugins: [],\n\troutes: [],\n}\n',
	);
	mkdirSync(join(dir, "routes", ".hidden"));
	writeFileSync(join(dir, "routes", ".hidden", "+page.rocx"), "import pf.Html\n\nview! = |_| <p>hidden</p>\n");
	writeFileSync(join(dir, "context.txt"), "ctx");
	let server;
	try {
		const built = run("build", dir);
		assert.equal(built.status, 0, built.stderr);
		buildHost();
		buildApp(join(dir, "main.roc"), join(dir, "app"));
		server = await start(join(dir, "app"), ["--context-file", join(dir, "context.txt")]);
		// The pages: Root's, each in its layouts (the root layout's <Errored> around the rest), as
		// the host renders it; a path no page has, the error page, 404, for a browser.
		const page = async (path) => {
			const response = await fetch(`${server.url}${path}`, { headers: { accept: "text/html" } });
			return { status: response.status, html: await response.text() };
		};
		const scripts = '<script type="application/json" class="rocx-answers">[]</script><script type="module" data-rocx src="/rocx/start.js"></script>';
		assert.deepEqual(await page("/"), { status: 200, html: `<!doctype html><main><!--errored--><h1>Home</h1><!--/errored--></main>${scripts}` });
		assert.deepEqual(await page("/blog"), { status: 200, html: `<!doctype html><main><!--errored--><section class="blog"><h2>The blog</h2></section><!--/errored--></main>${scripts}` });
		assert.deepEqual(await page("/blog/hello"), { status: 200, html: `<!doctype html><main><!--errored--><section class="blog"><h2>Post <!--x-->hello<!--/x--></h2> <a href="/blog/other">The other one</a></section><!--/errored--></main>${scripts}` }, "its param (a getter, D-039: a hole of its own), its link from Paths");
		assert.deepEqual(await page("/blog/hello/again"), { status: 404, html: `<!doctype html><main><p><!--x-->404<!--/x-->: <!--x-->nothing at /blog/hello/again<!--/x--></p></main>${scripts}` }, "the error page's props, getters (D-039): holes of their own");
		const known = await fetch(`${server.url}/.well-known/oauth-authorization-server`, { headers: { accept: "text/html" } });
		assert.equal(known.status, 200);
		assert.deepEqual(await known.json(), { issuer: "https://roc-solid.example" });
		const part = randomBytes(1 << 20);
		const uploaded = await fetch(`${server.url}/uploads/clip.mp4`, { method: "PUT", body: part, headers: { "content-type": "video/mp4" } });
		assert.deepEqual(await uploaded.json(), { name: "clip.mp4", size: 1 << 20, sha: createHash("sha256").update(part).digest("hex") });
		assert.equal((await fetch(`${server.url}/uploads/clip.mp4`, { method: "POST" })).headers.get("allow"), "PUT");
		assert.equal(await (await fetch(`${server.url}/mcp`, { method: "DELETE", body: "this" })).text(), "DELETE this ctx");
		assert.equal(await (await fetch(`${server.url}/mcp`)).text(), "GET  ctx");
		assert.equal((await fetch(`${server.url}/.hidden`)).status, 404, "another directory starting with a dot isn't routed");
		const openapi = await (await fetch(`${server.url}/openapi.json`)).json();
		assert.ok(openapi.paths["/.well-known/oauth-authorization-server"], Object.keys(openapi.paths).join(" "));
		assert.equal(openapi.paths["/mcp"], undefined, "respond! isn't an endpoint");
		assert.equal((await fetch(`${server.url}/openapi.html`)).status, 404, "Document: no page");
	} finally {
		await server?.stop();
		rmSync(dir, { recursive: true, force: true });
	}
});

// ---- The contract (D-037): Generated/Api imports no route file, so anything may publish through it ----

/** An app on the server platform whose live channel (`routes/news/+server.roc`) a route, an actor and
 * a job each publish on through `Generated/Api`, and whose page reads and sends its endpoints. */
function contractApp() {
	syncShared();
	const dir = mkdtempSync(join(here, "e2e", "run-"));
	const put = (path, text) => {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), text);
	};
	put("main.roc", 'app [program] { jobs: "../../../packages/jobs/main.roc", pf: platform "../../../server/platform/main.roc" }\n\nimport pf.Middleware\nimport jobs.Job\nimport Generated/App\n\nprogram = App.program({\n\tcontext: |_started| {},\n\tmiddleware: Middleware.headers([]),\n\tplugins: [Job.plugin({ jobs: App.jobs })],\n})\n');
	// The channel's message, in a module of its own: Api imports it, and the modules below import Api.
	put("News.roc", "## What the news channel says: who said it, and a number.\nNews := [].{\n\tSaid : { from : Str, n : U64 }\n}\n");
	put("routes/news/+server.roc", 'import pf.Server\nimport pf.Endpoint\nimport pf.Channel\nimport ../../News\n\n## The news: anyone may listen.\nchannel! : { request : Server.Request, params : {}, context : {} } => Try(Channel(Str, News.Said, []), Endpoint.Refusal)\nchannel! = |_| Ok(Channel.allow("anyone"))\n');
	// An actor and a job, each publishing on it through Api.
	put("Room.roc", 'import pf.Actor\nimport pf.Endpoint\nimport Generated/Api\n\nRoom := [].{\n\troom : Actor.Kind(U64, [Bump], U64)\n\troom = Actor.define({\n\t\tname: "room",\n\t\tinitial: |_| 0,\n\t\treceive!: |_, n, Bump| {\n\t\t\tEndpoint.publish!(Api.channel_news({}), { from: "actor", n: n + 1 })\n\t\t\t{ state: n + 1, reply: n + 1 }\n\t\t},\n\t})\n}\n');
	put("Jobs.roc", 'import jobs.Job\nimport pf.Endpoint\nimport Generated/Api\n\nJobs := [].{\n\tshout : Job.Kind({ n : U64 })\n\tshout = Job.define("shout", |{ n }| {\n\t\tEndpoint.publish!(Api.channel_news({}), { from: "job", n })\n\t\tOk({})\n\t})\n}\n');
	// A route that publishes itself, asks the actor, and queues the job (`?job=yes`: with a database).
	put("routes/publish/+server.roc", 'import pf.Server\nimport pf.Endpoint\nimport pf.Actor\nimport jobs.Job\nimport ../../Generated/Api\nimport ../../Room\nimport ../../Jobs\n\n## Publishes on the news, from here, from the actor, and from a job.\npost! : { request : Server.Request, params : {}, context : {}, body : { n : U64 } } => Try(Str, Endpoint.Refusal)\npost! = |{ request, body, .. }| {\n\tEndpoint.publish!(Api.channel_news({}), { from: "route", n: body.n })\n\t_ = Actor.ask!(Room.room, "lobby", Bump)\n\tqueued = if (request.query.contains("job=yes")) Job.enqueue!(Jobs.shout, { n: body.n }, { when: Now }) else Ok({})\n\tmatch queued {\n\t\tOk({}) => Ok("published")\n\t\tErr(JobErr(why)) => Err(Status(503, why))\n\t}\n}\n');
	// A page that reads an endpoint, and sends one: typed by the contract in both copies.
	put("routes/hello/+server.roc", 'import pf.Server\nimport pf.Endpoint\nimport ../../News\n\n## The latest news.\nget! : { request : Server.Request, params : {}, context : {} } => Try(News.Said, Endpoint.Refusal)\nget! = |_| Ok({ from: "hello", n: 7 })\n');
	// A route of respond! alone, which Handlers doesn't import, so it may import Handlers (an MCP route
	// would): it runs another route's handler there and then.
	put("routes/raw/+server.roc", 'import pf.Server\nimport pf.Endpoint\nimport ../../Generated/Handlers\n\n## Every method: the hello endpoint\'s answer, run here.\nrespond! : { request : Server.Request, params : {}, context : {} } => Server.Response\nrespond! = |{ request, context, .. }|\n\tmatch Endpoint.run!(Handlers.get_hello({}), request, context, {}) {\n\t\tOk(said) => Server.response(200, [], "${said.from} ${said.n.to_str()}")\n\t\tErr(_) => Server.response(500, [], "no answer")\n\t}\n');
	put("routes/+page.rocx", 'import pf.Html\nimport pf.Endpoint\nimport pf.Call\nimport ../Generated/Api\n\nview! = |_| {\n\tlatest = Endpoint.get!(Api.get_hello({}))\n\tsend! = || {\n\t\t_ = Endpoint.send!(Api.post_publish({}), { n: latest.n }, Call.fetch!)\n\t\t{}\n\t}\n\t<button type="button" on:click={send!}>{latest.from}</button>\n}\n');
	return dir;
}

test("the contract (D-037): a route, an actor and a job each import Generated/Api and publish on a channel; a subscriber hears each", { skip: (!hasRoc && "no Roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)") }, async () => {
	const dir = contractApp();
	const db = process.env.DATABASE_URL ? await testDatabase() : null;
	let server;
	const gone = new AbortController();
	try {
		const built = run("build", dir);
		assert.equal(built.status, 0, built.stderr);
		const api = readFileSync(join(dir, "Generated", "Api.roc"), "utf8");
		assert.match(api, /^import pf\.Channel\nimport \.\.\/News\n\nApi := /m, "the modules its types name, and no route file");
		assert.match(api, /\tchannel_news : \{\} -> Endpoint\(context, \{\}, Channel\(Str, News\.Said, \[\]\)\)\n/);
		buildHost();
		buildApp(join(dir, "main.roc"), join(dir, "build", "server"));
		server = await start(join(dir, "build", "server"), db ? ["--database-url", db.url] : []);
		// A tab's stream of its channels, as the runtime opens it: `resync`, then each message.
		const response = await fetch(`${server.url}/rocx/live?tab=t1&c=${encodeURIComponent("/news")}`, { headers: { accept: "text/event-stream" }, signal: gone.signal });
		assert.equal(response.status, 200);
		const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
		let buffered = "";
		const next = async () => {
			for (;;) {
				const end = buffered.indexOf("\n\n");
				if (end >= 0) {
					const block = buffered.slice(0, end);
					buffered = buffered.slice(end + 2);
					if (block.startsWith(":")) continue;
					const lines = block.split("\n");
					const field = (name) => lines.filter((line) => line.startsWith(`${name}: `)).map((line) => line.slice(name.length + 2));
					const [url, ...rest] = field("data");
					return { event: field("event")[0], url, said: rest.length ? JSON.parse(rest.join("\n")) : null };
				}
				const read = await reader.read();
				if (read.done) return null;
				buffered += read.value;
			}
		};
		assert.equal(await (await fetch(`${server.url}/raw`)).text(), "hello 7", "a respond! route ran a handler of Handlers'");
		assert.deepEqual(await next(), { event: "resync", url: "/news", said: null });
		const publish = (n, job) => fetch(`${server.url}/publish${job ? "?job=yes" : ""}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ n }) });
		const answered = await publish(1, false);
		assert.deepEqual([answered.status, await answered.text()], [200, '"published"']);
		assert.deepEqual(await next(), { event: "message", url: "/news", said: { from: "route", n: 1 } }, "the route's");
		assert.deepEqual(await next(), { event: "message", url: "/news", said: { from: "actor", n: 1 } }, "the actor's, in its turn");
		if (db) {
			assert.equal((await publish(2, true)).status, 200);
			const heard = [await next(), await next(), await next()];
			assert.deepEqual(heard.slice(0, 2), [{ event: "message", url: "/news", said: { from: "route", n: 2 } }, { event: "message", url: "/news", said: { from: "actor", n: 2 } }]);
			assert.deepEqual(heard[2], { event: "message", url: "/news", said: { from: "job", n: 2 } }, "the job's, as a worker ran it");
		}
	} finally {
		gone.abort();
		await server?.stop();
		await db?.drop();
		rmSync(dir, { recursive: true, force: true });
	}
});

test("the contract (D-037): a wrong body or answer against it doesn't compile, in the server's program or the browser's, each reported at its line", { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" }, () => {
	const dir = contractApp();
	try {
		const client = join(dir, "build", "client");
		const both = () => {
			const built = run("build", dir, "--client", client);
			assert.equal(built.status, 0, built.stderr);
			return [run("check", "--", roc, "check", join(dir, "main.roc")), run("check", "--", roc, "check", join(client, "main.roc"))];
		};
		for (const checked of both()) assert.equal(checked.status, 0, checked.stdout);
		// The page sends what the endpoint isn't sent, and reads its answer as what it isn't.
		const page = join(dir, "routes", "+page.rocx");
		writeFileSync(page, readFileSync(page, "utf8").replace("{ n: latest.n }", '{ n: "one" }').replace("{latest.from}", "{latest.title}"));
		for (const [checked, copy] of both().map((each, i) => [each, i ? "browser" : "server"])) {
			assert.notEqual(checked.status, 0, copy);
			assert.match(checked.stdout, /routes\/\+page\.rocx:9:\d+/, `${copy}: the send, at the .rocx line:\n${checked.stdout}`);
			assert.match(checked.stdout, /_ = Endpoint\.send!\(Api\.post_publish\(\{\}\), \{ n: "one" \}, Call\.fetch!\)/, `${copy}: the .rocx line, quoted`);
			assert.match(checked.stdout, /routes\/\+page\.rocx:12:\d+/, `${copy}: the read, at its line`);
			assert.doesNotMatch(checked.stdout, /(build\/client\/|Generated\/)\S*\.roc:\d+:\d+/, `${copy}: never a line of rocx's copy`);
		}
		// An actor publishes what the channel doesn't carry: at its line in Room.roc.
		writeFileSync(join(dir, "routes", "+page.rocx"), readFileSync(join(dir, "routes", "+page.rocx"), "utf8").replace('{ n: "one" }', "{ n: latest.n }").replace("{latest.title}", "{latest.from}"));
		writeFileSync(join(dir, "Room.roc"), readFileSync(join(dir, "Room.roc"), "utf8").replace('{ from: "actor", n: n + 1 }', '{ from: "actor", n: "many" }'));
		const [server] = both();
		assert.notEqual(server.status, 0);
		assert.match(server.stdout, /Room\.roc:11:\d+/, server.stdout);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
