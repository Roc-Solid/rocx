// Million in a real browser (Chromium's headless shell, hydrating strictly): two tabs on the
// boxes, a box checked in one showing in the other, live, and both counting it; then half a
// million boxes down, the rows there rendered as the grid scrolls, and a box checked there found
// checked by the other tab when it scrolls there too. The page never holds more than the rows
// that show. Skipped where there is no Chromium.
//
//   node --test 'examples/checkboxes/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launchBrowser } from "../../../packages/testing/index.mjs";
import { build, start } from "./million.mjs";

let app;
let browser;
before(async () => {
	browser = await launchBrowser();
	if (browser) app = await start(await build());
});
after(async () => {
	await browser?.close();
	await app?.stop();
});

/** The tab's grid scrolled to the row box `index` is in. */
const scrollTo = (tab, index) => tab.page.eval(`(() => {
	const grid = document.querySelector(".grid");
	const columns = grid.querySelector(".row").querySelectorAll("input").length;
	grid.scrollTop = Math.floor(${index} / columns) * 28;
	return columns;
})()`);

const count = (tab) => tab.page.eval("document.querySelector('.checked').textContent");

test("a box checked in one tab shows in the other, live, and both count it; half a million boxes down, the rows there are rendered as the grid scrolls", async (t) => {
	if (!browser) return t.skip("no Chromium");
	const a = await browser.open(`${app.url}/`);
	const b = await browser.open(`${app.url}/`);
	for (const tab of [a, b]) await tab.findByText("Live");
	assert.equal(await count(a), "0");
	assert.equal(await b.page.eval("document.querySelector('.online').textContent"), "2", "both tabs are online");

	// Box 5, checked in a: at once there, and soon in b.
	await (await a.getByLabelText("Box 5")).click();
	assert.equal(await (await a.getByLabelText("Box 5")).checked(), true);
	await a.page.wait("document.querySelector('.checked').textContent === '1'");
	await b.page.wait(`document.querySelector('[aria-label="Box 5"]').checked === true`);
	await b.page.wait("document.querySelector('.checked').textContent === '1'");

	// Half a million down in a: its rows are made as the grid gets there, and only those.
	const columns = await scrollTo(a, 500_000);
	assert.ok(columns >= 8 && columns <= 64, `${columns} boxes a row`);
	const far = await a.findByLabelText("Box 500,001");
	assert.equal(await far.checked(), false);
	await far.click();
	await b.page.wait("document.querySelector('.checked').textContent === '2'");
	assert.ok((await a.page.eval("document.querySelectorAll('.grid input').length")) < 64 * 60, "only the rows that show, and a few more");
	assert.equal(await a.page.eval(`document.querySelector('[aria-label="Box 1"]')`), null, "the first rows have gone");

	// b scrolls there too: the box is checked, from what b heard while it was elsewhere.
	await scrollTo(b, 500_000);
	await b.findByLabelText("Box 500,001");
	assert.equal(await (await b.getByLabelText("Box 500,001")).checked(), true);

	// Unchecked in b: a's count follows.
	await (await b.getByLabelText("Box 500,001")).click();
	await a.page.wait("document.querySelector('.checked').textContent === '1'");

	for (const tab of [a, b]) {
		assert.deepEqual(tab.errors, []);
		assert.deepEqual(tab.console, []);
	}
});
