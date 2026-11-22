// packages/testing's SQLite helper (sqlite.mjs): a file of a test's own, written and read over
// node:sqlite with values as parameters, and removed. Needs nothing else.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { testSqlite } from "../index.mjs";

test("testSqlite: a file of the test's own, its url for a server, values as parameters, rows as objects, removed by drop()", async () => {
	const db = testSqlite();
	assert.match(db.url, /^sqlite:.+test\.db$/);
	await db.query("create table notes (id integer primary key, body text not null, done boolean not null, meta json)");
	assert.deepEqual(await db.sql`insert into notes (body, done, meta) values (${"it's milk"}, ${true}, ${{ tags: ["a"] }})`, []);
	const [note] = await db.sql`select id, body, done, json_extract(meta, '$.tags[0]') as tag from notes where body = ${"it's milk"}`;
	assert.deepEqual(note, { id: 1, body: "it's milk", done: 1, tag: "a" });
	assert.deepEqual(await db.query("select count(*) as n from notes where done = ?", [false]), [{ n: 0 }]);
	assert.ok(existsSync(db.path));
	await db.drop();
	assert.ok(!existsSync(db.dir));
});
