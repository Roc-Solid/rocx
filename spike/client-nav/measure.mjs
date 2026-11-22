// Spike (client-side navigation, D-040): what a navigation would download if its payload were the
// page's whole HTML document, as the server answers it (or `just site` wrote it), against a JSON of
// only what the browser can't make itself: the answers, the `<NoHydration>` regions and the title.
//
//     node spike/client-nav/measure.mjs site/dist
//
// Every `index.html` under the directory (and 404.html) is measured raw and with brotli (quality
// 11, as the site's facts are). Nothing is written.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { brotliCompressSync, constants } from "node:zlib";

const dir = process.argv[2];
if (!dir) throw new Error("usage: node spike/client-nav/measure.mjs <a static site's directory>");

const pages = [];
const walk = (at) => {
	for (const name of readdirSync(at)) {
		const path = join(at, name);
		if (statSync(path).isDirectory()) walk(path);
		else if (name === "index.html" || (at === dir && name === "404.html")) pages.push(path);
	}
};
walk(dir);

const br = (text) => brotliCompressSync(Buffer.from(text), { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
const kb = (n) => (n / 1024).toFixed(1);

const between = (html, open, close) => {
	const found = [];
	let at = 0;
	for (;;) {
		const start = html.indexOf(open, at);
		if (start < 0) return found;
		const end = html.indexOf(close, start + open.length);
		if (end < 0) return found;
		found.push(html.slice(start + open.length, end));
		at = end + close.length;
	}
};

const rows = [];
for (const path of pages.sort()) {
	const html = readFileSync(path, "utf8");
	const answers = between(html, '<script type="application/json" class="rocx-answers">', "</script>").join("");
	const regions = between(html, "<!--nohydration-->", "<!--/nohydration-->");
	const title = between(html, "<title data-rocx>", "</title>")[0] ?? between(html, "<title>", "</title>")[0] ?? "";
	const json = JSON.stringify({ title, answers: answers ? JSON.parse(answers) : [], regions });
	rows.push({ page: `/${relative(dir, path).replace(/(^|\/)index\.html$/, "")}`, html: html.length, htmlBr: br(html), json: json.length, jsonBr: br(json), regionsRaw: regions.join("").length });
}

console.log("page\thtml KB\thtml br KB\tjson KB\tjson br KB\tregions KB\tbr ratio");
for (const r of rows) console.log(`${r.page}\t${kb(r.html)}\t${kb(r.htmlBr)}\t${kb(r.json)}\t${kb(r.jsonBr)}\t${kb(r.regionsRaw)}\t${(r.htmlBr / r.jsonBr).toFixed(2)}`);
const sum = (key) => rows.reduce((total, r) => total + r[key], 0);
console.log(`all ${rows.length}\t${kb(sum("html"))}\t${kb(sum("htmlBr"))}\t${kb(sum("json"))}\t${kb(sum("jsonBr"))}\t${kb(sum("regionsRaw"))}\t${(sum("htmlBr") / sum("jsonBr")).toFixed(2)}`);
