// Dom.roc in an app: a component's expects render it (`Html.to_str`) and query it by role, name and
// label (`testing.Dom`); `roc test` runs them with the app's, and one that fails is reported at its
// line in the .rocx file. Needs Roc (`just setup`, or ROC).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { repo, serverBuild } from "../build.mjs";

const pkg = join(dirname(fileURLToPath(import.meta.url)), "..");
const { roc, rocxBinary } = await serverBuild();
const compiler = (() => {
	try {
		return roc();
	} catch {
		return null;
	}
})();
const skip = !compiler && "no roc (run `just setup`, or set ROC)";

const GREETING = `import pf.Html
import testing.Dom

## A greeting, and the messages someone hasn't read.
Greeting := [].{
	view : { name : Str, unread : List(Str) } -> Html
	view = |{ name, unread }|
		<section aria-labelledby="hello">
			<h2 id="hello">Hello, {name}</h2>
			<ul aria-label="Unread">
				{...unread.map(|subject| <li><a href={"/mail?subject=\${subject}"}>{subject}</a></li>)}
			</ul>
			<form method="post" action="/wave">
				<label for="note">Say something</label>
				<input id="note" name="note" />
				<button>Wave</button>
			</form>
		</section>
}

page = |props| Dom.parse(Html.to_str(Greeting.view(props)))

expect page({ name: "Ada", unread: [] }).text_of(Role("heading")) == Ok("Hello, Ada")
expect page({ name: "Ada", unread: [] }).contains(Named("region", "Hello, Ada"))
expect page({ name: "Ada", unread: ["Lunch?", "Re: <the plan>"] }).texts(Role("link")) == ["Lunch?", "Re: <the plan>"]
expect page({ name: "Ada", unread: ["Lunch?"] }).get(Named("link", "Lunch?")).map_ok(|link| link.attr("href")) == Ok(Ok("/mail?subject=Lunch?"))
expect page({ name: "Ada", unread: [] }).get(Named("list", "Unread")).map_ok(|list| list.count(Role("listitem"))) == Ok(0)
expect page({ name: "Ada", unread: [] }).get(Label("Say something")).map_ok(|input| input.attr("name")) == Ok(Ok("note"))
expect page({ name: "Ada", unread: [] }).contains(Named("button", "Wave"))
`;

/** The app, in a directory of its own: on the web platform, naming this package `testing`. */
function app(greeting) {
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "rocx-testing-roc-")));
	const from = (path) => relative(dir, realpathSync(path));
	const files = {
		"main.roc": `app [main!] { pf: platform "${from(join(repo, "web", "platform", "main.roc"))}", testing: "${from(join(pkg, "main.roc"))}" }

import pf.Html
import Greeting

main! : {} => Html
main! = |{}| Greeting.view({ name: "Ada", unread: [] })
`,
		"Greeting.rocx": greeting,
	};
	for (const [path, content] of Object.entries(files)) {
		mkdirSync(dirname(join(dir, path)), { recursive: true });
		writeFileSync(join(dir, path), content);
	}
	const built = spawnSync(rocxBinary(), ["generate", dir], { encoding: "utf8" });
	assert.equal(built.status, 0, built.stderr);
	return dir;
}

/** `roc test` on the app, its reports pointed at the .rocx files (`rocx check`). */
const rocTest = (dir) => spawnSync(rocxBinary(), ["check", "--", compiler, "test", join(dir, "main.roc")], { encoding: "utf8", env: { ...process.env, ROC: compiler } });

test("an app's expects render a component and find in it by role, name and label", { skip }, () => {
	const dir = app(GREETING);
	try {
		const tested = rocTest(dir);
		assert.equal(tested.status, 0, `${tested.stdout}${tested.stderr}`);
		assert.match(tested.stdout, /All \(\d+\) tests passed/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("an expect that fails is reported at its .rocx line", { skip }, () => {
	const dir = app(GREETING.replace('Ok("Hello, Ada")', 'Ok("Hello, Bob")'));
	try {
		const tested = rocTest(dir);
		assert.notEqual(tested.status, 0);
		const line = GREETING.split("\n").findIndex((each) => each.includes('Ok("Hello, Ada")')) + 1;
		assert.match(`${tested.stdout}${tested.stderr}`, new RegExp(`Greeting\\.rocx:${line}:`));
		assert.match(tested.stdout, /1 failed/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
