#!/usr/bin/env node
// Re-baseline of per-page wasm splitting (2026-11-24), functions only (all data stays in main).
//
// One graph splitter with shared chunks, Rollup-style: each function goes to the chunk of the exact
// set of entries (route levels: each page's level closure, found by its `rocx-chunk:<Page>` marker)
// that reach it; main is what the runtime, the host, the exports and the root layout reach, plus what
// every page reaches, plus what nothing is known to reach (doubt → main). Then small chunks are
// merged and each page is capped at main + 3 files; binaryen's wasm-split --multi-split cuts the
// module, and each file is measured with brotli quality 11.
//
//   node plan.mjs [--out DIR] [--roots tight|parked] [--weak yes|no] [--min 2048] [--cap 3]
//                 [--mainShare 0.5] [--split exact|merged|both|none]
//
// Inputs (in --out, /tmp/rocx-split-2/out by default; see build.sh): marked-debug.wasm (+ .wat),
// archive/roc_app_llvm_wasm32_size.o (the `output: Archive` build's object), and, if present,
// caught/roc_app_unsealed_wasm32.o (the scratch dir's pre-composition object).
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { brotliCompressSync, constants } from "node:zlib";
import { parse, referencesOf, symbolsOf } from "./wasm.mjs";
import { locate } from "./locate.mjs";

const args = Object.fromEntries(
	process.argv.slice(2).reduce((pairs, arg, i, all) => (arg.startsWith("--") ? [...pairs, [arg.slice(2), all[i + 1]]] : pairs), []),
);
const OUT = args.out ?? "/tmp/rocx-split-2/out";
const ROOTS = args.roots ?? "tight";
const WEAK = (args.weak ?? "yes") === "yes";
const MIN = Number(args.min ?? 2048);
const CAP = Number(args.cap ?? 3);
const MAIN_SHARE = Number(args.mainShare ?? 0.5);
const SPLIT = args.split ?? "both";
// The address-based passes (a code constant or a data word that lands in a data object) assume the
// final address is the object's offset plus one base. Since the final link drops unreferenced data
// (2026-11-24: 413 KB of object data → 274 KB), that holds only up to the first dropped segment:
// --addresses no leaves them out (references then come from the objects' relocations, by name).
const ADDRESSES = (args.addresses ?? "yes") === "yes";
// Where the object's data objects are in the final module: `locate` (by content, locate.mjs) or
// `offset` (object offset + one base, the parked assumption, true only for the first 47 KB now).
const LAYOUT = args.layout ?? "locate";
const TAG = args.tag ?? `${ROOTS}-${WEAK ? "weak" : "strong"}${ADDRESSES ? "" : "-noaddr"}${LAYOUT === "locate" ? "-located" : ""}`;
const RUN = join(OUT, `run-${TAG}`);
mkdirSync(RUN, { recursive: true });

const brotli = (bytes) => brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
const kb = (n) => `${(n / 1024).toFixed(1)}`;
const log = (...xs) => console.log(...xs);
const add = (map, key, value) => (map.get(key) ?? map.set(key, new Set()).get(key)).add(value);

// ---- The graph (parked analyse(), its graph part, with the exports and quoted names read) ----

const wasmBytes = readFileSync(join(OUT, "marked-debug.wasm"));
const text = readFileSync(join(OUT, "marked-debug.wat"), "utf8");
const objectBytes = readFileSync(join(OUT, "archive", "roc_app_llvm_wasm32_size.o"));
const unsealedPath = join(OUT, "caught", "roc_app_unsealed_wasm32.o");
const unsealed = args.unsealed === "no" || !existsSync(unsealedPath) ? null : readFileSync(unsealedPath);

