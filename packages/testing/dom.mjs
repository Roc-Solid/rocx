// HTML as a tree, and the things in it found as a person finds them: by role and accessible name,
// by text, by label, by test id. Testing Library's queries (getByRole, getByText, getByLabelText,
// getByTestId, with queryBy…, getAllBy… and queryAllBy…), on the HTML a test fetched, with no
// dependencies. The rules are Dom.roc's, so a Roc `expect` and a node:test say the same thing.
//
//   const page = within(parse(await (await fetch(url)).text()));
//   page.getByRole("button", { name: "Save" });
//   page.getAllByRole("listitem").map(text);
//
// It reads HTML that closes its elements, as Roc Solid writes it and a browser serializes it: void
// elements need no end tag, <script> and <style> hold text as written, <textarea> and <title> text,
// and an end tag closes the elements still open inside it.

const VOID = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);
const RAW = new Set(["script", "style"]);
const ESCAPABLE = new Set(["textarea", "title"]);
const UNREAD = new Set(["script", "style", "template"]);
const SECTIONING = new Set(["article", "aside", "main", "nav", "section"]);
const LABELABLE = new Set(["button", "input", "meter", "output", "progress", "select", "textarea"]);
const FROM_CONTENT = new Set(["button", "cell", "checkbox", "columnheader", "gridcell", "heading", "link", "listitem", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "row", "rowheader", "switch", "tab", "tooltip", "treeitem"]);
const NAMED = {
	amp: 38, lt: 60, gt: 62, quot: 34, apos: 39, nbsp: 160, middot: 183, mdash: 8212, ndash: 8211, hellip: 8230, copy: 169, reg: 174, trade: 8482,
	times: 215, minus: 8722, larr: 8592, rarr: 8594, uarr: 8593, darr: 8595, laquo: 171, raquo: 187, lsquo: 8216, rsquo: 8217, ldquo: 8220,
	rdquo: 8221, bull: 8226, deg: 176, plusmn: 177, para: 182, sect: 167, euro: 8364, pound: 163, yen: 165, cent: 162, shy: 173, ensp: 8194,
	emsp: 8195, thinsp: 8201, zwj: 8205, zwnj: 8204, check: 10003, star: 9734,
};

/** A node of the tree: the document (`root`), an element, text or a comment. */
export class Node {
	constructor(type, { tag = "", attrs = [], value = "", parent = null } = {}) {
		/** `"root"`, `"element"`, `"text"` or `"comment"`. */
		this.type = type;
		/** An element's tag name, lower case. */
		this.tag = tag;
		/** An element's attributes, `[name, value]` in order, names lower case. */
		this.attrs = attrs;
		/** Text's or a comment's text. */
		this.value = value;
		this.parent = parent;
		this.children = [];
	}

	/** The attribute `name` (`""` for one written bare), or null. */
	attr(name) {
		const found = this.attrs.find(([written]) => written === name.toLowerCase());
		return found ? found[1] : null;
	}

	hasClass(name) {
		return (this.attr("class") ?? "").split(/\s+/).includes(name);
	}

	/** What a reader reads in it: its text without <script>, <style> and <template>, whitespace collapsed. */
	get text() {
		return normalize(content(this));
	}

	/** Its ARIA role, its own or its tag's; `""` for none. */
	get role() {
		return this.type === "element" ? roleOf(this) : "";
	}

	/** Its accessible name, as a screen reader says it. */
	get name() {
		return this.type === "element" ? nameOf(this) : "";
	}

	/** Its element children. */
	get elements() {
		return this.children.filter((child) => child.type === "element");
	}

	/** Its place: the index among its parent's elements at each level from the top. */
	get path() {
		const path = [];
		for (let node = this; node.parent; node = node.parent) path.unshift(node.parent.elements.indexOf(node));
		return path;
	}

	/** The top of its tree. */
	get root() {
		let node = this;
		while (node.parent) node = node.parent;
		return node;
	}

	toString() {
		return serialize(this);
	}
}

