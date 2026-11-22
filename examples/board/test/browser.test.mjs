// Two people on one board, each in a browser of their own (the tabs of one launch share their
// cookies, so they would be one person): Ada in Gecko (Zen or Firefox) when there is one, as many
// people browse, and in Chromium when there isn't; Bo in Chromium. Ada drags a card to another
// column; it shows there at once on her page, and moves on Bo's, gliding, without a reload. Each
// sees the other here; Bo sees which card Ada has open, and that she is editing it, and it opens
// for him to edit once she closes it.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { findChrome, findGecko, launchBrowser } from "../../../packages/testing/index.mjs";
import { as, ids, noDatabase, started } from "./app.mjs";

const noChrome = !(await findChrome()) && "needs Chromium's headless shell ($CHROME, or Playwright's)";
/** Ada's browser. */
const engine = (await findGecko()) ? "gecko" : "chromium";

/** Notes every glide (D-031) the page's runtime plays, by the key of the element that moved, and
 * those lifted above the page (out of a column's scrolling list into another's). */
const GLIDES = `document.addEventListener("rocx:ready", (event) => {
	window.__glides = [];
	window.__lifted = [];
	window.__runtime = event.detail.runtime;
	event.detail.runtime.observer = {
		glide: (detail) => {
			window.__glides.push(detail.key ?? "");
			if (detail.lifted) window.__lifted.push(detail.key ?? "");
		},
	};
});`;

/** Holds back the lease takes an open card sends (`POST …/lease`) while `window.__holdTakes` is set,
 * as a slow network might, until `window.__letTakesGo()` sends them (it answers how many); notes the
 * status each was answered with. */
const HOLD = `(() => {
	const send = window.fetch;
	window.__held = [];
	window.__answered = [];
	window.fetch = async (input, init) => {
		const url = typeof input === "string" ? input : input.url;
		if (window.__holdTakes && (init?.method ?? input.method) === "POST" && url.endsWith("/lease")) {
			await new Promise((go) => window.__held.push(go));
			const answer = await send(input, init);
			window.__answered.push(answer.status);
			return answer;
		}
		return send(input, init);
	};
	window.__letTakesGo = () => {
		window.__holdTakes = false;
		const held = window.__held.splice(0);
		for (const go of held) go();
		return held.length;
	};
})();`;

/** A key pressed and let go with Alt held, as a keyboard does it: over the DevTools protocol in
 * Chromium, with WebDriver's key actions in Gecko (Alt is `\uE00A` there, ArrowDown `\uE015`). */
async function pressAlt(tab, key) {
	if (typeof tab.page.send === "function") {
		for (const type of ["rawKeyDown", "keyUp"]) await tab.page.send("Input.dispatchKeyEvent", { type, key, code: key, modifiers: 1 });
		return;
	}
	const value = { ArrowUp: "\uE013", ArrowDown: "\uE015" }[key] ?? key;
	await tab.page.actions([{ type: "key", id: "keyboard", actions: [{ type: "keyDown", value: "\uE00A" }, { type: "keyDown", value }, { type: "keyUp", value }, { type: "keyUp", value: "\uE00A" }] }]);
}

