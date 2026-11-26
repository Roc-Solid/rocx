// A wrong post is refused when the app is built: a copy of the journal, with one post broken at a
// time, is built (`rocx build`) and checked (`roc check`), which evaluates `Posts.all` and so the
// content rules. A field the frontmatter's type requires, missing; then rules the type can't say
// (an unknown writer, a date that isn't a day, a tag that isn't a slug), all reported at once.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { repo, serverBuild } from "../../../packages/testing/index.mjs";
import { dir } from "./journal.mjs";

let copy;
let tools;
before(async () => {
	const { roc, rocxBinary } = await serverBuild();
	tools = { roc: roc(), rocx: rocxBinary() };
	copy = realpathSync(mkdtempSync(join(tmpdir(), "journal-content-")));
	cpSync(dir, copy, { recursive: true, filter: (path) => !/\/(build|Generated|node_modules)$/.test(path) });
	// The header names the packages and the platform by paths from the app: from the copy's place now.
	const main = join(copy, "main.roc");
	const from = (path) => relative(copy, realpathSync(join(repo, path)));
	writeFileSync(main, readFileSync(main, "utf8").replace(/"\.\.\/\.\.\/((?:packages|server)\/[^"]+)"/g, (_, path) => `"${from(path)}"`));
});
after(() => copy && rmSync(copy, { recursive: true, force: true }));

/** Builds and checks the copy: its exit status and what it said. */
function check() {
	const built = spawnSync(tools.rocx, ["generate", copy], { encoding: "utf8", env: { ...process.env, ROC: tools.roc } });
	if (built.status !== 0) return { status: built.status, said: built.stdout + built.stderr };
	const checked = spawnSync(tools.roc, ["check", join(copy, "main.roc")], { encoding: "utf8" });
	return { status: checked.status, said: checked.stdout + checked.stderr };
}

/** `content/<path>` with `change` made to it, for `body`; then as it was. */
function broken(path, change, body) {
	const file = join(copy, "content", path);
	const was = readFileSync(file, "utf8");
	writeFileSync(file, change(was));
	try {
		return body();
	} finally {
		writeFileSync(file, was);
	}
}

test("the journal's content, as it is, builds", () => {
	const { status, said } = check();
	assert.equal(status, 0, said);
});

test("a post missing a field its frontmatter needs fails the build, naming the file and the field", () => {
	const { status, said } = broken("en/rain-sounds.md", (text) => text.replace(/^summary: .*\n/m, ""), check);
	assert.notEqual(status, 0);
	assert.match(said, /compile time crash/);
	assert.match(said, /content\/en\/rain-sounds: summary/);
});

test("a post breaking the content rules fails the build, with every problem listed", () => {
	const wrong = (text) => text.replace(/^author: .*$/m, "author: nobody").replace(/^date: .*$/m, "date: 2026-02-30").replace(/^tags: .*$/m, "tags: [Night Trains]");
	const { status, said } = broken("pl/night-trains.md", wrong, check);
	assert.notEqual(status, 0);
	const flat = said.replace(/\s+/g, " ");
	assert.match(flat, /content\/pl\/night-trains\.md: date: "2026-02-30" isn't a day written YYYY-MM-DD/);
	assert.match(flat, /content\/pl\/night-trains\.md: author: no writer is called "nobody"/);
	assert.match(flat, /content\/pl\/night-trains\.md: tags: "Night Trains" isn't a slug/);
	assert.match(flat, /content\/pl\/night-trains\.md: a translation of content\/en\/night-trains\.md by another writer/);
});

test("a footnote referred to but never written fails the build", () => {
	const { status, said } = broken("en/json-by-hand.md", (text) => text.replace("[^postcard]: ", "[^post-card]: "), check);
	assert.notEqual(status, 0);
	const flat = said.replace(/\s+/g, " ");
	assert.match(flat, /content\/en\/json-by-hand\.md: \[\^postcard\] refers to a note that isn't there/);
	assert.match(flat, /content\/en\/json-by-hand\.md: \[\^post-card\] is a note nothing refers to/);
});
