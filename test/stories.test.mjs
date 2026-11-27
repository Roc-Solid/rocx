import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { build } from "../rocx-cli/rocx.mjs";
import { rootModule, routesModule, routeTable } from "../rocx-cli/rocx.mjs";
import { catalogHtml, storyIds } from "../rocx-cli/rocx.mjs";
import { RocxError, transpileModule } from "../rocx-cli/rocx.mjs";
import { findChrome, launch } from "../web/test/browser.mjs";

const CALLOUT = `import pf.Html
import pf.Router

Callout := [].{
	view = |{ kind, children }| <aside class={kind}>{...children}</aside>

	<story name="Tip">
		<Callout kind="tip"><p>Short.</p></Callout>
	</story>

	<story name="Where it is">
		<Callout kind="note"><p>{Router.location!({}).path}</p></Callout>
	</story>
}
`;

test("stories: each is a definition in its place, its lines kept: an effect's name, given nothing, run where it is rendered", () => {
	const { code, stories } = transpileModule(CALLOUT, "Ui/Callout.rocx", { module: "Ui/Callout" });
	const lines = code.split("\n");
	assert.equal(lines[6], "\tstory_tip! = |{}| Html.join([");
	assert.equal(lines[7], '\t\tCallout.view({ kind: "tip", children: [Html.element("p", [], [Html.text("Short."),]),], }),', "a pure component, called where it is written");
	assert.equal(lines[8], "\t])");
	assert.equal(lines[10], "\tstory_where_it_is! = |{}| Html.join([");
	assert.match(lines[11], /Html\.hole_of\(\|\| Html\.hole\(Router\.location!\(\{\}\)\.path\)\)/, "what it needs, it asks for, as a component does");
	assert.equal(lines[13], "}");
	assert.deepEqual(stories, [
		{ component: "Callout", name: "Tip", def: "story_tip!", line: 7 },
		{ component: "Callout", name: "Where it is", def: "story_where_it_is!", line: 11 },
	]);
	const source = 'import pf.Html\n\nCounter := [].{\n\tview! = |{ start }| <button>{start.to_str()}</button>\n\n\t<story name="At three">\n\t\t<Counter start={3} />\n\t</story>\n}\n';
	const counter = transpileModule(source, "Counter.rocx", { module: "Counter", views: { Counter: "view!" } });
	assert.equal(counter.code.split("\n")[6], "\t\tHtml.component(|| Counter.view!({ start: || 3, })),", "an effectful one, put off, given getters (D-039)");
	assert.deepEqual(counter.stories, [{ component: "Counter", name: "At three", def: "story_at_three!", line: 6 }]);
});

