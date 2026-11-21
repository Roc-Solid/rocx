// rocx: JSX-like markup in Roc. A .rocx file is Roc in which markup may stand wherever an
// expression can; `transpile` turns it into plain Roc that calls the platform's Html
// (web/platform/Html.roc: components, Solid-style), line for line, so that line N of the output is
// line N of the input and the compiler's line numbers point into the .rocx file. README.md
// describes the syntax.

import { scopeClass, scopeCss, UNSCOPED_ELEMENTS } from "./styles.mjs";

/** A problem in a .rocx file, at a line and column (both from 1). */
export class RocxError extends Error {
	constructor(reason, file, line, column) {
		super(`${file}:${line}:${column}: ${reason}`);
		this.reason = reason;
		this.file = file;
		this.line = line;
		this.column = column;
	}
}

/** The last lines of every generated file start with this; tools tell generated files by it. */
export const MARKER = "# rocx: generated from";

const VOID_ELEMENTS = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);
const RAW_TEXT_ELEMENTS = new Set(["script", "style"]);
// A component's handlers: `on:event={handler!}` runs an effect; `on:event.value={…}` and the others
// give it what the event says; `on:event.prevent={…}` takes over what the browser would do.
const HANDLERS = { "": "on", value: "on_value", checked: "on_checked", key: "on_key", prevent: "on_prevent" };
/** Which way each transition attribute plays (`Html.transition`'s first argument). */
const TRANSITION_WAYS = { transition: "Both", "transition:in": "In", "transition:out": "Out", "transition:move": "Move" };
// Words after which an expression begins, so a `<` after them starts markup.
const KEYWORDS_BEFORE_EXPRESSION = new Set(["else", "return", "crash", "expect", "dbg", "in"]);
const ENTITIES = {
	amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", copy: "©", reg: "®", trade: "™",
	mdash: "—", ndash: "–", hellip: "…", middot: "·", bull: "•", lsquo: "‘", rsquo: "’", ldquo: "“",
	rdquo: "”", laquo: "«", raquo: "»", times: "×", divide: "÷", rarr: "→", larr: "←", uarr: "↑", darr: "↓",
	check: "✓", deg: "°", euro: "€", pound: "£", sect: "§", para: "¶", shy: "­", thinsp: " ",
};

const isIdentStart = (c) => c !== undefined && /[A-Za-z_$]/.test(c);
const isIdentPart = (c) => c !== undefined && /[A-Za-z0-9_$!]/.test(c);
const isDigit = (c) => c !== undefined && /[0-9]/.test(c);

/** A Roc string literal holding `text` exactly. */
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

/**
 * Reactive, a component's prop named as an effect (`title!`) is an accessor, as Solid's compiler
 * makes a prop a getter: `title!={user!().name}` passes `|| user!().name`, so the component reads
 * it where it uses it, and is patched when it changes. A prop that already is a function, an
 * accessor's name (`title!`, `Store.title!`) or a lambda, is passed as it is. Other props are values.
 */
function accessorProp(name, expr) {
	if (!name.endsWith("!")) return expr;
	const code = expr.trim();
	if (/^([A-Za-z_][A-Za-z0-9_]*\.)*[a-z_][A-Za-z0-9_]*!$/.test(code) || code.startsWith("|")) return expr;
	return `|| ${expr}`;
}

/** `StatusPill` → `status_pill`: a component that is not an imported module is a local function. */
const snakeCase = (name) => name.replace(/[A-Z]/g, (c, i) => (i ? "_" : "") + c.toLowerCase());

/** `picks_context` → `PicksContext`: the tag of a context's provider, as Solid spells it. */
export const pascalCase = (name) => name.replace(/(^|_)([a-z0-9])/g, (_, __, c) => c.toUpperCase());

/** A context's definition, `name = create_context(…)`, at the top of a file or of its module. */
const CONTEXT_DEFINITION = /^(\t?)([a-z_][a-z0-9_]*)[ \t]*=[ \t]*create_context\(/gm;

/**
 * The contexts a file defines (`picks_context = create_context()`): their names, and whether each is
 * in the file's module (`Picks := [].{ … }`, indented), where other modules can name it.
 */
export function contextsDefined(source) {
	return [...source.matchAll(CONTEXT_DEFINITION)].map((match) => ({ name: match[2], shared: match[1] === "\t" }));
}

/** Text decoded as HTML would: `&amp;`, `&#39;`, `&#x2014;`. */
function decodeEntities(text, fail) {
	return text.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);/g, (whole, name) => {
		if (name[0] === "#") return String.fromCodePoint(name[1] === "x" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10));
		if (name in ENTITIES) return ENTITIES[name];
		fail(`unknown entity ${whole}; write the character itself`);
		return whole;
	});
}

/**
 * HTML's whitespace rule, as Svelte applies it: each run of spaces, tabs and newlines in text is
 * one space, and whitespace at the start and end of an element's children is dropped. So prose
 * may break lines anywhere, around links and values too. (`&nbsp;` is not whitespace.)
 */
function collapseWhitespace(raw, first, last) {
	let text = raw.replace(/[ \t\n\r\f]+/g, " ");
	if (first) text = text.trimStart();
	if (last) text = text.trimEnd();
	return text;
}

/** Elements whose text keeps its whitespace as written. */
const PREFORMATTED = new Set(["pre", "textarea"]);

/** A newline in the output, with the indentation the next source line has. */
class Newline {
	constructor(indent) {
		this.indent = indent;
	}
}

/** A component's child that is a function (`{|post, index!| …}`), as Solid's `<For>` and `<Show>` take. */
class FunctionChild {
	constructor(code) {
		this.code = code;
	}
}

/** Items of a Roc list or record, separated by commas, with newlines where the source had them. */
function items(parts) {
	let out = "";
	let pending = false;
	for (const part of parts) {
		if (part instanceof Newline) {
			if (pending) out += ",";
			pending = false;
			out += `\n${part.indent}`;
		} else {
			if (pending) out += ", ";
			out += part;
			pending = true;
		}
	}
	return pending ? `${out},` : out;
}

/** The types a file defines with a block, `Counter := [].{ … }`: their names. */
function typeBlocks(source) {
	return [...source.matchAll(/^([ \t]*)([A-Z][A-Za-z0-9_]*)(?:\([^)\n]*\))?[ \t]*:=(?:(?!\n\1[^\s\])}])[^])*?\.\{/gm)].map((match) => ({ name: match[2], at: match.index, indent: match[1] }));
}

/**
 * The components a file defines, each a type with a block (`Heading := [].{ … }`), and how each is
 * called: `view!`, a component that may make signals and read contexts, run where it is rendered
 * (`Html.component`); or `view`, a pure one (no `!`), which can do neither, so it is called where
 * it is written, like a function. `{ Heading: "view", Counter: "view!" }`; a block with neither
 * isn't there.
 */
