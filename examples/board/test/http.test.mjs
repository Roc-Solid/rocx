// Board over HTTP, as a browser without JavaScript and as the page's runtime ask it: joining,
// the seeded board, moves and their ranks (concurrent ones too), the edit lease, the board's
// channel, the rate limit on writes, and the forms.
import { after, before, describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { until } from "../../../packages/testing/index.mjs";
import { as, dir, ids, noDatabase, started, titles } from "./app.mjs";

describe("Board over HTTP", { skip: noDatabase }, () => {
	let running, app, db, seeded;
	before(async () => {
		// A lease runs out after 3 s here, rather than 30, so a test can wait for it.
		running = await started({ env: { BOARD_LEASE_TTL_MS: "3000" } });
		({ app, db } = running);
		seeded = await ids(db);
	});
	after(() => running?.stop());

	test("someone new is sent to join, picks a name and a colour, and comes back", async () => {
		const visitor = app.client();
		const front = await visitor.get("/b/launch");
		assert.equal(front.status, 303);
		assert.equal(front.location, "/join?then=%2Fb%2Flaunch");
		assert.deepEqual((await visitor.read("/join")).map((person) => person.name), ["Ada", "Bo", "Cyd"]);
		const page = await visitor.get("/join?then=%2Fb%2Flaunch");
		page.dom.getByRole("button", { name: "Ada" });
		page.dom.getByLabelText("Your name");

		const joined = await visitor.post("/join", { name: " Dee ", color: "#0b7285", then: "/b/launch" });
		assert.equal(joined.status, 303);
		assert.equal(joined.location, "/b/launch");
		const board = await visitor.read("/b/launch");
		assert.equal(board.me.name, "Dee");
		assert.equal(board.me.color, "#0b7285");

		// The same name, whatever its case, is the same person, in the colour picked last.
		const again = app.client();
		await again.post("/join", { name: "dee", color: "#e67700", then: "/" });
		assert.deepEqual(await again.read("/b/launch").then((data) => [data.me.id, data.me.name, data.me.color]), [board.me.id, "Dee", "#e67700"]);

		// Only this site's paths, and only the colours there are.
		assert.equal((await app.client().post("/join", { name: "Eve", color: "#0b7285", then: "//elsewhere.example/" })).location, "/");
		const refused = app.client();
		await refused.get("/join");
		assert.equal((await refused.post("/join", { name: "Eve", color: "red", then: "/" })).status, 303);
		assert.deepEqual([refused.flash.status, refused.flash.body], [400, "Pick one of the colours."]);
		assert.equal(refused.cookies.has("acme_board_person"), false);
	});

	test("the seeded board: three people, four columns, ten cards, and running the seed again adds nothing", async () => {
		const ada = await as(app, db, "Ada");
		const board = await ada.read("/b/launch");
		assert.equal(board.name, "Acme Rocket Launch");
		assert.deepEqual(board.columns.map((column) => column.name), ["Ideas", "To do", "Doing", "Done"]);
		assert.equal(board.cards.length, 10);
		assert.deepEqual(board.people.map((person) => person.name).filter((name) => ["Ada", "Bo", "Cyd"].includes(name)), ["Ada", "Bo", "Cyd"]);
		const pad = board.cards.find((card) => card.title === "Book the launch pad");
		assert.deepEqual(pad.checklist.map((item) => item.text), ["Call the pad crew", "Sign the booking form", "Tell the press office"]);
		assert.deepEqual(pad.labels, ["ops", "urgent"]);
		assert.match(pad.due, /^\d{4}-\d{2}-\d{2}$/);

		// The seed is several statements: node:sqlite's exec runs them all (db.query prepares one).
		const { DatabaseSync } = await import("node:sqlite");
		const seeding = new DatabaseSync(db.path, { timeout: 10_000 });
		seeding.exec(readFileSync(join(dir, "migrations", "0002_seed.sql"), "utf8"));
		seeding.close();
		const [counts] = await db.sql`select (select count(*) from people) as people, (select count(*) from cards) as cards, (select count(*) from checklist_items) as items`;
		assert.equal(Number(counts.cards), 10);
		assert.equal(Number(counts.items), 11);
	});

	test("a move puts the card between its new neighbours, writing its row alone", async () => {
		const ada = await as(app, db, "Ada");
		const { cards, columns } = seeded;
		const before = await db.sql`select cast(id as text) as id, rank from cards where id <> ${cards["Press kit"]} order by id`;

		// Into another column, between two cards.
		const moved = await ada.json("/b/launch/move", { card: cards["Press kit"], column: columns.Doing, before: cards["Rehearse the countdown"] });
		assert.equal(moved.status, 200);
		let board = await ada.read("/b/launch");
		assert.deepEqual(titles(board, columns.Doing), ["Telemetry dashboard", "Press kit", "Rehearse the countdown"]);
		assert.deepEqual(await db.sql`select cast(id as text) as id, rank from cards where id <> ${cards["Press kit"]} order by id`, before);

		// To the top of a column, and to its end.
		await ada.json("/b/launch/move", { card: cards["Fix the fuel gauge rounding"], column: columns["To do"], before: cards["Book the launch pad"] });
		await ada.json("/b/launch/move", { card: cards["Book the launch pad"], column: columns["To do"], before: "" });
		board = await ada.read("/b/launch");
		assert.deepEqual(titles(board, columns["To do"]), ["Fix the fuel gauge rounding", "Weather go/no-go checklist", "Book the launch pad"]);

		// Before a card that has gone to another column since: the end of the column instead.
		await ada.json("/b/launch/move", { card: cards["Weather go/no-go checklist"], column: columns.Ideas, before: "" });
		await ada.json("/b/launch/move", { card: cards["Press kit"], column: columns["To do"], before: cards["Weather go/no-go checklist"] });
		board = await ada.read("/b/launch");
		assert.deepEqual(titles(board, columns["To do"]), ["Fix the fuel gauge rounding", "Book the launch pad", "Press kit"]);

		// Every rank is a rank, and no two cards in a column share one.
		const ranks = await db.sql`select cast(column_id as text) as col, rank from cards`;
		assert.ok(ranks.every((row) => /^[0-9a-z]*[1-9a-z]$/.test(row.rank)), JSON.stringify(ranks));
		assert.equal(new Set(ranks.map((row) => `${row.col} ${row.rank}`)).size, ranks.length);
	});

	test("moves that can't be: before itself, a card or a column that isn't there, someone who hasn't joined", async () => {
		const ada = await as(app, db, "Ada");
		const { cards, columns } = seeded;
		const itself = await ada.json("/b/launch/move", { card: cards["Order the fuel"], column: columns.Done, before: cards["Order the fuel"] });
		assert.deepEqual([itself.status, itself.text], [400, "A card can't go before itself."]);
		assert.equal((await ada.json("/b/launch/move", { card: "999999", column: columns.Done, before: "" })).status, 404);
		assert.equal((await ada.json("/b/launch/move", { card: cards["Order the fuel"], column: "999999", before: "" })).status, 404);
		assert.equal((await ada.json("/b/launch/move", { card: "x", column: "y", before: "" })).status, 404);
		assert.equal((await ada.json("/b/elsewhere/move", { card: cards["Order the fuel"], column: columns.Done, before: "" })).status, 404);
		assert.equal((await app.client().json("/b/launch/move", { card: cards["Order the fuel"], column: columns.Done, before: "" })).status, 401);
	});

	test("ten cards dropped into one gap at once each get a rank of their own, in that gap", async () => {
		const bo = await as(app, db, "Bo");
		const { columns } = seeded;
		// A column of its own: two cards, and ten more to drop between them.
		await bo.json("/b/launch/columns", { name: "Race" });
		const race = (await bo.read("/b/launch")).columns.find((column) => column.name === "Race").id;
		for (const title of ["Top", "Bottom", ...Array.from({ length: 10 }, (_, index) => `Racer ${index}`)]) {
			assert.equal((await bo.json("/b/launch/cards", { column: title.startsWith("Racer") ? columns.Ideas : race, title })).status, 200);
		}
		const board = await bo.read("/b/launch");
		const id = (title) => board.cards.find((card) => card.title === title).id;
		const answers = await Promise.all(Array.from({ length: 10 }, (_, index) => bo.json("/b/launch/move", { card: id(`Racer ${index}`), column: race, before: id("Bottom") })));
		assert.deepEqual(answers.map((answer) => answer.status), Array(10).fill(200));
		const shown = titles(await bo.read("/b/launch"), race);
		assert.equal(shown.length, 12);
		assert.equal(shown[0], "Top");
		assert.equal(shown.at(-1), "Bottom");
		const ranks = await db.sql`select rank from cards where column_id = ${race}`;
		assert.equal(new Set(ranks.map((row) => row.rank)).size, 12);
	});

	test("the edit lease: one person edits a card at a time, and it ends when they close it or vanish", async () => {
		const [ada, bo] = [await as(app, db, "Ada"), await as(app, db, "Bo")];
		const card = seeded.cards["Telemetry dashboard"];
		const lease = `/b/launch/cards/${card}/lease`;
		const fields = { title: "Telemetry dashboard", description: "Every second.", assignee: "", due: "" };
		// Each opening of the card takes the lease, and lets it go, with a token of its own.
		const [adas, bos] = [{ token: "ada-1" }, { token: "bo-1" }];

		assert.deepEqual([(await ada.json(lease, adas)).status, (await ada.json(lease, adas)).status], [200, 200]);
		const refused = await bo.json(lease, bos);
		assert.deepEqual([refused.status, refused.text], [409, "Ada is editing this card."]);
		assert.deepEqual((await bo.read("/b/launch")).leases, [{ card, person: (await ada.read("/b/launch")).me.id, name: "Ada" }]);

		// While Ada edits it, Bo can't change it; Ada can.
		assert.equal((await bo.json(`/b/launch/cards/${card}`, fields)).status, 409);
		assert.equal((await bo.json(`/b/launch/cards/${card}/labels`, { label: "bug", on: "true" })).status, 409);
		assert.equal((await ada.json(`/b/launch/cards/${card}`, fields)).status, 200);
		// Moving it isn't editing it.
		assert.equal((await bo.json("/b/launch/move", { card, column: seeded.columns.Doing, before: "" })).status, 200);

		// Bo can't let Ada's lease go; Ada can, and then Bo has it.
		assert.equal((await bo.json(`${lease}/release`, bos)).text, '"not yours"');
		assert.equal((await ada.json(`${lease}/release`, adas)).text, '"released"');
		assert.equal((await bo.json(lease, bos)).status, 200);
		assert.equal((await ada.json(lease, { token: "ada-2" })).text, "Bo is editing this card.");

		// Bo's tab vanishes: no renewals, and the lease runs out on its own (3 s here).
		await until(async () => (await ada.json(lease, { token: "ada-2" })).status === 200, { ms: 5000, what: "Bo's lease to run out" });
		assert.equal((await bo.json(`/b/launch/cards/${card}`, fields)).status, 409);
	});

	test("a take an open card sent before it closed takes nothing, once it has let the lease go; opening it again takes it", async () => {
		const ada = await as(app, db, "Ada");
		const card = seeded.cards["Weather go/no-go checklist"];
		const lease = `/b/launch/cards/${card}/lease`;
		const leases = async () => (await ada.read("/b/launch")).leases.filter((each) => each.card === card);

		// Taken, saved and closed, and the renewal the card sent before it closed comes in last.
		assert.equal((await ada.json(lease, { token: "open-1" })).status, 200);
		assert.equal((await ada.json(`${lease}/release`, { token: "open-1" })).text, '"released"');
		const late = await ada.json(lease, { token: "open-1" });
		assert.deepEqual([late.status, late.text], [409, "This card was closed."]);
		assert.deepEqual(await leases(), []);

		// Opened and closed at once, the release in before the first take.
		assert.equal((await ada.json(`${lease}/release`, { token: "open-2" })).text, '"not yours"');
		assert.equal((await ada.json(lease, { token: "open-2" })).status, 409);
		assert.deepEqual(await leases(), []);

		// Opened again: a new token, and the lease is hers.
		assert.equal((await ada.json(lease, { token: "open-3" })).status, 200);
		assert.equal((await leases()).length, 1);
		assert.equal((await ada.json(`${lease}/release`, { token: "open-3" })).text, '"released"');
	});

	test("everyone on a board hears each change on its channel, and only members may listen", async () => {
		const [ada, bo] = [await as(app, db, "Ada"), await as(app, db, "Bo")];
		const live = await bo.events("/rocx/live?tab=bo-1&c=/b/launch");
		assert.equal((await live.next()).event, "hello", "the stream's id first (D-057)");
		assert.deepEqual(await live.next(), { event: "resync", data: "/b/launch", id: null });
		await ada.json("/b/launch/move", { card: seeded.cards["Order the fuel"], column: seeded.columns.Done, before: seeded.cards["Paint the rocket"] });
		const heard = await live.next();
		assert.equal(heard.event, "message");
		assert.deepEqual(JSON.parse(heard.data.split("\n")[1]), { by: "Ada", did: "moved “Order the fuel” to Done" });
		live.close();

		const visitor = await app.client().events("/rocx/live?tab=visitor-1&c=/b/launch");
		assert.equal((await visitor.next()).event, "hello");
		const turned = await visitor.next();
		assert.equal(turned.event, "refused");
		assert.equal(JSON.parse(turned.data.split("\n")[1]).status, 401);
		visitor.close();
		const nowhere = await ada.events("/rocx/live?tab=ada-1&c=/b/nowhere");
		assert.equal((await nowhere.next()).event, "hello");
		assert.equal(JSON.parse((await nowhere.next()).data.split("\n")[1]).status, 404);
		nowhere.close();
	});

	test("labels, the checklist, archiving and deleting, each said once however often it is sent", async () => {
		const cyd = await as(app, db, "Cyd");
		const card = seeded.cards["Rehearse the countdown"];
		const read = async () => (await cyd.read("/b/launch")).cards.find((each) => each.id === card);
		for (const _ of [1, 2]) assert.equal((await cyd.json(`/b/launch/cards/${card}/labels`, { label: "urgent", on: "true" })).status, 200);
		assert.deepEqual((await read()).labels, ["ops", "urgent"]);
		await cyd.json(`/b/launch/cards/${card}/labels`, { label: "ops", on: "false" });
		assert.deepEqual((await read()).labels, ["urgent"]);
		assert.equal((await cyd.json(`/b/launch/cards/${card}/labels`, { label: "nope", on: "true" })).status, 400);

		await cyd.json(`/b/launch/cards/${card}/checklist`, { text: "T minus ten" });
		await cyd.json(`/b/launch/cards/${card}/checklist`, { text: "Lift-off" });
		const [first, second] = (await read()).checklist;
		for (const _ of [1, 2]) await cyd.json(`/b/launch/cards/${card}/checklist/tick`, { item: first.id, done: "true" });
		await cyd.json(`/b/launch/cards/${card}/checklist/delete`, { item: second.id });
		assert.deepEqual((await read()).checklist, [{ id: first.id, text: "T minus ten", done: true }]);
		assert.equal((await cyd.json(`/b/launch/cards/${card}/checklist`, { text: "  " })).status, 400);

		const save = await cyd.json(`/b/launch/cards/${card}`, { title: "", description: "", assignee: "", due: "" });
		assert.deepEqual([save.status, save.text], [400, "A card needs a title."]);
		assert.equal((await cyd.json(`/b/launch/cards/${card}`, { title: "Rehearse", description: "", assignee: "", due: "next week" })).status, 400);
		assert.equal((await cyd.json(`/b/launch/cards/${card}`, { title: "Rehearse", description: "", assignee: "999999", due: "" })).status, 400);

		// Deleting is for archived cards; archived, it is off the board, and can come back.
		assert.equal((await cyd.json(`/b/launch/cards/${card}/delete`, {})).status, 409);
		await cyd.json(`/b/launch/cards/${card}/archive`, { archived: "true" });
		assert.equal((await read()).archived, true);
		await cyd.json(`/b/launch/cards/${card}/archive`, { archived: "false" });
		assert.equal((await read()).archived, false);
		await cyd.json(`/b/launch/cards/${card}/archive`, { archived: "true" });
		assert.equal((await cyd.json(`/b/launch/cards/${card}/delete`, {})).status, 200);
		assert.equal(await read(), undefined);
		assert.deepEqual(await db.sql`select id from checklist_items where card_id = ${card}`, []);
	});

	test("without JavaScript: the forms post, the board is a page, and a card opens from its address", async () => {
		const bo = await as(app, db, "Bo");
		const page = await bo.get("/b/launch");
		assert.equal(page.status, 200);
		page.dom.getByRole("heading", { name: "Acme Rocket Launch" });
		page.dom.getByRole("link", { name: "Paint the rocket" });

		const added = await bo.post("/b/launch/cards", { column: seeded.columns.Ideas, title: "Mission patch" });
		assert.equal(added.status, 303);
		assert.match(added.location, /\/b\/launch$/);
		assert.deepEqual([bo.flash.status, bo.flash.body], [200, '"added"']);
		(await added.follow()).dom.getByRole("link", { name: "Mission patch" });
		await bo.post("/b/launch/cards", { column: seeded.columns.Ideas, title: "" });
		assert.deepEqual([bo.flash.status, bo.flash.body], [400, "A card needs a title."]);

		const open = await bo.get(`/b/launch?card=${seeded.cards["Paint the rocket"]}`);
		assert.equal(open.dom.getByRole("heading", { level: 2, name: "Paint the rocket" }).tag, "h2");
		assert.equal(open.dom.getByLabelText("Title").attr("value"), "Paint the rocket");
		open.dom.getByRole("checkbox", { name: "Primer" });

		const made = await bo.post("/", { name: "Q1 Roadmap!" });
		assert.deepEqual([made.status, made.location], [303, "/b/q1-roadmap"]);
		assert.deepEqual((await bo.read("/b/q1-roadmap")).columns.map((column) => column.name), ["To do", "Doing", "Done"]);
		await bo.get("/");
		await bo.post("/", { name: "q1 roadmap" });
		assert.deepEqual([bo.flash.status, bo.flash.body], [409, "There is a board called that already."]);
		assert.equal((await bo.get("/b/nowhere")).status, 404);
	});

	test("writes are rate limited for each person: a burst of 60, then one a second", async () => {
		const burst = app.client();
		await burst.post("/join", { name: "Burst", color: "#5c940d", then: "/" });
		const answers = [];
		for (let index = 0; index < 70; index++) answers.push(await burst.json("/b/launch/columns/rename", { column: seeded.columns.Ideas, name: "Ideas" }));
		const statuses = answers.map((answer) => answer.status);
		assert.ok(statuses.slice(0, 60).every((status) => status === 200), statuses.join(" "));
		const limited = answers.find((answer) => answer.status === 429);
		assert.ok(limited, statuses.join(" "));
		assert.match(limited.headers.get("retry-after"), /^\d+$/);
		assert.equal(limited.headers.get("ratelimit-policy"), "60;w=60");
		// Someone else isn't held up, and reading isn't writing.
		assert.equal((await (await as(app, db, "Ada")).json("/b/launch/columns/rename", { column: seeded.columns.Ideas, name: "Ideas" })).status, 200);
		assert.equal((await burst.request("/b/launch", { headers: { accept: "application/json" } })).status, 200);
	});
});
