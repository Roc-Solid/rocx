// packages/video's example app in a browser: `<Player>` shows its poster frame as the server
// renders it, plays from the start once the page is live, pauses and plays from its button, and
// seeks with its scrubber, `<Sequence>` showing each scene in its stretch; the stories catalog lists
// the compositions; and `rocx render` films the same frames twice (a frame doesn't depend on how long
// it took), and writes MP4 and WebM files when there is ffmpeg.
// Run it with `node --test 'packages/video/example/test/*.test.mjs'`; ROCX_TEST_OPT=speed builds the
// server optimized (`--opt=speed`), as a release is.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, launchBrowser, startServer, testSqlite } from "../../../testing/index.mjs";
import { rocxBinary } from "../../../../server/build.mjs";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..");
let built;
let app;
let browser;
const db = testSqlite({ prefix: "rocx-video-" });
before(async () => {
	built = await buildForTests(dir, { dev: true });
	app = await startServer(built.server, { database: db.url, statics: built.statics });
	browser = await launchBrowser();
});
after(async () => {
	await browser?.close();
	await app?.stop();
});

/** The first player sought to `frame` through its scrubber, as the catalog and the renderer seek it
 * (a range input takes no typing). */
const seek = (tab, frame) => tab.page.eval(`(() => { const seek = document.querySelector(".video-seek"); seek.value = "${frame}"; seek.dispatchEvent(new Event("input", { bubbles: true })); })()`);

/** The first player's frame and whether it plays, as its element says. */
const state = (tab) => tab.page.eval(`(() => { const p = document.querySelector("[data-rocx-video]"); return { frame: Number(p.dataset.frame), playing: p.dataset.playing === "yes" }; })()`);

test("the server renders the poster frame: the last, every scene as it ends", async () => {
	const page = await app.client().get("/");
	assert.equal(page.status, 200);
	// The text as a reader reads it: without the runtime's markers around holes and parts.
	const html = page.text.replace(/<!--[^>]*-->/g, "");
	assert.match(html, /data-rocx-video=""/);
	assert.match(html, /data-frame="119"/);
	assert.match(html, /data-playing="no"/);
	// At 119 the title's stretch (0 to 79) is over, and the count's (from 40) shows its end.
	assert.doesNotMatch(html, /Acme Rockets/);
	assert.match(html, /1000 launches/);
});

test("live, it plays from the start, pauses and plays from its button, and seeks with its scrubber", async (t) => {
	if (!browser) return t.skip("no Chromium");
	const tab = await browser.open(`${app.url}/`);
	await tab.waitFor(async () => (await state(tab)).playing);
	const playing = await state(tab);
	assert.ok(playing.frame < 119, `it went back to the start: frame ${playing.frame}`);
	await (await tab.getByRole("button", { name: "Pause" })).click();
	const paused = await state(tab);
	assert.equal(paused.playing, false);
	await new Promise((resolve) => setTimeout(resolve, 200));
	assert.equal((await state(tab)).frame, paused.frame, "paused, the frame stays");
	// The scrubber: to frame 30, where the title is typed out and the count hasn't started.
	assert.ok(await tab.getByRole("slider", { name: "Position" }));
	await seek(tab, 30);
	await tab.waitFor(async () => (await state(tab)).frame === 30);
	assert.match(await tab.text(), /Acme Rockets/);
	assert.doesNotMatch(await tab.text(), /launches/);
	assert.match(await tab.text(), /0:01 \/ 0:04/);
	// To 100: the title's stretch is over, the count is in.
	await seek(tab, 100);
	await tab.waitFor(async () => (await state(tab)).frame === 100);
	assert.doesNotMatch(await tab.text(), /Acme Rockets/);
	assert.match(await tab.text(), /1000 launches/);
	await (await tab.getByRole("button", { name: "Play" })).click();
	await tab.waitFor(async () => (await state(tab)).frame !== 100);
	assert.deepEqual(tab.errors, []);
	await tab.close();
});