const object = parse(objectBytes);
const wasm = parse(wasmBytes);
const symbols = symbolsOf(object);
const finalNames = new Set(wasm.names.values());
const funcName = new Map();
for (const s of symbols) if (s.kind === "f" && s.name && !s.undefined && s.index >= object.importedFuncs) funcName.set(s.index - object.importedFuncs, s.name);
const inObject = new Set([...funcName.values()].filter((name) => finalNames.has(name)).map((name) => `F:${name}`));
// Functions the final link made (no name in the debug build; binaryen calls them by their index among
// the module's own functions): app code too (merged similar functions and their thunks' targets).
const synth = new Set();
for (let i = 0; i < wasm.bodies.length; i++) if (!wasm.names.has(i + wasm.importedFuncs)) synth.add(`F:${i}`);
const defined = new Set([...inObject, ...(process.env.SYNTH_HOST ? [] : synth)]);
// Each final function's size (its body), by name.
const size = new Map();
const bodyBytes = new Map();
{
	const code = wasm.sections[wasm.codeIndex];
	wasm.bodies.forEach((body, i) => {
		const name = `F:${wasm.names.get(i + wasm.importedFuncs) ?? i}`;
		size.set(name, body.end - body.start);
		bodyBytes.set(name, wasmBytes.subarray(code.base + body.start, code.base + body.end));
	});
}
const objects = symbols
	.filter((s) => s.kind === "d" && !s.undefined)
	.map((s) => ({ name: `D:${s.name}`, segment: s.segment, offset: s.offset, at: object.segments[s.segment].offset + s.offset, size: Math.max(s.size, 1), bytes: object.segments[s.segment].bytes.subarray(s.offset, s.offset + s.size) }))
	.sort((a, b) => a.at - b.at);
const starts = objects.map((o) => o.at);
const objectAt = (address) => {
	let lo = 0;
	let hi = starts.length - 1;
	while (lo <= hi) {
		const mid = (lo + hi) >> 1;
		if (starts[mid] <= address) lo = mid + 1;
		else hi = mid - 1;
	}
	const found = objects[hi];
	return found && found.at <= address && address < found.at + found.size ? found : null;
};
const edges = new Map();
const edge = (from, to) => add(edges, from, to);
const pointing = new Map();
const point = (from, to, at) => (pointing.get(to) ?? pointing.set(to, []).get(to)).push({ from, at });
const references = [objectBytes, ...(unsealed ? [unsealed] : [])].map(referencesOf);
const canonical = new Map();
const publicNames = new Set();
for (const names of references.flatMap((r) => r.aliases)) {
	const kept = names.find((name) => finalNames.has(name));
	if (!kept) continue;
	for (const name of names) canonical.set(`F:${name}`, `F:${kept}`);
	if (names.some((name) => !name.startsWith("roc__p"))) publicNames.add(`F:${kept}`);
}
const named = (node) => canonical.get(node) ?? node;
const counts = { relocation: 0, codeConst: 0, dataWord: 0, hostCall: 0, textCall: 0 };
for (const found of references)
	for (const { from, to, at } of found) {
		edge(named(from), named(to));
		counts.relocation++;
		if (to.startsWith("D:")) point(named(from), to, at);
	}
// Markers → the base (final address = object offset + base).
const markers = new Map();
for (const o of objects) {
	const t = Buffer.from(o.bytes).toString("latin1");
	for (const m of t.matchAll(/rocx-chunk:([A-Za-z0-9_]+)/g)) markers.set(m[1], { object: o, at: m.index });
}
const bases = new Set();
for (const segment of wasm.segments)
	for (const m of Buffer.from(segment.bytes).toString("latin1").matchAll(/rocx-chunk:([A-Za-z0-9_]+)/g)) {
		const marker = markers.get(m[1]);
		if (marker) bases.add(segment.offset + m.index - (marker.object.at + marker.at));
	}
