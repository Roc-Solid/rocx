// rocx fmt: a .rocx file's Roc through `roc fmt`, its markup as written. Needs Roc: the one `just
// setup` links, else $ROC.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { roc as findRoc, rocxBinary } from "../server/build.mjs";
import { FormatError, formatRocx, rocFmt } from "../rocx-cli/rocx.mjs";
import { transpileModule } from "../rocx-cli/rocx.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
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
const needsRoc = { skip: !hasRoc && "no Roc (run `just setup`, or set ROC)" };
const format = (source, file = "Page.rocx") => formatRocx(source, file, { roc });

test("the Roc around markup is formatted, and the markup, holes too, is kept as written", needsRoc, () => {
	const written = [
		"import pf.Html",
		"Card := [].{",
		"\tview! : { name : Str } => Html",
		"\tview! = |{ name }| {",
		'\t\tgreeting =    "Hello, ${name}"',
		'\t\t<div class="card">',
		'\t\t\t<p>{ if (name.is_empty()) "nobody" else    greeting }</p>',
		"\t\t</div>",
		"\t}",
		"}",
		"",
	];
	const expected = written.with(4, '\t\tgreeting = "Hello, ${name}"');
	assert.deepEqual(format(written.join("\n")).split("\n"), expected);
});

test("markup on lines of its own stays on them, moved with the code it is in; a comma after it stays", needsRoc, () => {
	const written = [
		"List := [].{",
		"\tview = |items|   Html.fragment(",
		"\t\t\t<ul>",
		"\t\t\t\t{items.map(|item| <li>{item}</li>)}",
		"\t\t\t</ul>",
		"\t\t)",
		"",
		"\trows = [",
		"\t\t<li>",
		"\t\t\tone",
		"\t\t</li>,",
		"\t\t<li>two</li>,",
		"\t]",
		"}",
		"",
	].join("\n");
	assert.equal(
		format(written),
		[
			"List := [].{",
			"\tview = |items| Html.fragment(",
			"\t\t<ul>",
			"\t\t\t{items.map(|item| <li>{item}</li>)}",
			"\t\t</ul>",
			"\t)",
			"",
			"\trows = [",
			"\t\t<li>",
			"\t\t\tone",
			"\t\t</li>,",
			"\t\t<li>two</li>,",
			"\t]",
			"}",
			"",
		].join("\n"),
	);
});

test("markup straight after an if's condition keeps the parentheses that make it markup", needsRoc, () => {
	const written = "Badge := [].{\n\tview = |ok| if (ok) <b>yes</b> else <i>no</i>\n}\n";
	assert.equal(format(written), written);
	assert.match(transpileModule(format(written), "Badge.rocx").code, /Html\.element\("b"/);
});

test("a <pre>'s text stays where it is when the markup around it moves", needsRoc, () => {
	const written = "Page := [].{\n\tview = |_|\n\t\t\t<div>\n\t\t\t\t<pre>\n\t\t\t\t\tkeep\n\t\t\t\t</pre>\n\t\t\t</div>\n}\n";
	assert.equal(format(written), "Page := [].{\n\tview = |_|\n\t\t<div>\n\t\t\t<pre>\n\t\t\t\t\tkeep\n\t\t\t\t</pre>\n\t\t</div>\n}\n");
});

test("a file's and a component's <style> are kept as written", needsRoc, () => {
	const written = "import pf.Html\n\n<style>\n  p { color: red; }\n</style>\n\nCard := [].{\n\t<style>\n\t\t.card { padding: 1em; }\n\t</style>\n\n\tview! = |_|    <p class=\"card\">hi</p>\n}\n";
	assert.equal(format(written), written.replace("|_|    <p", "|_| <p"));
});

test("formatting keeps a space on a tag's line, and a line break next to one, as written: the text is the same", needsRoc, () => {
	const written = [
		"Page := [].{",
		"\tview = |name|    Html.fragment(",
		"\t\t\t\t<p><b>Note: </b>a space on the tag's line stays.<span> </span>",
		"\t\t\t\t\tand one after {name} too </p>",
		"\t\t)",
		"}",
		"",
	].join("\n");
	const formatted = format(written);
	assert.notEqual(formatted, written, "the code around the markup was formatted");
	const texts = (source) => transpileModule(source, "Page.rocx").code.match(/Html\.text\([^)]*\)/g);
	assert.deepEqual(texts(formatted), ['Html.text("Note: ")', 'Html.text("a space on the tag\'s line stays.")', 'Html.text(" ")', 'Html.text(" and one after ")', "Html.text(name)", 'Html.text(" too ")']);
	assert.deepEqual(texts(formatted), texts(written));
});