export function viewsDefined(source) {
	const blocks = typeBlocks(source);
	const views = {};
	// A `view` is the block's it is a direct member of: the innermost one opened before it whose
	// indentation is less than its own (a type nested above it, `Name := [...].{ … }`, has members
	// indented deeper, and is closed by then).
	for (const match of source.matchAll(/^([ \t]+)view(!?)[ \t]*[:=]/gm)) {
		const owner = blocks.filter((block) => block.at < match.index && match[1].length > block.indent.length && match[1].startsWith(block.indent)).reduce((best, block) => (!best || block.indent.length >= best.indent.length ? block : best), null);
		if (owner && views[owner.name] !== "view!") views[owner.name] = match[2] ? "view!" : "view";
	}
	return views;
}

class Transpiler {
	constructor(source, file, { module, client = false, contexts = {}, views = {}, scopes = [] } = {}) {
		this.src = source;
		this.file = file;
		this.pos = 0;
		/** The module's name (`Demos/Echo`): its contexts are named after it. */
		this.module = module ?? file.split("/").pop().replace(/\.rocx$/, "");
		/** Whether this is the browser's copy, in which a `<NoHydration>` has no children. */
		this.client = client;
		/** The file's <style>s, scoped (styles.mjs): each `{ css, line, component, scope, from, to }`,
		 * where `from` and `to` are the offsets of the markup it styles: its component's block, or,
		 * at the file's top level, the whole file. */
		this.styles = [];
		/** The file's stories (`<story name="Tip">…</story>` in a component's block), each a
		 * definition there: `{ component, name, def, line }`. rocx build lists them in a dev build. */
		this.stories = [];
		/** Where each <style> found by a first run is (`{ scope, from, to }`): an element written
		 * between `from` and `to` gets its class (`rx-k3j9qa`), which every selector in it requires. */
		this.scopes = scopes;
		/** How many <pre> or <textarea> the parser is inside. */
		this.preformatted = 0;
		/** Where each markup expression and stylesheet code() read is, for rocx fmt: `{ kind, from, to }`. */
		this.spans = [];
		/** How many names of effects (`count!`, a component's `view!`) the code read so far has: a hole
		 * or attribute whose code adds none is static, written once, with nothing to run again. */
		this.effects = 0;
		/** How many `<NoHydration>`s the file has, and how many the parser is inside. */
		this.regions = 0;
		this.inRegion = 0;
		this.lineStarts = [0];
		for (let i = 0; i < source.length; i++) if (source[i] === "\n") this.lineStarts.push(i + 1);
		// Markup is components, written with the platform's Html (both platforms have it): there is
		// no other (the html package, which rendered static pages, is gone).
		const foreign = /^import[ \t]+([a-z_][a-z0-9_]*)\.Html\b/m.exec(source);
		if (foreign && foreign[1] !== "pf") this.fail(`import ${foreign[1]}.Html: markup is components, written with the platform's Html, which the server renders and the browser hydrates: import pf.Html`, foreign.index + foreign[0].indexOf(foreign[1]));
		// Modules imported by name: a component tag with one of these names calls its `view`.
		this.modules = new Set();
		// Those imported from a package (`import pf.Show`): a platform's components, which are markup.
		this.packaged = new Set();
		// `import Button`, `import ui.Button`, `import Ui/Button`, `import ../Ui/Button`, with or without `as`.
		for (const match of source.matchAll(/^import\s+(?:([a-z_][a-z0-9_]*)\.)?(?:\.{0,2}\/)*(?:[A-Za-z0-9_]+\/)*([A-Z][A-Za-z0-9]*)(?:\s+as\s+([A-Z][A-Za-z0-9]*))?/gm)) {
			const name = match[3] ?? match[2];
			this.modules.add(name);
			if (match[1]) this.packaged.add(name);
		}
		// And the components this file defines, each a type with a block (`Stepper := [].{ view! = … }`):
		// a file may have several.
		for (const { name } of typeBlocks(source)) this.modules.add(name);
		// Reactive, the contexts a provider's tag may name (`<PicksContext>`): this file's, and those of
		// the modules it imports (`contexts`, from rocx build: `{ PicksContext: "Picks.picks_context" }`).
		this.contexts = new Map();
		for (const [tag, defined] of Object.entries(contexts)) if (this.modules.has(defined.split(".")[0])) this.contexts.set(tag, defined);
		for (const { name } of contextsDefined(source)) this.contexts.set(pascalCase(name), name);
		// Reactive, the components that are pure (`view`, no `!`): called where they are written, not
		// put off. Those of the modules it imports (`views`, from rocx build: `{ Heading: "view" }`), and
		// this file's own.
		this.pure = new Set();
		const known = { ...views, ...viewsDefined(source) };
		for (const name of this.modules) if (known[name] === "view" && !this.packaged.has(name)) this.pure.add(name);
		// A function component of this file's (`card = |{ title }| …`, for `<Card>`) defined with no `!`
		// is pure too: called where it is written (`card({…})`).
		for (const [, name] of source.matchAll(/^[ \t]*([a-z][a-z0-9_]*)[ \t]*=[ \t]*\|/gm)) {
			const tag = pascalCase(name);
			if (!this.modules.has(tag) && snakeCase(tag) === name) this.pure.add(tag);
		}
	}

	location(pos) {
		let low = 0;
		let high = this.lineStarts.length - 1;
		while (low < high) {
			const mid = (low + high + 1) >> 1;
			if (this.lineStarts[mid] <= pos) low = mid;
			else high = mid - 1;
		}
		return [low + 1, pos - this.lineStarts[low] + 1];
	}

	fail(reason, pos = this.pos) {
		throw new RocxError(reason, this.file, ...this.location(pos));
	}

	startsWith(text) {
		return this.src.startsWith(text, this.pos);
	}

	/** The indentation of the line that starts at `pos`. */
	indentAt(pos) {
		let end = pos;
		while (this.src[end] === " " || this.src[end] === "\t") end++;
		return this.src.slice(pos, end);
	}

	// ---- Roc code ----

