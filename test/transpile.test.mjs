import { test } from "node:test";
import assert from "node:assert/strict";
import { RocxError, rocString, transpile, transpileModule, viewsDefined } from "../rocx-cli/rocx.mjs";
import { remap } from "../rocx-cli/rocx.mjs";
import { scopeClass } from "../rocx-cli/rocx.mjs";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

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
	assert.equal(roc(`x = <a href={link} title="Hi">{caption}</a>`), `x = Html.element("a", [Html.attr("href", link), Html.attr_literal("title", "Hi"),], [Html.shown(caption),])`);
	assert.equal(roc(`x = <div class:on={a} hidden?={b} required></div>`), `x = Html.element("div", [Html.class_if("on", a), Html.flag("hidden", b), Html.flag("required", Bool.True),], [])`);
	assert.equal(roc(`x = <p>{=pill} {...rows}</p>`), `x = Html.element("p", [], [Html.shown(pill), Html.text(" "), Html.join(rows),])`);
	assert.equal(roc(`x = <br />`), `x = Html.void("br", [])`);
	assert.equal(roc(`x = <div />`), `x = Html.element("div", [], [])`);
	assert.equal(roc(`x = <!doctype html>`), `x = Html.doctype({})`);
	assert.equal(roc(`x = <><b>a</b></>`), `x = Html.join([Html.element("b", [], [Html.text("a"),]),])`);
	assert.equal(roc(`x = <></>`), `x = Html.join([])`, "the empty fragment: nothing, as Html.empty({}) is");
});

test("components: imported modules' view!, others a local snake_case function's, run where they are rendered", () => {
	const source = `import ui.StatusPill\nimport Button as Btn\n\nx = <StatusPill status={s} />\ny = <Btn label="Go" primary />\nz = <LocalThing>hi</LocalThing>\nw = <Empty />`;
	const lines = roc(source).split("\n");
	assert.equal(lines[3], `x = StatusPill.view!({ status: s, })`, "a package's is markup, made where it is written");
	assert.equal(lines[4], `y = Html.component(|| Btn.view!({ label: || "Go", primary: || Bool.True, }))`, "its value props are getters (D-039)");
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
	assert.match(out.split("\n")[6], /Html\.shown\(post\.title\)/);
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
	assert.equal(roc(`Props := { fallback : Html ?? <></>, n : U64 }`), `Props := { fallback : Html ?? Html.join([]), n : U64 }`, "a default after ??");
	assert.equal(roc(`x = found ?? <i/>`), `x = found ?? Html.element("i", [], [])`);
	assert.equal(roc(`x = f? <b`), `x = f? <b`, "a lone ? ends a value");
	assert.equal(roc(`x = a ?? |b| b`), `x = a ?? |b| b`);
	assert.equal(roc(`x = {\n\tm = match a { B => 1 }\n\t<b/>\n}`), `x = {\n\tm = match a { B => 1 }\n\tHtml.element("b", [], [])\n}`, "first on its line, after a statement");
	assert.equal(roc(`x = '<'`), `x = '<'`);
	assert.equal(roc(`x = "<b>" # <i>`), `x = "<b>" # <i>`);
	assert.equal(roc(`x = "a\\"<b>${1}"`), `x = "a\\"<b>${1}"`);
	assert.equal(roc("x =\n\t\\\\<b>${y}</b>"), "x =\n\t\\\\<b>${y}</b>", "a \\\\ line is a string");
	assert.equal(roc(`x = "\${<b/>}"`), `x = "\${Html.element("b", [], [])}"`);
});

test("HTML's whitespace rule, as Svelte has it, but for a space on the tag's line", () => {
	assert.equal(roc(`x = <p>Published {at}</p>`), `x = Html.element("p", [], [Html.text("Published "), Html.shown(at),])`);
	assert.equal(roc(`x = <p>a <b>b</b> c</p>`), `x = Html.element("p", [], [Html.text("a "), Html.element("b", [], [Html.text("b"),]), Html.text(" c"),])`);
	assert.equal(roc(`x = <p>\n\t\tone\n\t\ttwo\n\t</p>`), `x = Html.element("p", [], [\n\t\tHtml.text("one two"),\n\t\t\n\t])`);
	assert.equal(roc(`x = <p>  spaced   out  </p>`), `x = Html.element("p", [], [Html.text(" spaced out "),])`, "runs collapsed; a space on the tag's line stays");
	assert.equal(roc(`x = <span>You are </span>`), `x = Html.element("span", [], [Html.text("You are "),])`, "a space before the closing tag, on its line, stays");
	assert.equal(roc(`x = <b> x</b>`), `x = Html.element("b", [], [Html.text(" x"),])`, "and one after the opening tag");
	assert.equal(roc(`x = <span> </span>`), `x = Html.element("span", [], [Html.text(" "),])`, "a space alone is a space");
	assert.equal(roc(`x = <span>\n</span>`), `x = Html.element("span", [], [\n])`, "a line break alone is nothing");
	assert.equal(roc(`x = <p> one \n</p>`), `x = Html.element("p", [], [Html.text(" one"),\n])`, "whitespace with a line break before the closing tag goes, spaces before the break too");
	assert.equal(roc(`x = <p>\t \n\tone </p>`), `x = Html.element("p", [], [\n\tHtml.text("one "),])`, "and after the opening tag");
	assert.equal(roc(`x = <p>Hi <!-- a comment -->\n</p>`), `x = Html.element("p", [], [Html.text("Hi"),\n])`, "a comment's whitespace is the run's");
	assert.equal(roc(`x = <p><b>a</b> </p>`), `x = Html.element("p", [], [Html.element("b", [], [Html.text("a"),]), Html.text(" "),])`, "between an element and the closing tag, on one line");
	assert.equal(
		roc(`x = <p>\n\tthe <a href="/t">terms</a> and\n\t<a href="/p">policy</a> of\n\t{name}\n</p>`),
		`x = Html.element("p", [], [\n\tHtml.text("the "), Html.element("a", [Html.attr_literal("href", "/t"),], [Html.text("terms"),]), Html.text(" and "),\n\tHtml.element("a", [Html.attr_literal("href", "/p"),], [Html.text("policy"),]), Html.text(" of "),\n\tHtml.shown(name),\n])`,
		"a line break next to a link or a value is a space, as in HTML",
	);
	assert.equal(roc(`x = <ul>\n\t<li>a</li>\n\t<li>b</li>\n</ul>`), `x = Html.element("ul", [], [\n\tHtml.element("li", [], [Html.text("a"),]), Html.text(" "),\n\tHtml.element("li", [], [Html.text("b"),]),\n])`);
	assert.equal(roc(`x = <pre>  a\n  <b>b</b>  </pre>`), `x = Html.element("pre", [], [Html.text("  a\\n  "),\n  Html.element("b", [], [Html.text("b"),]), Html.text("  "),])`, "pre keeps it");
	assert.equal(roc(`x = <p>a&nbsp;\n</p>`), `x = Html.element("p", [], [Html.text("a\u00a0"),\n])`, "&nbsp; is not whitespace");
	assert.equal(roc(`x = <Button>\n\tSave\n</Button>`), `x = Html.component(|| button!({ children: [\n\tHtml.text("Save"),\n], }))`);
});

test("entities and literal text", () => {
	assert.equal(roc(`x = <p>Tom &amp; Jerry &middot; &#x2014; &#39;</p>`), `x = Html.element("p", [], [Html.text("Tom & Jerry · — '"),])`);
	assert.equal(roc(`x = <p>{"<"} and {"{"}</p>`), `x = Html.element("p", [], [Html.shown("<"), Html.text(" and "), Html.shown("{"),])`);
	assert.equal(roc(`x = <p title="a &quot;b&quot;" />`), `x = Html.element("p", [Html.attr_literal("title", "a \\"b\\""),], [])`);
});

