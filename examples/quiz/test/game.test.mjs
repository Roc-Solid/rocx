// Pinwheel over HTTP, as its pages use it: forms posted, endpoints read, and the room's channel
// followed and spoken on (`/rocx/live`), on a SQLite file of the test's own. A whole game with a host
// and three players, checked question by question and at the end; the timers that run a room
// nobody answers; presence (a player who drops, and comes back); the join forms and the editor's
// refusals; and seeding that changes nothing the second time.
//
//   node --test 'examples/quiz/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { dir, follow, openRoom, say, skip, stage, started } from "./app.mjs";

let run;
before(async () => {
	if (!skip) run = await started({ questionMs: 4000, revealMs: 300 });
});
after(async () => {
	await run?.stop();
});

/** A player: joined to room `code` as `name` with a client of their own, and following it. */
async function player(app, code, name) {
	const client = app.client();
	await client.get("/");
	const joined = await client.post("/join", { code, name });
	assert.equal(joined.status, 303, `${name} joins: ${joined.text}`);
	assert.equal(joined.location, `/play/${code}`);
	const seat = await client.read(`/rooms/${code}`);
	const stream = await follow(client, code, `${name}-tab`);
	return { name, client, id: seat.who.Player, tab: `${name}-tab`, stream };
}

test("a whole game: a host and three players, every question, and the final scores", { skip }, async () => {
	const { app, db } = run;
	const host = app.client();
	const code = await openRoom(host, "Words and Wonders");
	assert.match(code, /^[BCDFGHJKMNPQRSTVWXZ]{4}$/);
	const answers = (await db.sql`select q.answer from quiz_questions q join quiz_sets s on s.id = q.set_id where s.slug = ${"words-and-wonders"} order by q.position`).map((row) => row.answer);
	assert.equal(answers.length, 6);

	const screen = await follow(host, code, "host-tab");
	const players = [];
	for (const name of ["Ada", "Bo", "Cy"]) players.push(await player(app, code, name));
	const [ada, bo] = players;
	assert.deepEqual(
		players.map((each) => each.id),
		["p1", "p2", "p3"],
	);

	// The lobby: everyone here, as presence says.
	const lobby = await screen.next((view) => stage(view) === "Lobby" && view.players.length === 3 && view.players.every((each) => each.here));
	assert.deepEqual(
		lobby.players.map((each) => each.name),
		["Ada", "Bo", "Cy"],
	);

	// Only the host starts the game.
	const notHost = await say(ada.client, code, ada.tab, "Start");
	assert.equal(notHost.status, 200);
	assert.match(notHost.json().refused[0].why, /Only the host/);
	assert.equal((await say(host, code, "host-tab", "Start")).status, 204);

	// Ada is always right; Bo is right on every other question; Cy is always wrong. Everyone answers,
	// so each question closes as the last answer comes in, without waiting for the clock.
	const earned = { Ada: 0, Bo: 0, Cy: 0 };
	for (let index = 0; index < answers.length; index++) {
		const asking = (await screen.next((view) => stage(view) === "Asking" && view.stage.Asking.index === index)).stage.Asking;
		assert.ok(!("answer" in asking), "no answer is sent while the question is asked");
		assert.ok(asking.left_ms <= 4000 && asking.limit_ms === 4000);
		const right = answers[index];
		const wrong = (right + 1) % asking.choices.length;
		const picks = { Ada: right, Bo: index % 2 === 0 ? right : wrong, Cy: wrong };
		for (const each of players) assert.equal((await say(each.client, code, each.tab, { Pick: { index, choice: picks[each.name] } })).status, 204);

		const revealing = (await screen.next((view) => stage(view) === "Revealing" && view.stage.Revealing.index === index)).stage.Revealing;
		assert.equal(revealing.answer, right);
		const tallies = asking.choices.map((_, at) => Object.values(picks).filter((choice) => choice === at).length);
		assert.deepEqual(revealing.tallies, tallies);
		assert.equal(revealing.last, index === answers.length - 1);
		for (const each of players) {
			const gain = revealing.gains.find((one) => one.id === each.id);
			assert.equal(gain.choice, picks[each.name]);
			if (picks[each.name] === right) assert.ok(gain.gained >= 500 && gain.gained <= 1000, `${each.name} earned ${gain.gained} for a right answer`);
			else assert.equal(gain.gained, 0, `${each.name} earned nothing for a wrong one`);
			earned[each.name] += gain.gained;
		}
	}

	// The podium: each score is what the reveals said it earned, and they are in the order the
	// answers deserve.
	const finished = await screen.next((view) => stage(view) === "Finished");
	const scores = Object.fromEntries(finished.players.map((each) => [each.name, each.score]));
	assert.deepEqual(scores, earned);
	assert.equal(scores.Cy, 0);
	assert.ok(scores.Ada >= 6 * 500 && scores.Ada <= 6 * 1000, `Ada: ${scores.Ada}`);
	assert.ok(scores.Bo >= 3 * 500 && scores.Bo <= 3 * 1000, `Bo: ${scores.Bo}`);
	assert.ok(scores.Ada > scores.Bo);

	// Each phone saw the same ending, and a player's page says so.
	const adaSaw = await ada.stream.next((view) => stage(view) === "Finished");
	assert.deepEqual(adaSaw.players, finished.players);
	const page = await ada.client.get(`/play/${code}`);
	assert.equal(page.status, 200);
	page.dom.getByRole("heading", { name: "You won!" });

	// A late answer is refused, and changes nothing.
	const late = await say(bo.client, code, bo.tab, { Pick: { index: 0, choice: answers[0] } });
	assert.equal(late.json().refused[0].status, 409);
	assert.match(late.json().refused[0].why, /isn't open/);

	// Again: the same players, from nothing, back in the lobby.
	assert.equal((await say(host, code, "host-tab", "Again")).status, 204);
	const again = await screen.next((view) => stage(view) === "Lobby");
	assert.deepEqual(
		again.players.map((each) => [each.name, each.score]),
		[
			["Ada", 0],
			["Bo", 0],
			["Cy", 0],
		],
	);
	for (const each of [screen, ...players.map((one) => one.stream)]) each.close();
});

test("the room's own timers: a question nobody answers closes when its time is up, and the next one follows its reveal", { skip }, async () => {
	const { app } = run;
	const host = app.client();
	const code = await openRoom(host, "Science Snacks");
	const screen = await follow(host, code, "host-tab");
	const dee = await player(app, code, "Dee");
	await screen.next((view) => stage(view) === "Lobby" && view.players.some((each) => each.here));
	assert.equal((await say(host, code, "host-tab", "Start")).status, 204);
	const started = Date.now();
	await screen.next((view) => stage(view) === "Asking" && view.stage.Asking.index === 0);
	const revealing = (await screen.next((view) => stage(view) === "Revealing")).stage.Revealing;
	const took = Date.now() - started;
	assert.ok(took >= 3500, `the question stayed open its 4 s (it closed after ${took} ms)`);
	assert.deepEqual(revealing.gains, [], "nobody answered");
	await screen.next((view) => stage(view) === "Asking" && view.stage.Asking.index === 1);

	// The host's Next closes a question at once, and moves a reveal on at once.
	assert.equal((await say(host, code, "host-tab", "Next")).status, 204);
	await screen.next((view) => stage(view) === "Revealing" && view.stage.Revealing.index === 1, { ms: 2000 });
	screen.close();
	dee.stream.close();
});

test("presence: a player whose phone goes is shown as dropped, and is back when it is", { skip }, async () => {
	const { app } = run;
	const host = app.client();
	const code = await openRoom(host, "Around the Globe");
	const screen = await follow(host, code, "host-tab");
	const eve = await player(app, code, "Eve");
	const fay = await player(app, code, "Fay");
	await screen.next((view) => view.players.length === 2 && view.players.every((each) => each.here));

	// Eve's tab closes: after the grace (4 s), she has dropped.
	eve.stream.close();
	const dropped = await screen.next((view) => view.players.some((each) => each.name === "Eve" && !each.here), { ms: 10000 });
	assert.deepEqual(
		dropped.players.map((each) => [each.name, each.here]),
		[
			["Eve", false],
			["Fay", true],
		],
	);
	// Her page, opened again, finds her a player still; her tab follows the room again, and she is back.
	assert.deepEqual((await eve.client.read(`/rooms/${code}`)).who, { Player: eve.id });
	const back = await follow(eve.client, code, "Eve-tab-2");
	await screen.next((view) => view.players.every((each) => each.here));
	for (const each of [screen, back, fay.stream]) each.close();
});

test("joining: the forms' issues at their fields, a plain post's flash, a room's own form, and no room at all", { skip }, async () => {
	const { app } = run;
	const host = app.client();
	const code = await openRoom(host, "Around the Globe");
	const gus = await player(app, code, "Gus");

	const someone = app.client();
	await someone.get("/");
	// As the runtime sends a form: 422 and the issues, as JSON, at their fields.
	const issues = async (answer) => JSON.parse(answer.text).map((issue) => [issue.field, issue.message]);
	assert.deepEqual(await issues(await someone.submit("/join", { code: "nope", name: "" })), [
		["code", "A code is four letters, like BKRT."],
		["name", "Fill this in"],
	]);
	assert.deepEqual(await issues(await someone.submit("/join", { code: code.toLowerCase(), name: "gus" })), [["name", "Someone in that room has this name already."]]);
	assert.deepEqual(await issues(await someone.submit("/join", { code: "ZZZZ", name: "Hal" })), [["code", "There's no room with that code."]]);
	// The form checks its body whatever it comes as (D-093): JSON is read by the same rules, and the
	// issues come back as JSON, saying so.
	const scripted = await someone.json("/join", { code: "nope", name: "" });
	assert.equal(scripted.status, 422);
	assert.equal(scripted.headers.get("content-type"), "application/json");
	assert.deepEqual(await issues(scripted), [
		["code", "A code is four letters, like BKRT."],
		["name", "Fill this in"],
	]);

	// Without the runtime, the form posts, and comes back to the front page with a flash.
	const posted = await someone.post("/join", { code: "ZZZZ", name: "Hal" });
	assert.equal(posted.status, 303);
	assert.equal(new URL(posted.location, app.url).pathname, "/");
	assert.equal(someone.flash.status, 422);
	const back = await posted.follow();
	assert.ok(back.dom.getAllByText("There's no room with that code.").length >= 1, "the page it came back to shows why");

	// A room's own page asks a newcomer only for a name.
	const page = await someone.get(`/play/${code}`);
	page.dom.getByRole("heading", { name: `Join room ${code}` });
	const named = await someone.post(`/play/${code}`, { name: "Hal" });
	assert.equal(named.status, 303);
	assert.equal(named.location, `/play/${code}`);
	assert.match((await someone.read(`/rooms/${code}`)).who.Player, /^p\d+$/);

	// A code with no room: the pages say so; its channel refuses (404).
	(await someone.get("/play/ZZZZ")).dom.getByRole("heading", { name: "There's no room ZZZZ" });
	(await someone.get("/host/ZZZZ")).dom.getByRole("heading", { name: "There's no room ZZZZ" });
	assert.equal(stage((await someone.read("/rooms/ZZZZ")).view), "Vacant");
	const events = await someone.events(`/rocx/live?tab=x&c=${encodeURIComponent("/rooms/ZZZZ")}`);
	const [hello, refusal] = await events.take(2);
	assert.equal(hello.event, "hello", "the stream's id first (D-057)");
	assert.equal(refusal.event, "refused");
	assert.equal(JSON.parse(refusal.data.split("\n")[1]).status, 404);
	events.close();
	gus.stream.close();
});

test("the editor: what it refuses, field by field; a new set, first on the host's page; a room for it", { skip }, async () => {
	const { app } = run;
	const writer = app.client();
	(await writer.get("/sets/new")).dom.getByLabelText("Questions");
	const refused = await writer.submit("/sets", { title: "", blurb: "", questions: "Which?\n- a\n- b" });
	assert.equal(refused.status, 422);
	assert.deepEqual(
		JSON.parse(refused.text).map((issue) => [issue.field, issue.message]),
		[
			["title", "Fill this in"],
			["questions", "Question 1: mark exactly one choice right, with *."],
		],
	);

	const questions = "Which of these is a citrus fruit?\n- Apple\n* Lime\n- Fig\n\nHow many strings has a violin?\n* Four\n- Six";
	const saved = await writer.post("/sets", { title: "Snack Time", blurb: "Fruit and fiddles.", questions });
	assert.equal(saved.status, 303);
	assert.match(saved.location, /^\/host\?made=\d+$/);
	const sets = await writer.read("/host");
	assert.equal(sets[0].title, "Snack Time");
	assert.equal(sets[0].questions, 2);
	(await saved.follow()).dom.getByRole("button", { name: "Open a room for Snack Time" });

	const code = await openRoom(writer, "Snack Time");
	const seat = await writer.read(`/rooms/${code}`);
	assert.equal(seat.who, "Host");
	assert.equal(seat.view.title, "Snack Time");
	assert.equal(seat.view.total, 2);
});

test("seeding is idempotent: the seed run again adds nothing", { skip }, async () => {
	const { db } = run;
	const count = async () => (await db.sql`select (select count(*) from quiz_sets where slug is not null) as sets, (select count(*) from quiz_questions q join quiz_sets s on s.id = q.set_id where s.slug is not null) as questions`)[0];
	const before = await count();
	assert.deepEqual(before, { sets: 3, questions: 18 });
	// The seed is several statements: node:sqlite's exec runs them all (db.query prepares one).
	const { DatabaseSync } = await import("node:sqlite");
	const seeding = new DatabaseSync(db.path, { timeout: 10_000 });
	seeding.exec(readFileSync(join(dir, "migrations", "0002_seed.sql"), "utf8"));
	seeding.close();
	assert.deepEqual(await count(), before);
});

test("the pages render on the server, each with what it is for", { skip }, async () => {
	const { app } = run;
	const visitor = app.client();
	const home = await visitor.get("/");
	home.dom.getByRole("heading", { name: "Join a game" });
	home.dom.getByLabelText("Room code");
	home.dom.getByRole("link", { name: "Open a room" });
	const hosting = await visitor.get("/host");
	assert.equal(hosting.dom.getAllByRole("button", { name: /^Open a room for/ }).length >= 3, true);
	(await visitor.get("/nowhere")).dom.getByRole("heading", { name: "Nothing here" });

	const host = app.client();
	const code = await openRoom(host, "Science Snacks");
	const screen = await host.get(`/host/${code}`);
	screen.dom.getByRole("heading", { name: "Join on your phone with" });
	screen.dom.getByRole("button", { name: "Waiting for players…" });
	assert.equal(screen.dom.getByLabelText(`Room code: ${code.split("").join(" ")}`).text, code);
});
