// The browser's wasm, cut into a main module and a chunk per page (`--split`).
//
// One Roc program is compiled as usual, then cut after linking: the main module keeps what every
// page needs (the platform, the layout, the runtime's glue), and each page's chunk holds what only
// that page reaches, its functions and its data. A chunk imports the main module's memory, table
// and stack pointer, so it is one heap, and nothing is copied twice. Code that two or more pages
// share is a chunk of its own (`Shared`), and code nothing reaches (functions and data Roc's linker
// keeps, though no reference to them is left) is `Unreached`, which no page loads.
//
// How the pieces are found, from one build:
//  - The app is built twice from the same source: the wasm (with `--debug`, for its function names),
//    and, with the platform's wasm32 `output: Archive` (a copy of the platform, `--replace-dep`), the
//    object it was linked from, whose symbols and relocations say which function calls or takes
//    which, and which data refers to what. A data object's final address is its offset in the
//    object plus one constant (the host's data comes first).
//  - Roc's own combining step resolves some references before the object is written: a function
//    taking a data object's address may then hold it as a plain constant. Every `i32.const` in a
//    function that falls inside a data object, and every word of data that does, counts too.
//  - rocx marks each page's entry (`--split` gives Root a `<NoHydration>` holding the page's name,
//    `rocx-chunk:<Page>`): the function that refers to that string is where the page begins.
//  - What the app's runtime functions reach (those not named `roc__p…`: builtins, entry points) is
//    the main module's, not going into a page; what one page reaches besides is that page's.
// Then binaryen's `wasm-split --multi-split` moves the functions, and each chunk is given its data
// as active segments at the same addresses (fresh memory is zero, so the main module drops them).
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, constants } from "node:zlib";

const ROCX = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** What marks a page's entry: `rocx-chunk:<Page>`, the page's module. */
export const MARKER = "rocx-chunk:";
/** The chunks that aren't a page's. */
export const SHARED = "Shared";
export const UNREACHED = "Unreached";
/** A chunk's file, beside the main module (`app.wasm`). */
export const chunkFile = (owner) => `app.${owner}.wasm`;

// ---- Reading wasm ----

class Reader {
	constructor(bytes, at = 0) {
		this.b = bytes;
		this.at = at;
	}
	u8() {
		return this.b[this.at++];
	}
	u32() {
		let result = 0;
		let shift = 0;
		for (;;) {
			const byte = this.b[this.at++];
			result += (byte & 0x7f) * 2 ** shift;
			shift += 7;
			if (byte < 0x80) return result;
		}
	}
	s32() {
		let result = 0;
		let shift = 0;
		for (;;) {
			const byte = this.b[this.at++];
			result += (byte & 0x7f) * 2 ** shift;
			shift += 7;
			if (byte < 0x80) return byte & 0x40 ? result - 2 ** shift : result;
		}
	}
	name() {
		const length = this.u32();
		const text = Buffer.from(this.b.subarray(this.at, this.at + length)).toString("utf8");
		this.at += length;
		return text;
	}
	limits() {
		const flags = this.u32();
		this.u32();
		if (flags & 1) this.u32();
	}
}

/** A module's sections: `{ id, name, start, end }`, `start` where its contents begin (after a custom
 * section's name). */
function sectionsOf(bytes) {
	const r = new Reader(bytes, 8);
	const out = [];
	while (r.at < bytes.length) {
		const at = r.at;
		const id = r.u8();
		const size = r.u32();
		const end = r.at + size;
		let name = null;
		let start = r.at;
		if (id === 0) {
			name = r.name();
			start = r.at;
		}
		out.push({ id, name, at, start, end, base: end - size });
		r.at = end;
	}
	return out;
}

/** What `parse` needs of a module: imported functions and globals, code bodies (their offsets from
 * the code section's start), data segments, the function names (name section). */