/** HTML as a tree: the document, or a fragment of one. */
export function parse(html) {
	const root = new Node("root");
	let open = root;
	let i = 0;
	const n = html.length;
	const add = (node) => {
		node.parent = open;
		const last = open.children.at(-1);
		if (node.type === "text" && last?.type === "text") last.value += node.value;
		else open.children.push(node);
	};
	while (i < n) {
		const lt = html.indexOf("<", i);
		const end = lt === -1 ? n : lt;
		if (end > i) {
			add(new Node("text", { value: decode(html.slice(i, end)) }));
			i = end;
			continue;
		}
		const next = html[i + 1] ?? "";
		if (html.startsWith("<!--", i)) {
			const close = html.indexOf("-->", i + 4);
			const stop = close === -1 ? n : close;
			add(new Node("comment", { value: html.slice(i + 4, stop) }));
			i = stop + 3;
		} else if (next === "!" || next === "?") {
			const close = html.indexOf(">", i);
			i = close === -1 ? n : close + 1;
		} else if (next === "/") {
			const match = /^<\/([^\s>]*)[^>]*>?/.exec(html.slice(i));
			const name = match[1].toLowerCase();
			for (let node = open; node !== root; node = node.parent) {
				if (node.tag === name) {
					open = node.parent;
					break;
				}
			}
			i += match[0].length;
		} else if (/[a-zA-Z]/.test(next)) {
			const read = readTag(html, i);
			const element = new Node("element", { tag: read.name, attrs: read.attrs });
			add(element);
			i = read.next;
			if (read.closed || VOID.has(read.name)) continue;
			if (RAW.has(read.name) || ESCAPABLE.has(read.name)) {
				const close = html.toLowerCase().indexOf(`</${read.name}`, i);
				const stop = close === -1 ? n : close;
				const inner = html.slice(i, stop);
				const said = ESCAPABLE.has(read.name) ? decode(inner) : inner;
				if (said) element.children.push(new Node("text", { value: said, parent: element }));
				const gt = html.indexOf(">", stop);
				i = gt === -1 ? n : gt + 1;
			} else {
				open = element;
			}
		} else {
			add(new Node("text", { value: "<" }));
			i += 1;
		}
	}
	return root;
}

/** A start tag at `start`: its name, its attributes, whether it ended `/>`, and where after it. */
function readTag(html, start) {
	const nameMatch = /^<([^\s>/]+)/.exec(html.slice(start));
	const name = nameMatch[1].toLowerCase();
	let i = start + nameMatch[0].length;
	const attrs = [];
	const space = /\s/;
	for (;;) {
		while (i < html.length && space.test(html[i])) i++;
		if (i >= html.length) return { name, attrs, closed: false, next: i };
		if (html[i] === ">") return { name, attrs, closed: false, next: i + 1 };
		if (html[i] === "/" && html[i + 1] === ">") return { name, attrs, closed: true, next: i + 2 };
		if (html[i] === "/") {
			i++;
			continue;
		}
		let nameEnd = i + 1;
		while (nameEnd < html.length && !/[\s=>/]/.test(html[nameEnd])) nameEnd++;
		const attr = html.slice(i, nameEnd).toLowerCase();
		let after = nameEnd;
		while (after < html.length && space.test(html[after])) after++;
		if (html[after] !== "=") {
			attrs.push([attr, ""]);
			i = after;
			continue;
		}
		let valueStart = after + 1;
		while (valueStart < html.length && space.test(html[valueStart])) valueStart++;
		const quote = html[valueStart];
		if (quote === '"' || quote === "'") {
			const close = html.indexOf(quote, valueStart + 1);
			const stop = close === -1 ? html.length : close;
			attrs.push([attr, decode(html.slice(valueStart + 1, stop))]);
			i = stop + 1;
		} else {
			let stop = valueStart;
			while (stop < html.length && !/[\s>]/.test(html[stop])) stop++;
			attrs.push([attr, decode(html.slice(valueStart, stop))]);
			i = stop;
		}
	}
}

/** Text with its character references (`&amp;`, `&#39;`, `&#x2014;`, `&middot;`) as characters. */
export function decode(text) {
	return text.replace(/&([^;&\s]{1,31});/g, (whole, name) => {
		let point = 0;
		if (name[0] === "#") {
			const hex = name[1] === "x" || name[1] === "X";
			const digits = hex ? name.slice(2) : name.slice(1);
			if ((hex ? /^[0-9a-fA-F]+$/ : /^[0-9]+$/).test(digits)) point = parseInt(digits, hex ? 16 : 10);
		} else {
			point = NAMED[name] ?? 0;
		}
		return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : whole;
	});
}

/** Text as a reader sees it: each run of whitespace (no-break spaces too) one space, none at the ends. */
export function normalize(text) {
	return text.replace(/[ \t\n\r\f ]+/g, " ").trim();
}

