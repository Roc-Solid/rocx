import { test } from "node:test";
import assert from "node:assert/strict";
import { RocxError, rocString, transpile, transpileModule, viewsDefined } from "../src/transpile.mjs";
import { remap, TRY_HINT } from "../src/remap.mjs";
import { scopeClass } from "../src/styles.mjs";

/** The generated code without the closing note, which every output ends with. */
const roc = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");

function failure(source) {
	try {
		transpile(source, "T.rocx");
	} catch (error) {
		assert.ok(error instanceof RocxError, `expected a RocxError, got ${error}`);
		return { reason: error.reason, line: error.line, column: error.column };
	}
	assert.fail("expected the source to be refused");
}

test("elements, attributes, text and holes", () => {
	assert.equal(roc(`x = <a href={link} title="Hi">{caption}</a>`), `x = Html.element("a", [Html.attr("href", link), Html.attr("title", "Hi"),], [Html.text(caption),])`);
	assert.equal(roc(`x = <div class:on={a} hidden?={b} required></div>`), `x = Html.element("div", [Html.class_if("on", a), Html.flag("hidden", b), Html.flag("required", Bool.True),], [])`);
	assert.equal(roc(`x = <p>{=pill} {...rows}</p>`), `x = Html.element("p", [], [(pill), Html.text(" "), Html.join(rows),])`);
	assert.equal(roc(`x = <br />`), `x = Html.void("br", [])`);
	assert.equal(roc(`x = <div />`), `x = Html.element("div", [], [])`);
	assert.equal(roc(`x = <!doctype html>`), `x = Html.doctype({})`);
	assert.equal(roc(`x = <><b>a</b></>`), `x = Html.join([Html.element("b", [], [Html.text("a"),]),])`);
});

test("components: imported modules' view!, others a local snake_case function's, run where they are rendered", () => {
	const source = `import ui.StatusPill\nimport Button as Btn\n\nx = <StatusPill status={s} />\ny = <Btn label="Go" primary />\nz = <LocalThing>hi</LocalThing>\nw = <Empty />`;
	const lines = roc(source).split("\n");
	assert.equal(lines[3], `x = StatusPill.view!({ status: s, })`, "a package's is markup, made where it is written");
	assert.equal(lines[4], `y = Html.component(|| Btn.view!({ label: "Go", primary: Bool.True, }))`);
	assert.equal(lines[5], `z = Html.component(|| local_thing!({ children: [Html.text("hi"),], }))`);
	assert.equal(lines[6], `w = Html.component(|| empty!({}))`);
	const paths = roc(`import Ui/Card\nimport ../Ui/Pill as P\n\nx = <Card><P /></Card>`).split("\n");
	assert.equal(paths[3], `x = Html.component(|| Card.view!({ children: [Html.component(|| P.view!({})),], }))`, "modules imported by path count too");
});

test("output lines are input lines", () => {
	const source = [
		"view = |posts|",
		"\t<ul",
		'\t\tclass="list"',
		"\t>",
		"\t\t{...posts.map(|post|",
		"\t\t\t<li>",
		"\t\t\t\t{post.title}",
		"\t\t\t\tmore text",
		"\t\t\t</li>",
		"\t\t)}",
		"\t\t<!-- a comment",
		"\t\t     over two lines -->",
		"\t\t{# and a Roc-side one",
		"\t\t   over two lines }",
		"\t\t<script>",
		"\t\t\tif (a < b) { go() }",
		"\t\t</script>",
		"\t</ul>",
	].join("\n");
	const out = roc(source);
	assert.equal(out.split("\n").length, source.split("\n").length);
	assert.match(out.split("\n")[6], /Html\.text\(post\.title\)/);
	assert.match(out.split("\n")[7], /Html\.text\(" more text"\)/, "after a value on the line above: a space");
	assert.match(out.split("\n")[15], /"\\t\\t\\tif \(a < b\) \{ go\(\) \}"/);
});

test("< is markup only where an expression can start", () => {
	assert.equal(roc(`x = a < b`), `x = a < b`);
	assert.equal(roc(`x = f(y)<z`), `x = f(y)<z`);
	assert.equal(roc(`x = n<b`), `x = n<b`);
	assert.equal(roc(`x = if (a < b) <b/> else <i/>`), `x = if (a < b) Html.element("b", [], []) else Html.element("i", [], [])`);
	assert.equal(roc(`x = match m { A => <b/>, B => [<i/>] }`), `x = match m { A => Html.element("b", [], []), B => [Html.element("i", [], [])] }`);
	assert.equal(roc(`x = |p| <b/>`), `x = |p| Html.element("b", [], [])`);
	assert.equal(roc(`x = {\n\tm = match a { B => 1 }\n\t<b/>\n}`), `x = {\n\tm = match a { B => 1 }\n\tHtml.element("b", [], [])\n}`, "first on its line, after a statement");
	assert.equal(roc(`x = '<'`), `x = '<'`);
	assert.equal(roc(`x = "<b>" # <i>`), `x = "<b>" # <i>`);
	assert.equal(roc(`x = "a\\"<b>${1}"`), `x = "a\\"<b>${1}"`);
	assert.equal(roc("x =\n\t\\\\<b>${y}</b>"), "x =\n\t\\\\<b>${y}</b>", "a \\\\ line is a string");
	assert.equal(roc(`x = "\${<b/>}"`), `x = "\${Html.element("b", [], [])}"`);
});

