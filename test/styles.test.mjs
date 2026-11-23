import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { build } from "../rocx-cli/rocx.mjs";
import { scopeClass, scopeCss } from "../rocx-cli/rocx.mjs";
import { RocxError, transpileModule } from "../rocx-cli/rocx.mjs";

const scoped = (css) => scopeCss(css, "rx-t");

function refusal(css) {
	try {
		scopeCss(css, "rx-t", (reason, offset) => {
			throw Object.assign(new Error(reason), { offset });
		});
	} catch (error) {
		return { reason: error.message, offset: error.offset };
	}
	assert.fail("expected the CSS to be refused");
}

test("styles: a file's class is named after its module, the same every time", () => {
	assert.match(scopeClass("Demos/Counter"), /^rx-[0-9a-z]{6}$/);
	assert.equal(scopeClass("Demos/Counter"), scopeClass("Demos/Counter"));
	assert.notEqual(scopeClass("Demos/Counter"), scopeClass("Demos/Count"));
});

test("styles: every compound gets the class, the first plainly and the rest in :where()", () => {
	assert.equal(scoped(".a { color: red }"), ".a.rx-t { color: red }");
	assert.equal(scoped(".a .b > p {}"), ".a.rx-t .b:where(.rx-t) > p:where(.rx-t) {}");
	assert.equal(scoped(".a+.b~.c {}"), ".a.rx-t + .b:where(.rx-t) ~ .c:where(.rx-t) {}");
	assert.equal(scoped(".a, .b {}"), ".a.rx-t, .b.rx-t {}");
	assert.equal(scoped("button:hover, p::before, :focus-visible {}"), "button.rx-t:hover, p.rx-t::before, .rx-t:focus-visible {}");
	assert.equal(scoped("* {}"), "*.rx-t {}");
});

test("styles: what's inside brackets, parentheses and strings is left as it is", () => {
	assert.equal(scoped('[data-x="a:b, c"] {}'), '[data-x="a:b, c"].rx-t {}');
	assert.equal(scoped("a:not(.x, .y) {}"), "a.rx-t:not(.x, .y) {}");
	assert.equal(scoped("li:nth-child(2n+1) {}"), "li.rx-t:nth-child(2n+1) {}");
	assert.equal(scoped(".md\\:flex {}"), ".md\\:flex.rx-t {}");
	assert.equal(scoped('@font-face { font-family: X; src: url("a{b}.woff") }'), '@font-face { font-family: X; src: url("a{b}.woff") }');
});

test("styles: :global(…), :global as a prefix, and :global blocks stay as written", () => {
	assert.equal(scoped(":global(body) { margin: 0 }"), "body { margin: 0 }");
	assert.equal(scoped("div :global(strong) {}"), "div.rx-t strong {}");
	assert.equal(scoped("p:global(.big.red) {}"), "p.big.red.rx-t {}");
	assert.equal(scoped(".a :global .b .c {}"), ".a.rx-t .b .c {}");
	assert.equal(scoped(":global .x {}"), ".x {}");
	assert.equal(scoped(".a > :global .b {}"), ".a.rx-t > .b {}");
	assert.equal(scoped(".a :global > .b {}"), ".a.rx-t > .b {}");
	assert.equal(scoped(":global { .b .c { x: y } }").trim(), ".b .c { x: y }");
	assert.equal(scoped(".a :global { .b { x: y } }"), ".a.rx-t { .b { x: y } }");
});

test("styles: nested rules are inside one that has the class already, and & stays", () => {
	assert.equal(
		scoped(".card { padding: 1rem; &:hover { x: y } .title { x: y } & > p { x: y } }"),
		".card.rx-t { padding: 1rem; &:hover { x: y } .title:where(.rx-t) { x: y } & > p:where(.rx-t) { x: y } }",
	);
	assert.equal(scoped(".a { @media (width > 40em) { color: red } }"), ".a.rx-t { @media (width > 40em) { color: red } }");
});

