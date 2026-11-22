// What the journal's tests share: the app built once at a time (rocx build writes Generated/ in
// the app's own folder, so two test files building at once would race; a lock directory takes
// turns), its server started with the journal's own files (`static/`) beside the built wasm, and a
// check that XML is well formed, for the feeds and the sitemap.
import { mkdirSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer } from "../../../packages/testing/index.mjs";

/** The journal's folder. */
export const dir = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The journal, built (`rocx build`, the browser's wasm, the server): `{ server, statics }`. */
export async function build() {
	const lock = join(dir, "build", "building.lock");
	mkdirSync(join(dir, "build"), { recursive: true });
	for (;;) {
		try {
			mkdirSync(lock);
			break;
		} catch {
			// A lock left by a build that died is ten minutes old: take it.
			if (Date.now() - (statSync(lock, { throwIfNoEntry: false })?.mtimeMs ?? Date.now()) > 10 * 60 * 1000) rmSync(lock, { recursive: true, force: true });
			await new Promise((resolve) => setTimeout(resolve, 200));
		}
	}
	try {
		return await buildForTests(dir);
	} finally {
		rmSync(lock, { recursive: true, force: true });
	}
}

/** The built journal's server, on a free port, serving the wasm and `static/` (styles, images). */
export async function start(built, options = {}) {
	return startServer(built.server, { statics: [...built.statics, join(dir, "static")], ...options });
}

/**
 * Throws unless `text` is well-formed XML: one root element, every element closed in order,
 * attributes quoted, and `&` only as an entity. Enough for the feeds and the sitemap, which have no
 * comments, CDATA or doctype. Its root element's name.
 */
export function wellFormed(text) {
	let rest = text.replace(/^<\?xml[^?]*\?>\s*/, "");
	const open = [];
	let root = null;
	const entities = /&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/;
	while (rest.length > 0) {
		const at = rest.indexOf("<");
		const text = at === -1 ? rest : rest.slice(0, at);
		if (entities.test(text)) throw new Error(`a bare & in text: ${JSON.stringify(text.slice(0, 80))}`);
		if (open.length === 0 && text.trim()) throw new Error(`text outside the root element: ${JSON.stringify(text.slice(0, 80))}`);
		if (at === -1) break;
		rest = rest.slice(at);
		const tag = /^<(\/?)([A-Za-z_][\w.:-]*)((?:\s+[A-Za-z_][\w.:-]*\s*=\s*(?:"[^"<]*"|'[^'<]*'))*)\s*(\/?)>/.exec(rest);
		if (!tag) throw new Error(`not a tag: ${JSON.stringify(rest.slice(0, 80))}`);
		const [whole, closing, name, attributes, selfClosing] = tag;
		if (entities.test(attributes)) throw new Error(`a bare & in <${name}>'s attributes`);
		if (closing) {
			const expected = open.pop();
			if (expected !== name) throw new Error(`</${name}> closes <${expected}>`);
		} else {
			if (open.length === 0) {
				if (root !== null) throw new Error(`a second root element, <${name}>`);
				root = name;
			}
			if (!selfClosing) open.push(name);
		}
		rest = rest.slice(whole.length);
	}
	if (open.length > 0) throw new Error(`<${open.at(-1)}> is never closed`);
	if (root === null) throw new Error("no root element");
	return root;
}