/** Its text, as `textContent` has it, without <script>, <style> and <template>. */
function content(node) {
	if (node.type === "text") return node.value;
	if (node.type === "comment" || UNREAD.has(node.tag)) return "";
	return node.children.map(content).join("");
}

/** The text directly in it, not in its elements, as getByText reads it. */
function ownText(node) {
	return normalize(node.children.filter((child) => child.type === "text").map((child) => child.value).join(""));
}

function inputType(element) {
	return (element.attr("type") ?? "text").toLowerCase();
}

/** Whether a reader can't see the element, nor what is inside it. */
function hides(element) {
	const style = (element.attr("style") ?? "").replace(/\s/g, "").toLowerCase();
	return (
		element.attr("hidden") !== null ||
		element.attr("aria-hidden") === "true" ||
		["head", "noscript", "script", "style", "template"].includes(element.tag) ||
		(element.tag === "input" && inputType(element) === "hidden") ||
		style.includes("display:none") ||
		style.includes("visibility:hidden")
	);
}

/** Whether it, or an element it is in, is hidden. */
export function isHidden(node) {
	for (let at = node; at && at.type === "element"; at = at.parent) if (hides(at)) return true;
	return false;
}

function roleOf(element) {
	const written = (element.attr("role") ?? "").trim().split(/\s+/)[0];
	return written || implicitRole(element);
}

function sectioned(element) {
	for (let at = element.parent; at && at.type === "element"; at = at.parent) if (SECTIONING.has(at.tag)) return true;
	return false;
}

function implicitRole(element) {
	const has = (name) => element.attr(name) !== null;
	switch (element.tag) {
		case "a":
		case "area":
			return has("href") ? "link" : "";
		case "button":
			return "button";
		case "input": {
			const listed = has("list");
			switch (inputType(element)) {
				case "button":
				case "submit":
				case "reset":
				case "image":
					return "button";
				case "checkbox":
					return "checkbox";
				case "radio":
					return "radio";
				case "range":
					return "slider";
				case "number":
					return "spinbutton";
				case "search":
					return listed ? "combobox" : "searchbox";
				case "hidden":
				case "password":
				case "color":
				case "date":
				case "datetime-local":
				case "month":
				case "time":
				case "week":
				case "file":
					return "";
				default:
					return listed ? "combobox" : "textbox";
			}
		}
		case "textarea":
			return "textbox";
		case "select":
			return has("multiple") ? "listbox" : "combobox";
		case "option":
			return "option";
		case "h1":
		case "h2":
		case "h3":
		case "h4":
		case "h5":
		case "h6":
			return "heading";
		case "ul":
		case "ol":
		case "menu":
		case "dl":
			return "list";
		case "li":
			return "listitem";
		case "nav":
			return "navigation";
		case "main":
			return "main";
		case "header":
			return sectioned(element) ? "" : "banner";
		case "footer":
			return sectioned(element) ? "" : "contentinfo";
		case "aside":
			return "complementary";
		case "section":
			return has("aria-label") || has("aria-labelledby") ? "region" : "";
		case "form":
			return "form";
		case "article":
			return "article";
		case "table":
			return "table";
		case "tr":
			return "row";
		case "td":
			return "cell";
		case "th":
			return element.attr("scope") === "row" ? "rowheader" : "columnheader";
		case "thead":
		case "tbody":
		case "tfoot":
			return "rowgroup";
		case "img":
			return element.attr("alt") === "" ? "presentation" : "img";
		case "dialog":
			return "dialog";
		case "progress":
			return "progressbar";
		case "meter":
			return "meter";
		case "output":
			return "status";
		case "hr":
			return "separator";
		case "fieldset":
		case "details":
		case "optgroup":
			return "group";
		case "figure":
			return "figure";
		case "p":
			return "paragraph";
		case "blockquote":
			return "blockquote";
		case "dt":
			return "term";
		case "dd":
			return "definition";
		default:
			return "";
	}
}

/** A heading's level: its `aria-level`, or its tag's (`h2`: 2). */
function levelOf(element) {
	const written = Number(element.attr("aria-level"));
	if (Number.isInteger(written) && written > 0) return written;
	const tagged = /^h([1-6])$/.exec(element.tag);
	return tagged ? Number(tagged[1]) : undefined;
}

/** Every element under `node`, in the page's order. */
function elementsUnder(node) {
	const out = [];
	const walk = (at) => {
		for (const child of at.children) {
			if (child.type !== "element") continue;
			out.push(child);
			walk(child);
		}
	};
	walk(node);
	return out;
}

