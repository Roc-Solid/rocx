// echo, tested: what its benchmark sends each endpoint comes back as it went. POST /echo answers
// the JSON string it was sent; POST /echo/json reads the order (order.json, sent compact as the
// benchmark sends it) into a record and writes it back, the same JSON with its fields in Roc's
// order; a body that isn't an order is refused before the endpoint runs.
//
//   node --test 'examples/echo/test/*.test.mjs'
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { buildForTests, startServer, repo } from "../../../packages/testing/index.mjs";

let app;

before(async () => {
	const built = await buildForTests(join(repo, "examples", "echo"));
	app = await startServer(built.server);
});

after(() => app?.stop());

/** POST `path` with `body` (text) as JSON: the answer's status and its text. */
async function posted(path, body) {
	const answer = await fetch(`${app.url}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body });
	return { status: answer.status, text: await answer.text(), timing: answer.headers.get("server-timing") ?? "" };
}

test("POST /echo answers the string it was sent, and says how long Roc took", async () => {
	const { status, text, timing } = await posted("/echo", '"hello"');
	assert.equal(status, 200);
	assert.equal(text, '"hello"');
	assert.match(timing, /dur=[\d.]+/, "the benchmark reads Roc's time from server-timing");
});

test("POST /echo/json answers the order it was sent, read and written again", async () => {
	const order = JSON.parse(readFileSync(join(repo, "examples", "echo", "order.json"), "utf8"));
	const { status, text } = await posted("/echo/json", JSON.stringify(order));
	assert.equal(status, 200, text);
	assert.deepEqual(JSON.parse(text), order);
	// Written again, not passed through: Roc writes a record's fields in its own order.
	assert.notEqual(text, JSON.stringify(order));
});

test("POST /echo/json refuses what isn't an order", async () => {
	const missing = await posted("/echo/json", '{"id":"order-1"}');
	assert.equal(missing.status, 400);
	assert.match(missing.text, /customer/);
	assert.equal((await posted("/echo/json", "{not json")).status, 400);
});