test("HTML's whitespace rule, as Svelte has it", () => {
	assert.equal(roc(`x = <p>Published {at}</p>`), `x = Html.element("p", [], [Html.text("Published "), Html.text(at),])`);
	assert.equal(roc(`x = <p>a <b>b</b> c</p>`), `x = Html.element("p", [], [Html.text("a "), Html.element("b", [], [Html.text("b"),]), Html.text(" c"),])`);
	assert.equal(roc(`x = <p>\n\t\tone\n\t\ttwo\n\t</p>`), `x = Html.element("p", [], [\n\t\tHtml.text("one two"),\n\t\t\n\t])`);
	assert.equal(roc(`x = <p>  spaced   out  </p>`), `x = Html.element("p", [], [Html.text("spaced out"),])`, "ends trimmed, runs collapsed");
	assert.equal(
		roc(`x = <p>\n\tthe <a href="/t">terms</a> and\n\t<a href="/p">policy</a> of\n\t{name}\n</p>`),
		`x = Html.element("p", [], [\n\tHtml.text("the "), Html.element("a", [Html.attr("href", "/t"),], [Html.text("terms"),]), Html.text(" and "),\n\tHtml.element("a", [Html.attr("href", "/p"),], [Html.text("policy"),]), Html.text(" of "),\n\tHtml.text(name),\n])`,
		"a line break next to a link or a value is a space, as in HTML",
	);
	assert.equal(roc(`x = <ul>\n\t<li>a</li>\n\t<li>b</li>\n</ul>`), `x = Html.element("ul", [], [\n\tHtml.element("li", [], [Html.text("a"),]), Html.text(" "),\n\tHtml.element("li", [], [Html.text("b"),]),\n])`);
	assert.equal(roc(`x = <pre>  a\n  <b>b</b>  </pre>`), `x = Html.element("pre", [], [Html.text("  a\\n  "),\n  Html.element("b", [], [Html.text("b"),]), Html.text("  "),])`, "pre keeps it");
	assert.equal(roc(`x = <p>a&nbsp; </p>`), `x = Html.element("p", [], [Html.text("a\u00a0"),])`, "&nbsp; is not whitespace");
	assert.equal(roc(`x = <Button>\n\tSave\n</Button>`), `x = Html.component(|| button!({ children: [\n\tHtml.text("Save"),\n], }))`);
});

test("entities and literal text", () => {
	assert.equal(roc(`x = <p>Tom &amp; Jerry &middot; &#x2014; &#39;</p>`), `x = Html.element("p", [], [Html.text("Tom & Jerry · — '"),])`);
	assert.equal(roc(`x = <p>{"<"} and {"{"}</p>`), `x = Html.element("p", [], [Html.text("<"), Html.text(" and "), Html.text("{"),])`);
	assert.equal(roc(`x = <p title="a &quot;b&quot;" />`), `x = Html.element("p", [Html.attr("title", "a \\"b\\""),], [])`);
});

test("script and style keep their text as written", () => {
	assert.equal(roc(`x = <style>a { color: red }</style>`), `x = Html.element("style", [], [Html.source_text("a { color: red }"),])`);
	assert.equal(roc("x = <script>\n\tlet s = `${1}`\n</script>"), 'x = Html.element("script", [], [Html.source_text(Str.join_with(["", \n\t"\\tlet s = `\\${1}`", \n""], "\\n")),])');
	assert.equal(roc(`x = while (i < n) <b/>`), `x = while (i < n) Html.element("b", [], [])`, "after a condition, an expression starts");
});

test("every file is components: a page's markup has handlers and keys too; Html is the platform's", () => {
	assert.equal(roc(`x = <button on:click={save!}>Save</button>`), `x = Html.element("button", [Html.on("click", save!),], [Html.text("Save"),])`);
	assert.equal(roc(`x = <li key={item.id}>{item.text}</li>`), `x = Html.element("li", [Html.key(item.id),], [Html.text(item.text),])`);
	assert.equal(roc(`x = <Pill on={a} />`), `x = Html.component(|| pill!({ on: a, }))`, "a component's prop may be called on");
	assert.equal(roc(`x = <Row key={k} />`), `x = Html.component(|| row!({ key: k, }))`, "a component's key is a prop like any other");
	// There is no other Html: the html package, which rendered static pages, is gone.
	assert.deepEqual(failure("import html.Html\n\nview! = |_| <p>Hi</p>"), {
		reason: "import html.Html: markup is components, written with the platform's Html, which the server renders and the browser hydrates: import pf.Html",
		line: 1,
		column: 8,
	});
	assert.match(failure("import pf.Server\nimport ui.Html as Page\n").reason, /^import ui\.Html: markup is components/);
});

