import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { build } from "../rocx-cli/rocx.mjs";
import { rootModule, routesModule, routeTable } from "../rocx-cli/rocx.mjs";
import { catalogHtml, storyIds } from "../rocx-cli/rocx.mjs";
import { RocxError, transpileModule } from "../rocx-cli/rocx.mjs";

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
	assert.match(lines[11], /Html\.text_of\(\|\| Router\.location!\(\{\}\)\.path\)/, "what it needs, it asks for, as a component does");
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