test("stories: a story is a component's, named, and only one by each name", () => {
	const refused = (source, options = {}) => {
		try {
			transpileModule(source, "T.rocx", options);
		} catch (error) {
			assert.ok(error instanceof RocxError, `expected a RocxError, got ${error}`);
			return `${error.line}:${error.column}: ${error.reason}`;
		}
		assert.fail("expected the source to be refused");
	};
	assert.match(refused('import pf.Html\n\n<story name="Tip"><p>x</p></story>\n'), /^3:1: a <story> goes in a component's block/);
	assert.match(refused("import pf.Html\n\nT := [].{\n\t<story><p>x</p></story>\n}\n"), /^4:2: a <story> is named/);
	assert.match(refused('import pf.Html\n\nT := [].{\n\t<story name="1st"><p>x</p></story>\n}\n'), /starts with a letter/);
	assert.match(refused('import pf.Html\n\nT := [].{\n\t<story name="Tip"><p>x</p></story>\n\t<story name="tip!"><p>y</p></story>\n}\n'), /^5:2: T has a story "Tip" already/);
	// Deeper in a definition, `<story>` is an element like any other.
	const { stories } = transpileModule("import pf.Html\n\nT := [].{\n\tview = |_|\n\t\t<story><p>x</p></story>\n}\n", "T.rocx");
	assert.deepEqual(stories, []);
});

test("stories: each at an id under /__rocx/stories, the component's name left out when it is the module's", () => {
	const placed = storyIds([
		{ file: "Ui/Callout.rocx", module: "Ui/Callout", component: "Callout", name: "Tip", def: "story_tip", line: 6 },
		{ file: "stories/Landing.rocx", module: "stories/Landing", component: "Split", name: "Wide hero", def: "story_wide_hero", line: 9 },
	]);
	assert.deepEqual(placed.map(({ id, alias }) => ({ id, alias })), [
		{ id: "Ui/Callout/tip", alias: "StoryUiCallout" },
		{ id: "stories/Landing/Split/wide-hero", alias: "StoryStoriesLanding" },
	]);
	assert.throws(
		() => storyIds([
			{ file: "A.rocx", module: "A", component: "A", name: "Tip", def: "story_tip", line: 3 },
			{ file: "A.rocx", module: "A", component: "A", name: "Tip!", def: "story_tip_", line: 4 },
		]),
		/A.rocx:4: the story "Tip!" would be at \/__rocx\/stories\/A\/tip, as A.rocx:3's is/,
	);
});

test("stories: the catalog is a page of its own, with the stories it is given, drafts (stories/) first", () => {
	const html = catalogHtml(
		[
			{ id: "Ui/Callout/tip", file: "Ui/Callout.rocx", component: "Callout", name: "</script> tip", line: 6 },
			{ id: "stories/Landing/today", file: "stories/Landing.rocx", component: "Landing", name: "Today", line: 17 },
		],
		{ title: "site", root: "/app" },
	);
	assert.match(html, /^<!doctype html>/);
	assert.match(html, /<title>Stories · site<\/title>/);
	const list = JSON.parse(/const STORIES = (\[.*\]);/.exec(html)[1]);
	assert.deepEqual(list, [
		{ id: "stories/Landing/today", file: "stories/Landing.rocx", component: "Landing", name: "Today", line: 17, kind: "draft", path: "/app/stories/Landing.rocx" },
		{ id: "Ui/Callout/tip", file: "Ui/Callout.rocx", component: "Callout", name: "</script> tip", line: 6, kind: "component", path: "/app/Ui/Callout.rocx" },
	]);
	assert.equal(html.match(/<\/script>/g).length, 1, "a name can't end the script");
});

test("stories: the catalog marks the stories this browser hasn't shown as new, folds the side's parts and widens it, and keeps all three", { skip: !findChrome() && "no Chromium (set CHROME)" }, async () => {
	const html = catalogHtml(
		[
			{ id: "stories/Landing/today", file: "stories/Landing.rocx", component: "Landing", name: "Today", line: 5 },
			{ id: "Ui/Callout/tip", file: "Ui/Callout.rocx", component: "Callout", name: "Tip", line: 6 },
			{ id: "Ui/Callout/warning", file: "Ui/Callout.rocx", component: "Callout", name: "Warning", line: 10 },
			{ id: "Ui/Badge/label", file: "Ui/Badge.rocx", component: "Badge", name: "Label", line: 4 },
		],
		{ title: "site", root: "/app" },
	);
	const server = createServer((request, response) => {
		response.setHeader("content-type", "text/html; charset=utf-8");
		response.end(request.url === "/__rocx/stories" ? html : `<!doctype html><title>${request.url}</title><p>a story</p>`);
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	const url = `http://127.0.0.1:${server.address().port}/__rocx/stories`;
	const browser = await launch();
	try {
		const page = await browser.page();
		const dots = () => page.eval(`[...document.querySelectorAll("#list .stories .dot")].map((dot) => dot.closest("a").textContent)`);
		const news = () => page.eval(`document.getElementById("news").hidden ? null : document.getElementById("new-count").textContent`);
		await page.goto(url);
		// The first visit shows the first story, so it is seen; the rest are new, and so are the
		// parts and components that hold them.
		assert.deepEqual(await dots(), ["Tip", "Warning", "Label"]);
		assert.equal(await news(), "3 new");
		assert.deepEqual(await page.eval(`[...document.querySelectorAll(".part-head")].map((head) => head.querySelector(".dot")?.title ?? null)`), [null, "3 new"], "Components has three; Drafts none");
		assert.deepEqual(await page.eval(`[...document.querySelectorAll("#list .component")].filter((row) => row.querySelector(".dot")).map((row) => row.querySelector(".open .name").textContent)`), ["Callout", "Badge"]);
		// N opens the next new one; it is seen, and its bar says it is new to this visit.
		await page.press("n");
		await page.wait(`location.hash === "#Ui/Callout/tip" && document.querySelector("#list .stories a.on")?.textContent === "Tip"`);
		assert.deepEqual(await dots(), ["Warning", "Label"]);
		assert.equal(await page.eval(`document.querySelector(".bar .fresh")?.textContent`), "New");
		// Side by side, each of a component's stories is seen; the one seen first here says so.
		await page.goto(`${url}#side/Ui/Callout.rocx%23Callout`);
		await page.wait(`document.querySelectorAll(".cell").length === 2`);
		const cells = () => page.eval(`[...document.querySelectorAll(".cell")].map((cell) => [cell.querySelector("header a").textContent, Boolean(cell.querySelector(".fresh"))])`);
		assert.deepEqual(await cells(), [["Tip", true], ["Warning", true]], "both seen for the first time in this visit");
		assert.deepEqual(await dots(), ["Label"]);
		// A reload is a new visit: both were seen in the last, so neither is new.
		await page.eval("window.before = true");
		await page.send("Page.reload");
		await page.wait(`!window.before && document.readyState === "complete" && document.querySelectorAll(".cell").length === 2`);
		assert.deepEqual(await cells(), [["Tip", false], ["Warning", false]]);
		assert.deepEqual(await dots(), ["Label"]);
		// Searching for "new" finds what hasn't been seen.
		await page.type("#find", "new");
		assert.deepEqual(await page.eval(`[...document.querySelectorAll("#list .stories a")].map((a) => a.textContent)`), ["Label"]);
		await page.eval(`(() => { const find = document.getElementById("find"); find.value = ""; find.dispatchEvent(new Event("input")); })()`);
		// Mark all seen: no dots, and a reload has none either.
		await page.click("#seen-all");
		assert.deepEqual([await dots(), await news()], [[], null]);
		await page.goto(url);
		assert.deepEqual([await dots(), await news()], [[], null], "what is seen is kept");

		// Folding: the Components part, then (unfolded) a component; each kept, and opening a story
		// in one unfolds it.
		const listed = () => page.eval(`[...document.querySelectorAll("#list .stories a, #list .component .open .name")].map((node) => node.textContent)`);
		assert.deepEqual(await listed(), ["Landing", "Today", "Callout", "Tip", "Warning", "Badge", "Label"]);
		await page.click('.part[data-kind="component"] .part-head');
		assert.deepEqual(await listed(), ["Landing", "Today"]);
		assert.equal(await page.eval(`document.querySelector('.part[data-kind="component"] .part-head').getAttribute("aria-expanded")`), "false");
		await page.goto(url);
		assert.deepEqual(await listed(), ["Landing", "Today"], "a folded part is kept");
		await page.type("#find", "warn");
		assert.deepEqual(await listed(), ["Callout", "Warning"], "a search shows every match, folded or not");
		await page.eval(`(() => { const find = document.getElementById("find"); find.value = ""; find.dispatchEvent(new Event("input")); })()`);
		await page.click('.part[data-kind="component"] .part-head');
		await page.click('#list [data-key="Ui/Callout.rocx#Callout"]');
		assert.deepEqual(await listed(), ["Landing", "Today", "Callout", "Badge", "Label"]);
		await page.goto(url);
		assert.deepEqual(await listed(), ["Landing", "Today", "Callout", "Badge", "Label"], "a folded component is kept");
		await page.goto(`${url}#Ui/Callout/warning`);
		await page.wait(`document.querySelector("#list .stories a.on")?.textContent === "Warning"`);
		assert.deepEqual(await listed(), ["Landing", "Today", "Callout", "Tip", "Warning", "Badge", "Label"], "a story opened is never folded away");

		// The side's edge drags it wider; the width is kept; a double click puts it back.
		const width = () => page.eval(`Math.round(document.getElementById("side").getBoundingClientRect().width)`);
		const before = await width();
		const grip = await page.center("#grip");
		await page.send("Input.dispatchMouseEvent", { type: "mousePressed", x: grip.x, y: grip.y, button: "left", buttons: 1, clickCount: 1 });
		for (const step of [40, 80, 120]) await page.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: grip.x + step, y: grip.y, button: "left", buttons: 1 });
		await page.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: grip.x + 120, y: grip.y, button: "left", buttons: 0, clickCount: 1 });
		assert.ok(Math.abs((await width()) - (before + 120)) <= 2, `dragged from ${before} to ${await width()}`);
		await page.goto(url);
		assert.ok(Math.abs((await width()) - (before + 120)) <= 2, "the width is kept");
		await page.eval(`document.getElementById("grip").dispatchEvent(new MouseEvent("dblclick", { bubbles: true }))`);
		assert.equal(await width(), before);
		assert.deepEqual(page.errors, [], "the catalog threw nothing");
	} finally {
		await browser.close();
		server.close();
	}
});