test("the stories catalog lists the compositions, and each story page has its player", async () => {
	const catalog = (await app.client().get("/__rocx/stories")).text;
	assert.match(catalog, /A bar to scrub/);
	assert.match(catalog, /Scaled, at 640 by 360/);
	const ids = [...catalog.matchAll(/"id":"([^"]+)"/g)].map((match) => match[1]);
	assert.ok(ids.length >= 3, `the catalog's stories: ${ids}`);
	for (const id of ids) {
		const story = await app.client().get(`/__rocx/stories/${id}`);
		assert.equal(story.status, 200, id);
		assert.match(story.text, /data-rocx-video/, id);
	}
});

/** `rocx render` run with `args` (the example's page first), to its end: its code and what it said. */
const render = (args) =>
	new Promise((resolve) => {
		const child = spawn(rocxBinary(), ["render", `${app.url}/`, ...args], { stdio: ["ignore", "pipe", "pipe"] });
		let stdout = "";
		let stderr = "";
		child.stdout.on("data", (chunk) => (stdout += chunk));
		child.stderr.on("data", (chunk) => (stderr += chunk));
		child.on("close", (code) => resolve({ code, stdout, stderr }));
	});

/** Each PNG in `dir`, in order, by its SHA-256. */
const hashes = (dir) => readdirSync(dir).sort().map((name) => createHash("sha256").update(readFileSync(join(dir, name))).digest("hex"));

test("rocx render films the same frames twice, whatever the time it takes", async (t) => {
	if (!browser) return t.skip("no Chromium");
	const out = mkdtempSync(join(tmpdir(), "rocx-video-"));
	try {
		const once = await render(["-o", join(out, "once") + "/", "--from", "0", "--to", "45", "--scale", "1"]);
		assert.equal(once.code, 0, once.stdout + once.stderr);
		assert.match(once.stdout, /filming 46 frames at 30 a second/);
		const again = await render(["-o", join(out, "again") + "/", "--from", "0", "--to", "45", "--scale", "1"]);
		assert.equal(again.code, 0, again.stdout + again.stderr);
		const first = hashes(join(out, "once"));
		assert.equal(first.length, 46);
		assert.equal(readdirSync(join(out, "once")).sort()[0], "frame-00000.png");
		assert.deepEqual(hashes(join(out, "again")), first);
		// Frames change as the composition does: the title types itself out.
		assert.ok(new Set(first).size > 20, `${new Set(first).size} different frames`);
		assert.equal(once.stderr, "", "the page threw nothing");
	} finally {
		rmSync(out, { recursive: true, force: true });
	}
});

test("rocx render writes an MP4 and a WebM", async (t) => {
	if (!browser) return t.skip("no Chromium");
	const out = mkdtempSync(join(tmpdir(), "rocx-video-"));
	try {
		const made = await render(["-o", join(out, "launch.mp4"), "-o", join(out, "launch.webm"), "--from", "0", "--to", "29", "--scale", "1"]);
		if (made.code !== 0 && made.stderr.includes("needs ffmpeg")) return t.skip("no ffmpeg");
		assert.equal(made.code, 0, made.stdout + made.stderr);
		assert.match(made.stdout, /30 frames, 1280 by \d+/);
		const mp4 = readFileSync(join(out, "launch.mp4"));
		assert.equal(mp4.subarray(4, 8).toString("latin1"), "ftyp");
		const webm = readFileSync(join(out, "launch.webm"));
		assert.deepEqual([...webm.subarray(0, 4)], [0x1a, 0x45, 0xdf, 0xa3]);
		// The PNGs it wrote for ffmpeg are gone.
		assert.deepEqual(readdirSync(out).sort(), ["launch.mp4", "launch.webm"]);
	} finally {
		rmSync(out, { recursive: true, force: true });
	}
});

test("rocx render says what is wrong: a page with no player, an option it doesn't know", async (t) => {
	if (!browser) return t.skip("no Chromium");
	const none = await render(["--player", "Nothing here", "-o", join(tmpdir(), "rocx-video-none") + "/"]);
	assert.equal(none.code, 1);
	assert.match(none.stderr, /has \d+ players? \(<Player>, \[data-rocx-video\]\); none is "Nothing here"/);
	const unknown = await render(["--fast"]);
	assert.equal(unknown.code, 2);
	assert.match(unknown.stderr, /rocx render: no option --fast/);
});