	/** Roc code, with any markup in it turned into calls; up to an unmatched `}` when inside a hole. */
	code(insideBraces) {
		const start = this.pos;
		let out = "";
		let depth = 0;
		let last = ""; // the last significant token: after a value, `<` is the less-than operator
		// Whether each open `(` holds an `if` or `while` condition: after its `)`, an expression starts.
		const parens = [];
		// Each open `{`: a type's block (`Counter := [].{`), where a <style> styles that component, or null.
		const blocks = [];
		let declared = null; // the type a `:=` just declared, whose block a `.{` would open
		while (this.pos < this.src.length) {
			const c = this.src[this.pos];
			if (c === "}" && insideBraces && depth === 0) return out;
			if (c === "(") {
				parens.push(last === "if" || last === "while");
				out += c;
				this.pos++;
				last = c;
			} else if (c === ")") {
				const condition = parens.pop();
				out += c;
				this.pos++;
				last = condition === true ? "(" : c;
			} else if (c === "{" || c === "[") {
				if (c === "{") {
					depth++;
					let back = this.pos - 1;
					while (back >= 0 && /\s/.test(this.src[back])) back--;
					const opensBlock = declared !== null && this.src[back] === ".";
					blocks.push(opensBlock ? { name: declared, from: this.pos, to: this.src.length, items: this.itemIndent(this.pos) } : null);
					if (opensBlock) declared = null;
				}
				out += c;
				this.pos++;
				last = c;
			} else if (c === "}") {
				depth--;
				const block = blocks.pop();
				if (block) block.to = this.pos;
				out += c;
				this.pos++;
				last = c;
			} else if (c === "#") {
				const end = this.src.indexOf("\n", this.pos);
				const stop = end < 0 ? this.src.length : end;
				out += this.src.slice(this.pos, stop);
				this.pos = stop;
			} else if (c === "\\" && this.src[this.pos + 1] === "\\") {
				out += this.multilineStringLine();
				last = '"';
			} else if (c === '"') {
				out += this.string();
				last = '"';
			} else if (c === "'") {
				out += this.charLiteral();
				last = "'";
			} else if (c === "<" && !insideBraces && this.directiveHere("story", depth, parens, blocks) !== undefined) {
				const from = this.pos;
				out += this.story(this.directiveHere("story", depth, parens, blocks));
				this.spans.push({ kind: "story", from, to: this.pos });
				last = ")";
			} else if (c === "<" && !insideBraces && this.stylesheetHere(depth, parens, blocks) !== undefined) {
				const from = this.pos;
				out = out.replace(/[ \t]*$/, "") + this.stylesheet(this.stylesheetHere(depth, parens, blocks));
				this.spans.push({ kind: "style", from, to: this.pos });
			} else if (c === "<" && this.markupStarts(last)) {
				const from = this.pos;
				out += this.markup();
				this.spans.push({ kind: "markup", from, to: this.pos });
				last = ")";
			} else if (isIdentStart(c) || isDigit(c)) {
				const begin = this.pos;
				while (isIdentPart(this.src[this.pos])) this.pos++;
				const word = this.src.slice(begin, this.pos);
				if (word === "create_context" && this.src[this.pos] === "(") {
					const { code, open } = this.context(out, begin);
					out += code;
					if (open) parens.push(false);
					last = open ? "(" : ")";
					continue;
				}
				if (word === "server!" && this.src[this.pos] === "(") {
					this.fail("server!(…) is gone (D-023): define a GET endpoint (get! in a route's +server.roc) and read it with Endpoint.get!(Api.get_…(params))", begin);
				}
				if (/^[A-Z]/.test(word) && /^[ \t]*(\([^)\n]*\))?[ \t]*:=/.test(this.src.slice(this.pos))) declared = word;
				if (word.endsWith("!")) this.effects++;
				out += word;
				last = word;
			} else {
				out += c;
				this.pos++;
				if (!/\s/.test(c)) last = c;
			}
		}
		if (insideBraces) this.fail("this { is never closed", start - 1);
		return out;
	}

	/**
	 * `name = create_context(default)`, or `create_context()` with none: Solid's context, named after
	 * its module and definition (`Picks.picks_context`), since Roc's values have no identity to tell
	 * two apart: `Context.define("Picks.picks_context", default)`, or `Context.required(…)`.
	 */
	context(out, begin) {
		const line = out.slice(out.lastIndexOf("\n") + 1);
		const defined = /^\s*([a-z_][A-Za-z0-9_]*)\s*=\s*$/.exec(line);
		if (!defined) this.fail("create_context(…) defines a context: write it as a definition, `name = create_context(…)`", begin);
		if (!/^import\s+[a-z_][a-z0-9_]*\.Context\b/m.test(this.src)) this.fail("create_context(…) needs `import pf.Context` in this file", begin);
		const named = rocString(`${this.module}.${defined[1]}`);
		this.pos++;
		let after = this.pos;
		while (this.src[after] === " ") after++;
		if (this.src[after] === ")") {
			this.pos = after + 1;
			return { code: `Context.required(${named})`, open: false };
		}
		return { code: `Context.define(${named}, `, open: true };
	}

	/**
	 * `<PicksContext value={…}>…</PicksContext>`: Solid 2.0's provider, the context's own tag. What is
	 * inside gets `value` for the context: `Context.provide!(picks_context, value, [what is inside])`.
	 */
	provider(name, attrs, start) {
		const children = this.children(name, start);
		if (children.some((child) => child instanceof FunctionChild)) this.fail(`a function child is a component's: <${name}> can't take one`, start);
		const fields = attrs.filter((field) => !(field instanceof Newline));
		if (fields.length !== 1 || !/^value: /.test(fields[0])) this.fail(`<${name}> gives its context a value: write <${name} value={…}>, and nothing else`, start);
		if (!/^import\s+[a-z_][a-z0-9_]*\.Context\b/m.test(this.src)) this.fail(`<${name}> needs \`import pf.Context\` in this file`, start);
		const value = attrs.map((field) => (field instanceof Newline ? `\n${field.indent}` : field.slice("value: ".length))).join("");
		return `Context.provide!(${this.contexts.get(name)}, ${value}, [${items(children)}])`;
	}

	/** The indentation of the first line with something on it after `pos`: a block's items'. */
	itemIndent(pos) {
		const next = /\n([ \t]*)(?=\S)/.exec(this.src.slice(pos));
		return next ? next[1] : "";
	}

	/**
	 * Whether the `<style` here is a stylesheet, and whose: first on its line, either in a type's
	 * block where its definitions go (that component's: the block), or at the file's top level, at
	 * the start of the line (the file's: null). Elsewhere (a definition's body, deeper in), it is
	 * markup, as written: `undefined`.
	 */
	stylesheetHere(depth, parens, blocks) {
		return this.directiveHere("style", depth, parens, blocks);
	}

	/** Whether the `<tag` here is that directive (`<style>`, `<story>`), and whose: as `stylesheetHere`. */
	directiveHere(tag, depth, parens, blocks) {
		if (parens.length || !new RegExp(`^<${tag}\\b`).test(this.src.slice(this.pos, this.pos + tag.length + 2))) return undefined;
		const lineStart = this.src.lastIndexOf("\n", this.pos - 1) + 1;
		const indent = this.src.slice(lineStart, this.pos);
		if (/\S/.test(indent)) return undefined;
		if (depth === 0) return indent === "" ? null : undefined;
		const block = blocks.at(-1);
		return block && blocks.length === depth && indent.length <= block.items.length ? block : undefined;
	}

	/**
	 * A <style> that is a stylesheet: its component's (`block`), or the file's (null). Its CSS is
	 * scoped to the markup it styles and kept for the stylesheet rocx build writes
	 * (Generated/Styles.roc); here, the lines it took, blank. (A <style> in markup is an element,
	 * its text as written: Svelte's nested <style>.)
	 */
	stylesheet(block) {
		const start = this.pos;
		const owner = block ?? { name: null, from: 0, to: this.src.length };
		if (this.styles.some((style) => style.component === owner.name)) {
			this.fail(owner.name ? `${owner.name} has a <style> already: put all its CSS in the first` : "a file has one <style> at its top level: put all its CSS in the first", start);
		}
		const tag = /^<style\s*>/.exec(this.src.slice(this.pos));
		if (!tag) this.fail(`${owner.name ? `${owner.name}'s` : "a file's"} <style> takes no attributes: write <style>`, start);
		const from = this.pos + tag[0].length;
		const closing = /<\/style\s*>/i.exec(this.src.slice(from));
		if (!closing) this.fail("<style> is never closed", start);
		const css = this.src.slice(from, from + closing.index);
		this.pos = from + closing.index + closing[0].length;
		const scope = scopeClass(owner.name ? `${this.module}.${owner.name}` : this.module);
		const scoped = scopeCss(css, scope, (reason, offset) => this.fail(`in <style>: ${reason}`, from + offset));
		// The block's end is known when its `}` is read: `owner` is the block itself, so `to` is read then.
		this.styles.push({ css: scoped, line: this.location(start)[0], component: owner.name, scope, get from() { return owner.from; }, get to() { return owner.to; } });
		return "\n".repeat(this.src.slice(start, this.pos).split("\n").length - 1);
	}

	/**
	 * `<story name="Tip">…</story>`, beside a component's definitions: a way it looks, for the dev
	 * build's catalog (`/__rocx/stories`), as a definition in its place (`story_tip`) that renders
	 * what is inside, given the page (`page`: `{ request, context }`), so every build checks it and
	 * only a dev build calls it.
	 */
	story(block) {
		const start = this.pos;
		if (!block) this.fail('a <story> goes in a component\'s block, beside its definitions: `Card := [].{ … <story name="Tip">…</story> }`', start);
		const tag = /^<story[ \t]+name="([^"\n]*)"[ \t]*>/.exec(this.src.slice(this.pos));
		if (!tag) this.fail('a <story> is named, and takes nothing else: <story name="Tip">', start);
		const name = tag[1].trim();
		const words = name.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
		if (!/^[a-z]/.test(words)) this.fail(`a story's name starts with a letter: "${name}"`, start);
		// A component's story is an effect's name, as its view is, and run where it is rendered (`Root`).
		const def = `story_${words}!`;
		const twin = this.stories.find((story) => story.component === block.name && story.def === def);
		if (twin) this.fail(`${block.name} has a story "${twin.name}" already, which "${name}" would be named like (${def})`, start);
		this.pos += tag[0].length;
		const children = this.children("story", start);
		this.stories.push({ component: block.name, name, def, line: this.location(start)[0] });
		// It is given nothing: what it needs, it asks for, as a component does (`Router.location!`).
		return `${def} = |{}| Html.join([${items(children)}])`;
	}

	/** The classes of the <style>s whose markup the element at `pos` is in. */
	scopesAt(pos) {
		return this.scopes.filter((scope) => scope.from <= pos && pos <= scope.to).map((scope) => scope.scope);
	}

	/** Whether the `<` here starts markup: an expression may begin here, and a tag follows. */
	markupStarts(last) {
		const next = this.src[this.pos + 1];
		const tagFollows = (next !== undefined && /[A-Za-z>]/.test(next)) || /^<!doctype\b/i.test(this.src.slice(this.pos, this.pos + 10));
		if (!tagFollows) return false;
		if (last === "" || KEYWORDS_BEFORE_EXPRESSION.has(last)) return true;
		// First on its line: a block's last expression after a statement that ended in `}` or `)`.
		// (A comparison continued on the next line starting with `<` would need parentheses.)
		let back = this.pos - 1;
		while (back >= 0 && (this.src[back] === " " || this.src[back] === "\t")) back--;
		if (back < 0 || this.src[back] === "\n") return true;
		const end = last[last.length - 1];
		return !(isIdentPart(end) || [")", "]", "}", '"', "'", "?"].includes(end));
	}

	string() {
		const start = this.pos++;
		let out = '"';
		for (;;) {
			const c = this.src[this.pos];
			if (c === undefined || c === "\n") this.fail("this string is never closed", start);
			if (c === "\\") {
				out += c + this.src[this.pos + 1];
				this.pos += 2;
			} else if (c === "$" && this.src[this.pos + 1] === "{") {
				this.pos += 2;
				out += `\${${this.code(true)}}`;
				this.pos++;
			} else if (c === '"') {
				this.pos++;
				return `${out}"`;
			} else {
				out += c;
				this.pos++;
			}
		}
	}

	multilineStringLine() {
		let out = "";
		while (this.pos < this.src.length && this.src[this.pos] !== "\n") {
			if (this.startsWith("${")) {
				this.pos += 2;
				out += `\${${this.code(true)}}`;
				this.pos++;
			} else {
				out += this.src[this.pos++];
			}
		}
		return out;
	}

	charLiteral() {
		const start = this.pos++;
		while (this.src[this.pos] !== "'") {
			if (this.src[this.pos] === undefined || this.src[this.pos] === "\n") this.fail("this character literal is never closed", start);
			if (this.src[this.pos] === "\\") this.pos++;
			this.pos++;
		}
		this.pos++;
		return this.src.slice(start, this.pos);
	}

	// ---- markup ----

	/** One element, component, fragment or doctype, as a Roc expression. */
	markup() {
		const start = this.pos;
		const doctype = /^<!doctype\s+html\s*>/i.exec(this.src.slice(this.pos, this.pos + 40));
		if (doctype) {
			this.pos += doctype[0].length;
			return "Html.doctype({})";
		}
		this.pos++;
		if (this.src[this.pos] === ">") {
			this.pos++;
			const parts = this.children("", start);
			if (parts.some((child) => child instanceof FunctionChild)) this.fail("a function child is a component's: <> can't take one", start);
			return `Html.join([${items(parts)}])`;
		}
		const name = /^[A-Za-z][A-Za-z0-9-]*/.exec(this.src.slice(this.pos))?.[0];
		if (!name) this.fail("expected a tag name after <");
		this.pos += name.length;
		// `<DIV>` is an HTML tag in capitals, not a component: a component's name has lower case in it.
		if (name.length > 1 && name === name.toUpperCase() && /[A-Z]/.test(name)) this.fail(`write HTML tags in lower case: <${name.toLowerCase()}>`, start);
		const component = /^[A-Z]/.test(name);
		if (component && name.includes("-")) this.fail(`a component's name is a Roc name: <${name}> has a -`, start);
		if (!component && name !== name.toLowerCase()) this.fail(`write HTML tags in lower case: <${name.toLowerCase()}>`, start);
		const { attrs, selfClosing, readsProps } = this.attributes(name, component, start);
		if (name === "NoHydration") return this.noHydration(attrs, selfClosing, start);

		// A component is an effect (`Picks.view!`), and so is a provider (`Context.provide!`); a pure
		// one (`Heading.view`) isn't.
		const pure = component && this.pure.has(name);
		if (component && !pure) this.effects++;
		if (component && this.contexts.has(name)) {
			if (selfClosing) this.fail(`<${name}> gives its context to what is inside: it needs children`, start);
			return this.provider(name, attrs, start);
		}
		if (component) {
			let fields = [...attrs];
			// A function child (Solid's `<For>`, `<Show>`): `view_with`, given the function as `children`.
			let suffix = "";
			if (!selfClosing) {
				const children = this.children(name, start);
				const function_ = children.find((child) => child instanceof FunctionChild);
				if (function_) {
					if (children.some((child) => !(child instanceof Newline) && child !== function_)) this.fail(`<${name}>'s function child must be its only child`, start);
					suffix = "_with";
					fields.push(...children.map((child) => (child === function_ ? `children: ${child.code}` : child)));
				} else if (children.some((child) => !(child instanceof Newline))) fields.push(`children: [${items(children)}]`);
				else fields.push(...children);
			}
			// How a <For> keeps its rows. Roc's values have no identity, so it says: a key function
			// (`keyed={|todo| todo.id}`, `view_with_keyed`) or positions (`keyed={Bool.False}`, Solid's
			// `<Index>` before 2.0, `view_with_unkeyed`).
			const keyed = fields.findIndex((field) => typeof field === "string" && /^keyed: /.test(field));
			const keys = "say how <For> keeps its rows: keyed={|item| item.id} (a row per key), or keyed={Bool.False} (a row per position); Roc's values have no identity to key them by";
			if (keyed >= 0) {
				const value = fields[keyed].slice("keyed: ".length).trim();
				if (/^(Bool\.False|false)$/.test(value)) {
					suffix += "_unkeyed";
					fields = fields.filter((_, i) => i !== keyed);
				} else if (/^(Bool\.True|true)$/.test(value)) this.fail(keys, start);
				else suffix += "_keyed";
			} else if (name === "For" && suffix === "_with") this.fail(keys, start);
			// A component may make signals, as in Solid: it is an effect (`Picks.view!`, `stats!`). A
			// pure one (`view`, no `!`) can't: it makes markup from its props, as a function does.
			const effect = pure ? "" : "!";
			const callee = this.modules.has(name) ? `${name}.view${suffix}${effect}` : `${snakeCase(name)}${suffix}${effect}`;
			const call = `${callee}({ ${items(fields)} })`.replace("({  })", "({})");
			// A component runs where it is rendered, and once, as in Solid, so it sees the contexts
			// provided above that place: its call is put off (`Html.component`). A platform's
			// (`<Show>`, `<For>`, `<Loading>`…) is markup, made now, and so is a pure one's, which reads
			// no context. A prop that is a value read from something that changes (`label={word!()}`)
			// is read by the place that renders the component, before it runs (`Html.component_with`):
			// a hole it is in runs again when it changes, and renders the component anew with it, as it
			// renders a pure one's markup anew; elsewhere it is read once. (A prop named as an effect,
			// `label!={word!()}`, is Solid's getter: read in the component's own holes, patched there.)
			if (!this.packaged.has(name) && !pure) return readsProps ? `Html.component_with(|| { ${items(fields)} }, ${callee})` : `Html.component(|| ${call})`;
			return call;
		}
		const functionChild = (children) => {
			if (children.some((child) => child instanceof FunctionChild)) this.fail(`a function child is a component's: <${name}> can't take one`, start);
			return children;
		};
		if (VOID_ELEMENTS.has(name)) {
			if (!selfClosing) this.fail(`<${name}> has no children or closing tag: write <${name} />`, start);
			return `Html.void(${rocString(name)}, [${items(attrs)}])`;
		}
		if (selfClosing) return `Html.element(${rocString(name)}, [${items(attrs)}], [])`;
		if (RAW_TEXT_ELEMENTS.has(name)) return `Html.element(${rocString(name)}, [${items(attrs)}], [${items([this.rawText(name, start)])}])`;
		if (PREFORMATTED.has(name)) this.preformatted++;
		const children = functionChild(this.children(name, start));
		if (PREFORMATTED.has(name)) this.preformatted--;
		return `Html.element(${rocString(name)}, [${items(attrs)}], [${items(children)}])`;
	}

	/**
	 * `<NoHydration>…</NoHydration>` (Solid's): what is inside is rendered on the server only, as static
	 * markup, every hole run once (`Html.no_hydration`), and the browser keeps the server's nodes
	 * there, never building, adopting or patching them. The browser's copy has no children in its
	 * place (its lines kept as lines), so none of it, nor an import only it used, is in the wasm.
	 * Nothing inside is ever hydrated, so a handler, a `key` or a transition written inside is
	 * refused (`attributes`); a component inside renders once, on the server.
	 */
	noHydration(attrs, selfClosing, start) {
		if (attrs.some((attr) => !(attr instanceof Newline))) this.fail("<NoHydration> takes no attributes: write <NoHydration>…</NoHydration>", start);
		if (selfClosing) this.fail("<NoHydration> holds what the server alone renders: write <NoHydration>…</NoHydration>", start);
		this.inRegion++;
		let children;
		try {
			children = this.children("NoHydration", start);
		} finally {
			this.inRegion--;
		}
		if (children.some((child) => child instanceof FunctionChild)) this.fail("a function child is a component's: <NoHydration> can't take one", start);
		this.regions++;
		const inside = items(children);
		// The browser's copy: each line what it begins with (its indentation), none of the code.
		if (this.client) return `Html.no_hydration([${inside.split("\n").map((line, i) => (i ? /^[ \t]*/.exec(line)[0] : "")).join("\n")}])`;
		return `Html.no_hydration([${inside}])`;
	}

	/** Attributes up to `>` or `/>`, as Html.attr calls (elements) or record fields (components). */
	attributes(tag, component, at) {
		const attrs = [];
		// Inside a component with a <style> (or a file with one), the element's classes end with its
		// (`rx-k3j9qa`): joined to its `class`, or a `class` of its own.
		const scopes = component || UNSCOPED_ELEMENTS.has(tag) ? "" : this.scopesAt(at).join(" ");
		const scoped = scopes !== "";
		let classed = false;
		// A component's prop that is a value (not named as an effect) whose expression reads
		// something that changes (`label={word!()}`): what it reads is the place's that renders it.
		let readsProps = false;
		const done = (selfClosing) => {
			if (scoped && !classed) attrs.push(`Html.attr("class", ${rocString(scopes)})`);
			return { attrs, selfClosing, readsProps };
		};
		for (;;) {
			attrs.push(...this.whitespace());
			if (this.pos >= this.src.length) this.fail(`<${tag}> is never closed`);
			if (this.startsWith("/>")) {
				this.pos += 2;
				return done(true);
			}
			if (this.src[this.pos] === ">") {
				this.pos++;
				return done(false);
			}
			const nameStart = this.pos;
			let name = /^[A-Za-z_@][A-Za-z0-9_:.-]*/.exec(this.src.slice(this.pos))?.[0];
			if (!name) this.fail(`unexpected ${JSON.stringify(this.src[this.pos])} in <${tag}>`);
			this.pos += name.length;
			// A component's prop may be an effect, named as Roc names one: `title!={title!}`.
			if (component && this.src[this.pos] === "!") {
				name += "!";
				this.pos++;
			}
			// `name?={bool}` is a boolean attribute, `name??={str}` one left out when the string is empty.
			let flag = false;
			let optional = false;
			if (this.startsWith("??=")) {
				optional = true;
				this.pos += 2;
			} else if (this.startsWith("?=")) {
				flag = true;
				this.pos++;
			}
			// `on:click={…}` is a component's Roc handler; `onclick="…"` would be a script in an attribute.
			const handler = !component && name.startsWith("on:");
			if (handler) this.handlerName(name, nameStart);
			// Inside a <NoHydration>, nothing is ever hydrated: what would only work in the browser is refused.
			if (this.inRegion && !component) {
				const never = "<NoHydration>, which the browser never hydrates";
				if (handler) this.fail(`${name} is inside ${never}, so this handler would never run: put <${tag}> outside <NoHydration>`, nameStart);
				if (name === "key") this.fail(`key is inside ${never}: nothing keeps <${tag}> by it there; drop it, or put <${tag}> outside <NoHydration>`, nameStart);
				if (name === "transition" || name.startsWith("transition:")) this.fail(`${name} is inside ${never}, so nothing there comes or goes: put <${tag}> outside <NoHydration>`, nameStart);
			}
			if (handler && (flag || optional)) this.fail(`${name} takes {a handler}: write ${name}={…}`, nameStart);
			if (!component && !handler && /^on/i.test(name)) this.fail(`inline event handlers (${name}) aren't allowed: in a component, write on:${name.slice(2).toLowerCase()}={…}`, nameStart);
			// `transition={…}`, `transition:in={…}`, `transition:out={…}`: a Transition the element plays.
			const transition = !component && (name === "transition" || name.startsWith("transition:"));
			if (transition) {
				if (!/^transition(?::in|:out|:move)?$/.test(name)) this.fail(`${name}: write transition={…} (both ways), transition:in={…}, transition:out={…} or transition:move={…}`, nameStart);
				if (flag || optional || this.src[this.pos] !== "=" || this.src[this.pos + 1] !== "{") this.fail(`${name} needs {a Transition}: write ${name}={Transition.fade}`, nameStart);
			}
			if (component && !/^[a-z_][A-Za-z0-9_]*!?$/.test(name)) this.fail(`a component's props are Roc field names: ${name}`, nameStart);
			if (this.src[this.pos] !== "=") {
				if (flag) this.fail(`${name}?= needs {a Bool}`, nameStart);
				if (optional) this.fail(`${name}??= needs {a Str}`, nameStart);
				if (handler) this.fail(`${name} needs {a handler}: write ${name}={…}`, nameStart);
				if (name === "key" && !component) this.fail("key needs {a Str}: write key={…}", nameStart);
				if (name.startsWith("class:")) this.fail(`${name} needs {a Bool}: write ${name}={…}`, nameStart);
				if (name.startsWith("style:")) this.fail(`${name} needs {a value}: write ${name}={…}`, nameStart);
				attrs.push(component ? `${name}: Bool.True` : `Html.flag(${rocString(name)}, Bool.True)`);
				continue;
			}
			this.pos++;
			const quote = this.src[this.pos];
			if (quote === '"' || quote === "'") {
				if (flag) this.fail(`${name}?= needs {a Bool}, not a string`, nameStart);
				if (optional) this.fail(`${name}??= needs {a Str}; a static value is always there`, nameStart);
				if (handler) this.fail(`${name} needs {a handler}, not a string: a handler is Roc, never script`, nameStart);
				if (name.startsWith("class:")) this.fail(`${name} needs {a Bool}`, nameStart);
				if (name.startsWith("style:")) this.fail(`${name} needs {a value}; a static one belongs in style="…"`, nameStart);
				const end = this.src.indexOf(quote, this.pos + 1);
				if (end < 0) this.fail(`the value of ${name} is never closed`, nameStart);
				const raw = this.src.slice(this.pos + 1, end);
				if (raw.includes("\n")) this.fail(`the value of ${name} can't span lines`, nameStart);
				this.pos = end + 1;
				let decoded = decodeEntities(raw, (reason) => this.fail(reason, nameStart));
				if (scoped && name === "class") {
					decoded = decoded.trim() ? `${decoded.trim()} ${scopes}` : scopes;
					classed = true;
				}
				const value = rocString(decoded);
				attrs.push(component ? `${name}: ${value}` : name === "key" ? `Html.key(${value})` : `Html.attr(${rocString(name)}, ${value})`);
			} else if (quote === "{") {
				this.pos++;
				const effects = this.effects;
				let expr = this.code(true);
				this.pos++;
				// An expression that calls nothing named with `!` reads nothing that changes: static.
				const computed = this.effects > effects;
				if (!expr.trim()) this.fail(`${name}={} is empty`, nameStart);
				// A computed class (`class={…}`) is the whole attribute, set again when it changes: the file's class goes in it.
				if (scoped && name === "class" && !flag && !optional) {
					expr = `Str.concat(${expr}, ${rocString(` ${scopes}`)})`;
					classed = true;
				}
				if (component && computed && !name.endsWith("!") && !/^\s*\|/.test(expr) && !/^\s*([A-Za-z_][A-Za-z0-9_]*\.)*[a-z_][A-Za-z0-9_]*!\s*$/.test(expr)) readsProps = true;
				if (component) attrs.push(`${name}: ${accessorProp(name, expr)}`);
				else if (transition) attrs.push(`Html.${computed ? "transition_of" : "transition"}(${TRANSITION_WAYS[name]}, ${computed ? `|| ${expr}` : expr})`);
				else if (computed || handler || name === "key") attrs.push(this.reactiveAttribute(name, expr, { flag, optional }, nameStart, computed));
				else if (flag) attrs.push(`Html.flag(${rocString(name)}, ${expr})`);
				else if (optional) attrs.push(`Html.optional(${rocString(name)}, ${expr})`);
				else if (name.startsWith("class:")) attrs.push(`Html.class_if(${rocString(name.slice(6))}, ${expr})`);
				else if (name.startsWith("style:")) {
					if (!/^style:--[A-Za-z0-9_-]+$/.test(name)) this.fail(`${name}: only custom properties (style:--name={…}) take a value from data`, nameStart);
					attrs.push(`Html.style_var(${rocString(name.slice(6))}, ${expr})`);
				}
				else if (name === "style") this.fail("style takes a static value: change classes, not styles, with data", nameStart);
				else attrs.push(`Html.attr(${rocString(name)}, ${expr})`);
			} else {
				this.fail(`${name}= needs "a value" or {an expression}: unquoted values aren't allowed`, nameStart);
			}
		}
	}

	/** `on:input.value` → the event (`input`) and what its handler is given (`value`; "" for nothing). */
	//
	// `on:frame.ms` is the runtime's own event, each animation frame; `on:keydown.ArrowUp` (a key's
	// name: capitalised, or one letter or digit; `.Space` for the space bar) runs its handler for
	// that key only; `on:click.prevent` prevents the event's default first.
	handlerName(name, nameStart) {
		const match = /^on:([a-z]+)(?:\.([A-Za-z0-9]+))?$/.exec(name);
		if (!match) this.fail(`${name}: write on:event={a handler}, e.g. on:click={save!}`, nameStart);
		const [, event, takes = ""] = match;
		if (event === "frame" || takes === "ms") {
			if (event !== "frame" || takes !== "ms") this.fail(`${name}: frames are on:frame.ms={…}, which gets the milliseconds since the last one`, nameStart);
			return { event, takes };
		}
		if (Object.hasOwn(HANDLERS, takes)) return { event, takes };
		if (/^[A-Z][A-Za-z0-9]*$/.test(takes) || /^[a-z0-9]$/.test(takes)) {
			if (event !== "keydown" && event !== "keyup") this.fail(`${name}: a key's name goes with on:keydown or on:keyup`, nameStart);
			return { event, takes, key: takes === "Space" ? " " : takes };
		}
		this.fail(`${name}: a handler takes .value, .checked or .key, a key's name (.Enter, .ArrowUp, .w), or .prevent, not .${takes}`, nameStart);
	}

	/** Whitespace in a tag, as newlines (spaces between attributes become the comma). */
	whitespace() {
		const newlines = [];
		while (this.pos < this.src.length && /\s/.test(this.src[this.pos])) {
			if (this.src[this.pos] === "\n") newlines.push(new Newline(this.indentAt(this.pos + 1)));
			this.pos++;
		}
		return newlines;
	}

	/** Children up to `</name>` (`</>` for a fragment): items for a Roc list. */
	children(name, openedAt) {
		const children = [];
		// The source of the text so far (for its lines), and what it says: comments in it say
		// nothing but their line breaks, so the whitespace around one is a single run.
		let text = "";
		let said = "";
		let textStart = this.pos;
		// `last`: the closing tag follows, so trailing whitespace goes.
		const flushText = (last = false) => {
			if (!text) return;
			const first = children.every((child) => child instanceof Newline);
			const kept = this.preformatted > 0 ? said : collapseWhitespace(said, first, last);
			const content = decodeEntities(kept, (reason) => this.fail(reason, textStart));
			// The text goes on the first line that has some, so output lines stay source lines.
			const lines = text.split("\n");
			const home = Math.max(0, lines.findIndex((line) => line.trim()));
			let at = textStart;
			lines.forEach((line, i) => {
				if (i > 0) children.push(new Newline(this.indentAt(at)));
				if (i === home && content) children.push(`Html.text(${rocString(content)})`);
				at += line.length + 1;
			});
			text = "";
			said = "";
		};
		const comment = (closer, unclosed) => {
			const end = this.src.indexOf(closer, this.pos);
			if (end < 0) this.fail(unclosed);
			const source = this.src.slice(this.pos, end + closer.length);
			if (!text) textStart = this.pos;
			text += source;
			said += source.replace(/[^\n]/g, "");
			this.pos = end + closer.length;
		};
		for (;;) {
			if (this.pos >= this.src.length) this.fail(`<${name}> is never closed`, openedAt);
			const c = this.src[this.pos];
			if (this.startsWith("</")) {
				flushText(true);
				const end = this.src.indexOf(">", this.pos);
				if (end < 0) this.fail("this closing tag is never closed");
				const closing = this.src.slice(this.pos + 2, end).trim();
				if (closing !== name) this.fail(name ? `<${name}> is closed by </${closing}>` : `<> is closed by </${closing}>`, this.pos);
				this.pos = end + 1;
				return children;
			}
			if (this.startsWith("<!--")) {
				comment("-->", "this comment is never closed");
				continue;
			}
			if (this.startsWith("{#")) {
				comment("}", "this {# comment} is never closed");
				continue;
			}
			if (c === "<") {
				if (!this.markupStarts("")) this.fail('a < in text starts a tag: write &lt; or {"<"}');
				flushText();
				children.push(this.markup());
				textStart = this.pos;
				continue;
			}
			if (c === "{") {
				flushText();
				children.push(...this.hole());
				textStart = this.pos;
				continue;
			}
			if (c === "}") this.fail('a } in text: write {"}"}');
			if (c === ">" ) this.fail('a > in text: write &gt; or {">"}');
			if (!text) textStart = this.pos;
			text += c;
			said += c;
			this.pos++;
		}
	}

	/** An attribute from an expression, reactive: a computation, or a handler that is an effect. */
	reactiveAttribute(name, expr, { flag, optional }, nameStart, computed = false) {
		if (name === "key") return computed ? `Html.key_of(|| ${expr})` : `Html.key(${expr})`;
		if (name.startsWith("on:")) {
			const { event, takes, key } = this.handlerName(name, nameStart);
			if (takes === "ms") return `Html.on_frame(${expr})`;
			if (key !== undefined) return `Html.on_named_key(${rocString(event)}, ${rocString(key)}, ${expr})`;
			return `Html.${HANDLERS[takes]}(${rocString(event)}, ${expr})`;
		}
		if (flag) return `Html.flag_of(${rocString(name)}, || ${expr})`;
		if (optional) return `Html.optional_of(${rocString(name)}, || ${expr})`;
		if (name.startsWith("class:")) return `Html.class_of(${rocString(name.slice(6))}, || ${expr})`;
		if (name.startsWith("style:")) {
			if (!/^style:--[A-Za-z0-9_-]+$/.test(name)) this.fail(`${name}: only custom properties (style:--name={…}) take a value from data`, nameStart);
			return `Html.style_of(${rocString(name.slice(6))}, || ${expr})`;
		}
		if (name === "style") this.fail("style takes a static value: change classes, not styles, with data", nameStart);
		return `Html.attr_of(${rocString(name)}, || ${expr})`;
	}

	/** `{text}`, `{=html}` or `{...list}` among children. */
	hole() {
		const start = this.pos++;
		let kind = "text";
		if (this.startsWith("...")) {
			kind = "list";
			this.pos += 3;
		} else if (this.src[this.pos] === "=") {
			kind = "html";
			this.pos++;
		}
		const effects = this.effects;
		const expr = this.code(true);
		this.pos++;
		if (!expr.trim()) this.fail("this {} is empty", start);
		// A function where a child goes is a component's function child (`{|post, index!| …}`).
		if (kind === "text" && expr.trim().startsWith("|")) return [new FunctionChild(expr)];
		// A hole that calls something named with `!` (a signal, a memo, an accessor prop, a context, a
		// component) is a computation; one that calls nothing so named can't change after its
		// component ran, as in Solid: static, written once.
		if (this.effects > effects) return [`Html.${kind === "text" ? "text" : kind}_of(|| ${expr})`];
		if (kind === "text") return [`Html.text(${expr})`];
		if (kind === "list") return [`Html.join(${expr})`];
		return [`(${expr})`];
	}

	/** A <script> or <style> body: static, as written, its lines kept as lines. */
	rawText(name, openedAt) {
		const closing = new RegExp(`</${name}\\s*>`, "i").exec(this.src.slice(this.pos));
		if (!closing) this.fail(`<${name}> is never closed`, openedAt);
		const content = this.src.slice(this.pos, this.pos + closing.index);
		this.pos += closing.index + closing[0].length;
		const lines = content.split("\n");
		if (lines.length === 1) return `Html.source_text(${rocString(content)})`;
		const start = this.pos - closing[0].length - content.length;
		let at = start;
		const parts = lines.map((line, i) => {
			const indent = i === 0 ? "" : `\n${this.indentAt(at)}`;
			at += line.length + 1;
			return `${indent}${rocString(line)}`;
		});
		return `Html.source_text(Str.join_with([${parts.join(", ")}], "\\n"))`;
	}
}