test("what roc can't read is reported at the file's line, past markup that took several", needsRoc, () => {
	const written = "Page := [].{\n\tview = |_| Html.fragment(<div>\n\t\t<p>hi</p>\n\t</div>)\n\tbroken = = 1\n}\n";
	assert.throws(() => format(written, "Broken.rocx"), (error) => error instanceof FormatError && /^Broken\.rocx:5:\d+: /.test(error.message));
});

test("every .rocx file here: formatting it keeps its code, and formatting it again changes nothing", needsRoc, () => {
	const rocxFiles = (dir) =>
		readdirSync(dir).flatMap((entry) => {
			const path = join(dir, entry);
			if (statSync(path).isDirectory()) return /^(build|dist|Generated|node_modules|run-.*)$/.test(entry) ? [] : rocxFiles(path);
			return path.endsWith(".rocx") ? [path] : [];
		});
	const files = ["site", "web/test/app", "test/e2e", "packages", "examples"].flatMap((dir) => rocxFiles(join(root, dir)));
	assert.ok(files.length > 20);
	for (const file of files) {
		const source = readFileSync(file, "utf8");
		const formatted = format(source, file);
		const code = (text) => rocFmt(transpileModule(text, file).code, { roc });
		assert.equal(code(formatted), code(source), `${file}: its code changed`);
		assert.equal(format(formatted, file), formatted, `${file}: formatted twice, it changed again`);
	}
});

test("rocx fmt formats an app's .rocx and hand-written .roc files, leaves rocx's own, and --check says which aren't", needsRoc, () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-fmt-"));
	try {
		mkdirSync(join(dir, "Generated"));
		writeFileSync(join(dir, "Page.rocx"), "Page := [].{\n\tview = |_|    <p>hi</p>\n}\n");
		writeFileSync(join(dir, "Util.roc"), "Util := [].{\n\ttwice = |x|    x * 2\n}\n");
		const generated = "Page := [].{\n\tview = |_|    1\n}\n\n# rocx: generated from Page.rocx: edit that file, not this one. Line N here is line N there.\n";
		writeFileSync(join(dir, "Gen.roc"), generated);
		writeFileSync(join(dir, "Generated", "Routes.roc"), "x =    1\n");
		const rocx = (...args) => spawnSync(rocxBinary(), ["fmt", ...args], { encoding: "utf8", env: { ...process.env, ROC: roc } });

		const checked = rocx("--check", dir);
		assert.equal(checked.status, 1);
		assert.match(checked.stderr, /Page\.rocx: not formatted/);
		assert.match(checked.stderr, /Util\.roc: not formatted/);
		assert.doesNotMatch(checked.stderr, /Gen\.roc|Routes\.roc/);

		assert.equal(rocx(dir).status, 0);
		assert.equal(readFileSync(join(dir, "Page.rocx"), "utf8"), "Page := [].{\n\tview = |_| <p>hi</p>\n}\n");
		assert.equal(readFileSync(join(dir, "Util.roc"), "utf8"), "Util := [].{\n\ttwice = |x| x * 2\n}\n");
		assert.equal(readFileSync(join(dir, "Gen.roc"), "utf8"), generated);
		assert.equal(readFileSync(join(dir, "Generated", "Routes.roc"), "utf8"), "x =    1\n");
		assert.equal(rocx("--check", dir).status, 0);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
