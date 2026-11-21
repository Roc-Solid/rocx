// Scoped styles, as Svelte has them. A .rocx file's top-level <style> styles the markup that file
// writes, and nothing else: rocx gives each of the file's elements a class named after the file
// (`rx-k3j9qa`), and adds that class to each selector in the file's CSS. So `.counter` in one file
// and `.counter` in another never meet, and a component's styles don't reach into the components it
// renders (their elements are written in other files). `rocx build` joins every file's scoped CSS
// into one stylesheet, Generated/Styles.roc, which the root layout puts in its <head>.
//
// Svelte's rules, kept:
//   - `.a .b {}` becomes `.a.rx-k3j9qa .b:where(.rx-k3j9qa) {}`: each compound selector gets the
//     class, the first as a class and the rest in :where(), so a selector's specificity goes up by
//     one class (0-1-0) however long it is.
//   - `:global(…)` leaves a selector, or part of a compound, as written: `:global(body)`,
//     `div :global(strong)` (any strong inside this file's divs), `p:global(.big)`.
//   - `.a :global .b .c` scopes what comes before `:global` and leaves the rest; `:global { … }`
//     and `.a :global { … }` leave every rule inside the block as written.
//   - `@keyframes spin` is the file's own (`rx-k3j9qa-spin`), and so is `spin` in the file's
//     `animation` and `animation-name`; `@keyframes -global-spin` is `spin`, for everyone.
// And CSS nesting: a rule inside a rule is relative to one that already has the class, so its
// compounds get it in :where(), and `&` is left as it is.

/** Elements that are never styled, so get no class: what goes in <head>, and the raw-text ones. */
export const UNSCOPED_ELEMENTS = new Set(["head", "meta", "title", "link", "base", "script", "style"]);

/** At-rules whose block holds rules (or, nested in a rule, declarations), which are scoped in turn. */
const GROUPING_AT_RULES = new Set(["media", "supports", "container", "layer", "scope", "starting-style", "document"]);

/** At-rules a file's <style> can't have: rocx joins every file's into one stylesheet, and these have to come first in one. */
const REFUSED_AT_RULES = new Set(["import", "charset", "namespace"]);

/** The class a file's elements get when it has a <style>: `rx-`, then a hash of the module's name. */
export function scopeClass(module) {
	// FNV-1a, 32 bits: the same name, the same class, in the server's copy and the browser's.
	let hash = 0x811c9dc5;
	for (const c of module) {
		hash ^= c.codePointAt(0);
		hash = Math.imul(hash, 0x01000193) >>> 0;
	}
	return `rx-${hash.toString(36).padStart(7, "0").slice(-6)}`;
}

/**
 * `css`, a file's <style>, with every selector scoped to `scope` (a class from `scopeClass`).
 * `fail(reason, offset)` reports a problem at an offset into `css`; it must throw.
 */
export function scopeCss(css, scope, fail = (reason) => { throw new Error(reason); }) {
	const source = blankComments(css, fail);
	// The file's own keyframes, by name: `spin` is `rx-k3j9qa-spin` wherever this file uses it.
	const keyframes = new Map();
	for (const [, name] of source.matchAll(/@(?:-[a-z]+-)?keyframes\s+([A-Za-z_-][\w-]*)/g)) {
		if (!name.startsWith("-global-")) keyframes.set(name, `${scope}-${name}`);
	}
	const scoper = new Scoper(source, scope, keyframes, fail);
	const out = scoper.items({ nested: false, global: false });
	if (scoper.pos < source.length) fail("this } closes nothing", scoper.pos);
	return tidy(out);
}

/** Comments as spaces (their line breaks kept), so offsets still point into the file. */
function blankComments(css, fail) {
	let out = "";
	for (let i = 0; i < css.length; ) {
		const c = css[i];
		if (c === '"' || c === "'") {
			const end = stringEnd(css, i);
			out += css.slice(i, end);
			i = end;
		} else if (c === "/" && css[i + 1] === "*") {
			const end = css.indexOf("*/", i + 2);
			if (end < 0) fail("this comment is never closed", i);
			out += css.slice(i, end + 2).replace(/[^\n]/g, " ");
			i = end + 2;
		} else {
			out += c;
			i++;
		}
	}
	return out;
}

