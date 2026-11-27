// packages/headless: the CLI platform's WebSocket client (cli/host/src/websocket.rs's unit tests),
// and the package's checks (main.roc beside this file), a Roc program on the CLI platform that
// drives Chromium's headless shell and exits 1 on the first check that fails, saying what it found.
// Without Chromium they skip; in CI (or with ROCX_BROWSERS=required) that is an error instead.
// Run it with `node --test 'packages/headless/test/*.test.mjs'`.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildCliHost, hasRust, hostUnitTests, roc, root } from "../../../server/build.mjs";
import { findChrome } from "../../../web/test/browser.mjs";

const here = dirname(fileURLToPath(import.meta.url));

test("the CLI platform's WebSocket: frames, replies by id, events in order, closing", (t) => {
	if (!hasRust()) return t.skip("no Rust");
	const dir = mkdtempSync(join(tmpdir(), "rocx-websocket-"));
	try {
		const ran = hostUnitTests("websocket.rs", join(dir, "websocket-unit-tests"), join(root, "cli", "host"));
		assert.equal(ran.status, 0, `${ran.stdout}${ran.stderr}`);
		assert.match(ran.stdout, /test result: ok\. \d+ passed/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a page used from Roc: going, running JavaScript, clicks, typing, keys, errors, photographs", (t) => {
	const chrome = findChrome();
	if (!chrome) return t.skip("no Chromium headless shell");
	buildCliHost();
	const dir = mkdtempSync(join(tmpdir(), "rocx-headless-"));
	try {
		const program = join(dir, "headless-checks");
		const built = spawnSync(roc(), ["build", `--output=${program}`, join(here, "main.roc")], { encoding: "utf8" });
		// 2: warnings alone, which the checks don't have either.
		assert.equal(built.status, 0, `${built.stdout}${built.stderr}`);
		const ran = spawnSync(program, [], { encoding: "utf8", env: { ...process.env, CHROME: chrome }, timeout: 60_000 });
		assert.equal(ran.status, 0, `${ran.stdout}${ran.stderr}`);
		assert.match(ran.stdout, /every check passed/);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