test("stories: videos shown together play in step from one transport, which pauses, seeks and steps them; stories from anywhere are compared side by side", { skip: !findChrome() && "no Chromium (set CHROME)" }, async () => {
	const html = catalogHtml(
		[
			{ id: "Intro/wide", file: "Intro.rocx", component: "Intro", name: "Wide", line: 5 },
			{ id: "Intro/tall", file: "Intro.rocx", component: "Intro", name: "Tall", line: 9 },
			{ id: "Ui/Badge/label", file: "Ui/Badge.rocx", component: "Badge", name: "Label", line: 4 },
		],
		{ title: "site", root: "/app", render: "/rocx/packages/video/render.mjs" },
	);
	assert.match(html, /const RENDER = "\/rocx\/packages\/video\/render.mjs";/);
	// A story with a player as packages/video renders one: live, its scrubber seeks it and pauses it,
	// and its element says where it is.
	const player = (frames, scaled = false) =>
		`<!doctype html><div class="video${scaled ? " video-scale" : ""}" data-rocx-video="" data-live="yes" data-fps="30" data-frames="${frames}" data-width="1920" data-frame="${frames - 1}" data-playing="yes"><input class="video-seek" type="range" hidden></div>` +
		`<script>const p = document.querySelector("[data-rocx-video]"); p.querySelector("input").addEventListener("input", (e) => { p.dataset.frame = e.target.value; p.dataset.playing = "no"; });</script>`;
	const pages = { "/__rocx/stories": html, "/__rocx/stories/Intro/wide": player(90, true), "/__rocx/stories/Intro/tall": player(60) };
	const server = createServer((request, response) => {
		response.setHeader("content-type", "text/html; charset=utf-8");
		response.end(pages[request.url] ?? `<!doctype html><title>${request.url}</title><p>a story</p>`);
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	const url = `http://127.0.0.1:${server.address().port}/__rocx/stories`;
	const browser = await launch();
	try {
		const page = await browser.page();
		const frames = () => page.eval(`[...document.querySelectorAll("#stage iframe")].map((frame) => Number(frame.contentDocument.querySelector("[data-rocx-video]")?.dataset.frame ?? -1))`);
		const seek = (ms) => page.eval(`(() => { const scrub = document.getElementById("scrub"); scrub.value = "${ms}"; scrub.dispatchEvent(new Event("input")); })()`);
		// Both of Intro's stories side by side: the transport shows, and plays them from the start in step.
		await page.goto(`${url}#side/Intro.rocx%23Intro`);
		await page.wait(`!document.getElementById("transport").hidden && document.getElementById("play").getAttribute("aria-label") === "Pause"`);
		assert.equal(await page.eval(`document.getElementById("in-step").textContent`), "2 videos in step");
		// The one laid out at 1920 pixels (fit={Scale}) gets a frame that wide, shrunk to its cell; the
		// other is its cell's width.
		await page.wait(`document.querySelector("#stage iframe").dataset.natural === "yes"`);
		assert.deepEqual(await page.eval(`[...document.querySelectorAll("#stage iframe")].map((frame) => [frame.style.width, frame.style.transform.startsWith("scale(0.")])`), [["1984px", true], ["", false]]);
		await page.wait(`(() => { const f = [...document.querySelectorAll("#stage iframe")].map((frame) => Number(frame.contentDocument.querySelector("[data-rocx-video]").dataset.frame)); return f[0] > 3 && f[0] < 50; })()`);
		await page.click("#play");
		const paused = await frames();
		assert.equal(paused[0], paused[1], `in step: ${paused}`);
		await new Promise((resolve) => setTimeout(resolve, 150));
		assert.deepEqual(await frames(), paused, "paused, they stay");
		// Seeking: a second in is frame 30 of each; a frame on with →, a second on with Shift+→.
		await seek(1000);
		await page.wait(`document.querySelector("#stage iframe").contentDocument.querySelector("[data-rocx-video]").dataset.frame === "30"`);
		assert.deepEqual(await frames(), [30, 30]);
		await page.press("ArrowRight");
		await page.wait(`document.querySelector("#stage iframe").contentDocument.querySelector("[data-rocx-video]").dataset.frame === "31"`);
		assert.deepEqual(await frames(), [31, 31]);
		// Past the shorter one's end, it keeps its last frame while the longer plays on.
		await seek(2500);
		await page.wait(`document.querySelector("#stage iframe").contentDocument.querySelector("[data-rocx-video]").dataset.frame === "75"`);
		assert.deepEqual(await frames(), [75, 59]);
		assert.match(await page.eval(`document.getElementById("clock").textContent`), /^0:02\.50 \/ 0:03\.00 · frame 75 of 90 at 30 fps$/);
		assert.equal(await page.eval(`document.getElementById("render").hidden`), false);
		assert.deepEqual(JSON.parse(await page.eval(`document.getElementById("render").dataset.stories`)), ["Intro/wide", "Intro/tall"]);

		// Comparing: a story from one component and one from another, picked in the side, then opened.
		await page.goto(`${url}#Ui/Badge/label`);
		await page.eval(`document.querySelector('#list .pin[aria-label="Compare Label"]').click()`);
		await page.eval(`document.querySelector('#list .pin[aria-label="Compare Wide"]').click()`);
		assert.equal(await page.eval(`document.getElementById("compare-open").textContent`), "Compare 2 side by side");
		await page.click("#compare-open");
		await page.wait(`document.querySelectorAll("#stage .cell").length === 2`);
		assert.deepEqual(await page.eval(`[...document.querySelectorAll("#stage .cell header a")].map((a) => a.textContent)`), ["Label", "Wide"]);
		assert.match(await page.eval(`document.getElementById("bar").textContent`), /Comparing 2 stories/);
		// One video among them: the transport drives it alone.
		await page.wait(`!document.getElementById("transport").hidden`);
		assert.equal(await page.eval(`document.getElementById("in-step").textContent`), "");
		// Kept for the app: a reload still has both picked; Clear takes them out.
		await page.goto(url);
		assert.equal(await page.eval(`document.getElementById("compare-line").hidden`), false);
		await page.click("#compare-clear");
		assert.equal(await page.eval(`document.getElementById("compare-line").hidden`), true);
		assert.deepEqual(page.errors, [], "the catalog threw nothing");
	} finally {
		await browser.close();
		server.close();
	}
});

test("stories: a dev build's Routes answers them: the catalog, and each story, the app's page, which Root renders in the root layout; another build's has none", () => {
	const table = routeTable(["+layout.rocx", "+page.rocx"]);
	const sources = new Map([
		["+layout.rocx", { view: "view!", meta: false, methods: [], middleware: null }],
		["+page.rocx", { view: "view!", meta: true, methods: [], middleware: null }],
	]);
	const [story] = storyIds([{ file: "Counter.rocx", module: "Counter", component: "Counter", name: "At three", def: "story_at_three!", line: 6 }]);
	const routes = routesModule(table, { sources, stories: [story] });
	assert.match(routes, /^import Stories$/m);
	assert.match(routes, /if \(request\.path == "\/__rocx\/stories" or request\.path\.starts_with\("\/__rocx\/stories\/"\)\) \{/);
	assert.match(routes, /Server\.response\(200, \[\{ name: "content-type", value: "text\/html; charset=utf-8" \}\], Stories\.catalog\)/);
	assert.match(routes, /\} else if \(id == "Counter\/at-three"\) \{\n\t\t\tRoutes\.page\(200\)/);
	assert.doesNotMatch(routes, /import \.\.\/Counter/, "Root imports it, not Routes");
	assert.match(routes, /story = \|id, request\|/);
	assert.doesNotMatch(routesModule(table, { sources }), /__rocx\/stories|Stories|story/);
	const root = rootModule(table, { sources, stories: [story] });
	assert.match(root, /^import \.\.\/Counter as StoryCounter$/m);
	assert.match(root, /\troute = \|path\| \{\n\t\tsegments = [^\n]*\n\t\tif \(path\.starts_with\("\/__rocx\/stories\/"\)\) \{\n\t\t\tStory\(path\.drop_prefix\("\/__rocx\/stories\/"\)\)\n/, "a story's route, matched before the pages'");
	assert.match(root, /\t\t\tStory\(id\) => "story \$\{id\}"\n/, "a level of its own, in the root layout");
	assert.match(root, /\t\t\tStory\(id\) => if \(id == "Counter\/at-three"\) Html\.component\(\|\| StoryCounter\.story_at_three!\(\{\}\)\) else Root\.failed\(404, "no story at \/__rocx\/stories\/\$\{id\}"\)\n/);
	assert.doesNotMatch(rootModule(table, { sources }), /__rocx/, "without stories, nothing");
});

test("stories: rocx build --dev writes the catalog, the routes and stories/; without --dev, none of them", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-stories-"));
	try {
		const file = (path, content) => {
			mkdirSync(dirname(join(dir, path)), { recursive: true });
			writeFileSync(join(dir, path), content);
		};
		file("routes/+layout.rocx", "import pf.Html\n\nview! = |{ children, .. }|\n\t<main>{...children}</main>\n");
		file("routes/+page.rocx", "import pf.Html\n\nview! = |_|\n\t<p>Hi</p>\n");
		file("Ui/Callout.rocx", CALLOUT);
		file("stories/Ideas.rocx", 'import pf.Html\n\nIdeas := [].{\n\t<story name="Big">\n\t\t<Big />\n\t</story>\n}\n\nBig := [].{\n\tview = |{}| <p class="big">Big</p>\n\n\t<style>\n\t\t.big { font-size: 3rem }\n\t</style>\n}\n');
		const said = [];
		const log = (line) => said.push(line);
		assert.ok(build([dir], { log, dev: true }), said.join("\n"));
		const catalog = readFileSync(join(dir, "Generated", "Stories.roc"), "utf8");
		assert.match(catalog, /^Stories := \[\]\.\{$/m);
		assert.match(catalog, /Ui\/Callout\/where-it-is/);
		assert.match(readFileSync(join(dir, "Generated", "Routes.roc"), "utf8"), /id == "Ui\/Callout\/where-it-is"\) \{\n\t\t\tRoutes\.page\(200\)/);
		assert.match(readFileSync(join(dir, "Generated", "Root.roc"), "utf8"), /StoryUiCallout\.story_where_it_is!\(\{\}\)/);
		assert.match(readFileSync(join(dir, "Ui", "Callout.roc"), "utf8"), /story_tip! = \|\{\}\|/, "the stories are in every build's module");
		assert.match(readFileSync(join(dir, "Generated", "Root.roc"), "utf8"), /StoryStoriesIdeas\.story_big!\(\{\}\)/, "stories/ is a dev build's");
		assert.match(readFileSync(join(dir, "Generated", "Styles.roc"), "utf8"), /font-size: 3rem/);

		assert.ok(build([dir], { log }), said.join("\n"));
		assert.ok(!existsSync(join(dir, "Generated", "Stories.roc")), "another build has no catalog");
		assert.doesNotMatch(readFileSync(join(dir, "Generated", "Routes.roc"), "utf8"), /__rocx\/stories/);
		assert.doesNotMatch(readFileSync(join(dir, "Generated", "Root.roc"), "utf8"), /__rocx\/stories/);
		assert.match(readFileSync(join(dir, "Ui", "Callout.roc"), "utf8"), /story_tip! = \|\{\}\|/);
		assert.ok(!existsSync(join(dir, "stories", "Ideas.roc")), "another build skips stories/, and what a dev build wrote there goes");
		assert.doesNotMatch(readFileSync(join(dir, "Generated", "Styles.roc"), "utf8"), /font-size: 3rem/, "its styles too");

		// A story is shown as the app's page, which Root renders: an app with no pages has none.
		rmSync(join(dir, "routes"), { recursive: true });
		file("routes/api/+server.roc", 'import pf.Server\nimport pf.Endpoint\n\nget! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)\nget! = |_| Ok("hi")\n');
		said.length = 0;
		assert.ok(!build([dir], { log, dev: true }));
		assert.match(said.join("\n"), /Ui\/Callout\.rocx:7: the story "Tip" is shown as the app's page, and the app has none: give it routes\/ with a \+page\.rocx/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
