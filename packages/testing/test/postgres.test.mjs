// postgres.mjs: literals, a connection that signs in (SCRAM, as Postgres 14 and later ask), rows as
// objects of JavaScript values, errors with Postgres's words, and a database of a test's own, made
// and dropped. Needs DATABASE_URL (`just db` starts one); without it only the literals are tested.
import { test } from "node:test";
import assert from "node:assert/strict";
import { connect, ident, literal, sqlText, testDatabase } from "../postgres.mjs";

const url = process.env.DATABASE_URL;
const skip = !url && "no DATABASE_URL (`just db` starts a Postgres)";

test("postgres: values become literals, names identifiers, and nothing in a string escapes it", () => {
	assert.equal(literal("it's"), "'it''s'");
	assert.equal(literal("a\\b"), "'a\\b'", "a backslash is itself: standard_conforming_strings");
	assert.equal(literal(null), "NULL");
	assert.equal(literal(undefined), "NULL");
	assert.equal(literal(3.5), "3.5");
	assert.equal(literal(10n), "10");
	assert.equal(literal(true), "TRUE");
	assert.equal(literal({ a: "'" }), `'{"a":"''"}'`);
	assert.equal(literal(Buffer.from([1, 255])), "'\\x01ff'::bytea");
	assert.equal(literal(new Date(0)), "'1970-01-01T00:00:00.000Z'");
	assert.throws(() => literal(NaN), /can't be written/);
	assert.throws(() => literal("a\0b"), /NUL/);
	assert.equal(ident('we"ird'), '"we""ird"');
	assert.equal(sqlText(["select ", " as a, ", " as b"], ["x'; drop table t; --", 2]), "select 'x''; drop table t; --' as a, 2 as b");
});

test("postgres: a database of the test's own, its rows as JavaScript values, Postgres's errors", { skip }, async () => {
	const db = await testDatabase(url);
	try {
		assert.match(db.name, /^rocx_test_[a-z0-9]+_[0-9a-f]{8}$/);
		assert.equal(new URL(db.url).pathname, `/${db.name}`);
		const [row] = await db.sql`select ${"it's"} as text, 1::int2 as small, 2::int4 as int, 3::int8 as big, 9007199254740993::int8 as huge, 1.5::float8 as float, 2.25::numeric as decimal, true as yes, null as nothing, ${{ a: [1] }}::jsonb as json, now() as at`;
		assert.deepEqual({ ...row, at: typeof row.at }, { text: "it's", small: 1, int: 2, big: 3, huge: 9007199254740993n, float: 1.5, decimal: 2.25, yes: true, nothing: null, json: { a: [1] }, at: "string" });
		assert.deepEqual(await db.query("create table notes (id serial primary key, body text not null); insert into notes (body) values ('one'), ('two')"), [], "statements without rows");
		assert.deepEqual(await db.query("select body from notes order by id"), [{ body: "one" }, { body: "two" }]);
		await assert.rejects(db.query("select * from nowhere"), /relation "nowhere" does not exist \[42P01\]\n {2}in: select \* from nowhere/);
		assert.deepEqual(await db.query("select 1 as still"), [{ still: 1 }], "the connection goes on after an error");
		const many = await Promise.all(Array.from({ length: 20 }, (_, i) => db.sql`select ${i}::int as i`));
		assert.deepEqual(many.map(([{ i }]) => i), Array.from({ length: 20 }, (_, i) => i), "queries at once run one at a time, in order");
		// Another test's database, a copy of this one.
		await db.close();
		const copy = await testDatabase(url, { template: db.name });
		try {
			assert.deepEqual(await copy.query("select count(*)::int as n from notes"), [{ n: 2 }]);
		} finally {
			await copy.drop();
		}
	} finally {
		await db.drop();
	}
	const admin = await connect(url);
	try {
		assert.deepEqual(await admin.sql`select count(*)::int as n from pg_database where datname = ${db.name}`, [{ n: 0 }], "dropped");
	} finally {
		await admin.close();
	}
});

test("postgres: a wrong password is Postgres's refusal, not a hang", { skip }, async () => {
	const wrong = new URL(url);
	wrong.password = "not-the-password";
	await assert.rejects(connect(wrong.toString()), /Postgres refused: password authentication failed/);
});