function parse(bytes) {
	const sections = sectionsOf(bytes);
	const module = { bytes, sections, importedFuncs: 0, globals: [], bodies: [], segments: [], names: new Map(), elems: [], codeIndex: -1, dataIndex: -1 };
	sections.forEach((section, index) => {
		const r = new Reader(bytes, section.start);
		if (section.id === 2) {
			for (let n = r.u32(); n > 0; n--) {
				const from = r.name();
				const field = r.name();
				const kind = r.u8();
				if (kind === 0) {
					r.u32();
					module.importedFuncs++;
				} else if (kind === 1) {
					r.u8();
					r.limits();
				} else if (kind === 2) r.limits();
				else if (kind === 3) {
					r.u8();
					r.u8();
					module.globals.push({ from, field });
				} else if (kind === 4) {
					r.u8();
					r.u32();
				}
			}
		} else if (section.id === 10) {
			module.codeIndex = index;
			for (let n = r.u32(); n > 0; n--) {
				const start = r.at - section.base;
				const size = r.u32();
				r.at += size;
				module.bodies.push({ start, end: r.at - section.base });
			}
		} else if (section.id === 11) {
			module.dataIndex = index;
			for (let n = r.u32(); n > 0; n--) {
				const flags = r.u32();
				let offset = null;
				if (flags === 0 || flags === 2) {
					if (flags === 2) r.u32();
					if (r.u8() !== 0x41) throw new Error("rocx split: a data segment's offset isn't an i32.const");
					offset = r.s32();
					if (r.u8() !== 0x0b) throw new Error("rocx split: a data segment's offset isn't a constant");
				}
				const size = r.u32();
				module.segments.push({ start: r.at - section.base, offset, size, bytes: bytes.subarray(r.at, r.at + size) });
				r.at += size;
			}
		} else if (section.id === 9) {
			module.elems = [];
			for (let n = r.u32(); n > 0; n--) {
				const flags = r.u32();
				if (flags !== 0) throw new Error(`rocx split: an element segment of a kind this doesn't read (${flags})`);
				if (r.u8() !== 0x41) throw new Error("rocx split: an element segment's offset isn't an i32.const");
				const offset = r.s32();
				r.u8();
				const funcs = [];
				for (let k = r.u32(); k > 0; k--) funcs.push(r.u32());
				module.elems.push({ offset, funcs });
			}
		} else if (section.id === 0 && section.name === "name") {
			while (r.at < section.end) {
				const sub = r.u8();
				const size = r.u32();
				const end = r.at + size;
				if (sub === 1) for (let n = r.u32(); n > 0; n--) module.names.set(r.u32(), r.name());
				r.at = end;
			}
		}
	});
	return module;
}

/** An object's symbols (linking section): `{ kind: "f"|"d"|"g"|"other", name, index, undefined, segment, offset, size }`. */
function symbolsOf(object) {
	const linking = object.sections.find((section) => section.id === 0 && section.name === "linking");
	if (!linking) throw new Error("rocx split: the app's object has no linking section");
	const r = new Reader(object.bytes, linking.start);
	r.u32();
	const symbols = [];
	while (r.at < linking.end) {
		const kind = r.u8();
		const size = r.u32();
		const end = r.at + size;
		if (kind === 8) {
			for (let n = r.u32(); n > 0; n--) {
				const symbolKind = r.u8();
				const flags = r.u32();
				const undef = (flags & 0x10) !== 0;
				if (symbolKind === 0 || symbolKind === 2 || symbolKind === 4 || symbolKind === 5) {
					const index = r.u32();
					const name = !undef || flags & 0x40 ? r.name() : null;
					symbols.push({ kind: symbolKind === 0 ? "f" : symbolKind === 2 ? "g" : "other", name, index, undefined: undef });
				} else if (symbolKind === 1) {
					const name = r.name();
					if (undef) symbols.push({ kind: "d", name, undefined: true });
					else symbols.push({ kind: "d", name, segment: r.u32(), offset: r.u32(), size: r.u32(), undefined: false });
				} else if (symbolKind === 3) {
					r.u32();
					symbols.push({ kind: "other", name: null });
				}
			}
		}
		r.at = end;
	}
	return symbols;
}

const ADDEND = new Set([3, 4, 5, 8, 9, 11, 14, 15, 16, 17, 21, 22, 23, 25]);
const CALL = new Set([0, 26]);
const TABLE = new Set([1, 2, 12, 18, 19, 24]);
const MEMORY = new Set([3, 4, 5, 11, 14, 15, 16, 17, 21, 23, 25]);
const GOT = new Set([7, 13]);

/** An object's relocations: `{ target, type, offset, index, addend }`, `target` the section index. */
function relocationsOf(object) {
	const out = [];
	for (const section of object.sections) {
		if (section.id !== 0 || !section.name.startsWith("reloc.")) continue;
		const r = new Reader(object.bytes, section.start);
		const target = r.u32();
		for (let n = r.u32(); n > 0; n--) {
			const type = r.u8();
			const offset = r.u32();
			const index = r.u32();
			const addend = ADDEND.has(type) ? r.s32() : 0;
			out.push({ target, type, offset, index, addend });
		}
	}
	return out;
}

/** The members of an `ar` archive (GNU's long names too): `{ name, bytes }`. */
function membersOf(archive) {
	if (Buffer.from(archive.subarray(0, 8)).toString("latin1") !== "!<arch>\n") throw new Error("rocx split: not an archive");
	const out = [];
	let longNames = "";
	for (let at = 8; at + 60 <= archive.length; ) {
		const header = Buffer.from(archive.subarray(at, at + 60)).toString("latin1");
		let name = header.slice(0, 16).trim();
		const size = Number(header.slice(48, 58).trim());
		const bytes = archive.subarray(at + 60, at + 60 + size);
		if (name === "//") longNames = Buffer.from(bytes).toString("latin1");
		else if (name !== "/") {
			if (/^\/\d+$/.test(name)) {
				const from = Number(name.slice(1));
				name = longNames.slice(from, longNames.indexOf("\n", from));
			}
			out.push({ name: name.replace(/\/$/, ""), bytes });
		}
		at += 60 + size + (size & 1);
	}
	return out;
}

/** An object's references, by name: `{ from, to, at }` (`at`: where in a data object it points),
 * from its relocations: calls and functions' places in the table (`F:`), data (`D:`), through the
 * GOT too (a position-independent object's). */
