// The platform's reference, read from the platform itself: every module the server platform exposes
// (server/platform/main.roc's `exposes`), each from its canonical source (web/platform for the
// modules both platforms have, which the server's build copies into server/platform; else
// server/platform), with its doc comment and, for each item of its block, its name, its type, and
// the `##` lines above it. The docs' reference page shows it (site/routes/platform/reference), and
// its test holds every effect to a doc comment, so neither can drift from the code.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { root, SHARED_MODULES } from "../server/build.mjs";
/** A Roc string literal holding `text` exactly: the site's own, for the modules it writes (rocx's is
 * Text.roc_string; this runs too often to go through the binary). */
export function rocString(text) {
	let out = '"';
	for (let i = 0; i < text.length; i++) {
		const c = text[i];
		const code = c.charCodeAt(0);
		if (c === "\\") out += "\\\\";
		else if (c === '"') out += '\\"';
		else if (c === "$" && text[i + 1] === "{") out += "\\$";
		else if (c === "\n") out += "\\n";
		else if (c === "\r") out += "\\r";
		else if (c === "\t") out += "\\t";
		else if (code < 0x20 || code === 0x7f) out += `\\u(${code.toString(16)})`;
		else out += c;
	}
	return out + '"';
}

/** The modules server/platform/main.roc exposes, in its order. */
export function exposedModules(base = root) {
	const main = readFileSync(join(base, "server", "platform", "main.roc"), "utf8");
	const list = /^\s*exposes\s*\[([^\]]*)\]/m.exec(main);
	if (!list) throw new Error("server/platform/main.roc: no `exposes [...]`");
	return list[1]
		.split(",")
		.map((name) => name.trim())
		.filter(Boolean);
}

/** Where a module is written: web/platform for one both platforms have, server/platform else. */
export const sourceOf = (name) => (SHARED_MODULES.includes(name) ? `web/platform/${name}.roc` : `server/platform/${name}.roc`);

/** The text of the `##` lines that end just above line `at` (indented by `indent`), without their `##`. */
function docAbove(lines, at, indent) {
	const prefix = `${indent}##`;
	let start = at;
	while (start > 0 && lines[start - 1].startsWith(prefix)) start--;
	return lines
		.slice(start, at)
		.map((line) => line.slice(prefix.length).replace(/^ /, ""))
		.join("\n")
		.trim();
}

/**
 * One module: its doc comment (the `##` lines above `Name :=` or `Name ::`), and each item of its
 * block (a line one tab in, `name : type`, the type joined if it spans lines; or `name =`, one with
 * no annotation): name, type, doc, and whether it is an effect (its name ends in `!`).
 */
export function readModule(name, base = root) {
	const file = sourceOf(name);
	const lines = readFileSync(join(base, file), "utf8").split("\n");
	const header = lines.findIndex((line) => new RegExp(`^${name}(\\(.*\\))?\\s*(:=|::)`).test(line));
	if (header < 0) throw new Error(`${file}: no \`${name} :=\` or \`${name} ::\``);
	const open = lines.findIndex((line, i) => i >= header && /\.\{\s*$/.test(line));
	const close = open < 0 ? -1 : lines.findIndex((line, i) => i > open && /^\}/.test(line));
	const items = [];
	const seen = new Set();
	for (let i = open + 1; open >= 0 && i < close; i++) {
		const annotated = /^\t([a-z_][a-zA-Z0-9_]*!?)\s*:(?!=)\s*(.*)$/.exec(lines[i]);
		const defined = /^\t([a-z_][a-zA-Z0-9_]*!?)\s*=(?!=)/.exec(lines[i]);
		if (annotated) {
			const parts = [annotated[2].trim()];
			// A type on more lines than one: each further line is indented more, up to the definition.
			while (i + 1 < close && /^\t\t/.test(lines[i + 1]) && !new RegExp(`^\\t${annotated[1].replace("!", "\\!")}\\s*=`).test(lines[i + 1])) parts.push(lines[++i].trim());
			// Joined as one line: `f(⏎a,⏎b,⏎)` as `f(a, b)`, `{⏎a : A,⏎}` as `{ a : A }`.
			const type = parts.slice(1).reduce((joined, part) => {
				if (/^[)\]]/.test(part)) return joined.replace(/,$/, "") + part;
				if (/^\}/.test(part)) return `${joined.replace(/,$/, "")} ${part}`;
				return /[([]$/.test(joined) ? joined + part : `${joined} ${part}`;
			}, parts[0]);
			const at = i - (parts.length - 1);
			items.push({ name: annotated[1], type, doc: docAbove(lines, at, "\t"), line: at + 1 });
			seen.add(annotated[1]);
		} else if (defined && !seen.has(defined[1])) {
			items.push({ name: defined[1], type: "", doc: docAbove(lines, i, "\t"), line: i + 1 });
			seen.add(defined[1]);
		}
	}
	return {
		name,
		file,
		shared: SHARED_MODULES.includes(name),
		doc: docAbove(lines, header, ""),
		effects: items.filter((item) => item.name.endsWith("!")),
		functions: items.filter((item) => !item.name.endsWith("!")),
	};
}

