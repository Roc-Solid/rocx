// `rocx agents [dir] [--force]` (D-108): rocx's rules for coding agents in an app's AGENTS.md, a block
// between two markers. It makes AGENTS.md (and a CLAUDE.md importing it) where there is none, adds
// the block to an AGENTS.md of the app's own, keeps everything outside the markers, brings a block of
// another rocx up to date, does nothing when it is current, and refuses a block someone edited unless
// given --force. No app is built: the command reads and writes two files.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { roc, root, rocxBinary } from "../server/build.mjs";

let compiler = null;
try {
	compiler = roc();
} catch {}
const skip = !compiler && "no roc (run `just setup`, or set ROC)";

let work;
before(() => {
	if (!skip) work = mkdtempSync(join(tmpdir(), "rocx-agents-"));
});
after(() => {
	if (work) rmSync(work, { recursive: true, force: true });
});

/** `rocx agents` on `dir`: its exit code and what it said. */
function agents(dir, ...args) {
	const ran = spawnSync(rocxBinary(), ["agents", dir, ...args], { encoding: "utf8", env: { ...process.env, NO_COLOR: "1" } });
	return { code: ran.status, said: `${ran.stdout}${ran.stderr}` };
}

/** The block as an older rocx wrote it: its text, and that text's fingerprint in the marker. */
function older(text) {
	const print = createHash("sha256").update(text).digest("hex").slice(0, 16);
	return `<!-- rocx:start ${print} · an older rocx's -->\n${text}<!-- rocx:end -->\n`;
}

const block = () => readFileSync(join(root, "agents", "block.md"), "utf8");
const read = (dir, name) => readFileSync(join(dir, name), "utf8");

test("rocx agents: AGENTS.md and CLAUDE.md where there are none; again, nothing to do", { skip }, () => {
	const dir = mkdtempSync(join(work, "new-"));
	const made = agents(dir);
	assert.equal(made.code, 0, made.said);
	assert.match(made.said, /✓ AGENTS\.md made, with rocx's block/);
	assert.match(made.said, /✓ CLAUDE\.md made: it imports AGENTS\.md, for Claude Code/);
	const file = read(dir, "AGENTS.md");
	assert.match(file, /^# AGENTS\.md\n/);
	assert.ok(file.includes(`-->\n${block()}<!-- rocx:end -->\n`), "the block's text, between its markers");
	const print = /<!-- rocx:start ([0-9a-f]{16}) /.exec(file)[1];
	assert.equal(print, createHash("sha256").update(block()).digest("hex").slice(0, 16), "its fingerprint, the text's SHA-256");
	assert.equal(read(dir, "CLAUDE.md"), "@AGENTS.md\n");

	const again = agents(dir);
	assert.equal(again.code, 0, again.said);
	assert.match(again.said, /AGENTS\.md: rocx's block is up to date/);
	assert.equal(read(dir, "AGENTS.md"), file, "unchanged");
});

test("rocx agents: the block added to the app's own AGENTS.md; a CLAUDE.md of its own kept, with a hint", { skip }, () => {
	const dir = mkdtempSync(join(work, "own-"));
	writeFileSync(join(dir, "AGENTS.md"), "# Shop\n\nPrices are in cents.\n");
	writeFileSync(join(dir, "CLAUDE.md"), "Be brief.\n");
	const ran = agents(dir);
	assert.equal(ran.code, 0, ran.said);
	assert.match(ran.said, /AGENTS\.md: rocx's block added at its end/);
	assert.match(ran.said, /! CLAUDE\.md doesn't name AGENTS\.md: a line `@AGENTS\.md` in it has Claude Code read it/);
	const file = read(dir, "AGENTS.md");
	assert.ok(file.startsWith("# Shop\n\nPrices are in cents.\n\n<!-- rocx:start "), file);
	assert.ok(file.endsWith(`${block()}<!-- rocx:end -->\n`));
	assert.equal(read(dir, "CLAUDE.md"), "Be brief.\n", "a CLAUDE.md of the app's own is never changed");
});

test("rocx agents: a block of another rocx brought up to date, the notes around it kept", { skip }, () => {
	const dir = mkdtempSync(join(work, "stale-"));
	writeFileSync(join(dir, "AGENTS.md"), `# Shop\n\nBefore.\n\n${older("old rules\n")}\nAfter: our deploy notes.\n`);
	const ran = agents(dir);
	assert.equal(ran.code, 0, ran.said);
	assert.match(ran.said, /AGENTS\.md: rocx's block brought up to date/);
	const file = read(dir, "AGENTS.md");
	assert.ok(file.startsWith("# Shop\n\nBefore.\n\n<!-- rocx:start "), file);
	assert.ok(file.endsWith(`${block()}<!-- rocx:end -->\n\nAfter: our deploy notes.\n`), file);
	assert.ok(!file.includes("old rules"));
});

test("rocx agents: a block someone edited is refused, and replaced with --force", { skip }, () => {
	const dir = mkdtempSync(join(work, "edited-"));
	assert.equal(agents(dir).code, 0);
	const edited = read(dir, "AGENTS.md").replace("The rules that matter most:", "The rules that matter most, and ours:");
	writeFileSync(join(dir, "AGENTS.md"), edited);
	const refused = agents(dir);
	assert.equal(refused.code, 1);
	assert.match(refused.said, /AGENTS\.md's rocx block was edited since rocx wrote it: move those notes outside the block and run rocx agents again, or rocx agents --force to replace it/);
	assert.equal(read(dir, "AGENTS.md"), edited, "nothing written");
	const forced = agents(dir, "--force");
	assert.equal(forced.code, 0, forced.said);
	assert.ok(!read(dir, "AGENTS.md").includes("and ours"));

	writeFileSync(join(dir, "AGENTS.md"), "# Shop\n\n<!-- rocx:start 0123456789abcdef -->\nhalf a block\n");
	const unclosed = agents(dir);
	assert.equal(unclosed.code, 1);
	assert.match(unclosed.said, /AGENTS\.md has rocx's start marker and no <!-- rocx:end --> after it/);
});

test("rocx agents: its words", { skip }, () => {
	const wrong = agents(join(work, "nowhere"));
	assert.equal(wrong.code, 1);
	assert.match(wrong.said, /rocx agents: no directory/);
	const help = spawnSync(rocxBinary(), ["help", "agents"], { encoding: "utf8", env: { ...process.env, NO_COLOR: "1" } });
	assert.match(help.stdout, /rocx agents \[dir\] \[--force\]/);
});
