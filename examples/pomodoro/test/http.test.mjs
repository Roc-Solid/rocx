// The pomodoro over HTTP: the page rendered on the server at a whole focus session, today's count
// read and a session recorded through the app's contract, a session no one could have refused, and
// the files a browser loads besides (the chime, the plugins' scripts).
//
//   node --test 'examples/pomodoro/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { started } from "./app.mjs";

let run;
before(async () => {
	run = await started();
});
after(() => run?.stop());

test("the page: the timer at 25:00, focus chosen, Start, and today's count, all rendered on the server", async () => {
	const page = await run.app.client().get("/");
	assert.equal(page.status, 200);
	assert.match(page.text, /<title>Pomodoro<\/title>/);
	page.dom.getByRole("heading", { level: 1, name: "Pomodoro" });
	assert.equal(page.dom.getByRole("tab", { name: "Focus" }).attr("aria-selected"), "true");
	assert.equal(page.dom.getByRole("tab", { name: "Break" }).attr("aria-selected"), "false");
	assert.equal(page.dom.getByRole("timer").attr("aria-label"), "25:00 left");
	page.dom.getByRole("button", { name: "Start" });
	page.dom.getByText("0 of 8 focus sessions today");
	assert.match(page.text, /stroke-dasharray="1000 1000"/, "the ring is whole");
	assert.match(page.text, /<script [^>]*src="\/rocx\/plugins\/audio\/audio.js"/);
	assert.match(page.text, /<script [^>]*src="\/rocx\/plugins\/vibrate\/vibrate.js"/);
});

test("a focus session recorded: today's count after it, and GET /api/today agrees", async () => {
	const client = run.app.client();
	assert.deepEqual((await client.get("/api/today")).json(), { done: 0, goal: 8 });
	const first = await client.json("/api/sessions", { minutes: 25 });
	assert.equal(first.status, 200, first.text);
	assert.deepEqual(first.json(), { done: 1, goal: 8 });
	await client.json("/api/sessions", { minutes: 25 });
	assert.deepEqual((await client.get("/api/today")).json(), { done: 2, goal: 8 });
	(await client.get("/")).dom.getByText("2 of 8 focus sessions today");
});

test("a session of no minutes, or longer than a day, is refused", async () => {
	const client = run.app.client();
	for (const minutes of [0, 24 * 60 + 1]) {
		const refused = await client.json("/api/sessions", { minutes });
		assert.equal(refused.status, 400, `${minutes} minutes`);
		assert.match(refused.text, /1 to 1,440 minutes/);
	}
});

test("the chime and the plugins' scripts are served", async () => {
	const client = run.app.client();
	const chime = await client.get("/sounds/done.wav");
	assert.equal(chime.status, 200);
	assert.match(chime.headers.get("content-type") ?? "", /audio\/(wav|x-wav)/);
	const script = await client.get("/rocx/plugins/vibrate/vibrate.js");
	assert.equal(script.status, 200);
	assert.match(script.text, /"vibrate\.pattern": vibrate/);
});
