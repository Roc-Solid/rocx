// Million over HTTP, as a page and its channel ask it: the page rendered on the server with its
// first rows, `GET /boxes`, a box said on the channel and every subscriber told its chunk, the
// count of pages open, and many boxes of one chunk checked at once, none lost.
//
//   node --test 'examples/checkboxes/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { box, build, checkedIn, follow, say, start } from "./million.mjs";

let app;
before(async () => {
	app = await start(await build());
});
after(() => app?.stop());

test("the page: rendered on the server with the rows its first 800 pixels show, 40 boxes a row, none checked", async () => {
	const page = await app.client().get("/");
	assert.equal(page.status, 200);
	assert.match(page.text, /<title>A million checkboxes · Million<\/title>/);
	page.dom.getByRole("heading", { level: 1, name: "Million" });
	const boxes = page.dom.getAllByRole("checkbox");
	assert.equal(boxes.length, 33 * 40, "29 rows show in 800 pixels, and 4 more below");
	assert.equal(boxes[0].attr("aria-label"), "Box 1");
	assert.equal(boxes.at(-1).attr("aria-label"), "Box 1,320");
	assert.ok(boxes.every((each) => each.attr("checked") === null), "none checked");
	assert.match(page.text, /class="virtual-list-space" style="height: 700000px"/, "25,000 rows of 28 pixels to scroll through");
});

test("a box checked on the channel: every page hears its chunk, one version on, and GET /boxes has it; checked again, nothing; unchecked, the next version; a box that isn't there is refused", async () => {
	const client = app.client();
	const a = await follow(client, "http-a");
	const b = await follow(client, "http-b");
	try {
		assert.equal((await say(client, "http-a", box(123_456))).status, 204);
		const changed = (message) => message.Changed?.chunk === 123;
		for (const tab of [a, b]) {
			const { Changed } = await tab.next(changed);
			assert.equal(Changed.version, 1);
			assert.ok(checkedIn(Changed.bits, 123_456));
			assert.ok(!checkedIn(Changed.bits, 123_457));
		}
		let read = await client.read("/boxes");
		assert.deepEqual(read.chunks.map(({ chunk, version }) => ({ chunk, version })), [{ chunk: 123, version: 1 }]);

		// Checked again: nothing changes, nothing is said. Then unchecked: version 2, and its chunk has
		// no box checked ("").
		assert.equal((await say(client, "http-b", box(123_456), box(123_456, false))).status, 204);
		const { Changed } = await a.next(changed);
		assert.deepEqual(Changed, { chunk: 123, version: 2, bits: "" });
		read = await client.read("/boxes");
		assert.deepEqual(read.chunks, [{ chunk: 123, version: 2, bits: "" }], "kept, with no box checked: a page that heard version 1 takes this");

		const refused = await say(client, "http-a", box(1_000_000));
		assert.equal(refused.status, 200);
		assert.match(refused.text, /"refused"/);
		assert.match(refused.text, /there are 1,000,000 boxes, numbered from 0/);
	} finally {
		a.close();
		b.close();
	}
});

test("how many pages are open: each subscriber counts, every page is told, and one that closes no longer counts", async () => {
	const client = app.client();
	const a = await follow(client, "online-a");
	const { Online: first } = await a.next((message) => "Online" in message);
	const b = await follow(client, "online-b");
	assert.equal((await b.next((message) => "Online" in message)).Online, first + 1, "it hears the count, itself in it");
	assert.equal((await a.next((message) => message.Online === first + 1)).Online, first + 1, "the others are told");
	b.close();
	assert.equal((await a.next((message) => message.Online === first)).Online, first);
	assert.equal((await client.read("/boxes")).online, first);
	a.close();
});

test("two hundred boxes of one chunk checked at once, from four tabs: none lost, each a version of its own", async () => {
	const client = app.client();
	const tabs = ["many-a", "many-b", "many-c", "many-d"];
	const indexes = Array.from({ length: 200 }, (_, i) => 777_000 + i * 5);
	await Promise.all(tabs.map((tab, t) => say(client, tab, ...indexes.filter((_, i) => i % tabs.length === t).map((index) => box(index)))));
	const read = await client.read("/boxes");
	const chunk = read.chunks.find((each) => each.chunk === 777);
	assert.equal(chunk.version, 200);
	assert.ok(indexes.every((index) => checkedIn(chunk.bits, index)), "every one checked");
});
