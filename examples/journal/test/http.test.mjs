// The journal over HTTP, as a browser and other programs ask it: each language's pages, the
// switcher, the 404s, the feeds and the sitemap (well-formed XML), the JSON API and its OpenAPI,
// search without JavaScript, and reactions (counted once, rate limited, refused when wrong).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { within } from "../../../packages/testing/index.mjs";
import { build, start, wellFormed } from "./journal.mjs";

let app;
before(async () => {
	app = await start(await build());
});
after(() => app?.stop());

/** The page's `<html lang>`. */
const langOf = (page) => /<html[^>]* lang="([^"]+)"/.exec(page.text)?.[1];

test("/ sends a reader to the journal in their browser's language", async () => {
	const polish = await app.client().get("/", { "accept-language": "pl-PL,pl;q=0.9,en;q=0.5" });
	assert.equal(polish.status, 303);
	assert.equal(polish.location, "/pl");
	const other = await app.client().get("/", { "accept-language": "de-DE,de" });
	assert.equal(other.location, "/en");
});

test("each language's index: its latest writing, newest first, four to a page", async () => {
	const en = await app.client().get("/en");
	assert.equal(en.status, 200);
	assert.equal(langOf(en), "en");
	en.dom.getByRole("heading", { level: 1, name: "Latest writing" });
	const titles = en.dom.getAllByRole("heading", { level: 2 }).map((heading) => heading.text);
	assert.deepEqual(titles, ["How this journal is made", "A field guide to rain sounds", "Reading JSON by hand", "Truing a bicycle wheel at the kitchen table"]);
	assert.equal(en.dom.getByRole("link", { name: "Page 1 of 3" }).attr("aria-current"), "page");

	const pl = await app.client().get("/pl");
	assert.equal(langOf(pl), "pl");
	pl.dom.getByRole("heading", { level: 1, name: "Najnowsze teksty" });
	assert.equal(pl.dom.getAllByRole("heading", { level: 2 })[0].text, "Niedziela z pierogami");
	pl.dom.getByRole("link", { name: "Starsze wpisy →" });

	const last = await app.client().get("/en/page/3");
	assert.equal(last.status, 200);
	assert.deepEqual(
		last.dom.getAllByRole("heading", { level: 2 }).map((heading) => heading.text),
		["Notes on slow bread", "A garden in winter"],
	);
	assert.equal((await app.client().get("/en/page/4")).status, 404);
});

test("dates, numbers and plurals are written as each language writes them", async () => {
	const en = await app.client().get("/en/posts/slow-bread");
	assert.match(en.text, /February 14, 2026/);
	assert.match(en.text, /3 min read/);
	const pl = await app.client().get("/pl/posts/slow-bread");
	assert.match(pl.text, /14 lutego 2026/);
	assert.match(pl.text, /2 minuty czytania/);
	// Polish has three plurals: 2 wpisy, 5 wpisów (and 1 wpis).
	assert.match((await app.client().get("/pl/tags/kuchnia")).text, /2 wpisy/);
	assert.match((await app.client().get("/pl/authors/hanna-wierzba")).text, /4 wpisy/);
	assert.match((await app.client().get("/en/authors/theo-marsh")).text, /4 posts/);
});

