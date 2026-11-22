// The journal's two islands in a real browser (Chromium's headless shell), each page hydrated
// strictly: search filtering as you type, and a reaction shown at once, kept by the server, and
// taken back. Skipped when there is no Chromium.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launchBrowser } from "../../../packages/testing/index.mjs";
import { build, start } from "./journal.mjs";

let app;
let browser;
before(async () => {
	app = await start(await build());
	browser = await launchBrowser();
});
after(async () => {
	await browser?.close();
	await app?.stop();
});

/** The titles the page lists now. */
const titles = async (tab) => (await tab.queryAllByRole("heading", { level: 2 })).map((heading) => heading.text);

test("search filters titles and tags as you type, asking the server nothing", async (t) => {
	if (!browser) return t.skip("no Chromium (see packages/testing/README.md)");
	const tab = await browser.open(`${app.url}/en/search`);
	await tab.findByText("All 10 posts in the journal");
	const field = await tab.getByLabelText("Search titles and tags");

	await field.type("tide");
	await tab.findByText("1 post matches “tide”.");
	assert.deepEqual(await titles(tab), ["How to read a tide table"]);
	assert.deepEqual((await tab.dom()).getAllByText("tide").map((mark) => mark.tag), ["mark"]);

	// A tag matches too: three posts are tagged code, none has it in its title.
	await field.fill("code");
	await tab.findByText("3 posts match “code”.");
	assert.deepEqual(await titles(tab), ["How this journal is made", "Reading JSON by hand", "Small shell scripts that earn their keep"]);

	await field.fill("kite");
	await tab.findByText("Nothing matches “kite”.");
	assert.deepEqual(await titles(tab), []);

	// The posts came with the page: typing fetched nothing.
	assert.ok(!(await tab.requested()).some((path) => path.startsWith("/api/")), "typing asked the server");
	assert.deepEqual(tab.errors, []);

	// Polish, typed without its marks.
	const polish = await browser.open(`${app.url}/pl/search`);
	await (await polish.getByLabelText("Szukaj w tytułach i tagach")).type("plywow");
	await polish.findByText("1 wpis pasuje do „plywow”.");
	assert.deepEqual(await titles(polish), ["Jak czytać tablicę pływów"]);
	assert.deepEqual(polish.errors, []);
});

test("a reaction shows at once, is kept by the server, and can be taken back", async (t) => {
	if (!browser) return t.skip("no Chromium (see packages/testing/README.md)");
	const url = `${app.url}/en/posts/night-trains`;
	const tab = await browser.open(url);
	const applause = () => tab.findByRole("button", { name: /^Applause \d+$/ });
	const count = (button) => Number(/(\d+)$/.exec(button.name)[1]);
	const before = await applause();
	const start = count(before);
	assert.equal(before.attr("aria-pressed"), "false");

	await before.click();
	const given = await tab.findByRole("button", { name: `Applause ${start + 1}` });
	assert.equal(given.attr("aria-pressed"), "true");

	// The server has it: once the page has read the counts again, a reload shows it too (the
	// browser keeps the reader cookie the first page gave it).
	await tab.waitFor(async () => (await tab.requested()).filter((path) => path === "/api/posts/en/night-trains/reactions").length >= 2);
	await tab.goto(url);
	const kept = await tab.findByRole("button", { name: `Applause ${start + 1}` });
	assert.equal(kept.attr("aria-pressed"), "true");

	await kept.click();
	const taken = await tab.findByRole("button", { name: `Applause ${start}` });
	assert.equal(taken.attr("aria-pressed"), "false");
	assert.deepEqual(tab.errors, []);
});
