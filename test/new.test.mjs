// `rocx new` from this clone (D-078): an app made from templates/app/ in a directory of the test's
// own, its placeholders filled in for each database, its `.rocx` linked to the clone (a clone has
// no version to pin, so no `.rocx-version`), checked by rocx (`rocx check`, `rocx check --sql`,
// `rocx test`); the database asked for at no terminal (SQLite, said); and what it refuses: a
// directory with something in it, a database it doesn't know, no directory. An install's `rocx new`
// is in install.test.mjs.
//
// Needs the toolchain (`just setup`) and both hosts built (`just server-host`, `just web-host`).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { nativeTarget, roc, root, rocxBinary } from "../server/build.mjs";

const hosts = [join(root, "server", "platform", "targets", nativeTarget(), "libhost.a"), join(root, "web", "platform", "targets", "wasm32", "host.wasm")];
let compiler = null;
try {
	compiler = roc();
} catch {}
const skip = (!compiler && "no roc (run `just setup`, or set ROC)") || (!hosts.every(existsSync) && "the hosts aren't built (just server-host, just web-host)");

let work;

/** rocx (this clone's) with `args` in `cwd`, stdin not a terminal: its exit code and what it said. */
function rocx(args, cwd = work) {
	const ran = spawnSync(rocxBinary(), args, { cwd, encoding: "utf8", input: "", maxBuffer: 1 << 28, env: { ...process.env, NO_COLOR: "1" } });
	return { code: ran.status, said: `${ran.stdout}${ran.stderr}` };
}

before(() => {
	if (!skip) work = realpathSync(mkdtempSync(join(tmpdir(), "rocx-new-")));
});

after(() => {
	if (work) rmSync(work, { recursive: true, force: true });
});

test("rocx new from a clone: the template filled in, .rocx linked to the clone; it checks, its SQL checks, its expects pass", { skip }, () => {
	const made = rocx(["new", "Acme-Books", "--db", "sqlite"]);
	assert.equal(made.code, 0, made.said);
	assert.match(made.said, /✓ Acme-Books\/ made from the template/);
	assert.match(made.said, /✓ on this clone of rocx \(\.rocx links to it\)/);
	const app = join(work, "Acme-Books");
	assert.equal(realpathSync(join(app, ".rocx")), realpathSync(root));
	assert.ok(!existsSync(join(app, ".rocx-version")), "a clone pins no version");
	const main = readFileSync(join(app, "main.roc"), "utf8");
	assert.match(main, /"acme_books_session"/);
	assert.match(main, /auth: "\.\/\.rocx\/packages\/auth\/main\.roc"/);
	assert.match(readFileSync(join(app, "README.md"), "utf8"), /Acme books/);
	// rocx's rules for coding agents (D-108): AGENTS.md with rocx's block, CLAUDE.md importing it.
	assert.match(made.said, /✓ AGENTS\.md and CLAUDE\.md: rocx's rules for coding agents/);
	const agents = readFileSync(join(app, "AGENTS.md"), "utf8");
	assert.ok(agents.includes(readFileSync(join(root, "agents", "block.md"), "utf8")), "the block's text");
	assert.match(agents, /<!-- rocx:start [0-9a-f]{16} /);
	assert.equal(readFileSync(join(app, "CLAUDE.md"), "utf8"), "@AGENTS.md\n");
	for (const [args, what] of [[["check", app], "rocx check"], [["check", "--sql", app], "rocx check --sql"], [["test", app], "rocx test"]]) {
		const ran = rocx(args);
		assert.equal(ran.code, 0, `${what}: ${ran.said}`);
		assert.doesNotMatch(ran.said, /AGENTS\.md/, `${what}: the block is this rocx's`);
	}
	// A block of another rocx: rocx check says so, and still passes.
	const old = "old rules\n";
	const print = createHash("sha256").update(old).digest("hex").slice(0, 16);
	writeFileSync(join(app, "AGENTS.md"), agents.replace(/<!-- rocx:start [\s\S]*<!-- rocx:end -->/, `<!-- rocx:start ${print} · an older rocx's -->\n${old}<!-- rocx:end -->`));
	const stale = rocx(["check", app]);
	assert.equal(stale.code, 0, stale.said);
	assert.match(stale.said, /AGENTS\.md's rocx block is from another version of rocx: rocx agents rewrites it/);
});

test("rocx new: each database's line in main.roc; at no terminal, SQLite, said", { skip }, () => {
	for (const [db, line] of [["postgres", "database: Postgres,"], ["turso", 'database: Turso("data/app.db"),']]) {
		const made = rocx(["new", `on-${db}`, "--db", db]);
		assert.equal(made.code, 0, made.said);
		assert.ok(readFileSync(join(work, `on-${db}`, "main.roc"), "utf8").includes(line), `${db}: ${line}`);
	}
	const asked = rocx(["new", "asked"]);
	assert.equal(asked.code, 0, asked.said);
	assert.match(asked.said, /no terminal to ask at, so SQLite/);
	assert.ok(readFileSync(join(work, "asked", "main.roc"), "utf8").includes('database: Sqlite("data/app.db"),'));
});

test("rocx new refuses a directory with something in it, a database it doesn't know, and no directory", { skip }, () => {
	mkdirSync(join(work, "full"), { recursive: true });
	writeFileSync(join(work, "full", "notes.txt"), "mine\n");
	const full = rocx(["new", "full"]);
	assert.equal(full.code, 1, full.said);
	assert.match(full.said, /isn't empty/);
	assert.deepEqual(readFileSync(join(work, "full", "notes.txt"), "utf8"), "mine\n", "left as it was");
	const unknown = rocx(["new", "x", "--db", "mysql"]);
	assert.equal(unknown.code, 1, unknown.said);
	assert.match(unknown.said, /--db takes sqlite, postgres or turso/);
	const none = rocx(["new"]);
	assert.equal(none.code, 1, none.said);
	assert.match(none.said, /which directory/);
});
