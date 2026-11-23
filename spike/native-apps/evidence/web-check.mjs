// The same page in a browser (D-063's spike: the phone's .rocx is the web's too): examples/phone-hello
// served by its server (`bin/rocx dev examples/phone-hello --port 8095`), in Chromium's headless
// shell (web/test/browser.mjs), hydrated by web/runtime.js. It taps the counter, waits for the GET's
// answer, types and sends the POST, and saves web.png; it fails if any of that doesn't show.
//
//   node spike/native-apps/evidence/web-check.mjs [http://127.0.0.1:8095/]
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "../../../web/test/browser.mjs";

const url = process.argv[2] ?? "http://127.0.0.1:8095/";
const here = dirname(fileURLToPath(import.meta.url));
const browser = await launch();
try {
	const page = await browser.page();
	await page.goto(url);
	await page.wait("document.querySelector('[data-rocx]') && window.rocxReady !== false", 10000);
	const text = () => page.eval("document.querySelector('main').innerText");
	const shown = (said) => page.wait(`document.querySelector('main').innerText.includes(${JSON.stringify(said)})`, 10000);
	await shown("Hello from the rocx server");
	const tap = () => page.eval("[...document.querySelectorAll('button')].find((button) => button.textContent.trim() === 'Tap').click()");
	// The page hydrates after it loads (start.js): a tap before that would be the browser's alone.
	await page.wait("performance.getEntriesByType('resource').some((entry) => entry.name.endsWith('app.wasm'))", 10000);
	await new Promise((resolve) => setTimeout(resolve, 500));
	await tap();
	await tap();
	await tap();
	await shown("Tapped 3 times");
	await page.type("input", "hello browser");
	await page.eval("[...document.querySelectorAll('button')].find((button) => button.textContent.trim() === 'Send').click()");
	await shown("HELLO BROWSER (13 characters)");
	writeFileSync(join(here, "web.png"), await page.screenshot({ width: 420, height: 760 }));
	console.log(await text());
	if (page.errors.length) throw new Error(`the page threw: ${page.errors.join("\n")}`);
	console.log("web-check: the same .rocx works in a browser (web.png)");
} finally {
	await browser.close();
}