function referencesOf(bytes) {
	const object = parse(bytes);
	const symbols = symbolsOf(object);
	const funcName = new Map();
	const aliases = new Map();
	for (const symbol of symbols)
		if (symbol.kind === "f" && symbol.name && !symbol.undefined && symbol.index >= object.importedFuncs) {
			funcName.set(symbol.index - object.importedFuncs, symbol.name);
			(aliases.get(symbol.index) ?? aliases.set(symbol.index, []).get(symbol.index)).push(symbol.name);
		}
	const inSegment = new Map();
	for (const symbol of symbols) if (symbol.kind === "d" && !symbol.undefined) (inSegment.get(symbol.segment) ?? inSegment.set(symbol.segment, []).get(symbol.segment)).push(symbol);
	const dataAt = (sectionOffset) => {
		const segment = object.segments.findIndex((s) => s.start <= sectionOffset && sectionOffset < s.start + s.size);
		if (segment < 0) return null;
		const within = sectionOffset - object.segments[segment].start;
		return (inSegment.get(segment) ?? []).find((symbol) => symbol.offset <= within && within < symbol.offset + Math.max(symbol.size, 1))?.name ?? null;
	};
	const bodyAt = (offset) => {
		let lo = 0;
		let hi = object.bodies.length - 1;
		while (lo <= hi) {
			const mid = (lo + hi) >> 1;
			const body = object.bodies[mid];
			if (offset < body.start) hi = mid - 1;
			else if (offset >= body.end) lo = mid + 1;
			else return mid;
		}
		return -1;
	};
	const out = [];
	for (const reloc of relocationsOf(object)) {
		const symbol = symbols[reloc.index];
		let to = null;
		if (GOT.has(reloc.type) && symbol.kind === "g" && symbol.undefined && symbol.index < object.globals.length) {
			const { from, field } = object.globals[symbol.index];
			if (from === "GOT.mem") to = `D:${field}`;
			else if (from === "GOT.func") to = `F:${field}`;
		} else if ((CALL.has(reloc.type) || TABLE.has(reloc.type)) && symbol.kind === "f" && symbol.name) to = `F:${symbol.name}`;
		else if (MEMORY.has(reloc.type) && symbol.kind === "d" && symbol.name) to = `D:${symbol.name}`;
		if (!to) continue;
		let from = null;
		if (reloc.target === object.codeIndex) {
			const name = funcName.get(bodyAt(reloc.offset));
			if (name !== undefined) from = `F:${name}`;
		} else if (reloc.target === object.dataIndex) {
			const name = dataAt(reloc.offset);
			if (name) from = `D:${name}`;
		}
		if (from) out.push({ from, to, at: reloc.addend });
	}
	// One function may have several names (`roc_mount`, a public name, and its procedure's): each
	// group, so every reference is the function's, whichever name the wasm keeps.
	out.aliases = [...aliases.values()].filter((names) => names.length > 1);
	return out;
}

// ---- The graph ----

/**
 * Who owns what: each defined function (by its name in the wasm) and data object is the main
 * module's (`core`), one page's, `Shared`'s, or `Unreached`'s. `object`: the app's object (from the
 * archive build); `wasm`: the linked module (with names); `text`: binaryen's text of it.
 */
