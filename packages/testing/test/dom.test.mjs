// dom.mjs: HTML parsed, and found in by role and name, text, label and test id, as Dom.roc finds
// it. The page is Dom.roc's sample, and each answer here is one of its expects.
import { test } from "node:test";
import assert from "node:assert/strict";
import { QueryError, decode, normalize, parse, roles, screen, serialize, within } from "../dom.mjs";

const SAMPLE = [
	'<!doctype html><html lang="en"><head><title>Groceries &middot; Shop</title><style>p > a { color: red }</style></head>',
	'<body><header><nav aria-label="Main"><a href="/">Home</a> <a href="/about" class="nav current">About</a></nav></header>',
	'<main><h1>Groceries</h1><!--loading--><p data-testid="total">Total: <b>3</b></p><!--/loading-->',
	'<ul aria-label="List"><li>Milk</li><li class="done">Eggs &amp; ham</li><li hidden>Gone</li></ul>',
	'<form><label for="item">New item</label><input id="item" name="item" placeholder="What?">',
	'<label><input type="checkbox" checked> Urgent</label>',
	'<input type="submit" value="Add"><button type="button" aria-label="Clear all">&times;</button>',
	'<button><img src="/x.svg" alt="Remove"></button><textarea aria-labelledby="note-label">a &lt;b&gt;</textarea><span id="note-label">Note</span></form>',
	"<article><header><h2>Recipe</h2></header><table><tr><th>Name</th></tr><tr><td>Bread</td></tr></table></article>",
	'<div aria-hidden="true"><button>Hidden</button></div><div style="display: none"><p>Not shown</p></div>',
	"<script>if (a < b && c > d) { done() }</script><p>Tom &amp; &#39;Jerry&#39; &#x2014;&nbsp; &lt;b&gt; &bogus; & more</p></main>",
	"<footer><p>Made with Roc</p></footer></body></html>",
].join("");

const page = screen(SAMPLE);

test("dom: roles and their names, as Dom.roc's sample has them", () => {
	assert.throws(() => page.getByRole("heading"), new QueryError("2 elements are a heading"));
	assert.deepEqual(page.getAllByRole("heading").map((node) => node.text), ["Groceries", "Recipe"]);
	assert.equal(page.getByRole("heading", { name: "Recipe" }).text, "Recipe");
	assert.equal(page.getByRole("heading", { name: /^Groc/ }).tag, "h1");
	assert.equal(page.getByRole("heading", { level: 2 }).text, "Recipe");
	assert.equal(page.queryByRole("heading", { level: 3 }), null);
	assert.throws(() => page.getByRole("heading", { level: 3, name: "Recipe" }), /^QueryError: nothing is a heading at level 3 named "Recipe"; the headings here: "Groceries", "Recipe"$/);
	assert.deepEqual(page.getAllByRole("link").map((node) => node.text), ["Home", "About"]);
	const about = page.getByRole("link", { name: "About" });
	assert.equal(about.attr("href"), "/about");
	assert.ok(about.hasClass("current") && !about.hasClass("cur"));
	assert.deepEqual(page.getAllByRole("listitem").map((node) => node.text), ["Milk", "Eggs & ham"]);
	assert.equal(within(page.getByRole("list", { name: "List" })).getAllByRole("listitem").length, 2);
	assert.ok(page.queryByRole("navigation", { name: "Main" }));
	assert.equal(page.getAllByRole("banner").length, 1, "the article's header isn't the page's banner");
	assert.equal(page.getAllByRole("contentinfo").length, 1);
	assert.ok(page.getByRole("textbox", { name: "New item" }));
	assert.equal(page.getByRole("checkbox", { name: "Urgent" }).attr("checked"), "");
	for (const name of ["Add", "Clear all", "Remove"]) assert.ok(page.getByRole("button", { name }), name);
	assert.ok(page.getByRole("textbox", { name: "Note" }));
	assert.deepEqual(page.getAllByRole("cell").map((node) => node.text), ["Bread"]);
	assert.deepEqual(page.getAllByRole("columnheader").map((node) => node.text), ["Name"]);
	assert.deepEqual(roles(page.scope).slice(0, 3), [
		{ role: "banner", name: "" },
		{ role: "navigation", name: "Main" },
		{ role: "link", name: "Home" },
	]);
});

