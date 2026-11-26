// spike/wasm-engine: a CPU profile of one operation on one of build.sh's pages (`engine`, best
// built with NAMES=1, or `today`), after five create/clear cycles: self time by function, and the
// slowest including what they call.
//
//   node spike/wasm-engine/profile.mjs [page] [op] [before] [out]   (engine #run "" /tmp/wasm-engine)
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(fileURLToPath(import.meta.url), "..", "..", "..");
const [which = "engine", op = "#run", before = "", out = "/tmp/wasm-engine"] = process.argv.slice(2);
const { launch } = await import(join(repo, "web", "test", "browser.mjs"));
const { serve } = await import(join(repo, "web", "test", "serve.mjs"));
const site = await serve(join(out, which));
const browser = await launch();
const page = await browser.page();
await page.beforeEachDocument("document.addEventListener('rocx:ready', () => { window.hydrated = true; });");
await page.goto(`${site.url}/frameworks/keyed/roc-solid/`);
await page.wait("window.hydrated === true", 10000);
const act = (sel) => page.eval(`(async () => { document.querySelector('${sel}').click(); await new Promise((r) => setTimeout(r, 0)); document.body.offsetHeight; })()`);
for (let i = 0; i < 5; i++) {
	await act("#run");
	await act("#clear");
}
if (before) await act(before);
await page.send("Profiler.enable");
await page.send("Profiler.setSamplingInterval", { interval: 50 });
await page.send("Profiler.start");
const t0 = await page.eval("performance.now()");
await act(op);
const t1 = await page.eval("performance.now()");
const { profile } = await page.send("Profiler.stop");
const byId = new Map(profile.nodes.map((node) => [node.id, node]));
const parent = new Map();
for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
const name = (node) => `${node.callFrame.functionName || "(anon)"}${node.callFrame.url ? ` ${node.callFrame.url.split("/").pop()}:${node.callFrame.lineNumber + 1}` : ""}`;
const self = new Map();
const total = new Map();
profile.samples.forEach((id, i) => {
	const ms = (profile.timeDeltas[i] ?? 0) / 1000;
	const key = name(byId.get(id));
	self.set(key, (self.get(key) ?? 0) + ms);
	const seen = new Set();
	for (let at = id; at !== undefined; at = parent.get(at)) {
		const up = name(byId.get(at));
		if (!seen.has(up)) {
			seen.add(up);
			total.set(up, (total.get(up) ?? 0) + ms);
		}
	}
});
console.log(`${which} ${op}: ${(t1 - t0).toFixed(1)} ms`);
console.log("-- self");
for (const [key, ms] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 30)) console.log(ms.toFixed(1).padStart(7), key);
console.log("-- total");
for (const [key, ms] of [...total].sort((a, b) => b[1] - a[1]).filter(([key]) => !/^\((root|program|idle)\)/.test(key)).slice(0, 30)) console.log(ms.toFixed(1).padStart(7), key);
await browser.close();
await site.close();
