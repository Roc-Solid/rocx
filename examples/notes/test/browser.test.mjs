// Notes in Chromium, as a person uses it: signs in with the link the app mails, writes a note in
// the editor (its preview rendered as they type, by packages/markdown in the page's WebAssembly),
// saves it, and finds it again by searching, the word it found highlighted. Every page hydrates
// strictly, with nothing logged.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { findChrome, launchBrowser } from "../../../packages/testing/index.mjs";
import { mailedLink, noDatabase, started } from "./app.mjs";

const noChrome = !(await findChrome()) && "needs Chromium's headless shell ($CHROME, or Playwright's)";

describe("Notes in a browser", { skip: noDatabase || noChrome }, () => {
	let running, browser, tab;
	before(async () => {
		running = await started();
		browser = await launchBrowser();
	});
	after(async () => {
		await browser?.close();
		await running?.stop();
	});

	/** Waits for the tab to be at `path` (a new page, after a click), hydrated. */
	const landed = async (path) => tab.page.wait(`location.pathname + location.search === ${JSON.stringify(path)} && Boolean(window.__rocxReady)`, 10_000);

	test("signing in with the mailed link", async () => {
		const { app } = running;
		tab = await browser.open(`${app.url}/`);
		// Signed out: the notebook sends you to sign in, and back after.
		assert.equal(await tab.page.eval("location.pathname + location.search"), "/sign-in?then=%2F");
		await (await tab.getByLabelText("Email address")).fill("ada@example.com");
		const before = (await app.mail()).length;
		await (await tab.getByRole("button", { name: "Email me a link" })).click();
		// The page stays, and says where the link went.
		await tab.findByRole("heading", { name: "Check your inbox" });
		await tab.findByText("ada@example.com");

		const link = await mailedLink(app, "ada@example.com", before);
		await tab.goto(`${app.url}${link}`);
		await (await tab.getByRole("button", { name: "Sign in" })).click();
		await landed("/");
		await tab.findByRole("heading", { name: "All notes" });
		await tab.findByRole("link", { name: "Launch week plan" });
		assert.deepEqual(tab.errors, []);
	});

	test("writing a note, its preview as it is typed, and saving it", async () => {
		await (await tab.getByRole("link", { name: "New note" })).click();
		await landed("/new");
		await (await tab.getByLabelText("Title")).fill("Kite festival");
		await (await tab.getByLabelText("Tags")).fill("events, Outdoors");
		await (await tab.getByLabelText("The note, in Markdown")).fill("## Packing\n\nBring the **orange** kite, and spare line.\n\n- [ ] Check the wind");

		// The preview is the Markdown rendered, in the page, as it was typed.
		const preview = await tab.findByRole("region", { name: "Preview" });
		assert.ok(preview);
		await tab.waitFor((dom) => dom.getByRole("heading", { name: "Packing", level: 2 }));
		assert.equal((await tab.findByText("orange")).tag, "strong");
		await tab.findByText("11 words");

		await (await tab.getByRole("button", { name: "Save note" })).click();
		await tab.page.wait("/^\\/notes\\/\\d+$/.test(location.pathname) && Boolean(window.__rocxReady)", 10_000);
		await tab.findByRole("heading", { name: "Kite festival", level: 1 });
		await tab.findByRole("link", { name: "#outdoors" });
		assert.deepEqual(tab.errors, []);

		const [row] = await running.db.sql`select n.body, n.tags from notes n join people p on p.id = n.person_id where p.email = 'ada@example.com' and n.title = 'Kite festival'`;
		// node:sqlite reads a json column as its text.
		assert.deepEqual(JSON.parse(row.tags), ["events", "outdoors"]);
	});

	test("finding it again by searching, the word it found highlighted", async () => {
		const box = await tab.getByRole("searchbox", { name: "Search your notes" });
		await box.fill("kites");
		await box.press("Enter");
		await landed("/?q=kites");
		await tab.findByRole("heading", { name: "Search" });
		await tab.findByRole("link", { name: "Kite festival" });
		const marked = await tab.page.eval(`[...document.querySelectorAll("mark")].map((mark) => mark.textContent)`);
		assert.deepEqual(marked, ["kite"]);
		assert.equal((await tab.findByRole("status")).text, "1 note for “kites”");
		assert.deepEqual(tab.errors, []);
	});
});