/** Where the string that opens at `start` ends: after its closing quote, or at the line's end. */
function stringEnd(css, start) {
	const quote = css[start];
	let i = start + 1;
	while (i < css.length && css[i] !== quote && css[i] !== "\n") i += css[i] === "\\" ? 2 : 1;
	return Math.min(css.length, css[i] === quote ? i + 1 : i);
}

/** No trailing spaces, no runs of blank lines, the common indentation gone. */
function tidy(css) {
	const lines = css.split("\n").map((line) => line.trimEnd());
	const indents = lines.filter((line) => line).map((line) => /^[ \t]*/.exec(line)[0].length);
	const common = indents.length ? Math.min(...indents) : 0;
	return lines
		.map((line) => line.slice(common))
		.join("\n")
		.replace(/\n{3,}/g, "\n\n")
		.trim();
}

/** `text` split at the top-level occurrences of `separator` (not inside (), [] or a string). */
function splitTopLevel(text, separator) {
	const parts = [];
	let depth = 0;
	let from = 0;
	for (let i = 0; i < text.length; i++) {
		const c = text[i];
		if (c === "\\") i++;
		else if (c === '"' || c === "'") i = stringEnd(text, i) - 1;
		else if (c === "(" || c === "[") depth++;
		else if (c === ")" || c === "]") depth--;
		else if (c === separator && depth === 0) {
			parts.push(text.slice(from, i));
			from = i + 1;
		}
	}
	parts.push(text.slice(from));
	return parts;
}

/**
 * A selector as compounds and the combinators between them: `.a > .b c` is
 * `[{ compound: ".a" }, { combinator: " > " }, { compound: ".b" }, { combinator: " " }, { compound: "c" }]`.
 */
function compounds(selector) {
	const parts = [];
	let depth = 0;
	let current = "";
	for (let i = 0; i < selector.length; i++) {
		const c = selector[i];
		if (depth === 0 && /[\s>+~]/.test(c)) {
			let explicit = "";
			while (i < selector.length && /[\s>+~]/.test(selector[i])) {
				if (!/\s/.test(selector[i])) explicit += selector[i];
				i++;
			}
			i--;
			if (current) parts.push({ compound: current });
			current = "";
			parts.push({ combinator: explicit ? ` ${explicit} ` : " " });
			continue;
		}
		if (c === "\\") {
			current += c + (selector[i + 1] ?? "");
			i++;
			continue;
		}
		if (c === '"' || c === "'") {
			const end = stringEnd(selector, i);
			current += selector.slice(i, end);
			i = end - 1;
			continue;
		}
		if (c === "(" || c === "[") depth++;
		else if (c === ")" || c === "]") depth--;
		current += c;
	}
	if (current) parts.push({ compound: current });
	return parts;
}

/** Where a compound's class goes: before its first pseudo-class or pseudo-element, or at its end. */
function classPosition(compound) {
	let depth = 0;
	for (let i = 0; i < compound.length; i++) {
		const c = compound[i];
		if (c === "\\") i++;
		else if (c === '"' || c === "'") i = stringEnd(compound, i) - 1;
		else if (c === "(" || c === "[") depth++;
		else if (c === ")" || c === "]") depth--;
		else if (c === ":" && depth === 0) return i;
	}
	return compound.length;
}

/** The text between the `(` at `open` and its `)`, and where that `)` is. */
function parenthesised(text, open) {
	let depth = 0;
	for (let i = open; i < text.length; i++) {
		const c = text[i];
		if (c === "\\") i++;
		else if (c === '"' || c === "'") i = stringEnd(text, i) - 1;
		else if (c === "(") depth++;
		else if (c === ")" && --depth === 0) return { inner: text.slice(open + 1, i), close: i };
	}
	return null;
}