if (bases.size !== 1) throw new Error(`bases: ${[...bases]}`);
const [base] = bases;
// Every data object at a final address (merged constants share theirs).
let objectsAtFinal;
if (LAYOUT === "locate") {
	const located = locate(object, wasm, symbols);
	log(`layout (by content): ${JSON.stringify(located.stats)}`);
	const placed = objects
		.filter((o) => located.final[o.segment] !== null)
		.map((o) => ({ o, from: located.final[o.segment] + o.offset, to: located.final[o.segment] + o.offset + o.size }))
		.sort((a, b) => a.from - b.from);
	const placedStarts = placed.map((p) => p.from);
	const biggest = Math.max(...placed.map((p) => p.to - p.from));
	objectsAtFinal = (address) => {
		let lo = 0;
		let hi = placedStarts.length - 1;
		while (lo <= hi) {
			const mid = (lo + hi) >> 1;
			if (placedStarts[mid] <= address) lo = mid + 1;
			else hi = mid - 1;
		}
		const out = [];
		for (let k = hi; k >= 0 && placed[k].from > address - biggest; k--) if (placed[k].from <= address && address < placed[k].to) out.push({ ...placed[k].o, final: placed[k].from });
		return out;
	};
} else
	objectsAtFinal = (address) => {
		const o = objectAt(address - base);
		return o ? [{ ...o, final: base + o.at }] : [];
	};
