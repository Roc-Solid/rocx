// Two people on one board, each in a browser of their own (two Chromium launches: the tabs of one
// launch share their cookies, so they would be one person). Ada drags a card to another column; it
// shows there at once on her page, and moves on Bo's, gliding, without a reload. Each sees the
// other here; Bo sees which card Ada has open, and that she is editing it, and it opens for him to
// edit once she closes it.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { findChrome, launchBrowser } from "../../../packages/testing/index.mjs";
import { ids, noDatabase, started } from "./app.mjs";

const noChrome = !(await findChrome()) && "needs Chromium's headless shell ($CHROME, or Playwright's)";

/** Notes every glide (D-031) the page's runtime plays, by the key of the element that moved. */
const GLIDES = `document.addEventListener("rocx:ready", (event) => {
	window.__glides = [];
	event.detail.runtime.observer = { glide: (detail) => window.__glides.push(detail.key ?? "") };
});`;

describe("Acme Board in two browsers", { skip: noDatabase || noChrome }, () => {
	let running, seeded, browsers, people, open, ada, bo;
	before(async () => {
		running = await started();
		seeded = await ids(running.db);
		people = Object.fromEntries((await running.db.sql`select name, id::text as id from people`).map((row) => [row.name, row.id]));
		browsers = [await launchBrowser(), await launchBrowser()];
		open = async (browser, person) => {
			const url = `${running.app.url}/b/launch`;
			const tab = await browser.open(url, { cookies: [["acme_board_person", person]] });
			await tab.page.send("Page.addScriptToEvaluateOnNewDocument", { source: GLIDES });
			await tab.goto(url);
			// Live: subscribed to the board's channel, and in its presence room.
			await tab.page.wait("document.querySelector('.live.on')", 5000);
			return tab;
		};
		[ada, bo] = [await open(browsers[0], people.Ada), await open(browsers[1], people.Bo)];
	});
	after(async () => {
		for (const browser of browsers ?? []) await browser?.close();
		await running?.stop();
	});

	/** The name of the column the card called `title` is in, on a tab's page now. */
	const columnOf = (tab, title) =>
		tab.page.eval(`(() => {
			const link = [...document.querySelectorAll(".tile .open")].find((each) => each.textContent.trim() === ${JSON.stringify(title)});
			return link ? link.closest("[data-column]").querySelector("h2").textContent : null;
		})()`);

	test("each sees the other on the board", async () => {
		await ada.findByRole("group", { name: "Bo is here" });
		await bo.findByRole("group", { name: "Ada is here" });
	});

	test("a card Ada drags to another column moves there on her page at once, and on Bo's as it is saved", async () => {
		const card = seeded.cards["Press kit"];
		assert.equal(await columnOf(ada, "Press kit"), "To do");
		assert.equal(await columnOf(bo, "Press kit"), "To do");
		await bo.page.eval("window.__stayed = true");

		// A real drag, through the browser's own drag and drop: pressed on the tile, moved over the
		// Doing column's first card, and dropped there.
		await ada.page.drag(`[data-card="${card}"]`, [`[data-card="${seeded.cards["Telemetry dashboard"]}"]`]);
		assert.equal(await columnOf(ada, "Press kit"), "Doing");

		await bo.page.wait(`[...document.querySelectorAll('[data-column="${seeded.columns.Doing}"] .tile .open')].map((each) => each.textContent).join("|") === "Press kit|Telemetry dashboard|Rehearse the countdown"`, 5000);
		assert.equal(await bo.page.eval("window.__stayed"), true, "Bo's page wasn't loaded again");
		// It glided there, on both pages: the tile that left To do and the one that came into Doing
		// share the card's key.
		assert.ok((await bo.page.eval("window.__glides")).includes(card));
		assert.ok((await ada.page.eval("window.__glides")).includes(card));
		// Bo is told who moved what.
		await bo.findByText("Ada moved “Press kit” to Doing");

		const [row] = await running.db.sql`select c.name from cards join columns c on c.id = cards.column_id where cards.id = ${card}`;
		assert.equal(row.name, "Doing");
	});

	test("Ada opens a card: Bo sees her there and that she is editing it, and it opens for him once she closes it", async () => {
		const title = "Book the launch pad";
		const card = seeded.cards[title];
		await (await ada.getByRole("link", { name: title })).click();
		await ada.findByRole("heading", { level: 2, name: title });
		assert.equal(await ada.page.eval("document.querySelector('.panel fieldset').disabled"), false);

		// On Bo's board, the tile shows Ada has it open, and is editing it.
		await bo.findByRole("group", { name: "Ada has this card open" });
		await bo.page.wait(`document.querySelector('[data-card="${card}"] .editing')?.textContent.includes("Ada is editing")`, 5000);

		// Bo opens it too: he can read it, not change it.
		await (await bo.getByRole("link", { name: title })).click();
		await bo.findByText("Ada is editing this card. You can read it; it opens for you once they close it.", undefined, { ms: 5000 });
		assert.equal(await bo.page.eval("document.querySelector('.panel fieldset').disabled"), true);

		// Ada closes it: the lease goes, and Bo's card opens for him, without his doing anything.
		await (await ada.getByRole("button", { name: "Done" })).click();
		await bo.page.wait("document.querySelector('.panel fieldset')?.disabled === false", 5000);
		await ada.page.wait(`document.querySelector('[data-card="${card}"] .editing')?.textContent.includes("Bo is editing")`, 5000);

		// Bo renames it; Ada's board shows the new title.
		await (await bo.getByLabelText("Title")).fill("Book the launch pad for Tuesday");
		await (await bo.getByRole("button", { name: "Save" })).click();
		await ada.findByRole("link", { name: "Book the launch pad for Tuesday" }, { ms: 5000 });
		await (await bo.getByRole("button", { name: "Done" })).click();
		await ada.page.wait(`!document.querySelector('[data-card="${card}"] .editing')`, 5000);
	});

	test("Cyd opens the card Ada has open: on Bo's board the tile's stack is kept, its label patched (D-039)", async () => {
		const title = "Telemetry dashboard";
		const card = seeded.cards[title];
		const stack = `document.querySelector('[data-card="${card}"] .avatar-stack')`;
		await (await ada.getByRole("link", { name: title })).click();
		await ada.findByRole("heading", { level: 2, name: title });
		await bo.findByRole("group", { name: "Ada has this card open" });
		await bo.page.eval(`window.__stack = ${stack}`);

		// Cyd, in a browser of their own, opens it too: Bo's tile now says both, the same stack.
		browsers.push(await launchBrowser());
		const cyd = await open(browsers[2], people.Cyd);
		await (await cyd.getByRole("link", { name: title })).click();
		await cyd.findByRole("heading", { level: 2, name: title });
		await bo.findByRole("group", { name: "Ada and Cyd have this card open" }, { ms: 5000 });
		assert.equal(await bo.page.eval(`window.__stack === ${stack}`), true, "the stack kept: its label patched where the prop is read, as Solid's props are");
		assert.equal(await bo.page.eval(`${stack}.querySelectorAll(".avatar").length`), 2, "the newcomer's avatar came into the kept stack");

		await (await ada.getByRole("button", { name: "Done" })).click();
		await bo.findByRole("group", { name: "Cyd has this card open" }, { ms: 5000 });
		assert.equal(await bo.page.eval(`window.__stack === ${stack}`), true);
		assert.deepEqual(cyd.errors, []);
		await browsers.pop().close();
	});

	test("neither page threw or warned", () => {
		for (const tab of [ada, bo]) {
			assert.deepEqual(tab.errors, []);
			assert.deepEqual(tab.console.filter((line) => line.type === "error" || line.type === "warning"), []);
		}
	});
});