/** Every module the server platform exposes, read (`readModule`), in the order it exposes them. */
export function platformReference(base = root) {
	return exposedModules(base).map((name) => readModule(name, base));
}

/** The effects with no doc comment, as `Module.name! (file:line)`: none, or the docs have a gap. */
export function undocumented(modules) {
	return modules.flatMap((module) => module.effects.filter((effect) => !effect.doc).map((effect) => `${module.name}.${effect.name} (${module.file}:${effect.line})`));
}

/**
 * The parts of the docs, each module in one; a module none names is in "Other", at the end, so a new
 * one is never left off the page.
 */
export const GROUPS = [
	{ id: "requests", name: "Requests and HTTP", modules: ["Server", "Endpoint", "Middleware", "Router", "Http", "HttpResponse", "Events", "Call", "Submission", "OpenApi"] },
	{ id: "data", name: "Data", modules: ["Db", "Kv"] },
	{ id: "plugins", name: "Plugins", modules: ["Plugin"] },
	{ id: "background", name: "Background", modules: ["Actor", "Live"] },
	{ id: "crypto", name: "Crypto", modules: ["AesGcm", "Random"] },
	{ id: "system", name: "System", modules: ["Env", "Time", "Log", "Tcp"] },
	{ id: "components", name: "Components and reactivity", modules: ["Solid", "Html", "Show", "For", "Loading", "Errored", "Context", "Transition", "Title", "HttpStatusCode", "Browser", "Audio"] },
];

/** The modules, in their groups (`GROUPS`), in the order each lists them. */
export function grouped(modules) {
	const byName = new Map(modules.map((module) => [module.name, module]));
	const groups = GROUPS.map((group) => ({ ...group, modules: group.modules.filter((name) => byName.has(name)).map((name) => byName.get(name)) }));
	const placed = new Set(GROUPS.flatMap((group) => group.modules));
	const others = modules.filter((module) => !placed.has(module.name));
	return [...groups, ...(others.length ? [{ id: "other", name: "Other", modules: others }] : [])].filter((group) => group.modules.length);
}

/** A line of a doc comment as text and code: `a `b` c` is Text("a "), Mono("b"), Text(" c"). */
const inlines = (text) =>
	text
		.split("`")
		.map((piece, i) => ({ kind: i % 2 ? "Mono" : "Text", text: piece }))
		.filter((piece) => piece.text);

/**
 * A doc comment as blocks: paragraphs (lines joined), lists (`- ` lines), and code: a fenced block
 * (```), or lines indented four spaces.
 */