const HOST = "H:host";
const small = new Map();
const stack = [];
let current = null;
const exportFns = [];
const fnNameOf = (rest) => (rest.startsWith('$"') ? rest.slice(2, rest.indexOf('"', 2)) : rest.slice(1).split(/[\s)]/)[0]);
for (const line of text.split("\n")) {
	if (line.startsWith(" (export ")) {
		const m = /\(func (\$\S+?)\)\)$/.exec(line) ?? /\(func (\$".*")\)\)$/.exec(line);
		if (m) exportFns.push(`F:${fnNameOf(m[1])}`);
		continue;
	}
	if (line.startsWith(" (func ")) {
		current = `F:${fnNameOf(line.slice(7))}`;
		stack.length = 0;
		continue;
	}
	if (!current) continue;
	const host = !defined.has(current);
	const depth = line.length - line.trimStart().length;
	while (stack.length && stack[stack.length - 1].depth >= depth) stack.pop();
	const parent = stack[stack.length - 1];
	if (parent) parent.children++;
	const op = line.trimStart().split(/[\s)]/)[0];
	stack.push({ depth, op, children: 0 });
	const stored = parent && /^\(i(32|64)\.store$/.test(parent.op) && parent.children === 2 ? /^\s*\(i32\.const (\d+)\)$/.exec(line) : null;
	if (stored && Number(stored[1]) > 0 && Number(stored[1]) < base) add(small, host ? HOST : current, Number(stored[1]));
	if (line.includes("(call ") || line.includes("(ref.func ") || line.includes("(return_call ")) {
		for (const m of line.matchAll(/\((?:call|return_call|ref\.func) (\$"[^"]*"|\$[^\s)]+)/g)) {
			const callee = `F:${fnNameOf(m[1])}`;
			if (!defined.has(callee)) continue;
			if (host) counts.hostCall++;
			else counts.textCall++;
			edge(host ? HOST : current, callee);
		}
	}
	if (!ADDRESSES || !line.includes("i32.const")) continue;
	for (const m of line.matchAll(/\(i32\.const (\d+)\)/g)) {
		const address = Number(m[1]);
		if (address < base) continue;
		for (const to of objectsAtFinal(address)) {
			edge(host ? HOST : current, to.name);
			counts.codeConst++;
			if (!host) point(current, to.name, address - to.final);
		}
	}
}
const slots = new Map();
for (const elem of wasm.elems) elem.funcs.forEach((index, k) => slots.set(elem.offset + k, wasm.names.get(index)));
if (ADDRESSES) {
	const low = Math.min(...wasm.segments.map((s) => s.offset)) & ~3;
	const high = Math.max(...wasm.segments.map((s) => s.offset + s.size));
	const image = new Uint8Array(high - low + 4);
	for (const s of wasm.segments) image.set(s.bytes, s.offset - low);
	const view = new DataView(image.buffer);
	for (let k = 0; k + 4 <= image.length; k += 4) {
		const word = view.getUint32(k, true);
		if (word === 0) continue;
		const at = low + k;
		const froms = at < base ? [{ name: HOST }] : objectsAtFinal(at);
		if (!froms.length) continue;
		if (word < base) {
			if (slots.has(word)) for (const from of froms) add(small, from.name, word);
			continue;
		}
		for (const to of objectsAtFinal(word))
			for (const from of froms)
				if (to.name !== from.name) {
					edge(from.name, to.name);
					counts.dataWord++;
				}
	}
}
// Entries: what refers to each marker (through data, a few levels up).
const entries = new Map();
for (const [page, marker] of markers) {
	const found = new Set();
	let frontier = new Set((pointing.get(marker.object.name) ?? []).filter((r) => marker.at - 16 <= r.at && r.at <= marker.at).map((r) => r.from));
	for (let depth = 0; depth < 4 && frontier.size; depth++) {
		for (const node of frontier) if (node.startsWith("F:")) found.add(node);
		frontier = new Set([...frontier].filter((n) => n.startsWith("D:")).flatMap((n) => (pointing.get(n) ?? []).map((r) => r.from)));
	}
	const live = [...found].filter((name) => defined.has(name));
	if (!live.length) throw new Error(`no entry for ${page}`);
	entries.set(page, live);
}
const pages = [...entries.keys()].sort();
// Calls a render found that the graph doesn't show (late.mjs's late.json, accumulated): page → function.
const EXTRA = args.extra ?? join(RUN, "extra-edges.json");
let extraCount = 0;
if (existsSync(EXTRA)) for (const [page, fn] of JSON.parse(readFileSync(EXTRA, "utf8"))) for (const entry of entries.get(page) ?? []) {
	edge(entry, `F:${fn}`);
	extraCount++;
}
const N = pages.length;
log(`graph: ${defined.size} app functions of ${wasm.bodies.length}, ${objects.length} data objects, base ${base}; edges from relocations ${counts.relocation}, code constants ${counts.codeConst}, data words ${counts.dataWord}, host calls ${counts.hostCall}, text calls ${counts.textCall}, synthesized ${synth.size}; unsealed ${unsealed ? "yes" : "no"}`);
log(`extra edges (from renders): ${extraCount}`);
log(`entries: ${N} pages, ${[...entries.values()].filter((f) => f.length !== 1).length} with other than one function; exports ${exportFns.length}`);

// ---- Who reaches what ----

const referenced = new Set();
for (const targets of edges.values()) for (const t of targets) referenced.add(t);
const unreferencedData = objects.filter((o) => !referenced.has(o.name) && edges.has(o.name)).map((o) => o.name);
const publicFunctions = [...edges.keys()].filter((n) => n.startsWith("F:") && !n.slice(2).startsWith("roc__p"));
// tight: the host, the exports, the public entry points. cells: also every data object nothing refers
// to (Roc's 4-byte static-data root cells `roc__dN`, whose address appears nowhere in the final
// binary: the code refers to their payloads, `roc__dN_1`); the parked analysis made them roots.
// parked: also every function not a procedure (`roc__p…`): builtins, RC helpers.
const rootsTight = [HOST, ...exportFns, ...publicNames];
const rootsCells = [...rootsTight, ...unreferencedData];
const rootsParked = [...rootsCells, ...publicFunctions, ...[...defined].filter((n) => !n.slice(2).startsWith("roc__p") && !/^F:\d+$/.test(n))];
const roots = ROOTS === "parked" ? rootsParked : ROOTS === "cells" ? rootsCells : rootsTight;
const stop = new Set([...entries.values()].flat());
const reach = (from, stopAt) => {
	const seen = new Set();
	const todo = from.filter((n) => !stopAt.has(n));
	while (todo.length) {
		const node = todo.pop();
		if (seen.has(node)) continue;
		seen.add(node);
		for (const next of edges.get(node) ?? []) if (!seen.has(next) && !stopAt.has(next)) todo.push(next);
	}
	return seen;
};
const slotOf = new Map([...slots].filter(([, name]) => name && defined.has(`F:${name}`)).map(([slot, name]) => [slot, `F:${name}`]));
let core;
let per;
let weakAdded = 0;
for (let round = 0; ; round++) {
	core = reach(roots, stop);
	per = new Map(pages.map((page) => {
		const others = new Set([...stop].filter((f) => !entries.get(page).includes(f)));
		const stopAt = new Set([...core, ...others]);
		return [page, reach(entries.get(page), stopAt)];
	}));
	if (!WEAK || round >= 8) break;
	// A function nothing reaches, whose table slot something holds as a plain number (a constant
	// stored to memory, a word of data): an edge from each holder that is reached.
	const reached = new Set([...core, ...[...per.values()].flatMap((s) => [...s])]);
	let added = 0;
	for (const [holder, numbers] of small) {
		if (!reached.has(holder)) continue;
		for (const number of numbers) {
			const orphan = slotOf.get(number);
			if (!orphan || reached.has(orphan) || edges.get(holder)?.has(orphan)) continue;
			edge(holder, orphan);
			added++;
		}
	}
	weakAdded += added;
	if (!added) break;
}
const fnsOnly = (set) => [...set].filter((n) => defined.has(n));
const reachCount = new Map();
for (const set of per.values()) for (const n of set) if (!core.has(n)) reachCount.set(n, (reachCount.get(n) ?? 0) + 1);
const owner = new Map();
const unreached = [];
const everyPage = [];
for (const f of defined) {
	if (core.has(f)) owner.set(f, "main");
	else if (!reachCount.has(f)) {
		owner.set(f, "main");
		unreached.push(f);
	} else if (reachCount.get(f) === N) {
		owner.set(f, "main");
		everyPage.push(f);
	}
}
const keyOf = new Map();
for (const f of defined) {
	if (owner.has(f)) continue;
	const key = pages.filter((p) => per.get(p).has(f));
	keyOf.set(f, key);
}
const sum = (fns) => fns.reduce((a, f) => a + (size.get(f) ?? 0), 0);
const coreFns = fnsOnly(core);
log(`weak slot edges added: ${weakAdded}`);
log(`main: core ${coreFns.length} fns ${kb(sum(coreFns))} KB raw; every page ${everyPage.length} fns ${kb(sum(everyPage))} KB; unreached ${unreached.length} fns ${kb(sum(unreached))} KB; host/unnamed rest ${wasm.bodies.length - defined.size} fns`);

// ---- Data, for a later data split (not moved here): each object data segment by who reaches its
// symbols (the strongest). What nothing reaches is what the final link drops (compare the sum of
// the rest with the final module's data).
{
	const rank = { unreached: 0, "one page": 1, "a few pages": 2, "most pages": 3, main: 4 };
	const names = Object.keys(rank);
	const segClass = new Map();
	for (const sym of symbols) {
		if (sym.kind !== "d" || sym.undefined) continue;
		const node = `D:${sym.name}`;
		let c;
		if (core.has(node)) c = "main";
		else {
			const n = reachCount.get(node) ?? 0;
			c = n === 0 ? "unreached" : n === N ? "main" : n === 1 ? "one page" : n < N / 2 ? "a few pages" : "most pages";
		}
		if (!segClass.has(sym.segment) || rank[c] > rank[segClass.get(sym.segment)]) segClass.set(sym.segment, c);
	}
	const parts = names.map((name) => {
		const bytes = Buffer.concat(object.segments.filter((seg, i) => (segClass.get(i) ?? "unreached") === name).map((seg) => Buffer.from(seg.bytes)));
		return `${name} ${kb(bytes.length)} KB raw ~${kb(brotli(bytes))} KB br`;
	});
	const finalData = wasm.segments.reduce((a, seg) => a + seg.size, 0);
	log(`object data by who reaches it: ${parts.join("; ")} (final module's data: ${kb(finalData)} KB raw)`);
}

if (process.env.BIG_DATA) {
	const mainData = objects.filter((o) => core.has(o.name)).sort((a, b) => b.size - a.size).slice(0, Number(process.env.BIG_DATA));
	for (const o of mainData) {
		const path = [];
		// who refers to it (one hop), for context
		const refs = [...edges].filter(([, t]) => t.has(o.name)).map(([f]) => f).slice(0, 3);
		log(`  ${String(o.size).padStart(6)} ${o.name} <- ${refs.join(" ")} | ${JSON.stringify(Buffer.from(o.bytes.subarray(0, 90)).toString("latin1").replace(/[^\x20-\x7e]/g, "."))}`);
	}
}
// ---- Chunks by exact entry set ----

let chunks = new Map();
for (const [f, key] of keyOf) {
	const id = key.join(",");
	const chunk = chunks.get(id) ?? chunks.set(id, { pages: new Set(key), fns: [] }).get(id);
	chunk.fns.push(f);
}
const estimate = (fns) => brotli(Buffer.concat(fns.map((f) => bodyBytes.get(f) ?? Buffer.alloc(0))));
for (const chunk of chunks.values()) chunk.est = estimate(chunk.fns);
const describe = (chunk) => (chunk.pages.size === 1 ? [...chunk.pages][0] : chunk.pages.size <= 3 ? [...chunk.pages].join("+") : `${chunk.pages.size} pages`);
const perPageCount = (cs) => pages.map((p) => [...cs.values()].filter((c) => c.pages.has(p)).length);
const exact = new Map([...chunks].map(([id, c]) => [id, { ...c, pages: new Set(c.pages), fns: [...c.fns] }]));
{
	const cnt = perPageCount(chunks).sort((a, b) => a - b);
	log(`exact chunks: ${chunks.size}; per page min ${cnt[0]} median ${cnt[N >> 1]} max ${cnt[N - 1]}; est. br total ${kb([...chunks.values()].reduce((a, c) => a + c.est, 0))} KB`);
}

// ---- Merging ----
// Cost of a merge: the bytes pages then load that they don't need, summed over pages.
let mainExtra = [];
const mergeCost = (a, b) => [...b.pages].filter((p) => !a.pages.has(p)).length * a.est + [...a.pages].filter((p) => !b.pages.has(p)).length * b.est;
const intoMainCost = (a) => (N - a.pages.size) * a.est;
const merge = (idA, idB) => {
	const a = chunks.get(idA);
	const b = chunks.get(idB);
	chunks.delete(idA);
	chunks.delete(idB);
	const fns = [...a.fns, ...b.fns];
	const merged = { pages: new Set([...a.pages, ...b.pages]), fns, est: estimate(fns) };
	const id = [...merged.pages].sort().join(",");
	const existing = chunks.get(id);
	if (existing) {
		existing.fns.push(...fns);
		existing.est = estimate(existing.fns);
	} else chunks.set(id, merged);
};
const toMain = (id) => {
	mainExtra.push(...chunks.get(id).fns);
	chunks.delete(id);
};
// 1. Small chunks (< MIN br): into main if most pages reach them, else into the cheapest chunk.
for (;;) {
	const smallest = [...chunks].filter(([, c]) => c.est < MIN).sort((x, y) => x[1].est - y[1].est)[0];
	if (!smallest) break;
	const [idA, a] = smallest;
	if (a.pages.size >= MAIN_SHARE * N) {
		toMain(idA);
		continue;
	}
	let best = { cost: intoMainCost(a), id: null };
	for (const [idB, b] of chunks) {
		if (idB === idA) continue;
		const cost = mergeCost(a, b);
		if (cost < best.cost) best = { cost, id: idB };
	}
	if (best.id === null) toMain(idA);
	else merge(idA, best.id);
}
// 2. The cap: a page loads main + at most CAP chunks.
for (;;) {
	const over = pages.find((p) => [...chunks.values()].filter((c) => c.pages.has(p)).length > CAP);
	if (!over) break;
	const mine = [...chunks].filter(([, c]) => c.pages.has(over));
	let best = { cost: Infinity };
	for (let i = 0; i < mine.length; i++) {
		const [idA, a] = mine[i];
		const cm = intoMainCost(a);
		if (cm < best.cost) best = { cost: cm, a: idA, b: null };
		for (let j = i + 1; j < mine.length; j++) {
			const [idB, b] = mine[j];
			const cost = mergeCost(a, b);
			if (cost < best.cost) best = { cost, a: idA, b: idB };
		}
	}
	if (best.b === null) toMain(best.a);
	else merge(best.a, best.b);
}
{
	const cnt = perPageCount(chunks).sort((a, b) => a - b);
	log(`merged chunks: ${chunks.size}; per page min ${cnt[0]} median ${cnt[N >> 1]} max ${cnt[N - 1]}; moved into main ${mainExtra.length} fns ${kb(sum(mainExtra))} KB raw`);
}

// ---- Splitting and measuring ----

const wasmSplit = (name, plan) => {
	const dir = join(RUN, name);
	rmSync(dir, { recursive: true, force: true });
	mkdirSync(dir, { recursive: true });
	const ids = [...plan.keys()];
	const manifest = ids.map((id, i) => `c${i}\n${plan.get(id).fns.map((f) => f.slice(2)).sort().join("\n")}`).join("\n\n");
	writeFileSync(join(dir, "manifest.txt"), `${manifest}\n`);
	writeFileSync(join(dir, "chunks.json"), JSON.stringify(ids.map((id, i) => ({ chunk: `c${i}`, pages: [...plan.get(id).pages].sort(), fns: plan.get(id).fns.length })), null, 1));
	const done = spawnSync("nix", ["shell", "nixpkgs#binaryen", "-c", "wasm-split", "--multi-split", join(OUT, "marked-debug.wasm"), "--manifest", join(dir, "manifest.txt"), "--out-prefix", `${dir}/`, "-o", join(dir, "primary.wasm"), "--strip-debug", "--placeholdermap"], { encoding: "utf8", maxBuffer: 1 << 28 });
	if (done.status !== 0) throw new Error(`wasm-split failed: ${done.stderr}`);
	const files = new Map();
	for (const file of readdirSync(dir).filter((f) => f.endsWith(".wasm"))) {
		const bytes = readFileSync(join(dir, file));
		files.set(file.replace(/\.wasm$/, ""), { raw: bytes.length, br: brotli(bytes) });
	}
	const mainBr = files.get("primary").br;
	const firstLoad = new Map(pages.map((p) => [p, mainBr + ids.map((id, i) => (plan.get(id).pages.has(p) ? files.get(`c${i}`).br : 0)).reduce((a, b) => a + b, 0)]));
	const chunkFiles = ids.map((id, i) => ({ id: `c${i}`, pages: plan.get(id).pages, ...files.get(`c${i}`), est: plan.get(id).est, fns: plan.get(id).fns.length }));
	return { dir, mainBr, mainRaw: files.get("primary").raw, firstLoad, chunkFiles, total: [...files.values()].reduce((a, f) => a + f.br, 0) };
};
const report = (name, result) => {
	const loads = [...result.firstLoad].sort((a, b) => a[1] - b[1]);
	const median = loads[N >> 1][1];
	log(`\n== ${name}: ${result.chunkFiles.length} chunks; main ${kb(result.mainRaw)} KB raw, ${kb(result.mainBr)} KB br; all files ${kb(result.total)} KB br`);
	log(`first load br: min ${kb(loads[0][1])} (${loads[0][0]}), median ${kb(median)}, max ${kb(loads[N - 1][1])} (${loads[N - 1][0]})`);
	log(`heaviest: ${loads.slice(-6).reverse().map(([p, b]) => `${p} ${kb(b)}`).join(", ")}`);
	log(`lightest: ${loads.slice(0, 6).map(([p, b]) => `${p} ${kb(b)}`).join(", ")}`);
	const at = (p) => kb(result.firstLoad.get(p));
	log(`selected: ${["RootPage", "SyntaxPage", "ComponentsPage", "ShowcasePage", "EcosystemChartsPage", "PlatformPage", "PlatformHttpPage", "RocxPage", "RoutingPage", "ToolingPage", "ExamplesPage", "EcosystemMarkdownPage"].filter((p) => result.firstLoad.has(p)).map((p) => `${p} ${at(p)}`).join(", ")}`);
	const big = [...result.chunkFiles].sort((a, b) => b.br - a.br).slice(0, 12);
	log(`biggest chunks: ${big.map((c) => `${c.id}[${describe(c)}] ${kb(c.br)}`).join(", ")}`);
	writeFileSync(join(result.dir, "first-load.tsv"), `page\tfirst_load_br\tchunks\n${loads.map(([p, b]) => `${p}\t${b}\t${result.chunkFiles.filter((c) => c.pages.has(p)).map((c) => `${c.id}:${c.br}`).join(" ")}`).join("\n")}\n`);
	return { name, mainBr: result.mainBr, min: loads[0][1], median, max: loads[N - 1][1], chunks: result.chunkFiles.length };
};
const summary = { tag: TAG, roots: ROOTS, weak: WEAK, core: coreFns.length, coreRaw: sum(coreFns), everyPage: everyPage.length, everyPageRaw: sum(everyPage), unreached: unreached.length, unreachedRaw: sum(unreached), exactChunks: exact.size, mergedChunks: chunks.size, results: [] };
if (SPLIT === "exact" || SPLIT === "both") summary.results.push(report("exact", wasmSplit("exact", exact)));
if (SPLIT === "merged" || SPLIT === "both") {
	// Functions merged into main are simply left out of the manifest.
	summary.results.push(report("merged", wasmSplit("merged", chunks)));
}
// Unreached functions, by brotli of their bodies, and the biggest.
summary.unreachedBr = estimate(unreached);
log(`\nunreached: ${unreached.length} fns, ${kb(summary.unreachedRaw)} KB raw, ~${kb(summary.unreachedBr)} KB br; biggest: ${unreached.sort((a, b) => size.get(b) - size.get(a)).slice(0, 8).map((f) => `${f.slice(2, 30)} ${size.get(f)}`).join(", ")}`);
const bigCore = coreFns.sort((a, b) => size.get(b) - size.get(a)).slice(0, 15);
log(`biggest core functions: ${bigCore.map((f) => `${f.slice(2, 40)} ${size.get(f)}`).join(", ")}`);
if (process.env.DUMP_EDGES) writeFileSync(join(RUN, "edges.json"), JSON.stringify({ roots, stop: [...stop], edges: Object.fromEntries([...edges].map(([k, v]) => [k, [...v]])), size: Object.fromEntries(size), entries: Object.fromEntries(entries), rootsTight, small: Object.fromEntries([...small].map(([k, v]) => [k, [...v]])) }));
writeFileSync(join(RUN, "summary.json"), JSON.stringify(summary, null, 1));
writeFileSync(join(RUN, "graph.json"), JSON.stringify({ entries: Object.fromEntries(entries), core: coreFns, everyPage, unreached, keys: Object.fromEntries([...keyOf].map(([f, k]) => [f, k.length === N ? "all" : k])) }));