class Scoper {
	constructor(source, scope, keyframes, fail) {
		this.src = source;
		this.scope = scope;
		this.keyframes = keyframes;
		this.fail = fail;
		this.pos = 0;
	}

	/** Whitespace, as it is. */
	space() {
		const start = this.pos;
		while (this.pos < this.src.length && /\s/.test(this.src[this.pos])) this.pos++;
		return this.src.slice(start, this.pos);
	}

	/** The text up to the first of `stops` outside (), [] and strings, or to the end. */
	until(stops) {
		const start = this.pos;
		let depth = 0;
		while (this.pos < this.src.length) {
			const c = this.src[this.pos];
			if (depth === 0 && stops.includes(c)) break;
			if (c === "\\") this.pos++;
			else if (c === '"' || c === "'") this.pos = stringEnd(this.src, this.pos) - 1;
			else if (c === "(" || c === "[") depth++;
			else if (c === ")" || c === "]") depth = Math.max(0, depth - 1);
			this.pos++;
		}
		return this.src.slice(start, this.pos);
	}

	/** The `}` that closes the block opened at `opened`. */
	close(opened) {
		if (this.src[this.pos] !== "}") this.fail("this { is never closed", opened);
		this.pos++;
	}

	/**
	 * Rules and at-rules up to an unmatched `}` or the end, and in a rule (`nested`) declarations
	 * too. `global`: in a `:global { … }` block, where selectors stay as written.
	 */
	items(context) {
		let out = "";
		for (;;) {
			out += this.space();
			if (this.pos >= this.src.length || this.src[this.pos] === "}") return out;
			if (this.src[this.pos] === ";") {
				out += ";";
				this.pos++;
				continue;
			}
			if (this.src[this.pos] === "@") {
				out += this.atRule(context);
				continue;
			}
			const start = this.pos;
			const text = this.until("{;}");
			if (this.src[this.pos] === "{") {
				this.pos++;
				out += this.rule(text, start, context);
				continue;
			}
			if (!context.nested) this.fail(`a declaration goes in a rule: ${text.trim()}`, start);
			out += this.declaration(text);
			if (this.src[this.pos] === ";") {
				out += ";";
				this.pos++;
			}
		}
	}

	/** A rule, its `{` read: its selectors scoped, then its block. */
	rule(prelude, start, context) {
		const block = (inner) => {
			const body = this.items(inner);
			this.close(start);
			return body;
		};
		if (context.global) return `${prelude}{${block({ nested: true, global: true })}}`;
		// `:global { … }`, and `.a :global { … }`: the rules inside stay as written.
		const global = /^(\s*)(?:(.*?)\s+)?:global(\s*)$/s.exec(prelude);
		if (global) {
			const [, lead, before, trail] = global;
			if (before === undefined) return `${lead}${block({ nested: context.nested, global: true })}`;
			if (splitTopLevel(before, ",").length > 1) this.fail("`:global { … }` follows one selector, not a list", start);
			return `${lead}${this.selector(before, context, start)}${trail}{${block({ nested: true, global: true })}}`;
		}
		const selectors = splitTopLevel(prelude, ",").map((selector) => this.selector(selector, context, start));
		return `${selectors.join(",")}{${block({ nested: true, global: false })}}`;
	}

