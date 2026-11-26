// `.env` (D-088): the server reads the file in the directory it starts in, or the one
// `--env-file` names, into its environment before anything else starts, so `Env.var!` sees it
// (server/test/envfile, an app that answers `GET /env/<NAME>`). A variable the environment has
// keeps its value; the log names what was set and kept, never a value; a line that isn't a setting,
// or a named file that isn't there, stops the server, saying which. And the parser's own tests
// (`dotenv.rs`).
//
// ROCX_TEST_OPT=speed builds the app optimized (`--opt=speed`) instead.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp, buildHost, hasRust, hostUnitTests, roc, root } from "../build.mjs";

let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)");

let dir;
let app;

/** A directory of its own with `files` in it, to start the server in. */
function place(files) {
	const at = mkdtempSync(join(dir, "start-"));
	for (const [name, text] of Object.entries(files)) writeFileSync(join(at, name), text);
	mkdirSync(join(at, "data"), { recursive: true });
	return at;
}

/** Starts the app in `cwd` with `flags` and `env` (beside the test's own, without the names the
 * tests use); resolves when it listens, or with its exit code and log when it stops first. */
function start(cwd, { flags = [], env = {} } = {}) {
	const inherited = { ...process.env };
	for (const name of ["ENVFILE_ONE", "ENVFILE_TWO", "ENVFILE_QUOTED", "ENVFILE_KEPT", "ENVFILE_NAMED", "ROCX_ENV_FILE"]) delete inherited[name];
	const child = spawn(app, ["--port", "0", ...flags], { cwd, stdio: ["ignore", "ignore", "pipe"], env: { ...inherited, ROCX_LOG: "json", ...env } });
	let logged = "";
	return new Promise((resolve) => {
		child.stderr.on("data", (chunk) => {
			logged += chunk;
			const match = /rocx server: (http:\/\/\S+) /.exec(logged);
			if (match)
				resolve({
					url: match[1],
					logged: () => logged,
					env: async (name) => (await fetch(`${match[1]}/env/${name}`)).text(),
					stop: () => new Promise((done) => (child.exitCode !== null ? done(child.exitCode) : (child.once("exit", done), child.kill("SIGTERM")))),
				});
		});
		child.on("exit", (code) => resolve({ exited: code, logged: () => logged }));
	});
}

/** The log's lines, parsed. */
const lines = (server) =>
	server
		.logged()
		.split("\n")
		.filter((line) => line.startsWith("{"))
		.map((line) => JSON.parse(line));

before(() => {
	if (skip) return;
	dir = mkdtempSync(join(tmpdir(), "rocx-envfile-"));
	app = join(dir, "app");
	buildHost();
	buildApp(join(root, "server", "test", "envfile", "main.roc"), app, { opt: process.env.ROCX_TEST_OPT ?? "dev" });
});

after(() => {
	if (dir) rmSync(dir, { recursive: true, force: true });
});

test("the parser: lines, comments, export, quotes, escapes, a name twice, what isn't a setting", { skip }, () => {
	const ran = hostUnitTests("dotenv.rs", join(dir, "dotenv-unit-tests"));
	assert.equal(ran.status, 0, ran.stdout + ran.stderr);
	assert.match(ran.stdout, /test result: ok\. 5 passed/);
});

test(".env where the server starts is in its environment; the environment's own value wins; the log names what it set and kept", { skip }, async () => {
	const cwd = place({ ".env": "# the app's settings\nENVFILE_ONE=from the file\nexport ENVFILE_TWO = two # a comment\nENVFILE_QUOTED=\"a \\\"quoted\\\" value\"\nENVFILE_KEPT=from the file\n" });
	const server = await start(cwd, { env: { ENVFILE_KEPT: "from the environment" } });
	try {
		assert.equal(server.exited, undefined, server.logged());
		assert.equal(await server.env("ENVFILE_ONE"), "from the file");
		assert.equal(await server.env("ENVFILE_TWO"), "two");
		assert.equal(await server.env("ENVFILE_QUOTED"), 'a "quoted" value');
		assert.equal(await server.env("ENVFILE_KEPT"), "from the environment");
		assert.equal(await server.env("ENVFILE_NOWHERE"), "(none)");
		const read = lines(server).find((line) => line.msg === "rocx server: settings read");
		assert.deepEqual({ file: read.file, set: read.set, kept: read.kept }, { file: ".env", set: "ENVFILE_ONE, ENVFILE_TWO, ENVFILE_QUOTED", kept: "ENVFILE_KEPT" });
		assert.ok(!server.logged().includes("from the file"), "never a value on the log");
	} finally {
		await server.stop();
	}
});

test("without a .env nothing is read, and nothing is said", { skip }, async () => {
	const server = await start(place({}));
	try {
		assert.equal(await server.env("ENVFILE_ONE"), "(none)");
		assert.ok(!lines(server).some((line) => line.msg === "rocx server: settings read"));
	} finally {
		await server.stop();
	}
});

test("--env-file names another file, read in place of .env", { skip }, async () => {
	const cwd = place({ ".env": "ENVFILE_ONE=from .env\n", "production.env": "ENVFILE_NAMED=from the named file\n" });
	const server = await start(cwd, { flags: ["--env-file", "production.env"] });
	try {
		assert.equal(await server.env("ENVFILE_NAMED"), "from the named file");
		assert.equal(await server.env("ENVFILE_ONE"), "(none)", ".env isn't read when a file is named");
	} finally {
		await server.stop();
	}
});

test("ROCX_ENV_FILE names the file when no flag does; set but empty, none is read (the tests' own servers)", { skip }, async () => {
	const cwd = place({ ".env": "ENVFILE_ONE=from .env\n", "staging.env": "ENVFILE_NAMED=from staging\n" });
	const named = await start(cwd, { env: { ROCX_ENV_FILE: "staging.env" } });
	try {
		assert.equal(await named.env("ENVFILE_NAMED"), "from staging");
		assert.equal(await named.env("ENVFILE_ONE"), "(none)");
	} finally {
		await named.stop();
	}
	const none = await start(cwd, { env: { ROCX_ENV_FILE: "" } });
	try {
		assert.equal(await none.env("ENVFILE_ONE"), "(none)", "a developer's .env doesn't reach a test's server");
		assert.ok(!lines(none).some((line) => line.msg === "rocx server: settings read"));
	} finally {
		await none.stop();
	}
});

test("the settings line is in the app's log format, as it is logged once the server listens", { skip }, async () => {
	const server = await start(place({ ".env": "ENVFILE_ONE=1\n" }), { env: { ROCX_LOG: "pretty" } });
	try {
		assert.match(server.logged(), /^\d\d:\d\d:\d\d INFO  rocx server: settings read/m, server.logged());
	} finally {
		await server.stop();
	}
});

test("a line that isn't a setting, or a named file that isn't there, stops the server, saying which", { skip }, async () => {
	const broken = await start(place({ ".env": "ENVFILE_ONE=1\nthis is not a setting\n" }));
	assert.equal(broken.exited, 2);
	assert.match(broken.logged(), /can't start.*\.env: line 2 isn't NAME=value/);
	const missing = await start(place({}), { flags: ["--env-file", "nowhere.env"] });
	assert.equal(missing.exited, 2);
	assert.match(missing.logged(), /can't start.*nowhere\.env: can't be read/);
});
