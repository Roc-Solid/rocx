// Pinwheel in a real browser (Chromium's headless shell, hydrating strictly): someone joins a room
// by its code from the front page, waits in its lobby, and answers its first question with a tap,
// while the host runs the room over HTTP; then the host's big screen, as the host (its buttons
// work) and as anyone else (no buttons). Skipped where there is no Chromium.
//
//   DATABASE_URL=… node --test 'examples/quiz/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launchBrowser } from "../../../packages/testing/index.mjs";
import { follow, openRoom, say, skip, stage, started } from "./app.mjs";

let run;
let browser;
before(async () => {
	if (skip) return;
	browser = await launchBrowser();
	if (browser) run = await started({ questionMs: 15000, revealMs: 5000 });
});
after(async () => {
	await browser?.close();
	await run?.stop();
});

test("joining by code from the front page, and answering a question with a tap", { skip }, async (t) => {
	if (!browser) return t.skip("no Chromium");
	const { app, db } = run;
	const host = app.client();
	const code = await openRoom(host, "Words and Wonders");
	const screen = await follow(host, code, "host-tab");
	const [first] = await db.sql`select q.prompt, q.choices, q.answer from quiz_questions q join quiz_sets s on s.id = q.set_id where s.slug = ${"words-and-wonders"} and q.position = 0`;
	const right = first.choices[first.answer];

	// The front page: the code (typed in lower case, with a dash) and a name, then Join.
	const tab = await browser.open(`${app.url}/`);
	await (await tab.getByLabelText("Room code")).fill(`${code.slice(0, 2).toLowerCase()}-${code.slice(2).toLowerCase()}`);
	await (await tab.getByLabelText("Your name")).fill("Ada");
	await (await tab.getByRole("button", { name: "Join" })).click();

	// The room's page, as a player: the lobby, with Ada in it, here.
	await tab.findByRole("heading", { name: "You're in, Ada!" }, {}, { ms: 10000 });
	assert.equal(new URL(await tab.page.eval("location.href")).pathname, `/play/${code}`);
	await tab.findByText("1 player here", {}, { ms: 10000 });
	const lobby = await screen.next((view) => stage(view) === "Lobby" && view.players.some((each) => each.name === "Ada" && each.here));
	assert.equal(lobby.players.length, 1);

	// The host starts: the question comes to the phone, with its clock.
	assert.equal((await say(host, code, "host-tab", "Start")).status, 204);
	await tab.findByRole("heading", { name: first.prompt }, {}, { ms: 10000 });
	await tab.findByRole("timer");
	await tab.findByText("Tap your answer.");

	// A tap: the choice is sent on the room's channel. Ada is the only player, so her answer
	// closes the question, and the reveal says how she did.
	await (await tab.getByRole("button", { name: right })).click();
	await tab.findByRole("heading", { name: "Right!" }, {}, { ms: 10000 });
	await tab.findByText(/^You're 1st of 1, with \d+ points\.$/);
	const revealing = await screen.next((view) => stage(view) === "Revealing");
	const [gain] = revealing.stage.Revealing.gains;
	assert.equal(gain.choice, first.answer);
	assert.ok(gain.gained >= 500 && gain.gained <= 1000);
	assert.equal((await tab.getByLabelText(`Score: ${gain.gained}`)).text, String(gain.gained));

	assert.deepEqual(tab.errors, []);

	// The host's screen, in its own tab (as the host): the board after the reveal; the host's Next
	// moves on, and its "Close it now" (said on the channel from the page) closes the question.
	const big = await browser.open(`${app.url}/host/${code}`, { cookies: [...host.cookies] });
	await big.findByRole("heading", { name: "The board" });
	assert.match((await big.getByRole("list", { name: "Leaderboard" })).text, /Ada/);
	assert.equal((await say(host, code, "host-tab", "Next")).status, 204);
	const second = await screen.next((view) => stage(view) === "Asking" && view.stage.Asking.index === 1);
	await big.findByRole("heading", { name: second.stage.Asking.prompt });
	await (await big.findByRole("button", { name: "Close it now" })).click();
	await screen.next((view) => stage(view) === "Revealing" && view.stage.Revealing.index === 1);
	await big.findByRole("button", { name: "Go on now" });
	assert.deepEqual(big.errors, []);

	// Anyone else's: the same room, without the host's buttons.
	const watching = await browser.open(`${app.url}/host/${code}`);
	await watching.findByRole("heading", { name: "The board" });
	assert.equal(await watching.queryByRole("button", { name: "Go on now" }), null);

	// Bo joins late (anyone may, until the podium) and answers the next question right; the host
	// skips the rest (Next closes a question, and moves a reveal on). The podium, on the screen that
	// was open all along, has the scores as the room has them now, Bo's among them.
	const answers = (await db.sql`select q.answer from quiz_questions q join quiz_sets s on s.id = q.set_id where s.slug = ${"words-and-wonders"} order by q.position`).map((row) => row.answer);
	const bo = app.client();
	await bo.get("/");
	assert.equal((await bo.post("/join", { code, name: "Bo" })).status, 303);
	const boTab = await follow(bo, code, "bo-tab");
	// Each phase once: a view that only says someone came or answered is the same phase.
	const phase = (view) => `${stage(view)} ${view.stage.Asking?.index ?? view.stage.Revealing?.index ?? ""}`;
	let last = "Revealing 1";
	let finished;
	let answered = false;
	while (!finished) {
		const now = await screen.next((view) => phase(view) !== last);
		last = phase(now);
		if (stage(now) === "Finished") finished = now;
		else {
			if (stage(now) === "Asking" && !answered) {
				answered = true;
				const index = now.stage.Asking.index;
				assert.equal((await say(bo, code, "bo-tab", { Pick: { index, choice: answers[index] } })).status, 204);
				await screen.next((view) => view.players.some((each) => each.name === "Bo" && each.answered));
			}
			assert.equal((await say(host, code, "host-tab", "Next")).status, 204);
		}
	}
	const scores = Object.fromEntries(finished.players.map((each) => [each.name, each.score]));
	assert.ok(scores.Ada >= 500 && scores.Bo >= 500, JSON.stringify(scores));
	await watching.findByRole("heading", { name: "That's the game!" });
	const podium = await watching.findByLabelText("Podium");
	assert.match(podium.text, new RegExp(`Ada ${scores.Ada}`));
	assert.match(podium.text, new RegExp(`Bo ${scores.Bo}`));
	boTab.close();
	assert.deepEqual(watching.errors, []);
	screen.close();
});