function labelable(element) {
	return LABELABLE.has(element.tag) && !(element.tag === "input" && inputType(element) === "hidden");
}

/** The control a <label> names: by its `for`, or the first inside it. */
function targetOf(label, scope) {
	const id = label.attr("for");
	if (id !== null) return elementsUnder(scope).find((element) => labelable(element) && element.attr("id") === id) ?? null;
	return elementsUnder(label).find(labelable) ?? null;
}

/** The text of the elements its `aria-labelledby` names, or null. */
function labelledBy(element, scope) {
	const ids = (element.attr("aria-labelledby") ?? "").split(/\s+/).filter(Boolean);
	if (!ids.length) return null;
	const all = elementsUnder(scope);
	return normalize(ids.map((id) => all.find((other) => other.attr("id") === id)).filter(Boolean).map(content).join(" "));
}

/** Its accessible name (the W3C's accname, its common cases), ids and labels looked up in `scope`. */
function nameOf(element, scope = element.root) {
	const byIds = labelledBy(element, scope);
	if (byIds !== null) return byIds;
	const label = normalize(element.attr("aria-label") ?? "");
	return label || normalize(nativeName(element, scope));
}

function nativeName(element, scope) {
	const title = element.attr("title") ?? "";
	const kind = inputType(element);
	if (element.tag === "input" && ["button", "submit", "reset"].includes(kind)) {
		return element.attr("value") ?? (kind === "submit" ? "Submit" : kind === "reset" ? "Reset" : title);
	}
	if (element.tag === "input" && kind === "image") return element.attr("alt") ?? (title || "Submit");
	if (labelable(element) && element.tag !== "button") {
		const labels = elementsUnder(scope).filter((other) => other.tag === "label" && targetOf(other, scope) === element).map(content);
		if (labels.length) return labels.join(" ");
		return title || (element.attr("placeholder") ?? "");
	}
	if (element.tag === "img" || element.tag === "area") return element.attr("alt") ?? title;
	if (["fieldset", "table", "figure"].includes(element.tag)) {
		const caption = { fieldset: "legend", table: "caption", figure: "figcaption" }[element.tag];
		const found = elementsUnder(element).find((other) => other.tag === caption);
		return found ? content(found) : title;
	}
	if (FROM_CONTENT.has(roleOf(element))) return normalize(nameContent(element)) || title;
	return title;
}

/** Content as a name has it: what a reader sees, an image as its alt, an element with an aria-label as that. */
function nameContent(node) {
	if (node.type === "text") return node.value;
	if (node.type === "comment") return "";
	if (node.type === "element") {
		if (hides(node)) return "";
		const label = node.attr("aria-label") ?? "";
		if (label) return ` ${label} `;
		if (node.tag === "img" || node.tag === "area") return ` ${node.attr("alt") ?? ""} `;
	}
	return node.children.map(nameContent).join("");
}

/** Whether `text` is what `wanted` asks for: the same, whitespace collapsed, or matched by a RegExp. */
function matches(text, wanted) {
	if (wanted instanceof RegExp) return wanted.test(text);
	if (typeof wanted === "function") return Boolean(wanted(text));
	return text === normalize(String(wanted));
}

const say = (wanted) => (wanted instanceof RegExp ? String(wanted) : typeof wanted === "function" ? "(a function)" : JSON.stringify(wanted));