export function analyse({ object: objectBytes, unsealed = null, wasm: wasmBytes, text, words = true, doubt = "core" }) {
	const object = parse(objectBytes);
	const wasm = parse(wasmBytes);
	const symbols = symbolsOf(object);
	const finalNames = new Set(wasm.names.values());
	const funcName = new Map();
	for (const symbol of symbols) if (symbol.kind === "f" && symbol.name && !symbol.undefined && symbol.index >= object.importedFuncs) funcName.set(symbol.index - object.importedFuncs, symbol.name);
	const defined = new Set([...funcName.values()].filter((name) => finalNames.has(name)).map((name) => `F:${name}`));
	// Data objects at their place in the object's data (its segments are laid out, at offsets).
	const objects = symbols
		.filter((symbol) => symbol.kind === "d" && !symbol.undefined)
		.map((symbol) => ({ name: `D:${symbol.name}`, at: object.segments[symbol.segment].offset + symbol.offset, size: Math.max(symbol.size, 1), segment: symbol.segment, offset: symbol.offset, bytes: object.segments[symbol.segment].bytes.subarray(symbol.offset, symbol.offset + symbol.size) }))
		.sort((a, b) => a.at - b.at);
	const starts = objects.map((each) => each.at);
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
	const edge = (from, to) => (edges.get(from) ?? edges.set(from, new Set()).get(from)).add(to);
	/** References to a data object with where in it they point (`addend`): for the markers. */
	const pointing = new Map();
	const point = (from, to, at) => (pointing.get(to) ?? pointing.set(to, []).get(to)).push({ from, at });
	// The object's relocations; and the object it was composed from (`unsealed`), whose references
	// composing resolved into plain numbers are relocations there still.
	const references = [objectBytes, ...(unsealed ? [unsealed] : [])].map(referencesOf);
	// A function's names: the one the wasm keeps stands for all; one public (not a procedure's
	// `roc__p…`) makes it a root.
	const canonical = new Map();
	const publicNames = new Set();
	for (const names of references.flatMap((each) => each.aliases)) {
		const kept = names.find((name) => finalNames.has(name));
		if (!kept) continue;
		for (const name of names) canonical.set(`F:${name}`, `F:${kept}`);
		if (names.some((name) => !name.startsWith("roc__p"))) publicNames.add(`F:${kept}`);
	}
	const named = (node) => canonical.get(node) ?? node;
	for (const found of references)
		for (const { from, to, at } of found) {
			edge(named(from), named(to));
			if (to.startsWith("D:")) point(named(from), to, at);
		}
	// Where the object's data lands: its offset plus the base, from the markers (in both).
	const markers = new Map();
	for (const each of objects) {
		const text = Buffer.from(each.bytes).toString("latin1");
		for (const match of text.matchAll(/rocx-chunk:([A-Za-z0-9_]+)/g)) markers.set(match[1], { object: each, at: match.index, length: match[0].length });
	}
	if (!markers.size) throw new Error("rocx split: no page is marked in the app (build it with rocx build --split)");
	const finalText = (segment) => Buffer.from(segment.bytes).toString("latin1");
	const bases = new Set();
	for (const segment of wasm.segments)
		for (const match of finalText(segment).matchAll(/rocx-chunk:([A-Za-z0-9_]+)/g)) {
			const marker = markers.get(match[1]);
			if (marker) bases.add(segment.offset + match.index - (marker.object.at + marker.at));
		}
	if (bases.size !== 1) throw new Error(`rocx split: the app's data isn't where its object puts it, plus one base (${[...bases].join(", ") || "none found"})`);
	const [base] = bases;
	const objectAtFinal = (address) => objectAt(address - base);
	// References Roc's combining resolved into constants: in code, and in data. The host's code
	// (functions the app's object doesn't have) is the main module's: what it calls, and the app's data
	// it holds the address of, start from it (`HOST`).
	const HOST = "H:host";
	/** Each function's small constants, any of which may be a table slot Roc's composition wrote. */
	const small = new Map();
	const stack = [];
	let current = null;
	for (const line of text.split("\n")) {
		if (line.startsWith(" (func ")) {
			current = `F:${line.slice(7).split(" ")[0].slice(1)}`;
			stack.length = 0;
			continue;
		}
		if (!current) continue;
		const host = !defined.has(current);
		// Where the line is: binaryen writes one operand a line, each a space deeper than its parent.
		const depth = line.length - line.trimStart().length;
		while (stack.length && stack[stack.length - 1].depth >= depth) stack.pop();
		const parent = stack[stack.length - 1];
		if (parent) parent.children++;
		const op = line.trimStart().split(/[\s)]/)[0];
		stack.push({ depth, op, children: 0 });
		// A number stored to memory (a store's value, its second operand) that is a slot: a function's
		// place in the table, written into a closure; the only small number taken as one in code.
		const stored = parent && /^\(i(32|64)\.store$/.test(parent.op) && parent.children === 2 ? /^\s*\(i32\.const (\d+)\)$/.exec(line) : null;
		if (stored && Number(stored[1]) > 0 && Number(stored[1]) < base) (small.get(host ? HOST : current) ?? small.set(host ? HOST : current, new Set()).get(host ? HOST : current)).add(Number(stored[1]));
		if (host && line.includes("(call ")) for (const match of line.matchAll(/\(call \$(\S+)/g)) if (defined.has(`F:${match[1]}`)) edge(HOST, `F:${match[1]}`);
		if (!line.includes("i32.const")) continue;
		for (const match of line.matchAll(/\(i32\.const (\d+)\)/g)) {
			const address = Number(match[1]);
			if (address < base) continue;
			const to = objectAtFinal(address);
			if (!to) continue;
			edge(host ? HOST : current, to.name);
			if (!host) point(current, to.name, address - base - to.at);
		}
	}
	// A function's place in the table, which Roc's composition writes into code and data as a number
	// with no relocation left: such a number is noted (`small`), for what nothing else reaches.
	const slots = new Map();
	for (const elem of wasm.elems) elem.funcs.forEach((index, k) => slots.set(elem.offset + k, wasm.names.get(index)));
	// Words are read from the data as it lands in memory: a segment may be shorter than a word, the
	// rest of it the zeros of fresh memory.
	if (words && wasm.segments.length) {
		const low = Math.min(...wasm.segments.map((segment) => segment.offset)) & ~3;
		const high = Math.max(...wasm.segments.map((segment) => segment.offset + segment.size));
		const image = new Uint8Array(high - low + 4);
		for (const segment of wasm.segments) image.set(segment.bytes, segment.offset - low);
		const view = new DataView(image.buffer);
		for (let k = 0; k + 4 <= image.length; k += 4) {
			const word = view.getUint32(k, true);
			if (word === 0) continue;
			const at = low + k;
			const from = at < base ? { name: HOST } : objectAtFinal(at);
			if (!from) continue;
			if (word < base) {
				// Maybe a slot (weak: data is full of small numbers), used only for what nothing reaches.
				if (slots.has(word)) (small.get(from.name) ?? small.set(from.name, new Set()).get(from.name)).add(word);
				continue;
			}
			const to = objectAtFinal(word);
			if (to && to !== from) edge(from.name, to.name);
		}
	}
	// Each page's entry: what refers to its marker (through data, a few levels up).
	const entries = new Map();
	for (const [page, marker] of markers) {
		const found = new Set();
		let frontier = new Set((pointing.get(marker.object.name) ?? []).filter((ref) => marker.at - 16 <= ref.at && ref.at <= marker.at).map((ref) => ref.from));
		for (let depth = 0; depth < 4 && frontier.size; depth++) {
			for (const node of frontier) if (node.startsWith("F:")) found.add(node);
			frontier = new Set([...frontier].filter((node) => node.startsWith("D:")).flatMap((node) => (pointing.get(node) ?? []).map((ref) => ref.from)));
		}
		const live = [...found].filter((name) => defined.has(name));
		if (!live.length) throw new Error(`rocx split: found no entry for ${page}`);
		entries.set(page, live);
	}
	const stop = new Set([...entries.values()].flat());
	// Data nothing refers to is reached some way no reference shows (static data the runtime finds by
	// itself): it, and what it points to, are the main module's.
	const referenced = new Set();
	for (const targets of edges.values()) for (const target of targets) referenced.add(target);
	const unreferenced = objects.filter((each) => !referenced.has(each.name) && edges.has(each.name)).map((each) => each.name);
	// Every public function either object has (the entries the host calls, `roc_mount`, the runtime's),
	// whether or not the wasm keeps its name: what it refers to is the main module's.
	const publicFunctions = [...edges.keys()].filter((node) => node.startsWith("F:") && !node.slice(2).startsWith("roc__p"));
	const roots = [HOST, ...unreferenced, ...publicNames, ...publicFunctions, ...[...defined].filter((name) => !name.slice(2).startsWith("roc__p"))];
	const reach = (from, stopAt) => {
		const seen = new Set();
		const todo = from.filter((node) => !stopAt.has(node));
		while (todo.length) {
			const node = todo.pop();
			if (seen.has(node)) continue;
			seen.add(node);
			for (const next of edges.get(node) ?? []) if (!seen.has(next) && !stopAt.has(next)) todo.push(next);
		}
		return seen;
	};
	// Who owns what, by the references that are certain: what the main module's roots reach is its
	// own; what one page's entry reaches besides is that page's; what two or more pages', Shared's.
	const core = reach(roots, stop);
	const per = new Map([...entries].map(([page, fns]) => [page, [...reach(fns, new Set())].filter((node) => !core.has(node))]));
	const count = new Map();
	for (const nodes of per.values()) for (const node of nodes) count.set(node, (count.get(node) ?? 0) + 1);
	const owner = new Map();
	for (const node of core) owner.set(node, "core");
	for (const [page, nodes] of per) for (const node of nodes) owner.set(node, count.get(node) === 1 ? page : SHARED);
	// Then a function nothing reaches, but whose place in the table something holds as a number (Roc's
	// composition writes slots with no relocation left: a constant stored to memory, a word of data).
	// A page's own holder is taken over the main module's, where small numbers are everywhere; the
	// function, and what it reaches that nothing owns yet, goes with its holder. What has no holder
	// stays Unreached, and so does its data (see below).
	const join = (a, b) => (!a ? b : a === b ? a : a === "core" || b === "core" ? "core" : SHARED);
	const slotOf = new Map([...slots].filter(([, name]) => name && defined.has(`F:${name}`)).map(([slot, name]) => [slot, `F:${name}`]));
	for (let round = 0; doubt !== "core" && round < 8; round++) {
		const claims = new Map();
		for (const [holder, numbers] of small) {
			const held = holder === HOST ? "core" : owner.get(holder);
			if (!held) continue;
			for (const number of numbers) {
				const orphan = slotOf.get(number);
				if (!orphan || owner.has(orphan)) continue;
				edge(holder, orphan);
				const claim = claims.get(orphan) ?? { pages: new Set(), core: false };
				if (held === "core") claim.core = true;
				else claim.pages.add(held);
				claims.set(orphan, claim);
			}
		}
		if (!claims.size) break;
		for (const [orphan, claim] of claims) {
			const pages = [...claim.pages].filter((page) => page !== SHARED);
			const given = claim.pages.size ? (pages.length === 1 && !claim.pages.has(SHARED) ? pages[0] : SHARED) : "core";
			const todo = [orphan];
			while (todo.length) {
				const node = todo.pop();
				if (owner.has(node) && node !== orphan) continue;
				owner.set(node, join(owner.get(node) === undefined || node === orphan ? undefined : owner.get(node), given));
				for (const next of edges.get(node) ?? []) if (!owner.has(next)) todo.push(next);
			}
		}
	}
	// What nothing is known to reach: the main module's (`doubt`), since a page loading code it didn't
	// say it needs would have to stop where it is (an abort through Roc's frames) and wait for it.
	for (const node of [...defined, ...objects.map((each) => each.name)]) if (!owner.has(node)) owner.set(node, doubt === "core" ? "core" : UNREACHED);
	const functions = new Map();
	for (const node of defined) if (owner.get(node) !== "core") (functions.get(owner.get(node)) ?? functions.set(owner.get(node), []).get(owner.get(node))).push(node.slice(2));
	// Data moves only to a chunk some page loads. Unlike a function, whose call into a chunk not yet in
	// waits for it, data read where it isn't would be zeros: what nothing seems to reach stays.
	const data = objects.filter((each) => !["core", UNREACHED].includes(owner.get(each.name))).map((each) => ({ at: base + each.at, size: each.size, owner: owner.get(each.name) }));
	// What stays, byte by byte: a symbol may share its bytes with another (merged constants), and a
	// byte any object of the main module's covers is the main module's.
	const kept = objects.filter((each) => ["core", UNREACHED].includes(owner.get(each.name))).map((each) => ({ at: base + each.at, size: each.size }));
	// What a page loads: the chunks of what its own code reaches (the claims above included), not
	// going on through the main module, which is always there (what it calls in a chunk, it waits for).
	const mainModule = new Set([...owner].filter(([, each]) => each === "core").map(([node]) => node));
	const needs = new Map([...entries].map(([page, fns]) => [page, [...new Set([page, ...[...reach(fns, mainModule)].map((node) => owner.get(node))])].filter((each) => each !== "core" && each !== UNREACHED).sort((a, b) => (a === page ? -1 : b === page ? 1 : a < b ? -1 : 1))]));
	return { pages: [...entries.keys()].sort(), functions, data, kept, needs, base, debug: { owner, edges, roots, entries, canonical, publicNames } };
}

// ---- Moving data into the chunks ----

const uleb = (n) => {
	const out = [];
	do {
		let byte = n & 0x7f;
		n = Math.floor(n / 128);
		if (n) byte |= 0x80;
		out.push(byte);
	} while (n);
	return Buffer.from(out);
};
const sleb = (n) => {
	const out = [];
	for (;;) {
		const byte = n & 0x7f;
		n = Math.floor(n / 128);
		if ((n === 0 && !(byte & 0x40)) || (n === -1 && byte & 0x40)) {
			out.push(byte);
			return Buffer.from(out);
		}
		out.push(byte | 0x80);
	}
};
const section = (id, payload) => Buffer.concat([Buffer.from([id]), uleb(payload.length), payload]);

/** Bytes by address (`bytes`: this module's own, zeros too), as runs of what isn't zero, joined over
 * a gap shorter than a segment's header only when the gap is its own bytes too: a module's segment
 * must never write over another's data (a chunk's are written after the main module's, and would
 * zero what it set). */
function runsOf(bytes) {
	const addresses = [...bytes.keys()].filter((address) => bytes.get(address)).sort((a, b) => a - b);
	const runs = [];
	for (const address of addresses) {
		const last = runs[runs.length - 1];
		const end = last ? last.at + last.bytes.length : 0;
		let own = last && address - end < 8;
		for (let gap = end; own && gap < address; gap++) own = bytes.has(gap);
		if (own) {
			for (let gap = end; gap < address; gap++) last.bytes.push(bytes.get(gap));
			last.bytes.push(bytes.get(address));
		} else runs.push({ at: address, bytes: [bytes.get(address)] });
	}
	return runs;
}

const dataSection = (runs) => Buffer.concat([uleb(runs.length), ...runs.map((run) => Buffer.concat([Buffer.from([0, 0x41]), sleb(run.at), Buffer.from([0x0b]), uleb(run.bytes.length), Buffer.from(run.bytes)]))]);

/** Moves the data `plan` gives a chunk out of `primary` into that chunk (`chunks`: owner → bytes),
 * at the same addresses. Answers the new primary and chunks. */
export function moveData(primary, chunks, plan, kept = []) {
	const parsed = parse(primary);
	const image = new Map();
	for (const segment of parsed.segments) for (let k = 0; k < segment.size; k++) image.set(segment.offset + k, segment.bytes[k]);
	const stays = new Set();
	for (const { at, size } of kept) for (let address = at; address < at + size; address++) stays.add(address);
	const moved = new Map();
	for (const { at, size, owner } of plan) {
		if (!chunks.has(owner)) continue;
		const into = moved.get(owner) ?? moved.set(owner, new Map()).get(owner);
		for (let address = at; address < at + size; address++)
			if (image.has(address) && !stays.has(address)) {
				into.set(address, image.get(address));
				image.delete(address);
			}
	}
	const runs = runsOf(image);
	const memory = parsed.sections.find((s) => s.id === 5);
	const limits = Buffer.from(primary.subarray(memory.start, memory.end)).subarray(1);
	const rebuilt = [Buffer.from(primary.subarray(0, 8))];
	for (const s of parsed.sections) {
		if (s.id === 11) rebuilt.push(section(11, dataSection(runs)));
		else if (s.id === 12) rebuilt.push(section(12, uleb(runs.length)));
		else rebuilt.push(Buffer.from(primary.subarray(s.at, s.end)));
	}
	const out = new Map();
	for (const [owner, bytes] of chunks) {
		const pieces = moved.get(owner);
		if (!pieces?.size) {
			out.set(owner, bytes);
			continue;
		}
		const chunk = parse(bytes);
		const raw = (s) => Buffer.from(bytes.subarray(s.at, s.end));
		const memoryImport = Buffer.concat([uleb(7), Buffer.from("primary"), uleb(6), Buffer.from("memory"), Buffer.from([2]), limits]);
		// A chunk with no memory import yet gets one: its data goes into the main module's memory.
		const importsOf = chunk.sections.find((s) => s.id === 2);
		let hasMemory = false;
		let importCount = 0;
		if (importsOf) {
			const r = new Reader(bytes, importsOf.start);
			importCount = r.u32();
			for (let n = importCount; n > 0; n--) {
				r.name();
				r.name();
				const kind = r.u8();
				if (kind === 2) {
					hasMemory = true;
					r.limits();
				} else if (kind === 0) r.u32();
				else if (kind === 1) {
					r.u8();
					r.limits();
				} else if (kind === 3) {
					r.u8();
					r.u8();
				} else if (kind === 4) {
					r.u8();
					r.u32();
				}
			}
		}
		const segments = runsOf(pieces);
		const parts = [Buffer.from(bytes.subarray(0, 8))];
		let imported = hasMemory;
		for (const s of chunk.sections) {
			// The import section comes after the type section (1), before everything else that isn't custom.
			if (!imported && s.id !== 0 && s.id !== 1 && s.id !== 2) {
				parts.push(section(2, Buffer.concat([uleb(1), memoryImport])));
				imported = true;
			}
			if (s.id === 2 && !imported) {
				const r = new Reader(bytes, s.start);
				r.u32();
				parts.push(section(2, Buffer.concat([uleb(importCount + 1), Buffer.from(bytes.subarray(r.at, s.end)), memoryImport])));
				imported = true;
			} else if (s.id === 12) parts.push(section(12, uleb(segments.length)));
			else if (s.id === 11) throw new Error(`rocx split: ${owner}'s chunk has data of its own`);
			else parts.push(raw(s));
			// The data section comes right after the code section.
			if (s.id === 10) parts.push(section(11, dataSection(segments)));
		}
		out.set(owner, Buffer.concat(parts));
	}
	return { primary: Buffer.concat(rebuilt), chunks: out };
}

// ---- Tools ----

/** The oldest binaryen whose wasm-split does what this needs (`--multi-split`); the Justfile pins 133. */
const MIN_BINARYEN = 120;

/** binaryen's tool `name`: the system's (on PATH, e.g. from Nix), else the one in .tools/binaryen. */
export function binaryen(name) {
	const system = spawnSync(name, ["--version"], { encoding: "utf8" });
	const version = Number(/version[ _](\d+)/.exec(system.stdout ?? "")?.[1] ?? 0);
	if (system.status === 0 && version >= MIN_BINARYEN) return name;
	const ours = join(ROCX, ".tools", "binaryen", "bin", name);
	if (existsSync(ours)) return ours;
	throw new Error(`rocx split: ${name} (binaryen) isn't on PATH or in .tools/binaryen: run \`just setup\`, or install binaryen (nixpkgs#binaryen)`);
}

function run(command, args, options = {}) {
	const done = spawnSync(command, args, { encoding: "utf8", maxBuffer: 1 << 30, ...options });
	if (done.status !== 0) throw new Error(`rocx split: ${command} ${args.join(" ")} failed:\n${done.stdout ?? ""}${done.stderr ?? ""}`);
	return done.stdout;
}

const brotli = (bytes) => brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length;

/** The server's `Chunks` (Generated/Chunks.roc): each page's chunks as `<link rel="preload">`s, in
 * the `<NoHydration>` Root puts before the page. `needs`: page → its chunks; empty before a split. */
export function chunksModule(needs = new Map(), { client = false } = {}) {
	const head = [
		"## Written by rocx build --split: what a page loads besides the browser's main wasm (app.wasm),",
		"## its chunks, which Root puts in a <NoHydration> before the page. On the server, a <link",
		"## rel=\"preload\"> for each (start.js reads them); in the browser's copy, the page's mark, which",
		"## tells the build where the page begins. Don't edit it.",
		"import pf.Html",
		"",
		"Chunks := [].{",
	];
	if (client) return [...head, "\tlinks : Str -> List(Html)", "\tlinks = |page| [Html.text(page)]", "}", "", "# rocx: generated from the routes: rocx build --split writes it.", ""].join("\n");
	const link = (owner) =>
		`Html.void("link", [Html.attr("rel", "preload"), Html.attr("href", ${JSON.stringify(`/rocx/${chunkFile(owner)}`)}), Html.attr("as", "fetch"), Html.attr("type", "application/wasm"), Html.attr("crossorigin", ""), Html.attr("data-rocx-chunk", ${JSON.stringify(owner)})])`;
	const branches = [...needs].sort(([a], [b]) => (a < b ? -1 : 1)).map(([page, owners]) => `if (page == ${JSON.stringify(MARKER + page)}) [${owners.map(link).join(", ")}]`);
	return [...head, "\tlinks : Str -> List(Html)", `\tlinks = |${branches.length ? "page" : "_page"}| ${[...branches, "[]"].join(" else ")}`, "}", "", "# rocx: generated from the routes: rocx build --split writes it.", ""].join("\n");
}

/**
 * Splits the browser's app. `roc`: the compiler; `app`: the browser's main.roc (rocx build
 * --client --split wrote it); `wasm`: it built with `--debug` (and `opts`, as for the archive);
 * `out`: the directory the page loads it from (`static/rocx`), where app.wasm and the chunks go;
 * `chunks`: the server's Generated/Chunks.roc, written with each page's. Answers sizes.
 */
export function split({ roc, app, wasm, out, opts = [], chunks, unsealed: unsealedObject = null }) {
	const work = mkdtempSync(join(tmpdir(), "rocx-split-"));
	try {
		// The object: the same app, the platform's wasm32 output an archive (in a copy of it).
		const header = readFileSync(app, "utf8");
		const declared = /pf:\s*platform\s+"([^"]+)"/.exec(header)?.[1];
		if (!declared) throw new Error(`rocx split: ${app} names no platform`);
		const platform = resolve(dirname(app), declared);
		const copy = join(work, "platform");
		cpSync(dirname(platform), copy, { recursive: true });
		const main = join(copy, "main.roc");
		const shared = readFileSync(main, "utf8");
		if (!/output:\s*Shared,/.test(shared)) throw new Error("rocx split: the platform's wasm32 output isn't Shared");
		writeFileSync(main, shared.replace(/output:\s*Shared,/, "output: Archive,"));
		const archive = join(work, "app.a");
		run(roc, ["build", "--target=wasm32", ...opts, "--debug", "--replace-dep", declared, main, `--output=${archive}`, app], { cwd: dirname(app) });
		const members = membersOf(readFileSync(archive));
		const object = members.find((member) => member.name !== "host.wasm" && member.name.endsWith(".o"));
		if (!object) throw new Error(`rocx split: the archive has no app object (${members.map((m) => m.name).join(", ")})`);
		const wasmBytes = readFileSync(wasm);
		const text = run(binaryen("wasm-dis"), [wasm]);
		// The object it was composed from, references and all: where the build kept it.
		const unsealed = unsealedObject ?? (process.env.ROCX_SPLIT_UNSEALED ? readFileSync(process.env.ROCX_SPLIT_UNSEALED) : null);
		const plan = analyse({ object: object.bytes, unsealed, wasm: wasmBytes, text });
		// The functions: binaryen's multi-split, then each chunk's data.
		const manifest = join(work, "manifest.txt");
		writeFileSync(manifest, `${[...plan.functions].map(([owner, names]) => `${owner}\n${names.sort().join("\n")}`).join("\n\n")}\n`);
		const pieces = join(work, "pieces");
		mkdirSync(pieces);
		run(binaryen("wasm-split"), ["--multi-split", wasm, "--manifest", manifest, "--out-prefix", `${pieces}/`, "-o", join(pieces, "primary.wasm"), "--strip-debug", "--placeholdermap"]);
		// Which function each placeholder stands for (`rocx: … placeholder N` names one), beside the
		// build with names, for whoever wonders why a page fetched a chunk it didn't name.
		cpSync(join(pieces, "primary.wasm.placeholders"), `${wasm}.placeholders`);
		rmSync(join(pieces, "primary.wasm.placeholders"));
		// Functions only: the data stays in the main module. A function in the wrong chunk is fetched
		// when it is first called (the call waits for it); data in the wrong place would read as
		// zeros, and not every reference to data shows in the object (Roc's runtime finds some itself).
		const done = { primary: readFileSync(join(pieces, "primary.wasm")), chunks: new Map(readdirSync(pieces).filter((file) => file !== "primary.wasm").map((file) => [file.replace(/\.wasm$/, ""), readFileSync(join(pieces, file))])) };
		mkdirSync(out, { recursive: true });
		for (const file of readdirSync(out)) if (/^app\.[A-Za-z0-9_]+\.wasm$/.test(file)) rmSync(join(out, file));
		writeFileSync(join(out, "app.wasm"), done.primary);
		for (const [owner, bytes] of done.chunks) writeFileSync(join(out, chunkFile(owner)), bytes);
		const sizes = { app: { bytes: done.primary.length, brotli: brotli(done.primary) } };
		for (const [owner, bytes] of done.chunks) sizes[owner] = { bytes: bytes.length, brotli: brotli(bytes) };
		const needs = Object.fromEntries([...plan.needs].map(([page, owners]) => [page, owners.filter((owner) => done.chunks.has(owner))]));
		const firstLoad = Object.fromEntries(Object.entries(needs).map(([page, owners]) => [page, sizes.app.brotli + owners.reduce((sum, owner) => sum + sizes[owner].brotli, 0)]));
		writeFileSync(join(out, "chunks.json"), `${JSON.stringify({ pages: needs, sizes, firstLoad }, null, "\t")}\n`);
		if (chunks) writeFileSync(chunks, chunksModule(new Map(Object.entries(needs))));
		return { pages: needs, sizes, firstLoad };
	} finally {
		rmSync(work, { recursive: true, force: true });
	}
}