/**
 * Turns a .rocx file into Roc, line for line. Throws a RocxError for a problem in the markup;
 * problems in the Roc code are the compiler's to report (see remap.mjs).
 */
export function transpile(source, file = "input.rocx", options = {}) {
	return transpileModule(source, file, options).code;
}

/**
 * `transpile`, and what the file has besides its code. `module` names it (`Demos/Echo`, the file's
 * path in its app without `.rocx`; the file's name by default); with `client`, the code is the
 * browser's copy, in which each `<NoHydration>` has no children (and, for a `route` file, there is
 * no `middleware`), the imports only those used dropped (`regions`: how many `<NoHydration>`s the
 * file has). Every file is
 * components (`import pf.Html`): holes that call something named with `!` are computations, the
 * others static, and handlers effects. `contexts` are the contexts other modules define, by their providers' tags (`{ PicksContext:
 * "Picks.picks_context" }`), and `views` how other modules' components are called (`{ Heading:
 * "view" }`: pure, called where written; `view!`, put off in `Html.component`), which rocx build
 * finds (`viewsDefined`). `styles`: the file's <style>s, scoped
 * (`{ css, line, component }`: a component's, or the file's when `component` is null); `module`
 * names their classes too, so both copies have the same.
 */
/**
 * The browser's copy without the imports only what it drops (a `<NoHydration>`'s children, or a
 * route file's middleware) used
 * (`import pf.Db`, which the browser's platform hasn't): each such line left empty, so lines stay
 * lines. `server` is the server's copy; an import its code doesn't use either is kept, for the
 * compiler to warn about.
 */