/** What each query finds under `scope`, and how to say what it asked. */
const QUERIES = {
	Role: {
		find: (scope, role, { name, hidden = false, level } = {}) =>
			elementsUnder(scope).filter(
				(element) => (hidden || !isHidden(element)) && roleOf(element) === role && (level === undefined || levelOf(element) === level) && (name === undefined || matches(nameOf(element, scope), name)),
			),
		describe: (role, { name, level } = {}) => `a ${role}${level === undefined ? "" : ` at level ${level}`}${name === undefined ? "" : ` named ${say(name)}`}`,
		instead: (scope, role, { name } = {}) => {
			const seen = roles(scope);
			const same = seen.filter((entry) => entry.role === role);
			if (name !== undefined && same.length) return `the ${role}s here: ${same.map((entry) => JSON.stringify(entry.name)).join(", ")}`;
			return seen.length ? `the roles here: ${seen.map((entry) => entry.role).join(", ")}` : "";
		},
	},
	Text: {
		find: (scope, text) => {
			if (typeof text === "string" && !normalize(text)) return [];
			return elementsUnder(scope).filter((element) => !isHidden(element) && !UNREAD.has(element.tag) && matches(ownText(element), text));
		},
		describe: (text) => `an element whose text is ${say(text)}`,
		instead: () => "",
	},
	LabelText: {
		find: (scope, text) => {
			const all = elementsUnder(scope);
			const targets = new Set();
			for (const label of all) {
				if (label.tag !== "label" || isHidden(label) || !matches(normalize(content(label)), text)) continue;
				const target = targetOf(label, scope);
				if (target) targets.add(target);
			}
			for (const element of all) {
				if (isHidden(element)) continue;
				const label = normalize(element.attr("aria-label") ?? "");
				const byIds = labelledBy(element, scope);
				if ((label && matches(label, text)) || (byIds !== null && matches(byIds, text))) targets.add(element);
			}
			return all.filter((element) => targets.has(element));
		},
		describe: (text) => `a control labelled ${say(text)}`,
		instead: (scope) => {
			const labels = elementsUnder(scope).filter((element) => element.tag === "label" && !isHidden(element));
			return labels.length ? `the labels here: ${labels.map((label) => JSON.stringify(normalize(content(label)))).join(", ")}` : "";
		},
	},
	TestId: {
		find: (scope, id) => elementsUnder(scope).filter((element) => element.attr("data-testid") !== null && (id instanceof RegExp ? id.test(element.attr("data-testid")) : element.attr("data-testid") === id)),
		describe: (id) => `an element with data-testid=${say(id)}`,
		instead: () => "",
	},
};

/** The role and accessible name of each element under `scope` a reader can reach (Testing Library's logRoles). */
export function roles(scope) {
	return elementsUnder(scope)
		.filter((element) => !isHidden(element) && roleOf(element))
		.map((element) => ({ role: roleOf(element), name: nameOf(element, scope) }));
}

/** Thrown by a getBy… query that finds nothing, or more than one. */
export class QueryError extends Error {
	name = "QueryError";
}

/**
 * The queries, bound to `scope` (a node `parse` gave, or an element in it): getByRole(role, { name, level }),
 * getByText, getByLabelText, getByTestId, and each as queryBy… (null for none), getAllBy… (throws for
 * none) and queryAllBy… ([] for none). A name or text is a string, matched whole with its whitespace
 * collapsed, or a RegExp. Roles, names, text and labels skip what a reader can't see, unless a
 * role query says `{ hidden: true }`.
 */
export function within(scope) {
	const bound = { scope, roles: () => roles(scope), text: () => scope.text };
	for (const [kind, query] of Object.entries(QUERIES)) {
		const all = (...args) => query.find(scope, ...args);
		const fail = (problem, args) => {
			const instead = query.instead(scope, ...args);
			return new QueryError(`${problem} ${query.describe(...args)}${instead ? `; ${instead}` : ""}`);
		};
		bound[`queryAllBy${kind}`] = all;
		bound[`getAllBy${kind}`] = (...args) => {
			const found = all(...args);
			if (!found.length) throw fail("nothing is", args);
			return found;
		};
		bound[`queryBy${kind}`] = (...args) => {
			const found = all(...args);
			if (found.length > 1) throw new QueryError(`${found.length} elements are ${query.describe(...args)}`);
			return found[0] ?? null;
		};
		bound[`getBy${kind}`] = (...args) => {
			const found = all(...args);
			if (found.length > 1) throw new QueryError(`${found.length} elements are ${query.describe(...args)}`);
			if (!found.length) throw fail("nothing is", args);
			return found[0];
		};
	}
	return bound;
}

/** The queries on `html`, parsed: `within(parse(html))`. */
export function screen(html) {
	return within(parse(html));
}

/** The text of a node, as a reader reads it (also `node.text`). */
export const text = (node) => node.text;

/** The tree as HTML again (attributes and text escaped), to print in a failure. */
export function serialize(node) {
	const escape = (value) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
	if (node.type === "text") return node.parent && (RAW.has(node.parent.tag)) ? node.value : escape(node.value);
	if (node.type === "comment") return `<!--${node.value}-->`;
	const inner = node.children.map(serialize).join("");
	if (node.type === "root") return inner;
	const attrs = node.attrs.map(([name, value]) => (value === "" ? ` ${name}` : ` ${name}="${escape(value)}"`)).join("");
	return VOID.has(node.tag) ? `<${node.tag}${attrs}>` : `<${node.tag}${attrs}>${inner}</${node.tag}>`;
}