test("dom: what a reader can't see isn't found by role, text or label", () => {
	assert.equal(page.queryByRole("button", { name: "Hidden" }), null);
	assert.ok(page.queryByRole("button", { name: "Hidden", hidden: true }), "unless asked");
	assert.equal(page.queryByText("Not shown"), null);
	assert.equal(page.queryByText("Gone"), null);
	assert.equal(page.queryByText("Groceries · Shop"), null, "the <title> is in the <head>");
	assert.equal(page.queryByText("if (a < b && c > d) { done() }"), null, "a script's text");
});

test("dom: text, labels and test ids", () => {
	assert.equal(page.getByTestId("total").text, "Total: 3");
	assert.equal(page.getByText("Total:").text, "Total: 3", "an element's own text");
	assert.equal(page.getByText("Tom & 'Jerry' — <b> &bogus; & more").tag, "p");
	assert.equal(page.getByText(/^Made with/).text, "Made with Roc");
	assert.equal(page.getByLabelText("New item").attr("name"), "item");
	assert.equal(page.getByLabelText("Urgent").tag, "input");
	assert.equal(page.getByLabelText("Note").text, "a <b>");
	assert.equal(page.getByLabelText("Clear all").tag, "button", "an aria-label labels too");
});

test("dom: a query that finds nothing says what there is instead", () => {
	assert.throws(() => page.getByRole("button", { name: "Save" }), new QueryError('nothing is a button named "Save"; the buttons here: "Add", "Clear all", "Remove"'));
	assert.throws(() => page.getByRole("tab", { name: "One" }), /^QueryError: nothing is a tab named "One"; the roles here: banner, navigation, link, link, main, heading,/);
	assert.throws(() => page.getByLabelText("Name"), new QueryError('nothing is a control labelled "Name"; the labels here: "New item", "Urgent"'));
	assert.throws(() => page.getByTestId("none"), new QueryError('nothing is an element with data-testid="none"'));
	assert.throws(() => page.getAllByRole("tab"), /^QueryError: nothing is a tab; the roles here:/);
	assert.deepEqual(page.queryAllByRole("tab"), []);
	assert.equal(page.queryByTestId("none"), null);
});

test("dom: the parser's edges, as Dom.roc's", () => {
	assert.equal(parse("a <b>bold</b> <i>c</B> d").text, "a bold c d");
	assert.equal(parse("<p>1 < 2 and 3 > 2</p>").text, "1 < 2 and 3 > 2");
	const div = within(parse("<div title=bare data-x = 'single \"q\"' hidden></div>")).scope.elements[0];
	assert.deepEqual([div.attr("title"), div.attr("data-x"), div.attr("hidden"), div.attr("nope")], ["bare", 'single "q"', "", null]);
	assert.equal(parse("<br/><img src=x /><p>after</p>").elements.map((node) => node.tag).join(), "br,img,p");
	assert.equal(parse("<p>&#128512; &#xE9;&eacute;</p>").text, "😀 é&eacute;");
	assert.equal(parse("<style>a{}</style><p>x</p><!-- note <p>not</p> -->").elements.length, 2);
	assert.equal(parse("").text, "");
	assert.equal(parse("<").text, "<");
	assert.equal(parse('<P CLASS="A">Up</P>').elements[0].attr("class"), "A");
	assert.equal(decode("&amp;lt; &#0; &#x110000;"), "&lt; &#0; &#x110000;");
	assert.equal(normalize(" a   b\n"), "a b");
});

test("dom: an element's place in the tree, and the tree as HTML again", () => {
	const doc = parse(SAMPLE);
	const about = within(doc).getByRole("link", { name: "About" });
	assert.deepEqual(about.path, [0, 1, 0, 0, 1], "html > body > header > nav > the second a");
	let at = doc;
	for (const index of about.path) at = at.elements[index];
	assert.equal(at, about);
	assert.equal(serialize(parse('<p class="a">x &amp; <b>y</b><br></p><script>a < b</script>')), '<p class="a">x &amp; <b>y</b><br></p><script>a < b</script>');
	assert.equal(String(about), '<a href="/about" class="nav current">About</a>');
});