function withoutServerImports(browser, server) {
	const named = (line) => /^import\s+(?:[a-z_][a-z0-9_]*\.)?(?:\.{0,2}\/)*(?:[A-Za-z0-9_]+\/)*([A-Z][A-Za-z0-9]*)(?:\s+as\s+([A-Z][A-Za-z0-9]*))?/.exec(line);
	const uses = (code, name) => new RegExp(`(^|[^A-Za-z0-9_.])${name}\\.`, "m").test(code.split("\n").filter((line) => !/^import\s/.test(line)).join("\n"));
	return browser
		.split("\n")
		.map((line) => {
			const found = named(line);
			if (!found) return line;
			const name = found[2] ?? found[1];
			return !uses(browser, name) && uses(server, name) ? "" : line;
		})
		.join("\n");
}

/**
 * Where a .rocx file's markup is, for rocx fmt: each markup expression its Roc has, those in holes
 * too (`kind: "markup"`), and each stylesheet (`"style"`), as offsets: `{ kind, from, to }`.
 */
export function markupSpans(source, file = "input.rocx", options = {}) {
	const transpiler = new Transpiler(source, file, options);
	transpiler.code(false);
	return transpiler.spans;
}

/**
 * The browser's copy of a route file without its `middleware` (its annotation and definition, to
 * the next definition at the file's top level), which only the server runs: each line left empty,
 * so lines stay lines. Middleware may read what only the server has (`pf.Env`, `pf.Db`).
 */