export function blocks(doc) {
	const lines = doc.split("\n");
	const out = [];
	let i = 0;
	while (i < lines.length) {
		const line = lines[i];
		if (!line.trim()) {
			i++;
		} else if (line.trimStart().startsWith("```")) {
			const code = [];
			for (i++; i < lines.length && !lines[i].trimStart().startsWith("```"); i++) code.push(lines[i]);
			i++;
			out.push({ kind: "Sample", code: code.join("\n") });
		} else if (/^ {4}/.test(line)) {
			const code = [];
			while (i < lines.length && (/^ {4}/.test(lines[i]) || (!lines[i].trim() && /^ {4}/.test(lines[i + 1] ?? "")))) code.push(lines[i++].slice(4));
			out.push({ kind: "Sample", code: code.join("\n") });
		} else if (/^- /.test(line)) {
			const items = [];
			while (i < lines.length && /^- /.test(lines[i])) {
				const item = [lines[i++].slice(2)];
				while (i < lines.length && /^ {2}\S/.test(lines[i])) item.push(lines[i++].trim());
				items.push(inlines(item.join(" ")));
			}
			out.push({ kind: "Bullets", items });
		} else {
			const text = [];
			while (i < lines.length && lines[i].trim() && !/^ {4}/.test(lines[i]) && !/^- /.test(lines[i]) && !lines[i].trimStart().startsWith("```")) text.push(lines[i++].trim());
			out.push({ kind: "Para", inlines: inlines(text.join(" ")) });
		}
	}
	return out;
}

/** The reference as a Roc module (site/Generated/PlatformReference.roc), for the page to show. */
export function referenceModule(modules) {
	const inline = (piece) => `${piece.kind}(${rocString(piece.text)})`;
	const block = (b) => {
		if (b.kind === "Sample") return `Sample(${rocString(b.code)})`;
		if (b.kind === "Bullets") return `Bullets([${b.items.map((item) => `[${item.map(inline).join(", ")}]`).join(", ")}])`;
		return `Para([${b.inlines.map(inline).join(", ")}])`;
	};
	const doc = (text) => `[${blocks(text).map(block).join(", ")}]`;
	const effect = (it) => `{ name: ${rocString(it.name)}, type: ${rocString(it.type)}, doc: ${doc(it.doc)} }`;
	const fn = (it) => `{ name: ${rocString(it.name)}, type: ${rocString(it.type)} }`;
	const module = (m) =>
		[
			"\t\t\t\t{",
			`\t\t\t\t\tname: ${rocString(m.name)},`,
			`\t\t\t\t\tfile: ${rocString(m.file)},`,
			`\t\t\t\t\tshared: Bool.${m.shared ? "True" : "False"},`,
			`\t\t\t\t\tdoc: ${doc(m.doc)},`,
			`\t\t\t\t\teffects: [${m.effects.map(effect).join(", ")}],`,
			`\t\t\t\t\tfunctions: [${m.functions.map(fn).join(", ")}],`,
			"\t\t\t\t},",
		].join("\n");
	const groups = grouped(modules);
	const count = (key) => modules.reduce((sum, m) => sum + m[key].length, 0);
	return [
		"## Written by site/build.mjs (site/reference.mjs): every module the server platform exposes, each",
		"## with its doc comment and its items', read from the platform's sources. Edit those (their `##`",
		"## comments), not this one.",
		"PlatformReference := [].{",
		"\tInline : [Text(Str), Mono(Str)]",
		"\tBlock : [Para(List(Inline)), Sample(Str), Bullets(List(List(Inline)))]",
		"\tEffect : { name : Str, type : Str, doc : List(Block) }",
		"\tFunction : { name : Str, type : Str }",
		"\tModule : { name : Str, file : Str, shared : Bool, doc : List(Block), effects : List(Effect), functions : List(Function) }",
		"\tGroup : { id : Str, name : Str, modules : List(Module) }",
		"",
		"\t## The groups, for the page's contents (`meta.toc`): their ids and names alone.",
		"\ttoc : List({ id : Str, label : Str })",
		`\ttoc = [${groups.map((g) => `{ id: ${rocString(g.id)}, label: ${rocString(g.name)} }`).join(", ")}]`,
		"",
		"\tmodule_count : U64",
		`\tmodule_count = ${modules.length}`,
		"",
		"\teffect_count : U64",
		`\teffect_count = ${count("effects")}`,
		"",
		"\tfunction_count : U64",
		`\tfunction_count = ${count("functions")}`,
		"",
		"\tgroups : List(Group)",
		"\tgroups = [",
		...groups.flatMap((g) => [
			"\t\t{",
			`\t\t\tid: ${rocString(g.id)},`,
			`\t\t\tname: ${rocString(g.name)},`,
			"\t\t\tmodules: [",
			...g.modules.map(module),
			"\t\t\t],",
			"\t\t},",
		]),
		"\t]",
		"}",
		"",
	].join("\n");
}
