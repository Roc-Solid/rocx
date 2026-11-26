// A tab's drag (browser.mjs, `Tab.drag`), in each browser there is: Chromium, through its own drag
// and drop, and Gecko (Zen or Firefox), through the DOM's drag events. One page, no app: a card
// that can be dragged, a list that takes it, and a tray that doesn't. Each skips without its browser.
// And a browser that isn't there: a skip said once on the console, or, in CI, an error.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findChrome, findGecko, launchBrowser } from "../browser.mjs";

const PAGE = `<!doctype html><html><body style="margin: 0; font: 16px sans-serif">
<ul class="from"><li id="card" draggable="true">Card</li><li id="plain">Plain</li></ul>
<ol class="to" style="height: 120px; margin: 20px; padding: 0; background: #def"><li id="inside">Inside</li></ol>
<section id="tray" style="height: 80px; margin: 20px; background: #eee">Tray</section>
<script>
window.log = [];
for (const type of ["dragstart", "drag", "dragenter", "dragover", "dragleave", "drop", "dragend"])
	document.addEventListener(type, (event) => window.log.push({ type, at: event.target.id || event.target.className, x: event.clientX, y: event.clientY, effect: event.dataTransfer?.dropEffect ?? null }), true);
card.addEventListener("dragstart", (event) => { event.dataTransfer.setData("text/plain", "card-1"); event.dataTransfer.effectAllowed = "move"; });
const to = document.querySelector(".to");
to.addEventListener("dragover", (event) => event.preventDefault());
to.addEventListener("drop", (event) => { event.preventDefault(); window.dropped = event.dataTransfer.getData("text/plain"); });
</script></body></html>`;

let site;
before(async () => {
	site = createServer((_, response) => {
		response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
		response.end(PAGE);
	});
	await new Promise((resolve) => site.listen(0, "127.0.0.1", resolve));
});
after(() => site?.close());

/** The drag's events, `drag` and `dragover` (fired again and again while it moves) left out. */
const steps = (log) => log.filter((event) => event.type !== "drag" && event.type !== "dragover").map((event) => `${event.type}@${event.at}`);

for (const [engine, find] of [
	["chromium", findChrome],
	["gecko", findGecko],
]) {
	test(`in ${engine}: a drag, dropped where it is taken, carries its data; one that isn't taken, or is called off, ends without a drop`, { skip: !(await find()) && `no ${engine} browser` }, async () => {
		const browser = await launchBrowser({ engine });
		try {
			const tab = await browser.open(`http://127.0.0.1:${site.address().port}/`);
			const log = () => tab.page.eval("window.log.splice(0)");
			const middle = await tab.page.center(".to");

			// Dropped on the list (an element of the page, or a selector): its dragover's default is
			// prevented, so it takes the drag, and its drop reads what dragstart set.
			const carried = await tab.drag(await tab.getByText("Card"), ".to");
			assert.deepEqual(
				carried.items.map(({ mimeType, data }) => [mimeType, data]),
				[["text/plain", "card-1"]],
			);
			assert.equal(await tab.page.eval("window.dropped"), "card-1");
			const dropped = await log();
			assert.deepEqual(steps(dropped), ["dragstart@card", "dragenter@to", "drop@to", "dragend@card"]);
			assert.ok(dropped.some((event) => event.type === "drag" && event.at === "card"), "drag, on the card");
			assert.equal(dropped.filter((event) => event.type === "dragover").at(-1).at, "to", "dragover, on the list");
			const drop = dropped.find((event) => event.type === "drop");
			assert.ok(Math.abs(drop.x - middle.x) <= 1 && Math.abs(drop.y - middle.y) <= 1, `dropped at the list's middle: ${JSON.stringify([drop, middle])}`);
			assert.equal(dropped.at(-1).effect, "move", "dragend: moved");

			// The tray doesn't take it: no drop, and the drag leaves it as it ends.
			await tab.drag("#card", "#tray");
			assert.deepEqual(steps(await log()), ["dragstart@card", "dragenter@tray", "dragleave@tray", "dragend@card"]);

			// Held over the list, then called off: no drop either. Gecko's DOM events give the list the
			// dragleave the HTML standard has a called-off drag fire; Chromium's DevTools protocol
			// (`dragCancel`) fires dragend alone.
			await tab.drag("#card", ".to", { drop: false });
			assert.deepEqual(steps(await log()), ["dragstart@card", "dragenter@to"]);
			await tab.finish({ cancel: true });
			const called = await log();
			assert.deepEqual(steps(called), engine === "gecko" ? ["dragleave@to", "dragend@card"] : ["dragend@card"]);
			assert.equal(called.at(-1).effect, "none", "dragend: nothing taken");
			assert.equal(await tab.page.eval("window.dropped"), "card-1", "the first drop's, still");

			// What can't be dragged isn't.
			await assert.rejects(tab.drag("#plain", ".to"));
			assert.deepEqual(tab.errors, []);
		} finally {
			await browser.close();
		}
	});
}

test("no browser: outside CI, null and one line saying so; in CI or with ROCX_BROWSERS=required, an error, so a broken install fails the run", () => {
	// A home with no Playwright cache, and none of this run's variables: no Chromium to find.
	const home = mkdtempSync(join(tmpdir(), "rocx-no-browser-"));
	const script = `const { findChrome, launchBrowser } = await import(${JSON.stringify(new URL("../browser.mjs", import.meta.url).href)});
try { console.log(JSON.stringify([await findChrome(), await findChrome(), await launchBrowser()])); } catch (error) { console.log("threw: " + error.message); }`;
	const run = (env) => spawnSync(process.execPath, ["--input-type=module", "-e", script], { env: { PATH: process.env.PATH, HOME: home, ...env }, encoding: "utf8" });
	try {
		for (const env of [{}, { CI: "false" }, { CI: "true", ROCX_BROWSERS: "optional" }]) {
			const skipped = run(env);
			assert.equal(skipped.stdout.trim(), "[null,null,null]", JSON.stringify(env));
			assert.deepEqual(skipped.stderr.trim().split("\n"), ["rocx tests: no Chromium headless shell, so the tests that need it skip (set CHROME to one, or run `npx playwright install --only-shell chromium`). In CI, or with ROCX_BROWSERS=required, they fail instead."], "said once");
		}
		assert.match(run({ CI: "true" }).stdout, /^threw: no Chromium headless shell, and browser tests must run here \(CI=true\): set CHROME to one/);
		assert.match(run({ ROCX_BROWSERS: "required" }).stdout, /^threw: no Chromium headless shell, and browser tests must run here \(ROCX_BROWSERS=required\)/);
		assert.match(run({ ROCX_BROWSERS: "yes" }).stdout, /^threw: ROCX_BROWSERS is "yes": "required" .* or "optional"/);
	} finally {
		rmSync(home, { recursive: true, force: true });
	}
});