function withoutMiddleware(code) {
	const lines = code.split("\n");
	let dropping = false;
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		if (/^middleware[ \t]*[:=]/.test(line)) dropping = true;
		else if (dropping && /^[^\s)\]}]/.test(line)) dropping = false;
		if (dropping) lines[i] = "";
	}
	return lines.join("\n");
}

export function transpileModule(source, file = "input.rocx", { module, client = false, contexts = {}, views = {}, route = false } = {}) {
	// A <style> may come after the markup it styles: a first run finds them, and a second, when
	// there are any, gives each element the classes of those whose markup it is in.
	const first = new Transpiler(source, file, { module, client, contexts, views });
	let body = first.code(false);
	const styles = first.styles.map(({ css, line, component, scope, from, to }) => ({ css, line, component, scope, from, to }));
	const scopes = styles.map(({ scope, from, to }) => ({ scope, from, to }));
	const transpiler = scopes.length ? new Transpiler(source, file, { module, client, contexts, views, scopes }) : first;
	if (scopes.length) body = transpiler.code(false);
	// The browser's copy of a route file has no middleware: only the server runs it.
	const kept = client && route ? withoutMiddleware(body) : body;
	if (client && (transpiler.regions || kept !== body)) body = withoutServerImports(kept, new Transpiler(source, file, { module, contexts, views, scopes }).code(false));
	const name = file.split("/").pop();
	const code = `${body.replace(/\n*$/, "")}\n\n${MARKER} ${name}: edit that file, not this one. Line N here is line N there.\n`;
	return { code, regions: transpiler.regions, styles: styles.map(({ css, line, component }) => ({ css, line, component })), stories: first.stories };
}