describe(`Acme Board in two browsers (Ada's: ${engine})`, { skip: noDatabase || noChrome }, () => {
	let running, seeded, browsers, people, open, ada, bo;
	before(async () => {
		running = await started();
		seeded = await ids(running.db);
		people = Object.fromEntries((await running.db.sql`select name, id::text as id from people`).map((row) => [row.name, row.id]));
		browsers = [await launchBrowser({ engine }), await launchBrowser()];
		open = async (browser, person) => {
			const tab = await browser.open(`${running.app.url}/b/launch`, { cookies: [["acme_board_person", person]], script: GLIDES + HOLD });
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

	test("each sees the other on the board, the board's channel and its presence room on one stream", async () => {
		await ada.findByRole("group", { name: "Bo is here" });
		await bo.findByRole("group", { name: "Ada is here" });
		for (const tab of [ada, bo]) {
			assert.equal(await tab.page.eval("window.__runtime.hub.stream?.key ?? null"), "/b/launch\n/b/launch/presence", "one stream (/rocx/live) for both channels");
			assert.equal(await tab.page.eval("window.__runtime.hub.stats.connects"), 1, "opened once");
			assert.ok(!(await tab.requested()).some((path) => path.startsWith("/b/launch/presence")), "presence asks nothing of its own");
		}
	});

	test("a card Ada drags to another column moves there on her page at once, and on Bo's as it is saved", async () => {
		const card = seeded.cards["Press kit"];
		assert.equal(await columnOf(ada, "Press kit"), "To do");
		assert.equal(await columnOf(bo, "Press kit"), "To do");
		await bo.page.eval("window.__stayed = true");

		// A drag, as a mouse makes it: pressed on the tile, and dropped on the Doing column's first
		// card (packages/testing's drag: Chromium's own drag and drop, or in Gecko, which never ends
		// a drag WebDriver starts, the DOM's drag events).
		await ada.drag(`[data-card="${card}"]`, `[data-card="${seeded.cards["Telemetry dashboard"]}"]`);
		assert.equal(await columnOf(ada, "Press kit"), "Doing");

		await bo.page.wait(`[...document.querySelectorAll('[data-column="${seeded.columns.Doing}"] .tile .open')].map((each) => each.textContent).join("|") === "Press kit|Telemetry dashboard|Rehearse the countdown"`, 5000);
		assert.equal(await bo.page.eval("window.__stayed"), true, "Bo's page wasn't loaded again");
		// It glided there, on both pages: the tile that left To do and the one that came into Doing
		// share the card's key.
		assert.ok((await bo.page.eval("window.__glides")).includes(card));
		assert.ok((await ada.page.eval("window.__glides")).includes(card));
		// Out of To do's list, which scrolls, into Doing's: above the page, so neither cuts it off; the
		// cards that made room for it stayed in their lists.
		for (const [who, tab] of [["Bo", bo], ["Ada", ada]]) {
			const lifted = await tab.page.eval("window.__lifted");
			assert.ok(lifted.includes(card) && lifted.every((key) => key === card), `lifted on ${who}'s page, and nothing else: ${lifted}`);
		}
		assert.equal(await ada.page.eval(`getComputedStyle(document.querySelector('[data-column="${seeded.columns.Doing}"] .cards')).overflowY`), "auto", "a column's cards scroll on their own");
		// Bo is told who moved what.
		await bo.findByText("Ada moved “Press kit” to Doing");

		const [row] = await running.db.sql`select c.name from cards join columns c on c.id = cards.column_id where cards.id = ${card}`;
		assert.equal(row.name, "Doing");
		// The board read again, and the glides over, each tile where it lands, no stand-in left: To do's
		// list, scrolled to show the card as it was dragged, is shorter now, and its cards glide down
		// from where they were seen.
		for (const tab of [ada, bo]) await tab.page.wait("!document.querySelector('.board.stale') && ![...document.querySelectorAll('.tile')].some((tile) => tile.getAnimations().length) && !document.querySelector('[data-rocx-lifted]')", 5000);
	});

	test("Ada opens a card: Bo sees her there and that she is editing it, and it opens for him once she closes it", async () => {
		const title = "Book the launch pad";
		const card = seeded.cards[title];
		await (await ada.getByRole("link", { name: title })).click();
		await ada.findByRole("heading", { level: 2, name: title });
		assert.equal(await ada.page.eval("document.querySelector('.panel fieldset').disabled"), false);

		// The card takes the keyboard's focus, at its title; Alt+↓ moves it down its column.
		await ada.page.wait("document.activeElement?.id === 'card-title'", 5000);
		const order = `[...document.querySelectorAll('[data-column="${seeded.columns["To do"]}"] .tile .open')].map((each) => each.textContent.trim()).join("|")`;
		assert.equal(await ada.page.eval(order), "Book the launch pad|Weather go/no-go checklist|Fix the fuel gauge rounding");
		await pressAlt(ada, "ArrowDown");
		await ada.page.wait(`${order} === "Weather go/no-go checklist|Book the launch pad|Fix the fuel gauge rounding"`, 5000);
		// Bo's board follows, the tile gliding down: it lands before he clicks it.
		await bo.page.wait(`${order} === "Weather go/no-go checklist|Book the launch pad|Fix the fuel gauge rounding" && ![...document.querySelectorAll('.tile')].some((tile) => tile.getAnimations().length) && !document.querySelector('[data-rocx-lifted]')`, 5000);

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
		// Bo closes it with Escape, pressed with the focus anywhere on the page (`<Document>`).
		await bo.page.eval("document.activeElement?.blur()");
		for (const type of ["rawKeyDown", "keyUp"]) await bo.page.send("Input.dispatchKeyEvent", { type, key: "Escape", code: "Escape" });
		await bo.page.wait("!document.querySelector('.panel')", 5000);
		await ada.page.wait(`!document.querySelector('[data-card="${card}"] .editing')`, 5000);
	});

	test("a card saved and closed at once is free for everyone else, though the renewal it sent was still on its way", async () => {
		// Bo, in Chromium, then Ada, in Gecko when there is one, saves a card and closes it at once. The
		// board, read again after the save, makes the open card renew its lease, and that take is held
		// back (a slow network) until the card has let the lease go: it reaches the server last, and
		// finds the lease let go by the opening that sent it, so it takes nothing.
		const cyd = await as(running.app, running.db, "Cyd");
		for (const [who, tab, other, title] of [
			["Bo", bo, ada, "Live countdown on the website"],
			["Ada", ada, bo, "Confetti cannon at lift-off"],
		]) {
			const card = seeded.cards[title];
			const editing = `document.querySelector('[data-card="${card}"] .editing')`;
			await (await tab.getByRole("link", { name: title })).click();
			await tab.findByRole("heading", { level: 2, name: title });
			await other.page.wait(`${editing}?.textContent.includes("${who} is editing")`, 5000);

			await tab.page.eval("window.__holdTakes = true");
			await (await tab.getByLabelText("Title")).fill(`${title}, again`);
			await (await tab.getByRole("button", { name: "Save" })).click();
			await tab.page.wait("window.__held.length > 0", 5000);
			await tab.page.eval("document.activeElement?.blur()");
			await tab.page.press("Escape");
			await tab.page.wait("!document.querySelector('.panel')", 5000);
			await other.page.wait(`!${editing}`, 5000);

			const late = await tab.page.eval("window.__letTakesGo()");
			await tab.page.wait(`window.__answered.length === ${late}`, 5000);
			assert.deepEqual(await tab.page.eval("window.__answered.splice(0)"), Array(late).fill(409), `${who}'s late renewals are refused`);
			assert.deepEqual((await cyd.read("/b/launch")).leases, [], `no one holds a lease once ${who} has closed the card`);
			assert.equal(await other.page.eval(`${editing} === null`), true);
			const [row] = await running.db.sql`select title from cards where id = ${card}`;
			assert.equal(row.title, `${title}, again`, `${who}'s save is in`);
		}
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
		// Cyd's browser closes: their tab's subscription ends, and once the room's grace (5 s) is up,
		// the next change anyone makes (Ada opening a card) sweeps them out of everyone's stack.
		await bo.findByRole("group", { name: "Ada and Cyd are here" });
		await browsers.pop().close();
		await new Promise((resolve) => setTimeout(resolve, 5500));
		await (await ada.getByRole("link", { name: title })).click();
		await bo.findByRole("group", { name: "Ada is here" }, { ms: 5000 });
		await (await ada.getByRole("button", { name: "Done" })).click();
	});

	test("neither page threw or warned", () => {
		for (const tab of [ada, bo]) {
			assert.deepEqual(tab.errors, []);
			assert.deepEqual(tab.console.filter((line) => line.type === "error" || line.type === "warning"), []);
		}
	});
});