test("styles: at-rules: rules inside @media are scoped; keyframes are the file's own unless -global-", () => {
	assert.equal(scoped("@media (min-width: 40em) { .a { x: y } }"), "@media (min-width: 40em) { .a.rx-t { x: y } }");
	assert.equal(scoped("@layer base, components;"), "@layer base, components;");
	assert.equal(
		scoped("@keyframes spin { to { rotate: 1turn } }\n.a { animation: spin 1s infinite, pulse 2s; animation-name: spin }"),
		"@keyframes rx-t-spin { to { rotate: 1turn } }\n.a.rx-t { animation: rx-t-spin 1s infinite, pulse 2s; animation-name: rx-t-spin }",
	);
	assert.equal(scoped("@keyframes -global-pulse { to { opacity: 0 } }\n.a { animation: pulse 1s }"), "@keyframes pulse { to { opacity: 0 } }\n.a.rx-t { animation: pulse 1s }");
});

test("styles: comments go, and the common indentation", () => {
	assert.equal(scoped("\n\t/* the box */\n\t.a {\n\t\tcolor: red;\n\t}\n"), ".a.rx-t {\n\tcolor: red;\n}");
});

test("styles: refused, at the offset of the problem", () => {
	assert.deepEqual(refusal(".a { color: red"), { reason: "this { is never closed", offset: 0 });
	assert.deepEqual(refusal(".a {} }"), { reason: "this } closes nothing", offset: 6 });
	assert.deepEqual(refusal("color: red"), { reason: "a declaration goes in a rule: color: red", offset: 0 });
	assert.match(refusal('@import "x.css";').reason, /^@import can't be in a file's <style>/);
	assert.deepEqual(refusal(".a {}\n/* x"), { reason: "this comment is never closed", offset: 6 });
	assert.deepEqual(refusal(", .a {}"), { reason: "a selector is empty", offset: 0 });
	assert.match(refusal(".a > :global > .b {}").reason, /between two combinators/);
});

const COUNTER = `import pf.Html
import Heading

Counter := [].{
	view! = |{ start }|
		<div class="counter" class:negative={start < 0}>
			<Heading text="Count" />
			<output class={if (start > 9) "big" else ""}>{start.to_str()}</output>
			<style>p { color: red }</style>
		</div>

	<style>
		.counter { display: flex }
	</style>
}
`;

test("styles: a component's <style> goes, its lines kept, and each element in its block gets its class", () => {
	const scope = scopeClass("Demos/Counter.Counter");
	const { code, styles } = transpileModule(COUNTER, "Demos/Counter.rocx", { module: "Demos/Counter" });
	const lines = code.split("\n");
	assert.equal(lines[5], `\t\tHtml.element("div", [Html.attr("class", "counter ${scope}"), Html.class_of("negative", || start!() < 0),], [`);
	assert.equal(lines[6], '\t\t\tHtml.component(|| Heading.view!({ text: || "Count", })), Html.text(" "),', "a component it renders has its own file's styles");
	assert.equal(lines[7], `\t\t\tHtml.element("output", [Html.attr_of("class", || Str.concat(if (start!() > 9) "big" else "", " ${scope}")),], [Html.text_of(|| start!().to_str()),]), Html.text(" "),`);
	assert.equal(lines[8], '\t\t\tHtml.element("style", [], [Html.source_text("p { color: red }"),]),', "a <style> in markup is as written");
	assert.deepEqual(lines.slice(11, 15), ["", "", "", "}"], "the <style>'s lines, blank");
	assert.deepEqual(styles, [{ css: `.counter.${scope} { display: flex }`, line: 12, component: "Counter" }]);
	assert.equal(transpileModule(COUNTER, "Demos/Counter.rocx", { module: "Demos/Counter", client: true }).code, code, "the browser's copy has the same classes");
});

const IDEAS = `import pf.Html

CounterIdeas := [].{
	view! = |{}|
		<section>
			<Stepper start={1} />
			<Slider start={2} />
		</section>
}

Stepper := [].{
	view! = |{ start }| <div class="counter">{start.to_str()}</div>

	<style>
		.counter { display: flex }
	</style>
}

Slider := [].{
	view! = |{ start }| <div class="counter"><input type="range" /></div>
	<style>
		.counter { display: grid }
	</style>
}
`;

