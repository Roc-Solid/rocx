import { startServer } from "/tmp/rocx-split/repo/site/build.mjs";
import { launch } from "/tmp/rocx-split/repo/web/test/browser.mjs";
const { build } = await import("/tmp/rocx-split/repo/site/build.mjs");
if (process.env.REBUILD) await build({ split: true, log: () => {} });
const site = await startServer();
const browser = await launch();
try {
	for (const path of process.argv.slice(2)) {
		const page = await browser.page();
		await page.send("Page.enable");
		await page.send("Page.addScriptToEvaluateOnNewDocument", { source: "window.rocxStrict = true;" });
		await page.goto(`${site.url}${path}`);
		await new Promise((r) => setTimeout(r, 2500));
		const hydrated = await page.eval("document.documentElement.hasAttribute('data-hydrated')");
		const wasm = await page.eval("performance.getEntriesByType('resource').map((e) => new URL(e.name).pathname).filter((p) => p.endsWith('.wasm'))");
		console.log(path, "hydrated:", hydrated, "wasm:", wasm.join(" "));
		console.log("  console:", JSON.stringify(page.console).slice(0, 600));
		console.log("  errors:", JSON.stringify(page.errors).slice(0, 600));
	}
} finally {
	await browser.close();
	await site.stop();
}
