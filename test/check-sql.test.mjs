// `rocx check --sql` (D-058), end to end: test/sql-check, a SQLite app whose statements are right
// or wrong on purpose, built and checked, on SQLite and on Turso; an app with no SQL needs no
// server. rocx's own scan and report are tested by its expects (rocx-cli/Sql.roc), the server's
// `--describe-sql` by server/test.
//
// Needs the toolchain (`just setup`: Roc, and Rust for the host); no database server.
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

/** `rocx check --sql` with `args`, from the repo: its exit code and its lines (stdout, then stderr). */
function check(...args) {
	const env = { ...process.env, ROC: roc() };
	delete env.DATABASE_URL;
	const ran = spawnSync(rocxBinary(), ["check", "--sql", ...args], { cwd: root, env, encoding: "utf8" });
	return { status: ran.status, out: ran.stdout, err: ran.stderr };
}

test("rocx check --sql: each statement the engine refuses and each call whose parameters don't match it, at its line; what isn't checked counted, and listed with --verbose; exit 1", { skip }, () => {
	const { status, out } = check(join("test", "sql-check"), "--verbose");
	assert.equal(status, 1, out);
	assert.deepEqual(out.trimEnd().split("\n"), [
		"test/sql-check/Store.roc:25:15: SQLite refuses it: no such column: bodyy in select bodyy as body from notes at offset 7",
		"test/sql-check/Store.roc:29:16: parameter $2 is given, and the statement doesn't use it",
		"test/sql-check/Store.roc:33:16: not checked: Db.unchecked",
		"test/sql-check/Store.roc:37:22: not checked: its SQL is interpolated",
		"rocx check --sql: 3 statements checked on SQLite: 2 problems, 2 calls not checked (--verbose lists them)",
	]);
});

test("rocx check --sql --engine turso: a SQLite app's statements on Turso, which says it its own way", { skip }, () => {
	const { status, out } = check(join("test", "sql-check"), "--engine", "turso");
	assert.equal(status, 1, out);
	const lines = out.trimEnd().split("\n");
	assert.match(lines[0], /^test\/sql-check\/Store\.roc:25:15: Turso refuses it: .*bodyy/);
	assert.equal(lines.at(-1), "rocx check --sql: 3 statements checked on Turso: 2 problems, 2 calls not checked (--verbose lists them)");
});

test("rocx check --sql: an app with no SQL is fine, and builds nothing", { skip }, () => {
	const { status, out, err } = check(join("examples", "hello"));
	assert.equal(status, 0, out + err);
	assert.equal(out.trimEnd(), "rocx check --sql: no statements to check");
	assert.doesNotMatch(err, /building/);
});

test("rocx check --sql: a directory with no main.roc is refused, saying what to give", { skip }, () => {
	const { status, err } = check("test");
	assert.equal(status, 2);
	assert.match(err, /test has no main\.roc: give the app's directory/);
});