test("styles: several components in a file, each with its own <style>; a tag calls the file's own component", () => {
	const stepper = scopeClass("Sketches/CounterIdeas.Stepper");
	const slider = scopeClass("Sketches/CounterIdeas.Slider");
	const { code, styles } = transpileModule(IDEAS, "Sketches/CounterIdeas.rocx", { module: "Sketches/CounterIdeas" });
	const lines = code.split("\n");
	assert.equal(lines[4], '\t\tHtml.element("section", [], [', "a component with no <style> is as it was");
	assert.equal(lines[5], "\t\t\tHtml.component(|| Stepper.view!({ start: || 1, })), Html.text(\" \"),");
	assert.equal(lines[11], `\tview! = |{ start: start! }| Html.element("div", [Html.attr("class", "counter ${stepper}"),], [Html.text_of(|| start!().to_str()),])`);
	assert.equal(lines[19], `\tview! = |{ start: start! }| Html.element("div", [Html.attr("class", "counter ${slider}"),], [Html.void("input", [Html.attr("type", "range"), Html.attr("class", "${slider}"),]),])`);
	assert.deepEqual(styles, [
		{ css: `.counter.${stepper} { display: flex }`, line: 14, component: "Stepper" },
		{ css: `.counter.${slider} { display: grid }`, line: 21, component: "Slider" },
	]);
});

