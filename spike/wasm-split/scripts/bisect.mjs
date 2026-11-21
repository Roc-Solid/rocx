import { startServer, nativePage } from "/tmp/rocx-split/repo/site/build.mjs";
import { Runtime } from "/tmp/rocx-split/repo/web/runtime.js";
import { readFileSync } from "node:fs";
const dir = "/tmp/rocx-split/repo/site/build/client/static/rocx";
const { pages } = JSON.parse(readFileSync(`${dir}/chunks.json`, "utf8"));
const owners = [...new Set(Object.values(pages).flat())];
const site = await startServer();
try {
	for (const [path, page] of [["/routing", "RoutingPage"], ["/calls", "CallsPage"]]) {
		const native = await nativePage(site.url, path);
		const tryWith = async (preload) => {
			const runtime = await Runtime.load(readFileSync(`${dir}/app.wasm`), { chunk: (o) => readFileSync(`${dir}/app.${o}.wasm`), preload });
			try { return runtime.renderToString({ path, answers: native.answers, regions: native.regions }).html === native.html; } catch (e) { return `threw ${String(e.message).slice(0, 80)}`; }
		};
		console.log(path, "needs", pages[page], "-> alone:", await tryWith(pages[page]));
		for (const extra of owners.filter((o) => !pages[page].includes(o))) {
			const ok = await tryWith([...pages[page], extra]);
			if (ok === true) console.log("  fixed by adding", extra);
		}
	}
} finally {
	await site.stop();
}
