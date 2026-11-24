// The wasm and object readers of parked/src/split.mjs (lines 42–323), unchanged but exported, for
// the 2026-11-24 re-baseline (split2/). See ../parked/src/split.mjs for the original.
// ---- Reading wasm ----

export class Reader {
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
export function sectionsOf(bytes) {
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
export function parse(bytes) {
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
export function symbolsOf(object) {
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

export const ADDEND = new Set([3, 4, 5, 8, 9, 11, 14, 15, 16, 17, 21, 22, 23, 25]);
export const CALL = new Set([0, 26]);
export const TABLE = new Set([1, 2, 12, 18, 19, 24]);
export const MEMORY = new Set([3, 4, 5, 11, 14, 15, 16, 17, 21, 23, 25]);
export const GOT = new Set([7, 13]);

/** An object's relocations: `{ target, type, offset, index, addend }`, `target` the section index. */
export function relocationsOf(object) {
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
export function membersOf(archive) {
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
export function referencesOf(bytes) {
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
