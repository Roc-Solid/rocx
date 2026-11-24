#!/usr/bin/env node
// Late loads: renders every page in Node (today's web/runtime.js, unchanged) from a split build with
// only main + the page's own chunks, and lists each call that lands in a chunk the page didn't load
// (a placeholder import). WebAssembly.instantiate is wrapped here, nothing in the tree is changed.
// Each render runs without the server's answers (reads fail or wait), so it covers what a page
// renders before its data; handlers aren't run.
//
//   node late.mjs <split dir (run-…/merged)> [--whole marked-debug.wasm]
// With --whole, renders the unsplit build too and checks each page's HTML is the same.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Runtime } from "../../../web/runtime.js";

const dir = process.argv[2];
const whole = process.argv.includes("--whole") ? process.argv[process.argv.indexOf("--whole") + 1] : null;
const chunks = JSON.parse(readFileSync(join(dir, "chunks.json"), "utf8"));
const names = new Map(readFileSync(join(dir, "primary.wasm.placeholders"), "utf8").trim().split("\n").map((line) => line.split(":")).map(([i, n]) => [Number(i), n]));
const primaryModule = new WebAssembly.Module(readFileSync(join(dir, "primary.wasm")));
const chunkModules = new Map(chunks.map((c) => [c.chunk, new WebAssembly.Module(readFileSync(join(dir, `${c.chunk}.wasm`)))]));
// Placeholders whose signature has a v128: a JS function can't stand for them (V8 throws "type
// incompatibility when transforming from/to JS" at the call, before the placeholder runs), so such a
// late call is found by which chunk makes the render pass, and all of that chunk's v128 functions count.
const v128ByChunk = new Map();
{
	const bytes = readFileSync(join(dir, "primary.wasm"));
	let at = 8;
	const u32 = () => {
		let result = 0;
		let shift = 0;
		for (;;) {
			const byte = bytes[at++];
			result += (byte & 0x7f) * 2 ** shift;
			shift += 7;
			if (byte < 0x80) return result;
		}
	};
	const str = () => {
		const n = u32();
		const t = bytes.subarray(at, at + n).toString("utf8");
		at += n;
		return t;
	};
	const types = [];
	while (at < bytes.length) {
		const id = bytes[at++];
		const size = u32();
		const end = at + size;
		if (id === 1)
			for (let n = u32(); n > 0; n--) {
				at++; // 0x60
				const params = [];
				for (let k = u32(); k > 0; k--) params.push(bytes[at++]);
				const results = [];
				for (let k = u32(); k > 0; k--) results.push(bytes[at++]);
				types.push([...params, ...results].includes(0x7b));
			}
		else if (id === 2)
			for (let n = u32(); n > 0; n--) {
				const module = str();
				const name = str();
				const kind = bytes[at++];
				if (kind === 0) {
					const type = u32();
					if (module.startsWith("placeholder.") && types[type]) (v128ByChunk.get(module.slice(12)) ?? v128ByChunk.set(module.slice(12), []).get(module.slice(12))).push(names.get(Number(name)) ?? name);
				} else if (kind === 1) {
					at++;
					const flags = u32();
					u32();
					if (flags & 1) u32();
				} else if (kind === 2) {
					const flags = u32();
					u32();
					if (flags & 1) u32();
				} else if (kind === 3) at += 2;
				else if (kind === 4) {
					at++;
					u32();
				}
			}
		at = end;
	}
}
const routes = JSON.parse(/routes = "(.*)"\n/.exec(readFileSync(new URL("../../../site/build/client-marked/Generated/Root.roc", import.meta.url), "utf8"))[1].replace(/\\"/g, '"'));
const pages = routes.pages.map((p) => ({ path: p.path, code: p.levels[p.levels.length - 1].code }));

const original = WebAssembly.instantiate;
let plan = null; // { load: Set(chunk), hits: [] }
WebAssembly.instantiate = async (bytes, imports) => {
	if (!plan) return original(bytes, imports);
	const placeholders = {};
	for (const imp of WebAssembly.Module.imports(primaryModule))
		if (imp.module.startsWith("placeholder.")) {
			const chunk = imp.module.slice("placeholder.".length);
			(placeholders[imp.module] ??= {})[imp.name] = () => {
				plan.hits.push({ chunk, fn: names.get(Number(imp.name)) ?? imp.name });
				if (process.env.STACK && !plan.stacked) {
					plan.stacked = true;
					console.log(`--- stack of the late call into ${chunk}:${names.get(Number(imp.name))}\n${new Error().stack.split("\n").slice(1, Number(process.env.STACK) + 1).map((l) => l.trim().replace(/\(.*?wasm-function/, "(wasm-function").slice(0, 150)).join("\n")}`);
				}
				throw new Error(`late load: ${chunk}`);
			};
		}
	const instance = new WebAssembly.Instance(primaryModule, { ...imports, ...placeholders });
	for (const chunk of plan.load) new WebAssembly.Instance(chunkModules.get(chunk), { primary: instance.exports });
	return { instance, module: primaryModule };
};

// Each page's answers, as the server recorded them: a prerendered site (`just site`'s site/dist,
// this tree's or DIST: a checkout at the same commit). Pages behind middleware aren't there: the front page's.
const DIST = process.env.DIST ?? new URL("../../../site/dist", import.meta.url).pathname;
const answersOf = (path) => {
	let html;
	try {
		html = readFileSync(join(DIST, path === "/" ? "index.html" : `${path.slice(1)}/index.html`), "utf8");
	} catch {
		html = readFileSync(join(DIST, "index.html"), "utf8");
	}
	const script = /<script type="application\/json" class="rocx-answers">(.*?)<\/script>/.exec(html);
	return script ? JSON.parse(script[1]) : [];
};
const render = async (bytes, path) => {
	const runtime = await Runtime.load(bytes);
	try {
		return { html: runtime.renderToString({ path, answers: answersOf(path) }).html };
	} catch (error) {
		if (process.env.STACK && /type incompatibility/.test(String(error.message))) console.log(`--- ${path}: ${error.message}\n${String(error.stack).split("\n").slice(1, Number(process.env.STACK) + 1).map((l) => l.trim().slice(0, 150)).join("\n")}`);
		return { error: String(error.message ?? error).split("\n")[0].slice(0, 160) };
	}
};

const wholeBytes = whole ? readFileSync(whole) : null;
const results = [];
for (const page of pages) {
	const own = chunks.filter((c) => c.pages.includes(page.code)).map((c) => c.chunk);
	// Render with the page's chunks; a call into another chunk is recorded, the chunk added, and the
	// page rendered again, until it renders with no late call (or 30 rounds).
	const load = new Set(own);
	const late = [];
	let split;
	for (let round = 0; round < 30; round++) {
		plan = { load: new Set(load), hits: [] };
		split = await render(new Uint8Array(8), page.path);
		const hit = plan.hits[0];
		if (!hit && /type incompatibility/.test(split.error ?? "")) {
			let fixed = null;
			for (const [chunk, fns] of v128ByChunk) {
				if (load.has(chunk)) continue;
				plan = { load: new Set([...load, chunk]), hits: [] };
				const tried = await render(new Uint8Array(8), page.path);
				if (!/type incompatibility/.test(tried.error ?? "")) {
					fixed = { chunk, fns };
					break;
				}
			}
			if (!fixed) break;
			for (const fn of fixed.fns) late.push({ chunk: fixed.chunk, fn, v128: true });
			load.add(fixed.chunk);
			continue;
		}
		if (!hit) break;
		late.push(hit);
		load.add(hit.chunk);
	}
	plan = { load: new Set(chunks.map((c) => c.chunk)), hits: [] };
	const all = await render(new Uint8Array(8), page.path);
	plan = null;
	let same = null;
	if (wholeBytes) {
		const reference = await render(wholeBytes, page.path);
		same = reference.html !== undefined && reference.html === all.html;
	}
	const splitSame = split.html !== undefined && split.html === all.html;
	results.push({ page: page.path, code: page.code, own, late, error: split.error, allError: all.error, same, splitSame });
	console.log(`${page.path.padEnd(28)} own [${own.join(",")}] ${late.length ? `LATE ${late.map((h) => `${h.chunk}:${h.fn.slice(0, 40)}`).join(" ")}` : "no late loads"}${split.error ? ` | split render: ${split.error}` : ""}${all.error ? ` | all-chunks render: ${all.error}` : ""}${same === false ? " | all chunks DIFFER from whole" : ""}${splitSame ? "" : " | final split render differs"}`);
}
writeFileSync(join(dir, "late.json"), JSON.stringify(results.flatMap((r) => r.late.map((h) => [r.code, h.fn]))));
const lateCount = results.filter((r) => r.late?.length).length;
console.log(`\n${pages.length} pages; ${lateCount} with late loads; ${results.filter((r) => r.same === false).length} differ from the whole build`);