test("styles: a page's <style>, at the file's top level, styles the file; not what goes in <head>", () => {
	const page = 'import pf.Html\n\nview! = |{ children, theme }|\n\t<html>\n\t\t<head><title>x</title></head>\n\t\t<body class={theme}>{...children}<br /></body>\n\t</html>\n\n<style>\n\tbody { margin: 0 }\n</style>\n';
	const scope = scopeClass("Generated/Layout");
	const { code, styles } = transpileModule(page, "routes/+layout.rocx", { module: "Generated/Layout" });
	assert.match(code, new RegExp(`Html\\.element\\("html", \\[Html\\.attr\\("class", "${scope}"\\),\\]`));
	assert.match(code, /Html\.element\("head", \[\], \[Html\.element\("title", \[\], /);
	assert.match(code, new RegExp(`Html\\.element\\("body", \\[Html\\.attr_of\\("class", \\|\\| Str\\.concat\\(theme!\\(\\), " ${scope}"\\)\\),\\]`), "a layout's prop is a getter (D-039): the class follows it");
	assert.match(code, new RegExp(`Html\\.void\\("br", \\[Html\\.attr\\("class", "${scope}"\\),\\]\\)`));
	assert.deepEqual(styles, [{ css: `body.${scope} { margin: 0 }`, line: 9, component: null }]);
});

test("styles: an element in a styled component of a styled file gets both classes", () => {
	const source = "import pf.Html\n\nCard := [].{\n\tview! = |{}| <p class=\"a\">x</p>\n\t<style>.a { color: red }</style>\n}\n\n<style>p { margin: 0 }</style>\n";
	const { code } = transpileModule(source, "Card.rocx", { module: "Card" });
	assert.ok(code.includes(`Html.attr("class", "a ${scopeClass("Card.Card")} ${scopeClass("Card")}")`), code);
});

test("styles: the platform's <A> (D-040) is an <a>, styled as one: its class prop gets the file's class", () => {
	const source = 'import pf.Html\nimport pf.A\nimport ./Card\n\nview! = |{ id }| <nav><A href={"/lists/${id}"} class="list" end>Open</A><A href="/">Home</A><Card class="x" /></nav>\n\n<style>a { color: red }</style>\n';
	const scope = scopeClass("Nav");
	const { code } = transpileModule(source, "Nav.rocx", { module: "Nav" });
	assert.ok(code.includes(`A.view!({ href: "/lists/\${id!()}", class: "list ${scope}", end: Bool.True, children: [Html.text("Open"),], })`), code);
	assert.ok(code.includes(`A.view!({ href: "/", class: "${scope}", children: [Html.text("Home"),], })`), "a class of its own when it has none");
	assert.ok(!code.includes(`class: || "x ${scope}"`) && code.includes('class: || "x"'), "another component's class is its own");
});

test("styles: a <style> in a definition's body, or in markup, is an element, as written", () => {
	const source = "import pf.Html\n\nview = |_|\n\t<style>.a {}</style>\n\nT := [].{\n\tview = |_|\n\t\t<style>.b {}</style>\n}\n";
	const { code, styles } = transpileModule(source, "T.rocx");
	assert.deepEqual(styles, []);
	assert.ok(!code.includes("rx-"));
	assert.equal(code.split("\n")[3], '\tHtml.element("style", [], [Html.source_text(".a {}"),])');
	assert.equal(code.split("\n")[7], '\t\tHtml.element("style", [], [Html.source_text(".b {}"),])');
});

test("styles: a file with no <style> is as it was", () => {
	const source = 'import pf.Html\n\nview = |_|\n\t<div class="a"><style>.a { color: red }</style></div>\n';
	const { code, styles } = transpileModule(source, "P.rocx");
	assert.deepEqual(styles, []);
	assert.ok(!code.includes("rx-"));
});

test("styles: a second <style>, attributes, or bad CSS, refused at its line", () => {
	const refused = (source) => {
		try {
			transpileModule(source, "T.rocx");
		} catch (error) {
			assert.ok(error instanceof RocxError, `expected a RocxError, got ${error}`);
			return `${error.line}:${error.column}: ${error.reason}`;
		}
		assert.fail("expected the source to be refused");
	};
	assert.match(refused("import pf.Html\n\nT := [].{\n\t<style>.a {}</style>\n\t<style>.b {}</style>\n}\n"), /^5:2: T has a <style> already/);
	assert.match(refused("import pf.Html\n\n<style>.a {}</style>\n<style>.b {}</style>\n"), /^4:1: a file has one <style> at its top level/);
	assert.match(refused('import pf.Html\n\nT := [].{\n\t<style lang="scss">.a {}</style>\n}\n'), /^4:2: T's <style> takes no attributes/);
	assert.match(refused("import pf.Html\n\nT := [].{\n\t<style>\n\t\t.a {\n\t\t\tcolor: red\n\t</style>\n}\n"), /^5:3: in <style>: this \{ is never closed/);
});

test("styles: rocx build writes every <style>, scoped, into Generated/Styles.roc", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-styles-"));
	try {
		const file = (path, content) => {
			mkdirSync(dirname(join(dir, path)), { recursive: true });
			writeFileSync(join(dir, path), content);
		};
		file("routes/+layout.rocx", 'import pf.Html\n\nview! = |{ children, .. }|\n\t<main>{...children}</main>\n\n<style>\n\tmain { margin: 0 auto }\n</style>\n');
		file("routes/+page.rocx", "import pf.Html\n\nview! = |_|\n\t<p>Hi</p>\n");
		file("Ui/Card.rocx", 'import pf.Html\n\nCard := [].{\n\tview = |{ title }| <h2 class="card">{title}</h2>\n\n\t<style>\n\t\t.card { font-weight: 700 }\n\t</style>\n}\n');
		const said = [];
		assert.ok(build([dir], { log: (line) => said.push(line) }), said.join("\n"));
		const styles = readFileSync(join(dir, "Generated", "Styles.roc"), "utf8");
		const card = scopeClass("Ui/Card.Card");
		assert.match(styles, /^import pf\.Html$/m);
		assert.ok(styles.indexOf('"/* Ui/Card.rocx, Card */"') < styles.indexOf('"/* routes/+layout.rocx */"'), "in the order of the files' paths");
		const layout = /"main\.(rx-[0-9a-z]{6}) \{ margin: 0 auto \}",/.exec(styles)?.[1];
		assert.ok(layout, styles);
		assert.notEqual(layout, card);
		assert.ok(styles.includes(`".card.${card} { font-weight: 700 }",`), styles);
		assert.match(styles, /style = Html\.element\("style", \[\], \[Html\.source_text\(css\)\]\)/);
		assert.ok(readFileSync(join(dir, "Ui", "Card.roc"), "utf8").includes(`Html.attr("class", "card ${card}")`));
		// No <style> anywhere: an empty stylesheet, and nothing in the page.
		rmSync(join(dir, "Ui"), { recursive: true });
		file("routes/+layout.rocx", "import pf.Html\n\nview! = |{ children, .. }|\n\t<main>{...children}</main>\n");
		assert.ok(build([dir], { log: (line) => said.push(line) }), said.join("\n"));
		const none = readFileSync(join(dir, "Generated", "Styles.roc"), "utf8");
		assert.match(none, /\tcss = ""\n/);
		assert.match(none, /\tstyle = Html\.empty\(\{\}\)\n/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("styles: with the browser's copy (--client), the stylesheet is a file named by its content beside start.js, which Styles.style links; another <style> is another name, and the old file goes", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-styles-"));
	try {
		const file = (path, content) => {
			mkdirSync(dirname(join(dir, path)), { recursive: true });
			writeFileSync(join(dir, path), content);
		};
		const card = (weight) => `import pf.Html\n\nCard := [].{\n\tview = |{ title }| <h2 class="card">{title}</h2>\n\n\t<style>\n\t\t.card { font-weight: ${weight} }\n\t</style>\n}\n`;
		file("routes/+layout.rocx", 'import pf.Html\n\nview! = |{ children, .. }|\n\t<main>{...children}</main>\n\n<style>\n\tmain { margin: 0 auto }\n</style>\n');
		file("routes/+page.rocx", "import pf.Html\n\nview! = |_|\n\t<p>Hi</p>\n");
		file("Ui/Card.rocx", card(700));
		const client = join(dir, "build", "client");
		const said = [];
		const log = (line) => said.push(line);
		const sheets = () => readdirSync(join(client, "static", "rocx")).filter((name) => name.endsWith(".css"));
		assert.ok(build([dir], { client, log }), said.join("\n"));
		const [first] = sheets();
		assert.match(first ?? "", /^styles-[0-9a-f]{16}\.css$/, "one stylesheet, named by its content");
		assert.deepEqual(sheets(), [first]);
		const css = readFileSync(join(client, "static", "rocx", first), "utf8");
		assert.ok(css.includes(`.card.${scopeClass("Ui/Card.Card")} { font-weight: 700 }`), css);
		assert.match(css, /^\/\* Ui\/Card\.rocx, Card \*\/\n/, "each file's, after a comment that says whose");
		const styles = readFileSync(join(dir, "Generated", "Styles.roc"), "utf8");
		assert.ok(styles.includes(`\thref = "/rocx/${first}"\n`), styles);
		assert.match(styles, /\tstyle = Html\.void\("link", \[Html\.attr\("rel", "stylesheet"\), Html\.attr\("href", href\)\]\)\n/, "a <link>, rel then href");
		assert.equal(readFileSync(join(client, "Generated", "Styles.roc"), "utf8"), styles, "the same in the browser's copy");
		// The same sources, the same name; another <style>, another name, and the old file goes.
		assert.ok(build([dir], { client, log }), said.join("\n"));
		assert.deepEqual(sheets(), [first], "built again unchanged: the same name");
		file("Ui/Card.rocx", card(600));
		assert.ok(build([dir], { client, log }), said.join("\n"));
		const [second, ...more] = sheets();
		assert.deepEqual(more, []);
		assert.match(second, /^styles-[0-9a-f]{16}\.css$/);
		assert.notEqual(second, first, "a change to a component's <style> is a new name");
		assert.ok(readFileSync(join(dir, "Generated", "Styles.roc"), "utf8").includes(`\thref = "/rocx/${second}"\n`));
		// Without the browser's copy there is nowhere to put the file: inline, as a <style>.
		assert.ok(build([dir], { log }), said.join("\n"));
		const inline = readFileSync(join(dir, "Generated", "Styles.roc"), "utf8");
		assert.match(inline, /\thref = ""\n/);
		assert.match(inline, /\tstyle = Html\.element\("style", \[\], \[Html\.source_text\(css\)\]\)\n/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
