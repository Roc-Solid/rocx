// The app's context (`program.init!`, server/test/context): made once when the server starts,
// kept by the host for as long as it runs, and handed to every call that runs the app's code, which
// shares it (one reference more a call, let go of as the call ends). It is made once; every request
// sees all of it, many at once and across a pause; a crash after reading it leaves it whole and
// nothing held; a stream reads it after its request has ended; a job, an actor's turn and a
// plugin's call, loop, start and check are each given it; an actor `init!` asks is refused, saying
// why (the context isn't made yet), and the server starts; and an `Err` from `init!` stops the
// server, saying why.
//
// ROCX_TEST_OPT=speed builds the app optimized (`--opt=speed`) instead.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildApp, buildHost, hasRust, roc, root } from "../build.mjs";

let hasRoc = true;
try {
	roc();
} catch {
	hasRoc = false;
}
const skip = (!hasRoc && "no roc (run `just setup`, or set ROC)") || (!hasRust() && "no Rust (run `just setup`)");

let dir;
let app;
let server;

/** Starts the app with `context` as its `--context-file`; resolves when it listens, or rejects with
 * its log when it exits first. */
function start(context) {
	const file = join(dir, `context-${Math.random().toString(36).slice(2)}.txt`);
	writeFileSync(file, context);
	const child = spawn(app, ["--port", "0", "--debug", "--context-file", file, "--database-url", `sqlite:${join(dir, `${Math.random().toString(36).slice(2)}.db`)}`], { stdio: ["ignore", "ignore", "pipe"], env: { ...process.env, ROCX_LOG: "" } });
	let logged = "";
	return new Promise((resolve, reject) => {
		child.stderr.on("data", (chunk) => {
			logged += chunk;
			const match = /rocx server: (http:\/\/\S+) /.exec(logged);
			if (match)
				resolve({
					url: match[1],
					logged: () => logged,
					text: async (path) => (await fetch(`${match[1]}${path}`)).text(),
					get: (path) => fetch(`${match[1]}${path}`),
					stop: () => new Promise((done) => (child.exitCode !== null ? done(child.exitCode) : (child.once("exit", done), child.kill("SIGTERM")))),
				});
		});
		child.on("exit", (code) => reject(Object.assign(new Error(`the server exited (${code})`), { code, logged })));
	});
}

/** Waits until `check()` is true (or `ms` pass): whether it was. */
async function until(check, ms = 5000) {
	const end = Date.now() + ms;
	while (Date.now() < end) {
		if (await check()) return true;
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
	return check();
}

const allocations = async () => Number(await server.text("/__rocx/allocations"));

/** What every request answers: the context, read whole. */
let expected;

before(async () => {
	if (skip) return;
	dir = mkdtempSync(join(tmpdir(), "rocx-context-"));
	app = join(dir, "app");
	buildHost();
	buildApp(join(root, "server", "test", "context", "main.roc"), app, { opt: process.env.ROCX_TEST_OPT ?? "dev" });
	server = await start("facts=yes");
	expected = await server.text("/context");
});

after(async () => {
	await server?.stop();
	if (dir) rmSync(dir, { recursive: true, force: true });
});

test("init! runs once, and every request sees all of what it made", { skip }, async () => {
	const [started, madeAt, count, last, label, sizes, greeting] = expected.split("|");
	assert.equal(started, "facts=yes", "the text of --context-file");
	assert.match(madeAt, /^\d+$/, "when it was made");
	assert.equal(count, "1000", "the list, whole");
	assert.equal(last, "word 999");
	assert.equal(label, "nested in facts=yes", "the record inside it");
	assert.equal(sizes, "3");
	assert.equal(greeting, "hello, you, from facts=yes", "the function in it, with what it captured");
	for (let each = 0; each < 50; each++) assert.equal(await server.text("/context"), expected, "the same context each time: made once");
	assert.equal(server.logged().match(/context made/g)?.length, 1, "init! ran once");
});

test("many requests at once, some pausing on the way, share it", { skip }, async () => {
	const paths = Array.from({ length: 400 }, (_, index) => (index % 3 === 0 ? "/slow" : "/context"));
	const answers = await Promise.all(paths.map((path) => server.text(path)));
	assert.deepEqual(new Set(answers), new Set([expected]), "every one saw the same context, whole");
});

test("a crash after reading it leaves it whole, and nothing held", { skip }, async () => {
	await until(async () => (await allocations()) === (await allocations()));
	const settled = await allocations();
	for (let each = 0; each < 50; each++) assert.equal((await server.get("/crash")).status, 500);
	assert.equal(await server.text("/context"), expected, "still whole after 50 crashes");
	assert.equal(await until(async () => (await allocations()) === settled), true, `every call let go of what it made: ${await allocations()} allocations, ${settled} before`);
});

test("a stream reads it after its request has ended", { skip }, async () => {
	const settled = await allocations();
	assert.equal(
		await server.text("/stream"),
		"data: word 0 hello, stream, from facts=yes\n\ndata: word 1 hello, stream, from facts=yes\n\ndata: word 2 hello, stream, from facts=yes\n\nevent: end\ndata: \n\n",
		"three events, each read from the context, then the stream's end",
	);
	assert.equal(await until(async () => (await allocations()) === settled), true, `the stream let go of what it held: ${await allocations()} allocations, ${settled} before`);
});

test("a job, an actor's turn, and a plugin's call, loop, start and check are each given it", { skip }, async () => {
	assert.equal(await server.text("/call"), "a call saw facts=yes", "the plugin's call");
	assert.equal(await server.text("/actor"), "the actor a key saw facts=yes", "an actor's turn");
	assert.equal(await server.text("/saw?start"), "the start saw facts=yes", "the plugin's start");
	assert.equal(await until(async () => (await server.text("/saw?loop")) !== ""), true, "the plugin's loop ran");
	assert.equal(await server.text("/saw?loop"), "the loop saw facts=yes", "the plugin's loop");
	assert.equal((await server.get("/job")).status, 202);
	assert.equal(await until(async () => (await server.text("/saw?job")) !== ""), true, "the job ran");
	assert.equal(await server.text("/saw?job"), "job saw facts=yes", "a job");
	assert.equal(await until(async () => server.logged().includes("the check saw facts=yes")), true, "the plugin's check, logged");
});

test("an actor init! asks is refused, saying why, and the server starts", { skip }, async () => {
	assert.match(await server.text("/asked-in-init"), /^refused: .*the app's context isn't made yet: its init! is still running/);
});

test("an Err from init! stops the server, saying why", { skip }, async () => {
	const failed = await start("fail").then(
		async (other) => {
			await other.stop();
			return null;
		},
		(error) => error,
	);
	assert.ok(failed, "the server didn't start");
	assert.notEqual(failed.code, 0);
	assert.match(failed.logged, /told to fail by --context-file/);
});