test("on: a component's handlers are effects, given what the event says", () => {
	const component = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	const refused = (source) => {
		try {
			component(source);
		} catch (error) {
			assert.ok(error instanceof RocxError, `expected a RocxError, got ${error}`);
			return error.reason;
		}
		assert.fail("expected the source to be refused");
	};
	assert.equal(component(`x = <button on:click={save!}>Save</button>`), `x = Html.element("button", [Html.on("click", save!),], [Html.text("Save"),])`);
	assert.equal(component(`x = <input type="checkbox" on:change.checked={set_done!} />`), `x = Html.void("input", [Html.attr("type", "checkbox"), Html.on_checked("change", set_done!),])`);
	assert.equal(component(`x = <div tabindex="0" on:keydown.ArrowUp={up!} on:keydown.w={up!} />`), `x = Html.element("div", [Html.attr("tabindex", "0"), Html.on_named_key("keydown", "ArrowUp", up!), Html.on_named_key("keydown", "w", up!),], [])`);
	assert.match(refused(`x = <b on:click="go()" />`), /not a string: a handler is Roc, never script/);
	assert.match(refused(`x = <b on:click />`), /on:click needs \{a handler\}/);
	assert.match(refused(`x = <b on:click?={a} />`), /takes \{a handler\}/);
	assert.match(refused(`x = <b on:Click={a} />`), /write on:event=\{a handler\}/);
	assert.match(refused(`x = <b on:input.files={a} />`), /takes .value, .checked or .key, or a key's name \(.Enter, .ArrowUp, .w\), not .files/);
	assert.match(refused(`x = <b on:input.constructor={a} />`), /not .constructor/);
	assert.match(refused(`x = <div on:frame={tick!} />`), /frames are on:frame.ms=\{…\}/);
	assert.match(refused(`x = <div on:click.ms={tick!} />`), /frames are on:frame.ms/);
	assert.match(refused(`x = <div on:click.Enter={go!} />`), /a key's name goes with on:keydown or on:keyup/);
	assert.match(refused(`x = <div on:keydown.enter={go!} />`), /not .enter/, "key names are as the browser has them: Enter");
	assert.match(refused(`x = <a onclick="go()">x</a>`), /inline event handlers \(onclick\) aren't allowed: in a component, write on:click=\{…\}/);
});

test("server!: a function on the server, named after its module, and only its name in the browser's copy", () => {
	const source = [
		"import pf.Server",
		"",
		"Echo := [].{",
		"\techo! : Str => Str",
		"\techo! = server!(|request, message|",
		'\t\t# not this server!( or ")" ',
		'\t\t"Echo: ${message} (${Str.join_with([")", "("], ",")})")',
		"\tview! = |{}| <p>Hi</p>",
		"}",
	].join("\n");
	const server = transpileModule(source, "site/Demos/Echo.rocx", { module: "Demos/Echo" });
	assert.deepEqual(server.serverFunctions, [{ name: "echo!", call: "echo", line: 5, package: "pf" }]);
	const lines = server.code.split("\n");
	assert.equal(lines[4], '\techo! = Server.local("Demos/Echo.echo", |request, message|');
	assert.equal(lines[6], '\t\t"Echo: ${message} (${Str.join_with([")", "("], ",")})")', "the implementation as written");
	const browser = transpileModule(source, "site/Demos/Echo.rocx", { module: "Demos/Echo", client: true }).code.split("\n");
	assert.equal(browser[4], '\techo! = Server.remote("Demos/Echo.echo")');
	assert.deepEqual(browser.slice(5, 7), ["", ""], "its lines stay, empty");
	assert.equal(browser[7], lines[7], "the rest is as on the server");
	assert.equal(browser.length, lines.length);
	// Without a module, the file's name names it.
	assert.match(transpile(source, "Echo.rocx"), /Server\.local\("Echo\.echo", /);
});

test("server!: what only a server function uses leaves the browser's copy with it, imports too", () => {
	const source = ["import pf.Html", "import pf.Server", "import pf.Db", "import Unused", "", "Notes := [].{", "\tcount! : {} => I64", "\tcount! = server!(|_request, {}|", '\t\tDb.count!("notes"))', "\tview! = |{}| <p>{count!({}).to_str()}</p>", "}"].join("\n");
	const server = transpileModule(source, "Notes.rocx", { module: "Notes" }).code.split("\n");
	const browser = transpileModule(source, "Notes.rocx", { module: "Notes", client: true }).code.split("\n");
	assert.equal(server[2], "import pf.Db");
	assert.equal(browser[2], "", "the browser's platform has no Db: the line stays, empty");
	assert.equal(browser[3], "import Unused", "an import nothing uses stays, for the compiler to warn about");
	assert.deepEqual(browser.slice(0, 2), ["import pf.Html", "import pf.Server"]);
	assert.equal(browser.length, server.length);
});

test("server!: a function, the same call on both sides", () => {
	const source = ["import pf.Server", "", "Echo := [].{", "\techo! : Str => Str", "\techo! = server!(|_request, message|", '\t\t"Echo: ${message}")', "}"].join("\n");
	const server = transpileModule(source, "Echo.rocx", { module: "Echo" });
	assert.deepEqual(server.serverFunctions, [{ name: "echo!", call: "echo", line: 5, package: "pf" }]);
	assert.equal(server.code.split("\n")[4], '\techo! = Server.local("Echo.echo", |_request, message|');
	const browser = transpileModule(source, "Echo.rocx", { module: "Echo", client: true }).code.split("\n");
	assert.deepEqual(browser.slice(4, 6), ['\techo! = Server.remote("Echo.echo")', ""]);
});

test("server! is refused outside a definition, or without the Server module", () => {
	const component = (source) => {
		try {
			transpile(source, "T.rocx");
		} catch (error) {
			return { reason: error.reason, line: error.line, column: error.column };
		}
		assert.fail("expected the source to be refused");
	};
	assert.deepEqual(component("import pf.Server\nx = run(server!(|_, m| m))"), { reason: "server!(…) defines a server function: write it as a definition, `name = server!(|request, input| …)`", line: 2, column: 9 });
	assert.deepEqual(component("x! = server!(|_, m| m)"), { reason: "server!(…) needs `import pf.Server` in this file", line: 1, column: 6 });
});

test("server!: one that takes or answers a Try is refused at its annotation, naming the tag union to write; the compiler's report says so too", () => {
	const refused = (source) => {
		try {
			transpile(source, "Finder.rocx");
		} catch (error) {
			assert.ok(error instanceof RocxError, `expected a RocxError, got ${error}`);
			return { reason: error.reason, line: error.line, column: error.column };
		}
		assert.fail("expected the source to be refused");
	};
	const lines = ["import pf.Html", "import pf.Server", "", "Finder := [].{", "\t## Finds it.", "\tfind! : Str => Try(Str, [NotFound])", '\tfind! = server!(|_, id| if (id == "") Err(NotFound) else Ok(id))', "}"];
	assert.deepEqual(refused(lines.join("\n")), {
		reason: "find! is a server function, and what it takes and answers goes as JSON, which the builtin Try(Str, [NotFound]) can't be on this Roc (Try has no encoder or parser): use a tag union instead, [Ok(Str), Err([NotFound])], which a match reads as it reads a Try",
		line: 6,
		column: 17,
	});
	// Held in a record, on the annotation's next line, it is still a Try.
	const nested = ["import pf.Html", "import pf.Server", "", "Finder := [].{", "\tfind! :", "\t\t{ id : Str }", "\t\t=> { found : Try(U64, Str) }", "\tfind! = server!(|_, { id }| { found: Ok(id.count_utf8_bytes()) })", "}"];
	assert.match(refused(nested.join("\n")).reason, /builtin Try\(U64, Str\) can't be on this Roc.*\[Ok\(U64\), Err\(Str\)\]/);
	assert.equal(refused(nested.join("\n")).line, 7);
	// A tag union is fine, and so is a Try another definition's annotation names.
	const fine = ["import pf.Html", "import pf.Server", "", "Finder := [].{", "\tparse : Str -> Try(U64, [Bad])", "\tparse = |_| Err(Bad)", "", "\tfind! : Str => [Ok(Str), Err([NotFound])]", "\tfind! = server!(|_, id| Ok(id))", "}"];
	assert.match(transpile(fine.join("\n"), "Finder.rocx"), /find! = Server\.local\("Finder\.find", \|_, id\| Ok\(id\)\)/);
	// With no annotation, the compiler's report that Try has no parser_for gets the hint.
	const report = ["── ✗ missing method ──── Finder.roc:7:2", "", "A where clause requires the parser_for method here, but the type being used", "doesn't have that method.", "", "The value's type, which does not have a method named parser_for, is:", "", "    Try(Str, [NotFound])", "", "Hint: For this to work, the type would need a method named parser_for."].join("\n");
	const hinted = remap(report).split("\n");
	assert.deepEqual(hinted.slice(7, 10), ["    Try(Str, [NotFound])", "", TRY_HINT]);
	assert.equal(remap(report.replace("Try(Str, [NotFound])", "Thing")), report.replace("Try(Str, [NotFound])", "Thing"), "another type's report is as it was");
});

test("components: holes and attributes are computations, handlers effects", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	assert.equal(reactive(`x = <p title="Hi" class:on={a.get!()}>Hi {name.get!()}</p>`), `x = Html.element("p", [Html.attr("title", "Hi"), Html.class_of("on", || a.get!()),], [Html.text("Hi "), Html.text_of(|| name.get!()),])`);
	assert.equal(reactive(`x = <ul>{...items.get!().map(|i| <li>{i}</li>)}</ul>`), `x = Html.element("ul", [], [Html.list_of(|| items.get!().map(|i| Html.element("li", [], [Html.text(i),]))),])`, "inside, `{i}` reads nothing that changes");
	assert.equal(reactive(`x = <button on:click={|| n.set!(1)} disabled?={busy.get!()}>Go</button>`), `x = Html.element("button", [Html.on("click", || n.set!(1)), Html.flag_of("disabled", || busy.get!()),], [Html.text("Go"),])`);
	assert.equal(reactive(`x = <input on:input.value={|v| draft.set!(v)} value={draft.get!()} />`), `x = Html.void("input", [Html.on_value("input", |v| draft.set!(v)), Html.attr_of("value", || draft.get!()),])`);
	// Frames, keys' names, custom properties and optional attributes.
	const more = reactive;
	assert.equal(more(`x = <p style:--a={b!()}></p>`), `x = Html.element("p", [Html.style_of("--a", || b!()),], [])`);
	assert.equal(more(`x = <p title??={t!()}></p>`), `x = Html.element("p", [Html.optional_of("title", || t!()),], [])`);
	assert.equal(more(`x = <p on:keydown.ArrowUp={up!}></p>`), `x = Html.element("p", [Html.on_named_key("keydown", "ArrowUp", up!),], [])`);
	assert.equal(more(`x = <p on:keydown.Space={go!}></p>`), `x = Html.element("p", [Html.on_named_key("keydown", " ", go!),], [])`);
	assert.equal(more(`x = <p on:keydown.key={pressed!}></p>`), `x = Html.element("p", [Html.on_key("keydown", pressed!),], [])`);
	assert.equal(more(`x = <i on:frame.ms={tick!}></i>`), `x = Html.element("i", [Html.on_frame(tick!),], [])`);
	assert.throws(() => more(`x = <p style:color={b}></p>`), /only custom properties/);
	// Solid's control flow: a function child calls `view_with!`; `keyed={Bool.False}` the unkeyed one.
	const lines = (source) => reactive(source).split("\n").slice(1).join("\n");
	assert.equal(lines(`import pf.For\nx = <For each!={posts!()} keyed={|post| post.id} fallback={<p>None</p>}>{|post!, i!| <li>{post!().title}</li>}</For>`), `x = For.view_with_keyed!({ each!: || posts!(), keyed: |post| post.id, fallback: Html.element("p", [], [Html.text("None"),]), children: |post!, i!| Html.element("li", [], [Html.text_of(|| post!().title),]), })`);
	assert.equal(lines(`import pf.For\nx = <For each!={names!()} keyed={Bool.False}>{|name!, i| <li>{name!()}</li>}</For>`), `x = For.view_with_unkeyed!({ each!: || names!(), children: |name!, i| Html.element("li", [], [Html.text_of(|| name!()),]), })`);
	assert.equal(lines(`import pf.Show\nx = <Show when!={n!() > 0}><p>Some</p></Show>`), `x = Show.view!({ when!: || n!() > 0, children: [Html.element("p", [], [Html.text("Some"),]),], })`);
	assert.equal(lines(`import pf.Show\nx = <Show when!={xs!().first()}>{|first!| <p>{first!()}</p>}</Show>`), `x = Show.view_with!({ when!: || xs!().first(), children: |first!| Html.element("p", [], [Html.text_of(|| first!()),]), })`);
	assert.throws(() => reactive(`x = <ul>{|a| a}</ul>`), /a function child is a component's/);
	assert.throws(() => reactive(`import pf.For\nx = <For each!={xs!()} keyed={Bool.False}>{|a!, i| a}<li></li></For>`), /function child must be its only child/);
	// Roc's values have no identity: a <For> says how it keeps its rows.
	assert.throws(() => reactive(`import pf.For\nx = <For each!={xs!()}>{|a, i!| a}</For>`), /say how <For> keeps its rows: keyed=\{\|item\| item\.id\}/);
	assert.throws(() => reactive(`import pf.For\nx = <For each!={xs!()} keyed={Bool.True}>{|a, i!| a}</For>`), /say how <For> keeps its rows/);
	// A prop named as an effect is an accessor, as Solid makes a prop a getter: an expression is
	// wrapped in one; an accessor's name or a lambda is passed as it is; other props are values.
	// (A component's call is put off, to run where it is rendered: `Html.component`.)
	assert.equal(reactive(`x = <Stats likes!={likes!} label="Likes" />`), `x = Html.component(|| stats!({ likes!: likes!, label: "Likes", }))`);
	assert.equal(reactive(`x = <Heading text!={user!().name} level={2} />`), `x = Html.component(|| heading!({ text!: || user!().name, level: 2, }))`);
	assert.equal(reactive(`x = <Field value!={Store.title!} save!={|text| set_title!(text)} />`), `x = Html.component(|| field!({ value!: Store.title!, save!: |text| set_title!(text), }))`);
});

test("components: a hole or attribute that calls nothing named with ! is static", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	// Text, markup and a list: no closure, nothing for the runtime to run again (no <!--x-->).
	assert.equal(reactive(`x = <p>Hi {name} {count!().to_str()}</p>`), `x = Html.element("p", [], [Html.text("Hi "), Html.text(name), Html.text(" "), Html.text_of(|| count!().to_str()),])`);
	assert.equal(reactive(`x = <div>{=header}{...rows}</div>`), `x = Html.element("div", [], [(header), Html.join(rows),])`);
	assert.equal(reactive(`x = <div>{=if (big) <b>{n}</b> else <i>{m!()}</i>}</div>`), `x = Html.element("div", [], [Html.html_of(|| if (big) Html.element("b", [], [Html.text(n),]) else Html.element("i", [], [Html.text_of(|| m!()),])),])`, "a hole is computed if anything in it is");
	// Every kind of attribute.
	assert.equal(
		reactive(`x = <input value={v} title??={t} disabled?={off} class:on={on} style:--w={w} class={c} />`),
		`x = Html.void("input", [Html.attr("value", v), Html.optional("title", t), Html.flag("disabled", off), Html.class_if("on", on), Html.style_var("--w", w), Html.attr("class", c),])`,
	);
	assert.equal(
		reactive(`x = <input value={v!()} title??={t!()} disabled?={off!()} class:on={on!()} class={c!()} />`),
		`x = Html.void("input", [Html.attr_of("value", || v!()), Html.optional_of("title", || t!()), Html.flag_of("disabled", || off!()), Html.class_of("on", || on!()), Html.attr_of("class", || c!()),])`,
	);
	// A ! anywhere in it makes it a computation: in a string's interpolation, a lambda, a field.
	assert.equal(reactive('x = <p title={"${n!()} left"}>{"${n!()} left"}</p>'), 'x = Html.element("p", [Html.attr_of("title", || "${n!()} left"),], [Html.text_of(|| "${n!()} left"),])');
	assert.equal(reactive(`x = <p>{xs.map(|x| f!(x))}</p>`), `x = Html.element("p", [], [Html.text_of(|| xs.map(|x| f!(x))),])`);
	assert.equal(reactive(`x = <p>{props.title!()}</p>`), `x = Html.element("p", [], [Html.text_of(|| props.title!()),])`);
	// But not in a string, a character or a comment, and not `!=` or `!cond`.
	assert.equal(reactive('x = <p title={"Go!"}>{if (a != b) "yes!" else "no"}{if (!done) \'!\' else \'.\'}</p>'), 'x = Html.element("p", [Html.attr("title", "Go!"),], [Html.text(if (a != b) "yes!" else "no"), Html.text(if (!done) \'!\' else \'.\'),])');
	// A component in a hole is an effect; so is a provider. Handlers and keys are what they were.
	assert.equal(reactive(`import Card\nx = <div>{=if (big) <Card /> else Html.empty({})}</div>`).split("\n")[1], `x = Html.element("div", [], [Html.html_of(|| if (big) Html.component(|| Card.view!({})) else Html.empty({})),])`);
	assert.equal(reactive(`x = <button on:click={go} key={id}>Go</button>`), `x = Html.element("button", [Html.on("click", go), Html.key(id),], [Html.text("Go"),])`);
	// A prop named with ! is still an accessor; other props are values, as they were.
	assert.equal(reactive(`x = <Heading text!={user.name} level={2} />`), `x = Html.component(|| heading!({ text!: || user.name, level: 2, }))`);
});

test("components: transition, transition:in and transition:out are a Transition the element plays, computed if it reads anything", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	assert.equal(
		reactive(`x = <li transition={Transition.fade} transition:in={Transition.fly({ x: 0.0, y: 8.0 })} transition:out={Transition.fade.ms(100)}>Hi</li>`),
		`x = Html.element("li", [Html.transition(Both, Transition.fade), Html.transition(In, Transition.fly({ x: 0.0, y: 8.0 })), Html.transition(Out, Transition.fade.ms(100)),], [Html.text("Hi"),])`,
	);
	assert.equal(reactive(`x = <rect transition:out={Transition.grow(if (bar!().value < 0.0) Top else Bottom)} />`), `x = Html.element("rect", [Html.transition_of(Out, || Transition.grow(if (bar!().value < 0.0) Top else Bottom)),], [])`);
	// A component's prop of that name is its own.
	assert.equal(reactive(`x = <Card transition={t} />`), `x = Html.component(|| card!({ transition: t, }))`);
	assert.match(failure(`x = <li transition:fade={Transition.fade}></li>`).reason, /write transition=\{…\} \(both ways\), transition:in=\{…\} or transition:out=\{…\}/);
	assert.throws(() => reactive(`x = <li transition="fade"></li>`), /transition needs \{a Transition\}: write transition=\{Transition\.fade\}/);
	assert.throws(() => reactive(`x = <li transition:out></li>`), /transition:out needs \{a Transition\}/);
	assert.throws(() => reactive(`x = <li transition?={on}></li>`), /transition needs \{a Transition\}/);
});

test("components: a doctype, and <script> and <style> in markup, are the platform's raw text", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	assert.equal(reactive(`view! = |{}| <><!doctype html><html><body>{n!()}</body></html></>`), `view! = |{}| Html.join([Html.doctype({}), Html.element("html", [], [Html.element("body", [], [Html.text_of(|| n!()),]),]),])`);
	assert.equal(reactive(`x = <div><style>p > a { color: red }</style><script>if (a < b) go()</script></div>`), `x = Html.element("div", [], [Html.element("style", [], [Html.source_text("p > a { color: red }"),]), Html.element("script", [], [Html.source_text("if (a < b) go()"),]),])`);
	assert.equal(reactive("x = <div><script>\n\tlet s = `${n}`\n</script></div>"), 'x = Html.element("div", [], [Html.element("script", [], [Html.source_text(Str.join_with(["", \n\t"\\tlet s = `\\${n}`", \n""], "\\n")),]),])', "its lines kept as lines; ${…} in it is text");
	// A component's first <style>, in its block, is still its stylesheet: lifted, never raw text.
	const source = "import pf.Html\n\nCard := [].{\n\tview! = |{}| <p class=\"a\">{n!()}<style>i {}</style></p>\n\n\t<style>.a { color: red }</style>\n}\n";
	const { code, styles } = transpileModule(source, "Card.rocx", { module: "Card" });
	const scope = scopeClass("Card.Card");
	assert.equal(code.split("\n")[3], `\tview! = |{}| Html.element("p", [Html.attr("class", "a ${scope}"),], [Html.text_of(|| n!()), Html.element("style", [], [Html.source_text("i {}"),]),])`);
	assert.equal(code.split("\n")[5], "", "the stylesheet's line, blank");
	assert.deepEqual(styles, [{ css: `.a.${scope} { color: red }`, line: 6, component: "Card" }]);
	// A computed class keeps the scope class, in the computation.
	const computed = transpileModule("import pf.Html\n\nCard := [].{\n\tview! = |{}| <p class={c!()}></p>\n\t<style>p {}</style>\n}\n", "Card.rocx", { module: "Card" }).code;
	assert.equal(computed.split("\n")[3], `\tview! = |{}| Html.element("p", [Html.attr_of("class", || Str.concat(c!(), " ${scope}")),], [])`);
});

test("components: one runs where it is rendered; a context is named, and provided by its own tag", () => {
	const reactive = (source, options = {}) => transpileModule(source, "Picks.rocx", { module: "Picks", ...options }).code.replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	// A component's call is put off: it runs where it is rendered, so it sees the contexts above
	// that place, as in Solid. A platform's component (`import pf.Show`) is markup, made now.
	assert.equal(reactive(`import pf.Show\nimport Tally\nx = <Show when!={a!()}><Tally /></Show>`).split("\n")[2], `x = Show.view!({ when!: || a!(), children: [Html.component(|| Tally.view!({})),], })`);
	// A context is named after its module and definition, with a default or none.
	const defined = reactive(`import pf.Context\n\tpicks_context = create_context()\n\ttheme = create_context("light")`).split("\n");
	assert.equal(defined[1], `\tpicks_context = Context.required("Picks.picks_context")`);
	assert.equal(defined[2], `\ttheme = Context.define("Picks.theme", "light")`);
	// Its provider is its own tag, as in Solid 2.0: here, or in a module that imports it.
	assert.equal(reactive(`import pf.Context\n\tpicks_context = create_context()\nx = <PicksContext value={store!({})}><Tally /></PicksContext>`).split("\n")[2], `x = Context.provide!(picks_context, store!({}), [Html.component(|| tally!({})),])`);
	assert.equal(reactive(`import pf.Context\nimport Picks\nx = <PicksContext value={s}><p>Hi</p></PicksContext>`, { contexts: { PicksContext: "Picks.picks_context" } }).split("\n")[2], `x = Context.provide!(Picks.picks_context, s, [Html.element("p", [], [Html.text("Hi"),]),])`);
	assert.equal(reactive(`import pf.Context\nx = <PicksContext value={s}><p>Hi</p></PicksContext>`, { contexts: { PicksContext: "Picks.picks_context" } }).split("\n")[1], `x = Html.component(|| picks_context!({ value: s, children: [Html.element("p", [], [Html.text("Hi"),]),], }))`, "another module's, only if this one imports it");
	assert.throws(() => reactive(`import pf.Context\nx = foo(create_context())`), /create_context\(…\) defines a context: write it as a definition/);
	assert.throws(() => reactive(`\tpicks_context = create_context()`), /needs `import pf.Context`/);
	assert.throws(() => reactive(`import pf.Context\n\tpicks_context = create_context()\nx = <PicksContext><p /></PicksContext>`), /write <PicksContext value=\{…\}>/);
	assert.throws(() => reactive(`import pf.Context\n\tpicks_context = create_context()\nx = <PicksContext value={s} />`), /it needs children/);
});

test("components: a value prop read from something that changes is read by the place that renders the component (Html.component_with); an accessor, a lambda or a constant isn't", () => {
	const reactive = (source) => transpileModule(source, "Page.rocx", { module: "Page" }).code.split("\n")[1];
	assert.equal(reactive(`import Shows\nx = <p>{=<Shows label={word!()} />}</p>`), `x = Html.element("p", [], [Html.html_of(|| Html.component_with(|| { label: word!(), }, Shows.view!)),])`, "the hole reads label, and renders Shows anew when it changes");
	assert.equal(reactive(`import Shows\nx = <Shows label={word!()} size={2} />`), `x = Html.component_with(|| { label: word!(), size: 2, }, Shows.view!)`, "outside a hole, read once, before it runs");
	assert.equal(reactive(`import Shows\nx = <Shows label!={word!()} save={save!} pick={|it| pick!(it)} size={2} />`), `x = Html.component(|| Shows.view!({ label!: || word!(), save: save!, pick: |it| pick!(it), size: 2, }))`, "an accessor (Solid's getter), a function and a constant: nothing to read");
});

test("components: a pure one (`view`, no `!`) is called where it is written, as a function; it makes the hole it is in no computation", () => {
	const reactive = (source, options = {}) => transpileModule(source, "Page.rocx", { module: "Page", ...options }).code.replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	const views = { Heading: "view", Counter: "view!" };
	assert.equal(reactive(`import Ui/Heading\nx = <Heading id="a">Hi</Heading>`, { views }).split("\n")[1], `x = Heading.view({ id: "a", children: [Html.text("Hi"),], })`, "rocx build says Heading's view is pure");
	assert.equal(reactive(`import Counter\nx = <Counter start={1} />`, { views }).split("\n")[1], `x = Html.component(|| Counter.view!({ start: 1, }))`, "a view! is put off, as before");
	assert.equal(reactive(`import Badge\nx = <Badge />`).split("\n")[1], `x = Html.component(|| Badge.view!({}))`, "not known to be pure: view!");
	assert.equal(reactive(`import Ui/Heading\nx = <ul>{...items.map(|item| <li><Heading id={item}>{item}</Heading></li>)}</ul>`, { views }).split("\n")[1], `x = Html.element("ul", [], [Html.join(items.map(|item| Html.element("li", [], [Heading.view({ id: item, children: [Html.text(item),], }),]))),])`, "static: nothing in the hole is an effect");
	assert.equal(reactive(`Card := [].{\n\tview = |{ title }| <h2>{title}</h2>\n}\nx = <Card title="T" />`).split("\n")[3], `x = Card.view({ title: "T", })`, "this file's own");
	assert.equal(reactive(`card = |{ title }| <h2>{title}</h2>\nx = <p><Card title="T" /></p>`).split("\n")[1], `x = Html.element("p", [], [card({ title: "T", }),])`, "a function of this file's, defined with no !");
	assert.equal(reactive(`stats! = |{ n }| <p>{n}</p>\nx = <Stats n={1} />`).split("\n")[1], `x = Html.component(|| stats!({ n: 1, }))`, "one defined with ! is put off");
	assert.equal(reactive(`import pf.Show\nx = <Show when!={a!()}><p /></Show>`, { views: { Show: "view" } }).split("\n")[1], `x = Show.view!({ when!: || a!(), children: [Html.element("p", [], []),], })`, "a platform's is the platform's");
	assert.deepEqual(viewsDefined("Heading := [].{\n\tview : { id : Str } -> Html\n\tview = |_| x\n}\n\nCounter := [].{\n\tview! = |_| x\n\tview_with = 1\n}\n\nOther := [].{\n\tx = 1\n}\n"), { Heading: "view", Counter: "view!" });
	// A type nested above the view: the view is the outer block's.
	assert.deepEqual(viewsDefined("Icon := [].{\n\tName := [Check, Cross].{\n\t\tis_eq : Name, Name -> Bool\n\t\tis_eq = |a, b| a == b\n\t}\n\n\tview! : { name : Name } => Html\n\tview! = |_| x\n}\n"), { Icon: "view!" });
	assert.deepEqual(viewsDefined("Card := [].{\n\tPart := [Head].{\n\t\tview = |_| y\n\t}\n\n\tview = |_| x\n}\n"), { Card: "view", Part: "view" }, "each its own");
});

test("<NoHydration>: what is inside renders on the server only; the browser's copy has none of it, nor an import only it used", () => {
	const source = [
		"import pf.Html",
		"import Ui/Code",
		"import Ui/Counter",
		"",
		"Page := [].{",
		"\tview! : {} => Html",
		"\tview! = |{}|",
		"\t\t<main>",
		"\t\t\t<NoHydration>",
		"\t\t\t\t<p>Prose, <Code code=\"x\" />, {count!().to_str()}</p>",
		"\t\t\t\t<Counter />",
		"\t\t\t\t<ul>",
		"\t\t\t\t\t<li>A child over lines</li>",
		"\t\t\t\t</ul>",
		"\t\t\t</NoHydration>",
		"\t\t\t<Counter />",
		"\t\t</main>",
		"}",
	].join("\n");
	const views = { Code: "view", Counter: "view!" };
	const server = transpileModule(source, "Page.rocx", { module: "Page", views });
	const browser = transpileModule(source, "Page.rocx", { module: "Page", views, client: true });
	assert.equal(server.regions, 1);
	const lines = server.code.split("\n");
	assert.deepEqual(lines.slice(8, 15), [
		"\t\t\tHtml.no_hydration([",
		'\t\t\t\tHtml.element("p", [], [Html.text("Prose, "), Code.view({ code: "x", }), Html.text(", "), Html.text_of(|| count!().to_str()),]), Html.text(" "),',
		"\t\t\t\tHtml.component(|| Counter.view!({})), Html.text(\" \"),",
		'\t\t\t\tHtml.element("ul", [], [',
		'\t\t\t\t\tHtml.element("li", [], [Html.text("A child over lines"),]),',
		"\t\t\t\t]),",
		"\t\t\t]), Html.text(\" \"),",
	], "on the server, what is inside as it is anywhere else, in Html.no_hydration");
	const kept = browser.code.split("\n");
	assert.equal(kept.length, lines.length, "lines stay lines");
	assert.deepEqual(kept.slice(8, 15), ["\t\t\tHtml.no_hydration([", "\t\t\t\t", "\t\t\t\t", "\t\t\t\t", "\t\t\t\t\t", "\t\t\t\t", '\t\t\t]), Html.text(" "),'], "the browser's copy: a placeholder, its children gone, every line kept");
	assert.equal(kept[1], "", "an import only the children used goes, its line left empty");
	assert.equal(kept[2], "import Ui/Counter", "one the rest uses stays");
	assert.equal(kept[15], lines[15], "the rest is as on the server");
	assert.doesNotMatch(browser.code, /Prose|Code\.view/);
	// A file without one: the browser's copy is the server's.
	const plain = "import pf.Html\n\nview! = |{}| <p>Hi</p>\n";
	assert.equal(transpileModule(plain, "P.rocx", { reactive: true, client: true }).code, transpileModule(plain, "P.rocx").code);
	assert.equal(transpileModule(plain, "P.rocx").regions, 0);
});

test("<NoHydration>: a handler, a key or a transition written inside is refused (it would never run), as is one with attributes", () => {
	const refused = (inner) => {
		try {
			transpile(`import pf.Html\n\nview! = |{}|\n\t<main>\n\t\t<NoHydration>\n\t\t\t${inner}\n\t\t</NoHydration>\n\t</main>\n`, "T.rocx");
		} catch (error) {
			assert.ok(error instanceof RocxError, `expected a RocxError, got ${error}`);
			return { reason: error.reason, line: error.line, column: error.column };
		}
		assert.fail("expected the source to be refused");
	};
	assert.deepEqual(refused("<button on:click={go!}>Go</button>"), { reason: "on:click is inside <NoHydration>, which the browser never hydrates, so this handler would never run: put <button> outside <NoHydration>", line: 6, column: 12 });
	assert.match(refused("<p>{=if (open!()) <button on:click={go!}>Go</button> else Html.empty({})}</p>").reason, /^on:click is inside <NoHydration>/, "markup in a hole inside it too");
	assert.match(refused("<li key={id}>x</li>").reason, /^key is inside <NoHydration>, which the browser never hydrates: nothing keeps <li> by it there/);
	assert.match(refused("<p transition:in={Transition.fade}>x</p>").reason, /^transition:in is inside <NoHydration>, which the browser never hydrates, so nothing there comes or goes/);
	assert.match(failureOf(() => transpile("import pf.Html\n\nview! = |{}| <NoHydration class=\"x\"><p /></NoHydration>\n", "T.rocx")), /<NoHydration> takes no attributes/);
	assert.match(failureOf(() => transpile("import pf.Html\n\nview! = |{}| <NoHydration />\n", "T.rocx")), /<NoHydration> holds what the server alone renders/);
	// Outside it, the same are a component's as ever; a component inside it is allowed, and renders once.
	assert.match(transpile("import pf.Html\nimport Counter\n\nview! = |{}| <div><NoHydration><Counter /></NoHydration><button on:click={go!}>Go</button></div>\n", "T.rocx"), /Html\.no_hydration\(\[Html\.component\(\|\| Counter\.view!\(\{\}\)\),\]\), Html\.element\("button", \[Html\.on\("click", go!\),\]/);
});

const failureOf = (render) => {
	try {
		render();
	} catch (error) {
		return error.reason;
	}
	assert.fail("expected the source to be refused");
};

test("rocString escapes what Roc would read differently", () => {
	assert.equal(rocString('a"b\\c${d}\ne\t\u0001'), '"a\\"b\\\\c\\${d}\\ne\\t\\u(1)"');
});

test("unsafe or unclear markup is refused at its line and column", () => {
	assert.deepEqual(failure(`x =\n\t<a onclick="go()">x</a>`), { reason: "inline event handlers (onclick) aren't allowed: in a component, write on:click={…}", line: 2, column: 5 });
	assert.match(failure(`x = <a class={c}x</a>`).reason, /unexpected/);
	assert.match(failure(`x = <a title=hi>x</a>`).reason, /unquoted values aren't allowed/);
	assert.match(failure(`x = <p style={s}>x</p>`).reason, /style takes a static value/);
	assert.match(failure(`x = <br>`).reason, /write <br \/>/);
	assert.deepEqual(failure(`x = <ul>\n  <li>a</li>\n</ol>`), { reason: "<ul> is closed by </ol>", line: 3, column: 1 });
	assert.match(failure(`x = <p>a < b</p>`).reason, /write &lt;/);
	assert.match(failure(`x = <p>a > b</p>`).reason, /write &gt;/);
	assert.match(failure(`x = <p>{}</p>`).reason, /empty/);
	assert.match(failure(`x = <p>&bogus;</p>`).reason, /unknown entity/);
	assert.equal(roc(`x = <Div>x</Div>`), `x = Html.component(|| div!({ children: [Html.text("x"),], }))`, "a capitalised tag is a component");
	assert.match(failure(`x = <DIV>x</DIV>`).reason, /lower case/);
	assert.match(failure(`x = <p>never closed`).reason, /<p> is never closed/);
	assert.match(failure(`x = <Pill data-x="1" />`).reason, /props are Roc field names/);
	assert.match(failure(`x = <input checked?="yes" />`).reason, /needs \{a Bool\}/);
	assert.match(failure(`x = <p style:color={c} />`).reason, /only custom properties/);
	assert.match(failure(`x = <a class:card-link>x</a>`).reason, /class:card-link needs \{a Bool\}/, "not a literal attribute");
	assert.match(failure(`x = <a style:--x />`).reason, /style:--x needs \{a value\}/);
	assert.equal(roc(`x = <p style:--size={s} />`), `x = Html.element("p", [Html.style_var("--size", s),], [])`);
	assert.equal(roc(`x = <a rel??={r} />`), `x = Html.element("a", [Html.optional("rel", r),], [])`);
	assert.match(failure(`x = <a rel??="x" />`).reason, /always there/);
});
