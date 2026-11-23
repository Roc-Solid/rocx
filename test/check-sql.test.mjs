// `rocx check --sql` (D-058), end to end: test/sql-check, a SQLite app whose statements and rows
// are right or wrong on purpose, built and checked, on SQLite and on Turso; the server's Postgres
// test app, whose wrong statements are its tests of what fails; an app with no SQL needs no
// server. rocx's own scan, row types and report are tested by its expects (rocx-cli/Sql.roc),
// packages/dbcheck's rules by its own, the server's `--describe-sql` by server/test.
//
// Needs the toolchain (`just setup`: Roc, and Rust for the host); Postgres (DATABASE_URL) for one.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { hasRust, roc, root, rocxBinary } from "../server/build.mjs";

let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)");
const skipDb = skip || (!process.env.DATABASE_URL && "no DATABASE_URL (`just db` starts a Postgres)");

/** `rocx check --sql` with `args`, from the repo, DATABASE_URL unset unless `environment` sets it:
 * its exit code, stdout and stderr. */
function check(args, environment = {}) {
	const env = { ...process.env, ROC: roc() };
	delete env.DATABASE_URL;
	Object.assign(env, environment);
	const ran = spawnSync(rocxBinary(), ["check", "--sql", ...args], { cwd: root, env, encoding: "utf8" });
	return { status: ran.status, out: ran.stdout, err: ran.stderr };
}

test("rocx check --sql: each statement the engine refuses, each call whose parameters don't match it, and each row that doesn't fit its columns (a field the statement lacks, a type its values can't decode into, a nullable column read as a plain value), at its line; what isn't checked counted, and listed with --verbose; exit 1", { skip }, () => {
	const { status, out } = check([join("test", "sql-check"), "--verbose"]);
	assert.equal(status, 1, out);
	assert.deepEqual(out.trimEnd().split("\n"), [
		"test/sql-check/Store.roc:29:15: SQLite refuses it: no such column: bodyy in select bodyy as body from notes at offset 7",
		"test/sql-check/Store.roc:33:16: parameter $2 is given, and the statement doesn't use it",
		"test/sql-check/Store.roc:50:10: `body` is read as an integer, and notes.body is a TEXT (text)",
		"test/sql-check/Store.roc:58:10: `note` is read as a plain value, and notes.note may be null (it has no `not null`): read it as Db.Nullable(…)",
		"test/sql-check/Store.roc:66:10: `title` isn't a column the statement returns (it returns id)",
		"test/sql-check/Store.roc:37:16: not checked: Db.unchecked",
		"test/sql-check/Store.roc:72:22: not checked: its SQL is interpolated",
		"rocx check --sql: 7 statements checked on SQLite (the rows of 5 against their records): 5 problems, 2 calls not checked (--verbose lists them)",
	]);
});

test("rocx check --sql --engine turso: a SQLite app's statements on Turso, which says it its own way", { skip }, () => {
	const { status, out } = check([join("test", "sql-check"), "--engine", "turso"]);
	assert.equal(status, 1, out);
	const lines = out.trimEnd().split("\n");
	assert.match(lines[0], /^test\/sql-check\/Store\.roc:29:15: Turso refuses it: .*bodyy/);
	assert.equal(lines.at(-1), "rocx check --sql: 7 statements checked on Turso (the rows of 5 against their records): 5 problems, 2 calls not checked (--verbose lists them)");
});

test("rocx check --sql on Postgres: the server's test app, on a scratch database made beside DATABASE_URL, finds exactly the statements its tests make fail on purpose; its other rows fit", { skip: skipDb }, () => {
	const { status, out, err } = check([join("server", "test", "app")], { DATABASE_URL: process.env.DATABASE_URL, FIXTURE_KEY: "set" });
	assert.equal(status, 1, out + err);
	assert.deepEqual(out.trimEnd().split("\n"), [
		"server/test/app/main.roc:123:11: Postgres refuses it: 42725: function unnest(unknown) is not unique",
		"server/test/app/main.roc:371:12: `maybe` isn't a column the statement returns (it returns maybe?)",
		'server/test/app/main.roc:404:10: Postgres refuses it: 42P01: relation "nowhere" does not exist',
		'server/test/app/main.roc:452:10: Postgres refuses it: 42P01: relation "nowhere" does not exist',
		'server/test/app/main.roc:520:11: Postgres refuses it: 42P01: relation "nowhere" does not exist',
		'server/test/app/main.roc:524:17: Postgres refuses it: 42P01: relation "nowhere" does not exist',
		"rocx check --sql: 42 statements checked on Postgres (the rows of 21 against their records): 6 problems",
	]);
});

test("rocx dev's check (rocx check --sql --server --quiet): the server it built, none built again; what is wrong said the same; an app with no SQL says nothing", { skip }, () => {
	const run = (args) => spawnSync(rocxBinary(), ["check", "--sql", ...args], { cwd: root, env: { ...process.env, ROC: roc(), DATABASE_URL: "" }, encoding: "utf8" });
	// The first test built test/sql-check's server.
	const built = join(root, "test", "sql-check", "build", "sql", "server");
	const checked = run([join("test", "sql-check"), "--server", built, "--quiet"]);
	assert.equal(checked.status, 1, checked.stderr);
	assert.equal(checked.stdout.trimEnd().split("\n").at(-1), "rocx check --sql: 7 statements checked on SQLite (the rows of 5 against their records): 5 problems, 2 calls not checked (--verbose lists them)");
	assert.doesNotMatch(checked.stdout + checked.stderr, /building/);
	const quiet = run([join("examples", "hello"), "--quiet"]);
	assert.equal(quiet.status, 0, quiet.stderr);
	assert.equal(quiet.stdout + quiet.stderr, "");
});

test("rocx check --sql: an app with no SQL is fine, and builds nothing", { skip }, () => {
	const { status, out, err } = check([join("examples", "hello")]);
	assert.equal(status, 0, out + err);
	assert.equal(out.trimEnd(), "rocx check --sql: no statements to check");
	assert.doesNotMatch(err, /building/);
});

test("rocx check --sql: a directory with no main.roc is refused, saying what to give", { skip }, () => {
	const { status, err } = check(["test"]);
	assert.equal(status, 2);
	assert.match(err, /test has no main\.roc: give the app's directory/);
});
