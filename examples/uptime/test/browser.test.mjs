// The app in a real browser (Chromium's headless shell), each page hydrated strictly: the
// status page follows a monitor down and up again without a reload, through the live channel; and
// the subscribe form answers in place, on a SQLite file of its own. Skipped without Chromium.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launchBrowser } from "../../../packages/testing/index.mjs";
import { build, check, fakeTarget, start, watch } from "./uptime.mjs";

let target;
let running;
let browser;

before(async () => {
	browser = await launchBrowser();
	if (!browser) return;
	target = await fakeTarget();
	running = await start(await build(), target);
});

after(async () => {
	await browser?.close();
	await running?.stop();
	await target?.close();
});

const skip = (t) => {
	if (!browser) return (t.skip("no Chromium (see packages/testing/README.md)"), true);
	return false;
};

test("the status page follows a monitor down and up again, live, without a reload", async (t) => {
	if (skip(t)) return;
	const { app, db } = running;
	const id = await watch(db, target, { name: "Acme Checkout", path: "/checkout", threshold: 1 });
	const tab = await browser.open(`${app.url}/`);
	await tab.findByText("Live");
	await tab.findByRole("heading", { level: 1, name: "All systems operational" });
	const loads = await tab.page.eval("performance.getEntriesByType('navigation').length");

	target.status = 500;
	await check(db, id);
	await tab.findByRole("heading", { level: 1, name: "Partial outage" });
	await tab.findByRole("heading", { level: 2, name: "Happening now" });
	await tab.findByRole("link", { name: "Acme Checkout is down" });
	await tab.findByText("Outage");

	target.status = 200;
	await check(db, id);
	await tab.findByRole("heading", { level: 1, name: "All systems operational" });
	await tab.waitFor((dom) => dom.queryByRole("heading", { level: 2, name: "Happening now" }) === null);
	assert.equal(await tab.page.eval("performance.getEntriesByType('navigation').length"), loads, "no reload");
	assert.equal(await tab.page.eval("document.querySelector('[aria-live]').textContent"), "Acme Checkout is back: its incident is resolved.");
	assert.deepEqual(tab.errors, []);
});

test("subscribing from the status page answers in place", async (t) => {
	if (skip(t)) return;
	const { app, db } = running;
	const tab = await browser.open(`${app.url}/`);
	await tab.findByText("Live");
	await (await tab.getByLabelText("Get an email when an incident opens or closes")).fill("linus@example.com");
	await (await tab.getByRole("button", { name: "Subscribe" })).click();
	await tab.findByText("Subscribed: linus@example.com hears about incidents as they open and close.");
	assert.equal(await tab.page.eval("location.pathname"), "/");
	const [{ count }] = await db.sql`select count(*) as count from subscribers where email = 'linus@example.com'`;
	assert.equal(count, 1);
	assert.deepEqual(tab.errors, []);
});