test("script and style keep their text as written", () => {
	assert.equal(roc(`x = <style>a { color: red }</style>`), `x = Html.element("style", [], [Html.source_text("a { color: red }"),])`);
	assert.equal(roc("x = <script>\n\tlet s = `${1}`\n</script>"), 'x = Html.element("script", [], [Html.source_text(Str.join_with(["", \n\t"\\tlet s = `\\${1}`", \n""], "\\n")),])');
	assert.equal(roc(`x = while (i < n) <b/>`), `x = while (i < n) Html.element("b", [], [])`, "after a condition, an expression starts");
});

test("every file is components: a page's markup has handlers and keys too; Html is the platform's", () => {
	assert.equal(roc(`x = <button on:click={save!}>Save</button>`), `x = Html.element("button", [Html.on("click", save!),], [Html.text("Save"),])`);
	assert.equal(roc(`x = <li key={item.id}>{item.text}</li>`), `x = Html.element("li", [Html.key(item.id),], [Html.shown(item.text),])`);
	assert.equal(roc(`x = <Pill on={a} />`), `x = Html.component(|| pill!({ on: a, }))`, "a component's prop may be called on");
	assert.equal(roc(`x = <Row key={k} />`), `x = Html.component(|| row!({}))`, "a component's key is a .map row's (D-071), never a prop");
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
	assert.equal(component(`x = <input type="checkbox" on:change.checked={set_done!} />`), `x = Html.void("input", [Html.attr_literal("type", "checkbox"), Html.on_checked("change", set_done!),])`);
	assert.equal(component(`x = <div tabindex="0" on:keydown.ArrowUp={up!} on:keydown.w={up!} />`), `x = Html.element("div", [Html.attr_literal("tabindex", "0"), Html.on_named_key("keydown", "ArrowUp", up!), Html.on_named_key("keydown", "w", up!),], [])`);
	assert.match(refused(`x = <b on:click="go()" />`), /not a string: a handler is Roc, never script/);
	assert.match(refused(`x = <b on:click />`), /on:click needs \{a handler\}/);
	assert.match(refused(`x = <b on:click?={a} />`), /takes \{a handler\}/);
	assert.match(refused(`x = <b on:Click={a} />`), /write on:event=\{a handler\}/);
	assert.match(refused(`x = <b on:input.blob={a} />`), /takes .value, .checked, .key, .keys, .point, .visible, .data or .files, a key's name \(.Enter, .ArrowUp, .w\) after any modifier keys \(.Shift\+Enter, .Mod\+K\), or .prevent, not .blob/);
	// Key combinations: the modifier keys held, each once, then the key; `.keys` gives them all.
	assert.equal(component(`x = <input on:keydown.Shift+Enter={send!} on:keydown.Mod+K={open!} on:keydown.Ctrl+Alt+Delete={reset!} on:keyup.Mod+Space={go!} />`), `x = Html.void("input", [Html.on_named_key("keydown", "Shift+Enter", send!), Html.on_named_key("keydown", "Mod+K", open!), Html.on_named_key("keydown", "Ctrl+Alt+Delete", reset!), Html.on_named_key("keyup", "Mod+ ", go!),])`);
	assert.equal(component(`x = <input on:keydown.keys={pressed!} />`), `x = Html.void("input", [Html.on_keys("keydown", pressed!),])`);
	assert.match(refused(`x = <input on:keydown.Hyper+K={a} />`), /Hyper isn't a modifier key: the keys held are Shift, Ctrl, Alt, Meta and Mod/);
	assert.match(refused(`x = <input on:keydown.Shift+Shift+K={a} />`), /each modifier key goes in once/);
	assert.match(refused(`x = <input on:keydown.Mod+Ctrl+K={a} />`), /Mod is ⌘ on macOS and Ctrl elsewhere/);
	assert.match(refused(`x = <input on:keydown.Shift+={a} />`), /not .Shift\+/);
	assert.match(refused(`x = <input on:click.Shift+Enter={a} />`), /a key's name goes with on:keydown or on:keyup/);
	assert.match(refused(`x = <input data-a+b="c" />`), /unexpected \+ in data-a\+b: a \+ joins the keys of a combination/);
	// <Document> and <Window>: handlers on the whole document or window, written as an element's.
	assert.equal(component(`x = <Document on:keydown.Mod+K={open!} on:keydown.Escape={close!} on:click.prevent={away!} />`), `x = Html.on_document([Html.on_named_key("keydown", "Mod+K", open!), Html.on_named_key("keydown", "Escape", close!), Html.on_prevent("click", away!),])`);
	assert.equal(component(`x = <Window on:resize={fit!} on:keydown.keys={pressed!} />`), `x = Html.on_window([Html.on("resize", fit!), Html.on_keys("keydown", pressed!),])`);
	assert.match(refused(`x = <Document on:click={a}><p>x</p></Document>`), /<Document> renders nothing, so it has no children/);
	assert.match(refused(`x = <Document class="a" on:click={a} />`), /<Document> takes handlers only/);
	assert.match(refused(`x = <Window on:frame.ms={tick!} />`), /<Window> takes handlers only/);
	assert.match(refused(`x = <Document onclick="go()" />`), /inline event handlers \(onclick\) aren't allowed/);
	assert.equal(component(`import Document\n\nx = <Document title="t" />`), `import Document\n\nx = Html.component(|| Document.view!({ title: || "t", }))`, "a module of the file's own by that name is a component, its value props getters (D-039)");
	// <Meta>, <Link> and <Style> (D-054): elements in the document's <head>, written as a <meta>'s, a
	// <link>'s and a <style>'s are; <Style>'s CSS static, as written.
	assert.equal(component(`x = <Meta name="description" content={summary!()} />`), `x = Html.document_head(Html.void("meta", [Html.attr_literal("name", "description"), Html.attr_of("content", || summary!()),]))`);
	assert.equal(component(`x = <Link rel="canonical" href="/posts" />`), `x = Html.document_head(Html.void("link", [Html.attr_literal("rel", "canonical"), Html.attr_literal("href", "/posts"),]))`);
	assert.equal(component(`x = <Style>p { color: red }</Style>`), `x = Html.document_head(Html.element("style", [], [Html.source_text("p { color: red }")]))`);
	assert.match(refused(`x = <Style />`), /<Style> holds its CSS/);
	assert.match(refused(`x = <Meta name="a">b</Meta>`), /<Meta> has no children/);
	assert.match(refused(`x = <Link rel="x" on:load={a} />`), /<Link> is an element in the document's <head>: it takes no handlers/);
	assert.equal(component(`import Meta\n\nx = <Meta title="t" />`), `import Meta\n\nx = Html.component(|| Meta.view!({ title: || "t", }))`, "a module of the file's own by that name is a component");
	// Drag and drop are events as any other; `.prevent` takes over what the browser would do.
	assert.equal(component(`x = <li draggable="true" on:dragstart={start!} on:dragend={stop!}>a</li>`), `x = Html.element("li", [Html.attr_literal("draggable", "true"), Html.on("dragstart", start!), Html.on("dragend", stop!),], [Html.text("a"),])`);
	assert.equal(component(`x = <ul on:dragenter={over!} on:dragleave={out!} on:drop={|| put!(day)} on:drop.value={dropped!} />`), `x = Html.element("ul", [Html.on("dragenter", over!), Html.on("dragleave", out!), Html.on("drop", || put!(day)), Html.on_value("drop", dropped!),], [])`);
	assert.equal(component(`x = <a href="/next" on:click.prevent={go!}>Next</a>`), `x = Html.element("a", [Html.attr_literal("href", "/next"), Html.on_prevent("click", go!),], [Html.text("Next"),])`);
	assert.match(refused(`x = <b on:input.constructor={a} />`), /not .constructor/);
	assert.match(refused(`x = <div on:frame={tick!} />`), /frames are on:frame.ms=\{…\}/);
	assert.match(refused(`x = <div on:click.ms={tick!} />`), /frames are on:frame.ms/);
	assert.match(refused(`x = <div on:viewport.value={seen!} />`), /write on:viewport=\{\|view\| …\}/);
	assert.match(refused(`x = <Window on:viewport={seen!} />`), /<Window> takes handlers only/);
	// D-055: where the pointer is, whether the page shows, what a drop carries and its files; what a
	// drag of an element carries and shows.
	assert.equal(component(`x = <div on:pointermove.point={moved!} on:drop.data={took!} on:drop.files={kept!} />`), `x = Html.element("div", [Html.on_point("pointermove", moved!), Html.on_data("drop", took!), Html.on_files("drop", kept!),], [])`);
	assert.equal(component(`x = <input type="file" on:change.files={chose!} />`), `x = Html.void("input", [Html.attr_literal("type", "file"), Html.on_files("change", chose!),])`);
	assert.equal(component(`x = <Document on:visibilitychange.visible={shown!} on:paste.files={pasted!} />`), `x = Html.on_document([Html.on_visible("visibilitychange", shown!), Html.on_files("paste", pasted!),])`);
	assert.equal(component(`x = <li draggable="true" drag:data={[("text/plain", title)]} drag:image="ghost" />`), `x = Html.element("li", [Html.attr_literal("draggable", "true"), Html.drag_data([("text/plain", title)]), Html.drag_image("ghost"),], [])`);
	assert.equal(component(`x = <li drag:data={[("text/plain", card!().title)]} drag:image={"ghost-\${card!().id}"} />`), `x = Html.element("li", [Html.drag_data_of(|| [("text/plain", card!().title)]), Html.drag_image_of(|| "ghost-\${card!().id}"),], [])`);
	assert.match(refused(`x = <div on:click.visible={a!} />`), /.visible goes with on:visibilitychange/);
	assert.match(refused(`x = <div on:click.files={a!} />`), /.files goes with on:drop or on:paste, or a file input's on:change/);
	assert.match(refused(`x = <div on:change.data={a!} />`), /.data goes with on:drop or on:paste, which carry it/);
	assert.match(refused(`x = <li drag:ghost={a} />`), /write drag:data=\{\[\(type, value\), …\]\} \(what a drag of it carries\) or drag:image=\{id\}/);
	assert.match(refused(`x = <li drag:data="text" />`), /drag:data needs \{a list of \(type, value\)\}/);
	assert.match(refused(`x = <div on:click.Enter={go!} />`), /a key's name goes with on:keydown or on:keyup/);
	assert.match(refused(`x = <div on:keydown.enter={go!} />`), /not .enter/, "key names are as the browser has them: Enter");
	assert.match(refused(`x = <a onclick="go()">x</a>`), /inline event handlers \(onclick\) aren't allowed: in a component, write on:click=\{…\}/);
});

test("server! is gone (D-023): refused at its line, saying what to write instead", () => {
	try {
		transpile("import pf.Server\n\necho! = server!(|_, m| m)\n", "Echo.rocx");
		assert.fail("expected server! to be refused");
	} catch (error) {
		assert.ok(error instanceof RocxError, `expected a RocxError, got ${error}`);
		assert.deepEqual(
			{ reason: error.reason, line: error.line, column: error.column },
			{ reason: "server!(…) is gone (D-023): define a GET endpoint (get! in a route's +server.roc) and read it with Api.get_…(params).read!()", line: 3, column: 9 },
		);
	}
});

test("components: a record spread on a component passes its fields on as they are (D-052): Solid's merge (the last of a name wins) and, with a pattern's ..rest, its omit", () => {
	const code = (lines, opts = {}) => transpileModule(lines.join("\n"), "Ui/Button.rocx", { module: "Ui/Button", ...opts }).code.split("\n");
	const annotated = code(["import Base", "Button := [].{", "\tview! : { kind : Str, label : Str, size : U64, on_press! : () => {} } => Html", "\tview! = |{ kind, ..rest }| <Base {...rest} size={3} class={kind} />", "}"]);
	assert.equal(annotated[3], "\tview! = |{ kind: kind!, ..rest }| Html.component(|| Base.view!({ label: rest.label, on_press!: rest.on_press!, size: || 3, class: || kind!(), }))", "the fields rocx knows, written out, getters as they are; an attribute after replaces one");
	const before = code(["import Base", "Button := [].{", "\tview! : { label : Str } => Html", "\tview! = |props| <Base label=\"x\" {...props} />", "}"]);
	assert.equal(before[3], "\tview! = |props| Html.component(|| Base.view!({ label: props.label, }))", "a spread after an attribute replaces it, as in JSX");
	const unknown = code(["import Base", "Button := [].{", "\tview! = |{ kind, ..rest }| <Base {...rest} size={3} />", "}"]);
	assert.equal(unknown[2], "\tview! = |{ kind: kind!, ..rest }| Html.component(|| Base.view!({ ..rest, size: || 3, }))", "fields rocx doesn't know: Roc's record update");
	const alone = code(["import Base", "Button := [].{", "\tview! = |{ kind, ..rest }| <Base {...rest} />", "}"]);
	assert.equal(alone[2], "\tview! = |{ kind: kind!, ..rest }| Html.component(|| Base.view!(rest))", "alone, the record as it is");
	const read = code(["Button := [].{", "\tview! : { kind : Str, label : Str } => Html", "\tview! = |{ kind, ..rest }| <p>{rest.label} {kind}</p>", "}"]);
	assert.equal(read[2], `\tview! = |{ kind: kind!, ..rest }| Html.element("p", [], [Html.hole_of(|| Html.hole((rest.label)())), Html.text(" "), Html.hole_of(|| Html.hole(kind!())),])`, "a field of the rest read through its getter, as a whole record's is");
	assert.throws(() => code(["import Base", "Button := [].{", "\tview! = |{ kind, ..rest }| <Base {...rest} {...kind} />", "}"]), /two records whose fields rocx doesn't know/);
	assert.throws(() => code(["import pf.Loading", "Button := [].{", "\tview! = |{ kind, ..rest }| <Loading {...rest} />", "}"]), /<Loading> takes its props as they are written/);
	assert.throws(() => code(["import Base", "x = <Base {...make(1)} />"]), /spread a record by its name/);
	assert.throws(() => code(["x = <div {...attrs} />"]), /unexpected "\{" in <div>/, "an element takes no spread");
});

test("rocx check: a report at a component given a record's fields gets a hint, what rocx wrote and what to do (D-052)", () => {
	const dir = mkdtempSync(join(tmpdir(), "rocx-spread-"));
	try {
		// The compiler's report at the line (1-based) of the generated Button.roc, which quotes it.
		const report = (lines, line) => {
			const source = lines.join("\n");
			writeFileSync(join(dir, "Button.rocx"), source);
			const generated = transpileModule(source, "Button.rocx", { module: "Button" }).code;
			writeFileSync(join(dir, "Button.roc"), generated);
			const quoted = generated.split("\n")[line - 1].trim();
			return remap([`── ✗ type mismatch ──── ${join(dir, "Button.roc")}:${line}:30`, "", "This expression is used in an unexpected way.", "", quoted, "^^^^", "", "Hint: This record is missing the field: size", "", "── 1 errors and 0 warnings ──"].join("\n")).split("\n");
		};
		const update = report(["import Base", "Button := [].{", "\tview! = |{ kind, ..rest }| <Base {...rest} size={3} />", "}"], 3);
		const hint = update.findIndex((line) => line.startsWith("Hint: rocx passes {...record} on as Roc's record update"));
		assert.ok(hint > 0 && hint < update.indexOf("── 1 errors and 0 warnings ──"), update.join("\n"));
		assert.ok(update.some((line) => line.trim() === "view! = |{ kind, ..rest }| <Base {...rest} size={3} />"), "the .rocx line quoted");
		const written = report(["import Base", "Button := [].{", "\tview! : { kind : Str, label : Str } => Html", "\tview! = |{ kind, ..rest }| <Base {...rest} />", "}"], 4);
		assert.ok(written.some((line) => line.startsWith("Hint: rocx passes {...record} on field by field")), written.join("\n"));
		const plain = report(["import Base", "Button := [].{", "\tview! = |{ kind }| <Base size={3} />", "}"], 3);
		assert.ok(!plain.some((line) => line.startsWith("Hint: rocx passes")), "no spread, no hint");
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("components: holes and attributes are computations, handlers effects", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	assert.equal(reactive(`x = <p title="Hi" class:on={a.get!()}>Hi {name.get!()}</p>`), `x = Html.element("p", [Html.attr_literal("title", "Hi"), Html.class_of("on", || a.get!()),], [Html.text("Hi "), Html.hole_of(|| Html.hole(name.get!())),])`);
	assert.equal(reactive(`x = <ul>{...items.get!().map(|i| <li key={i}>{i}</li>)}</ul>`), `x = Html.element("ul", [], [Html.rows!(|| items.get!(), |i| i, |i!, _| Html.template("T:0",  Html.element("li", [Html.key(i!()),], [Html.hole_of(|| Html.hole(i!())),]))),])`, "its rows (D-071): `{i}` reads the row's item now");
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
	assert.equal(more(`x = <div on:viewport={seen!}></div>`), `x = Html.element("div", [Html.on_viewport(seen!),], [])`);
	assert.equal(more(`x = <p style:color={b!()} style:-webkit-line-clamp={n}></p>`), `x = Html.element("p", [Html.style_of("color", || b!()), Html.style_var("-webkit-line-clamp", n),], [])`, "a property of the style, computed or not");
	assert.throws(() => more(`x = <p style:col0r={b}></p>`), /a style property's name is letters and dashes \(style:color=\{…\}\), or a custom property's/);
	// A component's function child calls `view_with!`.
	const lines = (source) => reactive(source).split("\n").slice(1).join("\n");
	assert.equal(lines(`import pf.Loading\nx = <Loading fallback={<p>Wait</p>}><p>Some</p></Loading>`), `x = Loading.view!({ fallback: Html.element("p", [], [Html.text("Wait"),]), children: [Html.element("p", [], [Html.text("Some"),]),], })`);
	assert.throws(() => reactive(`x = <ul>{|a| a}</ul>`), /a function child is a component's/);
	assert.throws(() => reactive(`import pf.Loading\nx = <Loading fallback={<p />}>{|a!, i| a}<li></li></Loading>`), /function child must be its only child/);
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
	assert.equal(reactive(`x = <p>Hi {name} {count!().to_str()}</p>`), `x = Html.element("p", [], [Html.text("Hi "), Html.shown(name), Html.text(" "), Html.hole_of(|| Html.hole(count!().to_str())),])`);
	assert.equal(reactive(`x = <div>{=header}{...rows}</div>`), `x = Html.element("div", [], [Html.shown(header), Html.join(rows),])`);
	assert.equal(reactive(`x = <div>{=if (big) <b>{n}</b> else <i>{m!()}</i>}</div>`), `x = Html.element("div", [], [Html.hole_of(|| Html.hole(if (big) Html.element("b", [], [Html.shown(n),]) else Html.element("i", [], [Html.hole_of(|| Html.hole(m!())),]))),])`, "a hole is computed if anything in it is");
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
	assert.equal(reactive('x = <p title={"${n!()} left"}>{"${n!()} left"}</p>'), 'x = Html.element("p", [Html.attr_of("title", || "${n!()} left"),], [Html.hole_of(|| Html.hole("${n!()} left")),])');
	assert.equal(reactive(`x = <p>{xs.map(|x| f!(x))}</p>`), `x = Html.element("p", [], [Html.hole_of(|| Html.hole(xs.map(|x| f!(x)))),])`);
	assert.equal(reactive(`x = <p>{props.title!()}</p>`), `x = Html.element("p", [], [Html.hole_of(|| Html.hole(props.title!())),])`);
	// But not in a string, a character or a comment, and not `!=` or `!cond`.
	assert.equal(reactive('x = <p title={"Go!"}>{if (a != b) "yes!" else "no"}{if (!done) \'!\' else \'.\'}</p>'), 'x = Html.element("p", [Html.attr("title", "Go!"),], [Html.shown(if (a != b) "yes!" else "no"), Html.shown(if (!done) \'!\' else \'.\'),])');
	// A component in a hole is an effect; so is a provider. Handlers and keys are what they were.
	assert.equal(reactive(`import Card\nx = <div>{=if (big) <Card /> else <></>}</div>`).split("\n")[1], `x = Html.element("div", [], [Html.hole_of(|| Html.hole(if (big) Html.component(|| Card.view!({})) else Html.join([]))),])`);
	assert.equal(reactive(`x = <button on:click={go} key={id}>Go</button>`), `x = Html.element("button", [Html.on("click", go), Html.key(id),], [Html.text("Go"),])`);
	// A prop named with ! is still an accessor; other props are values, as they were.
	assert.equal(reactive(`x = <Heading text!={user.name} level={2} />`), `x = Html.component(|| heading!({ text!: || user.name, level: 2, }))`);
});

test("components: transition, transition:in, transition:out and transition:move are a Transition the element plays, computed if it reads anything", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	assert.equal(
		reactive(`x = <li transition={Transition.fade} transition:in={Transition.fly({ x: 0.0, y: 8.0 })} transition:out={Transition.fade.ms(100)}>Hi</li>`),
		`x = Html.element("li", [Html.transition(Both, Transition.fade), Html.transition(In, Transition.fly({ x: 0.0, y: 8.0 })), Html.transition(Out, Transition.fade.ms(100)),], [Html.text("Hi"),])`,
	);
	assert.equal(reactive(`x = <rect transition:out={Transition.grow(if (bar!().value < 0.0) Top else Bottom)} />`), `x = Html.element("rect", [Html.transition_of(Out, || Transition.grow(if (bar!().value < 0.0) Top else Bottom)),], [])`);
	// How it moves, with the key that makes it the same element in another list.
	assert.equal(reactive(`x = <li key={card.id} transition:move={Transition.glide}>Hi</li>`), `x = Html.element("li", [Html.key(card.id), Html.transition(Move, Transition.glide),], [Html.text("Hi"),])`);
	assert.equal(reactive(`x = <li key={card!().id} transition:move={Transition.glide}>Hi</li>`), `x = Html.element("li", [Html.key_of(|| card!().id), Html.transition(Move, Transition.glide),], [Html.text("Hi"),])`);
	assert.equal(reactive(`x = <li transition:move={if (fast!()) Transition.glide.ms(100) else Transition.glide}>Hi</li>`), `x = Html.element("li", [Html.transition_of(Move, || if (fast!()) Transition.glide.ms(100) else Transition.glide),], [Html.text("Hi"),])`);
	// A component's prop of that name is its own.
	assert.equal(reactive(`x = <Card transition={t} />`), `x = Html.component(|| card!({ transition: t, }))`);
	assert.match(failure(`x = <li transition:fade={Transition.fade}></li>`).reason, /write transition=\{…\} \(both ways\), transition:in=\{…\}, transition:out=\{…\} or transition:move=\{…\}/);
	assert.throws(() => reactive(`x = <li transition="fade"></li>`), /transition needs \{a Transition\}: write transition=\{Transition\.fade\}/);
	assert.throws(() => reactive(`x = <li transition:out></li>`), /transition:out needs \{a Transition\}/);
	assert.throws(() => reactive(`x = <li transition?={on}></li>`), /transition needs \{a Transition\}/);
});

test("components: a doctype, and <script> and <style> in markup, are the platform's raw text", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	assert.equal(reactive(`view! = |{}| <><!doctype html><html><body>{n!()}</body></html></>`), `view! = |{}| Html.join([Html.doctype({}), Html.element("html", [], [Html.element("body", [], [Html.hole_of(|| Html.hole(n!())),]),]),])`);
	assert.equal(reactive(`x = <div><style>p > a { color: red }</style><script>if (a < b) go()</script></div>`), `x = Html.element("div", [], [Html.element("style", [], [Html.source_text("p > a { color: red }"),]), Html.element("script", [], [Html.source_text("if (a < b) go()"),]),])`);
	assert.equal(reactive("x = <div><script>\n\tlet s = `${n}`\n</script></div>"), 'x = Html.element("div", [], [Html.element("script", [], [Html.source_text(Str.join_with(["", \n\t"\\tlet s = `\\${n}`", \n""], "\\n")),]),])', "its lines kept as lines; ${…} in it is text");
	// A component's first <style>, in its block, is still its stylesheet: lifted, never raw text.
	const source = "import pf.Html\n\nCard := [].{\n\tview! = |{}| <p class=\"a\">{n!()}<style>i {}</style></p>\n\n\t<style>.a { color: red }</style>\n}\n";
	const { code, styles } = transpileModule(source, "Card.rocx", { module: "Card" });
	const scope = scopeClass("Card.Card");
	assert.equal(code.split("\n")[3], `\tview! = |{}| Html.element("p", [Html.attr_literal("class", "a ${scope}"),], [Html.hole_of(|| Html.hole(n!())), Html.element("style", [], [Html.source_text("i {}"),]),])`);
	assert.equal(code.split("\n")[5], "", "the stylesheet's line, blank");
	assert.deepEqual(styles, [{ css: `.a.${scope} { color: red }`, line: 6, component: "Card" }]);
	// A computed class keeps the scope class, in the computation.
	const computed = transpileModule("import pf.Html\n\nCard := [].{\n\tview! = |{}| <p class={c!()}></p>\n\t<style>p {}</style>\n}\n", "Card.rocx", { module: "Card" }).code;
	assert.equal(computed.split("\n")[3], `\tview! = |{}| Html.element("p", [Html.attr_of("class", || Str.concat(c!(), " ${scope}")),], [])`);
});

test("components: one runs where it is rendered; a context is named, and provided by its own tag", () => {
	const reactive = (source, options = {}) => transpileModule(source, "Picks.rocx", { module: "Picks", ...options }).code.replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	// A component's call is put off: it runs where it is rendered, so it sees the contexts above
	// that place, as in Solid. A platform's component (`import pf.Loading`) is markup, made now.
	assert.equal(reactive(`import pf.Loading\nimport Tally\nx = <Loading fallback={<p />}><Tally /></Loading>`).split("\n")[2], `x = Loading.view!({ fallback: Html.element("p", [], []), children: [Html.component(|| Tally.view!({})),], })`);
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

test("components: a value prop is a getter (D-039), read where the component reads it; an accessor, a function and children are given as they are", () => {
	const reactive = (source) => transpileModule(source, "Page.rocx", { module: "Page" }).code.split("\n")[1];
	assert.equal(reactive(`import Shows\nx = <p>{=<Shows label={word!()} />}</p>`), `x = Html.element("p", [], [Html.hole_of(|| Html.hole(Html.component(|| Shows.view!({ label: || word!(), })))),])`, "the hole reads nothing: Shows reads label");
	assert.equal(reactive(`import Shows\nx = <Shows label={word!()} size={2} />`), `x = Html.component(|| Shows.view!({ label: || word!(), size: || 2, }))`, "outside a hole, the same");
	assert.equal(reactive(`import Shows\nx = <Shows label!={word!()} save!={save!} pick={|it| pick!(it)} size="2" on>Hi</Shows>`), `x = Html.component(|| Shows.view!({ label!: || word!(), save!: save!, pick: || |it| pick!(it), size: || "2", on: || Bool.True, children: [Html.text("Hi"),], }))`, "an accessor and an effect as they are; a lambda, a string and a flag as getters; children as markup");
});

test("components: a component's value props are getters inside it (D-039): its type, its pattern, and each read where it is written", () => {
	const code = (source) => transpileModule(source, "Page.rocx", { module: "Page" }).code.replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	const shows = code(["Shows := [].{", "\tview! : { label : Str, n : U64 } => Html", "\tview! = |{ label, n }| {", "\t\tfirst = label", "\t\t<p title={label} on:click={|| say!(label)}>{label} {first} {n.to_str()}</p>", "\t}", "}"].join("\n")).split("\n");
	assert.equal(shows[1], "\tview! : { label : () => Str, n : () => U64 } => Html", "its type: getters");
	assert.equal(shows[2], "\tview! = |{ label: label!, n: n! }| {", "its pattern binds the getters");
	assert.equal(shows[3], "\t\tfirst = label!()", "a read in its body: once, as it runs");
	assert.equal(shows[4], `\t\tHtml.element("p", [Html.attr_of("title", || label!()), Html.on("click", || say!(label!())),], [Html.hole_of(|| Html.hole(label!())), Html.text(" "), Html.shown(first), Html.text(" "), Html.hole_of(|| Html.hole(n!().to_str())),])`, "a read in a hole or an attribute is a computation's; a handler's when it runs; what the body read is static");
	const props = code(["Card := [].{", "\tProps := { title : Str, max : U64 ?? 5, pick! : Str => {}, children : List(Html) }", "", "\tview! : Props => Html", "\tview! = |{ title, max, pick!, children }| <div class={title}>{max.to_str()}{...children}</div>", "}"].join("\n")).split("\n");
	assert.equal(props[1], "\tProps := { title : () => Str, max : (() => U64) ?? (|| 5), pick! : Str => {}, children : List(Html) }", "the block's Props: getters, a default as one");
	assert.equal(props[4], `\tview! = |{ title: title!, max: max!, pick!, children }| Html.element("div", [Html.attr_of("class", || title!()),], [Html.hole_of(|| Html.hole(max!().to_str())), Html.join(children),])`);
	const markup = code(["Gate := [].{", "\tProps := { open : Bool, fallback : Html ?? <></>, note : Html ?? <em>{\"none\"}</em>, n : U64 ?? 1 }", "", "\tview! : Props => Html", "\tview! = |{ open, fallback, note, n }| <p>{=if (open) note else fallback}</p>", "}"].join("\n")).split("\n");
	assert.equal(markup[1], `\tProps := { open : () => Bool, fallback : (() => Html) ?? (|| Html.join([])), note : (() => Html) ?? (|| Html.element("em", [], [Html.shown("none"),])), n : (() => U64) ?? (|| 1) }`, "markup in a default, as anywhere");
	const whole = code(["Chart := [].{", "\tview! : { label : Str, data! : () => List(U64) } => Html", "\tview! = |props| {", "\t\tdata! = props.data!", "\t\t<p>{props.label}</p>", "\t}", "}"].join("\n")).split("\n");
	assert.equal(whole[3], "\t\tdata! = props.data!", "an accessor field as it is");
	assert.equal(whole[4], `\t\tHtml.element("p", [], [Html.hole_of(|| Html.hole((props.label)())),])`, "a value field through its getter (in parentheses: `props.label()` would call a method)");
});

test("components: a prop read in a lambda that may be pure is read where that lambda is made (D-039)", () => {
	const line = (body) => transpileModule(["Day := [].{", "\tview! = |{ day, me }| {", `\t\t${body}`, "\t}", "}"].join("\n"), "Page.rocx", { module: "Page" }).code.split("\n")[2];
	assert.equal(line("here! = || plans!().keep_if(|plan| plan.day == day.id)"), "\t\there! = || plans!().keep_if((|day| |plan| plan.day == day.id)(day!()))", "given to keep_if: read when the lambda is made, in here!");
	assert.equal(line("<p>{xs.map(|x| x.concat(me).concat(day)).join(\",\")}</p>"), `\t\tHtml.element("p", [], [Html.hole_of(|| Html.hole(xs.map((|me, day| |x| x.concat(me).concat(day))(me!(), day!())).join(","))),])`, "in a hole, the hole reads them: it is a computation");
	assert.equal(line("fmt = |x| \"${x} ${me}\""), "\t\tfmt = (|me| |x| \"${x} ${me}\")(me!())", "a pure helper in the body: read once, as it is made");
	assert.equal(line("fmt! = |x| \"${x} ${me}\""), "\t\tfmt! = |x| \"${x} ${me!()}\"", "one named as an effect reads it when called");
	assert.equal(line("create_effect!(|| day.id, |id| log!(id, me))"), "\t\tcreate_effect!(|| day!().id, |id| log!(id, me!()))", "an effect's halves");
	assert.equal(line("rows = xs.map(|x| <li on:click={|| pick!(xs.keep_if(|y| y == me))}>{me}</li>)"), `\t\trows = xs.map(|x| Html.element("li", [Html.on("click", || pick!(xs.keep_if((|me_2| |y| y == me_2)(me!())))),], [Html.hole_of(|| Html.hole(me!())),]))`, "markup in a pure lambda reads for itself; a handler there too (a root inside another's run names its own)");
	assert.equal(line("rows = xs.map(|x| (x, me, <b on:click={|| f!(xs.keep_if(|y| y == me))} />))"), `\t\trows = xs.map((|me| |x| (x, me, Html.element("b", [Html.on("click", || f!(xs.keep_if((|me_2| |y| y == me_2)(me!())))),], [])))(me!()))`, "a root inside another's run: its own names, read where it is made");
	assert.equal(line("x = { id: day.id, me }"), "\t\tx = { id: day!().id, me: me!() }", "a record's label is no read; a punned field is");
	assert.equal(line("x = card.me"), "\t\tx = card.me", "a field of something else");
});

test("components: a dev build says where a component's body calls an accessor, for the browser's warning of a read made once (D-052)", () => {
	const lines = (body, dev = true) => transpileModule(["Chart := [].{", "\tview! : { goal : U64, label : Str } => Html", "\tview! = |{ goal, label }| {", ...body.map((line) => `\t\t${line}`), "\t}", "}"].join("\n"), "Ui/Chart.rocx", { module: "Ui/Chart", dev }).code.split("\n").slice(3, 3 + body.length);
	const body = ["(drawn!, set_drawn!) = create_signal!(goal)", "first = drawn!()", "x = { id: label, goal }", "fmt = |x| \"${x} ${label}\"", "kept = untrack!(|| goal)", "n = store.count!()", "<p on:click={|| set_drawn!(goal)}>{label} {drawn!().to_str()}</p>"];
	const [signal, first, record, fmt, kept, field, markup] = lines(body);
	assert.equal(signal, `\t\t(drawn!, set_drawn!) = create_signal!(Html.read_at!("Ui/Chart.rocx:4:41", goal!))`, "a prop read in the body: its getter, said where");
	assert.equal(first, `\t\tfirst = Html.read_at!("Ui/Chart.rocx:5:11", drawn!)`, "an accessor called with nothing");
	assert.equal(record, `\t\tx = { id: Html.read_at!("Ui/Chart.rocx:6:13", label!), goal: Html.read_at!("Ui/Chart.rocx:6:20", goal!) }`, "in a record, punned too");
	assert.equal(fmt, `\t\tfmt = (|label| |x| "\${x} \${label}")(Html.read_at!("Ui/Chart.rocx:7:9", label!))`, "a pure helper's read, made in the body: where the helper is");
	assert.equal(kept, "\t\tkept = untrack!(|| goal!())", "inside untrack!'s lambda: not the body's");
	assert.equal(field, "\t\tn = store.count!()", "a field's accessor, as written");
	assert.equal(markup, `\t\tHtml.element("p", [Html.on("click", || set_drawn!(goal!())),], [Html.hole_of(|| Html.hole(label!())), Html.text(" "), Html.hole_of(|| Html.hole(drawn!().to_str())),])`, "markup's holes and handlers: not the body's");
	assert.deepEqual(lines(body, false).slice(0, 2), ["\t\t(drawn!, set_drawn!) = create_signal!(goal!())", "\t\tfirst = drawn!()"], "any other build: as before");
	const outside = transpileModule("x! = || count!()\ny = count!()", "Page.rocx", { module: "Page", dev: true }).code.split("\n");
	assert.deepEqual(outside.slice(0, 2), ["x! = || count!()", "y = count!()"], "outside a component: as written");
});

test("components: a prop's name can't be bound again in its view (D-039)", () => {
	const fails = (body) => assert.throws(() => transpileModule(["Day := [].{", "\tview! = |{ day }| {", `\t\t${body}`, "\t\tday", "\t}", "}"].join("\n"), "Page.rocx", { module: "Page" }), /day is a prop of this component/);
	fails("day = 1");
	fails("xs.map(|day| day)");
	fails("for day in days {}");
});

test("components: a function of the file's renders with getters when the file only renders it; called too, it keeps values and says so (D-039)", () => {
	const code = (source) => transpileModule(source, "Page.rocx", { module: "Page" });
	const only = code("stats! = |{ n }| <p>{n}</p>\nx = <Stats n={count!()} />").code.split("\n");
	assert.equal(only[0], `stats! = |{ n: n! }| Html.element("p", [], [Html.hole_of(|| Html.hole(n!())),])`);
	assert.equal(only[1], `x = Html.component(|| stats!({ n: || count!(), }))`);
	const both = code("stats! = |{ n }| <p>{n}</p>\nx = <Stats n={count!()} />\ny = stats!({ n: 1 })");
	const lines = both.code.split("\n");
	assert.equal(lines[0], `stats! = |{ n }| Html.element("p", [], [Html.shown(n),])`, "kept as written");
	assert.equal(lines[1], `x = Html.html_of(|| (|props| Html.component(|| stats!(props)))({ n: count!(), }))`, "a hole of its own, made anew");
	assert.equal(both.warnings.length, 1);
	assert.match(both.warnings[0].reason, /<Stats> keeps values for props \(D-039\), since this file also calls stats! directly/);
	assert.equal(both.warnings[0].line, 2);
});

test("components: a pure one (`view`, no `!`) is called where it is written, as a function; it makes the hole it is in no computation", () => {
	const reactive = (source, options = {}) => transpileModule(source, "Page.rocx", { module: "Page", ...options }).code.replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	const views = { Heading: "view", Counter: "view!" };
	assert.equal(reactive(`import Ui/Heading\nx = <Heading id="a">Hi</Heading>`, { views }).split("\n")[1], `x = Heading.view({ id: "a", children: [Html.text("Hi"),], })`, "rocx build says Heading's view is pure");
	assert.equal(reactive(`import Counter\nx = <Counter start={1} />`, { views }).split("\n")[1], `x = Html.component(|| Counter.view!({ start: || 1, }))`, "a view! is put off, given getters");
	assert.equal(reactive(`import Ui/Heading\nx = <Heading id={id!()}>Hi</Heading>`, { views }).split("\n")[1], `x = Html.html_of(|| Heading.view({ id: id!(), children: [Html.text("Hi"),], }))`, "given a value read from what changes, its call is a hole of its own (D-039)");
	assert.equal(reactive(`import Badge\nx = <Badge />`).split("\n")[1], `x = Html.component(|| Badge.view!({}))`, "not known to be pure: view!");
	assert.equal(reactive(`import Ui/Heading\nx = <ul>{...items.map(|item| <li><Heading id={item}>{item}</Heading></li>)}</ul>`, { views }).split("\n")[1], `x = Html.element("ul", [], [Html.join(items.map(|item| Html.element("li", [], [Heading.view({ id: item, children: [Html.shown(item),], }),]))),])`, "static: nothing in the hole is an effect");
	assert.equal(reactive(`Card := [].{\n\tview = |{ title }| <h2>{title}</h2>\n}\nx = <Card title="T" />`).split("\n")[3], `x = Card.view({ title: "T", })`, "this file's own");
	assert.equal(reactive(`card = |{ title }| <h2>{title}</h2>\nx = <p><Card title="T" /></p>`).split("\n")[1], `x = Html.element("p", [], [card({ title: "T", }),])`, "a function of this file's, defined with no !");
	assert.equal(reactive(`stats! = |{ n }| <p>{n}</p>\nx = <Stats n={1} />`).split("\n")[1], `x = Html.component(|| stats!({ n: || 1, }))`, "one defined with ! is put off, given getters");
	assert.equal(reactive(`import pf.Loading\nx = <Loading fallback={<p />}><p /></Loading>`, { views: { Loading: "view" } }).split("\n")[1], `x = Loading.view!({ fallback: Html.element("p", [], []), children: [Html.element("p", [], []),], })`, "a platform's is the platform's");
	assert.deepEqual(viewsDefined("Heading := [].{\n\tview : { id : Str } -> Html\n\tview = |_| x\n}\n\nCounter := [].{\n\tview! = |_| x\n\tview_with = 1\n}\n\nOther := [].{\n\tx = 1\n}\n"), { Heading: "view", Counter: "view!" });
	// A type nested above the view: the view is the outer block's.
	assert.deepEqual(viewsDefined("Icon := [].{\n\tName := [Check, Cross].{\n\t\tis_eq : Name, Name -> Bool\n\t\tis_eq = |a, b| a == b\n\t}\n\n\tview! : { name : Name } => Html\n\tview! = |_| x\n}\n"), { Icon: "view!" });
	assert.deepEqual(viewsDefined("Card := [].{\n\tPart := [Head].{\n\t\tview = |_| y\n\t}\n\n\tview = |_| x\n}\n"), { Card: "view", Part: "view" }, "each its own");
});

test("a hole's if with no else (D-070): nothing shows otherwise, an empty fragment rocx adds; each branch a hole, so text or markup; static when the condition reads nothing that changes; lines stay lines", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	assert.equal(reactive(`x = <div>{if open!() { <p>Open</p> }}</div>`), `x = Html.element("div", [], [Html.branched(|| Ok(if (open!() ) "0" else "1"), || if (open!() ) Html.shown({ Html.element("p", [], [Html.text("Open"),]) }) else Html.empty({})),])`);
	assert.equal(reactive(`x = <div>{if (ready) <i />}</div>`), `x = Html.element("div", [], [(if (ready) Html.shown( Html.element("i", [], [])) else Html.empty({})),])`, "static");
	assert.equal(reactive(`x = <p>{if busy!() { "Saving…" }}</p>`), `x = Html.element("p", [], [Html.branched(|| Ok(if (busy!() ) "0" else "1"), || if (busy!() ) Html.shown({ "Saving…" }) else Html.empty({})),])`, "text");
	assert.equal(reactive(`x = <div>{if (a!()) <i /> else if (b!()) <u />}</div>`), `x = Html.element("div", [], [Html.branched(|| Ok(if (a!()) "0" else if (b!()) "1" else "2"), || if (a!()) Html.shown( Html.element("i", [], []) ) else if (b!()) Html.shown( Html.element("u", [], [])) else Html.empty({})),])`, "else if, and no else");
	const lines = "x = <div>{if open!() {\n\t<p>Open</p>\n}}</div>";
	assert.equal(reactive(lines).split("\n").length, 3);
});

test("<Show>, <Switch> and <Match> are gone (D-070): writing one says what to write instead; a component of the app's own by that name is the app's", () => {
	for (const tag of ["Show", "Switch", "Match"]) {
		assert.throws(() => transpile(`x = <div><${tag} when!={a!()}><p>hi</p></${tag}></div>`, "T.rocx"), (error) => error instanceof RocxError && error.message.includes(`<${tag}> is gone (D-070): write a hole's if or match`), tag);
	}
	assert.match(transpile(`import Show\nx = <Show when={a} />`, "T.rocx"), /Show\.view!\(/, "an imported module\'s");
	assert.throws(() => transpile(`import pf.Show\nx = <div><Show when!={a!()}><p>hi</p></Show></div>`, "T.rocx"), (error) => error instanceof RocxError && error.message.includes("<Show> is gone (D-070)"), "the platform's, imported before D-070");
});

test("a hole's if and match (D-070): one that reads what changes is the part its branch makes, each branch a hole of its own; a match arm's names are getters; text in every branch, or a condition that reads nothing that changes, is a hole as before; lines stay lines", () => {
	const reactive = (source) => transpile(source, "T.rocx").replace(/\n\n# rocx: generated from[^\n]*\n$/, "");
	assert.equal(reactive(`x = <div>{if (count!() > 3) <b>big</b> else <></>}</div>`), `x = Html.element("div", [], [Html.branched(|| Ok(if (count!() > 3) "0" else "1"), || if (count!() > 3) Html.shown( Html.element("b", [], [Html.text("big"),]) ) else Html.shown( Html.join([]))),])`, "the case names the branch; the part made again only when it changes");
	assert.equal(reactive(`x = <div>{if open!() and big { <i /> } else if loading!() { <u /> } else { <></> }}</div>`), `x = Html.element("div", [], [Html.branched(|| Ok(if (open!() and big ) "0" else if (loading!() ) "1" else "2"), || if (open!() and big ) Html.shown({ Html.element("i", [], []) } ) else if (loading!() ) Html.shown({ Html.element("u", [], []) } ) else Html.shown( { Html.join([]) })),])`, "else if, and blocks");
	assert.equal(reactive(`x = <p>{if (n!() > 1) "items" else "item"}</p>`), `x = Html.element("p", [], [Html.hole_of(|| Html.hole(if (n!() > 1) "items" else "item")),])`, "text in every branch: a text hole, patched");
	assert.equal(reactive(`x = <div>{if (ready) <i /> else <u />}</div>`), `x = Html.element("div", [], [Html.shown(if (ready) Html.element("i", [], []) else Html.element("u", [], [])),])`, "a condition that reads nothing that changes: static");
	const arms = reactive(`x = <div>{match tab!() { Home => <p>home</p>, Other(name) => <p>{name}</p> }}</div>`);
	assert.ok(arms.startsWith(`x = Html.element("div", [], [Html.branched(|| Ok(match  tab!()  { Home => "0", Other(_) => "1" }), || match  tab!()  {Home => Html.shown( Html.element("p", [], [Html.text("home"),])), Other(_) => (|name!| `), arms);
	assert.ok(arms.includes(`Html.hole_of(|| Html.hole(name!()))`), "the arm's name, read through its getter where the arm reads it");
	assert.ok(arms.includes(`(|| match  tab!()  { Other(name) => name, _ => Html.unmatched!("name is read after its match arm stopped matching") })`), "the getter: the arm's pattern again, binding that name alone");
	const guarded = reactive(`x = <div>{match pair!() { (a, _) if a > 1 => <p>{a}</p>, _ => <></> }}</div>`);
	assert.ok(guarded.includes(`Ok(match  pair!()  { (a, _) if  a > 1  => "0", _ => "1" })`), "a guard is the case's too, with the names it reads");
	assert.ok(guarded.includes(`_ => Html.shown( Html.join([]) ) }`), "a catch-all arm");
	const lines = `x = <div>{match user!() {\n\tOk({ name, age: years }) if years > 17 =>\n\t\t<p>{name}</p>\n\tErr(_) => <></>\n}}</div>`;
	assert.equal(reactive(lines).split("\n").length, lines.split("\n").length, "as many lines");
	assert.match(reactive(lines).split("\n")[2], /Html\.element\("p"/, "the arm's markup on its line");
	assert.match(reactive(lines).split("\n")[1], /^\tOk\(\{ name: _, age: years \}\) if {2}years > 17 {2}=> /, "the arm's pattern on its line, indented as written, binding only what its guard reads");
});

test("a hole's .map (D-071): a list that changes is its rows, by the root's key, its names getters; by position with .map_with_index and key={i}; a list that doesn't change is made once, as before", () => {
	const line = (source) => transpile(source, "T.rocx").split("\n")[0];
	assert.equal(line(`x = <ul>{...posts!().map(|post| <li key={post.id}>{post.title}</li>)}</ul>`), `x = Html.element("ul", [], [Html.rows!(|| posts!(), |post| post.id, |post!, _| Html.template("T:0",  Html.element("li", [Html.key(post!().id),], [Html.hole_of(|| Html.hole(post!().title)),]))),])`);
	assert.equal(line(`x = <ul>{...names!().map_with_index(|name, i| <li key={i}>{i.to_str()} {name}</li>)}</ul>`), `x = Html.element("ul", [], [Html.rows_at!(|| names!(), |name!, i| Html.template("T:0",  Html.element("li", [Html.key(i),], [Html.shown(i.to_str()), Html.text(" "), Html.hole_of(|| Html.hole(name!())),]))),])`);
	// A component's key is the row's, never a prop.
	assert.match(line(`x = <ul>{...xs!().map(|x| <Row key={x.id} label={x.name} />)}</ul>`), /Html\.rows!\(\|\| xs!\(\), \|x\| x\.id, \|x!, _\| .*\{ label: x!\(\)\.name, \}/);
	assert.equal(line(`x = <ul>{...names.map(|name| <li>{name}</li>)}</ul>`), `x = Html.element("ul", [], [Html.join(names.map(|name| Html.element("li", [], [Html.shown(name),]))),])`);
	// Roc's values have no identity: a row says its key.
	assert.throws(() => line(`x = <ul>{...xs!().map(|a| <li>{a}</li>)}</ul>`), /T\.rocx:1:27: a list that changes is a row per key, kept as the list changes/);
	assert.throws(() => line(`x = <ul>{...xs!().map_with_index(|a, i| <li key={a.id + i}>{a}</li>)}</ul>`), /a key made from the index is a row per position: write key=\{i\} alone/);
	assert.throws(() => line(`import pf.For\nx = <For each!={xs!()} keyed={|a| a}>{|a!, _| <li />}</For>`), /<For> is gone \(D-071\)/);
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
		'\t\t\t\tHtml.element("p", [], [Html.text("Prose, "), Code.view({ code: "x", }), Html.text(", "), Html.hole_of(|| Html.hole(count!().to_str())),]), Html.text(" "),',
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

test("<NoHydration>: a name only what is inside used is rewritten in the browser's copy where it is bound, so the compiler doesn't warn (D-044)", () => {
	const browserOf = (source) => transpileModule(source, "P.rocx", { module: "P", client: true }).code;
	// A field of the view's record pattern: `params: _` (its getter's binding, `params: params!`, D-039).
	const page = browserOf("import pf.Html\n\nview! = |{ params }|\n\t<main>\n\t\t<NoHydration><p>{params.lang}</p></NoHydration>\n\t</main>\n");
	assert.match(page, /^view! = \|\{ params: _ \}\|$/m);
	// Two fields, one still used: only the other.
	const error = browserOf("import pf.Html\n\nview! = |{ status, problem }|\n\t<main>\n\t\t<h1>{status.to_str()}</h1>\n\t\t<NoHydration><p>{problem}</p></NoHydration>\n\t</main>\n");
	assert.match(error, /^view! = \|\{ status: status!, problem: _ \}\|$/m);
	// A plain parameter: `_props`.
	assert.match(browserOf("import pf.Html\n\nview! = |props|\n\t<main><NoHydration><p>{props.text}</p></NoHydration></main>\n"), /^view! = \|_props\|$/m);
	// A local definition: `_lang = …`; what it reads (`params`) is still used, so it stays.
	const local = browserOf("import pf.Html\n\nview! = |{ params }| {\n\tlang = params.lang\n\t<main><NoHydration><p>{lang}</p></NoHydration></main>\n}\n");
	assert.match(local, /^\t_lang = params!\(\)\.lang$/m);
	assert.match(local, /^view! = \|\{ params: params! \}\| \{$/m);
	// What the browser's copy still uses, and a member of a block (another module may read it), are left as they are.
	const kept = browserOf("import pf.Html\n\nview! = |{ name }|\n\t<main><p>{name}</p><NoHydration><p>{name}</p></NoHydration></main>\n");
	assert.match(kept, /^view! = \|\{ name: name! \}\|$/m);
	const member = browserOf("import pf.Html\n\nCard := [].{\n\ttitle = \"Hi\"\n\n\tview! : {} => Html\n\tview! = |{}| <main><NoHydration><p>{title}</p></NoHydration></main>\n}\n");
	assert.match(member, /^\ttitle = "Hi"$/m);
	// A word in a string's text or a comment is no name: left as it is, though the server's copy has it twice.
	const text = browserOf("import pf.Html\n\nview! = |{}| {\n\titem = { label: \"Comments, entities, raw ${\"text\"}\", sign: '\"' } # entities, too\n\t<main><p>{item.label}</p><NoHydration><p>{\"entities, \"}</p></NoHydration></main>\n}\n");
	assert.match(text, /^\titem = \{ label: "Comments, entities, raw \$\{"text"\}", sign: '"' \} # entities, too$/m);
	// A file with no <NoHydration> is untouched (and so is the server's copy).
	assert.match(transpileModule("import pf.Html\n\nview! = |{ params }|\n\t<main><NoHydration><p>{params.lang}</p></NoHydration></main>\n", "P.rocx", { module: "P" }).code, /^view! = \|\{ params: params! \}\|$/m);
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
	assert.match(refused("<p>{=if (open!()) <button on:click={go!}>Go</button> else <></>}</p>").reason, /^on:click is inside <NoHydration>/, "markup in a hole inside it too");
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
	assert.equal(roc(`x = <p style:color={c} />`), `x = Html.element("p", [Html.style_var("color", c),], [])`, "a property of the style, from data");
	assert.match(failure(`x = <p style:background:url={c} />`).reason, /a style property's name is letters and dashes/);
	assert.match(failure(`x = <a class:card-link>x</a>`).reason, /class:card-link needs \{a Bool\}/, "not a literal attribute");
	assert.match(failure(`x = <a style:--x />`).reason, /style:--x needs \{a value\}/);
	assert.equal(roc(`x = <p style:--size={s} />`), `x = Html.element("p", [Html.style_var("--size", s),], [])`);
	assert.equal(roc(`x = <a rel??={r} />`), `x = Html.element("a", [Html.optional("rel", r),], [])`);
	assert.match(failure(`x = <a rel??="x" />`).reason, /always there/);
});

test("a channel's route file (channel! and its hooks, plain Roc) is left as it is, in both copies (its middleware is its directory's, D-103)", () => {
	const source = [
		"import pf.Server",
		"import pf.Endpoint",
		"import pf.Channel",
		"",
		"## An org's news.",
		"channel! : { request : Server.Request, params : { org : Str }, context : { org : Str, name : Str } } => Try(Channel(Str, { title : Str }, []), Endpoint.Refusal)",
		"channel! = |{ params, context, .. }| if context.org == params.org Ok(Channel.allow(context.name)) else Err(Forbidden)",
		"",
		"on_open! = |{ who, .. }| [{ title: \"welcome, ${who}\" }]",
		"",
	].join("\n");
	const file = "routes/org/[org]/news/+server.roc";
	const server = transpileModule(source, file, { module: "Generated/OrgOrgNewsServer" }).code;
	assert.match(server, /^channel! = \|\{ params, context, \.\. \}\| if context\.org == params\.org Ok\(Channel\.allow\(context\.name\)\) else Err\(Forbidden\)$/m, "the check, as written");
	const browser = transpileModule(source, file, { module: "Generated/OrgOrgNewsServer", client: true, route: true }).code;
	assert.match(browser, /^channel! = /m, "the check, as written: nothing in the browser calls it");
	assert.match(browser, /^on_open! = \|\{ who, \.\. \}\| \[\{ title: "welcome, \$\{who\}" \}\]$/m, "the hooks, as written: nothing in the browser calls them");
});
