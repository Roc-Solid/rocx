// packages/video's example app in a browser: `<Player>` shows its poster frame as the server
// renders it, plays from the start once the page is live, pauses and plays from its button, and
// seeks with its scrubber, `<Sequence>` showing each scene in its stretch; the stories catalog lists
// the compositions; and render.mjs films the same frames twice (a frame doesn't depend on how long it
// took), and writes MP4 and WebM files when there is ffmpeg.
// Run it with `node --test 'packages/video/example/test/*.test.mjs'`; ROCX_TEST_OPT=speed builds the
// server optimized (`--opt=speed`), as a release is.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, launchBrowser, startServer, testSqlite } from "../../../testing/index.mjs";
import { findFfmpeg, render } from "../../render.mjs";

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

test("render.mjs films the same frames twice, whatever the time it takes", async (t) => {
	if (!browser) return t.skip("no Chromium");
	const once = await render({ url: `${app.url}/`, outputs: [], from: 0, to: 45, scale: 1, browser });
	const again = await render({ url: `${app.url}/`, outputs: [], from: 0, to: 45, scale: 1, browser });
	assert.equal(once.frames, 46);
	assert.equal(once.fps, 30);
	assert.deepEqual(once.hashes, again.hashes);
	// Frames change as the composition does: the title types itself out.
	assert.ok(new Set(once.hashes).size > 20, `${new Set(once.hashes).size} different frames`);
	assert.deepEqual(once.errors, []);
});

test("render.mjs writes an MP4 and a WebM", async (t) => {
	if (!browser) return t.skip("no Chromium");
	try {
		findFfmpeg();
	} catch {
		return t.skip("no ffmpeg");
	}
	const out = mkdtempSync(join(tmpdir(), "rocx-video-"));
	try {
		const made = await render({ url: `${app.url}/`, outputs: [join(out, "launch.mp4"), join(out, "launch.webm")], from: 0, to: 29, scale: 1, browser });
		assert.equal(made.frames, 30);
		const mp4 = readFileSync(join(out, "launch.mp4"));
		assert.equal(mp4.subarray(4, 8).toString("latin1"), "ftyp");
		const webm = readFileSync(join(out, "launch.webm"));
		assert.deepEqual([...webm.subarray(0, 4)], [0x1a, 0x45, 0xdf, 0xa3]);
	} finally {
		rmSync(out, { recursive: true, force: true });
	}
});
