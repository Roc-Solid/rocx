// The pomodoro in a real browser (Chromium's headless shell, hydrating strictly): started, the
// title counting down, paused and kept, reset; then a whole focus session gone by (the page's
// clock moved on 25 minutes, as a tab the browser slowed down finds it): the chime and the buzz
// asked for, the session recorded and today's count read again, and the break set up, waiting.
// Skipped where there is no Chromium.
//
//   node --test 'examples/pomodoro/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launchBrowser, until } from "../../../packages/testing/index.mjs";
import { started } from "./app.mjs";

let run;
let browser;
before(async () => {
	browser = await launchBrowser();
	if (browser) run = await started();
});
after(async () => {
	await browser?.close();
	await run?.stop();
});

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

/** The page's clock made movable (`window.skew`), and what the sound and the buzz are asked for kept
 * (`window.asked`) instead of played. */
const rig = `(() => {
	const real = Date.now.bind(Date);
	window.skew = 0;
	Date.now = () => real() + window.skew;
	window.asked = [];
	window.Audio = function (url) { window.asked.push(["sound", url]); return { play: () => Promise.resolve() }; };
	Object.defineProperty(navigator, "vibrate", { configurable: true, value: (pattern) => (window.asked.push(["buzz", pattern]), true) });
	return true;
})()`;

const click = (tab, name) => tab.page.eval(`[...document.querySelectorAll("button")].find((each) => each.textContent.trim() === ${JSON.stringify(name)}).click()`);
const timer = (tab) => tab.page.eval(`document.querySelector('[role="timer"]').getAttribute("aria-label")`);

test("start, the title counting down; pause, the time kept; reset, a whole session again", async (t) => {
	if (!browser) return t.skip("no Chromium");
	const tab = await browser.open(`${run.app.url}/`);
	try {
		await tab.findByText("Start");
		await tab.page.eval(rig);
		await click(tab, "Start");
		await until(async () => /^24:5\d · Focus$/.test(await tab.page.eval("document.title")), { what: "the title counting down" });
		await click(tab, "Pause");
		const kept = await timer(tab);
		assert.match(kept, /^24:5\d left$/);
		await tab.findByText("Start");
		await sleep(1300);
		assert.equal(await timer(tab), kept, "paused, it doesn't move");
		assert.equal(await tab.page.eval("document.title"), "Pomodoro");
		await click(tab, "Reset");
		await until(async () => (await timer(tab)) === "25:00 left", { what: "a whole session again" });
		assert.deepEqual(tab.errors, []);
	} finally {
		tab.close();
	}
});

test("a whole focus session gone by: the chime and the buzz, the session recorded, the break set up", async (t) => {
	if (!browser) return t.skip("no Chromium");
	const tab = await browser.open(`${run.app.url}/`);
	try {
		await tab.findByText("0 of 8 focus sessions today");
		await tab.page.eval(rig);
		await click(tab, "Start");
		await until(async () => /^24:5\d left$/.test(await timer(tab)), { what: "the timer running" });
		await tab.page.eval("window.skew = 25 * 60 * 1000");
		await tab.findByText("1 of 8 focus sessions today");
		assert.equal(await timer(tab), "05:00 left");
		assert.equal(await tab.page.eval(`document.querySelector('[role="tab"][aria-selected="true"]').textContent.trim()`), "Break");
		await tab.findByText("Start");
		const asked = await tab.page.eval("window.asked");
		assert.deepEqual(asked, [["sound", "/sounds/done.wav"], ["buzz", [300, 150, 300]]]);
		assert.equal(await tab.page.eval(`document.querySelector(".fill").style.width`), "12.5%");
		assert.deepEqual(tab.errors, []);
	} finally {
		tab.close();
	}
});