	/** One selector of a list, scoped; the whitespace around it kept. */
	selector(text, context, start) {
		const [, lead, body, trail] = /^(\s*)(.*?)(\s*)$/s.exec(text);
		if (!body) this.fail("a selector is empty", start);
		let parts = compounds(body);
		// `.a :global .b`: what comes after `:global` stays as written.
		const at = parts.findIndex((part) => part.compound === ":global");
		let rest = [];
		if (at >= 0) {
			const before = parts[at - 1]?.combinator;
			const after = parts[at + 1]?.combinator;
			if (before && after && before !== " " && after !== " ") this.fail("`:global` stands between two combinators", start);
			rest = parts.slice(at + 1);
			parts = parts.slice(0, at);
			// One combinator for the two around `:global`: the one that says something (`>`, `+`, `~`).
			if (before && after) {
				if (before === " ") parts.pop();
				else rest.shift();
			} else if (before) parts.pop();
			else if (rest[0]?.combinator === " ") rest.shift();
		}
		// In a nested rule, the rule around it has the class already.
		let bumped = context.nested;
		const scoped = parts.map((part) => {
			if (part.combinator !== undefined) return part.combinator;
			const compound = part.compound;
			if (compound.includes("&")) return compound;
			const global = /:global\(/.exec(compound);
			let plain = compound;
			if (global) {
				const found = parenthesised(compound, global.index + ":global".length);
				if (!found) this.fail("this :global( is never closed", start);
				if (global.index === 0 && found.close === compound.length - 1) return found.inner;
				plain = compound.slice(0, global.index) + found.inner + compound.slice(found.close + 1);
			}
			const position = classPosition(plain);
			const added = bumped ? `:where(.${this.scope})` : `.${this.scope}`;
			bumped = true;
			return plain.slice(0, position) + added + plain.slice(position);
		});
		return `${lead}${scoped.join("")}${rest.map((part) => part.combinator ?? part.compound).join("")}${trail}`;
	}

	/** A declaration, with this file's keyframes named as their scoped names in `animation`. */
	declaration(text) {
		const colon = text.indexOf(":");
		if (colon < 0 || !this.keyframes.size) return text;
		const property = text.slice(0, colon).trim().toLowerCase();
		if (!/^(-[a-z]+-)?animation(-name)?$/.test(property)) return text;
		const value = text.slice(colon + 1).replace(/(^|[\s,])([A-Za-z_-][\w-]*)(?=$|[\s,!])/g, (whole, before, name) => before + (this.keyframes.get(name) ?? name));
		return text.slice(0, colon + 1) + value;
	}

	/** An at-rule: its block scoped if it holds rules, as written if it holds declarations. */
	atRule(context) {
		const start = this.pos++;
		const name = /^-?[A-Za-z][\w-]*/.exec(this.src.slice(this.pos))?.[0];
		if (!name) this.fail("an at-rule needs a name: @media, @keyframes…", start);
		this.pos += name.length;
		const prelude = this.until("{;}");
		if (REFUSED_AT_RULES.has(name.toLowerCase())) this.fail(`@${name} can't be in a file's <style>: rocx puts every file's in one stylesheet, and @${name} has to come first in one; write it in a stylesheet of the app's own`, start);
		if (this.src[this.pos] !== "{") {
			// A statement (`@layer base, components;`).
			if (this.src[this.pos] !== ";") return `@${name}${prelude}`;
			this.pos++;
			return `@${name}${prelude};`;
		}
		this.pos++;
		if (/^(-[a-z]+-)?keyframes$/i.test(name)) {
			const given = prelude.trim();
			const named = given.startsWith("-global-") ? given.slice("-global-".length) : (this.keyframes.get(given) ?? given);
			return `@${name} ${named} {${this.verbatim(start)}}`;
		}
		if (GROUPING_AT_RULES.has(name.toLowerCase())) {
			const body = this.items(context);
			this.close(start);
			return `@${name}${prelude}{${body}}`;
		}
		// @font-face, @page, @property, @counter-style…: declarations, which no selector scopes.
		return `@${name}${prelude}{${this.verbatim(start)}}`;
	}

	/** A block's text as written, up to its `}` (read). */
	verbatim(opened) {
		const start = this.pos;
		let depth = 0;
		while (this.pos < this.src.length) {
			const c = this.src[this.pos];
			if (c === "\\") this.pos++;
			else if (c === '"' || c === "'") this.pos = stringEnd(this.src, this.pos) - 1;
			else if (c === "{") depth++;
			else if (c === "}" && depth-- === 0) {
				const body = this.src.slice(start, this.pos);
				this.pos++;
				return body;
			}
			this.pos++;
		}
		this.fail("this { is never closed", opened);
	}
}
