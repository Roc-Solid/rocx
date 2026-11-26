// spike/wasm-engine: build.sh's two pages timed, interleaved: for each operation, the median of
// `n` clicks (click to the flush done and layout forced, after five warm cycles), today's page and
// the engine's, `rounds` times over. The tables both pages show after each operation are compared
// too (comments aside, which the engine writes unlabelled).
//
//   node spike/wasm-engine/time.mjs [out] [n] [rounds]
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(fileURLToPath(import.meta.url), "..", "..", "..");
const [out = "/tmp/wasm-engine", n = "15", rounds = "2"] = process.argv.slice(2);
const { launch } = await import(join(repo, "web", "test", "browser.mjs"));
const { serve } = await import(join(repo, "web", "test", "serve.mjs"));
const path = "/frameworks/keyed/roc-solid/";
const OPS = [
	["create 1,000", "#run", "#clear"],
	["create 10,000", "#runlots", "#clear"],
	["append 1,000", "#add", "#run"],
	["update every 10th", "#update", "#run"],
	["swap two", "#swaprows", "#run"],
	["clear", "#clear", "#run"],
];

const browser = await launch();
const sites = { today: await serve(join(out, "today")), engine: await serve(join(out, "engine")) };

async function open(name) {
	const page = await browser.page();
	await page.beforeEachDocument("document.addEventListener('rocx:ready', () => { window.hydrated = true; });");
	await page.goto(`${sites[name].url}${path}`);
	await page.wait("window.hydrated === true", 10000);
	return page;
}

const act = (page, sel) =>
	page.eval(`(async () => { const t = performance.now(); document.querySelector('${sel}').click(); await new Promise((r) => setTimeout(r, 0)); document.body.offsetHeight; return performance.now() - t; })()`);
const table = (page) => page.eval(`document.querySelector('tbody').innerHTML.replace(/<!--[^]*?-->/g, '')`);

async function time(name, op, reset) {
	const page = await open(name);
	for (let i = 0; i < 5; i++) {
		await act(page, op);
		await act(page, reset);
	}
	const times = [];
	for (let i = 0; i < Number(n); i++) {
		// A reset that makes rows comes before the op (an update needs rows); one that clears, after.
		if (reset === "#run") await act(page, reset);
		times.push(await act(page, op));
		if (reset !== "#run") await act(page, reset);
	}
	const shown = await table(page);
	await page.close();
	times.sort((a, b) => a - b);
	return { median: times[times.length >> 1], shown };
}

const results = {};
for (let round = 0; round < Number(rounds); round++) {
	for (const [label, op, reset] of OPS) {
		for (const name of ["today", "engine"]) {
			const { median, shown } = await time(name, op, reset);
			(results[label] ??= { today: [], engine: [], shown: {} })[name].push(median);
			results[label].shown[name] = shown;
		}
	}
}
const ms = (list) => list.map((value) => value.toFixed(1)).join(" / ");
for (const [label, { today, engine, shown }] of Object.entries(results)) {
	// Rows are numbered from where the page's count is, which differs by how many rows each made.
	const strip = (html) => html.replace(/>\d+</g, "><");
	const same = strip(shown.today) === strip(shown.engine) ? "" : "  (tables differ)";
	console.log(`${label.padEnd(18)} today ${ms(today).padEnd(14)} engine ${ms(engine)}${same}`);
}
await browser.close();
for (const site of Object.values(sites)) await site.close();