test("a post: its table of contents, reading time, notes, translation, and the posts around it", async () => {
	const page = await app.client().get("/en/posts/slow-bread");
	assert.equal(page.status, 200);
	const { dom } = page;
	dom.getByRole("heading", { level: 1, name: "Notes on slow bread" });
	assert.match(page.text, /<title data-rocx>Notes on slow bread · Acme Journal<\/title>/);
	const contents = within(dom.getByRole("navigation", { name: "Contents" }));
	assert.deepEqual(
		contents.getAllByRole("link").map((link) => link.attr("href")),
		["#time-does-the-kneading", "#the-numbers-i-actually-use", "#what-goes-wrong", "#baking-it"],
	);
	// Footnotes: numbered references, and notes that link back to them.
	assert.equal(dom.getByRole("link", { name: "1" }).attr("href"), "#fn-cold");
	assert.equal(dom.getByRole("link", { name: "1" }).attr("id"), "fnref-cold");
	const notes = within(dom.getByRole("region", { name: "Notes" }));
	assert.equal(notes.getAllByRole("listitem").length, 2);
	assert.equal(notes.getAllByRole("link", { name: "Back to the text" })[0].attr("href"), "#fnref-cold");
	// A table and the cover, described.
	assert.equal(dom.getAllByRole("table").length, 2);
	dom.getByRole("img", { name: /A round loaf on a wooden board/ });
	// Its translation, and the newer and older posts.
	const polish = dom.getByRole("link", { name: "Czytaj po polsku →" });
	assert.equal(polish.attr("href"), "/pl/posts/slow-bread");
	assert.equal(polish.attr("hreflang"), "pl");
	const around = within(dom.getByRole("navigation", { name: "More from the journal" }));
	assert.equal(around.getByRole("link", { name: /In praise of the pocket notebook/ }).attr("href"), "/en/posts/pocket-notebook");
	assert.equal(around.getByRole("link", { name: /A garden in winter/ }).attr("href"), "/en/posts/winter-garden");
	// Code blocks keep their language, and an image its caption.
	const shell = await app.client().get("/en/posts/small-shell-scripts");
	assert.equal(shell.dom.getAllByLabelText("Code: sh").length, 3);
	const tides = await app.client().get("/en/posts/reading-a-tide-table");
	assert.equal(tides.dom.getByRole("img", { name: /A curve of the water's height/ }).attr("loading"), "lazy");
	assert.match(tides.text, /One day of tides: two highs and two lows/);
});

test("the language switcher keeps a reader on the post when it has a translation", async () => {
	const switcher = async (path) => within((await app.client().get(path)).dom.getByRole("navigation", { name: /Language|Język/ }));
	assert.equal((await switcher("/en/posts/night-trains")).getByRole("link", { name: "Polski" }).attr("href"), "/pl/posts/night-trains");
	assert.equal((await switcher("/pl/posts/night-trains")).getByRole("link", { name: "English" }).attr("href"), "/en/posts/night-trains");
	// No Polish rain sounds, no English pierogi: the other language's front page instead.
	assert.equal((await switcher("/en/posts/rain-sounds")).getByRole("link", { name: "Polski" }).attr("href"), "/pl");
	assert.equal((await switcher("/pl/posts/niedziela-z-pierogami")).getByRole("link", { name: "English" }).attr("href"), "/en");
	// A tag the other language doesn't have: its tags.
	assert.equal((await switcher("/en/tags/bread")).getByRole("link", { name: "Polski" }).attr("href"), "/pl/tags");
	// The head names the real translations alone.
	const head = (await app.client().get("/en/posts/night-trains")).text;
	assert.match(head, /<link rel="alternate" hreflang="pl" href="\/pl\/posts\/night-trains">/);
	assert.doesNotMatch((await app.client().get("/en/posts/rain-sounds")).text, /<link rel="alternate" hreflang="pl"/);
});

test("tag and writer pages", async () => {
	const tag = await app.client().get("/en/tags/code");
	tag.dom.getByRole("heading", { level: 1, name: "Posts tagged “code”" });
	assert.deepEqual(
		tag.dom.getAllByRole("heading", { level: 2 }).map((heading) => heading.text),
		["How this journal is made", "Reading JSON by hand", "Small shell scripts that earn their keep"],
	);
	const tags = await app.client().get("/pl/tags");
	assert.equal(tags.dom.getByRole("link", { name: "#kuchnia" }).attr("href"), "/pl/tags/kuchnia");
	const writer = await app.client().get("/pl/authors/iris-vale");
	writer.dom.getByRole("heading", { level: 1, name: "Teksty: Iris Vale" });
	assert.match(writer.text, /piecze w weekendy/);
});

test("a page that isn't there is a 404, in the language of its address", async () => {
	for (const path of ["/en/posts/no-such-post", "/en/tags/no-such-tag", "/en/authors/nobody", "/nothing/here"]) {
		const page = await app.client().get(path);
		assert.equal(page.status, 404, path);
		page.dom.getByRole("heading", { level: 1, name: "Nothing here" });
	}
	// An English-only post has no Polish page; its reactions show nothing either.
	const polish = await app.client().get("/pl/posts/rain-sounds");
	assert.equal(polish.status, 404);
	polish.dom.getByRole("heading", { level: 1, name: "Nic tu nie ma" });
	assert.equal(polish.dom.queryByRole("region", { name: "Jak się czytało?" }), null);
	// A language the journal isn't written in.
	assert.equal((await app.client().get("/de")).status, 404);
	assert.equal((await app.client().get("/de/search")).status, 404);
});

test("an Atom feed for each language, well-formed, every post whole", async () => {
	const client = app.client();
	for (const [lang, count] of [["en", 10], ["pl", 9]]) {
		const feed = await client.request(`/${lang}/feed.xml`);
		assert.equal(feed.status, 200);
		assert.equal(feed.headers.get("content-type"), "application/atom+xml; charset=utf-8");
		assert.equal(wellFormed(feed.text), "feed");
		assert.equal(feed.text.match(/<entry>/g).length, count);
		assert.match(feed.text, new RegExp(`xml:lang="${lang}"`));
		assert.match(feed.text, new RegExp(`<link rel="self" type="application/atom\\+xml" href="${app.url}/${lang}/feed.xml"/>`));
	}
	const en = (await client.request("/en/feed.xml")).text;
	// The newest first, with whole URLs, and the HTML of the body (its notes too) escaped.
	assert.match(en, new RegExp(`<entry><title>How this journal is made</title><link rel="alternate" type="text/html" href="${app.url}/en/posts/how-this-journal-is-made"/>`));
	assert.match(en, /&lt;section class=&quot;footnotes&quot; data-footnotes&gt;/);
	assert.equal((await client.request("/xx/feed.xml")).status, 404);
});

test("sitemap.xml lists every page with its translations as hreflang alternates", async () => {
	const sitemap = await app.client().request("/sitemap.xml");
	assert.equal(sitemap.status, 200);
	assert.equal(wellFormed(sitemap.text), "urlset");
	const url = (path) => {
		const found = new RegExp(`<url><loc>${app.url}${path}</loc>.*?</url>`).exec(sitemap.text);
		assert.ok(found, `no <url> for ${path}`);
		return found[0];
	};
	const bread = url("/en/posts/slow-bread");
	assert.match(bread, /<lastmod>2026-02-14<\/lastmod>/);
	assert.match(bread, new RegExp(`hreflang="pl" href="${app.url}/pl/posts/slow-bread"`));
	assert.match(bread, new RegExp(`hreflang="x-default" href="${app.url}/en/posts/slow-bread"`));
	assert.doesNotMatch(url("/en/posts/rain-sounds"), /hreflang/);
	url("/pl/page/3");
	url("/pl/tags/kuchnia");
	url("/en/authors/theo-marsh");
});

test("the JSON API: posts by language, tag, writer and search, and one post whole", async () => {
	const client = app.client();
	const all = await client.read("/api/posts");
	assert.equal(all.length, 19);
	const pl = await client.read("/api/posts?lang=pl");
	assert.equal(pl.length, 9);
	const bread = pl.find((post) => post.slug === "slow-bread");
	assert.deepEqual(bread.translations, [{ lang: "en", url: "/en/posts/slow-bread" }]);
	assert.equal(bread.author_name, "Iris Vale");
	assert.equal(bread.url, "/pl/posts/slow-bread");
	assert.deepEqual((await client.read("/api/posts?lang=en&tag=code")).map((post) => post.slug), ["how-this-journal-is-made", "json-by-hand", "small-shell-scripts"]);
	assert.equal((await client.read("/api/posts?author=theo-marsh")).length, 7);
	assert.deepEqual((await client.read("/api/posts?lang=pl&q=plywow")).map((post) => post.title), ["Jak czytać tablicę pływów"]);
	const wrong = await client.request("/api/posts?lang=de", { headers: { accept: "application/json" } });
	assert.equal(wrong.status, 400);

	const post = await client.read("/api/posts/en/night-trains");
	assert.equal(post.post.title, "Night trains, again");
	assert.ok(post.words > 400, `${post.words} words`);
	assert.deepEqual(post.toc.map((heading) => heading.id), ["the-compartment", "the-night", "the-morning", "a-few-practical-notes"]);
	assert.match(post.html, /<h2 id="the-night">The night<\/h2>/);
	assert.match(post.html, /<li id="fn-etiquette">/);
	const missing = await client.request("/api/posts/pl/rain-sounds", { headers: { accept: "application/json" } });
	assert.equal(missing.status, 404);
});

test("OpenAPI: the document and Scalar's page, opted in through App.program", async () => {
	const client = app.client();
	const document = await client.read("/openapi.json");
	assert.equal(document.openapi, "3.2.0");
	assert.deepEqual(Object.keys(document.paths).sort(), ["/api/posts", "/api/posts/{lang}/{slug}", "/api/posts/{lang}/{slug}/reactions"]);
	const react = document.paths["/api/posts/{lang}/{slug}/reactions"].post;
	assert.match(react.description, /A reader's reaction/);
	assert.deepEqual(react.requestBody.content["application/json"].schema.required, ["kind", "on"]);
	const page = await client.request("/openapi.html");
	assert.equal(page.status, 200);
	assert.match(page.text, /@scalar\/api-reference/);
	// The page loads Scalar from jsDelivr, so guard's CSP is on every other answer but not this one.
	assert.equal(page.headers.get("content-security-policy"), null);
	assert.match((await client.get("/en")).headers.get("content-security-policy"), /script-src 'self' 'wasm-unsafe-eval'/);
});

test("search without JavaScript: a plain form, answered by the server", async () => {
	const page = await app.client().get("/en/search?q=tide+table");
	assert.equal(page.status, 200);
	assert.equal(page.dom.getByLabelText("Search titles and tags").attr("value"), "tide table");
	assert.match(page.text, /1 post matches “tide table”\./);
	assert.deepEqual(page.dom.getAllByRole("heading", { level: 2 }).map((heading) => heading.text), ["How to read a tide table"]);
	const polish = await app.client().get("/pl/search?q=ogr%C3%B3d");
	assert.deepEqual(polish.dom.getAllByRole("heading", { level: 2 }).map((heading) => heading.text), ["Ogród zimą"]);
});

test("reactions: counted once per reader, taken back, refused when wrong", async () => {
	const reader = app.client();
	const page = await reader.get("/en/posts/winter-garden");
	assert.match(reader.cookies.get("reader") ?? "", /^r\d+$/, "a page gives the browser a reader cookie");
	page.dom.getByRole("region", { name: "Did this one land?" });
	const url = "/api/posts/en/winter-garden/reactions";
	const before = await reader.read(url);
	const claps = (tally) => tally.counts.find((each) => each.kind === "clap").count;
	assert.deepEqual(before.mine, []);

	const given = (await reader.json(url, { kind: "clap", on: "true" })).json();
	assert.equal(claps(given), claps(before) + 1);
	assert.deepEqual(given.mine, ["clap"]);
	// Given again: no change. The Polish page counts the same post.
	assert.equal(claps((await reader.json(url, { kind: "clap", on: "true" })).json()), claps(before) + 1);
	assert.equal(claps(await reader.read("/api/posts/pl/winter-garden/reactions")), claps(before) + 1);
	// Another reader sees the count, but not as theirs.
	const other = app.client();
	await other.get("/en/posts/winter-garden");
	const seen = await other.read(url);
	assert.equal(claps(seen), claps(before) + 1);
	assert.deepEqual(seen.mine, []);
	// Taken back.
	const taken = (await reader.json(url, { kind: "clap", on: "false" })).json();
	assert.equal(claps(taken), claps(before));
	assert.deepEqual(taken.mine, []);

	const refused = async (client, path, body) => {
		const answer = await client.json(path, body);
		return [answer.status, answer.text];
	};
	assert.deepEqual((await refused(reader, url, { kind: "boo", on: "true" }))[0], 400);
	assert.deepEqual((await refused(reader, url, { kind: "clap", on: "maybe" }))[0], 400);
	assert.deepEqual((await refused(reader, "/api/posts/pl/rain-sounds/reactions", { kind: "clap", on: "true" }))[0], 404);
	const stranger = await refused(app.client(), url, { kind: "clap", on: "true" });
	assert.equal(stranger[0], 403);
	assert.match(stranger[1], /reader cookie/);
});

test("reactions without JavaScript: each button is a form that posts and comes back", async () => {
	const reader = app.client();
	const page = await reader.get("/en/posts/json-by-hand");
	const before = await reader.read("/api/posts/en/json-by-hand/reactions");
	const idea = page.dom.getByRole("button", { name: /Made me think/ });
	assert.equal(idea.attr("aria-pressed"), "false");
	const posted = await reader.post("/api/posts/en/json-by-hand/reactions", { kind: "idea", on: "true" });
	assert.equal(posted.status, 303);
	assert.match(posted.location, /\/en\/posts\/json-by-hand$/);
	const back = await posted.follow();
	assert.equal(back.dom.getByRole("button", { name: /Made me think/ }).attr("aria-pressed"), "true");
	const after = await reader.read("/api/posts/en/json-by-hand/reactions");
	const ideas = (tally) => tally.counts.find((each) => each.kind === "idea").count;
	assert.equal(ideas(after), ideas(before) + 1);
});

test("reactions are rate limited by guard: 20 a minute from each reader", async () => {
	const reader = app.client();
	await reader.get("/en/posts/truing-a-wheel");
	const url = "/api/posts/en/truing-a-wheel/reactions";
	const statuses = [];
	for (let i = 0; i < 20; i++) statuses.push((await reader.json(url, { kind: "smile", on: i % 2 === 0 ? "true" : "false" })).status);
	assert.deepEqual(statuses, Array(20).fill(200));
	const limited = await reader.json(url, { kind: "smile", on: "true" });
	assert.equal(limited.status, 429);
	assert.ok(Number(limited.headers.get("retry-after")) > 0);
	assert.equal(limited.headers.get("ratelimit-policy"), "20;w=60");
	// Reading isn't limited, and another reader has a limit of their own.
	assert.equal((await reader.request(url, { headers: { accept: "application/json" } })).status, 200);
	const other = app.client();
	await other.get("/en/posts/truing-a-wheel");
	assert.equal((await other.json(url, { kind: "smile", on: "true" })).status, 200);
});
