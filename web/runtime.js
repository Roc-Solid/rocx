// The browser's runtime: Solid 2.0-style components written in Roc, run by a wasm module built on
// web/platform. Roc builds markup whose holes are computations (boxes this runtime keeps
// by their pointers); this file runs them, tracks what each reads, runs it again when that changes,
// and patches only its own node. An async read whose value isn't in yet throws (NotReady) through
// the Roc frames: the computation stops, the nearest <Loading> shows its fallback until the first
// values are in, and the computation runs again once its value is. A failure (Failed) shows the
// nearest <Errored>. Handlers run as effects; one that waits for an answer from the server is run
// again when the answer is in, its writes dropped meanwhile (writes apply when a handler is done).
// A component runs where it is rendered, once, its reads untracked (as in Solid), so it sees the
// contexts provided above it; a signal belongs to the run that made it, and goes with it, as do its
// effects (Solid 2.0's split ones: a tracked compute, then an apply after the flush), cleanups,
// timers and listens, a cleanup run before what made it runs again, and when it goes. A form
// posting to an endpoint a component reads the submission of is sent with fetch, as is an action a
// handler sends; a submission answered with a result reads the page's reads again before it is done.
// Drop targets accept drags; elements that glide are measured around a flush that moves them. An app
// whose root renders a whole document (`<!doctype html><html>…`) hydrates the page the server sent
// (`hydrateDocument`, called by start.js).

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** A read whose value isn't in yet: `wait` settles when it might be. */
export class NotReady extends Error {
	constructor(wait) {
		super("not ready");
		this.wait = wait;
	}
}

/** A read that failed, or a computation that failed: the nearest <Errored> shows `message`. */
export class Failed extends Error {
	constructor(message, memo = null) {
		super(message);
		this.memo = memo;
	}
}

/** A request as the host passes it to Roc (`Host.request!`), as HTTP writes it: `METHOD target`, a
 * header a line, a blank line, then its body. */
const wire = (method, target, headers, body) => [`${method} ${target}`, ...headers.map(([name, value]) => `${name}: ${value}`)].join("\n") + `\n\n${body}`;

let ids = 0;

/** What a run makes, as it makes it: child computations, boxes kept for them, what it reads
 * (`sources`: see `addSource`), signals, cleanups (a kept box's id, or the runtime's own function),
 * and what its `is_pending!` calls answered (`queries`). Each list is the one empty `NONE` until
 * something goes in it (`own`): most runs (a row's holes) make nothing but their answer, and
 * allocate no lists for it. `live` once it read or made something that changes, which the rest
 * don't show (an endpoint's read; rendering as a server would, an effect, a cleanup…): a hole
 * whose run is none of these is static (`inert`, D-052). `untracked`: how many `untrack!`s it is
 * inside now, its reads not tracked there. */
const making_ = () => ({ children: NONE, kept: NONE, sources: NONE, signals: NONE, cleanups: NONE, queries: NONE, live: false, untracked: 0 });

/** What a run reads, added to its `sources`: a short array, searched (most holes read one or two
 * things), and a Set once it holds more than eight. Either is iterated with `for … of`; how many is
 * `sourceCount`. */
function addSource(making, source) {
	const sources = making.sources;
	if (sources === NONE) making.sources = [source];
	else if (sources instanceof Set) sources.add(source);
	else if (!sources.includes(source)) {
		if (sources.length < 8) sources.push(source);
		else (making.sources = new Set(sources)).add(source);
	}
}

const sourceCount = (sources) => (sources instanceof Set ? sources.size : sources.length);

/**
 * Whether a run read and made nothing that changes (D-052): no tracked read (a signal, a memo, a
 * row, a submission, an endpoint, `is_pending!`), no signal, memo, effect, cleanup, timer, listen,
 * subscription or title. A hole whose run is inert is static: it never runs again, so the server
 * writes it without its comments and hydrating takes its text as the server wrote it. The server
 * (server/host/src/signals.rs, `touched`) notes the same calls, so both agree.
 */
/** The one empty list a finished run's record keeps for each kind of thing it made none of (most
 * holes make nothing but their text): a thousand rows' holes keep no empty arrays of their own.
 * Something added to one later (a child adopted, a box kept, a cleanup) gets a list of its own (`own`). */
const NONE = Object.freeze([]);
const own = (record, name) => (record[name] === NONE ? (record[name] = []) : record[name]);
const spare = (record) => {
	for (const name of ["children", "kept", "signals", "cleanups", "queries"]) if (record[name]?.length === 0) record[name] = NONE;
	return record;
};

/** What a finished run that made nothing keeps (most holes make nothing but their answer): one of
 * two records, shared and frozen, as `inert` would read the run's own: `MADE_NONE` for one that read
 * nothing that changes (a static hole), `MADE_READ` for one that did. Something added to it later
 * gets its computation a record of its own (`Computation#ownMade`). */
const MADE_NONE = Object.freeze({ children: NONE, kept: NONE, cleanups: NONE, signals: NONE, queries: NONE, sources: NONE, live: false });
const MADE_READ = Object.freeze({ children: NONE, kept: NONE, cleanups: NONE, signals: NONE, queries: NONE, sources: NONE, live: true });

const madeNothing = (making) => making.children.length === 0 && making.kept.length === 0 && making.cleanups.length === 0 && making.signals.length === 0 && making.queries.length === 0;

const inert = (making) => !making.live && sourceCount(making.sources) === 0 && making.children.length === 0 && making.signals.length === 0 && making.cleanups.length === 0 && making.queries.length === 0;

/** A hole, attribute, memo, fallback or the root: a box Roc made, run again when what it read changes. */
class Computation {
	constructor(runtime, { kind, runner = null, owner, scope, target = null, name = null }) {
		this.id = ++ids;
		this.runtime = runtime;
		this.kind = kind;
		this.runner = runner;
		this.scope = scope;
		this.target = target;
		this.name = name;
		/** What its last run read (`addSource`). */
		this.sources = NONE;
		/** What reads it (made by the first: nothing reads most holes). */
		this.observers = null;
		/** What the last complete run made: child computations, boxes kept for them, cleanups. */
		this.made = MADE_NONE;
		/** Its requests' answers, by method, URL and body: a run again reads them. Made by the first
		 * request (most computations make none: a row's holes, a page's text). */
		this.calls = null;
		this.disposed = false;
		/** Run untracked (a `.map`'s row, an `if`'s part: Solid's mapArray and untrack,
		 * D-039): what it reads doesn't run it again; only a read that waits does, once it is in. */
		this.untracked = false;
		owner?.adopt(this);
	}

	adopt(child) {
		own(this.making ?? this.ownMade(), "children").push(child);
	}

	/** What its last complete run made, its own to add to (not the shared `MADE_NONE`). */
	ownMade() {
		if (this.made === MADE_NONE || this.made === MADE_READ) this.made = { ...this.made };
		return this.made;
	}
}

/** A <Loading>: its fallback until everything inside has its first values; later waits keep what is shown. */
class Loading {
	constructor() {
		this.waiting = new Set();
		this.revealed = false;
	}
	wait(computation) {
		if (!this.revealed) this.waiting.add(computation);
	}
	done(computation) {
		this.waiting.delete(computation);
		if (!this.revealed && this.built && this.waiting.size === 0) this.reveal();
	}
	reveal() {
		this.revealed = true;
		replaceRange(this.range, this.children);
	}
}

/** An <Errored>: when something inside fails, its fallback, given why and a retry. */
class Errored {
	constructor(runtime, { runner, nodes, owner, scope, range }) {
		this.runtime = runtime;
		this.id = ++ids;
		this.runner = runner;
		this.nodes = nodes;
		this.owner = owner;
		this.scope = scope;
		this.range = range;
		this.failed = null;
		this.memos = new Set();
		runtime.boundaries.set(this.id, this);
	}

	/** Builds what is inside: the nodes, their computations owned by this boundary. */
	build() {
		this.inside = new Computation(this.runtime, { kind: "boundary", owner: this.owner, scope: { ...this.scope, errored: this } });
		const fragment = document.createDocumentFragment();
		for (const node of this.nodes) fragment.append(this.runtime.build(node, this.inside, this.inside.scope));
		return fragment;
	}

	/** Hydrating: what is inside, as the server rendered it. */
	adopt(cursor) {
		this.inside = new Computation(this.runtime, { kind: "boundary", owner: this.owner, scope: { ...this.scope, errored: this } });
		for (const node of this.nodes) this.runtime.adopt(node, this.inside, this.inside.scope, cursor);
	}

	fail(problem, memo) {
		if (memo) this.memos.add(memo);
		if (this.failed !== null) return;
		this.failed = problem;
		// After the run that failed: what is inside stops, and the fallback shows instead.
		queueMicrotask(() => {
			if (this.failed === null) return;
			this.runtime.dispose(this.inside);
			this.fallback = new Computation(this.runtime, { kind: "html", runner: this.runner, owner: this.owner, scope: this.scope, target: this.range, name: "fallback" });
			this.fallback.boundary = this;
			this.runtime.run(this.fallback);
		});
	}

	/** Shows what is inside again, and reads again what failed: the memos it saw fail, and every
	 * failed memo they read, all the way up, as Solid 2.0's boundary reset does. A memo that reads
	 * one that failed fails with it, and may be all the boundary saw: read again alone, it would
	 * find the memo it reads still failed, and fail again. */
	retry() {
		if (this.failed === null) return;
		this.failed = null;
		this.runtime.dispose(this.fallback);
		const failed = new Set(this.memos);
		for (const memo of failed) {
			for (const source of memo.sources) if (source.kind === "memo" && source.state === "failed") failed.add(source);
		}
		for (const memo of failed) this.runtime.refresh(memo);
		this.memos.clear();
		replaceRange(this.range, this.build());
	}
}

/** Whether a computation is an `if`'s or `match`'s part picking its branch (D-070), or made by
 * one as it does (a store's selection its condition read): up to the first component, which reads
 * for itself. */
function choosing(computation) {
	for (let at = computation; at; at = at.owner) {
		if (at.choosing) return true;
		if (at.kind === "component") return false;
	}
	return false;
}

/** What D-070's hole shows, when it is text alone (one text node's JSON): that text, else null. */
function loneText(nodes) {
	return nodes.length === 1 && nodes[0]?.t === "s" ? nodes[0].v : null;
}

/** A markup hole's answer as nodes: D-070's hole answers a JSON string while it shows text alone. */
function answered(parsed) {
	return typeof parsed === "string" ? [{ t: "s", v: parsed }] : Array.isArray(parsed) ? parsed : [parsed];
}

/** The DOM between two comments: what a markup or list hole, or a boundary, shows. */
function makeRange(label) {
	const start = document.createComment(label);
	const end = document.createComment(`/${label}`);
	const fragment = document.createDocumentFragment();
	fragment.append(start, end);
	return { start, end, fragment };
}

function replaceRange(range, content) {
	while (range.start.nextSibling && range.start.nextSibling !== range.end) range.start.nextSibling.remove();
	range.end.parentNode.insertBefore(content, range.end);
}

/** The range's nodes, its comments with them, taken out to be put elsewhere. */
/** Whether a range isn't on the page: never put there (its fragment holds it), or taken off. */
function detached(range) {
	return range.start.parentNode === null || range.start.parentNode.nodeType === 11;
}

/**
 * Which rows stay where they are when a list's rows are put in order: `was` is where each row was
 * (by its place now; -1 for one that wasn't on the page), and the rows of a longest increasing run
 * of it are already in order among themselves, so only the others need to move. O(n log n).
 */
function steady(was) {
	const tails = [];
	const before = new Array(was.length).fill(-1);
	for (let index = 0; index < was.length; index++) {
		if (was[index] < 0) continue;
		let low = 0;
		let high = tails.length;
		while (low < high) {
			const middle = (low + high) >> 1;
			if (was[tails[middle]] < was[index]) low = middle + 1;
			else high = middle;
		}
		if (low > 0) before[index] = tails[low - 1];
		tails[low] = index;
	}
	const stays = new Array(was.length).fill(false);
	for (let index = tails.length ? tails[tails.length - 1] : -1; index >= 0; index = before[index]) stays[index] = true;
	return stays;
}

function collectRange(range) {
	const fragment = document.createDocumentFragment();
	let node = range.start;
	while (node) {
		const next = node.nextSibling;
		fragment.append(node);
		if (node === range.end) break;
		node = next;
	}
	return fragment;
}

/** A scope in which a provider (`{"t":"ctx","n":name,"v":id}`) gives its context its value. */
function provided(scope, node) {
	return { ...scope, contexts: { ...scope.contexts, [node.n]: node.v } };
}

/** The nodes in a range, between its comments. */
function inside(range) {
	const nodes = [];
	for (let node = range.start.nextSibling; node && node !== range.end; node = node.nextSibling) nodes.push(node);
	return nodes;
}

/** Everything between a range's comments, gone at once (a list whose rows all went): its parent
 * emptied when the range is all it holds, as vanillajs clears a table, else a DOM Range's contents
 * deleted. */
function clearRange(range) {
	const parent = range.start.parentNode;
	if (!parent) return;
	if (parent.firstChild === range.start && parent.lastChild === range.end) {
		parent.textContent = "";
		parent.append(range.start, range.end);
	} else {
		const between = document.createRange();
		between.setStartAfter(range.start);
		between.setEndBefore(range.end);
		between.deleteContents();
	}
}

function removeRange(range) {
	let node = range.start;
	while (node) {
		const next = node.nextSibling;
		node.remove();
		if (node === range.end) break;
		node = next;
	}
}

/**
 * The server's `<NoHydration>` regions under `root`, in the page's order, each taken out with its
 * comments (a fragment): rendering `root`'s part again, each placeholder takes the next, so the
 * server's markup stays, though the browser has no copy of what is inside. Inside a region there
 * are no comments of the runtime's, so it ends at the first `<!--/nohydration-->` after it.
 */
function serverRegions(root) {
	const starts = [];
	const walker = root.ownerDocument.createTreeWalker(root, 128 /* NodeFilter.SHOW_COMMENT */);
	for (let node = walker.nextNode(); node; node = walker.nextNode()) if (node.data === "nohydration") starts.push(node);
	return starts
		.map((start) => {
			let end = start.nextSibling;
			while (end && !(end.nodeType === 8 && end.data === "/nohydration")) end = end.nextSibling;
			return end ? collectRange({ start, end }) : null;
		})
		.filter(Boolean);
}

/** Why a handler inside a `<NoHydration>` is refused (signals.rs's `in_region`). */
const inRegion = (tag, event) => `rocx: <${tag} on:${event}> is inside <NoHydration>, which the browser never hydrates, so its handler would never run: render what has it outside <NoHydration>`;

/** What hydration found that the server's DOM doesn't match. */
class Mismatch extends Error {
	/** `found`: the node that isn't what the app renders (null: nothing was there). */
	constructor(message, found = null) {
		super(message);
		this.found = found;
	}
}

/** A node as a mismatch names it: `<div#id.class>` (its scoped-style classes left out),
 * `<!--show-->`, `text` (what it says isn't told: a page's text is its visitor's), or `nothing`. */
function named(node) {
	if (!node) return "nothing";
	if (node.nodeType === 1) {
		const id = node.id ? `#${node.id}` : "";
		const classes = words(node.getAttribute("class") ?? "").filter((name) => !name.startsWith("rx-")).slice(0, 3);
		return `<${node.localName}${id}${classes.map((name) => `.${name}`).join("")}>`;
	}
	if (node.nodeType === 3) return "text";
	if (node.nodeType === 8) return `<!--${node.data.slice(0, 40)}-->`;
	if (node.nodeType === 10) return "<!doctype>";
	return node.nodeName;
}

/** Where `element` is in the page, ` in body > main > ul.rows` (its last six levels), or nothing. */
function placed(element) {
	const path = [];
	for (let at = element; at?.nodeType === 1 && at.localName !== "html" && path.length < 6; at = at.parentNode) path.unshift(named(at).slice(1, -1));
	return path.length ? ` in ${path.join(" > ")}` : "";
}

/** Elements hydrating passed over (D-112): an extension's, straight in `<html>`, `<head>` or
 * `<body>`, left there when `<body>` is rendered again (`renderBody`). */
const foreignNodes = new WeakSet();
/** Whether hydrating passes over such elements: not when hydrating strictly (`hydrateDocument`). */
let foreignKept = true;

/**
 * Computations waiting to run (or effects whose apply is due), taken oldest first (by id): a set,
 * for `has` and `delete`, and a heap beside it, so taking the oldest of D waiting is log D, not a
 * sort of all D (a grid whose thousand cells read one signal has a thousand waiting at once). One
 * deleted from the set stays in the heap until it comes up, and is passed over then.
 */
class Pending {
	constructor() {
		this.set = new Set();
		this.heap = [];
	}
	get size() {
		return this.set.size;
	}
	has(computation) {
		return this.set.has(computation);
	}
	add(computation) {
		if (this.set.has(computation)) return;
		this.set.add(computation);
		const heap = this.heap;
		let at = heap.push(computation) - 1;
		while (at > 0) {
			const parent = (at - 1) >> 1;
			if (heap[parent].id <= computation.id) break;
			heap[at] = heap[parent];
			at = parent;
		}
		heap[at] = computation;
	}
	delete(computation) {
		return this.set.delete(computation);
	}
	/** The oldest waiting, no longer waiting; undefined with none. */
	take() {
		const heap = this.heap;
		while (heap.length) {
			const top = heap[0];
			const last = heap.pop();
			if (heap.length) {
				let at = 0;
				for (;;) {
					const left = 2 * at + 1;
					if (left >= heap.length) break;
					const right = left + 1;
					const child = right < heap.length && heap[right].id < heap[left].id ? right : left;
					if (heap[child].id >= last.id) break;
					heap[at] = heap[child];
					at = child;
				}
				heap[at] = last;
			}
			if (this.set.delete(top)) return top;
		}
		return undefined;
	}
}

/** An element the host put in the page, not the app (the bootstrap, the dev reload script). */
const hosts = (node) => node.nodeType === 1 && node.hasAttribute("data-rocx");

/** Text that is only HTML's whitespace, which the parser drops or moves around `<html>`. */
const blank = (text) => /^[\t\n\f\r ]*$/.test(text);
/** A `class`'s names. */
const words = (text) => text.split(/[\t\n\f\r ]+/).filter(Boolean);
/** Whether `attrs` give an element's `class` (`name`), or its `style`, `class:name`s
 * (`style:name`s) beside a value of its own: one attribute, then, written whole. */
const joined = (attrs, name) => attrs.some(([kind]) => (name === "class" ? kind === "ci" || kind === "co" : name === "style" && (kind === "sv" || kind === "so")));
/** Whether `attrs` compute the element's `name` (`class={…}`). */
const computedOf = (attrs, name) => attrs.some(([kind, named]) => named === name && (kind === "vo" || kind === "oo"));

/**
 * Walks the server's DOM, a node at a time, the children of `parent`. It passes over the host's own
 * elements (`[data-rocx]`). `rebuild`, in the document's and `<html>`'s children only: rendering a
 * page again, it passes over what the app doesn't render there too (an extension's nodes).
 */
class Cursor {
	constructor(node, parent = node?.parentNode ?? null, rebuild = false) {
		this.parent = parent;
		this.rebuild = rebuild;
		this.node = node;
	}
	get node() {
		return this.at;
	}
	set node(node) {
		while (node && hosts(node)) node = node.nextSibling;
		this.at = node;
	}
	/** Walking the document's children or `<html>`'s, where the parser moves whitespace around. */
	get top() {
		return this.parent?.nodeType === 9 || (this.parent !== null && this.parent === this.parent.ownerDocument?.documentElement);
	}
	/**
	 * Whether elements the app doesn't render may be here, passed over and left where they are
	 * (D-112): straight in the document's `<html>`, `<head>` or `<body>`, where a browser extension
	 * puts its own (a password manager's popup, a grammar checker's, a dark theme's style) before
	 * the app hydrates. Not when hydrating strictly (the tests'), where the page is exactly what the
	 * server sent.
	 */
	get foreign() {
		const parent = this.parent;
		const doc = parent?.ownerDocument;
		return foreignKept && !this.rebuild && !!doc && (parent === doc.body || parent === doc.head || parent === doc.documentElement);
	}
	/** Where elements may be passed over (`foreign`): to the first node `check` takes, if there is
	 * one after elements only; else it stays where it is. */
	passForeign(check) {
		if (!this.foreign) return;
		let at = this.node;
		while (at && at.nodeType === 1 && !check(at)) at = at.nextSibling;
		if (!at || !check(at)) return;
		for (let node = this.node; node !== at; node = node.nextSibling) foreignNodes.add(node);
		this.node = at;
	}
	/** What is left from here that the app doesn't render (null: nothing). The host's elements are
	 * passed over; whitespace where `blankToo` (at the top: the parser puts what follows `</body>` in
	 * it); and where elements may be (`foreign`), elements, and whitespace beside them. */
	left(blankToo) {
		const foreign = this.foreign;
		for (let node = this.node; node; node = node.nextSibling) {
			if (hosts(node) || ((blankToo || foreign) && node.nodeType === 3 && blank(node.data))) continue;
			if (foreign && node.nodeType === 1) {
				foreignNodes.add(node);
				continue;
			}
			return node;
		}
		return null;
	}
	take(check, what) {
		// The document's doctype, where the markup doesn't take it: the host writes one when the
		// markup begins with none (or with a hole's comment, its own doctype then inside).
		if (this.parent?.nodeType === 9 && this.node?.nodeType === 10 && !check(this.node)) this.node = this.node.nextSibling;
		if (this.rebuild) while (this.node && !check(this.node)) this.node = this.node.nextSibling;
		if (this.node && !check(this.node)) this.passForeign(check);
		const node = this.node;
		if (!node || !check(node)) throw new Mismatch(`expected ${what}, found ${named(node)}${placed(this.parent)}`, node);
		this.node = node.nextSibling;
		return node;
	}
	comment(label) {
		return this.take((node) => node.nodeType === 8 && node.data === label, `<!--${label}-->`);
	}
	/** The comment that ends the range starting before here (`<!--/label-->`), ranges inside skipped. */
	closing(label) {
		let depth = 0;
		for (let node = this.node; node; node = node.nextSibling) {
			if (node.nodeType !== 8) continue;
			if (!node.data.startsWith("/") && RANGES.has(node.data.split(":")[0])) depth++;
			else if (node.data.startsWith("/")) {
				if (depth === 0) {
					if (node.data !== `/${label}`) break;
					return node;
				}
				depth--;
			}
		}
		throw new Mismatch(`no <!--/${label}-->`);
	}
	end(end) {
		if (this.node !== end) this.passForeign((node) => node === end);
		if (this.node !== end) throw new Mismatch(`expected the end of a range, found ${named(this.node)}${placed(this.parent)}`, this.node);
	}
}

/** A <script> that won't run: the one the server sent ran as the page was read, and one built
 * again (a <Show> switching back, a page rendered again) mustn't run twice. Solid's don't run either:
 * a script the HTML parser makes for `innerHTML` is marked as started. */
function inertScript() {
	const template = document.createElement("template");
	template.innerHTML = "<script></script>";
	return document.importNode(template.content.firstChild, true);
}

/** Whether markup may have `name` (D-079), a byte loop (it runs for every element): an ASCII
 * letter, then letters, digits and `-`; an attribute's `_`, `.` and `:` too, and never `on…`, an
 * inline handler, which runs its value (rocx's handlers are `on:click`). signals.rs's `plain_tag`
 * and `plain_attribute`, and `Html.to_str`'s, are the same rule. */
function plainName(name, attribute) {
	const length = name.length;
	for (let at = 0; at < length; at++) {
		const c = name.charCodeAt(at) | 32;
		if (c >= 97 && c <= 122) continue;
		const code = name.charCodeAt(at);
		if (at === 0 || !((code >= 48 && code <= 57) || code === 45 || (attribute && (code === 95 || code === 46 || code === 58)))) return false;
	}
	return length > 0 && !(attribute && length >= 2 && (name.charCodeAt(0) | 32) === 111 && (name.charCodeAt(1) | 32) === 110);
}

/** Attributes that name themselves (the others are handlers, keys, classes and styles). */
const NAMED = new Set(["v", "o", "vo", "oo", "f", "fo"]);

/** Whether an element's markup gives it an `aria-current` of its own: a link that does isn't marked
 * (D-086). */
function ownsCurrent(node) {
	for (const [kind, name] of node.a) if (NAMED.has(kind) && name === "aria-current") return true;
	return false;
}
/** The names refused, each said once. */
const refusedNames = new Set();

/**
 * An element's markup as it may be written (D-079): `null` when it isn't (its tag isn't a plain
 * name, or it is a `<script>` that isn't as a `.rocx` file has it, its text as written, `raw`);
 * else `node`, or a copy without the attributes whose names it can't have. Each refused name is
 * said once on the console; `runtime`, when it is building, lets go of a refused computed
 * attribute's box. Markup built by hand in Roc (`Html.element`, `Html.attr`) can name anything.
 */
function writable(node, runtime) {
	const tag = node.tag;
	if (!plainName(tag, false) || (isScript(tag) && !(node.c.length && node.c.every((part) => part.t === "raw")))) {
		refuse(`<${tag}>`);
		return null;
	}
	let kept = null;
	for (let at = 0; at < node.a.length; at++) {
		const attribute = node.a[at];
		if (NAMED.has(attribute[0]) && !plainName(attribute[1], true)) {
			kept ??= node.a.slice(0, at);
			refuse(`${attribute[1]} on <${tag}>`);
			if (runtime && attribute[0].length === 2) runtime.releaseKept(attribute[2]);
		} else if (kept) kept.push(attribute);
	}
	return kept ? { ...node, a: kept } : node;
}

/** Whether a tag is `script`, in any case, without making a string. */
function isScript(tag) {
	if (tag.length !== 6) return false;
	for (let at = 0; at < 6; at++) if ((tag.charCodeAt(at) | 32) !== "script".charCodeAt(at)) return false;
	return true;
}

function refuse(what) {
	if (refusedNames.has(what)) return;
	refusedNames.add(what);
	console.warn(`rocx: ${what} isn't written: a page can't have that name (D-079). Markup built by hand (Html.element, Html.attr) names only plain elements and attributes, never an inline handler (on…) or a <script> of data`);
}

const RANGES = new Set(["app", "html", "list", "loading", "errored", "x", "show", "for", "row", "fallback", "nohydration"]);
/** The elements whose content the HTML parser reads as text (RCDATA): the server writes no hole's
 * comments inside one (they would show), and hydrating binds its holes to its text. */
const RCDATA = new Set(["title", "textarea"]);
const VOID = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);
const escape = (text) => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

/** The bootstrap the host puts before a page's `</body>` (server/host/src/signals.rs's `START`). */
const START = '<script type="module" data-rocx src="/rocx/start.js"></script>';

/** The bootstrap with the build's id (`Router.app!`, D-040), as signals.rs's `start` writes it. */
const startWith = (build) => (build === null ? START : `<script type="module" data-rocx data-build="${build.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")}" src="/rocx/start.js"></script>`);

/** A level made anew (D-040: it read the location once): a case no `<Show>`'s is, so its part is. */
const REMADE = Symbol("remade");

/** The `<NoHydration>` regions in a document, in order, each its comments (`{ start, end }`): inside
 * one there are no comments of the runtime's, so it ends at the first `<!--/nohydration-->` after it. */
function regionRanges(doc) {
	const ranges = [];
	const walker = doc.createTreeWalker(doc.documentElement ?? doc, 128 /* NodeFilter.SHOW_COMMENT */);
	for (let node = walker.nextNode(); node; node = walker.nextNode()) {
		if (node.data !== "nohydration") continue;
		let end = node.nextSibling;
		while (end && !(end.nodeType === 8 && end.data === "/nohydration")) end = end.nextSibling;
		if (end) ranges.push({ start: node, end });
	}
	return ranges;
}

/** A level's code, reached (D-040 §18): every level's is in the one wasm today, so at once. */
const REACHED = Promise.resolve();

/** Markup that is a whole document: `<html>` at its top, after a doctype and any holes' comments. */
const DOCUMENT = /^\s*(?:<!--[^>]*-->\s*|<!doctype[^>]*>\s*)*<html[\s>]/i;

/** The SVG namespace: an element inside an <svg> is made in it, or the browser doesn't draw it. */
const SVG = "http://www.w3.org/2000/svg";

/** Parts a walk for transitions passes over: theirs play when they come or go themselves. */
const OWN_PARTS = new Set(["show", "for", "leaving"]);

/** Whether someone asked their system for less motion: then no transition plays. */
const reducedMotion = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

/** What `js_fetch` answers (usize's largest, on wasm32) for a request whose caller unwinds. */
const WAITS = 0xffffffff;

/** The computations that run again when what they read changes: the ones a submission's result
 * reads again (`revalidate`). A component, the root and a handler run once. */
const READERS = new Set(["memo", "text", "attr", "flag", "class", "optional", "style", "html", "show", "for", "reaction", "transition", "drag"]);

/** A submission as Roc reads it (`Host.submission!`), its id too in a list (`Host.submissions!`). */
const submissionJson = ({ id, state, input, json, status, body }, listed = false) => JSON.stringify(listed ? { id, state, input, json, status, body } : { state, input, json, status, body });

/** The latest submission, once it is forgotten: none, and not the flash either. */
const CLEARED = submissionJson({ state: "cleared", input: "", json: false, status: 0, body: "" });

/** The events of drag and drop whose handlers the runtime takes part in (`dragAndDrop`). */
const DRAG_EVENTS = new Set(["dragstart", "dragenter", "dragleave", "drop"]);

/** What a drop target says it will do with a drag the source allows `allowed` for: a move, unless
 * only a copy or a link is allowed. */
const dropEffect = (allowed) => (/move|all|uninitialized/i.test(allowed ?? "all") ? "move" : /copy/i.test(allowed) ? "copy" : /link/i.test(allowed) ? "link" : "none");

/** A drag by touch or a pen (`pointerDrag`): held this long, moving less than `slop` pixels, it
 * starts (a swipe scrolls, a tap clicks); `edge` pixels from a box's edge that scrolls, the box
 * scrolls, at most `speed` pixels a frame. */
const POINTER_DRAG = { hold: 250, slop: 8, edge: 48, speed: 16 };

/** The events whose `.point` runs at most once an animation frame, with the latest place. */
const MOVES = new Set(["pointermove", "mousemove", "touchmove", "pointerrawupdate"]);

/** What a popover's own styles (`[popover]`) change of an element's look: kept as they were while a
 * glide lifts it into the top layer (`lift`). */
const POPOVER_LOOK = ["color", "background-color", "overflow-x", "overflow-y", "padding-top", "padding-right", "padding-bottom", "padding-left", ...["top", "right", "bottom", "left"].flatMap((side) => [`border-${side}-width`, `border-${side}-style`, `border-${side}-color`])];

/** What a drag (or a paste) carries but its files, as JSON for `Html.DragItem`s: each type and its
 * value, in order, without the runtime's own (`application/x-rocx`). */
const itemsOf = (transfer) => JSON.stringify([...(transfer?.types ?? [])].filter((type) => type !== "Files" && type !== "application/x-rocx").map((type) => ({ type, value: transfer.getData(type) })));

/** What a drag by touch or a pen carries (`pointerDrag`): a `DataTransfer` where the browser makes
 * one, otherwise one of the runtime's with the same reads and writes. */
function makeTransfer() {
	try {
		const transfer = new DataTransfer();
		// What it allows and what a drop target says it does, as the browser's own drag keeps them
		// (Chromium's made one ignores both writes): allowing anything until dragstart says otherwise.
		let allowed = "uninitialized";
		let effect = "none";
		Object.defineProperties(transfer, {
			effectAllowed: { get: () => allowed, set: (value) => void (allowed = String(value)), configurable: true },
			dropEffect: { get: () => effect, set: (value) => void (/^(none|copy|link|move)$/.test(value) && (effect = value)), configurable: true },
		});
		return transfer;
	} catch {
		const data = new Map();
		return {
			dropEffect: "none",
			effectAllowed: "uninitialized",
			files: [],
			items: [],
			get types() {
				return [...data.keys()];
			},
			setData: (type, value) => void data.set(String(type).toLowerCase(), String(value)),
			getData: (type) => data.get(String(type).toLowerCase()) ?? "",
			clearData: (type) => (type === undefined ? data.clear() : data.delete(String(type).toLowerCase())),
			setDragImage: () => {},
		};
	}
}

/** Whether Mod is ⌘ (macOS, iOS) or Ctrl (elsewhere), in key combinations (`on:keydown.Mod+K`). */
const MAC = typeof navigator !== "undefined" && /mac|iphone|ipad|ipod/i.test(navigator.userAgentData?.platform ?? navigator.platform ?? "");

/** The modifier keys, by their names in a combination, and the flag each sets on a key event; a
 * modifier key's own name as `event.key` has it (its own flag is ignored, as it is that key). */
const MODIFIERS = { Shift: ["shiftKey", "Shift"], Ctrl: ["ctrlKey", "Control"], Alt: ["altKey", "Alt"], Meta: ["metaKey", "Meta"] };

/**
 * What a key handler is for (`on:keydown.Enter`, `on:keydown.Shift+Enter`, `Mod+K`): a test of a key
 * event, true when that key is pressed with exactly those modifier keys held, so Shift+Enter isn't
 * Enter. Mod is ⌘ on macOS, Ctrl elsewhere. A letter or digit is the same in either case; when the
 * layout types something else there (Alt+K on macOS types ˚; a Cyrillic layout, л), it is the key in
 * its place (`event.code`). Nothing while an input method composes (an Enter that picks a word).
 */
function keyCombo(wanted) {
	const parts = wanted.split("+");
	const key = parts.pop();
	const held = new Set(parts.map((name) => (name === "Mod" ? (MAC ? "Meta" : "Ctrl") : name)));
	const single = /^[a-z0-9]$/i.test(key) ? key.toLowerCase() : null;
	const code = single && (/[0-9]/.test(single) ? `Digit${single}` : `Key${single.toUpperCase()}`);
	return (event) => {
		if (event.isComposing) return false;
		const pressed = event.key ?? "";
		if (single ? (/^[a-z0-9]$/i.test(pressed) ? pressed.toLowerCase() !== single : event.code !== code) : pressed !== key) return false;
		return Object.entries(MODIFIERS).every(([name, [flag, own]]) => key === own || Boolean(event[flag]) === held.has(name));
	};
}

/** A key event as `.keys` gives it to Roc: whether Shift, Ctrl, Alt, Meta and Mod were held (`1`
 * or `0` each), then the key. */
const keysOf = (event) => [event.shiftKey, event.ctrlKey, event.altKey, event.metaKey, MAC ? event.metaKey : event.ctrlKey].map((on) => (on ? "1" : "0")).join("") + (event.key ?? "");

/** A CSS property as `element.animate` names it: `transform-origin` is `transformOrigin`. */
const camel = (property) => property.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());

/** The scope an element's children are made in: an <svg>'s know they are SVG, so a `.map`'s row or
 * an `if`'s part made inside one later, in the browser, is SVG too. */
const within = (node, scope) => (node.tag === "svg" && !scope.svg ? { ...scope, svg: true } : scope);

/**
 * The tab's channels (`Endpoint.subscribe!`, `say!`, `resync!`): every subscription in the tab on
 * one stream, `GET /rocx/live?tab=…&c=<url>&c=<url>…` (server-sent events), whatever its number,
 * so a page's channels take one of the six connections a browser makes to a host. Two subscribers
 * to one channel share it.
 *
 * - The stream says its id first (`hello`). What the page subscribes to changes as effects run and
 *   components go: once the render that changed it is done, the hub tells the stream what it now
 *   subscribes to and what it dropped (`subscribe` and `unsubscribe`, in a post naming the stream's
 *   id: D-057), and the route's `on_close!` hears `Dropped` for each channel dropped; the stream
 *   stays open. Changes made before the stream has said hello are told once it has. With nothing
 *   left to subscribe to, the hub tells the stream, then closes it. A stream that never says hello
 *   (an older server) is opened again with the new set instead.
 * - Each time it opens, and for each channel subscribed over it, the server sends the channel
 *   `resync` (then the route's `on_open!` messages), or `refused`; then the channel's messages as
 *   they are published (`message`), and `ended` for one its check refuses at a beat (`: beat`
 *   comments, every 15 s).
 * - When the stream drops, the hub opens it again after a wait that doubles each time (from 0.5 s
 *   to 30 s), and once it has stayed up 10 s, starts over at 0.5 s.
 * - Each subscriber hears its events one at a time, in order: the next once its handler is done
 *   (a handler waiting for an answer runs again first).
 * - What the page says (`say!`), and its asks for a resync (`resync!`, a new subscriber to a channel
 *   already open), go in one `POST /rocx/live/send` a frame.
 * - The tab's id (`tab`, random, kept in sessionStorage, so a reload keeps it) names the tab to the
 *   server's hooks. A tab has one stream: the server ends a tab's old stream when a new one comes,
 *   telling it `replaced`, and a page that hears it is another tab with the same id (a duplicated
 *   tab copies sessionStorage), so it takes a new id before it connects again.
 * - Where no server answers (a static copy of the site: a 404, a 405, or a page that isn't a
 *   stream), every subscriber hears `Refused(404, …)` and the hub asks for nothing more.
 */
class Hub {
	constructor(runtime) {
		this.runtime = runtime;
		/** By URL: `{ subscribers, open, refused, ended }`, `open` once this stream sent its resync. */
		this.channels = new Map();
		/** The stream: the URLs it carries (as the hub has told the server), how to stop it, when it
		 * opened, its id once it said hello (`id`), or `legacy` once it spoke without one. */
		this.stream = null;
		this.reconciling = null;
		this.retrying = null;
		/** Drops in a row: the next wait is `first` doubled that many times, `most` at the most. */
		this.drops = 0;
		this.first = 500;
		this.most = 30000;
		/** How long a stream stays up before a drop starts the waits over. */
		this.steady = 10000;
		/** `[status, why]` once no server answers channels here. */
		this.unavailable = null;
		this.outbox = [];
		this.flushing = false;
		this.tabId = null;
		this.stats = { connects: 0, posts: 0 };
	}

	/** The tab's id: random, made once per tab, kept in sessionStorage (a reload keeps it). A new one
	 * (`fresh`) when the server said another tab has this one (`replaced`). */
	tab({ fresh = false } = {}) {
		if (this.tabId && !fresh) return this.tabId;
		const made = () => [...crypto.getRandomValues(new Uint8Array(12))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
		try {
			this.tabId = (!fresh && sessionStorage.getItem("rocx-tab")) || made();
			sessionStorage.setItem("rocx-tab", this.tabId);
		} catch {
			this.tabId = made();
		}
		return this.tabId;
	}

	/** A subscription (`Host.subscribe!`) for the running component, computation or effect: its
	 * handler kept until that owner is cleaned up. */
	subscribe(url, ptr) {
		const runtime = this.runtime;
		if (runtime.onServer) return runtime.ex.release(ptr);
		const cleanups = runtime.cleanupsOf(runtime.current);
		if (!cleanups) {
			runtime.ex.release(ptr);
			throw new Failed(`Endpoint.subscribe!(${url}) is called in a component, a computation or an effect, not in a handler: nothing would end it`);
		}
		const id = ++ids;
		runtime.kept.set(id, ptr);
		const subscriber = { id, url, scope: runtime.current?.scope ?? null, owner: runtime.owner(), queue: [], busy: false, gone: false };
		let channel = this.channels.get(url);
		const fresh = !channel;
		if (fresh) {
			channel = { subscribers: new Map(), open: false, refused: null, ended: null };
			this.channels.set(url, channel);
		}
		channel.subscribers.set(id, subscriber);
		cleanups.push(() => this.unsubscribe(subscriber));
		runtime.notify("subscribe", { url });
		// What the others on this channel heard that still holds: told once this run is done.
		const told = this.unavailable ? { Refused: this.unavailable } : channel.refused ? { Refused: channel.refused } : channel.ended !== null ? { Ended: channel.ended } : null;
		if (told) queueMicrotask(() => this.deliver(subscriber, told));
		// A new subscriber to a channel the stream has open: the server sends it its resync (and
		// `on_open!`'s messages) again.
		else if (channel.open) this.post(`{"channel":${JSON.stringify(url)},"resync":true}`);
		if (fresh) this.changed();
	}

	unsubscribe(subscriber) {
		subscriber.gone = true;
		subscriber.queue.length = 0;
		// After the handler running now, which may be its own.
		queueMicrotask(() => this.runtime.releaseKept(subscriber.id));
		this.runtime.notify("unsubscribe", { url: subscriber.url });
		const channel = this.channels.get(subscriber.url);
		if (!channel?.subscribers.delete(subscriber.id) || channel.subscribers.size) return;
		// Its last subscriber gone, the channel stays until the stream follows the set (`reconcile`):
		// one subscribing meanwhile (the next page's, as a navigation renders it, D-040) finds it open,
		// and is sent its resync.
		this.changed();
	}

	/** What the page says on a channel (`Host.say!`), for the next post. */
	say(url, json) {
		if (this.runtime.onServer) return;
		this.post(`{"channel":${JSON.stringify(url)},"message":${json}}`);
	}

	/** A resync of a channel the tab subscribes to (`Host.resync!`), asked of the server. */
	resync(url) {
		if (this.channels.get(url)?.open) this.post(`{"channel":${JSON.stringify(url)},"resync":true}`);
	}

	/** The set changed: once the render that changed it is done, the stream follows it. */
	changed() {
		if (this.reconciling) return;
		this.reconciling = setTimeout(() => {
			this.reconciling = null;
			this.reconcile();
		}, 0);
	}

	reconcile() {
		for (const [url, channel] of this.channels) if (!channel.subscribers.size) this.channels.delete(url);
		// A wait before the next try is under way: it opens the stream with the set as it is then.
		if (this.unavailable || this.retrying) return;
		const urls = [...this.channels.keys()].sort();
		const stream = this.stream;
		if (!stream) {
			if (urls.length) this.connect(urls);
			return;
		}
		const wanted = new Set(urls);
		const dropped = [...stream.urls].filter((url) => !wanted.has(url));
		const added = urls.filter((url) => !stream.urls.has(url));
		if (!dropped.length && !added.length) return;
		// An older server's stream, with no id: opened again with the new set.
		if (stream.legacy) {
			stream.controller.abort();
			this.stream = null;
			if (urls.length) this.connect(urls);
			return;
		}
		// Not said hello yet: told once it has.
		if (!stream.id) return;
		for (const url of dropped) {
			stream.urls.delete(url);
			this.post(`{"channel":${JSON.stringify(url)},"unsubscribe":true}`, { stream });
		}
		for (const url of added) {
			stream.urls.add(url);
			this.post(`{"channel":${JSON.stringify(url)},"subscribe":true}`, { stream });
		}
	}

	async connect(urls) {
		const controller = new AbortController();
		const stream = { urls: new Set(urls), controller, opened: performance.now(), id: null, legacy: false };
		this.stream = stream;
		// What was waiting to be told the old stream: this one carries the set as it is.
		this.outbox = this.outbox.filter((item) => !item.stream);
		for (const channel of this.channels.values()) Object.assign(channel, { open: false, refused: null, ended: null });
		this.stats.connects++;
		this.runtime.notify("connect", { urls });
		const query = [`tab=${encodeURIComponent(this.tab())}`, ...urls.map((url) => `c=${encodeURIComponent(url)}`)].join("&");
		try {
			const response = await fetch(this.runtime.under(`/rocx/live?${query}`), { headers: { accept: "text/event-stream" }, cache: "no-store", signal: controller.signal });
			if (!(response.headers.get("content-type") ?? "").startsWith("text/event-stream")) {
				response.body?.cancel();
				// A 5xx (a proxy while the server restarts, say) is tried again; anything else says no
				// server answers channels here.
				if (response.status < 500) return this.giveUp(stream);
				throw new Error(`${response.status}`);
			}
			const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
			let buffer = "";
			for (;;) {
				const { value, done } = await reader.read();
				if (done || this.stream !== stream) break;
				buffer += value.replaceAll("\r\n", "\n");
				// An event ends at a blank line: its `event:` name, and its `data:` lines (the channel's
				// URL, then what it says). A comment (`: beat`) is the server saying it is there.
				for (let end = buffer.indexOf("\n\n"); end >= 0; end = buffer.indexOf("\n\n")) {
					const lines = buffer.slice(0, end).split("\n");
					buffer = buffer.slice(end + 2);
					const field = (name) => lines.filter((line) => line.startsWith(`${name}:`)).map((line) => line.slice(name.length + 1).replace(/^ /, ""));
					const data = field("data");
					const kind = field("event")[0] ?? "message";
					if (!data.length || this.stream !== stream) continue;
					if (kind === "hello") {
						// Its id: the changes made meanwhile are told now.
						stream.id = data[0];
						this.runtime.notify("hello", { stream: stream.id });
						this.reconcile();
						continue;
					}
					if (!stream.id && !stream.legacy) {
						stream.legacy = true;
						this.reconcile();
					}
					this.dispatch(kind, data[0], data.slice(1).join("\n"));
				}
			}
		} catch {
			// Offline, or cut off: tried again, below. Aborted: replaced, or gone.
		}
		if (this.stream !== stream) return;
		this.stream = null;
		this.drops = performance.now() - stream.opened >= this.steady ? 0 : this.drops + 1;
		const wait = Math.min(this.most, this.first * 2 ** Math.max(0, this.drops - 1)) * (1 + Math.random() / 4);
		this.runtime.notify("dropped", { wait });
		this.retrying = setTimeout(() => {
			this.retrying = null;
			this.reconcile();
		}, wait);
	}

	/** No server answers channels here: every subscriber is told, and nothing more is asked. */
	giveUp(stream) {
		if (this.stream === stream) this.stream = null;
		this.unavailable = [404, "no server answers channels here (a static copy of the site?)"];
		for (const channel of this.channels.values()) for (const subscriber of channel.subscribers.values()) this.deliver(subscriber, { Refused: this.unavailable });
	}

	/** An event of the stream, for the channel at `url`; or `replaced`, for the stream: another tab
	 * has this one's id, and a stream of its own now. */
	dispatch(kind, url, said) {
		if (kind === "replaced") {
			this.runtime.notify("replaced", { tab: this.tabId });
			this.tab({ fresh: true });
			return;
		}
		const channel = this.channels.get(url);
		if (!channel) return;
		let heard;
		if (kind === "resync") {
			Object.assign(channel, { open: true, refused: null, ended: null });
			heard = "Resync";
		} else if (kind === "message") heard = { Message: said };
		else if (kind === "refused") {
			const { status, why } = JSON.parse(said);
			channel.refused = [status, why];
			heard = { Refused: channel.refused };
		} else if (kind === "ended") {
			Object.assign(channel, { open: false, ended: JSON.parse(said) });
			heard = { Ended: channel.ended };
		} else return;
		this.runtime.notify("heard", { url, heard });
		for (const subscriber of channel.subscribers.values()) this.deliver(subscriber, heard);
	}

	/** Its subscriber hears it after what it heard before: one at a time, each once the handler
	 * before is done. */
	deliver(subscriber, heard) {
		if (subscriber.gone) return;
		subscriber.queue.push(heard);
		this.pump(subscriber);
	}

	pump(subscriber) {
		while (!subscriber.busy && !subscriber.gone && subscriber.queue.length && this.runtime.kept.has(subscriber.id)) {
			const heard = subscriber.queue.shift();
			subscriber.busy = true;
			let returned = false;
			this.runtime.handle(subscriber.id, JSON.stringify(heard), subscriber.scope, {
				owner: subscriber.owner,
				done: () => {
					subscriber.busy = false;
					if (returned) this.pump(subscriber);
				},
			});
			returned = true;
		}
	}

	/** An item for the next post (`POST /rocx/live/send`): sent once this frame is done. A change of
	 * what the stream carries names it (`stream`), and is dropped if another stream opens first. */
	post(text, { stream = null } = {}) {
		if (this.unavailable) return;
		this.outbox.push({ text, stream });
		if (this.flushing) return;
		this.flushing = true;
		const go = () => {
			this.flushing = false;
			this.send();
		};
		if (typeof requestAnimationFrame === "function" && document.visibilityState === "visible") requestAnimationFrame(go);
		else setTimeout(go, 0);
	}

	async send() {
		const stream = this.stream;
		// Changes for a stream that has gone are dropped: the next carries the set as it is.
		const items = this.outbox.splice(0).filter((item) => !item.stream || item.stream === stream);
		if (!items.length) return;
		this.stats.posts++;
		const query = `tab=${encodeURIComponent(this.tab())}${stream?.id ? `&stream=${encodeURIComponent(stream.id)}` : ""}`;
		try {
			const response = await fetch(this.runtime.under(`/rocx/live/send?${query}`), { method: "POST", headers: { "content-type": "application/json" }, body: `[${items.map((item) => item.text).join(",")}]` });
			if (response.status === 200) {
				const { refused = [] } = await response.json();
				for (const { index, status, why } of refused) {
					// The stream it named has ended (or the server never had it): a new one carries
					// the set as it is.
					if (items[index].stream && status === 404) {
						if (this.stream === stream) {
							stream.controller.abort();
							this.stream = null;
							this.reconcile();
						}
					} else console.warn(`rocx: ${JSON.parse(items[index].text).channel} refused what was said: ${status} ${why}`);
				}
			} else if (response.status === 404 || response.status === 405) this.unavailable ??= [404, "no server answers channels here (a static copy of the site?)"];
			else if (!response.ok) console.warn(`rocx: what was said wasn't heard: ${response.status} ${await response.text()}`);
		} catch {
			// Offline: what was said is lost, as it would be if the tab closed.
		}
		// Nothing left to subscribe to, and the stream told so: it closes.
		if (this.stream === stream && stream && !this.channels.size && !stream.urls.size) {
			stream.controller.abort();
			this.stream = null;
		}
	}
}

export class Runtime {
	/** How many pages navigations and prefetches keep (D-040 §6.2), and for how long one is used
	 * again (ms); how long the pointer rests on a link before it is prefetched (ms, §11). */
	static CACHE = 8;
	static FRESH = 10_000;
	static REST = 65;
	/** How many leaves (`Router.use_before_leave!`'s) are kept for a `retry!` later; how long a load
	 * the runtime starts once the listeners let a navigation go isn't asked again (ms). */
	static LEAVES = 64;
	static ASKED = 1000;

	/**
	 * `base` is the path the site is served under (`/`, or `/rocx/` for a copy at
	 * `example.github.io/rocx/`): a URL Roc gives that begins with `/` (an endpoint's) is asked for
	 * under it.
	 */
	/**
	 * The runtime, its app's wasm loaded from `source`. `effects` are the page's own functions Roc's
	 * handlers may call (`Browser.call!(name, arg)`), by name, each given the argument, parsed; one
	 * not there is looked for on `window.rocxEffects` too, for a page start.js wakes up.
	 */
	static async load(source, { base = "/", effects = {} } = {}) {
		// The runtime first: its imports are what the wasm calls, each given as it is (a call from Roc
		// goes straight to it, through no wrapper). One the runtime hasn't fails at the call that needs it.
		const runtime = new Runtime(null, base);
		const env = new Proxy(runtime.imports, { get: (imports, name) => imports[name] ?? (() => { throw new Error(`rocx: the runtime has no import ${String(name)}`); }) });
		const resolved = await source;
		// Compiled as it downloads, when the server says it is wasm.
		const { instance } =
			resolved instanceof Response && typeof WebAssembly.instantiateStreaming === "function" && resolved.headers.get("content-type")?.startsWith("application/wasm")
				? await WebAssembly.instantiateStreaming(resolved, { env })
				: await WebAssembly.instantiate(resolved instanceof Response ? await resolved.arrayBuffer() : resolved, { env });
		runtime.ex = instance.exports;
		runtime.effects = effects;
		return runtime;
	}

	constructor(exports, base = "/") {
		this.ex = exports;
		/** The path the site is served under, ending with `/`. */
		this.base = base.endsWith("/") ? base : `${base}/`;
		/** Boxes kept for Roc, by id: computations, handlers, fallbacks. */
		this.kept = new Map();
		this.signals = new Map();
		this.memos = new Map();
		/** Selectors (`create_selector!`), by id: each its key now and a source each key read. */
		this.selectors = new Map();
		// Templates (`Html.template`, D-084): each site's id, and by id its skeleton (null until it comes,
		// false for a site refused).
		this.templateIds = new Map();
		this.templates = [null];
		/** The links the runtime marks (D-086): `<a href>`s it made or adopted with no `aria-current`
		 * of their own. */
		this.links = new WeakSet();
		/** Each `.map`'s rows (a "for" node), by key; its rows' indexes; and, by position, its items. */
		this.lists = new Map();
		this.boundaries = new Map();
		/** The browser's timers for Roc's (`Solid.set_timeout!`, `set_interval!`), by the id of the
		 * handler's box: `{ repeat, handle }`. */
		this.timers = new Map();
		/** The page's functions handlers call (`Browser.call!`), and the calls waiting for the patch.
		 * Those named `rocx:…` are the runtime's own: `Browser.focus!` is `rocx:focus`. (A plugin's
		 * script registers its own on `window.rocxEffects`: packages/audio's player, `audio.play`.) */
		this.effects = {};
		this.calling = [];
		/** What every effect is given after its argument (`callEffects`). */
		this.toEffects = Object.freeze({ under: (url) => this.under(url) });
		this.builtins = { "rocx:focus": (id) => this.page?.getElementById?.(id)?.focus() };
		/** Each element's transitions (`transition={…}`), `{ in, out }`, as `Transition.json` writes
		 * them; `animates` once there is one, so an app without any walks nothing for them. */
		this.transitions = new WeakMap();
		this.animates = false;
		/** Each element's style holes' values, as Roc gave them (`style:--x={…}`): an element the
		 * runtime makes writes its `style` as the server does (`inOrder`), not as the CSSOM would. */
		this.rawStyles = new WeakMap();
		/** An element's computed `class` (`class={…}`) and `style` beside `class:name`s and
		 * `style:name`s, the value each last had, and whether each `class:name` is on: its `class`
		 * and `style` written whole from them (`wholeClass`, `wholeStyle`), as the server writes
		 * them, so neither part drops the other. */
		this.computedClasses = new WeakMap();
		this.computedStyles = new WeakMap();
		this.classToggles = new WeakMap();
		/** Elements whose in-transition plays once what this flush changes is on the page. */
		this.entering = [];
		/** The `<Title>`s there are, by the computation of each one's hole: `{ seq, title }`, the
		 * highest `seq` (the last rendered) the document's (`showTitle`); `titled`, rendering as a
		 * server would, the page's. */
		this.titles = new Map();
		this.titleSeqs = 0;
		this.titlesDirty = false;
		this.titled = null;
		/** The `<Meta>`s, `<Link>`s and `<Style>`s there are (D-054), by the computation of each one's
		 * hole: `{ seq, key, markup }`, in `<head>` in the order of their first runs, a later one in
		 * the place of an earlier with its key (`showHead`); `headed`, rendering as a server would,
		 * the page's, in the order told. */
		this.heads = new Map();
		this.headSeqs = 0;
		this.headsDirty = false;
		this.headed = [];
		/** The transition a handler's optimistic writes are held by (`create_optimistic!`, D-054),
		 * open while its writes apply and its event goes on: the submissions sent meanwhile (its
		 * actions, the form its submit sends) join it. */
		this.transition = null;
		/** Rows and parts on their way out, by their first comment: each stays, inert, until its
		 * transitions are over. A `.map`'s rows put in order pass over them. `leavingNodes`:
		 * the range each one's top nodes are in. */
		this.leaving = new Map();
		this.leavingNodes = new WeakMap();
		/** Each element's name on the page (`key={…}`), and the elements that glide when they move
		 * (`transition:move`); where those were before the flush first changed the page (`measure`),
		 * and in what (their parents then); the glide each is playing, and how to put back one
		 * lifted out of what would clip it (`lift`). */
		this.keys = new WeakMap();
		this.gliders = new Set();
		this.measured = null;
		this.measuredIn = null;
		this.glides = new WeakMap();
		this.lifted = new Map();
		/** Whether a flush is running its computations now: the page changes only then. */
		this.inFlush = false;
		/** The drop targets a drag is over now (`depth` above 0), told it left when the drag ends. */
		this.overs = new Set();
		this.dragEnds = null;
		/** What an element's drag carries (`drag:data`) and shows (`drag:image`), by element; the drag
		 * by touch or a pen there is now (`pointerDrag`); the files dropped, pasted or chosen, by the
		 * `blob:` URL a handler was given (`fileOf`). */
		this.dragged = new WeakMap();
		this.pointerDrag = null;
		this.files = new Map();
		/** Letting go of what is inside a part that is leaving: its `.map`s' rows stay with it. */
		this.keeping = false;
		/** The computation or handler running now. */
		this.current = null;
		this.dirty = new Pending();
		/** Effects whose apply is due, after the flush. */
		this.due = new Pending();
		this.flushing = false;
		/** The endpoints a component asks for the submissions of (`use_submission!`,
		 * `use_submissions!`), by URL, and how many ask: their forms are sent too (with the route
		 * table's endpoints', D-095), and their finished submissions outlast a navigation; the
		 * submissions to each (forms', actions'), a source computations read; whether it listens for
		 * submits. */
		this.actions = new Map();
		this.submissions = new Map();
		this.submitting = null;
		/** The computations that read a GET from the server (`Endpoint.read!`): what a submission's
		 * result has read again before it is done (`revalidate`). */
		this.readers = new Set();
		/** Why the last request `js_fetch` answered "waits" for unwinds its caller (`js_waits`). */
		this.waiting = null;
		/** In the browser: the flash the page came with (`Server.flash!`). On the server: the flash
		 * the page being rendered read, for the page to carry. */
		this.flash = "";
		this.flashed = "";
		/** On the server: the names of the `<input type="password">`s the page being rendered has. */
		this.secrets = [];
		this.taken = null;
		this.stats = { runs: 0, aborts: 0, patches: 0, selections: 0 };
		/** In the browser: answers the server gave while rendering the page, by name and input. */
		this.answers = new Map();
		// The computations that read the flash (`js_flash`): run again when a navigation's document
		// brings another (D-119).
		this.flashReaders = new Set();
		// What the last navigation's commit read again from its document (D-119), for the submission
		// that asked for it (`sendSubmission`) to read the rest from the server.
		this.refreshed = null;
		/** On the server: the request being answered, as HTTP writes it (`METHOD target`, a header a
		 * line, a blank line, its body), and the answers noted. */
		this.request = "";
		this.recorded = [];
		/** The request's headers, as `[name, value]` pairs. */
		this.headers = [];
		/** Rendering as a server would (in Node, `renderToString`): a component's call of a server
		 * function is then answered from the page's recorded answers (`answers`), as the server
		 * platform answered it. */
		this.onServer = false;
		/** While hydrating: what the page asked the server for that it didn't carry (`asked`), which
		 * strict hydration refuses. */
		this.hydrating = null;
		/** The status the page is answered with (`<HttpStatusCode>`), rendering as a server would. */
		this.status = 200;
		/** The page the runtime is on: where it listens for forms' submits. */
		this.page = typeof document === "undefined" ? null : document;
		/** Whoever wants to see what the runtime does, as it does it (the docs' inspector): an object
		 * with any of `seeded`, `fetch`, `fetched`, `listen`, `unlisten`, `heard`, `patch`, `row`,
		 * `show`, `remade` (a part made anew), `frame`, `transition`, `glide` (an element moving),
		 * `effect` (a call of the page's own function), `apply` (an effect's apply), `submit`,
		 * `submitted`, `revalidate` (a submission's result reading the page's reads again), `warn` (a
		 * dev build's warning), the router's `navigate`, `navigated` and `leave`, and the hub's
		 * `hello`, `subscribe`, `unsubscribe`, `connect`, `replaced` and `dropped`. */
		this.observer = null;
		/** In a dev build, where the read a component's body is making is (`Html.read_at!`), and the
		 * places already warned of (`warnRead`). */
		this.place = null;
		this.warned = new Set();
		/** The tab's channels (`Endpoint.subscribe!`): one stream for all of them. */
		this.hub = new Hub(this);
		/** Where the page is (`Router.location!`, D-040), a source computations read: the location the
		 * page on screen was rendered for (`committed`; null until hydrating, `location`'s meanwhile),
		 * which a navigation in place commits. */
		this.locationSource = { observers: new Set() };
		this.committed = null;
		/** Whether a navigation in place is on its way (`Router.is_routing!`), a source. */
		this.routing = { on: false, observers: new Set() };
		/** `Router.use_before_leave!`'s listeners, in the order they came (each a computation of kind
		 * `leave`, owned by what made it); the leaves they were asked about lately, by id, for a
		 * `retry!` (`LEAVES` of them); the one being asked; the browser's prompt before a load, while
		 * one would stop it (`guardUnload`), and when the runtime last started a load they had let go. */
		this.leaveListeners = new Set();
		this.leaves = new Map();
		this.leaveAsked = null;
		this.unloadGuard = null;
		this.loadAsked = -Infinity;
		/** The app, as its root told it (`Router.app!`): `{ build, dev, routes, pages, error }`, the
		 * route table's pages each `{ path, parts, levels }` (`parts`: its path's segments, a param
		 * `null`), in the order `Root` tries them; null for an app that has no route table. Rendering as
		 * a server would, `built` is the build's id, for the page's bootstrap. */
		this.app = null;
		this.built = null;
		this.imports = this.makeImports();
	}

	notify(kind, detail) {
		if (this.observer) this.observer[kind]?.(detail);
	}

	// ---- Calling Roc ----

	text(ptr, len) {
		return decoder.decode(new Uint8Array(this.ex.memory.buffer, ptr >>> 0, len >>> 0));
	}

	/** Calls an export, in a frame of the host's (what it allocates is noted). An abort leaves Roc's
	 * stack pointer where the unwound frames left it: restore it. The error thrown says which frame
	 * unwound (`frame`): whoever catches it lets go of what the run made, then `reclaim`s it. */
	enter(call) {
		const sp = this.ex.__stack_pointer.value;
		const frame = this.ex.frame_begin();
		try {
			call();
			this.ex.frame_end(frame);
			return this.text(this.ex.result_ptr(), this.ex.result_len());
		} catch (error) {
			this.ex.__stack_pointer.value = sp;
			this.ex.frame_unwound(frame);
			if (error && typeof error === "object") error.frame = frame;
			throw error;
		}
	}

	/** What an unwound run made, freed now that the runtime has let go of what it handed over. */
	reclaim(error) {
		if (error?.frame) this.ex.reclaim(error.frame);
		if (error) error.frame = 0;
	}

	/** Answers an import with text: its length now, its bytes with `js_take`. */
	give(text) {
		this.taken = encoder.encode(text);
		return this.taken.length;
	}

	makeImports() {
		const text = (ptr, len) => this.text(ptr, len);
		return {
			js_log: (ptr, len) => console.log(text(ptr, len)),
			js_crashed: (ptr, len) => {
				throw new Error(`roc crashed: ${text(ptr, len)}`);
			},
			js_take: (dest) => new Uint8Array(this.ex.memory.buffer, dest >>> 0, this.taken.length).set(this.taken),
			js_keep: (ptr) => {
				const id = ++ids;
				this.kept.set(id, ptr);
				const making = this.current?.making;
				if (making) own(making, "kept").push(id);
				return id;
			},
			js_signal_new: (ptr) => {
				this.touch();
				const id = ++ids;
				this.signals.set(id, { id, value: ptr, observers: new Set() });
				// It belongs to the run that made it: when that run's part goes, it goes too.
				const making = this.current?.making;
				if (making) own(making, "signals").push(id);
				return id;
			},
			js_signal_get: (id) => {
				const signal = this.signals.get(id);
				if (!signal) throw new Error("rocx: a signal was read after the part that made it went away");
				this.track(signal);
				// Inside `update!` (D-094): the handler's own write, not yet applied, if it made one.
				if (this.current?.own > 0) return this.ownWrite(this.current, signal) ?? signal.value;
				return signal.value;
			},
			js_signal_set: (id, ptr) => {
				const handler = this.current;
				if (handler?.kind !== "handler") {
					this.ex.release(ptr);
					throw new Failed("a signal is written in a handler, not while computing");
				}
				handler.writes.push({ signal: this.signals.get(id), value: ptr });
			},
			js_memo_new: (ptr) => {
				this.touch();
				const memo = new Computation(this, { kind: "memo", runner: ptr, owner: this.current, scope: this.current?.scope ?? {} });
				memo.state = "pending";
				memo.value = 0;
				// Whether it has a value and waits for a new one (`refreshing`), or it or a memo it reads
				// does (`stale`): what is_pending! answers, its readers tracking `pending`.
				memo.refreshing = memo.stale = false;
				memo.pending = { observers: new Set() };
				this.memos.set(memo.id, memo);
				this.run(memo);
				return memo.id;
			},
			js_memo_done: (ptr, same) => {
				if (this.current?.next) this.ex.release(this.current.next);
				this.current.next = ptr;
				// A store's selection whose part is what it was (D-053): its readers aren't told.
				this.current.same = same !== 0;
			},
			// Whether the running computation tracks its reads, and so runs again when they change: a
			// store's selection is made only then (D-053). Rendering as a server would, nothing runs again.
			js_tracking: () => {
				const running = this.current;
				return !this.onServer && running?.making && running.making.untracked === 0 && !running.untracked && running.kind !== "component" && running.kind !== "once" ? 1 : 0;
			},
			// The running memo's value, for a store's selection to compare its new one with: 0 when it
			// has none yet (or failed), so it compares with itself. Each call is a selection's run.
			js_memo_last: () => {
				this.stats.selections++;
				const memo = this.current;
				return memo?.kind === "memo" && memo.state === "ok" && memo.value ? memo.value : 0;
			},
			// A signal's value with the running handler's own write, not yet applied, if it made one: a
			// store's setter starts from it, so two in one handler compose (D-053). Untracked.
			js_signal_latest: (id) => {
				const signal = this.signals.get(id);
				if (!signal) throw new Error("rocx: a signal was read after the part that made it went away");
				return (this.current?.kind === "handler" && this.ownWrite(this.current, signal)) || signal.value;
			},
			// `Solid.update!` (D-094): the running handler's reads of signals give its own writes from on
			// to off. Only a handler writes, so anywhere else there is nothing to give.
			js_own_writes: (on) => {
				const handler = this.current;
				if (handler?.kind === "handler") handler.own = Math.max(0, (handler.own ?? 0) + (on ? 1 : -1));
			},
			// A selector (`create_selector!`): a computation answering its source's key, and a source a
			// key, so a reader of a key runs again only when the answer for it changes (`settle`).
			js_selector_new: (ptr) => {
				this.touch();
				const selector = new Computation(this, { kind: "selector", runner: ptr, owner: this.current, scope: this.current?.scope ?? {} });
				selector.key = null;
				selector.keys = new Map();
				this.selectors.set(selector.id, selector);
				this.run(selector);
				return selector.id;
			},
			// A template's state, by its site (D-084): 0 (the markup itself) on the server and while
			// hydrating, whose nodes must be the server's, node for node; else its id times two, plus one
			// once its skeleton is here.
			js_template: (ptr, len) => {
				if (this.onServer || this.current?.adopting) return 0;
				const site = text(ptr, len);
				let id = this.templateIds.get(site);
				if (id === undefined) {
					id = this.templates.length;
					this.templates.push(null);
					this.templateIds.set(site, id);
				}
				const template = this.templates[id];
				return template === false ? 0 : id * 2 + (template ? 1 : 0);
			},
			js_selector_is: (id, ptr, len) => {
				const selector = this.selectors.get(id);
				if (!selector) throw new Error("rocx: a selector was read after the part that made it went away");
				const key = text(ptr, len);
				let source = selector.keys.get(key);
				if (!source) selector.keys.set(key, (source = { observers: null, selector, key }));
				this.track(source);
				if (selector.key === null) throw new NotReady(selector.settled ??= new Promise((resolve) => (selector.settle = resolve)));
				return selector.key === key ? 1 : 0;
			},
			js_memo_get: (id) => {
				const memo = this.memos.get(id);
				if (this.current?.kind === "probe") this.current.memos.add(memo);
				this.track(memo);
				// A memo computing again shows its last value meanwhile; with none yet, the reader waits.
				if (memo.state === "failed") throw new Failed(memo.error, memo);
				if (memo.value) return memo.value;
				throw new NotReady(memo.settled ??= new Promise((resolve) => (memo.settle = resolve)));
			},
			js_refresh: (ptr) => {
				// The memos the accessor reads, found by running it once (functions can't be compared).
				let memos;
				try {
					memos = this.probe(ptr);
				} finally {
					this.ex.release(ptr);
				}
				for (const memo of memos) this.later({ refresh: memo });
			},
			// Whether a memo the accessor reads is pending (`pending`). A computation that asks tracks
			// each one's `pending`, not its value, and keeps the probe: when one changes, it is run
			// again only if the probe, run again, answers otherwise (`answersChanged`).
			js_is_pending: (ptr) => {
				this.touch(true);
				if (this.onServer) {
					this.ex.release(ptr);
					return 0;
				}
				let memos;
				try {
					memos = this.probe(ptr);
				} catch (error) {
					this.ex.release(ptr);
					throw error;
				}
				const answer = this.pending(memos);
				const making = this.current?.making;
				// Untracked (`untrack!`), or a handler's: answered once, nothing kept.
				if (!making || making.untracked > 0) {
					this.ex.release(ptr);
					return answer ? 1 : 0;
				}
				const id = ++ids;
				this.kept.set(id, ptr);
				own(making, "kept").push(id);
				own(making, "queries").push({ probe: id, memos, answer });
				for (const memo of memos) this.track(memo.pending);
				return answer ? 1 : 0;
			},
			js_fail: (ptr, len) => {
				throw new Failed(text(ptr, len));
			},
			js_event_value: () => this.give(this.current?.event ?? ""),
			js_boundary: () => this.current.boundary.id,
			js_problem: () => this.give(this.current.boundary.failed ?? ""),
			js_retry: (id) => this.later({ retry: this.boundaries.get(id) }),
			js_request: () => this.give(this.request),
			js_for_new: () => {
				const id = ++ids;
				this.lists.set(id, { id, rows: new Map(), indexes: new Map(), items: new Map() });
				return id;
			},
			js_row_index: (id, ptr, len) => {
				const index = this.lists.get(id).indexes.get(text(ptr, len));
				this.track(index);
				return index.value;
			},
			// A row's item; and whether the page shows its row already (kept: it needs no box).
			js_row_set: (id, keyPtr, keyLen, ptr, same) => {
				const list = this.lists.get(id);
				const at = text(keyPtr, keyLen);
				const item = list.items.get(at);
				if (!item) {
					list.items.set(at, { value: ptr, observers: null });
					return list.rows.has(at) ? 1 : 0;
				}
				this.ex.release(item.value);
				item.value = ptr;
				// A <For compared>'s item `==` the one the row had (D-053): the row isn't told; it keeps the newest.
				if (!same) for (const observer of item.observers ?? NONE) this.schedule(observer);
				return list.rows.has(at) ? 1 : 0;
			},
			// A row's item, untracked, for a <For compared> to compare its new one with: 0 for a new row.
			js_row_last: (id, keyPtr, keyLen) => this.lists.get(id).items.get(text(keyPtr, keyLen))?.value ?? 0,
			js_row_get: (id, keyPtr, keyLen) => {
				const item = this.lists.get(id).items.get(text(keyPtr, keyLen));
				this.track(item);
				return item.value;
			},
			// A provider's value: kept while the run that made it is, as a computation's box is.
			js_context_value: (ptr) => {
				const id = ++ids;
				this.kept.set(id, ptr);
				const making = this.current?.making;
				if (making) own(making, "kept").push(id);
				return id;
			},
			js_context_find: (ptr, len) => this.current?.scope?.contexts?.[text(ptr, len)] ?? 0,
			js_context_get: (id) => this.kept.get(id),
			// A request's answer; one that isn't in (or failed) is thrown by `js_waits`, once the host has
			// let go of the request's text (a throw would skip that).
			js_fetch: (mp, ml, up, ul, hp, hl, bp, bl) => {
				try {
					return this.fetchFor(text(mp, ml), text(up, ul), text(hp, hl), text(bp, bl));
				} catch (error) {
					if (!(error instanceof NotReady || error instanceof Failed)) throw error;
					this.waiting = error;
					return WAITS;
				}
			},
			js_waits: () => {
				const error = this.waiting;
				this.waiting = null;
				throw error;
			},
			js_listen: (up, ul, ptr) => {
				this.touch();
				return this.listenTo(text(up, ul), ptr);
			},
			js_subscribe: (up, ul, ptr) => {
				this.touch();
				return this.hub.subscribe(text(up, ul), ptr);
			},
			js_say: (up, ul, sp, sl) => this.hub.say(text(up, ul), text(sp, sl)),
			js_resync: (up, ul) => this.hub.resync(text(up, ul)),
			js_live_publish: () => {
				throw new Failed("Endpoint.publish! is the server's: a page says things on a channel with Endpoint.say!");
			},
			js_timer: (ms, repeat, ptr) => {
				this.touch();
				return this.startTimer(ms, repeat === 1, ptr);
			},
			js_clear_timer: (id) => this.clearTimer(id),
			js_browser_call: (np, nl, ap, al) => {
				const name = text(np, nl);
				const handler = this.current;
				// Only a handler acts: a computation runs again whenever what it read changes.
				if (handler?.kind !== "handler") throw new Failed(`Browser.call!("${name}") is a handler's: call it from an event, a frame or a timer, not while computing`);
				handler.writes.push({ effect: name, arg: text(ap, al) });
			},
			// Where the page is: a source the computation reading it tracks, so a navigation in place
			// runs it again (D-040). A component's body reads it once (`readOnce`: phase 2's levels).
			js_location: () => {
				this.touch(true);
				const reader = this.current;
				if (reader?.making && reader.making.untracked === 0) addSource(reader.making, this.locationSource);
				// An `if`'s or `match`'s part (D-070) reads its condition again as it is made, to pick its
				// branch: its case computation follows that read, so it isn't one made once.
				if (reader && !choosing(reader) && (reader.kind === "component" || reader.making?.untracked > 0 || reader.untracked)) this.readOnce?.(reader);
				return this.give(this.location());
			},
			// `Router.app!` (D-040): the build's id, whether it is a dev build, and the route table.
			js_app: (bp, bl, dev, rp, rl) => {
				const build = text(bp, bl);
				if (this.onServer) {
					this.built = build;
					return;
				}
				const routes = text(rp, rl);
				if (this.app?.build === build && this.app.routes === routes && this.app.dev === (dev === 1)) return;
				this.app = { ...Runtime.routeTable(routes), build, dev: dev === 1, routes };
				// A form to one of its endpoints is sent with fetch, whoever asks for it (D-095).
				if (this.app.posts.length) this.listenForSubmits();
			},
			// `Router.navigate!`, `navigate_with!`: once the handler is done, as its writes are.
			js_navigate: (tp, tl, replace, scroll) => {
				if (this.onServer) return;
				const to = text(tp, tl);
				const handler = this.current;
				if (handler?.kind !== "handler") throw new Failed(`Router.navigate!("${to}") is a handler's: call it from an event, a timer or an effect's apply, not while computing (render <Navigate> to send the visitor elsewhere as a page renders)`);
				handler.writes.push({ navigate: { to, replace: replace === 1, scroll: scroll === 1 } });
			},
			// `Router.is_routing!`: tracked; false rendering as a server would.
			js_is_routing: () => {
				this.touch(true);
				if (this.onServer) return 0;
				this.track(this.routing);
				return this.routing.on ? 1 : 0;
			},
			// `Router.use_before_leave!` (D-040): a listener, a computation of its own owned by what is
			// running (it goes when that goes), asked ahead of a load in the next flush (`probeLeave`),
			// and before each navigation in place (`mayLeave`). Rendering as a server would, nothing.
			js_before_leave: (ptr) => {
				this.touch();
				if (this.onServer) return this.ex.release(ptr);
				const owner = this.current;
				if (!owner?.making) {
					this.ex.release(ptr);
					throw new Failed("Router.use_before_leave! is called in a component or a computation, which its listener goes with: in a handler or an effect's apply, nothing would own it");
				}
				const id = ++ids;
				this.kept.set(id, ptr);
				const listener = new Computation(this, { kind: "leave", runner: id, owner, scope: owner.scope ?? {} });
				listener.owner = owner;
				listener.prevents = false;
				this.leaveListeners.add(listener);
				this.schedule(listener);
			},
			// `Leave.prevent!`: the leave its listeners are being asked about, stopped; asked ahead of a
			// load (id 0), the probe's answer.
			js_leave_prevent: (id) => {
				const asking = this.current;
				if (asking?.leaveProbe) {
					if (id === 0) asking.prevented = true;
				} else if (this.leaveAsked?.id === id) this.leaveAsked.prevented = true;
			},
			// `Leave.retry!`: once the handler is done, as `navigate!` is.
			js_leave_retry: (id, force) => {
				if (this.onServer) return;
				const handler = this.current;
				if (handler?.kind !== "handler") throw new Failed("Leave.retry! is a handler's: call it from an event, a timer or an effect's apply, not while computing");
				handler.writes.push({ leaveRetry: { id, force: force === 1 } });
			},
			js_status: (code) => {
				if (this.onServer) this.status = code;
			},
			// An effect: owned by the component or computation running, its compute run now. On the
			// server, nothing (Solid's server doesn't run effects).
			js_effect_new: (ptr) => {
				this.touch();
				if (this.onServer) return this.ex.release(ptr);
				const owner = this.current;
				if (!owner?.making) {
					this.ex.release(ptr);
					throw new Failed("create_effect! is made in a component or a computation, not in a handler or an effect's apply: nothing would own it");
				}
				// Its kind is "reaction": "effect" is Browser.call!'s (a handler's `{ effect }` write, the
				// observers' `effect`, the page's `effects`).
				const effect = new Computation(this, { kind: "reaction", runner: ptr, owner, scope: owner.scope ?? {} });
				effect.cleanups = [];
				effect.apply = 0;
				// A render effect's apply runs at once (`render`); an error handler's box (`onError`)
				// takes a failed compute instead of the nearest <Errored>, and what failed waits for it
				// in `failure` (D-052). Its compute says so, first (`js_effect_options`).
				effect.render = false;
				effect.onError = 0;
				effect.failure = null;
				this.run(effect);
			},
			// The running effect's options, which its compute tells before it computes
			// (`create_render_effect!`, `create_effect_with!`).
			js_effect_options: (render, error) => {
				const effect = this.current;
				if (effect?.kind !== "reaction") return;
				effect.render = render === 1;
				effect.onError = error;
			},
			js_cleanup: (ptr) => {
				this.touch();
				if (this.onServer) return this.ex.release(ptr);
				const cleanups = this.cleanupsOf(this.current);
				if (!cleanups) {
					this.ex.release(ptr);
					throw new Failed("on_cleanup! is called in a component, a computation or an effect: in a handler, nothing would ever run it");
				}
				const id = ++ids;
				this.kept.set(id, ptr);
				cleanups.push(id);
			},
			// The flash: on the server, what Roc found in the request's cookie, noted for the page; in the
			// browser, what the page noted.
			js_flash: (ptr, len) => {
				// What reads the flash runs again when a navigation brings another (D-119).
				if (!this.onServer) {
					if (this.current) this.flashReaders.add(this.current);
					return this.give(this.flash);
				}
				const found = text(ptr, len);
				if (found) this.flashed = found;
				return this.give(found);
			},
			js_action: (ptr, len) => {
				this.touch();
				if (this.onServer) return;
				const key = this.actionKey(text(ptr, len));
				this.actions.set(key, (this.actions.get(key) ?? 0) + 1);
				this.listenForSubmits();
				this.cleanupsOf(this.current)?.push(() => {
					const left = (this.actions.get(key) ?? 1) - 1;
					if (left > 0) this.actions.set(key, left);
					else this.actions.delete(key);
				});
			},
			// The latest submission to an endpoint: none once it is forgotten (`clear!`), until the next.
			js_submission: (ptr, len) => {
				this.touch(true);
				if (this.onServer) return this.give("");
				const source = this.submissionOf(this.actionKey(text(ptr, len)));
				this.track(source);
				if (source.cleared) return this.give(CLEARED);
				const latest = source.list.at(-1);
				return this.give(latest ? submissionJson(latest) : "");
			},
			js_submissions: (ptr, len) => {
				this.touch(true);
				if (this.onServer) return this.give("");
				const source = this.submissionOf(this.actionKey(text(ptr, len)));
				this.track(source);
				if (!source.list.length && !source.cleared) return this.give("");
				return this.give(`{"cleared":${source.cleared},"list":[${source.list.map((entry) => submissionJson(entry, true)).join(",")}]}`);
			},
			js_submission_clear: (ptr, len) => {
				if (!this.onServer) this.later({ cleared: this.actionKey(text(ptr, len)) });
			},
			js_submission_drop: (ptr, len, id) => {
				if (!this.onServer) this.later({ dropped: this.actionKey(text(ptr, len)), id });
			},
			// An action (`use_action!`): sent once the handler is done, so one that waits and runs again
			// sends it once.
			js_submit: (mp, ml, up, ul, bp, bl, ip, il) => {
				if (this.onServer) return;
				const handler = this.current;
				const url = text(up, ul);
				if (handler?.kind !== "handler") throw new Failed(`use_action!(${url})'s function sends from a handler (an event, a timer, an effect's apply), not while computing`);
				handler.writes.push({ submit: { method: text(mp, ml), url, body: text(bp, bl), input: text(ip, il) } });
			},
			// `Router.revalidate!` in a handler (D-054): those reads read again once it is done.
			js_revalidate: (ptr, len) => {
				if (this.onServer) return;
				const keys = JSON.parse(text(ptr, len));
				const handler = this.current;
				if (handler?.kind !== "handler") throw new Failed("Router.revalidate! reads again from a handler (an event, a timer, an effect's apply), not while computing");
				handler.writes.push({ revalidate: keys });
			},
			// `retry!` (D-054): a submission sent again, once the handler is done.
			js_submission_retry: (ptr, len, id) => {
				if (!this.onServer) this.later({ retried: this.actionKey(text(ptr, len)), id });
			},
			// `create_optimistic!`'s write (D-054): applied with the handler's writes, held by their transition.
			js_optimistic_set: (id, ptr) => {
				const handler = this.current;
				if (handler?.kind !== "handler") {
					this.ex.release(ptr);
					throw new Failed("an optimistic value is written in a handler, not while computing");
				}
				handler.writes.push({ optimistic: { signal: this.signals.get(id), value: ptr } });
			},
			// The clock (`Time`): for handlers, effects and timers; markup made from it wouldn't hydrate.
			js_now_millis: () => Date.now(),
			js_now_precise: () => performance.timeOrigin + performance.now(),
			// A <Title>'s hole: rendering as a server would, the page's title (the last one rendered);
			// in the browser, its computation's, until it runs again or goes (`showTitle`).
			js_title: (ptr, len) => {
				this.touch();
				const title = text(ptr, len);
				if (this.onServer) {
					this.titled = title;
					return;
				}
				const owner = this.current;
				const cleanups = this.cleanupsOf(owner);
				if (!cleanups) throw new Failed("a <Title> says the title in its own hole: Html.document_title is rocx's to write");
				// Its place among the titles is the first run's, so running again doesn't move it up.
				owner.titleSeq ??= ++this.titleSeqs;
				this.titles.set(owner, { seq: owner.titleSeq, title });
				cleanups.push(() => {
					this.titles.delete(owner);
					this.titleChanged();
				});
				this.titleChanged();
			},
			// A <Meta>, <Link> or <Style>'s hole (D-054): rendering as a server would, noted for the page's
			// <head>; in the browser, its computation's, until it runs again or goes (`showHead`).
			js_head: (kp, kl, mp, ml) => {
				this.touch();
				const key = text(kp, kl);
				const markup = text(mp, ml);
				if (this.onServer) {
					this.headed.push({ key, markup });
					return;
				}
				const owner = this.current;
				const cleanups = this.cleanupsOf(owner);
				if (!cleanups) throw new Failed("a <Meta>, <Link> or <Style> says its element in its own hole: Html.document_head is rocx's to write");
				// Its place is the first run's, so running again doesn't move it.
				owner.headSeq ??= ++this.headSeqs;
				this.heads.set(owner, { seq: owner.headSeq, key, markup });
				cleanups.push(() => {
					this.heads.delete(owner);
					this.headChanged();
				});
				this.headChanged();
			},
			// `untrack!` (Solid's `untrack`): the running computation's reads aren't tracked until it is
			// done (on, then off); a computation made meanwhile tracks its own.
			js_untrack: (on) => {
				const making = this.current?.making;
				if (making) making.untracked = Math.max(0, making.untracked + (on ? 1 : -1));
			},
			// A dev build's `Html.read_at!`: where the read a component's body makes is, until it is done;
			// the place before, given back for it to restore.
			js_read_at: (ptr, len) => {
				const outer = this.place ?? "";
				this.place = text(ptr, len) || null;
				return this.give(outer);
			},
		};
	}

	/** Where a cleanup made now goes: the running computation's run, or an effect's apply. */
	cleanupsOf(current) {
		return current?.making ? own(current.making, "cleanups") : (current?.cleanups ?? null);
	}

	/** Runs cleanups, the last first, and empties the list: a kept box's id is run as a handler (it
	 * may write signals) and let go of; a function is the runtime's own. */
	cleanUp(cleanups) {
		if (!cleanups?.length) return;
		for (const cleanup of cleanups.splice(0).reverse()) {
			if (typeof cleanup === "function") {
				cleanup();
				continue;
			}
			if (!this.kept.has(cleanup)) continue;
			this.handle(cleanup, "");
			const ptr = this.kept.get(cleanup);
			this.kept.delete(cleanup);
			if (ptr) this.ex.release(ptr);
		}
	}

	// ---- Forms ----

	/** An endpoint's URL as the runtime keys its forms: the path without the site's base, and the
	 * query. */
	actionKey(url) {
		if (typeof location === "undefined") return url;
		const resolved = new URL(this.under(url), location.href);
		return `${this.unbased(resolved.pathname)}${resolved.search}`;
	}

	/** The submissions to an endpoint, oldest first (`list`), each `{ id, state, input, json,
	 * status, body }`: a source computations read. `cleared` once the latest was forgotten, until
	 * the next is sent: the latest is then none, and so is the flash. */
	submissionOf(key) {
		let source = this.submissions.get(key);
		if (!source) this.submissions.set(key, (source = { list: [], cleared: false, observers: new Set() }));
		return source;
	}

	/** The submissions to an endpoint changed: what read them runs again. */
	submissionsChanged(source) {
		for (const observer of source.observers) this.schedule(observer);
	}

	/** Listens for forms submitted on the page, once: `submitted` sends the ones it should. */
	listenForSubmits() {
		if (this.submitting || typeof this.page?.addEventListener !== "function") return;
		this.submitting = (event) => this.submitted(event);
		this.page.addEventListener("submit", this.submitting);
	}

	/**
	 * A form submitted: sent with fetch if it posts to one of the app's endpoints (the route table's,
	 * D-095) or to one a component reads the submission of, on this site, into this tab, and no
	 * handler prevented its submit. Its fields go as a form sends them: URL-encoded, or, a form with
	 * files (`enctype="multipart/form-data"`), as the browser's `FormData` (D-054). One a component
	 * reads the submissions of goes with `accept: application/json` and `x-rocx-submission: 1`, so the
	 * endpoint answers its result, or its refusal, for that component to show. One nothing on the page
	 * reads goes as the browser would post it (`accept: text/html`, no `x-rocx-submission`), with
	 * `x-rocx-in-place: 1` (D-118): the endpoint answers it as a plain form (its result or refusal
	 * flashed back to the page it came from, or its own redirect), the server gives the runtime that
	 * redirect to read (`Endpoint.for_runtime`), and the runtime follows it in place. So the page shows
	 * what a plain post would have shown, and only the page changes. A form whose URL is an
	 * endpoint's with fields in its query (`Endpoint.with_fields`) is that endpoint's, those fields
	 * first in its input. Any other form is the browser's (another site's, a `target`ed one, a path no
	 * endpoint has: a plugin's own route).
	 */
	submitted(event) {
		if (event.defaultPrevented) return;
		const form = event.target;
		if (!form || form.localName !== "form") return;
		const submitter = event.submitter ?? null;
		const of = (name, attribute) => (submitter?.hasAttribute(attribute) ? submitter.getAttribute(attribute) : form.getAttribute(name)) ?? "";
		if (of("method", "formmethod").toLowerCase() !== "post") return;
		const enctype = of("enctype", "formenctype").toLowerCase();
		if (enctype === "text/plain") return;
		// Into another tab or frame: fetch has nowhere to show the answer.
		const target = of("target", "formtarget").toLowerCase();
		if (target && target !== "_self") return;
		const url = new URL(of("action", "formaction"), location.href);
		const key = this.formKey(url);
		if (key === null) return;
		event.preventDefault();
		const data = new FormData(form, submitter ?? undefined);
		// What it sent, as the endpoint reads it: the URL's fields (`with_fields`'), then the form's, a
		// file's its name.
		const own = new URLSearchParams([...data].map(([name, value]) => [name, typeof value === "string" ? value : value.name])).toString();
		const input = [url.search.slice(1), own].filter(Boolean).join("&");
		// Nothing on the page reads its submissions: answered as a plain form, in place (D-118).
		const plain = !this.actions.has(key);
		if (enctype === "multipart/form-data") this.submit(key, url.href, { body: data, input, json: false, plain });
		else this.submit(key, url.href, { headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(data).toString(), input, json: false, plain });
	}

	/** What a form posting to `url` is kept under, its submissions' key: the endpoint a component
	 * asks for (`submittedKey`); else, one of the app's endpoints that take a POST (D-095), by its
	 * path (its URL's query is fields, `with_fields`'); null for none: another site's, a path outside
	 * the site's base, or one no endpoint has. */
	formKey(url) {
		if (url.origin !== location.origin) return null;
		const base = this.base.slice(0, -1);
		if (base && url.pathname !== base && !url.pathname.startsWith(this.base)) return null;
		const path = this.unbased(url.pathname);
		return this.submittedKey(`${path}${url.search}`) ?? (this.postOf(path) ? path : null);
	}

	/** The endpoint a form's URL (its path without the site's base, and its query) is: one the
	 * runtime sends forms to, or one whose URL with fields after it this is (`Endpoint.with_fields`),
	 * the longest; null for none. */
	submittedKey(key) {
		if (this.actions.has(key)) return key;
		let found = null;
		for (const known of this.actions.keys()) {
			if ((key.startsWith(`${known}?`) || key.startsWith(`${known}&`)) && known.length > (found?.length ?? -1)) found = known;
		}
		return found;
	}

	/**
	 * An action (`use_action!`), sent: its arg as JSON in its body, as `Endpoint.send!` sends it. One
	 * whose arg has a top-level field holding the URL of a file the page has (`fileOf`: a picked,
	 * dropped or pasted file's, `Html.File`'s `url`), or a list of them, goes as a form with files
	 * (D-054): each such file a part of that field's name, the other fields as a form's (text as it
	 * is; a number, `true` or `false` as written; a list as its items). The input is the JSON, so a
	 * pending input's file field is still its URL (an `<img src>` of what is on its way).
	 */
	sendAction({ method, url, body, input }) {
		const href = typeof location === "undefined" ? this.under(url) : new URL(this.under(url), location.href).href;
		const data = this.filesForm(body);
		if (data) return this.submit(this.actionKey(url), href, { method, body: data, input, json: true });
		const headers = method === "GET" || method === "HEAD" ? {} : { "content-type": "application/json" };
		this.submit(this.actionKey(url), href, { method, headers, body, input, json: true });
	}

	/** An action's JSON as a form with files (`FormData`), if a top-level field of it holds a file's
	 * URL the page has (or a list of them); else null. A record inside a field can't go in a form:
	 * it fails, saying so. */
	filesForm(json) {
		let arg;
		try {
			arg = JSON.parse(json);
		} catch {
			return null;
		}
		if (!arg || typeof arg !== "object" || Array.isArray(arg)) return null;
		const file = (value) => (typeof value === "string" ? this.fileOf(value) : null);
		const holdsFiles = Object.values(arg).some((value) => file(value) || (Array.isArray(value) && value.length && value.every((item) => file(item))));
		if (!holdsFiles) return null;
		const data = new FormData();
		for (const [name, value] of Object.entries(arg)) {
			for (const item of Array.isArray(value) ? value : [value]) {
				const found = file(item);
				if (found) data.append(name, found, found.name);
				else if (item === null) continue;
				else if (typeof item === "object") throw new Failed(`an action with a file goes as a form, and its field ${name} is a record, which a form doesn't have`);
				else data.append(name, String(item));
			}
		}
		return data;
	}

	/**
	 * Sends a submission to an endpoint (a form's fields, or an action's arg), a new one in its
	 * list, pending until it is answered: 200, its result (JSON); any other status, a refusal; none,
	 * status 0 and why. Several may be on their way at once, each answered on its own. A result has
	 * the page's reads read again (`revalidate`) before the submission is done, so what shows the
	 * server's data and the submission's end changes at once. A redirect of the endpoint's own
	 * (`x-rocx-redirect`), or one fetch followed (middleware's), is where the browser goes.
	 */
	submit(key, href, { method = "POST", headers = {}, body, input, json, plain = false }) {
		const source = this.submissionOf(key);
		const entry = { id: ++ids, state: "pending", input, json, status: 0, body: "" };
		// What it sent, to send again (`retry!`).
		entry.request = { href, method, headers, body, plain };
		source.list.push(entry);
		source.cleared = false;
		this.sendSubmission(key, source, entry);
	}

	/** A submission sent (again, for `retry!`): pending until it is answered; in the transition open
	 * now, if any (`create_optimistic!`'s writes, D-054), which ends once its submissions are done. A
	 * result reads again the reads its answer names (`x-rocx-revalidate`: `Router.revalidate!` in
	 * its handler), or every one the page read. */
	sendSubmission(key, source, entry) {
		const { href, method, headers, body, plain = false } = entry.request;
		const input = entry.input;
		const transition = this.transition;
		if (transition) {
			transition.sent = true;
			transition.pending++;
		}
		this.submissionsChanged(source);
		const asked = performance.now();
		const navigations = this.navigations;
		this.notify("submit", { method, url: key, input, id: entry.id });
		const done = (status, said) => {
			Object.assign(entry, { state: "done", status, body: said });
			// Forgotten meanwhile: nothing reads it.
			if (source.list.includes(entry)) this.submissionsChanged(source);
			// The transition's last: its optimistic writes go in this same flush.
			if (transition && --transition.pending === 0) this.endTransition(transition);
		};
		// A form nothing on the page reads goes as the browser would post it, to be answered as a plain
		// form and followed in place (D-118); any other as the runtime's, for its result or refusal.
		const asked_as = plain ? { accept: "text/html,application/xhtml+xml,*/*;q=0.8", "x-rocx-in-place": "1" } : { accept: "application/json", "x-rocx-submission": "1" };
		fetch(href, { method, headers: { ...headers, ...asked_as }, body: method === "GET" || method === "HEAD" ? undefined : body }).then(
			async (response) => {
				const to = response.headers.get("x-rocx-redirect");
				if (to !== null || response.redirected) {
					this.notify("submitted", { url: key, input, id: entry.id, status: response.status, redirect: to ?? response.url, ms: performance.now() - asked });
					// The server's data changed, as with a result (`revalidate`): a page fetched or
					// prefetched before isn't the page now, the one the redirect goes to included.
					this.pages?.clear();
					// In place when it is one of the app's pages (D-040), but not if the visitor went to
					// another page meanwhile: a form sent from one mustn't move them off the next.
					// The submission is done once there, with no result (200, ""): it succeeded, and its
					// transition (`create_optimistic!`'s writes) ends with the new data in, not before. One
					// answered as a plain form (D-118) leaves the browser's list then: the flash the page
					// came back with is what it said.
					const finish = () => {
						done(200, "");
						if (plain) {
							source.list = source.list.filter((each) => each !== entry);
							this.submissionsChanged(source);
						}
					};
					if (this.navigations === navigations) {
						// What the navigation keeps (a layout the two pages share, §4.3; the page itself, when
						// the answer brings it back) reads again what its document answered (D-119); what the
						// document didn't carry it reads from the server then (D-117): every read, or the
						// handler's `Router.revalidate!` keys. A sign-in's redirect so shows the layout signed
						// in. What the navigation makes anew reads from its document anyway.
						const before = new Set(this.readers);
						const keys = Runtime.revalidating(response.headers.get("x-rocx-revalidate"));
						this.refreshed = null;
						Promise.resolve(this.navigate(to !== null ? this.urlOf(to) : new URL(response.url), { refresh: true })).then(() => {
							const rest = new Set([...before].filter((computation) => !this.refreshed?.has(computation)));
							this.revalidate(finish, keys, rest);
						});
					} else finish();
					return;
				}
				const said = await response.text();
				this.notify("submitted", { url: key, input, id: entry.id, status: response.status, body: said, ms: performance.now() - asked });
				if (response.status === 200) this.revalidate(() => done(200, said), Runtime.revalidating(response.headers.get("x-rocx-revalidate")));
				else {
					this.unread(method, key, response.status, said);
					done(response.status, said);
				}
			},
			(error) => {
				const why = `${method} ${key}: ${error?.message ?? error}`;
				this.notify("submitted", { url: key, input, id: entry.id, error: why, ms: performance.now() - asked });
				this.unread(method, key, 0, error?.message ?? String(error));
				done(0, why);
			},
		);
	}

	/** A submission refused, or with no answer, that no component asks for (D-095: a form to one of
	 * the app's endpoints is sent whoever asks): nothing on the page shows it, so the console says so,
	 * in every build, as it says a refusal of what a channel was told. */
	unread(method, key, status, why) {
		if (this.actions.has(key)) return;
		const what = status === 0 ? `had no answer (${why})` : `was refused (${status}: ${why})`;
		console.warn(`rocx: ${method} ${key} ${what}, and nothing on the page reads its submissions: use_submission! or use_submissions! shows it`);
	}

	/** The reads an answer names to read again (`x-rocx-revalidate`: a JSON list of URLs), or null
	 * for every one (no header, or one that isn't such a list). */
	static revalidating(header) {
		if (header === null) return null;
		try {
			const keys = JSON.parse(header);
			return Array.isArray(keys) && keys.every((key) => typeof key === "string") ? keys : null;
		} catch {
			return null;
		}
	}

	/** Sends a submission again (`retry!`, D-054), by its id (0: the latest), with what it sent:
	 * pending again, its answer to come. One on its way, forgotten, or never sent by the runtime (a
	 * plain form's flash), isn't. */
	retrySubmission(key, id) {
		const source = this.submissionOf(key);
		const entry = id === 0 ? (source.cleared ? undefined : source.list.at(-1)) : source.list.find((each) => each.id === id);
		if (!entry?.request || entry.state === "pending") return;
		Object.assign(entry, { state: "pending", status: 0, body: "" });
		this.sendSubmission(key, source, entry);
	}

	/**
	 * Reads the page's reads again (Solid Router revalidating after an action), then `done`: every
	 * computation that read a GET from the server (`read!`, or `send!` of a GET) asks it again, its last
	 * value shown meanwhile, and `done` runs once each has its answer (or failed, or went), in the
	 * run of the last one, so whatever reads both sees the new data and the submission's end
	 * together. With `keys` (`Router.revalidate!`'s, D-054), only the reads of a GET whose URL is
	 * one, or begins with one and a `/` or a `?`; none, `[]`. With `among` (a set of computations),
	 * only those of them still there: what a navigation kept (D-117).
	 */
	revalidate(done, keys = null, among = null) {
		// The server's data changed: a page fetched or prefetched before isn't the page now (D-040 §6.2).
		this.pages?.clear();
		const named = (key) => {
			if (!key.startsWith("GET ")) return false;
			if (keys === null) return true;
			const url = key.slice(4, key.includes("\n") ? key.indexOf("\n") : undefined);
			return keys.some((wanted) => url === wanted || url.startsWith(`${wanted}/`) || url.startsWith(`${wanted}?`));
		};
		const targets = [...this.readers].filter((computation) => !computation.disposed && (among === null || among.has(computation)) && computation.calls !== null && [...computation.calls.keys()].some(named));
		this.notify("revalidate", { reads: targets.length });
		if (!targets.length) return done();
		let left = targets.length;
		const one = () => {
			if (--left === 0) done();
		};
		for (const target of targets) {
			(target.revalidating ??= []).push(one);
			this.refresh(target);
		}
	}

	// ---- Optimistic values (`create_optimistic!`, D-054) ----

	/** A transition for a handler's optimistic writes, open until this task is over, so the form its
	 * submit event sends joins it too: it ends once its submissions are done, or, with none sent, at
	 * once (Solid 2.0 undoes an optimistic write outside a transition). */
	openTransition() {
		const transition = { pending: 0, sent: false, signals: new Set() };
		this.transition = transition;
		queueMicrotask(() => {
			if (this.transition === transition) this.transition = null;
			if (!transition.sent) this.endTransition(transition);
		});
		return transition;
	}

	/** An optimistic write: the signal shows it, held (with its value before any, `base`) until its
	 * transition ends; the latest held shows. */
	hold({ signal, value }, transition) {
		if (!signal || !this.signals.has(signal.id)) return this.ex.release(value);
		signal.held ??= { base: signal.value, writes: [] };
		signal.held.writes.push({ value, transition });
		transition.signals.add(signal);
		signal.value = value;
		for (const observer of signal.observers) this.schedule(observer);
	}

	/** A transition is over: its writes are undone, each signal showing the latest still held, or
	 * its value before them. */
	endTransition(transition) {
		for (const signal of transition.signals) {
			const held = signal.held;
			if (!held || !this.signals.has(signal.id)) continue;
			const kept = [];
			for (const write of held.writes) {
				if (write.transition === transition) this.ex.release(write.value);
				else kept.push(write);
			}
			held.writes = kept;
			signal.value = kept.at(-1)?.value ?? held.base;
			if (!kept.length) signal.held = null;
			for (const observer of signal.observers) this.schedule(observer);
		}
	}

	/** A signal's boxes let go of: its value, or, while optimistic writes are held, each and its
	 * value before them. */
	releaseSignal(signal) {
		if (!signal.held) return this.ex.release(signal.value);
		this.ex.release(signal.held.base);
		for (const write of signal.held.writes) this.ex.release(write.value);
	}

	/** A computation read again for a submission (`revalidate`) has its answer, failed, or went. */
	revalidated(computation) {
		const waiting = computation.revalidating;
		if (!waiting) return;
		computation.revalidating = null;
		for (const one of waiting) one();
	}

	/** A read in a computation: it runs again when what it read changes; inside `untrack!`, it
	 * doesn't. A dev build says where a component's body reads one, once a place (`warnRead`). */
	track(source) {
		const reader = this.current;
		if (!reader?.making || reader.making.untracked > 0) return;
		addSource(reader.making, source);
		if (this.place && reader.kind === "component" && !this.onServer) this.warnRead(this.place);
	}

	/** What the running computation did makes it live (`inert`): it read or made something that
	 * changes. A read inside `untrack!` doesn't (`read`). */
	touch(read = false) {
		const making = this.current?.making;
		if (making && !(read && making.untracked > 0)) making.live = true;
	}

	/**
	 * A dev build (`rocx build --dev`, `rocx dev`) wraps each accessor a component's body calls
	 * (`label!()`, `count!()`) in `Html.read_at!`, which says where it is (`place`, the `.rocx` file's
	 * line and column) while it runs. A read there that tracks is one the component makes once, as it
	 * runs: what it shows won't follow it. Said once a place, as Solid 2.0's dev build says
	 * STRICT_READ_UNTRACKED; `untrack!` says the one read is meant, and silences it.
	 */
	warnRead(place) {
		if (this.warned.has(place)) return;
		this.warned.add(place);
		this.notify("warn", { place });
		console.warn(`rocx: ${place} reads a value that changes (a signal, a memo or a prop) in a component's body, once, as the component runs: what it shows won't follow it. Read it where it is used (in markup, a memo, an effect's compute or a handler), or, if one read is what you want, say so: untrack!(|| …)`);
	}

	/** In a handler, applied when it is done; elsewhere, now. */
	later(write) {
		if (this.current?.kind === "handler") this.current.writes.push(write);
		else this.apply([write]);
	}

	/** Where the page is (`Router.location!`): rendering as a server would, the request's path and
	 * query; in the browser, the location the page on screen was rendered for (`committed`), else
	 * `location.pathname` without the site's base, and `location.search`. A trailing slash is
	 * dropped. So the browser sees what the server does. */
	location() {
		if (this.onServer) return Runtime.target(/^\S+ (\S*)/.exec(this.request)?.[1] ?? "/");
		return this.committed ?? this.here();
	}

	/** Where the browser is now, as `Router.location!` says it: `location`'s path without the base,
	 * and its query. */
	here() {
		return Runtime.target(typeof location === "undefined" ? "/" : `${this.unbased(location.pathname)}${location.search}`);
	}

	/** A path and query as `Router.location!` gives it: a trailing slash dropped, no hash. */
	static target(target) {
		const [path, query] = target.split("#")[0].split(/\?(.*)/s);
		const trimmed = path.length > 1 ? path.replace(/\/+$/, "") || "/" : path || "/";
		return query === undefined ? trimmed : `${trimmed}?${query}`;
	}

	/** Commits where the page is (a navigation's, D-040): what read the location runs again. */
	commitLocation(target) {
		if (this.committed === target) return;
		this.committed = target;
		for (const observer of this.locationSource.observers) this.schedule(observer);
		this.markLinks();
	}

	/**
	 * Whether a link to `href` (an app's own path, `/…`, as the markup writes it) is where the page is,
	 * `"page"` (its path, and its query if it has one, the page's), above it, `"true"` (a path the
	 * page is under, never `/`), or neither, `null`: its `aria-current` (D-086), as signals.rs's
	 * `current` says it. `<A>`'s active state, on every link.
	 */
	linkMark(href) {
		if (typeof href !== "string" || !href.startsWith("/") || href.startsWith("//")) return null;
		const [path, query = ""] = Runtime.target(href).split(/\?(.*)/s);
		const [here, asked = ""] = this.location().split(/\?(.*)/s);
		if (path === here) return !query || query === asked ? "page" : null;
		return !query && path !== "/" && here.startsWith(`${path}/`) ? "true" : null;
	}

	/** A link the runtime made or adopted, with no `aria-current` of its own: marked as the page is
	 * now (`linkMark`), and kept, to be marked again as the page moves (`markLinks`). Its mark is its
	 * last attribute, as the server writes it. */
	markLink(element) {
		this.links.add(element);
		const href = element.getAttribute("href");
		const mark = href === null ? null : this.linkMark(this.unbased(href));
		const was = element.getAttribute("aria-current");
		if (mark === was) return;
		element.removeAttribute("aria-current");
		if (mark) element.setAttribute("aria-current", mark);
	}

	/** Every link the runtime marks, marked again: the page moved (a navigation in place, D-040). */
	markLinks() {
		for (const link of this.page?.querySelectorAll?.("a[href]") ?? []) if (this.links.has(link)) this.markLink(link);
	}

	/** Says whether a navigation in place is on its way (`Router.is_routing!`). */
	setRouting(on) {
		if (this.routing.on === on) return;
		this.routing.on = on;
		for (const observer of this.routing.observers) this.schedule(observer);
	}

	// ---- The app's pages (D-040) ----

	/** The route table rocx build wrote (`Router.app!`'s `routes`, JSON): its pages, each with its
	 * path's segments (a `[param]` one `null`) and its levels' code, root layout first; the error
	 * page's code. */
	static routeTable(routes) {
		const table = JSON.parse(routes);
		const parts = (path) => path.split("/").filter(Boolean).map((part) => (/^\[.+\]$/.test(part) ? null : part));
		const pages = (table.pages ?? []).map((page) => ({ ...page, parts: parts(page.path) }));
		// The app's endpoints that take a POST (D-095), whose forms the runtime sends with fetch.
		const posts = (table.posts ?? []).map((path) => ({ path, parts: parts(path) }));
		return { pages, error: table.error ?? null, posts };
	}

	/** The segments of a path (without the base, no query), decoded; null for one that can't be. */
	static segmentsOf(path) {
		try {
			return path.split("/").filter(Boolean).map(decodeURIComponent);
		} catch {
			return null;
		}
	}

	/** Whether a route's parts (a fixed part, or null for a `[param]`, any one segment) match a path's segments. */
	static matched(parts, segments) {
		return parts.length === segments.length && parts.every((part, at) => part === null || part === segments[at]);
	}

	/** Whether one of the app's endpoints takes a POST at `path` (without the base, no query), as the
	 * route table says (D-095); false with no table. */
	postOf(path) {
		const segments = Runtime.segmentsOf(path);
		return segments !== null && (this.app?.posts ?? []).some((post) => Runtime.matched(post.parts, segments));
	}

	/** The app's page at `path` (without the base, no query), as `Root` matches it, segment by
	 * segment, in the table's order (a `[param]` any one segment): `{ page, params }`, the params
	 * by name, decoded; null where the app has no page (or no table). */
	routeOf(path) {
		if (!this.app) return null;
		const segments = Runtime.segmentsOf(path);
		if (segments === null) return null;
		for (const page of this.app.pages) {
			if (!Runtime.matched(page.parts, segments)) continue;
			const params = {};
			page.path
				.split("/")
				.filter(Boolean)
				.forEach((part, at) => {
					if (page.parts[at] === null) params[part.slice(1, -1)] = segments[at];
				});
			return { page, params };
		}
		return null;
	}

	/**
	 * A level's code (D-040 §18: `{ code, path }`, one of a route table page's `levels`), reached:
	 * the one step a navigation takes to have what renders a level. Every level's code is in the
	 * one wasm today, so it is there at once; with wasm splitting it would load the level's chunks
	 * (named by `code`, under the build's id), the render waiting on them as it waits on the page's
	 * document.
	 */
	pageCode(level) {
		return REACHED;
	}

	/** The levels' code a page needs (its route's), reached: what a navigation waits on beside the
	 * page's document. */
	codeOf(route) {
		return Promise.all((route?.page.levels ?? []).map((level) => this.pageCode(level)));
	}

	/** The URL `to` names (`Router.navigate!`'s, a link's): a path under the site's base, a query
	 * or a hash alone on this page, or another site's. */
	urlOf(to) {
		return new URL(to.startsWith("/") && !to.startsWith("//") ? this.under(to) : to, location.href);
	}

	// ---- Navigating in place (D-040) ----

	/**
	 * Listens for what navigates (once, as the app starts): clicks on the document (a link to one
	 * of the app's pages, `clicked`), back and forward (`popstate`), and the page going (its scroll
	 * kept, for a reload). The history entry the page is on gets a key, the scroll is the runtime's
	 * (`scrollRestoration` manual), and a reload's is put back.
	 */
	listenForNavigation() {
		if (this.navigating || !this.app || typeof window === "undefined" || this.page !== document) return;
		this.navigating = true;
		/** The navigation on its way: `{ id, url, controller }`; how many were committed (a
		 * submission's redirect is followed only if none was since it was sent). */
		this.navigation = null;
		this.navigations = 0;
		/** What the pages navigated to or prefetched lately need (`Runtime.CACHE` of them, by URL, each
		 * used for `FRESH` ms): `{ at, promise }`, the promise their document's (`pageFor`). */
		this.pages = new Map();
		// Each entry's key, and its index (how far it is from the first the runtime saw: back and
		// forward's `delta`, so a leave stopped can be undone, `popped`).
		const state = history.state;
		this.entryKey = state?.rocx?.key ?? Runtime.entryKey();
		this.entryIndex = state?.rocx?.index ?? 0;
		if (state?.rocx?.key !== this.entryKey || state?.rocx?.index !== this.entryIndex) history.replaceState({ ...(state && typeof state === "object" ? state : {}), rocx: { key: this.entryKey, index: this.entryIndex } }, "");
		if ("scrollRestoration" in history) history.scrollRestoration = "manual";
		const kept = this.scrollOf(this.entryKey);
		if (kept && !location.hash) window.scrollTo(kept.x, kept.y);
		document.addEventListener("click", (event) => this.clicked(event));
		// Prefetch (D-040 §11): a link the pointer rests on, one focused, one touched; and, where asked
		// for, one that comes into sight (`watchSight`).
		document.addEventListener("pointerover", (event) => this.hovered(event));
		document.addEventListener("pointerout", (event) => this.unhovered(event));
		// Focus by the keyboard: a click focuses its link too, on the way to navigating.
		document.addEventListener("focusin", (event) => event.target?.matches?.(":focus-visible") && this.prefetchLink(this.linkOf(event.target)));
		document.addEventListener("touchstart", (event) => this.prefetchLink(this.linkOf(event.target)), { passive: true });
		this.watchSight();
		// A GET form to one of the app's pages (phase 2's `gotForm`).
		document.addEventListener("submit", (event) => this.gotForm?.(event));
		window.addEventListener("popstate", (event) => this.popped(event));
		window.addEventListener("pagehide", () => this.keepScroll());
	}

	/** A fresh key for a history entry. */
	static entryKey() {
		return Math.random().toString(36).slice(2, 10);
	}

	/** Where an entry was scrolled to, kept by its key (`keepScroll`), if it was. */
	scrollOf(key) {
		try {
			const kept = sessionStorage.getItem(`rocx:scroll:${key}`);
			return kept ? JSON.parse(kept) : null;
		} catch {
			return null;
		}
	}

	/** Keeps where the page is scrolled to, by the key of the entry it is on. */
	keepScroll() {
		try {
			sessionStorage.setItem(`rocx:scroll:${this.entryKey}`, JSON.stringify({ x: window.scrollX, y: window.scrollY }));
		} catch {}
	}

	/**
	 * A click on the document: navigates in place when it is the main button with no modifier key,
	 * no handler prevented it, on an `<a>` (an SVG one too) with an `href`, no `download`, no `rel`
	 * with `external`, no `target` but `_self`, to this origin under the site's base, at a path the
	 * app has a page for, and not to a place on this page (only the hash differing: the browser
	 * scrolls there). `<html data-rocx-navigation="off">` turns it off; `"explicit"`, for a link
	 * without `data-rocx-link`. A link's `replace` replaces the entry; `noscroll` keeps the scroll.
	 */
	clicked(event) {
		if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
		const link = this.linkOf(event.target);
		if (!link) return;
		event.preventDefault();
		this.navigate(link.url, { replace: link.anchor.hasAttribute("replace"), scroll: !link.anchor.hasAttribute("noscroll") });
	}

	/** The link `node` is in, if it navigates in place (`{ anchor, url }`): an `<a>` (or an SVG `<a>`)
	 * with an `href`, no `download`, no `rel` with `external`, no `target` but `_self`, to one of the
	 * app's pages (`ours`) and not to a place on this page, navigation in place not turned off
	 * (`data-rocx-navigation`: `off`; `explicit`, but for an `<a data-rocx-link>`). */
	linkOf(node) {
		const anchor = node?.closest?.("a");
		if (!anchor) return null;
		const href = anchor.getAttribute("href") ?? anchor.getAttribute("xlink:href");
		if (href === null || anchor.hasAttribute("download")) return null;
		if (/(^|\s)external(\s|$)/i.test(anchor.getAttribute("rel") ?? "")) return null;
		const target = anchor.getAttribute("target");
		if (target && target !== "_self") return null;
		const mode = document.documentElement.getAttribute("data-rocx-navigation");
		if (mode === "off" || (mode === "explicit" && !anchor.hasAttribute("data-rocx-link"))) return null;
		const url = new URL(href, document.baseURI);
		if (!this.ours(url) || Runtime.samePage(url)) return null;
		return { anchor, url };
	}

	// ---- Prefetch (D-040 §11) ----

	/** How a link prefetches: the nearest `data-rocx-preload` on it or above it (`<html>`'s, for the
	 * app), `hover` (on hover, focus and touch) when there is none; `off`, never; `viewport`, as it
	 * comes into sight too. */
	static preloadOf(anchor) {
		return anchor.closest("[data-rocx-preload]")?.getAttribute("data-rocx-preload") || "hover";
	}

	/** The pointer came over a link: prefetched once it has rested there 65 ms. */
	hovered(event) {
		const link = this.linkOf(event.target);
		if (this.hovering?.anchor === link?.anchor) return;
		clearTimeout(this.hovering?.timer);
		this.hovering = link && { anchor: link.anchor, timer: setTimeout(() => this.prefetchLink(link), Runtime.REST) };
	}

	/** The pointer left the link it rested on, before it was prefetched. */
	unhovered(event) {
		const anchor = this.hovering?.anchor;
		if (!anchor || anchor.contains(event.relatedTarget)) return;
		clearTimeout(this.hovering.timer);
		this.hovering = null;
	}

	/** A link's page, prefetched, unless it says not to be (`data-rocx-preload="off"`). */
	prefetchLink(link) {
		if (link && Runtime.preloadOf(link.anchor) !== "off") this.prefetch(link.url);
	}

	/**
	 * What the page at `url` needs, fetched ahead of a navigation to it (D-040 §11 and §18): its
	 * document (`x-rocx-navigate: preload`, at a low priority) and its levels' code, as one entry of
	 * the cache a navigation takes it from (`pageFor`), with one age. One already there and fresh,
	 * or on its way, isn't asked again; the page the browser is on isn't. Quietly: one that fails,
	 * or that isn't of this build, is dropped.
	 */
	prefetch(url) {
		if (!this.navigating || !this.ours(url) || Runtime.documentKey(url) === Runtime.documentKey(new URL(location.href))) return;
		const key = Runtime.documentKey(url);
		const promise = this.pageFor(url, { preload: true });
		const entry = this.pages.get(key);
		promise.then(
			(fetched) => {
				if (!fetched.text.includes(`data-build="${this.app.build}"`) && this.pages.get(key) === entry) this.pages.delete(key);
			},
			() => {},
		);
	}

	/**
	 * Links that prefetch as they come into sight (`data-rocx-preload="viewport"` on them or above
	 * them), watched: as the app starts and after each navigation, and those a page adds later. With
	 * none on the page, nothing watches.
	 */
	watchSight() {
		this.sight?.disconnect();
		this.added?.disconnect();
		if (typeof IntersectionObserver === "undefined" || !document.querySelector('[data-rocx-preload="viewport"]')) return;
		this.sight ??= new IntersectionObserver((entries) => {
			for (const entry of entries) {
				if (!entry.isIntersecting) continue;
				this.sight.unobserve(entry.target);
				this.prefetchLink(this.linkOf(entry.target));
			}
		});
		const watch = (root) => {
			const anchors = root.localName === "a" ? [root] : [...(root.querySelectorAll?.("a[href]") ?? [])];
			for (const anchor of anchors) if (Runtime.preloadOf(anchor) === "viewport") this.sight.observe(anchor);
		};
		watch(document.documentElement);
		this.added ??= new MutationObserver((records) => {
			for (const record of records) for (const node of record.addedNodes) if (node.nodeType === 1) watch(node);
		});
		this.added.observe(document.body, { childList: true, subtree: true });
	}

	// ---- View Transitions (D-040 §5.3) ----

	/** Whether a navigation's change of page is a View Transition: the app asked for them
	 * (`<html data-rocx-transitions>`), the browser has them, and less motion isn't asked for. */
	transitionsWanted() {
		return typeof document.startViewTransition === "function" && document.documentElement.hasAttribute("data-rocx-transitions") && !reducedMotion();
	}

	/** Whether `url` is a place on the page the browser is on: the same path and query, and a hash
	 * (`#below`, or `#` alone), which the browser scrolls to itself. */
	static samePage(url) {
		return url.href.includes("#") && url.origin === location.origin && url.pathname === location.pathname && url.search === location.search;
	}

	/** Whether `url` is one of the app's pages: this origin's, under the site's base, at a path the
	 * route table has a page for. */
	ours(url) {
		if (url.origin !== location.origin) return false;
		const base = this.base.slice(0, -1);
		if (base && url.pathname !== base && !url.pathname.startsWith(this.base)) return false;
		return this.routeOf(this.unbased(url.pathname)) !== null;
	}

	/**
	 * Back or forward: the entry's page, rendered as a click's is, without pushing an entry. A
	 * change of the hash alone is the browser's. The address has changed already, so the page's
	 * leave listeners (`mayLeave`) are asked now, with how far it went (`delta`, from the entries'
	 * indexes); one that stops it has the browser go back the other way (`restoring`), as Solid
	 * Router does, the page never having changed. Not asked: one a retry forces (`forcing`), and one
	 * to an entry the runtime didn't make, whose distance it doesn't know.
	 */
	popped(event) {
		if (this.restoring) {
			this.restoring = false;
			return;
		}
		const forced = this.forcing;
		this.forcing = false;
		const key = event.state?.rocx?.key ?? null;
		const index = event.state?.rocx?.index;
		if (this.here() === this.committed && !this.navigation) {
			if (key) {
				this.entryKey = key;
				if (typeof index === "number") this.entryIndex = index;
			} else {
				// The browser's own entry for a place on the page, after the one it was on.
				this.entryIndex++;
				history.replaceState({ ...(event.state ?? {}), rocx: { key: this.entryKey, index: this.entryIndex } }, "");
			}
			return;
		}
		const url = new URL(location.href);
		const delta = typeof index === "number" ? index - this.entryIndex : 0;
		if (delta && !forced && !this.mayLeave(url, { delta })) {
			this.restoring = true;
			history.go(-delta);
			return;
		}
		if (typeof index === "number") this.entryIndex = index;
		this.keepScroll();
		this.navigate(url, { pop: key ?? Runtime.entryKey(), asked: true });
	}

	/** The browser loads `url`: another site's, a page that isn't the app's, a document the runtime
	 * can't render. Back or forward (`pop`), the address is already there: loaded again. `asked`:
	 * the page's leave listeners let it go, so the browser's prompt doesn't ask again. */
	load(url, { replace = false, pop = null, asked = false } = {}) {
		if (asked) this.loadAsked = performance.now();
		if (pop) location.reload();
		else if (replace) location.replace(url.href ?? url);
		else location.assign(url.href ?? url);
	}

	// ---- Leaving the page (D-040: Solid Router's `useBeforeLeave`) ----

	/**
	 * Whether the page may be left for `url`, a navigation in place: each listener a component
	 * registered (`Router.use_before_leave!`) is run as a handler, in the order they came, given the
	 * leave (`leaveEvent`), and may stop it (`Leave.prevent!`). They are all asked, each told whether
	 * one before stopped it. The leave is kept a while (`LEAVES`), so a handler can let it go later
	 * (`Leave.retry!`, `retryLeave`). A listener that waits for the server isn't run again: the
	 * navigation is decided now. With no listener, it may.
	 */
	mayLeave(url, { replace = false, scroll = true, delta = 0 } = {}) {
		if (!this.leaveListeners.size) return true;
		const leave = { id: ++ids, to: Runtime.target(`${this.unbased(url.pathname)}${url.search}`), url, replace, scroll, delta, key: this.entryKey, index: this.entryIndex, prevented: false };
		this.leaves.set(leave.id, leave);
		while (this.leaves.size > Runtime.LEAVES) this.leaves.delete(this.leaves.keys().next().value);
		const outer = this.leaveAsked;
		this.leaveAsked = leave;
		try {
			for (const listener of [...this.leaveListeners]) {
				if (listener.disposed) continue;
				this.handle(listener.runner, this.leaveEvent(leave), listener.scope, { owner: listener.owner, again: false });
			}
		} finally {
			this.leaveAsked = outer;
		}
		this.notify("leave", { to: leave.to, delta, prevented: leave.prevented });
		return !leave.prevented;
	}

	/** A leave as Roc reads it (`Leave.of`), a line each: its id, where it goes, the path and the query
	 * it leaves (`Router.location!`'s), replace and scroll, back and forward's delta, and whether a
	 * listener before stopped it. */
	leaveEvent(leave) {
		const [path, query = ""] = this.location().split(/\?(.*)/s);
		return [leave.id, leave.to, path, query, leave.replace ? 1 : 0, leave.scroll ? 1 : 0, leave.delta, leave.prevented ? 1 : 0].join("\n");
	}

	/**
	 * A listener asked ahead of a load (leaving the site, reloading, closing the tab: the page can't
	 * hold one, the browser asks): run as a handler is, given a leave with id 0 and `to` "", what it
	 * writes dropped (a dialog it would open, a retry), what it reads tracked, so it is asked again
	 * when that changes (a draft typed into, saved). While one would stop a load, the browser's
	 * prompt is armed (`guardUnload`). One that waits for the server, or fails, wouldn't.
	 */
	probeLeave(listener) {
		const making = making_();
		const probe = {
			kind: "handler",
			leaveProbe: true,
			prevented: false,
			runner: listener.runner,
			calls: new Map(),
			writes: [],
			own: 0,
			event: this.leaveEvent({ id: 0, to: "", replace: false, scroll: true, delta: 0, prevented: false }),
			scope: listener.scope,
			owner: listener.owner,
			making,
			adopt: (child) => own(making, "children").push(child),
		};
		const previous = this.current;
		this.current = probe;
		let ok = true;
		try {
			this.enter(() => this.ex.run(this.kept.get(listener.runner)));
		} catch (error) {
			if (!(error instanceof NotReady || error instanceof Failed)) throw error;
			ok = false;
			this.reclaim(error);
		} finally {
			this.current = previous;
		}
		for (const write of probe.writes) {
			if (write.signal) this.ex.release(write.value);
			else if (write.optimistic) this.ex.release(write.optimistic.value);
		}
		for (const source of listener.sources) source.observers?.delete(listener);
		listener.sources = making.sources;
		for (const source of listener.sources) (source.observers ??= new Set()).add(listener);
		// A cleanup it registered would run as a handler, its writes applied: let go of instead.
		making.cleanups = making.cleanups.filter((cleanup) => typeof cleanup === "function" || (this.releaseKept(cleanup), false));
		this.drop(making);
		listener.prevents = ok && probe.prevented;
		this.guardUnload();
		return "ok";
	}

	/**
	 * A leave let go after all (`Leave.retry!`), once the handler that said so is done and the
	 * navigation it stopped has been decided: navigated to again, its listeners asked again unless
	 * `force` (Solid Router's `retry(force)`). Back and forward go there again in history (`history.go`
	 * of its delta) while the page is on the entry it was left from; else, and for the others, a
	 * navigation to its URL, with its options.
	 */
	retryLeave(id, force) {
		const leave = this.leaves.get(id);
		if (!leave) return;
		queueMicrotask(() => {
			if (leave.delta && this.entryKey === leave.key && this.entryIndex === leave.index) {
				this.forcing = force;
				history.go(leave.delta);
			} else this.navigate(leave.url, { replace: leave.replace, scroll: leave.scroll, force });
		});
	}

	/**
	 * The browser's prompt before a load (`beforeunload`, its own words): listened for while a leave
	 * listener would stop one (`probeLeave`), and only then, since a page that listens for it may be
	 * kept out of the browser's back-forward cache. A load the runtime starts once the listeners let
	 * a navigation go (`load`'s `asked`) isn't asked again.
	 */
	guardUnload() {
		if (typeof window === "undefined") return;
		let wanted = false;
		for (const listener of this.leaveListeners) if (listener.prevents) wanted = true;
		if (wanted === (this.unloadGuard !== null)) return;
		if (wanted) {
			this.unloadGuard = (event) => {
				if (performance.now() - this.loadAsked < Runtime.ASKED) return;
				event.preventDefault();
				event.returnValue = "";
			};
			window.addEventListener("beforeunload", this.unloadGuard);
		} else {
			window.removeEventListener("beforeunload", this.unloadGuard);
			this.unloadGuard = null;
		}
	}

	/**
	 * Navigates to `to` (a link's URL, `Router.navigate!`'s, back and forward's): one of the app's
	 * pages is rendered in place, from its document, fetched (`pageFor`: as the server answers a
	 * load, behind its middleware, a redirect followed), the old page staying until it is in
	 * (`is_routing!`), and the address pushed (or replaced, or, back and forward, left); anything
	 * else the browser loads. A newer navigation overtakes one on its way (its fetch aborted).
	 * `rocx:navigate` is dispatched on the document as it starts, `rocx:navigated` once the page is
	 * on screen, each with `{ url }` (and `ms`, the time it took). The page's leave listeners are
	 * asked first (`mayLeave`), and may stop it, unless `force` (a retry's) or `asked` (back and
	 * forward's, in `popped`); a load is the browser's, which asks with its own prompt while one
	 * would stop it (`guardUnload`).
	 */
	async navigate(to, { replace = false, scroll = true, pop = null, force = false, asked = false, refresh = false } = {}) {
		const url = to instanceof URL ? to : this.urlOf(to);
		if (!this.navigating || !this.ours(url)) return this.load(url, { replace, pop, asked });
		if (!pop && Runtime.samePage(url)) return this.load(url, { replace });
		if (!force && !asked && !this.mayLeave(url, { replace, scroll })) return;
		// The page it is on, again: its entry replaced, as a browser loading the same URL does.
		if (!pop && url.href === location.href) replace = true;
		if (this.inPlace?.(url, { replace, scroll, pop })) return;
		const started = performance.now();
		// Where the page is scrolled to as the visitor leaves it (before the progress a navigation
		// shows can move it: scroll anchoring).
		if (!pop) this.keepScroll();
		// The one on its way is overtaken: its fetch aborted (and forgotten) if it was its own and for
		// another page; one for this page goes on, and this one waits for it.
		const previous = this.navigation;
		if (previous && Runtime.documentKey(previous.url) !== Runtime.documentKey(url)) {
			previous.controller.abort();
			const key = Runtime.documentKey(previous.url);
			if (this.pages.get(key)?.signal === previous.controller.signal) this.pages.delete(key);
		}
		const navigation = (this.navigation = { id: ++ids, url, controller: new AbortController() });
		this.setRouting(true);
		this.notify("navigate", { url: url.href });
		document.dispatchEvent(new CustomEvent("rocx:navigate", { detail: { url: url.href } }));
		let fetched;
		try {
			fetched = await this.pageFor(url, { signal: navigation.controller.signal });
		} catch (error) {
			if (this.navigation !== navigation) return;
			this.navigation = null;
			// Offline, the server down, or a redirect to another site (refused by CORS): the browser's.
			return this.load(url, { replace, pop, asked: true });
		}
		if (this.navigation !== navigation) return;
		// Where it ended: a redirect's address, but one that only adds the trailing slash (a static
		// host's) is the link's page.
		let at = url;
		if (fetched.redirected) {
			const ended = new URL(fetched.url);
			ended.hash = url.hash;
			if (!(ended.origin === url.origin && ended.pathname === `${url.pathname}/` && ended.search === url.search)) at = ended;
		}
		const doc = this.appDocument(fetched);
		if (!doc || (at !== url && !this.ours(at))) {
			this.navigation = null;
			this.pages.delete(Runtime.documentKey(url));
			return this.load(at, { replace, pop, asked: true });
		}
		// A submission's answer bringing back the page it is on (D-119): kept where it is, its scroll,
		// focus and nothing announced, as its reads and the flash follow the document.
		const stays = refresh && Runtime.documentKey(at) === Runtime.documentKey(new URL(location.href));
		if (pop) this.entryKey = pop;
		else {
			this.entryKey = Runtime.entryKey();
			if (!replace) this.entryIndex++;
			history[replace ? "replaceState" : "pushState"]({ rocx: { key: this.entryKey, index: this.entryIndex } }, "", at.href);
		}
		if (pop && history.state?.rocx?.key !== pop) history.replaceState({ ...(history.state ?? {}), rocx: { key: pop, index: this.entryIndex } }, "");
		this.navigation = null;
		this.navigations++;
		try {
			const show = () => {
				this.commit(doc, Runtime.target(`${this.unbased(at.pathname)}${at.search}`), { refresh });
				this.afterNavigate?.(doc);
				if (!stays) this.scrolled(at, { pop, scroll });
			};
			// A View Transition, where the app asked for one (§5.3): the browser snapshots the old page,
			// the flush makes the new one (scrolled where it goes), and it cross-fades.
			if (this.transitionsWanted()) {
				this.notify("transition", { url: at.href });
				const transition = document.startViewTransition(show);
				// A navigation that comes before this one's animation is ready (a second click, a
				// navigate! as the page arrives) skips it, rejecting `ready` with an AbortError: the
				// page is the next one's then, and nothing is wrong. `finished` rejects as the update
				// does, which the await below hears.
				transition.ready.catch(() => {});
				transition.finished.catch(() => {});
				await transition.updateCallbackDone;
			} else show();
			if (!stays) {
				this.focused(at);
				this.announce(at);
			}
			this.watchSight();
			const ms = performance.now() - started;
			this.notify("navigated", { url: at.href, ms });
			document.dispatchEvent(new CustomEvent("rocx:navigated", { detail: { url: at.href, ms } }));
		} finally {
			// The effects' applies, held while the page was made, run once the page is as it will stay,
			// as a load's run after it hydrated (and after `rocx:ready`).
			this.holdingEffects = false;
			this.wake();
		}
	}

	/** A document's key in the cache: its URL without the hash. */
	static documentKey(url) {
		return url.href.split("#")[0];
	}

	/**
	 * What the page at `url` needs (D-040 §18: a page, not a document), one entry of the cache with
	 * one age: its document, as the server answers a load (`accept: text/html`, and
	 * `x-rocx-navigate: 1`, or `preload` for a prefetch, so a middleware can tell them from a load),
	 * and its levels' code (`codeOf`, at once while the wasm holds every page). Its promise is the
	 * document's: `{ status, url, redirected, type, text }`. One complete at most `FRESH` ms ago is
	 * used again (back and forward in a hurry, a click on a link prefetched, ask nothing), and one
	 * on its way is waited for; the last `CACHE` are kept, and a revalidation empties them. A
	 * failure (offline, a redirect to another site) throws, and isn't kept.
	 */
	pageFor(url, { signal = undefined, preload = false } = {}) {
		const key = Runtime.documentKey(url);
		const cached = this.pages.get(key);
		if (cached && (cached.at === null || performance.now() - cached.at <= Runtime.FRESH)) return cached.promise;
		const entry = { at: null, promise: null, signal };
		const asked = performance.now();
		this.notify("fetch", { method: "GET", url: key, body: "", preload });
		const document = fetch(key, { headers: { accept: "text/html", "x-rocx-navigate": preload ? "preload" : "1" }, signal, credentials: "same-origin", priority: preload ? "low" : "auto" }).then(async (response) => {
			const text = await response.text();
			this.notify("fetched", { method: "GET", url: key, status: response.status, body: "", ms: performance.now() - asked, preload });
			return { status: response.status, url: response.url, redirected: response.redirected, type: response.headers.get("content-type") ?? "", text };
		});
		entry.promise = Promise.all([document, this.codeOf(this.routeOf(this.unbased(url.pathname)))]).then(
			([fetched]) => {
				entry.at = performance.now();
				return fetched;
			},
			(error) => {
				if (this.pages.get(key) === entry) this.pages.delete(key);
				throw error;
			},
		);
		this.pages.delete(key);
		this.pages.set(key, entry);
		while (this.pages.size > Runtime.CACHE) this.pages.delete(this.pages.keys().next().value);
		return entry.promise;
	}

	/** The fetched page as a document the runtime renders: an app document (HTML, with the app's
	 * bootstrap) of this build (`data-build`, D-040 §10.3); else null, and the browser loads it.
	 * Read with `DOMParser`: no script in it runs. */
	appDocument(fetched) {
		if (!/^text\/html\b/i.test(fetched.type)) return null;
		const doc = new DOMParser().parseFromString(fetched.text, "text/html");
		const start = [...doc.querySelectorAll("script[data-rocx][src]")].find((script) => /(^|\/)rocx\/start\.js$/.test(script.getAttribute("src")));
		if (!start || start.getAttribute("data-build") !== this.app.build) return null;
		return doc;
	}

	/**
	 * A fetched document made the page: its answers and flash seeded, the location committed, and
	 * the root run again in one flush, the document rendered anew from them (`settleDocument`):
	 * `<head>` reconciled with the document's, `<body>` made anew with the document's
	 * `<NoHydration>` regions, `<html>`'s and `<body>`'s attributes the document's. Nothing is asked
	 * of the server; strictly (the tests'), asking throws. The effects' applies wait (`navigate`).
	 */
	commit(doc, target, { refresh = false } = {}) {
		const flashBefore = this.flash;
		// What the page read from the server before (the levels it keeps among them).
		const before = [...this.readers];
		this.flash = "";
		this.seed(doc);
		this.refreshing = refresh;
		const hydrating = (this.hydrating = { asked: [] });
		this.arriving = doc;
		this.holdingEffects = true;
		this.setRouting(false);
		try {
			if (this.committed === target) for (const observer of this.locationSource.observers) this.schedule(observer);
			this.commitLocation(target);
			// Phase 1 makes the whole document anew; phase 2's levels may keep the root (`remakeRoot`).
			if (this.root && (this.remakeRoot?.(target) ?? true)) this.schedule(this.root);
			this.flush();
			// What the navigation kept reads again what its document answered otherwise (D-119): no
			// request, and kept layouts follow the server's data on every navigation.
			this.refreshKept(before, flashBefore);
		} finally {
			this.refreshing = false;
			this.arriving = null;
			this.hydrating = null;
			this.answers.clear();
		}
		if (this.strict && hydrating.asked.length) throw new Error(`rocx: navigating to ${target}, the page asked the server again for ${hydrating.asked.join(", ")}: its document didn't carry it`);
	}

	/**
	 * After a navigation's flush, the computations it kept (a layout both pages have, the page when it
	 * is the same one again: D-119) read again what the document's answers say otherwise: each whose
	 * reads of the server the document answered every one of, one of them now differently, runs again,
	 * reading them from those answers (asked of no one). What reads the flash runs again if the
	 * document brought another. Those it read again, or found the same, are `refreshed`: a
	 * submission's redirect (`sendSubmission`) asks the server for the rest (D-117).
	 */
	refreshKept(before, flashBefore) {
		const refreshed = new Set();
		let again = false;
		for (const computation of before) {
			if (computation.disposed || !computation.calls) continue;
			const reads = [...computation.calls.keys()].filter((key) => key.startsWith("GET "));
			if (!reads.length || !reads.every((key) => this.answers.has(key))) continue;
			refreshed.add(computation);
			if (reads.every((key) => computation.calls.get(key)?.value === this.answers.get(key))) continue;
			for (const key of reads) computation.calls.delete(key);
			this.schedule(computation);
			again = true;
		}
		for (const reader of this.flashReaders) {
			if (reader.disposed) this.flashReaders.delete(reader);
			else if (this.flash !== flashBefore) {
				this.schedule(reader);
				again = true;
			}
		}
		this.refreshed = refreshed;
		if (again) this.flush();
	}

	/** After a navigation: back and forward, the scroll the entry had; else, unless told not to, the
	 * top, or the element the hash names. */
	scrolled(url, { pop, scroll }) {
		if (pop) {
			const kept = this.scrollOf(pop);
			window.scrollTo(kept?.x ?? 0, kept?.y ?? 0);
			return;
		}
		if (!scroll) return;
		const hash = url.hash ? decodeURIComponent(url.hash.slice(1)) : "";
		const target = hash ? (document.getElementById(hash) ?? document.getElementsByName(hash)[0]) : null;
		if (target) target.scrollIntoView();
		else window.scrollTo(0, 0);
	}

	/** After a navigation, the focus where a load puts it: an `autofocus` element of the new page's,
	 * the hash's target if it can be focused, or the start of `<body>`, so the next Tab reaches the
	 * page's skip link. */
	focused(url) {
		const auto = document.body?.querySelector("[autofocus]");
		if (auto) return auto.focus();
		const hash = url.hash ? decodeURIComponent(url.hash.slice(1)) : "";
		const target = hash ? document.getElementById(hash) : null;
		if (target && target.tabIndex >= 0) return target.focus({ preventScroll: true });
		const body = document.body;
		if (!body) return;
		const tabindex = body.getAttribute("tabindex");
		body.tabIndex = -1;
		body.focus({ preventScroll: true });
		if (tabindex === null) body.removeAttribute("tabindex");
		else body.setAttribute("tabindex", tabindex);
		// The next Tab starts from the top of the page, not from where the link was.
		const selection = getSelection();
		if (selection && selection.type !== "Range") selection.removeAllRanges();
	}

	/** Says the new page to a screen reader, which can't see a navigation in place: its title (or
	 * its path), in a live region of the host's at the end of `<body>`, hidden by its style. */
	announce(url) {
		let announcer = this.announcer;
		if (!announcer?.isConnected) {
			announcer = this.announcer = document.createElement("div");
			announcer.setAttribute("data-rocx", "");
			announcer.setAttribute("aria-live", "assertive");
			announcer.setAttribute("aria-atomic", "true");
			Object.assign(announcer.style, { position: "absolute", width: "1px", height: "1px", margin: "-1px", padding: "0", border: "0", overflow: "hidden", clip: "rect(0 0 0 0)", clipPath: "inset(50%)", whiteSpace: "nowrap" });
			document.body.append(announcer);
		}
		announcer.textContent = document.title || this.unbased(url.pathname);
	}

	/**
	 * Rendering anew for a navigation: the live `<head>`'s nodes made the fetched document's, in its
	 * order, a node equal to one there kept where it is (so a stylesheet isn't loaded again or a
	 * script run again), the others the document's (a script inert), and the host's elements
	 * (`[data-rocx]`: the runtime's title and head elements) left alone. A stylesheet that goes
	 * stays until the ones that come have loaded, so nothing shows unstyled.
	 */
	reconcileHead(head, from) {
		const live = [...head.childNodes].filter((node) => !hosts(node));
		const wanted = [...from.childNodes].filter((node) => !hosts(node));
		const kept = new Set();
		const plan = [];
		let at = 0;
		for (const node of wanted) {
			let found = null;
			for (let i = at; i < live.length; i++) {
				if (live[i].isEqualNode(node)) {
					found = live[i];
					at = i + 1;
					break;
				}
			}
			if (found) kept.add(found);
			plan.push(found ?? node);
		}
		const sheet = (node) => node.nodeType === 1 && node.localName === "link" && /(^|\s)stylesheet(\s|$)/i.test(node.getAttribute("rel") ?? "");
		const going = live.filter((node) => !kept.has(node));
		const coming = [];
		let next = null;
		for (let i = plan.length - 1; i >= 0; i--) {
			const node = plan[i];
			if (kept.has(node)) {
				next = node;
				continue;
			}
			const made = node.nodeType === 1 && node.localName === "script" ? Runtime.inertCopy(node) : document.importNode(node, true);
			if (sheet(made)) coming.push(made);
			head.insertBefore(made, next ?? Runtime.headEnd(head));
			next = made;
		}
		const sheets = going.filter(sheet);
		for (const node of going) if (!sheets.includes(node)) node.remove();
		if (sheets.length) {
			if (!coming.length) for (const node of sheets) node.remove();
			else {
				let left = coming.length;
				const done = () => {
					if (--left === 0) for (const node of sheets) node.remove();
				};
				for (const made of coming) {
					made.addEventListener("load", done, { once: true });
					made.addEventListener("error", done, { once: true });
				}
			}
		}
		// The runtime's title stays the document's: before the layout's own.
		const own = head.querySelector("title[data-rocx]");
		const first = [...head.querySelectorAll("title")].find((title) => !hosts(title));
		if (own && first && own.compareDocumentPosition(first) & Node.DOCUMENT_POSITION_PRECEDING) head.insertBefore(own, first);
	}

	/** Where a node the head gets goes when nothing kept follows it: before the host's own elements
	 * at the head's end (the `<Meta>`s, `<Link>`s and `<Style>`s), else at the end. */
	static headEnd(head) {
		let end = null;
		for (let node = head.lastChild; node && hosts(node) && node.localName !== "title"; node = node.previousSibling) end = node;
		return end;
	}

	/** A copy of a fetched `<script>` that won't run (`inertScript`): a script a page renders runs on
	 * a load, not after a navigation in place. */
	static inertCopy(script) {
		const made = inertScript();
		for (const { name, value } of script.attributes) made.setAttribute(name, value);
		made.textContent = script.textContent;
		return made;
	}

	/** Rendering anew for a navigation: `<html>`'s or `<body>`'s attributes that the app writes
	 * (`node`'s: its values, flags, classes and styles) made the fetched document's; any other (one a
	 * page script set, `data-hydrated`) is left as it is. */
	static attributesFrom(element, node, from) {
		const names = new Set();
		for (const [kind, name] of node.a) {
			if (kind === "v" || kind === "vo" || kind === "o" || kind === "oo" || kind === "f" || kind === "fo") names.add(name);
			else if (kind === "ci" || kind === "co") names.add("class");
			else if (kind === "sv" || kind === "so") names.add("style");
		}
		for (const name of names) {
			const value = from?.getAttribute(name) ?? null;
			if (value === null) element.removeAttribute(name);
			else if (element.getAttribute(name) !== value) element.setAttribute(name, value);
		}
	}

	/**
	 * An HTTP request for the running computation or handler (`Call.fetch!`): its answer, as
	 * `{"status":…,"body":…}`, from its calls if in, or asked for now (and it waits, as for a server
	 * read's). A GET the server made as it rendered the page (`Endpoint.read!`: noted under
	 * `GET <url>`) is read from the page's answers, not asked again. Rendering as a server would, it
	 * is the answer the page recorded (`renderToString({ answers })`): the server platform answers a
	 * GET by its route, natively, and anything else is a 599.
	 */
	fetchFor(method, url, headerLines, body) {
		// A read of an endpoint is one that changes (a result reads it again: `revalidate`), unless
		// it is untracked.
		const tracked = !(this.current?.making?.untracked > 0);
		if (tracked) this.touch();
		if (this.onServer) {
			const found = this.given?.find(([named, asked]) => named === `${method} ${url}` && asked === body);
			if (!found) throw new Failed(`599: ${method} ${url} wasn't answered as the server rendered the page`);
			// Noted once, as the server notes a GET once a render.
			if (!this.current?.scope?.region && !this.recorded.includes(found)) this.recorded.push(found);
			return this.give(found[2]);
		}
		const asking = this.current;
		const key = `${method} ${url}\n${body}`;
		let answer = asking.calls?.get(key);
		if (!answer && this.answers.has(key)) {
			// The server answered it while rendering the page: read here, not asked again.
			answer = { state: "ok", value: this.answers.get(key) };
			(asking.calls ??= new Map()).set(key, answer);
			this.notify("seeded", { method, url, value: answer.value });
		}
		if (!answer) {
			this.hydrating?.asked.push(`${method} ${url}`);
			answer = { state: "pending" };
			const headers = Object.fromEntries(headerLines.split("\n").filter(Boolean).map((line) => [line.slice(0, line.indexOf(": ")), line.slice(line.indexOf(": ") + 2)]));
			const asked = performance.now();
			this.notify("fetch", { method, url, body });
			answer.promise = fetch(this.under(url), { method, headers, body: method === "GET" || method === "HEAD" ? undefined : body }).then(
				async (response) => {
					const text = await response.text();
					this.notify("fetched", { method, url, status: response.status, body: text, ms: performance.now() - asked });
					return Object.assign(answer, { state: "ok", value: JSON.stringify({ status: response.status, body: text }) });
				},
				(error) => {
					this.notify("fetched", { method, url, error: String(error.message ?? error), ms: performance.now() - asked });
					return Object.assign(answer, { state: "failed", error: `${method} ${url}: ${error.message ?? error}` });
				},
			);
			(asking.calls ??= new Map()).set(key, answer);
		}
		// What this run asked for (a computation's, made by its first request: `run` drops the rest).
		if (asking.used !== undefined) (asking.used ??= new Set()).add(key);
		if (method === "GET" && tracked && READERS.has(asking.kind)) this.readers.add(asking);
		if (answer.state === "pending") throw new NotReady(answer.promise);
		if (answer.state === "failed") throw new Failed(answer.error);
		return this.give(answer.value);
	}

	/** `url` under the site's base, if it begins with `/` (and isn't `//host/…`). */
	under(url) {
		return url.startsWith("/") && !url.startsWith("//") ? `${this.base}${url.slice(1)}` : url;
	}

	/** A URL the runtime writes into the page (an `href`, `src` or `action` it builds or patches),
	 * under the site's base, as the static copy has the server's (site/build.mjs's `underBase`):
	 * under `/rocx/`, `/syntax` is `/rocx/syntax`. Anything else as it is. */
	written(name, value) {
		return this.base !== "/" && (name === "href" || name === "src" || name === "action") && typeof value === "string" ? this.under(value) : value;
	}

	/** A path the browser shows, the site's base taken off: under `/rocx/`, `/rocx/syntax` is
	 * `/syntax` and `/rocx` is `/`; a path not under it stays as it is. A static copy's page is its
	 * directory's index.html (`rocx build --static`, D-073), and a host may show it by that name:
	 * `/syntax/index.html` is `/syntax/`, `/index.html` is `/`. */
	unbased(path) {
		const base = this.base.slice(0, -1);
		const under = !base || (path !== base && !path.startsWith(this.base)) ? path : path.slice(base.length) || "/";
		return under.endsWith("/index.html") ? under.slice(0, -"index.html".length) : under;
	}

	/**
	 * Listens to the events at `url` (an endpoint's `events!`) for a handler Roc gave (`Call.listen!`):
	 * it runs for each event's data as it comes, `{"Event":…}`, then once at the end, `"Ended"`, or
	 * `{"Failed":…}` (a refusal: an answer that isn't a stream; or a stream cut off). Then its box is
	 * let go of. Started in an owner (a component, a computation, an effect's apply), it stops when
	 * that owner is cleaned up: the request is aborted, and the handler doesn't run again.
	 */
	async listenTo(url, ptr) {
		const id = ++ids;
		this.kept.set(id, ptr);
		const scope = this.current?.scope ?? null;
		const owner = this.owner();
		const controller = new AbortController();
		let stopped = false;
		const stop = () => {
			if (stopped) return;
			stopped = true;
			controller.abort();
			if (!this.kept.has(id)) return;
			this.kept.delete(id);
			this.ex.release(ptr);
		};
		this.cleanupsOf(this.current)?.push(() => {
			if (!stopped) this.notify("unlisten", { url });
			stop();
		});
		const tell = (heard) => {
			if (stopped) return;
			this.notify("heard", { url, heard });
			if (this.kept.has(id)) this.handle(id, JSON.stringify(heard), scope, { owner });
		};
		const done = (heard) => {
			tell(heard);
			stop();
		};
		this.notify("listen", { url });
		try {
			const response = await fetch(this.under(url), { headers: { accept: "text/event-stream" }, signal: controller.signal });
			if (!response.ok || !(response.headers.get("content-type") ?? "").startsWith("text/event-stream")) {
				return done({ Refused: [response.status, await response.text()] });
			}
			const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
			let buffer = "";
			for (;;) {
				const { value, done: over } = await reader.read();
				if (over) return done({ Failed: "the stream was cut off before it ended" });
				buffer += value.replaceAll("\r\n", "\n");
				// An event ends at a blank line: its `event:` name, if any, and its `data:` lines.
				for (let end = buffer.indexOf("\n\n"); end >= 0; end = buffer.indexOf("\n\n")) {
					const lines = buffer.slice(0, end).split("\n");
					buffer = buffer.slice(end + 2);
					const field = (name) => lines.filter((line) => line.startsWith(`${name}:`)).map((line) => line.slice(name.length + 1).replace(/^ /, ""));
					if (field("event")[0] === "end") {
						reader.cancel();
						return done("Ended");
					}
					const data = field("data");
					if (data.length) tell({ Event: data.join("\n") });
				}
			}
		} catch (error) {
			done({ Failed: String(error?.message ?? error) });
		}
	}

	/**
	 * A component's timer (`Solid.set_timeout!`, `set_interval!`): its handler runs after `ms`, or
	 * every `ms`, as a handler does, until it is cleared (`clearTimer`), a timeout has run, or what
	 * started it is cleaned up. Started in a component or a computation (an effect's compute too),
	 * or in an effect's apply, it stops with that run's cleanups, as if it had called
	 * `on_cleanup!(clear!)`, Solid's `onCleanup(() => clearInterval(id))`: before a computation runs
	 * again, before an effect's next apply, and when what made it goes. Started in an event handler,
	 * it belongs to the run that made the handler's element, and stops when that goes. Rendering as
	 * a server would, there is none (its id is 0).
	 */
	startTimer(ms, repeat, ptr) {
		if (this.onServer) {
			this.ex.release(ptr);
			return 0;
		}
		const id = ++ids;
		this.kept.set(id, ptr);
		const cleanups = this.cleanupsOf(this.current);
		if (cleanups)
			cleanups.push(() => {
				this.stopTimer(id);
				this.releaseKept(id);
			});
		else if (this.current?.owner?.made) own(this.current.owner.ownMade?.() ?? this.current.owner.made, "kept").push(id);
		const scope = this.current?.scope ?? null;
		const owner = this.owner();
		const fire = () => {
			if (!this.kept.has(id)) return;
			if (repeat) return this.handle(id, "", scope, { owner });
			// A timeout runs once: its box goes once its handler is done (or, waiting for a server
			// function's answer, once it has run again).
			this.timers.delete(id);
			this.handle(id, "", scope, { owner, done: () => this.releaseKept(id) });
		};
		this.timers.set(id, { repeat, handle: repeat ? setInterval(fire, ms) : setTimeout(fire, ms) });
		return id;
	}

	/** A timer, cleared by the `clear!` Roc was given: stopped, and its box let go of (after the
	 * handler running now, which may be its own: an interval that stops itself). */
	clearTimer(id) {
		this.stopTimer(id);
		if (this.current?.kind === "handler") queueMicrotask(() => this.releaseKept(id));
		else this.releaseKept(id);
	}

	/** The browser's timer for a box, if there is one, stopped. */
	stopTimer(id) {
		const timer = this.timers.get(id);
		if (!timer) return;
		this.timers.delete(id);
		if (timer.repeat) clearInterval(timer.handle);
		else clearTimeout(timer.handle);
	}

	releaseKept(id) {
		const ptr = this.kept.get(id);
		if (!ptr) return;
		this.kept.delete(id);
		this.ex.release(ptr);
	}

	/** The computation what runs now belongs to: a computation, itself; a handler, the one that made
	 * its element (or started its timer, or its listening). */
	owner() {
		return this.current?.making ? this.current : (this.current?.owner ?? null);
	}

	// ---- Kept levels, and the query in place (D-040, phase 2) ----

	/**
	 * A read of the location that won't follow it (`js_location`'s): in a component's body, or in a
	 * part made once (an `if`'s part, a `.map`'s row), it runs once. It is noted on the level it is
	 * in, the keyed part around it (`scope.level`, which a route's keyed part is made with: `Root`'s
	 * levels are D-053's `Html.switched`; an `if`'s part, D-070's, isn't one), or on the root (the root layout, the
	 * document) when there is none. A level that read it so is made anew when the location changes,
	 * as if the location were part of its key (§4.3), so it never shows what the last page knew. A
	 * read inside `untrack!` is one meant once, and isn't noted.
	 */
	readOnce(reader) {
		if (this.onServer || reader.making?.untracked > 0) return;
		const level = reader.scope?.level;
		if (level) (this.onceLevels ??= new Set()).add(level);
		else this.rootOnce = true;
	}

	/** Whether a level that read the location once is still there, or the root read it so: a
	 * navigation keeping them would show what they read, so it is one with a document. */
	readsOnce() {
		if (this.rootOnce) return true;
		for (const level of this.onceLevels ?? []) if (!level.disposed) return true;
		return false;
	}

	/** The `<Errored>` boundaries on the page that show their fallback now. */
	failedBoundaries() {
		return [...this.boundaries.values()].filter((boundary) => boundary.failed !== null && boundary.fallback && !boundary.fallback.disposed && boundary.range.start.isConnected);
	}

	/**
	 * A navigation, before its document is fetched (`navigate`): made in place, and true, when only
	 * the query changes (§7), no level read the location once, and nothing on the page failed (each
	 * would be made anew from the page's document, so that is fetched instead). The address is pushed
	 * (or replaced; back and forward, left as it is), the location committed, and what read it runs
	 * again, in one flush: a read whose URL changed asks its endpoint (behind that endpoint's
	 * middleware; the page's own isn't asked again), its last value shown meanwhile (`is_pending!`).
	 * It scrolls as told (a link unless `noscroll`, `Search.set!` not), back and forward to where
	 * the entry was; the focus stays where it is, and nothing is announced.
	 */
	inPlace(url, { replace = false, scroll = true, pop = null } = {}) {
		const target = Runtime.target(`${this.unbased(url.pathname)}${url.search}`);
		const now = this.location();
		// Where a navigation leaves from, for `remakeRoot`: the same page again is made anew.
		this.leftFrom = now;
		if (target === now || target.split("?")[0] !== now.split("?")[0]) return false;
		if (this.readsOnce() || this.failedBoundaries().length) return false;
		// One on its way is overtaken: its fetch aborted, and forgotten if it was its own (`navigate`'s).
		const previous = this.navigation;
		if (previous) {
			previous.controller.abort();
			const key = Runtime.documentKey(previous.url);
			if (this.pages.get(key)?.signal === previous.controller.signal) this.pages.delete(key);
		}
		this.navigation = null;
		this.setRouting(false);
		const started = performance.now();
		this.notify("navigate", { url: url.href, inPlace: true });
		document.dispatchEvent(new CustomEvent("rocx:navigate", { detail: { url: url.href } }));
		if (pop) {
			this.entryKey = pop;
			if (history.state?.rocx?.key !== pop) history.replaceState({ ...(history.state ?? {}), rocx: { key: pop, index: this.entryIndex } }, "");
		} else {
			this.keepScroll();
			this.entryKey = Runtime.entryKey();
			if (!replace) this.entryIndex++;
			history[replace ? "replaceState" : "pushState"]({ rocx: { key: this.entryKey, index: this.entryIndex } }, "", url.href);
		}
		this.commitLocation(target);
		this.flush();
		this.navigations++;
		this.scrolled(url, { pop, scroll });
		this.watchSight();
		const ms = performance.now() - started;
		this.notify("navigated", { url: url.href, ms, inPlace: true });
		document.dispatchEvent(new CustomEvent("rocx:navigated", { detail: { url: url.href, ms } }));
		return true;
	}

	/**
	 * A navigation's location committed and its document's answers seeded, before its flush
	 * (`commit`): whether the root runs again, the whole document made anew (phase 1's way). It does
	 * when the root layout read the location once, or the page on screen is navigated to again (a
	 * link to it: made anew from its document, as a load would). Otherwise the root layout is kept,
	 * and the levels below it follow by themselves (each a keyed part of `Root`'s route: kept while
	 * its key is the same, made anew when it changes); those that read the location once are made
	 * anew too (`remakeLevels`). A boundary that showed its fallback before the navigation is tried
	 * again once the levels are there, with the document's answers: the error page a failed page
	 * left gives way to the next page.
	 */
	remakeRoot(target) {
		const previous = this.leftFrom;
		this.leftFrom = null;
		// The same page again is made anew (a link to it, as a load would), but not when a submission's
		// answer brings it back (D-119): kept, it reads again what changed (`refreshKept`).
		this.rootKept = !(this.rootOnce || (target === previous && !this.refreshing));
		if (!this.rootKept) {
			if (this.rootOnce) this.madeAnew("the root layout");
			this.rootOnce = false;
			this.onceLevels = new Set();
			this.remade = [];
			return true;
		}
		const failed = this.failedBoundaries();
		this.remakeLevels();
		if (failed.length) {
			this.flush();
			for (const boundary of failed) if (boundary.failed !== null && boundary.range.start.isConnected) boundary.retry();
		}
		return false;
	}

	/** The levels that read the location once, made anew: each run again, its part made as if its key
	 * had changed (`settleShow`). Which they were, for `afterNavigate` to say. */
	remakeLevels() {
		const levels = this.onceLevels ?? [];
		this.onceLevels = new Set();
		this.remade = [];
		for (const level of levels) {
			if (level.disposed) continue;
			this.remade.push({ level, key: level.holds });
			level.holds = REMADE;
			this.schedule(level);
		}
	}

	/** A level made anew for a read of the location once: said in a dev build's console (§4.3), as
	 * Solid 2.0's dev build says a read that won't follow. */
	madeAnew(what) {
		this.notify("remade", { level: what });
		if (this.app?.dev) console.info(`rocx: ${what} was made anew: it read Router.location! once, in its body, and the location changed. Read it where it is used (in markup, or a memo) for it to be kept across navigations (D-040)`);
	}

	/**
	 * A navigation's page made, from its document (`navigate`, after the commit's flush): the levels
	 * made anew for a read of the location are said (`madeAnew`), the server's `<NoHydration>`
	 * regions are the document's (`refreshRegions`), and, the root layout kept, so is the rest of
	 * `<head>` (`reconcileHead`: what is the same stays, a stylesheet that differs is swapped; a page
	 * of the same build rarely differs there, its holes patched already); and the finished
	 * submissions of endpoints no component on the page asks for are forgotten (`forgetSubmissions`).
	 */
	afterNavigate(doc) {
		for (const { level, key } of this.remade ?? []) {
			// A level whose key changed anyway was made anew for that, not for its read.
			if (!level.disposed && level.holds === key) this.madeAnew(typeof key === "string" ? key.slice(1) : "a <Show>'s part");
		}
		this.remade = [];
		// A root made anew took the document's regions as it was made (`settleDocument`); a kept one's
		// are the server's for the page loaded before, and follow the document now.
		if (this.rootKept) this.refreshRegions(doc);
		if (this.rootKept && doc.head && document.head) this.reconcileHead(document.head, doc.head);
		this.rootKept = false;
		this.forgetSubmissions();
	}

	/**
	 * The page's `<NoHydration>` regions, the document's (§4.3): a kept level's were the server's for
	 * the page that was loaded, and a level made in this navigation has an empty one (`region`).
	 * The page and the document render the same markup, so their regions match one for one, in
	 * order: each that differs from the document's (`isEqualNode`) gets its content (a script in it
	 * inert), the others are left as they are. journal's masthead, a region in its kept layout,
	 * follows the page so.
	 */
	refreshRegions(doc) {
		const live = regionRanges(document);
		const fetched = regionRanges(doc);
		if (live.length !== fetched.length) {
			console.warn(`rocx: the page has ${live.length} <NoHydration> regions and its document ${fetched.length}: they are left as they are`);
			return;
		}
		live.forEach((range, at) => {
			const now = inside(range);
			const then = inside(fetched[at]);
			if (now.length === then.length && now.every((node, i) => node.isEqualNode(then[i]))) return;
			const fragment = document.createDocumentFragment();
			for (const node of then) {
				const script = node.nodeType === 1 && node.localName === "script";
				const made = script ? Runtime.inertCopy(node) : document.importNode(node, true);
				if (!script && made.nodeType === 1) for (const inner of made.querySelectorAll("script")) inner.replaceWith(Runtime.inertCopy(inner));
				fragment.append(made);
			}
			replaceRange(range, fragment);
		});
	}

	/** After a navigation (§9.2): the finished submissions to endpoints no component on the new page
	 * asks for are forgotten, so an old one's error doesn't show on a later page that reads that
	 * endpoint; those on their way stay until answered. */
	forgetSubmissions() {
		for (const [key, source] of this.submissions) {
			if (this.actions.has(key)) continue;
			const pending = source.list.filter((entry) => entry.state === "pending");
			if (pending.length === source.list.length) continue;
			source.list = pending;
			this.submissionsChanged(source);
			if (!pending.length && !source.observers.size) this.submissions.delete(key);
		}
	}

	/**
	 * A form submitted with GET (`<form action="/search">`, the browser's query from its fields): a
	 * navigation to its URL (§9.1), in place when it is one of the app's pages, as a link's is, so a
	 * search box needs nothing of the app's. Its fields are the query (a file's, its name), as the
	 * browser sends them; a `target` but `_self`, another site, or `data-rocx-navigation="off"` (and
	 * `"explicit"` for a form without `data-rocx-link`) leave it to the browser. `replace` and
	 * `noscroll` on the form, as on a link.
	 */
	gotForm(event) {
		if (event.defaultPrevented) return;
		const form = event.target;
		if (form?.localName !== "form") return;
		const submitter = event.submitter ?? null;
		const of = (name, attribute) => (submitter?.hasAttribute(attribute) ? submitter.getAttribute(attribute) : form.getAttribute(name)) ?? "";
		if ((of("method", "formmethod").toLowerCase() || "get") !== "get") return;
		const target = of("target", "formtarget");
		if (target && target !== "_self") return;
		const mode = document.documentElement.getAttribute("data-rocx-navigation");
		if (mode === "off" || (mode === "explicit" && !form.hasAttribute("data-rocx-link"))) return;
		const url = new URL(of("action", "formaction") || location.href, document.baseURI);
		const data = new FormData(form, submitter ?? undefined);
		url.search = new URLSearchParams([...data].map(([name, value]) => [name, typeof value === "string" ? value : value.name])).toString();
		url.hash = "";
		if (!this.ours(url)) return;
		event.preventDefault();
		this.navigate(url, { replace: form.hasAttribute("replace"), scroll: !form.hasAttribute("noscroll") });
	}

	// ---- Running ----

	/** Runs a computation. A complete run replaces what the last one made; one that aborts or fails
	 * keeps it. The last complete run's cleanups run first, as Solid runs them before a run again.
	 * What it came to: "ok", "pending" (it waits) or "failed"; nothing if it didn't run. */
	run(computation) {
		if (computation.disposed) return;
		if (computation.kind === "leave") return this.probeLeave(computation); //#nav
		if (computation.recheck) {
			// Here only because a memo an `is_pending!` it called reads changed: run only if that
			// would answer otherwise now.
			computation.recheck = false;
			if (!this.answersChanged(computation)) return;
		}
		this.cleanUp(computation.made.cleanups);
		const making = making_();
		const previous = this.current;
		this.current = computation;
		computation.making = making;
		computation.used = null;
		this.stats.runs++;
		let out;
		let outcome = "ok";
		let failure = null;
		let waited = null;
		try {
			out = this.enter(() => (computation.kind === "root" ? this.ex.mount() : this.ex.run(computation.runner)));
		} catch (error) {
			if (error instanceof NotReady) {
				outcome = "pending";
				waited = error;
				this.stats.aborts++;
				error.wait.then(() => this.schedule(computation));
			} else if (error instanceof Failed) {
				outcome = "failed";
				failure = error;
			} else throw error;
		} finally {
			this.current = previous;
		}
		// What it reads now is what it depends on, whatever the outcome; an untracked run depends on
		// nothing (a read that waits runs it again, above).
		for (const source of computation.sources) source.observers?.delete(computation);
		computation.sources = computation.untracked ? NONE : making.sources;
		for (const source of computation.sources) (source.observers ??= new Set()).add(computation);
		if (outcome === "ok") {
			computation.making = making;
			try {
				this.settle(computation, out);
			} finally {
				// Even if settling threw (hydrating found a mismatch): what it made is the computation's
				// now, so disposing it lets go of all of it.
				const old = computation.made;
				computation.made = !madeNothing(making) ? spare(making) : inert(making) ? MADE_NONE : MADE_READ;
				computation.queries = making.queries;
				computation.making = null;
				this.drop(old);
			}
			// Answers this run didn't ask for are stale.
			if (computation.calls !== null) for (const key of computation.calls.keys()) if (!computation.used?.has(key)) computation.calls.delete(key);
			computation.scope.loading?.done(computation);
		} else {
			computation.making = null;
			this.drop(making);
			if (computation.kind === "memo") {
				if (computation.next) this.ex.release(computation.next);
				computation.next = 0;
			}
			this.reclaim(failure ?? waited);
			if (outcome === "pending" && computation.kind === "root") {
				// Run again, a component would make its memos again, and ask the server again, forever.
				throw new Error("rocx: a component read a value that isn't in yet outside its markup: read it in a hole ({…}), which waits");
			}
			// An effect is no part of the markup: it holds no <Loading>.
			if (outcome === "pending") {
				if (computation.kind !== "reaction") computation.scope.loading?.wait(computation);
			} else this.failed(computation, failure);
		}
		if (computation.kind === "memo") {
			// Waiting for a new value with one to show (and not failed): pending, from this flush on.
			computation.refreshing = outcome === "pending" && computation.value !== 0 && computation.state !== "failed";
			this.restale(computation);
			// A value, or a failure: a probe that stopped at it may now read further.
			if (outcome !== "pending") this.recheckReaders(computation);
		}
		if (outcome !== "pending") this.revalidated(computation);
		return outcome;
	}

	/** A hole's computation, just run, that is static (`inert`): one that answered, and read and made
	 * nothing that changes. It never runs again. */
	isStatic(computation, outcome) {
		return outcome === "ok" && inert(computation.made);
	}

	/** A static hole's computation, let go of: nothing will run it, and it owns nothing (only boxes it
	 * kept, if any, which keep it as their owner). */
	forget(computation, owner) {
		if (computation.made.kept.length) return;
		computation.disposed = true;
		const children = owner ? (owner.making ?? owner.made).children : null;
		if (children?.at(-1) === computation) children.pop();
	}

	/**
	 * Whether a memo, or a memo it reads (all the way up), has a value and waits for a new one: set
	 * again after it runs. When that changes, the computations whose `is_pending!` read it are
	 * rechecked, and the memos that read it set theirs again. A failed memo is not pending.
	 */
	restale(memo) {
		if (memo.disposed) return;
		let stale = memo.refreshing;
		if (memo.state !== "failed") for (const source of memo.sources) if (source.kind === "memo" && source.stale) stale = true;
		if (stale === memo.stale) return;
		memo.stale = stale;
		this.recheckReaders(memo);
		for (const observer of memo.observers ?? NONE) if (observer.kind === "memo") this.restale(observer);
	}

	/** What `is_pending!` answers for the memos its probe read. */
	pending(memos) {
		return memos.some((memo) => memo.stale);
	}

	/** The computations whose `is_pending!` read the memo, rechecked in the flush. */
	recheckReaders(memo) {
		for (const reader of memo.pending.observers) {
			if (reader.disposed || this.dirty.has(reader)) continue;
			reader.recheck = true;
			this.dirty.add(reader);
			this.wake();
		}
	}

	/** Whether an `is_pending!` the computation's last run called answers otherwise now, or reads
	 * other memos: each one's probe, run again. */
	answersChanged(computation) {
		for (const { probe, memos, answer } of computation.queries ?? []) {
			const ptr = this.kept.get(probe);
			if (!ptr) return true;
			const now = this.probe(ptr);
			if (this.pending(now) !== answer || now.length !== memos.length || now.some((memo, i) => memo !== memos[i])) return true;
		}
		return false;
	}

	/** Runs an accessor once (`refresh!`'s probe, `is_pending!`'s), its reads untracked: the memos it
	 * reads, in order. A read that waits or fails only stops it. */
	probe(ptr) {
		const probe = { kind: "probe", memos: new Set(), calls: new Map() };
		const previous = this.current;
		this.current = probe;
		try {
			this.enter(() => this.ex.run(ptr));
		} catch (error) {
			if (!(error instanceof NotReady || error instanceof Failed)) throw error;
			this.reclaim(error);
		} finally {
			this.current = previous;
		}
		return [...probe.memos];
	}

	/** A complete run's answer, applied: the node patched, or the memo's value set. */
	settle(computation, out) {
		const { kind, target, name } = computation;
		if (kind === "selector") {
			// Its key, as Roc wrote it. When it changes, the readers of the key it was and of the key it
			// is run again, and no other: the rows a selection leaves and comes to. Keys no reader reads
			// any more go, swept once there are twice as many as the last sweep left (rows cleared and
			// made again with new keys), so a change costs the same however many rows there are.
			const was = computation.key;
			computation.key = out;
			computation.settle?.();
			computation.settled = computation.settle = null;
			if (was !== null && was !== out) {
				for (const key of [was, out]) for (const observer of computation.keys.get(key)?.observers ?? NONE) this.schedule(observer);
				if (computation.keys.size > 2 * (computation.swept ?? 0) + 64) {
					for (const [key, source] of computation.keys) if (!source.observers?.size) computation.keys.delete(key);
					computation.swept = computation.keys.size;
				}
			}
			return;
		}
		if (kind === "memo") {
			// A store's selection whose part is the one it had, an answer it had (D-053), keeps quiet: its
			// readers aren't told. It keeps the newest value all the same.
			const quiet = computation.same && computation.state === "ok" && computation.value !== 0;
			computation.same = false;
			if (computation.value) this.ex.release(computation.value);
			computation.value = computation.next;
			computation.next = 0;
			computation.state = "ok";
			computation.settle?.();
			computation.settled = computation.settle = null;
			if (!quiet) for (const observer of computation.observers ?? NONE) this.schedule(observer);
			return;
		}
		if (kind === "reaction") {
			// Its apply (the box its compute kept, by id), run after the flush; a render effect's, now,
			// as Solid 2.0's `createRenderEffect` runs it in the render (D-052). An answer after a
			// failure: the failure is over.
			computation.apply = Number(out);
			computation.failure = null;
			if (computation.render) {
				this.due.delete(computation);
				this.applyReaction(computation);
				return;
			}
			this.due.add(computation);
			this.wake();
			return;
		}
		if (kind === "show") return this.settleShow(computation, JSON.parse(out));
		if (kind === "for") return this.settleFor(computation, JSON.parse(out));
		if (kind === "transition") return this.setTransition(target, name, JSON.parse(out));
		if (kind === "key") return this.keys.set(target, JSON.parse(out));
		if (kind === "drag") return this.setDrag(target, name, JSON.parse(out));
		if (kind === "text" || kind === "attr" || kind === "flag" || kind === "class" || kind === "optional" || kind === "style") {
			// A value the node has already isn't a patch (a hole runs again whenever what it read
			// was written, which may be with the same value). A URL under the site's base.
			const value = kind === "attr" || kind === "optional" ? this.written(name, JSON.parse(out)) : JSON.parse(out);
			if (computation.adopting && kind === "text") {
				computation.adopting = false;
				target.data = value;
				return;
			}
			// A field being made has no `value` attribute yet: written, as the server writes it, which
			// is no patch.
			if (kind === "attr" && name === "value" && "value" in target && !target.hasAttribute("value")) {
				target.setAttribute(name, value);
				target.value = value;
				return;
			}
			// A computed `class` beside `class:name`s, each `class:name`, and a computed `style` beside
			// `style:name`s: the element's whole attribute, written as the server writes it.
			if (computation.attrs && (kind === "class" || ((kind === "attr" || kind === "optional") && (name === "class" || name === "style")))) {
				if (kind === "class") {
					let toggles = this.classToggles.get(target);
					if (!toggles) this.classToggles.set(target, (toggles = new Map()));
					toggles.set(name, value);
					const computed = computedOf(computation.attrs, "class");
					// Beside a computed `class` that has run: the whole attribute. Else itself, turned on
					// where the server writes it; before the computed `class` has run (written after it),
					// that orders it.
					if (computed && this.computedClasses.has(target)) return this.writeWhole(target, "class", this.wholeClass(target, computation.attrs), kind, name);
					if (target.classList.contains(name) === value) return;
					this.stats.patches++;
					this.notify("patch", { kind, name, node: target });
					target.classList.toggle(name, value);
					if (value && !computed) this.writeWhole(target, "class", this.wholeClass(target, computation.attrs));
					return;
				}
				if (name === "class") {
					const old = this.computedClasses.get(target) ?? "";
					this.computedClasses.set(target, value);
					return this.writeWhole(target, "class", this.wholeClass(target, computation.attrs, old), kind, name);
				}
				this.computedStyles.set(target, value);
				return this.writeWhole(target, "style", this.wholeStyle(target, computation.attrs), kind, name);
			}
			// A style hole's value, as Roc gave it, whether or not it changed (`wholeStyle`).
			if (kind === "style") {
				let raw = this.rawStyles.get(target);
				if (!raw) this.rawStyles.set(target, (raw = new Map()));
				raw.set(name, value);
			}
			const now =
				kind === "text"
					? target.data
					: kind === "attr"
						? name === "value" && "value" in target
							? target.value
							: target.getAttribute(name)
						: kind === "optional"
							? (target.getAttribute(name) ?? "")
							: kind === "style"
								? target.style.getPropertyValue(name).trim()
								: kind === "class"
									? target.classList.contains(name)
									: name in target
										? target[name]
										: target.hasAttribute(name);
			if (now === value) return;
			this.stats.patches++;
			this.notify("patch", { kind, name, node: target });
			if (kind === "text") target.data = value;
			else if (kind === "attr") {
				target.setAttribute(name, value);
				// What a field shows is its property once someone has typed in it, not its attribute.
				if (name === "value" && "value" in target) target.value = value;
			}
			else if (kind === "optional") value === "" ? target.removeAttribute(name) : target.setAttribute(name, value);
			else if (kind === "style") value === "" ? target.style.removeProperty(name) : target.style.setProperty(name, value);
			else if (kind === "class") target.classList.toggle(name, value);
			else {
				target.toggleAttribute(name, value);
				if (name in target) target[name] = value;
			}
			// A link's new address: its mark too (D-086).
			if (name === "href" && this.links.has(target)) this.markLink(target);
			return;
		}
		if (target?.document) return this.settleDocument(computation, JSON.parse(out));
		// D-070's hole while it shows text alone: patched as a text hole's text.
		if (kind === "html" && computation.text && !computation.peek && this.settleHoleText(computation, JSON.parse(out))) return;
		if (kind === "html" || kind === "root") {
			const nodes = answered(JSON.parse(out));
			if (computation.peek) {
				// Its first run, before its place is known: built (or adopted) by whoever ran it, once it
				// knows whether the hole is static.
				computation.peeked = nodes;
				return;
			}
			if (computation.adopting) {
				// Hydrating: the server rendered this; bind to its nodes instead of making new ones (no patch).
				computation.adopting = false;
				const cursor = new Cursor(target.start.nextSibling);
				for (const node of nodes) this.adopt(node, computation, computation.scope, cursor);
				cursor.end(target.end);
				return;
			}
			this.stats.patches++;
			this.notify("patch", { kind, name, node: target.start.parentNode });
			this.measure(); //#moves
			const fragment = document.createDocumentFragment();
			for (const node of nodes) fragment.append(this.build(node, computation, computation.scope));
			replaceRange(target, fragment);
		}
	}

	/**
	 * A run of D-070's hole while it shows text alone (`computation.text`): its text node patched
	 * (bound, hydrating), true. When it shows markup now, its text's place becomes a range, as a
	 * markup hole's, and false: the run is a markup hole's from here on.
	 */
	settleHoleText(computation, parsed) {
		const nodes = answered(parsed);
		const text = computation.target;
		const value = loneText(nodes);
		if (value !== null) {
			if (computation.adopting) {
				computation.adopting = false;
				if (text.data !== value) {
					this.stats.patches++;
					this.notify("patch", { kind: "text", name: null, node: text });
					text.data = value;
				}
				return true;
			}
			if (text.data === value) return true;
			this.stats.patches++;
			this.notify("patch", { kind: "text", name: null, node: text });
			text.data = value;
			return true;
		}
		const start = document.createComment("html");
		const end = document.createComment("/html");
		text.before(start);
		text.after(end);
		computation.target = { start, end };
		computation.text = false;
		computation.adopting = false;
		return false;
	}

	failed(computation, failure) {
		const memo = computation.kind === "memo" ? computation : failure.memo;
		computation.scope.loading?.done(computation);
		if (computation.kind === "memo") {
			computation.state = "failed";
			computation.error = failure.message;
			computation.settle?.();
			computation.settled = computation.settle = null;
			for (const observer of computation.observers ?? NONE) this.schedule(observer);
			return;
		}
		// An effect with an error handler (`create_effect_with!`, D-052): the handler is told, after the
		// flush, as its apply would be, unless it answers again meanwhile; no <Errored> shows.
		if (computation.kind === "reaction" && computation.onError) {
			computation.failure = failure.message;
			this.due.add(computation);
			this.wake();
			return;
		}
		if (computation.scope.errored) computation.scope.errored.fail(failure.message, memo);
		else console.error(`rocx: ${failure.message} (no <Errored> around it)`);
	}

	/** Lets go of what a run made, in Solid's unwind order: its computations stop (the last made
	 * first), its cleanups run (the last first), and the boxes kept for them are released. */
	drop(made) {
		for (let i = made.children.length - 1; i >= 0; i--) this.dispose(made.children[i]);
		this.cleanUp(made.cleanups);
		for (const id of made.kept) {
			this.stopTimer(id);
			const ptr = this.kept.get(id);
			this.kept.delete(id);
			if (ptr) this.ex.release(ptr);
		}
		for (const id of made.signals ?? []) {
			const signal = this.signals.get(id);
			if (!signal) continue;
			this.signals.delete(id);
			this.releaseSignal(signal);
		}
	}

	dispose(computation) {
		if (!computation || computation.disposed) return;
		computation.disposed = true;
		this.readers.delete(computation);
		this.revalidated(computation);
		for (const source of computation.sources) {
			source.observers?.delete(computation);
			// A selector's key no reader reads any more (its row gone): gone from the selector too, so
			// rows made and cleared with new keys leave none behind.
			if (source.selector && !source.observers?.size) source.selector.keys.delete(source.key);
		}
		computation.scope.loading?.done(computation);
		if (computation.kind === "leave") {
			// A `use_before_leave!` listener, gone with its owner: asked no more.
			this.leaveListeners.delete(computation);
			this.releaseKept(computation.runner);
			this.guardUnload();
		}
		if (computation.kind === "reaction") {
			// Its last apply's cleanups; its compute is its own box, as a memo's is.
			this.due.delete(computation);
			this.cleanUp(computation.cleanups);
			this.ex.release(computation.runner);
		}
		this.drop(computation.made);
		// What it shows (an `if`'s part, a `.map`'s rows) is its own, not its last run's.
		if (computation.part) this.dispose(computation.part);
		if (computation.list) this.dropList(computation.list);
		if (computation.kind === "selector") {
			this.selectors.delete(computation.id);
			// Its computation is its own box, as a memo's is.
			this.ex.release(computation.runner);
		}
		if (computation.kind === "memo") {
			this.memos.delete(computation.id);
			if (computation.value) this.ex.release(computation.value);
			if (computation.next) this.ex.release(computation.next);
			// A memo's computation is its own box (not one kept for markup): released with it.
			this.ex.release(computation.runner);
		}
	}

	schedule(computation) {
		if (computation.disposed) return;
		computation.recheck = false;
		this.dirty.add(computation);
		this.wake();
	}

	/** A flush, on the next microtask, unless one is coming. */
	wake() {
		if (!this.flushing) {
			this.flushing = true;
			queueMicrotask(() => this.flush());
		}
	}

	/** Runs what is dirty, oldest first: a memo before what reads it, an owner before what it made.
	 * Then, with nothing dirty, the effects whose apply is due, oldest first (what they write is
	 * dirty again, and runs before the next). */
	flush() {
		this.inFlush = true;
		for (;;) {
			if (this.dirty.size) this.run(this.dirty.take());
			// A navigation's render holds them until the page is as it will stay (`navigate`).
			else if (this.due.size && !this.holdingEffects) this.applyReaction(this.due.take());
			else break;
		}
		this.inFlush = false;
		this.flushing = false;
		// What moved glides, before what came plays its transition in (one that is a moved element's
		// doesn't).
		if (this.measured) this.glide(); //#moves
		if (this.entering.length) this.playEntering();
		// The title before the page's functions, so one sees the page as the flush left it.
		if (this.titlesDirty) this.showTitle();
		if (this.headsDirty) this.showHead();
		if (this.calling.length) this.callEffects();
	}

	/** A title came, changed or went: shown once the flush that did it is over (one is coming). */
	titleChanged() {
		this.titlesDirty = true;
		if (!this.flushing) {
			this.flushing = true;
			queueMicrotask(() => this.flush());
		}
	}

	/**
	 * The document's title: the text of the last `<Title>` rendered that is still there, in a
	 * `<title data-rocx>` first in `<head>` (the server's, if it put one there; or one made here), which
	 * is what `document.title` reads. With none, that element goes, and the root layout's own
	 * `<title>` stands. The host's elements are passed over hydrating, so the layout's `<head>`
	 * hydrates as it renders.
	 */
	showTitle() {
		this.titlesDirty = false;
		if (typeof document === "undefined") return;
		let top = null;
		for (const entry of this.titles.values()) if (!top || entry.seq > top.seq) top = entry;
		let element = document.head?.querySelector("title[data-rocx]") ?? null;
		if (!top) return element?.remove();
		if (!element) {
			element = document.createElement("title");
			element.setAttribute("data-rocx", "");
			const head = document.head ?? document.documentElement;
			head.insertBefore(element, head.querySelector("title"));
		}
		if (element.textContent !== top.title) element.textContent = top.title;
	}

	// ---- The head's other elements (D-054) ----

	/** A `<Meta>`, `<Link>` or `<Style>` came, changed or went: shown once the flush is over. */
	headChanged() {
		this.headsDirty = true;
		this.wake();
	}

	/** Head elements in their order (`seq`), each with a key (a `<Meta>`'s name…) only where it is
	 * the last with it: @solidjs/meta's cascade. */
	static headsOf(entries) {
		const last = new Map();
		for (const entry of entries) if (entry.key) last.set(entry.key, entry);
		return entries.filter((entry) => !entry.key || last.get(entry.key) === entry);
	}

	/**
	 * The `<head>`'s host elements (`[data-rocx]`, but its `<title>`) as the `<Meta>`s, `<Link>`s and
	 * `<Style>`s there are say, in their order: one equal to what is there (the server's, hydrating)
	 * is kept, so a stylesheet isn't loaded again; one that differs is replaced; one more is added
	 * at the head's end; one fewer goes.
	 */
	showHead() {
		this.headsDirty = false;
		if (typeof document === "undefined" || !document.head) return;
		const wanted = Runtime.headsOf([...this.heads.values()].sort((a, b) => a.seq - b.seq));
		const have = [...document.head.children].filter((node) => node.hasAttribute("data-rocx") && node.localName !== "title" && node.localName !== "script");
		const template = document.createElement("template");
		wanted.forEach((entry, at) => {
			template.innerHTML = entry.markup;
			const made = template.content.firstElementChild;
			if (!made) return;
			const old = have[at];
			if (old?.isEqualNode(made)) return;
			if (old) old.replaceWith(made);
			else document.head.append(made);
		});
		for (const extra of have.slice(wanted.length)) extra.remove();
	}

	/** The markup with the head elements the page rendered before its `</head>` (signals.rs's
	 * `headed`), in their order, a later one in an earlier's place with its key. */
	static headed(markup, heads) {
		const shown = Runtime.headsOf(heads);
		const end = markup.indexOf("</head>");
		if (!shown.length || end < 0) return markup;
		return `${markup.slice(0, end)}${shown.map((entry) => entry.markup).join("")}${markup.slice(end)}`;
	}

	/**
	 * The page's functions the handlers that are done called (`Browser.call!`), in order, now that the
	 * page is patched with what they wrote: each given the argument, parsed, and what an effect
	 * can't reach otherwise, `{ under }` (`under(url)`: a URL that begins with `/` under the site's
	 * base, `/rocx/sounds/eat.wav` for `/sounds/eat.wav` on a copy served at `/rocx/`). A plugin's
	 * script registers its effects on `window.rocxEffects`, named `<plugin>.<effect>`
	 * (`audio.play`). One that isn't there, or throws, is told on the console.
	 */
	callEffects() {
		const calls = this.calling;
		this.calling = [];
		for (const { effect: name, arg } of calls) {
			this.notify("effect", { name, arg });
			const effect = name.startsWith("rocx:") ? this.builtins[name] : (this.effects[name] ?? globalThis.rocxEffects?.[name]);
			if (typeof effect !== "function") {
				const plugin = /^([a-z0-9-]+)\.[^.]/.exec(name)?.[1];
				const said = plugin ? `the ${plugin} plugin's script registers it: is the ${plugin} plugin in the app's plugins?` : `give the runtime one (Runtime.load(wasm, { effects: { ${name}(arg) {…} } }))`;
				console.error(`rocx: no effect is called ${name}: ${said}`);
				continue;
			}
			try {
				effect(JSON.parse(arg), this.toEffects);
			} catch (error) {
				console.error(`rocx: the effect ${name} failed:`, error);
			}
		}
	}

	/** An effect's apply: its last apply's cleanups first, then the box its compute kept, as a
	 * handler (untracked; its writes applied when it is done), owning what it starts. A failed
	 * compute's error handler instead, given why (`create_effect_with!`), the same way. */
	applyReaction(effect) {
		if (effect.disposed) return;
		const failure = effect.failure;
		const box = failure !== null ? effect.onError : effect.apply;
		if (!this.kept.has(box)) return;
		effect.failure = null;
		this.cleanUp(effect.cleanups);
		this.notify("apply", { id: effect.id, failure });
		this.handle(box, failure ?? "", effect.scope, { owner: effect, cleanups: effect.cleanups });
	}

	/** Computes a memo again, asking the server again. A failed one waits from now on, so what reads
	 * it next (an <Errored> trying again) waits for the new answer instead of failing again. */
	refresh(memo) {
		memo.calls?.clear();
		if (memo.state === "failed") {
			memo.state = "pending";
			memo.error = null;
		}
		this.schedule(memo);
	}

	/** The value a handler's latest write to a signal gave it, not yet applied (an optimistic write's
	 * too); undefined if it wrote none. */
	ownWrite(handler, signal) {
		const writes = handler.writes;
		for (let at = writes.length - 1; at >= 0; at--) {
			const write = writes[at];
			if (write.signal === signal) return write.value;
			if (write.optimistic?.signal === signal) return write.optimistic.value;
		}
		return undefined;
	}

	/** Writes a handler made, applied together once it is done. */
	apply(writes) {
		// Optimistic writes (D-054) open a transition the submissions sent with them join.
		const transition = writes.some((write) => write.optimistic) ? this.openTransition() : null;
		for (const write of writes) {
			if (write.optimistic) this.hold(write.optimistic, transition);
			else if (write.revalidate) this.revalidate(() => {}, write.revalidate);
			else if (write.retried !== undefined) this.retrySubmission(write.retried, write.id);
			else if (write.signal) {
				const { signal, value } = write;
				// Its part went away while the handler ran: nothing reads it.
				if (!this.signals.has(signal.id)) {
					this.ex.release(value);
					continue;
				}
				this.ex.release(signal.value);
				signal.value = value;
				for (const observer of signal.observers) this.schedule(observer);
			} else if (write.refresh) this.refresh(write.refresh);
			else if (write.retry) write.retry.retry();
			else if (write.effect) {
				// Called once the page is patched: a flush runs them, so there is one coming.
				this.calling.push(write);
				if (!this.flushing) {
					this.flushing = true;
					queueMicrotask(() => this.flush());
				}
			} else if (write.cleared !== undefined) {
				// The latest forgotten (Solid's `clear`): out of the list, and none is the latest until the next.
				const source = this.submissionOf(write.cleared);
				source.list.pop();
				source.cleared = true;
				this.submissionsChanged(source);
			} else if (write.dropped !== undefined) {
				const source = this.submissionOf(write.dropped);
				source.list = source.list.filter((entry) => entry.id !== write.id);
				this.submissionsChanged(source);
			} else if (write.submit) this.sendAction(write.submit);
			else if (write.navigate) this.navigate(write.navigate.to, write.navigate); //#nav
			else if (write.leaveRetry) this.retryLeave(write.leaveRetry.id, write.leaveRetry.force); //#nav
		}
	}

	/** Runs a handler (the id of its box). If it waits for an answer from the server, its writes are
	 * dropped, and it runs again once the answer is in. Its `owner` is the computation a timer it
	 * starts belongs to; an effect's apply passes its `cleanups`, where what it starts goes (dropped
	 * too, run, if it waits); `done`, if any, is called once it has run (or failed). `again: false`
	 * (a leave's listener): one that waits isn't run again, and is done. */
	handle(runner, event, scope = null, { owner = null, cleanups = null, done = null, again = true } = {}) {
		// Its scope: the contexts and region where it was bound.
		// `own`: how many `Solid.update!`s it is inside now, whose reads of signals give its writes.
		const handler = { kind: "handler", runner, calls: new Map(), writes: [], own: 0, event, scope, owner, cleanups };
		const go = () => {
			const previous = this.current;
			this.current = handler;
			handler.writes = [];
			handler.own = 0;
			const mark = cleanups?.length ?? 0;
			try {
				this.enter(() => this.ex.run(this.kept.get(handler.runner)));
			} catch (error) {
				for (const write of handler.writes) {
					if (write.signal) this.ex.release(write.value);
					else if (write.optimistic) this.ex.release(write.optimistic.value);
				}
				if (cleanups) {
					this.current = previous;
					this.cleanUp(cleanups.splice(mark));
				}
				if (error instanceof NotReady || error instanceof Failed) this.reclaim(error);
				if (error instanceof NotReady) {
					this.stats.aborts++;
					if (again) {
						error.wait.then(() => this.kept.has(handler.runner) && go());
						return;
					}
					// A leave's listener: what it waits for can't hold the navigation (`mayLeave`).
					if (this.app?.dev) console.warn("rocx: a Router.use_before_leave! listener waited for the server: the navigation couldn't wait for it, and went on unless it was stopped before. Decide from what the page has (a signal, a memo already in)");
					done?.();
					return;
				}
				if (error instanceof Failed) {
					console.error(`rocx: a handler failed: ${error.message}`);
					done?.();
					return;
				}
				throw error;
			} finally {
				this.current = previous;
			}
			this.apply(handler.writes);
			done?.();
		};
		go();
	}

	// ---- Parts (a hole's `if` and `match`, a "show" node) and rows (a `.map`'s, a "for" node) ----

	/** A part of the markup, built (or found, hydrating) in `range`, owned by a computation of its own. */
	part(nodes, scope, range, adopting) {
		const owner = new Computation(this, { kind: "boundary", owner: null, scope });
		if (adopting) {
			const cursor = new Cursor(range.start.nextSibling);
			for (const node of nodes) this.adopt(node, owner, scope, cursor);
			cursor.end(range.end);
		} else {
			const fragment = document.createDocumentFragment();
			for (const node of nodes) fragment.append(this.build(node, owner, scope));
			replaceRange(range, fragment);
		}
		return owner;
	}

	/**
	 * A <Show>: only a change of whether its condition holds switches what it shows. What it showed
	 * goes at once, or, if anything in it has a transition out, stays until that is over, in a range
	 * of its own before the <Show>'s; what it shows now plays its transitions in. Its first time, it
	 * plays none: what a page, a row or a part shows as it is made comes with it.
	 */
	settleShow(computation, holds) {
		if (computation.holds === holds) return;
		const adopting = computation.adopting;
		computation.adopting = false;
		const first = computation.holds === undefined;
		computation.holds = holds;
		if (!first && !adopting) this.measure(); //#moves
		const { node, target, scope } = computation;
		const outs = first || adopting ? [] : this.transitioned(target, "out");
		if (outs.length) {
			const going = { start: target.start, end: document.createComment("/leaving") };
			target.start = document.createComment("show");
			target.end.before(going.end, target.start);
			this.keep(() => this.dispose(computation.part));
			this.leave(going, outs);
		} else this.dispose(computation.part);
		// What it makes is a level (D-040): a read of the location once, in it, makes it anew (`readOnce`).
		// A level of the page (D-040, a route's keyed part); an `if`'s or `match`'s part (D-070, `"b"`)
		// belongs to the level around it.
		const level = node.b ? scope : { ...scope, level: computation };
		if (holds && node.with) {
			// A function child: made when it shows, by its own computation (it reads the narrowed value).
			const made = new Computation(this, { kind: "html", runner: this.kept.get(node.with), owner: null, scope: level, target });
			made.adopting = adopting;
			// Made once, as a component is: its holes, and the getters it gives its components, follow.
			made.untracked = true;
			made.choosing = Boolean(node.b);
			computation.part = made;
			this.run(made);
		} else computation.part = this.part(holds ? node.c : [node.fallback], level, target, adopting);
		if (!first && !adopting) this.entered(target);
		// Its nodes gathered only for an observer (the tests', the docs' demos): nothing else reads them.
		if (!adopting && this.observer) this.notify("show", { holds, nodes: inside(target) });
	}

	/**
	 * A `.map`'s rows, from what its list says now (`[{k, r}]`): a row whose key is still there is
	 * kept, and moved where it now goes (its index changing; its item, set as the list was read,
	 * changing too); a new key gets a new row, made by its own computation; a key that is gone takes
	 * its row and its item with it. A row owns the box it was made with.
	 */
	settleFor(computation, entries) {
		const list = computation.list;
		const { target, scope, node } = computation;
		const adopting = computation.adopting;
		computation.adopting = false;
		// Rows made its first time come with the page, the row or the part it is in: no transition.
		const later = computation.settled === true;
		computation.settled = true;
		// Rows that go, come or move change the page: where what glides is, first.
		if (later && !adopting && (entries.length !== list.rows.size || entries.some(({ k }, index) => list.indexes.get(k)?.value !== index || !list.rows.has(k)))) this.measure(); //#moves
		const cursor = adopting ? new Cursor(target.start.nextSibling) : null;
		// The rows' boxes aren't the run's to let go of: each is its row's, or let go of here. Taken out
		// of what the run keeps in one pass (one search a row was quadratic in the rows).
		const kept = computation.making.kept;
		// (A row the page shows already comes with none: `Host.row_set!` said it is kept.)
		if (kept !== NONE) {
			const runners = new Set();
			for (const { r } of entries) if (r) runners.add(r);
			let left = 0;
			for (const id of kept) if (!runners.has(id)) kept[left++] = id;
			kept.length = left;
		}
		const rows = new Map();
		// Where each row was, by its place now: -1 for a row that wasn't on the page (see `steady`).
		const was = new Array(entries.length).fill(-1);
		entries.forEach(({ k, r }, index) => {
			let row = list.rows.get(k);
			if (row) {
				// Still there: the box this run made for it, if it made one, isn't needed.
				if (r) {
					this.ex.release(this.kept.get(r));
					this.kept.delete(r);
				}
				const at = list.indexes.get(k);
				if (!detached(row.range)) was[index] = at.value;
				if (at.value !== index) {
					at.value = index;
					for (const observer of at.observers ?? NONE) this.schedule(observer);
				}
			} else {
				list.indexes.set(k, { value: index, observers: null });
				const range = adopting ? { start: cursor.comment("row"), end: cursor.closing("row") } : makeRange("row");
				row = { key: k, runner: r, range, fresh: !adopting };
				row.computation = new Computation(this, { kind: "html", runner: this.kept.get(r), owner: null, scope, target: range });
				row.computation.adopting = adopting;
				// Made once, as Solid's mapArray makes a row: its holes, and the getters it gives its
				// components, follow its item (D-039).
				row.computation.untracked = true;
				this.run(row.computation);
				if (later && !adopting) this.entered(range);
				if (adopting) cursor.node = range.end.nextSibling;
			}
			rows.set(k, row);
		});
		const going = [];
		for (const [key, row] of list.rows) if (!rows.has(key)) going.push(row);
		// Every row going at once, none on its way out or leaving with a transition: the list emptied in
		// one go (as vanillajs clears), not row by row.
		if (!rows.size && going.length > 1 && !this.keeping && going.every((row) => !detached(row.range) && !this.transitioned(row.range, "out").length)) {
			for (const row of going) this.dropRow(list, row, false, false);
			clearRange(target);
		} else for (const row of going) this.dropRow(list, row, true);
		// The items of keys that are gone go too.
		for (const [key, item] of list.items) {
			if (!rows.has(key)) {
				this.ex.release(item.value);
				list.items.delete(key);
			}
		}
		list.rows = rows;
		if (adopting) {
			if (!rows.size) {
				computation.fallbackRange = { start: cursor.comment("fallback"), end: cursor.closing("fallback") };
				computation.part = this.part([node.fallback], scope, computation.fallbackRange, true);
			}
			return;
		}
		// The fallback while there are no rows.
		if (rows.size) {
			this.dispose(computation.part);
			computation.part = null;
			if (computation.fallbackRange) {
				removeRange(computation.fallbackRange);
				computation.fallbackRange = null;
			}
		} else if (!computation.fallbackRange) {
			computation.fallbackRange = makeRange("fallback");
			target.end.before(computation.fallbackRange.fragment);
			computation.part = this.part([node.fallback], scope, computation.fallbackRange, false);
		}
		// Rows in order, as few moved as can be: the longest run of rows already in order (by where
		// each was) stays where it is, and the others move (or arrive) beside them, the last first, as
		// Solid's reconcile does. Two rows swapped in a thousand move two, not the ones between. A row
		// on its way out stays where it is.
		const order = [...rows.values()];
		const stays = steady(was);
		const placed = [];
		let next = target.end;
		for (let index = order.length - 1; index >= 0; index--) {
			const row = order[index];
			if (!stays[index]) {
				next.before(detached(row.range) ? (row.range.fragment ?? collectRange(row.range)) : collectRange(row.range));
				// On the page now: the fragment that held it is empty, and needn't be kept.
				row.range.fragment = null;
				this.stats.patches++;
				placed.push(row);
			}
			next = row.range.start;
		}
		// Each row placed, said (its nodes gathered) only to an observer: the tests', the docs' demos.
		if (this.observer) {
			for (let index = placed.length - 1; index >= 0; index--) {
				const row = placed[index];
				this.notify("row", { what: row.fresh ? "made" : "moved", key: row.key, nodes: inside(row.range) });
			}
		}
		for (const row of order) row.fresh = false;
	}

	/** A row goes: at once, or (`animated`, its key gone from the list) once the transitions out of
	 * what is in it are over. Inside a part that is leaving, it stays, to go with the part; with
	 * `remove` false its nodes stay for the caller to take off with the others' (`clearRange`). */
	dropRow(list, row, animated = false, remove = true) {
		this.notify("row", { what: "dropped", key: row.key, nodes: [] });
		const outs = animated && !this.keeping ? this.transitioned(row.range, "out") : [];
		if (outs.length) this.keep(() => this.dispose(row.computation));
		else this.dispose(row.computation);
		this.ex.release(this.kept.get(row.runner));
		this.kept.delete(row.runner);
		list.indexes.delete(row.key);
		if (outs.length) this.leave(row.range, outs);
		else if (!this.keeping && remove) removeRange(row.range);
	}

	/** A `.map`'s rows go: its rows, and its items. Its id stays: what made it still names it, and may
	 * build it again (an <Errored> trying again). */
	dropList(list) {
		for (const row of list.rows.values()) this.dropRow(list, row);
		for (const item of list.items.values()) this.ex.release(item.value);
		list.items.clear();
		list.rows.clear();
	}

	// ---- Transitions ----

	/** An element's transition (`way`: "in", "out", "both" or "move"), from the markup or a
	 * computation. One that moves is among the elements a change of the page measures. */
	setTransition(element, way, spec) {
		let own = this.transitions.get(element);
		if (!own) this.transitions.set(element, (own = { in: null, out: null, move: null }));
		if (way === "move") {
			own.move = spec;
			this.gliders.add(element);
			return;
		}
		if (way !== "out") own.in = spec;
		if (way !== "in") own.out = spec;
		this.animates = true;
	}

	/**
	 * The elements in a range with a transition `way` ("in" or "out"), each with it: `[[element,
	 * spec]]`. The <Show>s and <For>s in it are passed over, as is a part already leaving: theirs
	 * play when they come or go themselves, as Svelte's transitions are local.
	 */
	transitioned(range, way) {
		const found = [];
		if (!this.animates) return found;
		const visit = (first, end) => {
			let depth = 0;
			for (let node = first; node && node !== end; node = node.nextSibling) {
				if (node.nodeType === 8) {
					if (OWN_PARTS.has(node.data)) depth++;
					else if (depth > 0 && OWN_PARTS.has(node.data.slice(1)) && node.data.startsWith("/")) depth--;
					continue;
				}
				if (depth > 0 || node.nodeType !== 1) continue;
				const spec = this.transitions.get(node)?.[way];
				if (spec) found.push([node, spec]);
				if (node.firstChild) visit(node.firstChild, null);
			}
		};
		visit(range.start.nextSibling, range.end);
		return found;
	}

	/** Runs `release` (disposing a part that is leaving) with what is inside it kept on the page. */
	keep(release) {
		const keeping = this.keeping;
		this.keeping = true;
		try {
			release();
		} finally {
			this.keeping = keeping;
		}
	}

	/** A row or part that came: its transitions in play once this flush's changes are on the page. */
	entered(range) {
		for (const entry of this.transitioned(range, "in")) this.entering.push(entry);
	}

	playEntering() {
		const entering = this.entering;
		this.entering = [];
		for (const [element, spec] of entering) if (element.isConnected) this.play(element, spec, "in");
	}

	/**
	 * A row or part going, with transitions out (`outs`): it stays where it is, inert and hidden from
	 * screen readers, its holes no longer running, until they are over; then it is taken away. Should
	 * they never end (a tab in the background runs no animations), it goes a second after they would.
	 */
	leave(range, outs) {
		range.start.data = "leaving";
		range.end.data = "/leaving";
		this.leaving.set(range.start, range);
		for (const node of inside(range)) {
			this.leavingNodes.set(node, range);
			if (node.nodeType !== 1) continue;
			node.setAttribute("inert", "");
			node.setAttribute("aria-hidden", "true");
			node.style?.setProperty("pointer-events", "none");
		}
		let gone = false;
		const go = () => {
			if (gone) return;
			gone = true;
			this.leaving.delete(range.start);
			removeRange(range);
		};
		// Gone at once (an element in it moved elsewhere: `glide`), its transitions out stopped.
		range.finish = () => {
			for (const animation of playing) animation.cancel();
			go();
		};
		const playing = outs.map(([element, spec]) => this.play(element, spec, "out")).filter(Boolean);
		if (!playing.length) return go();
		Promise.all(playing.map((animation) => animation.finished.catch(() => {}))).then(go);
		setTimeout(go, Math.max(...outs.map(([, spec]) => spec.ms + spec.delay)) + 1000);
	}

	/**
	 * Plays a transition: coming (`in`), from the element's hidden style to its own; going (`out`),
	 * the same backwards, ending hidden. None for someone who asked for less motion, or in a browser
	 * without `element.animate`.
	 */
	play(element, spec, way) {
		if (typeof element.animate !== "function" || reducedMotion()) return null;
		const fixed = {};
		if (spec.origin) fixed.transformOrigin = spec.origin;
		// Inside an <svg>, an origin is the element's own box's, as it is outside one.
		if (element.namespaceURI === SVG) fixed.transformBox = "fill-box";
		const hidden = { ...fixed };
		for (const [property, value] of spec.h) hidden[property.startsWith("--") ? property : camel(property)] = value;
		try {
			return element.animate([{ ...hidden, offset: 0 }, { ...fixed, offset: 1 }], {
				duration: spec.ms,
				delay: spec.delay,
				easing: spec.easing || "ease-out",
				direction: way === "out" ? "reverse" : "normal",
				fill: way === "out" ? "forwards" : "backwards",
			});
		} catch {
			// An easing the browser doesn't know: no animation, rather than an error.
			return null;
		}
	}

	// ---- Moves ----

	/**
	 * Before a flush first changes what the page shows (a row comes, goes or moves; a part
	 * switches; a hole's markup is made anew): where each element that glides (`transition:move`) is
	 * on the screen. Once a flush, and only in one: hydrating and mounting move nothing.
	 */
	measure() {
		if (this.measured || !this.inFlush || !this.gliders.size || typeof document === "undefined") return;
		const still = reducedMotion();
		this.measured = new Map();
		this.measuredIn = new Map();
		for (const element of this.gliders) {
			if (!element.isConnected) continue;
			this.measured.set(element, still ? null : element.getBoundingClientRect());
			// One lifted now is in nothing that clips it: moved again, it glides on above the page.
			this.measuredIn.set(element, this.lifted.has(element) ? null : element.parentElement);
		}
	}

	/** The range on its way out (`leave`) an element is in, if it is. */
	leavingRangeOf(element) {
		for (let node = element; node; node = node.parentNode) {
			const range = this.leavingNodes.get(node);
			if (range) return range;
		}
		return null;
	}

	/**
	 * Once the flush is done: each element that glides and moved, as it was measured before and as
	 * it is now, plays its move backwards from where it was (FLIP), with `translate`, so its own
	 * transform stays its own. An element with a key (`key={…}`) that came as one with the same key
	 * went (taken out of one list and put in another; a part switched) is that one moved: it glides
	 * from the other's place, plays no transition in, and the other, if it was on its way out, goes
	 * at once. One inside another that glides moves with it. Nothing glides for someone who asked
	 * for less motion; an element taken off the page is forgotten. One that glides from another box
	 * that scrolls or clips (a card into another column's list), where what clips it now would hide
	 * where it was, glides above the page (`lift`), so nothing cuts it off on its way.
	 */
	glide() {
		const before = this.measured;
		const parents = this.measuredIn;
		this.measured = this.measuredIn = null;
		const still = reducedMotion();
		// The ones that went (taken away, or on their way out), by key: where they were.
		const went = new Map();
		for (const [element, box] of before) {
			if (!box || (element.isConnected && !this.leavingRangeOf(element))) continue;
			const key = this.keys.get(element);
			if (key !== undefined) went.set(key, { element, box });
		}
		const moves = [];
		// Where each came from, when that is another element (a keyed pair's): what it was in.
		const origins = new Map();
		for (const element of this.gliders) {
			if (!element.isConnected) {
				// Taken off the page (not waiting in a fragment, as what a <Loading> holds does).
				if (element.getRootNode().nodeType !== 11) this.gliders.delete(element);
				continue;
			}
			if (still || this.leavingRangeOf(element)) continue;
			let box = before.get(element);
			if (box === undefined) {
				const key = this.keys.get(element);
				const pair = key === undefined ? undefined : went.get(key);
				if (!pair) continue;
				went.delete(key);
				box = pair.box;
				origins.set(element, pair.element);
				this.entering = this.entering.filter(([entering]) => entering !== element);
				this.leavingRangeOf(pair.element)?.finish();
			}
			if (box) moves.push([element, box]);
		}
		if (!moves.length) return;
		// Glides playing stop (one lifted is put back), then every box is read at once: one layout.
		for (const [element] of moves) {
			this.glides.get(element)?.cancel();
			this.lifted.get(element)?.();
		}
		const boxes = moves.map(([element]) => element.getBoundingClientRect());
		const moving = new Map();
		moves.forEach(([element, box], index) => {
			const to = boxes[index];
			const dx = box.left - to.left;
			const dy = box.top - to.top;
			const resized = Math.abs(box.width - to.width) >= 0.5 || Math.abs(box.height - to.height) >= 0.5;
			if (Math.abs(dx) >= 0.5 || Math.abs(dy) >= 0.5 || resized) moving.set(element, { dx, dy, resized, from: box, to });
		});
		const clips = new Map();
		for (const [element, { dx, dy, resized, from, to }] of moving) {
			let carried = false;
			for (let parent = element.parentElement; parent && !carried; parent = parent.parentElement) carried = moving.has(parent);
			if (carried || typeof element.animate !== "function") continue;
			const spec = this.transitions.get(element)?.move ?? {};
			const was = parents.get(origins.get(element) ?? element);
			const lifted = this.crosses(element, from, was, clips) ? this.lift(element, to) : null;
			try {
				const animation = element.animate(this.glideFrames(element, from, to, resized, lifted ? { was, clips } : null), {
					duration: spec.ms ?? 250,
					delay: spec.delay ?? 0,
					easing: spec.easing || "ease-out",
					fill: "backwards",
				});
				this.glides.set(element, animation);
				animation.finished.then(
					() => {
						lifted?.();
						if (this.glides.get(element) === animation) this.glides.delete(element);
					},
					() => lifted?.(),
				);
				this.notify("glide", { node: element, dx, dy, width: from.width / (to.width || 1), height: from.height / (to.height || 1), key: this.keys.get(element), lifted: Boolean(lifted) });
			} catch {
				// An easing the browser doesn't know: no glide, rather than an error.
				lifted?.();
			}
		}
	}

	/**
	 * A glide's two frames (FLIP): from where the element was (`from`) to where it is (`to`), with
	 * `translate`, and, when its size changed (`resized`), `scale` too, from its old size to its new
	 * one, about its own `transform-origin`, so its old box is exactly where it starts; its own
	 * `transform` stays its own. What is inside is scaled with it as it glides (FLIP's way: a card
	 * put in a narrower column is drawn narrower from the start, its text squeezed for the glide,
	 * rather than laid out again each frame). One lifted above the page (`lifted`: what it was in, and
	 * the glide's clips) is clipped as the boxes it leaves and lands in clip it (`clip-path`): from
	 * what showed of it where it was to what will show of it where it lands, so one whose place is
	 * scrolled out of sight slides under its new box's edge, rather than over it.
	 */
	glideFrames(element, from, to, resized, lifted) {
		let sx = 1;
		let sy = 1;
		let ox = 0;
		let oy = 0;
		if (resized && to.width > 0 && to.height > 0) {
			sx = from.width / to.width;
			sy = from.height / to.height;
			[ox, oy] = getComputedStyle(element).transformOrigin.split(" ").map((each) => parseFloat(each) || 0);
		}
		// A point of the element, `p` from its box's corner, is drawn at `origin + s·(p − origin) + t`:
		// its corner at `from`'s when `t` is this.
		const tx = from.left - to.left - ox * (1 - sx);
		const ty = from.top - to.top - oy * (1 - sy);
		const first = { translate: `${tx}px ${ty}px` };
		const last = { translate: "0px 0px" };
		if (sx !== 1 || sy !== 1) {
			first.scale = `${sx} ${sy}`;
			last.scale = "1 1";
		}
		if (lifted) {
			// What of a box shows inside a clip, as insets in the element's own pixels (scaled by `s`).
			const shown = (box, clip, sx, sy) =>
				clip ? [Math.max(0, clip.top - box.top) / sy, Math.max(0, box.right - clip.right) / sx, Math.max(0, box.bottom - clip.bottom) / sy, Math.max(0, clip.left - box.left) / sx] : [0, 0, 0, 0];
			const before = shown(from, lifted.was?.isConnected ? this.clipping(lifted.was, lifted.clips)?.rect : null, sx, sy);
			const after = shown(to, this.clipping(element.parentElement, lifted.clips)?.rect, 1, 1);
			if ([...before, ...after].some((inset) => inset > 0)) {
				first.clipPath = `inset(${before.map((inset) => `${inset}px`).join(" ")})`;
				last.clipPath = `inset(${after.map((inset) => `${inset}px`).join(" ")})`;
			}
		}
		return [first, last];
	}

	/**
	 * What clips what is in `node` (`node` itself, then its ancestors): the boxes that scroll or clip
	 * (`overflow` other than `visible`, `contain: paint`), their boxes on the screen intersected
	 * (`rect`), and the nearest of them (`box`); none when nothing does (the page's own scrolling
	 * clips nothing here). Kept in `clips` for one glide, which reads each ancestor's style once.
	 */
	clipping(node, clips) {
		if (!node || node.nodeType !== 1 || node === this.page.documentElement || node === this.page.body) return null;
		if (clips.has(node)) return clips.get(node);
		const outer = this.clipping(node.parentElement, clips);
		const style = getComputedStyle(node);
		let found = outer;
		if (style.overflowX !== "visible" || style.overflowY !== "visible" || /paint|strict|content/.test(style.contain)) {
			const own = node.getBoundingClientRect();
			const rect = outer ? { left: Math.max(own.left, outer.rect.left), top: Math.max(own.top, outer.rect.top), right: Math.min(own.right, outer.rect.right), bottom: Math.min(own.bottom, outer.rect.bottom) } : own;
			found = { box: node, rect };
		}
		clips.set(node, found);
		return found;
	}

	/**
	 * Whether a glide from `from` (where it was, in `was`, its parent then, or none when it was lifted
	 * already) to where `element` is now would be cut off: what clips it now hides some of where it
	 * was, and that is another box than the one it was in (in the same box, a row coming from where
	 * the list is scrolled away comes in from its edge, as it would). Cheap when nothing clips the
	 * element: one walk up, styles cached.
	 */
	crosses(element, from, was, clips) {
		if (!(element instanceof HTMLElement)) return false;
		const now = this.clipping(element.parentElement, clips);
		if (!now) return false;
		const { rect } = now;
		if (from.left >= rect.left - 0.5 && from.top >= rect.top - 0.5 && from.right <= rect.right + 0.5 && from.bottom <= rect.bottom + 0.5) return false;
		return !was?.isConnected || this.clipping(was, clips)?.box !== now.box;
	}

	/**
	 * Lifts an element out of what clips it, for its glide: fixed where it now is (`to`), above the
	 * page, with a stand-in of its size where it is in the page, so nothing around it moves. It stays
	 * where it is in the document, so its styles and handlers are its own. Inside a box that makes
	 * fixed elements its own (a `transform`, a `filter`, `contain: paint`: `holdsFixed`), fixed isn't
	 * above the page, so it goes to the top layer instead (a manual popover, `showPopover`), which no
	 * box clips or holds, its own look kept over the popover's (`POPOVER_LOOK`); and where the browser
	 * has no popovers, it is put where it is seen to be, inside that box. Answers how to put it back
	 * (once its glide ends, or another one starts), its own styles as they were.
	 */
	lift(element, to) {
		const style = getComputedStyle(element);
		const width = element.offsetWidth;
		const height = element.offsetHeight;
		const holder = this.page.createElement(element.localName);
		holder.setAttribute("aria-hidden", "true");
		holder.setAttribute("data-rocx-lifted", "");
		const display = style.display === "inline" ? "inline-block" : style.display;
		holder.style.cssText = `display: ${display}; box-sizing: border-box; width: ${width}px; height: ${height}px; margin: ${style.marginTop} ${style.marginRight} ${style.marginBottom} ${style.marginLeft}; padding: 0; border: 0; flex: none; grid-area: ${style.gridArea}; visibility: hidden; list-style: none`;
		element.before(holder);
		const fixed = { position: "fixed", left: `${to.left}px`, top: `${to.top}px`, right: "auto", bottom: "auto", width: `${width}px`, height: `${height}px`, margin: "0px", "max-width": "none", "max-height": "none", "box-sizing": "border-box", "z-index": "2147483647" };
		const layered = this.holdsFixed(element) && typeof element.showPopover === "function" && !element.hasAttribute("popover");
		// The look the popover's own styles would change, as it is now.
		if (layered) for (const name of POPOVER_LOOK) fixed[name] = style.getPropertyValue(name);
		const own = Object.keys(fixed).map((name) => [name, element.style.getPropertyValue(name), element.style.getPropertyPriority(name)]);
		for (const [name, value] of Object.entries(fixed)) element.style.setProperty(name, value, "important");
		if (layered) {
			element.setAttribute("popover", "manual");
			element.showPopover();
		} else {
			// Fixed inside a box that holds it is placed from that box: put where it is seen to be.
			const seen = element.getBoundingClientRect();
			if (Math.abs(seen.left - to.left) >= 0.5 || Math.abs(seen.top - to.top) >= 0.5) {
				element.style.setProperty("left", `${2 * to.left - seen.left}px`, "important");
				element.style.setProperty("top", `${2 * to.top - seen.top}px`, "important");
			}
		}
		let back = false;
		const putBack = () => {
			if (back) return;
			back = true;
			if (this.lifted.get(element) === putBack) this.lifted.delete(element);
			holder.remove();
			if (layered) {
				if (element.matches(":popover-open")) element.hidePopover();
				element.removeAttribute("popover");
			}
			for (const [name, value, priority] of own) {
				if (value) element.style.setProperty(name, value, priority);
				else element.style.removeProperty(name);
			}
		};
		this.lifted.set(element, putBack);
		return putBack;
	}

	/** Whether a box around `element` makes fixed elements its own (their place and their clip):
	 * a `transform`, `translate`, `scale`, `rotate`, `perspective`, `filter` or `backdrop-filter`,
	 * `contain` with layout or paint, a container query's box, or `will-change` saying one is coming. */
	holdsFixed(element) {
		for (let node = element.parentElement; node && node !== this.page.documentElement; node = node.parentElement) {
			const style = getComputedStyle(node);
			if (style.transform !== "none" || (style.translate && style.translate !== "none") || (style.scale && style.scale !== "none") || (style.rotate && style.rotate !== "none") || style.perspective !== "none") return true;
			if (style.filter !== "none" || (style.backdropFilter && style.backdropFilter !== "none")) return true;
			if (/layout|paint|strict|content/.test(style.contain) || (style.containerType && style.containerType !== "normal")) return true;
			if (/transform|perspective|filter|translate|scale|rotate/.test(style.willChange)) return true;
		}
		return false;
	}

	// ---- The DOM ----

	/** A node of the markup's JSON as DOM; its computations owned by `owner`. */
	build(node, owner, scope) {
		switch (node.t) {
			case "s":
			case "raw":
				return document.createTextNode(node.v);
			case "doctype":
				// Only a document has one: rendering again, the page's stays.
				return document.createDocumentFragment();
			case "x": {
				const text = document.createTextNode("");
				const computation = new Computation(this, { kind: "text", runner: this.kept.get(node.r), owner, scope, target: text });
				// Inside RCDATA, binding to the text the server wrote whole: not a patch.
				computation.adopting = Boolean(scope.rcdata);
				// Static (D-052): the text stays, and nothing will run its computation again.
				if (this.isStatic(computation, this.run(computation))) this.forget(computation, owner);
				return text;
			}
			case "h":
			case "l": {
				// Run before its range is made: a static one (D-052) is its nodes alone, as the server
				// writes it, its computation only the owner of what they hold.
				const computation = new Computation(this, { kind: "html", runner: this.kept.get(node.r), owner, scope, target: null });
				computation.peek = true;
				const outcome = this.run(computation);
				computation.peek = false;
				const nodes = computation.peeked;
				computation.peeked = null;
				if (this.isStatic(computation, outcome)) {
					const fragment = document.createDocumentFragment();
					for (const child of nodes) fragment.append(this.build(child, computation, scope));
					return fragment;
				}
				const range = makeRange(node.t === "h" ? "html" : "list");
				computation.target = range;
				if (nodes) {
					// Its first markup, as its run would have patched it in.
					this.stats.patches++;
					this.notify("patch", { kind: "html", name: null, node: range.start.parentNode });
					this.measure(); //#moves
					const fragment = document.createDocumentFragment();
					for (const child of nodes) fragment.append(this.build(child, computation, scope));
					range.end.before(fragment);
				}
				return range.fragment;
			}
			case "hx": {
				// A hole of either kind (D-070): run first; while it shows text alone, a text node it
				// patches, as a text hole's; markup, a range, as a markup hole's (and text that turns
				// into markup later turns into one).
				const computation = new Computation(this, { kind: "html", runner: this.kept.get(node.r), owner, scope, target: null });
				computation.hole = true;
				computation.peek = true;
				const outcome = this.run(computation);
				computation.peek = false;
				const nodes = computation.peeked;
				computation.peeked = null;
				const value = nodes ? loneText(nodes) : null;
				if (this.isStatic(computation, outcome)) {
					if (value !== null) {
						// Static (D-052) text, as a text hole's: written once (a patch, as its run would), and
						// its computation let go of.
						const text = document.createTextNode("");
						if (value !== "" && !scope.rcdata) {
							this.stats.patches++;
							this.notify("patch", { kind: "text", name: null, node: text });
						}
						text.data = value;
						this.forget(computation, owner);
						return text;
					}
					const fragment = document.createDocumentFragment();
					for (const child of nodes) fragment.append(this.build(child, computation, scope));
					return fragment;
				}
				if (value !== null) {
					const text = document.createTextNode("");
					computation.target = text;
					computation.text = true;
					// Inside RCDATA, the text the server wrote whole: not a patch.
					if (value !== "" && !scope.rcdata) {
						this.stats.patches++;
						this.notify("patch", { kind: "text", name: null, node: text });
					}
					text.data = value;
					return text;
				}
				const range = makeRange("html");
				computation.target = range;
				if (nodes) {
					this.stats.patches++;
					this.notify("patch", { kind: "html", name: null, node: range.start.parentNode });
					this.measure(); //#moves
					const fragment = document.createDocumentFragment();
					for (const child of nodes) fragment.append(this.build(child, computation, scope));
					range.end.before(fragment);
				}
				return range.fragment;
			}
			case "f": {
				const fragment = document.createDocumentFragment();
				for (const child of node.c) fragment.append(this.build(child, owner, scope));
				return fragment;
			}
			case "e":
				return this.element(node, owner, scope);
			case "tpl":
				// A template (D-084): its skeleton the first time, then a copy of it, its parts put in.
				if (node.k) this.templates[node.s] = this.skeleton(node.k, scope);
				return this.instantiate(this.templates[node.s], node.p, owner, scope);
			case "loading": {
				const loading = new Loading();
				loading.range = makeRange("loading");
				const inner = { ...scope, loading };
				loading.children = document.createDocumentFragment();
				for (const child of node.c) loading.children.append(this.build(child, owner, inner));
				loading.built = true;
				if (loading.waiting.size === 0) loading.reveal();
				else replaceRange(loading.range, this.build(node.fallback, owner, scope));
				return loading.range.fragment;
			}
			case "show":
			case "for": {
				const range = makeRange(node.t);
				const computation = new Computation(this, { kind: node.t, runner: this.kept.get(node.r), owner, scope, target: range });
				computation.node = node;
				if (node.t === "for") computation.list = this.lists.get(node.id);
				this.run(computation);
				return range.fragment;
			}
			case "errored": {
				const range = makeRange("errored");
				const errored = new Errored(this, { runner: this.kept.get(node.r), nodes: node.c, owner, scope, range });
				range.end.before(errored.build());
				return range.fragment;
			}
			case "c": {
				const { computation, nodes } = this.component(node, owner, scope);
				const fragment = document.createDocumentFragment();
				for (const child of nodes) fragment.append(this.build(child, computation, scope));
				return fragment;
			}
			case "ctx": {
				const fragment = document.createDocumentFragment();
				for (const child of node.c) fragment.append(this.build(child, owner, provided(scope, node)));
				return fragment;
			}
			case "nh":
				return this.region();
			case "listen":
				this.listenOn(node, owner, scope);
				return document.createDocumentFragment();
			default:
				throw new Error(`rocx: unknown node ${node.t}`);
		}
	}

	/**
	 * A `<NoHydration>` the browser makes: the server's, if a part the server rendered is being
	 * rendered again (`<body>` after a mismatch); otherwise there is nothing to make it
	 * from (the browser's copy hasn't what is inside), and it is empty.
	 */
	region() {
		const kept = this.keptRegions?.shift();
		if (kept) return kept;
		// A level made by a navigation inside a kept one: its regions come from the document after the
		// flush (`refreshRegions`, D-040).
		if (this.arriving) return makeRange("nohydration").fragment;
		console.warn("rocx: a <NoHydration> the server didn't render here is empty: what is inside is the server's, and the browser has no copy of it");
		return makeRange("nohydration").fragment;
	}

	/** Builds `root`'s part again with `build`, each `<NoHydration>` in it the server's (`serverRegions`). */
	keepingRegions(root, build) {
		const outer = this.keptRegions;
		this.keptRegions = serverRegions(root);
		try {
			return build();
		} finally {
			this.keptRegions = outer;
		}
	}

	element(given, owner, scope) {
		const node = writable(given, this);
		if (!node) return document.createDocumentFragment();
		const element = node.tag === "script" ? inertScript() : node.tag === "svg" || scope.svg ? document.createElementNS(SVG, node.tag) : document.createElement(node.tag);
		// Its classes in one `class`, first, as the server writes them.
		const classes = [];
		for (const [kind, name, value] of node.a) {
			if (name === "class" && (kind === "v" || (kind === "o" && value !== ""))) classes.push(value);
			else if (kind === "ci" && value) classes.push(name);
		}
		if (classes.length) element.setAttribute("class", classes.join(" "));
		for (const [kind, name, value] of node.a) {
			if (kind === "v" && name !== "class") element.setAttribute(name, this.written(name, value));
			else if (kind === "o" && value !== "" && name !== "class") element.setAttribute(name, this.written(name, value));
			else if (kind === "f") element.toggleAttribute(name, value);
			else if (kind === "sv" && value) element.style.setProperty(name, value);
		}
		this.bind(element, node, owner, scope);
		this.styled(element, node);
		Runtime.inOrder(element, node);
		if (node.tag === "a" && !ownsCurrent(node)) this.markLink(element);
		const inside = within(node, scope);
		for (const child of node.c) element.append(this.build(child, owner, inside));
		return element;
	}

	/**
	 * A template's skeleton (`Html.template`, D-084): its elements as `element` makes them with the
	 * attributes written in the file, its text, and an empty comment where each other child goes. Its
	 * slots, in the order its parts come: an element with attributes to put in (`node`, its list with
	 * `["?"]` where each goes), or a child's place; each by its path from the root.
	 */
	skeleton(node, scope) {
		const slots = [];
		const links = [];
		const root = this.skeletal(node, scope, [], slots, links);
		return { root, slots, links };
	}

	skeletal(node, scope, path, slots, links) {
		if (node.t === "s") return document.createTextNode(node.v);
		if (node.t !== "e") {
			slots.push({ path, svg: Boolean(scope.svg) });
			return document.createComment("");
		}
		const element = node.tag === "svg" || scope.svg ? document.createElementNS(SVG, node.tag) : document.createElement(node.tag);
		const written = { tag: node.tag, a: node.a.filter(([kind]) => kind !== "?"), c: [] };
		const classes = [];
		for (const [, name, value] of written.a) if (name === "class") classes.push(value);
		if (classes.length) element.setAttribute("class", classes.join(" "));
		for (const [, name, value] of written.a) if (name !== "class") element.setAttribute(name, this.written(name, value));
		Runtime.inOrder(element, written);
		if (written.a.length !== node.a.length) slots.push({ path, node });
		// A link, marked in each copy (D-086) unless its markup gives it an `aria-current`: its own
		// attributes', or its parts' (`slot`, the slot they are in).
		if (node.tag === "a") links.push({ path, own: ownsCurrent(written), slot: written.a.length !== node.a.length ? slots.length - 1 : -1 });
		const inside = within(node, scope);
		node.c.forEach((child, index) => element.append(this.skeletal(child, inside, [...path, index], slots, links)));
		return element;
	}

	/** A copy of a template's skeleton with a row's parts put in, in its slots' order (D-084): an
	 * element's attributes as `element` writes and binds them, a child as `build` makes it. */
	instantiate(template, parts, owner, scope) {
		const root = template.root.cloneNode(true);
		const { slots, links } = template;
		const find = (path) => {
			let found = root;
			for (const index of path) found = found.childNodes[index];
			return found;
		};
		// Every slot's node first: a part put in may be several nodes, which would move the paths after it.
		const nodes = new Array(slots.length);
		for (let i = 0; i < slots.length; i++) nodes[i] = find(slots[i].path);
		const linked = links.length ? links.map((link) => find(link.path)) : null;
		const filled = links.length ? new Array(slots.length) : null;
		let at = 0;
		for (let i = 0; i < slots.length; i++) {
			const slot = slots[i];
			if (slot.node) {
				let own = [];
				const a = slot.node.a.map((attr) => (attr[0] === "?" ? (own[own.length] = parts[at++]) : attr));
				// A part's name markup can't have (D-079) is left out, as `element` leaves it out.
				const node = writable({ tag: slot.node.tag, a, c: [] }, this);
				if (node.a !== a) own = own.filter((attr) => node.a.includes(attr));
				this.fill(nodes[i], node, own, owner, scope);
				if (filled) filled[i] = node;
			} else {
				nodes[i].replaceWith(this.build(parts[at++], owner, slot.svg && !scope.svg ? { ...scope, svg: true } : scope));
			}
		}
		if (linked) links.forEach((link, i) => !link.own && !(link.slot >= 0 && ownsCurrent(filled[link.slot])) && this.markLink(linked[i]));
		return root;
	}

	/** A skeleton's element given its other attributes (`own`; `node.a` all of them, in the markup's
	 * order): what `element` does with them, the ones written in the file already on it. */
	fill(element, node, own, owner, scope) {
		if (own.some(([kind, name]) => kind === "ci" || ((kind === "v" || kind === "o") && name === "class"))) {
			const classes = [];
			for (const [kind, name, value] of node.a) {
				if (name === "class" && (kind === "v" || (kind === "o" && value !== ""))) classes.push(value);
				else if (kind === "ci" && value) classes.push(name);
			}
			if (classes.length) element.setAttribute("class", classes.join(" "));
		}
		for (const [kind, name, value] of own) {
			if (kind === "v" && name !== "class") element.setAttribute(name, this.written(name, value));
			else if (kind === "o" && value !== "" && name !== "class") element.setAttribute(name, this.written(name, value));
			else if (kind === "f") element.toggleAttribute(name, value);
			else if (kind === "sv" && value) element.style.setProperty(name, value);
		}
		this.bind(element, node, owner, scope);
		this.styled(element, node);
		Runtime.inOrder(element, node);
	}

	/** An element the runtime made, its `class` and `style` written as the server writes them
	 * (signals.rs's): its classes in the markup's order, a `class:name` that holds among the static
	 * ones where it is written; its static style, then each `style:name`'s `name: value`, in the
	 * markup's order, joined by `; `, not reserialized by the CSSOM (`--x: 1;`, `3.6e+06px`). */
	/** An element's `class` as the server writes it (signals.rs's), in its markup's order: its own
	 * `class` (written, or computed: the value it last had; an optional one when it isn't ""), each
	 * `class:name` that is on; then any
	 * others (a page script's), so an element a navigation kept, whose class a hole turned on, is the
	 * element a load renders (D-040), not the class added at the end. `old` is the computed `class`'s
	 * value before this one: its names aren't another's. */
	wholeClass(element, attrs, old = "") {
		const toggles = this.classToggles.get(element);
		const ordered = [];
		const ours = new Set(words(old));
		for (const [kind, name, value] of attrs) {
			if (name === "class" && (kind === "v" || kind === "o" || kind === "vo" || kind === "oo")) {
				const own = kind === "v" || kind === "o" ? value : (this.computedClasses.get(element) ?? "");
				for (const word of words(own)) ours.add(word);
				if (kind === "v" || kind === "vo" || own !== "") ordered.push(own);
			} else if (kind === "ci" || kind === "co") {
				ours.add(name);
				if (kind === "ci" ? value : (toggles?.get(name) ?? element.classList.contains(name))) ordered.push(name);
			}
		}
		return [...ordered, ...[...element.classList].filter((name) => !ours.has(name))].join(" ");
	}

	/** An element's `style` as the server writes it, in its markup's order: its own `style` (written,
	 * or computed: the value it last had), then each `style:name`'s `name: value`, as Roc gave it,
	 * joined by `; `, not reserialized by the CSSOM (`--x: 1;`, `3.6e+06px`). A `style:name` that
	 * hasn't run yet has the element's value. */
	wholeStyle(element, attrs) {
		const raw = this.rawStyles.get(element);
		const parts = [];
		for (const [kind, name, value] of attrs) {
			if (kind === "v" && name === "style") parts.push(value);
			else if (name === "style" && (kind === "o" || kind === "vo" || kind === "oo")) {
				const own = kind === "o" ? value : (this.computedStyles.get(element) ?? "");
				if (kind === "vo" || own !== "") parts.push(own);
			} else if (kind === "sv" && value) parts.push(`${name}: ${value}`);
			else if (kind === "so") {
				// One that hasn't run yet (hydrating, written after the computed style): the page's.
				const held = raw?.has(name) ? raw.get(name) : element.style.getPropertyValue(name).trim();
				if (held) parts.push(`${name}: ${held}`);
			}
		}
		return parts.join("; ");
	}

	/** Writes an element's `class` or `style` whole (`attribute`; none when it is ""), unless it is
	 * already: a patch of the hole `kind` `name`'s. */
	writeWhole(element, attribute, whole, kind, name) {
		if ((element.getAttribute(attribute) ?? "") === whole) return;
		if (kind) {
			this.stats.patches++;
			this.notify("patch", { kind, name, node: element });
		}
		if (whole === "") element.removeAttribute(attribute);
		else element.setAttribute(attribute, whole);
	}

	styled(element, node) {
		if (node.a.some(([kind]) => kind === "co")) this.writeWhole(element, "class", this.wholeClass(element, node.a));
		if (node.a.some(([kind]) => kind === "sv" || kind === "so")) this.writeWhole(element, "style", this.wholeStyle(element, node.a));
	}

	/**
	 * An element the runtime made, its attributes in the order the server writes them
	 * (signals.rs's): `class` first, then the others in the markup's order, the holes' among them,
	 * `style` last. Its holes set theirs after its static ones, so one with a hole between two static
	 * attributes is put in order; an element that is already (most) isn't touched.
	 */
	static inOrder(element, node) {
		if (!node.a.some(([kind]) => kind === "vo" || kind === "oo" || kind === "fo" || kind === "so" || kind === "sv" || (kind === "v" && node.a.length > 1))) return;
		const order = ["class"];
		for (const [kind, name] of node.a) {
			if ((kind === "v" || kind === "o" || kind === "oo" || kind === "f" || kind === "vo" || kind === "fo") && name !== "class" && name !== "style" && !order.includes(name)) order.push(name);
		}
		order.push("style");
		const have = element.getAttributeNames().filter((name) => order.includes(name));
		const wanted = order.filter((name) => have.includes(name));
		if (have.every((name, at) => name === wanted[at])) return;
		for (const name of wanted) {
			const value = element.getAttribute(name);
			element.removeAttribute(name);
			element.setAttribute(name, value);
		}
	}

	/**
	 * Hydrating an RCDATA element (`<title>`, `<textarea>`) with holes in it: the server wrote its
	 * text whole, with no comments, so its holes are bound to text nodes made here, in its place. Its
	 * text is the server's, or it is a mismatch.
	 */
	adoptText(element, node, owner, scope) {
		const server = element.textContent;
		const fragment = document.createDocumentFragment();
		for (const child of node.c) fragment.append(this.build(child, owner, { ...scope, rcdata: true }));
		element.replaceChildren(fragment);
		if (element.textContent !== server) throw new Mismatch(`<${node.tag}> says ${JSON.stringify(server)}, not ${JSON.stringify(element.textContent)}`);
	}

	/** Hydrating: binds `node`'s computations to the DOM the server rendered for it, from `cursor`. */
	adopt(node, owner, scope, cursor) {
		switch (node.t) {
			case "s": {
				if (!node.v) return;
				// Before `<html>` and `<head>` the parser drops whitespace (and puts what follows
				// `</body>` in it): the page may not have the markup's there.
				if (cursor.top && blank(node.v) && !(cursor.node?.nodeType === 3 && cursor.node.data.startsWith(node.v))) return;
				const text = cursor.take((found) => found.nodeType === 3 && found.data.startsWith(node.v), JSON.stringify(node.v));
				// The parser joins neighbouring text: split what belongs to the next node off.
				if (text.data.length > node.v.length) cursor.node = text.splitText(node.v.length);
				return;
			}
			case "raw":
				// A <script>'s or <style>'s text, as the .rocx file has it: taken, not compared.
				if (cursor.node?.nodeType === 3) cursor.node = cursor.node.nextSibling;
				return;
			case "doctype":
				// The parser keeps a doctype only at the top of a document; anywhere else it drops it.
				if (cursor.node?.nodeType === 10) cursor.node = cursor.node.nextSibling;
				return;
			case "x": {
				// Run first, on a text of its own: a static hole (D-052) is text the server wrote without
				// comments, taken as a text node is; any other is the text between its comments.
				const computation = new Computation(this, { kind: "text", runner: this.kept.get(node.r), owner, scope, target: document.createTextNode("") });
				computation.adopting = true;
				const outcome = this.run(computation);
				const value = computation.target.data;
				if (this.isStatic(computation, outcome)) {
					this.forget(computation, owner);
					return this.adopt({ t: "s", v: value }, owner, scope, cursor);
				}
				cursor.comment("x");
				let text = cursor.node?.nodeType === 3 ? cursor.take(() => true, "text") : null;
				const end = cursor.comment("/x");
				if (!text) end.before((text = document.createTextNode("")));
				computation.target = text;
				// Waiting (an answer the page didn't carry): its next run binds it, as hydrating.
				if (outcome !== "ok") return;
				computation.adopting = false;
				if (text.data !== value) {
					this.stats.patches++;
					this.notify("patch", { kind: "text", name: null, node: text });
					text.data = value;
				}
				return;
			}
			case "h":
			case "l": {
				const label = node.t === "h" ? "html" : "list";
				const computation = new Computation(this, { kind: "html", runner: this.kept.get(node.r), owner, scope, target: null });
				computation.peek = true;
				const outcome = this.run(computation);
				computation.peek = false;
				const nodes = computation.peeked;
				computation.peeked = null;
				if (this.isStatic(computation, outcome)) {
					// Static (D-052): its nodes, where the server wrote them without comments.
					for (const child of nodes) this.adopt(child, computation, scope, cursor);
					return;
				}
				const start = cursor.comment(label);
				const end = cursor.closing(label);
				computation.target = { start, end };
				if (nodes) {
					const inside = new Cursor(start.nextSibling);
					for (const child of nodes) this.adopt(child, computation, scope, inside);
					inside.end(end);
				} else computation.adopting = true;
				cursor.node = end.nextSibling;
				return;
			}
			case "hx": {
				// A hole of either kind (D-070): what the server wrote says which, `<!--x-->` (text alone)
				// or `<!--html-->` (markup); a static one is what it shows, without comments.
				const computation = new Computation(this, { kind: "html", runner: this.kept.get(node.r), owner, scope, target: null });
				computation.hole = true;
				computation.peek = true;
				const outcome = this.run(computation);
				computation.peek = false;
				const nodes = computation.peeked;
				computation.peeked = null;
				if (this.isStatic(computation, outcome)) {
					for (const child of nodes) this.adopt(child, computation, scope, cursor);
					return;
				}
				if (cursor.node?.nodeType === 8 && cursor.node.data === "x") {
					cursor.comment("x");
					let text = cursor.node?.nodeType === 3 ? cursor.take(() => true, "text") : null;
					const end = cursor.comment("/x");
					if (!text) end.before((text = document.createTextNode("")));
					computation.target = text;
					computation.text = true;
					// Waiting (an answer the page didn't carry): its next run binds it, as hydrating.
					computation.adopting = true;
					if (nodes) this.settleHoleText(computation, nodes);
					if (!computation.text) {
						// Markup, though the server wrote text: its range, as built.
						const fragment = document.createDocumentFragment();
						for (const child of nodes) fragment.append(this.build(child, computation, scope));
						replaceRange(computation.target, fragment);
					}
					return;
				}
				const start = cursor.comment("html");
				const end = cursor.closing("html");
				computation.target = { start, end };
				if (nodes) {
					const inside = new Cursor(start.nextSibling);
					for (const child of nodes) this.adopt(child, computation, scope, inside);
					inside.end(end);
				} else computation.adopting = true;
				cursor.node = end.nextSibling;
				return;
			}
			case "f":
				for (const child of node.c) this.adopt(child, owner, scope, cursor);
				return;
			case "e": {
				// What the server didn't write (D-079) isn't there to adopt.
				node = writable(node, this);
				if (!node) return;
				// The parser makes the `<head>` a document leaves out: an empty one is passed over.
				if (node.tag === "body" && cursor.top && cursor.node?.localName === "head" && !cursor.node.firstChild) cursor.node = cursor.node.nextSibling;
				const element = cursor.take((found) => found.nodeType === 1 && found.localName === node.tag, `<${node.tag}>`);
				this.bind(element, node, owner, scope);
				// A link the server marked (or didn't): the runtime's to mark from now on (D-086).
				if (node.tag === "a" && !ownsCurrent(node)) this.markLink(element);
				const inner = within(node, scope);
				if (RCDATA.has(node.tag) && node.c.some((child) => child.t !== "s" && child.t !== "raw")) return this.adoptText(element, node, owner, inner);
				if (cursor.rebuild && this.arriving && (node.tag === "html" || node.tag === "body")) Runtime.attributesFrom(element, node, node.tag === "html" ? this.arriving.documentElement : this.arriving.body);
				if (cursor.rebuild && node.tag === "head") {
					if (this.arriving?.head) this.reconcileHead(element, this.arriving.head); //#nav
					return this.keepHead(element, node, owner, inner);
				}
				if (cursor.rebuild && node.tag === "body") return this.renderBody(element, node, owner, inner);
				const inside = new Cursor(element.firstChild, element, cursor.rebuild && element === element.ownerDocument.documentElement);
				for (const child of node.c) this.adopt(child, owner, inner, inside);
				const left = inside.node && !inside.rebuild ? inside.left(node.tag === "body" && cursor.top) : null;
				if (left) throw new Mismatch(`<${node.tag}> has more than the server's markup says: ${named(left)}${placed(element)}`, left);
				return;
			}
			case "loading": {
				// The server rendered what is inside, everything in: already revealed.
				const loading = new Loading();
				loading.revealed = true;
				const start = cursor.comment("loading");
				const end = cursor.closing("loading");
				loading.range = { start, end };
				for (const child of node.c) this.adopt(child, owner, { ...scope, loading }, cursor);
				cursor.end(end);
				cursor.node = end.nextSibling;
				return;
			}
			case "show":
			case "for": {
				if (node.t === "show" && !(cursor.node?.nodeType === 8 && cursor.node.data === "show")) {
					// Static (D-052, D-070): its case read nothing that changes, and the server wrote its part
					// without comments; the part, adopted where it is, owned by what owns it.
					const holds = JSON.parse(this.once(node.r, owner, scope));
					if (!holds) return this.adopt(node.fallback, owner, scope, cursor);
					if (!node.with) {
						for (const child of node.c) this.adopt(child, owner, scope, cursor);
						return;
					}
					const made = new Computation(this, { kind: "html", runner: this.kept.get(node.with), owner, scope, target: null });
					made.untracked = true;
					made.choosing = Boolean(node.b);
					made.peek = true;
					this.run(made);
					made.peek = false;
					const nodes = made.peeked ?? [];
					made.peeked = null;
					for (const child of nodes) this.adopt(child, made, scope, cursor);
					return;
				}
				const start = cursor.comment(node.t);
				const end = cursor.closing(node.t);
				const computation = new Computation(this, { kind: node.t, runner: this.kept.get(node.r), owner, scope, target: { start, end } });
				computation.node = node;
				if (node.t === "for") computation.list = this.lists.get(node.id);
				computation.adopting = true;
				this.run(computation);
				cursor.node = end.nextSibling;
				return;
			}
			case "c": {
				const { computation, nodes } = this.component(node, owner, scope);
				for (const child of nodes) this.adopt(child, computation, scope, cursor);
				return;
			}
			case "ctx":
				for (const child of node.c) this.adopt(child, owner, provided(scope, node), cursor);
				return;
			case "nh":
				// The server's, left as it is: never built, adopted or patched.
				cursor.comment("nohydration");
				cursor.node = cursor.closing("nohydration").nextSibling;
				return;
			case "listen":
				// Nothing on the page: its handlers, on the document or the window.
				this.listenOn(node, owner, scope);
				return;
			case "errored": {
				const failed = cursor.node?.nodeType === 8 && cursor.node.data === "errored:failed";
				const start = cursor.comment(failed ? "errored:failed" : "errored");
				const end = cursor.closing("errored");
				const errored = new Errored(this, { runner: this.kept.get(node.r), nodes: node.c, owner, scope, range: { start, end } });
				// Failed on the server: the browser tries what is inside again.
				if (failed) replaceRange(errored.range, errored.build());
				else {
					errored.adopt(cursor);
					cursor.end(end);
				}
				cursor.node = end.nextSibling;
				return;
			}
			default:
				throw new Mismatch(`unknown node ${node.t}`);
		}
	}

	/** Reads, and takes out, what the server put in the page for the browser: the answers its server
	 * functions gave, and the flash it read (`Server.flash!`). */
	seed(page) {
		const script = page.querySelector("script.rocx-answers");
		for (const [name, input, answer] of script ? JSON.parse(script.textContent) : []) this.answers.set(`${name}\n${input}`, answer);
		script?.remove();
		const flash = page.querySelector("script.rocx-flash");
		if (flash) this.flash = JSON.parse(flash.textContent);
		flash?.remove();
	}

	/**
	 * Hydrates the app the server rendered in `container`: reads the answers it put in the page
	 * (the GETs its reads made), then binds every computation to the server's nodes, running
	 * each once. If the DOM isn't what the markup says, it renders the app again, and says so.
	 * `strict` (the tests') throws if hydrating asked the server for anything the page didn't carry.
	 */
	hydrate(container, { strict = false } = {}) {
		this.seed(container);
		const seeded = new Map(this.answers);
		const hydrating = (this.hydrating = { asked: [] });
		const start = [...container.childNodes].find((node) => node.nodeType === 8 && node.data === "app");
		const end = [...container.childNodes].find((node) => node.nodeType === 8 && node.data === "/app");
		this.root = new Computation(this, { kind: "root", owner: null, scope: {}, target: { start, end } });
		this.root.adopting = true;
		foreignKept = !strict;
		try {
			if (!start || !end) throw new Mismatch("no <!--app--> in the page");
			this.run(this.root);
		} catch (error) {
			if (!(error instanceof Mismatch)) throw error;
			this.mismatched(error, "rendering it again");
			this.dispose(this.root);
			// Rendering again, the server's answers are still the ones to read, and its regions stay.
			this.answers = seeded;
			this.keepingRegions(container, () => {
				container.replaceChildren();
				this.mount(container);
			});
		}
		this.answers.clear();
		this.hydrating = null;
		if (strict && hydrating.asked.length) throw Runtime.askedAgain(hydrating.asked);
	}

	/**
	 * Says that the page isn't what the app renders (D-112): on the console, with the node that isn't
	 * (inspectable there, even once rendering again took it out of the page), and as `rocx:mismatch`
	 * on the document, `{ message, node }`, for an app's error reporting to send (packages/posthog's
	 * page script does). Elements an extension put straight in `<html>`, `<head>` or `<body>` aren't
	 * a mismatch: hydrating passes over them (`Cursor.foreign`).
	 */
	mismatched(error, then) {
		console.warn(`rocx: the page isn't what the app renders (${error.message}); ${then}`, ...(error.found ? [error.found] : []));
		globalThis.document?.dispatchEvent(new CustomEvent("rocx:mismatch", { bubbles: true, detail: { message: error.message, node: error.found } }));
	}

	/** What strict hydration throws when hydrating asked the server for what the page didn't carry. */
	static askedAgain(asked) {
		return new Error(`rocx: hydrating, the page asked the server again for ${asked.join(", ")}: the server didn't note it as it rendered the page`);
	}

	/**
	 * Hydrates the document the server rendered (start.js calls it): reads and removes the answers
	 * the server put in the page, runs the app's root (`main!`) once, and binds every computation to
	 * the server's nodes, from `document.childNodes` down: the doctype to the DocumentType node,
	 * `<html>` to `documentElement`, passing over the host's elements (`[data-rocx]`). If the page
	 * isn't what the app renders (an extension added a node; the parser repaired the markup), it says
	 * so and renders `<body>`'s children again, from the same answers, leaving `<head>` alone, since
	 * rendering it again would run its scripts again and flash its styles. `strict` (the tests')
	 * throws instead; and throws if hydrating asked the server for anything the page didn't carry
	 * (an endpoint's GET), which the server should have answered as it
	 * rendered the page.
	 */
	hydrateDocument(doc = document, { strict = false } = {}) {
		this.page = doc;
		this.strict = strict;
		this.committed = this.here();
		this.seed(doc);
		const seeded = new Map(this.answers);
		const root = () => new Computation(this, { kind: "root", owner: null, scope: {}, target: { document: doc } });
		this.root = root();
		this.root.adopting = true;
		const hydrating = (this.hydrating = { asked: [] });
		const askedAgain = () => Runtime.askedAgain(hydrating.asked);
		foreignKept = !strict;
		try {
			this.run(this.root);
			if (strict && hydrating.asked.length) throw askedAgain();
		} catch (error) {
			if (!(error instanceof Mismatch)) throw error;
			this.dispose(this.root);
			if (strict && hydrating.asked.length) throw askedAgain();
			if (strict) throw new Error(`rocx: the page isn't what the app renders (${error.message})`);
			this.mismatched(error, "rendering <body> again");
			// Rendering again, the server's answers are still the ones to read.
			this.answers = seeded;
			this.root = root();
			try {
				this.run(this.root);
			} catch (again) {
				if (again instanceof Mismatch) throw new Error(`rocx: the page can't be rendered again (${again.message})`);
				throw again;
			}
		} finally {
			this.answers.clear();
			this.hydrating = null;
		}
		// The app's pages, from here on, navigated to in place (D-040).
		this.listenForNavigation(); //#nav
	}

	/**
	 * A document app's root, settled: hydrating, its markup bound to the document's nodes; rendering
	 * again (after a mismatch, or when the root runs again), `<head>` kept and `<body>`'s children
	 * made anew.
	 */
	settleDocument(computation, parsed) {
		const rebuild = !computation.adopting;
		computation.adopting = false;
		const doc = computation.target.document;
		const cursor = new Cursor(doc.firstChild, doc, rebuild);
		for (const node of Array.isArray(parsed) ? parsed : [parsed]) this.adopt(node, computation, computation.scope, cursor);
	}

	/**
	 * Rendering a page again: `<head>` stays as the server sent it. Its computations are bound to it
	 * if it is what the app renders; if not, to a copy nobody sees.
	 */
	keepHead(head, node, owner, scope) {
		const part = new Computation(this, { kind: "boundary", owner, scope });
		try {
			const cursor = new Cursor(head.firstChild, head);
			for (const child of node.c) this.adopt(child, part, scope, cursor);
			const left = cursor.node && cursor.left(false);
			if (left) throw new Mismatch(`<head> has more than the server's markup says: ${named(left)}`, left);
		} catch (error) {
			if (!(error instanceof Mismatch)) throw error;
			console.warn(`rocx: <head> isn't what the app renders either (${error.message}); it stays as the server sent it`, ...(error.found ? [error.found] : []));
			this.dispose(part);
			const unseen = new Computation(this, { kind: "boundary", owner, scope });
			const copy = document.createDocumentFragment();
			for (const child of node.c) copy.append(this.build(child, unseen, scope));
		}
	}

	/** Rendering a page again: `<body>`'s children made anew. What isn't the app's stays: the host's
	 * elements (`[data-rocx]`), the server's `<NoHydration>` regions, and an extension's elements
	 * (D-112): one hydrating passed over, and any after the host's last element (start.js's script,
	 * the last the server writes), which only a script puts there. */
	renderBody(body, node, owner, scope) {
		// A navigation's: the fetched document's regions.
		const fragment = this.keepingRegions(this.arriving?.body ?? body, () => {
			const made = document.createDocumentFragment();
			for (const child of node.c) made.append(this.build(child, owner, scope));
			return made;
		});
		const children = [...body.childNodes];
		const last = children.findLastIndex(hosts);
		body.replaceChildren(fragment, ...children.filter((child, at) => hosts(child) || foreignNodes.has(child) || (last >= 0 && at > last && child.nodeType === 1)));
	}

	/** Binds an element's computed attributes and handlers (made, or found when hydrating). */
	bind(element, node, owner, scope) {
		// Drag and drop: an element with a drop handler is a drop target, and one with a dragstart
		// handler starts a drag in every browser (`dragAndDrop`). Its dragenter and dragleave handlers
		// are the element's own, as mouseenter and mouseleave are.
		let drag = null;
		for (const [kind, name] of node.a) {
			if (((kind === "on" || kind === "onp") && DRAG_EVENTS.has(name)) || kind === "dd" || kind === "ddo") {
				drag ??= { drop: false, start: false, enter: [], leave: [], depth: 0 };
				if (name === "drop") drag.drop = true;
				if (name === "dragstart" || kind === "dd" || kind === "ddo") drag.start = true;
			}
		}
		for (const [kind, name, value, wanted] of node.a) {
			if (kind === "vo" || kind === "fo" || kind === "co" || kind === "oo" || kind === "so") {
				const computed = { vo: "attr", fo: "flag", co: "class", oo: "optional", so: "style" }[kind];
				const computation = new Computation(this, { kind: computed, runner: this.kept.get(value), owner, scope, target: element, name });
				// A class's, and a computed `class` or `style` beside `class:name`s or `style:name`s: the
				// element's attributes, so its `class` (`style`) is written whole, as the server writes it
				// (`wholeClass`, `wholeStyle`).
				if (kind === "co" || ((kind === "vo" || kind === "oo") && joined(node.a, name))) computation.attrs = node.a;
				// One that read nothing that changes (a prop given a constant) is static: nothing keeps it.
				if (this.isStatic(computation, this.run(computation))) this.forget(computation, owner);
			} else if (kind === "on" || kind === "onp") {
				const handler = this.listener(kind, name, value, wanted, scope, owner);
				if (drag && name === "dragenter") drag.enter.push(handler);
				else if (drag && name === "dragleave") drag.leave.push(handler);
				else element.addEventListener(name, handler);
			} else if (kind === "k") this.keys.set(element, name);
			else if (kind === "ko") this.run(new Computation(this, { kind: "key", runner: this.kept.get(name), owner, scope, target: element }));
			else if (kind === "onk") element.addEventListener(name, this.listener(kind, name, value, wanted, scope, owner));
			else if (kind === "tr") this.setTransition(element, name, value);
			else if (kind === "tro") this.run(new Computation(this, { kind: "transition", runner: this.kept.get(value), owner, scope, target: element, name }));
			else if (kind === "frame") {
				// Every animation frame while the element is on the page, given the time since the last
				// one in whole microseconds (at most 100 ms: a tab that comes back resumes, not jumps).
				// When its part goes (a <Show> that hides it), its box is released, and frames stop.
				let last = performance.now();
				let shown = false;
				const tick = (now) => {
					if (!this.kept.has(value) || (shown && !element.isConnected)) return;
					const ms = Math.min(Math.max(now - last, 0), 100);
					last = now;
					if (element.isConnected) {
						shown = true;
						// The frame, and what it changed, now (not in a microtask), so it can be timed.
						const started = performance.now();
						const patches = this.stats.patches;
						this.handle(value, String(Math.round(ms * 1000)), scope, { owner });
						this.flush();
						this.notify("frame", { node: element, ms: performance.now() - started, patches: this.stats.patches - patches });
					}
					requestAnimationFrame(tick);
				};
				requestAnimationFrame(tick);
			} else if (kind === "view") this.viewport(element, value, scope, owner);
			else if (kind === "pt") this.pointAt(element, name, value, scope, owner, () => element.getBoundingClientRect()); //#point
			else if (kind === "dd") this.setDrag(element, name, value);
			else if (kind === "ddo") {
				const computation = new Computation(this, { kind: "drag", runner: this.kept.get(value), owner, scope, target: element, name });
				if (this.isStatic(computation, this.run(computation))) this.forget(computation, owner);
			}
		}
		if (drag) this.dragAndDrop(element, drag); //#drag
	}

	/**
	 * `on:viewport={|view| …}` (`["view", "viewport", id]`): the handler given what of the element's
	 * content shows, `top,left,width,height` in whole pixels (`scrollTop`, `scrollLeft`,
	 * `clientWidth`, `clientHeight`), once the element is on the page, then each time it scrolls or
	 * changes size (a ResizeObserver), at most once an animation frame, and only when one of the four
	 * changed. The scroll listener and the observer go with the owner's cleanups (a row that goes, a
	 * <Show> that hides it); a box released (its owner ran again) runs nothing.
	 */
	viewport(element, value, scope, owner) {
		if (typeof requestAnimationFrame === "undefined") return;
		let said = "";
		let asked = 0;
		const measure = () => {
			asked = 0;
			if (!this.kept.has(value) || !element.isConnected) return;
			const now = `${Math.round(element.scrollTop)},${Math.round(element.scrollLeft)},${element.clientWidth},${element.clientHeight}`;
			if (now === said) return;
			said = now;
			this.handle(value, now, scope, { owner });
		};
		const ask = () => {
			asked ||= requestAnimationFrame(measure);
		};
		element.addEventListener("scroll", ask, { passive: true });
		const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(ask);
		observer?.observe(element);
		ask();
		const record = owner?.making ?? owner?.made;
		const cleanups = record ? own(record, "cleanups") : undefined;
		cleanups?.push(() => {
			element.removeEventListener("scroll", ask);
			observer?.disconnect();
			if (asked) cancelAnimationFrame(asked);
		});
	}

	/**
	 * What a handler (`["on"|"onp"|"onk", event, id, wanted]`) listens with: an element's, or the
	 * document's or window's (`listenOn`). By the box's id: when its owner runs again the box is
	 * released (and an element replaced), so a listener left over runs nothing.
	 */
	listener(kind, name, value, wanted, scope, owner) {
		if (kind === "onk")
			// Given the key (`on:keydown.key`), or the key and the modifier keys held (`on:keydown.keys`).
			return (event) => {
				if (this.kept.has(value)) this.handle(value, wanted === "keys" ? keysOf(event) : (event.key ?? ""), scope, { owner });
			};
		// For one key, or a combination (`on:keydown.ArrowUp`, `on:keydown.Mod+K`): that key only, with
		// those modifier keys held and no others.
		// `.data` and `.files` (`["on", event, id, ".files"]`) say what the handler is given, not a key.
		const given = wanted?.startsWith(".") ? wanted : undefined;
		const pressed = wanted === undefined || given ? null : keyCombo(wanted);
		return (event) => {
			// That key only, and the browser doesn't also do what it would (an arrow key a game takes
			// doesn't scroll the page).
			if (pressed && !pressed(event)) return;
			// `.prevent`: what the browser would do (follow a link) is the handler's to do.
			if (kind === "onp" || name === "submit" || pressed) event.preventDefault();
			const target = event.target;
			// A drop's value is the text dropped (from another page, or another program); `.data`, all it
			// carries but its files; `.files`, its files (a paste's, a file input's); `.visible`, whether
			// the page shows.
			const input =
				given === ".files"
					? this.filesOf(event, owner)
					: given === ".data"
						? itemsOf(event.dataTransfer ?? event.clipboardData)
						: event.type === "drop"
							? (event.dataTransfer?.getData("text/plain") ?? "")
							: event.type === "visibilitychange"
								? String(this.page?.visibilityState !== "hidden")
								: target?.type === "checkbox"
									? String(target.checked)
									: String(target?.value ?? "");
			if (this.kept.has(value)) this.handle(value, input, scope, { owner });
		};
	}

	/**
	 * `<Document on:keydown.Mod+K={…} />` and `<Window on:resize={…} />` (`{"t":"listen"}`): their
	 * handlers on the whole document (or window), as an element's are, from where they are rendered
	 * until their owner runs again or goes (a `<Show>` hiding them, a row going), as Solid's
	 * `makeEventListener` is: taken off with the owner's cleanups. Nothing on the page.
	 */
	listenOn(node, owner, scope) {
		const target = node.to === "window" ? this.page?.defaultView : this.page;
		if (!target?.addEventListener) return;
		const record = owner?.making ?? owner?.made;
		const cleanups = record ? own(record, "cleanups") : undefined;
		for (const [kind, name, value, wanted] of node.a) {
			if (kind === "pt") {
				const view = this.page.defaultView;
				this.pointAt(target, name, value, scope, owner, () => ({ left: 0, top: 0, width: view?.innerWidth ?? 0, height: view?.innerHeight ?? 0 })); //#point
				continue;
			}
			if (kind !== "on" && kind !== "onp" && kind !== "onk") continue;
			const listener = this.listener(kind, name, value, wanted, scope, owner);
			target.addEventListener(name, listener);
			cleanups?.push(() => target.removeEventListener(name, listener));
		}
	}

	/**
	 * An element's part in drag and drop, after its own handlers (so they run first):
	 *
	 * - A drop target (a drop handler) accepts a drag: its dragenter's and dragover's default is
	 *   prevented, and dragover's `dropEffect` set (a move, unless the drag allows only a copy or a
	 *   link); its drop's default too (a dropped link or file doesn't open).
	 * - Its dragenter handlers run when a drag comes over it from outside, its dragleave handlers
	 *   when the drag leaves it for outside, is dropped, or ends: not each time the drag crosses a
	 *   child, as the browser's events fire (a count of enters and leaves).
	 * - An element with a dragstart handler has data set on the drag (`application/x-rocx`), which
	 *   Firefox needs to start one; what is dragged is the app's to keep (a signal its handlers set).
	 */
	dragAndDrop(element, drag) {
		const left = (event) => {
			drag.depth = 0;
			this.overs.delete(drag);
			for (const handler of drag.leave) handler(event);
		};
		drag.left = left;
		if (drag.enter.length || drag.leave.length || drag.drop) {
			element.addEventListener("dragenter", (event) => {
				if (drag.drop) event.preventDefault();
				if (drag.depth++ > 0) return;
				this.overs.add(drag);
				this.listenForDragEnds();
				for (const handler of drag.enter) handler(event);
			});
			element.addEventListener("dragleave", (event) => {
				if (drag.depth > 0 && --drag.depth === 0) left(event);
			});
			element.addEventListener("drop", (event) => {
				if (drag.drop) event.preventDefault();
				if (drag.depth > 0) left(event);
			});
		}
		if (drag.drop)
			element.addEventListener("dragover", (event) => {
				event.preventDefault();
				if (event.dataTransfer) event.dataTransfer.dropEffect = dropEffect(event.dataTransfer.effectAllowed);
			});
		if (drag.start) {
			element.addEventListener("dragstart", (event) => {
				const transfer = event.dataTransfer;
				if (!transfer) return;
				const own = this.dragged.get(element);
				for (const [type, data] of own?.data ?? []) transfer.setData(type, data);
				if (!transfer.types.length) transfer.setData("application/x-rocx", "rocx");
				// The app's drag image (`drag:image`): the browser's own drag draws a copy of it, held as the
				// element was taken. (A drag by touch or a pen draws its own: `pointerDrag`.)
				if (own?.image && !this.pointerDrag && typeof transfer.setDragImage === "function") {
					const image = this.dragImage(element, own.image, event);
					if (image) {
						transfer.setDragImage(image.node, image.x, image.y);
						setTimeout(() => image.node.remove(), 0);
					}
				}
			});
			// By touch or a pen, a drag of the runtime's own (`pointerDrag`): the browser's own drag (a long
			// press, in some) is called off, as one is already under way.
			element.addEventListener("pointerdown", (event) => this.pointerDown(element, event));
			element.addEventListener(
				"dragstart",
				(event) => {
					if (this.pointerDrag && !this.pointerDrag.firing) {
						event.preventDefault();
						event.stopImmediatePropagation();
					}
				},
				true,
			);
			// A touch that drags doesn't scroll the page: a listener that may say so must be there before
			// the touch starts (a passive one can't), on the element the touch starts on.
			element.addEventListener(
				"touchmove",
				(event) => {
					if (this.pointerDrag?.state === "dragging" && event.cancelable) event.preventDefault();
				},
				{ passive: false },
			);
		}
	}

	/** What an element's drag carries (`drag:data`: `name` "data", `[[type, value], …]` as JSON) or
	 * shows (`drag:image`: `name` "image", an element's id). */
	setDrag(element, name, value) {
		let own = this.dragged.get(element);
		if (!own) this.dragged.set(element, (own = { data: [], image: "" }));
		if (name === "data") {
			try {
				own.data = JSON.parse(value);
			} catch {
				own.data = [];
			}
		} else own.image = String(value);
	}

	/**
	 * A copy of the element whose id is `id` (`drag:image`), as a drag of `element` shows it: put just
	 * after it (so what styles it there styles the copy too), fixed, out of sight unless `at` says
	 * where, shown even if it is `hidden`, without ids, taking no pointer events, marked
	 * `data-rocx-drag-image` for the app's CSS. Held where the drag took the element (`event`): at the
	 * same share of the copy's width and height. None when no element has the id.
	 */
	dragImage(element, id, event) {
		const source = id ? this.page.getElementById(id) : element;
		if (!source) return null;
		const node = source.cloneNode(true);
		node.removeAttribute("id");
		node.removeAttribute("hidden");
		for (const inside of node.querySelectorAll("[id]")) inside.removeAttribute("id");
		node.setAttribute("aria-hidden", "true");
		node.setAttribute("data-rocx-drag-image", "");
		const own = source.getBoundingClientRect();
		const fixed = { position: "fixed", left: "-100000px", top: "0px", right: "auto", bottom: "auto", margin: "0px", "pointer-events": "none", "z-index": "2147483647", "box-sizing": "border-box" };
		// A copy of the element itself keeps its size, wherever it is drawn.
		if (!id) Object.assign(fixed, { width: `${own.width}px`, height: `${own.height}px` });
		for (const [name, value] of Object.entries(fixed)) node.style.setProperty(name, value, "important");
		source.after(node);
		const box = node.getBoundingClientRect();
		const from = element.getBoundingClientRect();
		const share = (at, start, size) => (size > 0 ? Math.min(Math.max((at - start) / size, 0), 1) : 0.5);
		return { node, x: Math.round(share(event.clientX, from.left, from.width) * box.width), y: Math.round(share(event.clientY, from.top, from.height) * box.height), width: box.width, height: box.height };
	}

	/** The files a drop, a paste or a file input carries, as JSON for `Html.File`s: each read by a
	 * `blob:` URL, kept (`fileOf`) until the element's owner goes, then let go. */
	filesOf(event, owner) {
		const list = event.dataTransfer?.files ?? event.clipboardData?.files ?? event.target?.files ?? [];
		const record = owner?.making ?? owner?.made;
		const cleanups = record ? own(record, "cleanups") : undefined;
		const files = [];
		for (const file of list) {
			const url = typeof URL.createObjectURL === "function" ? URL.createObjectURL(file) : "";
			if (url) {
				this.files.set(url, file);
				cleanups?.push(() => {
					this.files.delete(url);
					URL.revokeObjectURL(url);
				});
			}
			files.push({ name: file.name ?? "", type: file.type ?? "", size: file.size ?? 0, url });
		}
		return JSON.stringify(files);
	}

	/** The file a handler was given by its `blob:` URL (`Html.File`'s `url`), while it is kept: what
	 * an action posting a form field with that URL as its value sends in its place. */
	fileOf(url) {
		return this.files.get(url) ?? null;
	}

	/**
	 * `on:pointermove.point={|point| …}` (`["pt", event, id]`): the handler given where the pointer is
	 * over the element (`box`: the element's, or the viewport's for `<Document>` and `<Window>`), as
	 * thousandths of its width and height, `x,y` (whole numbers, 0 to 1000). A move (`MOVES`) runs it
	 * at most once an animation frame, with the latest place. Taken off with the owner's cleanups.
	 */
	pointAt(target, name, value, scope, owner, box) {
		let last = null;
		let asked = 0;
		const say = () => {
			asked = 0;
			if (!last || !this.kept.has(value)) return;
			const rect = box();
			const share = (at, start, size) => (size > 0 ? Math.round(Math.min(Math.max((at - start) / size, 0), 1) * 1000) : 0);
			const point = `${share(last.x, rect.left, rect.width)},${share(last.y, rect.top, rect.height)}`;
			last = null;
			this.handle(value, point, scope, { owner });
		};
		const listener = (event) => {
			const touch = event.touches?.[0] ?? event.changedTouches?.[0];
			last = { x: touch?.clientX ?? event.clientX ?? 0, y: touch?.clientY ?? event.clientY ?? 0 };
			if (!MOVES.has(name) || typeof requestAnimationFrame === "undefined") say();
			else asked ||= requestAnimationFrame(say);
		};
		target.addEventListener(name, listener, { passive: true });
		const record = owner?.making ?? owner?.made;
		const cleanups = record ? own(record, "cleanups") : undefined;
		cleanups?.push(() => {
			target.removeEventListener(name, listener);
			if (asked) cancelAnimationFrame(asked);
		});
	}

	// ---- Dragging by touch and pen ----

	/**
	 * A drag by touch or a pen (D-055), which many browsers start none of, in the same events as the
	 * browser's own (so D-029's drop targets and the app's handlers take it as they take one): a
	 * pointer that isn't a mouse (a mouse has the browser's own drag, which carries data and files to
	 * other windows), pressed on an element that starts drags, held a moment (`POINTER_DRAG.hold`)
	 * while it moves less than `slop` (a swipe scrolls the page as before; a tap clicks), starts one.
	 * Meanwhile, and while it drags, the element has no long-press callout and selects no text.
	 */
	pointerDown(element, event) {
		if (event.pointerType === "mouse" || !event.isPrimary || event.button > 0 || this.pointerDrag || !element.draggable) return;
		if (event.target?.closest?.("input, textarea, select, [contenteditable]:not([contenteditable=false])") && element.contains(event.target)) return;
		const page = this.page;
		const drag = { element, id: event.pointerId, state: "held", from: { x: event.clientX, y: event.clientY }, at: { x: event.clientX, y: event.clientY }, firing: false, target: null, operation: "none", transfer: null, ghost: null, frame: 0, styles: [] };
		this.pointerDrag = drag;
		// Each as it was first (one may be another's alias), then set.
		const quiet = ["-webkit-touch-callout", "-webkit-user-select", "user-select"];
		for (const name of quiet) drag.styles.push([name, element.style.getPropertyValue(name), element.style.getPropertyPriority(name)]);
		for (const name of quiet) element.style.setProperty(name, "none");
		const ours = (event) => event.pointerId === drag.id;
		const moved = (event) => {
			if (!ours(event)) return;
			drag.at = { x: event.clientX, y: event.clientY };
			if (drag.state === "held") {
				if (Math.hypot(drag.at.x - drag.from.x, drag.at.y - drag.from.y) > POINTER_DRAG.slop) this.pointerDragEnd(drag, { cancel: true });
			} else if (drag.state === "dragging") {
				this.placeGhost(drag);
				drag.frame ||= requestAnimationFrame(() => this.pointerDragFrame(drag));
			}
		};
		const up = (event) => ours(event) && this.pointerDragEnd(drag, { cancel: drag.state !== "dragging" });
		const cancelled = (event) => ours(event) && this.pointerDragEnd(drag, { cancel: true });
		// A long press's own menu and selection don't come while it is held or drags.
		const hush = (event) => event.preventDefault();
		const timer = setTimeout(() => this.pointerDragStart(drag), POINTER_DRAG.hold);
		drag.off = () => {
			clearTimeout(timer);
			page.removeEventListener("pointermove", moved, true);
			page.removeEventListener("pointerup", up, true);
			page.removeEventListener("pointercancel", cancelled, true);
			page.removeEventListener("contextmenu", hush, true);
			page.removeEventListener("selectstart", hush, true);
		};
		page.addEventListener("pointermove", moved, true);
		page.addEventListener("pointerup", up, true);
		page.addEventListener("pointercancel", cancelled, true);
		page.addEventListener("contextmenu", hush, true);
		page.addEventListener("selectstart", hush, true);
	}

	/** The events of a drag by touch or a pen, as the browser fires its own: each a `DragEvent` with
	 * its place, all carrying one `DataTransfer` (what dragstart puts on it, a drop reads), bubbling.
	 * Answers whether its default was prevented. */
	fireDrag(drag, type, target, { related = null, effect = "none" } = {}) {
		const transfer = drag.transfer;
		try {
			transfer.dropEffect = type === "dragenter" || type === "dragover" ? dropEffect(transfer.effectAllowed) : effect;
		} catch {}
		const init = { bubbles: true, composed: true, cancelable: type !== "dragleave" && type !== "dragend", clientX: drag.at.x, clientY: drag.at.y, screenX: drag.at.x, screenY: drag.at.y, buttons: type === "drop" || type === "dragend" ? 0 : 1, relatedTarget: related, dataTransfer: transfer };
		let event;
		try {
			event = new DragEvent(type, init);
		} catch {
			event = new MouseEvent(type, init);
		}
		if (event.dataTransfer !== transfer) Object.defineProperty(event, "dataTransfer", { value: transfer });
		drag.firing = true;
		try {
			return !target.dispatchEvent(event);
		} finally {
			drag.firing = false;
		}
	}

	/** Held long enough: the drag starts, as the browser's would (dragstart on the element, which may
	 * call it off), its image under the finger (`drag:image`'s, or a copy of the element as it was
	 * before dragstart's handlers changed it), and goes over what is under it. */
	pointerDragStart(drag) {
		if (this.pointerDrag !== drag || drag.state !== "held" || !drag.element.isConnected) return this.pointerDragEnd(drag, { cancel: true });
		drag.transfer = makeTransfer();
		const image = this.dragImage(drag.element, this.dragged.get(drag.element)?.image ?? "", { clientX: drag.from.x, clientY: drag.from.y });
		if (this.fireDrag(drag, "dragstart", drag.element)) {
			image?.node.remove();
			return this.pointerDragEnd(drag, { cancel: true });
		}
		drag.state = "dragging";
		if (image) {
			drag.ghost = image;
			// Above everything (the top layer, where the browser has it), its own look kept.
			if (typeof image.node.showPopover === "function") {
				const look = getComputedStyle(image.node);
				for (const name of POPOVER_LOOK) image.node.style.setProperty(name, look.getPropertyValue(name), "important");
				image.node.setAttribute("popover", "manual");
				image.node.showPopover();
			}
			image.node.style.setProperty("left", "0px", "important");
			image.node.style.setProperty("top", "0px", "important");
			this.placeGhost(drag);
		}
		this.pointerDragFrame(drag);
	}

	/** The image where the finger is, held as the element was taken. */
	placeGhost(drag) {
		const ghost = drag.ghost;
		if (ghost) ghost.node.style.setProperty("translate", `${drag.at.x - ghost.x}px ${drag.at.y - ghost.y}px`, "important");
	}

	/**
	 * Once an animation frame while it drags: drag on the element; what is under the finger now gets
	 * dragenter when the drag comes to it (and the one it left, dragleave, after: the browser's
	 * order), then dragover, which accepts the drag when its default is prevented (D-029's drop
	 * targets do). Near the edge of a box that scrolls (or the page's), that box scrolls, and the next
	 * frame comes even if the finger is still.
	 */
	pointerDragFrame(drag) {
		drag.frame = 0;
		if (this.pointerDrag !== drag || drag.state !== "dragging") return;
		this.fireDrag(drag, "drag", drag.element);
		const target = this.page.elementFromPoint(drag.at.x, drag.at.y) ?? this.page.body;
		if (target !== drag.target) {
			this.fireDrag(drag, "dragenter", target, { related: drag.target });
			if (drag.target) this.fireDrag(drag, "dragleave", drag.target, { related: target });
			drag.target = target;
		}
		drag.operation = this.fireDrag(drag, "dragover", target) ? drag.transfer.dropEffect || "move" : "none";
		if (this.scrollNear(target, drag.at)) drag.frame = requestAnimationFrame(() => this.pointerDragFrame(drag));
	}

	/** Scrolls the innermost box around `node` (or the page) that `at` is near the edge of and can
	 * scroll that way, faster nearer the edge. Answers whether something scrolled. */
	scrollNear(node, at) {
		const { edge, speed } = POINTER_DRAG;
		const step = (near) => (near < edge ? Math.ceil(speed * (1 - Math.max(near, 0) / edge)) : 0);
		const page = this.page.scrollingElement ?? this.page.documentElement;
		for (let box = node?.nodeType === 1 ? node : node?.parentElement; box; box = box.parentElement) {
			const whole = box === page || box === this.page.body;
			const style = whole ? null : getComputedStyle(box);
			const scrolls = (overflow) => whole || overflow === "auto" || overflow === "scroll";
			const rect = whole ? { left: 0, top: 0, right: innerWidth, bottom: innerHeight } : box.getBoundingClientRect();
			const target = whole ? page : box;
			let dx = 0;
			let dy = 0;
			if (scrolls(style?.overflowX) && target.scrollWidth > target.clientWidth) {
				if (target.scrollLeft > 0) dx -= step(at.x - rect.left);
				if (target.scrollLeft + target.clientWidth < target.scrollWidth - 1) dx += step(rect.right - at.x);
			}
			if (scrolls(style?.overflowY) && target.scrollHeight > target.clientHeight) {
				if (target.scrollTop > 0) dy -= step(at.y - rect.top);
				if (target.scrollTop + target.clientHeight < target.scrollHeight - 1) dy += step(rect.bottom - at.y);
			}
			if (dx || dy) {
				target.scrollBy(dx, dy);
				return true;
			}
			if (whole) break;
		}
		return false;
	}

	/**
	 * The drag ends: lifted where something accepted it, a drop there; otherwise (or `cancel`: the
	 * browser took the touch to scroll, or it was let go before it started) a dragleave on what it was
	 * over. Then dragend on the element, its `dropEffect` the drop's ("none" if nothing took it), as
	 * the browser's own drag ends; a drag that never started ends with nothing. A click the lift
	 * would make after a drag doesn't come.
	 */
	pointerDragEnd(drag, { cancel = false } = {}) {
		if (this.pointerDrag !== drag) return;
		this.pointerDrag = null;
		drag.off();
		if (drag.frame) cancelAnimationFrame(drag.frame);
		const started = drag.state === "dragging";
		drag.state = "done";
		drag.ghost?.node.remove();
		for (const [name, value, priority] of drag.styles.toReversed()) {
			if (value) drag.element.style.setProperty(name, value, priority);
			else drag.element.style.removeProperty(name);
		}
		if (!started) return;
		const dropped = !cancel && drag.operation !== "none" && drag.target;
		if (dropped) this.fireDrag(drag, "drop", drag.target, { effect: drag.operation });
		else if (drag.target) this.fireDrag(drag, "dragleave", drag.target);
		this.fireDrag(drag, "dragend", drag.element, { effect: dropped ? drag.operation : "none" });
		// The lift's own click, if the browser makes one, comes before the next press.
		const page = this.page;
		const click = (event) => {
			event.preventDefault();
			event.stopPropagation();
			done();
		};
		const done = () => {
			page.removeEventListener("click", click, true);
			page.removeEventListener("pointerdown", done, true);
		};
		page.addEventListener("click", click, true);
		page.addEventListener("pointerdown", done, true);
		setTimeout(done, 400);
	}

	/** Once: a drag that ends (dropped anywhere, or called off) leaves every drop target it was over,
	 * should the browser not have said so (the element under it went). */
	listenForDragEnds() {
		if (this.dragEnds || typeof this.page?.addEventListener !== "function") return;
		this.dragEnds = (event) => {
			for (const drag of [...this.overs]) drag.left(event);
		};
		this.page.addEventListener("dragend", this.dragEnds);
		this.page.addEventListener("drop", this.dragEnds);
	}

	// ---- On the server ----

	/** Runs a hole once, for its answer (a failure throws). */
	once(runner, owner, scope, boundary = null) {
		return this.onceInert(runner, owner, scope, boundary).out;
	}

	/** The same, and whether the run was static (`inert`): a hole the server writes without comments. */
	onceInert(runner, owner, scope, boundary = null) {
		const computation = new Computation(this, { kind: "once", runner: this.kept.get(runner), owner, scope });
		computation.boundary = boundary;
		computation.making = making_();
		const previous = this.current;
		this.current = computation;
		try {
			const out = this.enter(() => this.ex.run(computation.runner));
			return { out, inert: inert(computation.making) };
		} finally {
			this.current = previous;
			computation.made = computation.making;
			computation.making = null;
		}
	}

	/** A node of the markup's JSON as HTML, every hole run once, with the comments hydration finds holes by. */
	serverHtml(node, owner, scope) {
		const all = (nodes) => nodes.map((child) => this.serverHtml(child, owner, scope)).join("");
		// Inside RCDATA (`<title>`), no comments: the parser would show them. Inside a <NoHydration>,
		// none either: the browser never hydrates what is there.
		const mark = (label, inner) => (scope.rcdata || scope.region ? inner : `<!--${label}-->${inner}<!--/${label}-->`);
		switch (node.t) {
			case "s":
				return escape(node.v);
			case "raw":
				// A <script>'s or <style>'s text, as rocx wrote it from the .rocx file: never data.
				return node.v;
			case "doctype":
				return "<!doctype html>";
			case "x": {
				// A hole that read nothing that changes is static (D-052): no comments, as a text's.
				const { out, inert } = this.onceInert(node.r, owner, scope);
				const text = escape(JSON.parse(out));
				return inert ? text : mark("x", text);
			}
			case "h":
			case "l": {
				const label = node.t === "h" ? "html" : "list";
				const { out, inert } = this.onceInert(node.r, owner, scope);
				const parsed = JSON.parse(out);
				const inner = (Array.isArray(parsed) ? parsed : [parsed]).map((child) => this.serverHtml(child, owner, scope)).join("");
				return inert ? inner : mark(label, inner);
			}
			case "hx": {
				// A hole of either kind (D-070): a text hole's comments while it shows text alone.
				const { out, inert } = this.onceInert(node.r, owner, scope);
				const nodes = answered(JSON.parse(out));
				const inner = nodes.map((child) => this.serverHtml(child, owner, scope)).join("");
				return inert ? inner : mark(loneText(nodes) === null ? "html" : "x", inner);
			}
			case "f":
				return all(node.c);
			case "loading":
				// On the server every read is answered as it is made: nothing waits, and what is inside renders.
				return mark("loading", all(node.c));
			case "show": {
				// One whose case read nothing that changes is static (D-052, D-070): no comments.
				const { out, inert } = this.onceInert(node.r, owner, scope);
				const holds = JSON.parse(out);
				const shown = !holds ? this.serverHtml(node.fallback, owner, scope) : node.with ? this.serverHtml(JSON.parse(this.once(node.with, owner, scope)), owner, scope) : all(node.c);
				return inert ? shown : mark("show", shown);
			}
			case "for": {
				const list = this.lists.get(node.id);
				const entries = JSON.parse(this.once(node.r, owner, scope));
				const rows = entries.map(({ k, r }, index) => {
					list.indexes.set(k, { value: index, observers: null });
					return mark("row", this.serverHtml(JSON.parse(this.once(r, owner, scope)), owner, scope));
				});
				return mark("for", rows.length ? rows.join("") : mark("fallback", this.serverHtml(node.fallback, owner, scope)));
			}
			case "errored":
				try {
					return mark("errored", all(node.c));
				} catch (error) {
					if (!(error instanceof Failed)) throw error;
					const fallback = JSON.parse(this.once(node.r, owner, scope, { id: 0, failed: error.message }));
					const shown = this.serverHtml(fallback, owner, scope);
					return scope.rcdata || scope.region ? shown : `<!--errored:failed-->${shown}<!--/errored-->`;
				}
			case "c":
				return this.serverHtml(JSON.parse(this.once(node.r, owner, scope)), owner, scope);
			case "nh": {
				// Static markup in its markers (one inside another is its part); or, rendering against a
				// page (`renderToString({ regions })`), the page's own, as it has it.
				if (scope.region || scope.rcdata) return all(node.c);
				if (this.regions) {
					if (!this.regions.length) throw new Error("rocx: the app renders more <NoHydration>s than the page has");
					return `<!--nohydration-->${this.regions.shift()}<!--/nohydration-->`;
				}
				const inner = { ...scope, region: true };
				return `<!--nohydration-->${node.c.map((child) => this.serverHtml(child, owner, inner)).join("")}<!--/nohydration-->`;
			}
			case "ctx":
				return node.c.map((child) => this.serverHtml(child, owner, provided(scope, node))).join("");
			case "listen":
				// `<Document>`, `<Window>`: nothing on the page; in a <NoHydration>, handlers that would never run.
				if (scope.region && node.a.length) throw new Error(inRegion(node.to === "window" ? "Window" : "Document", node.a[0][1]));
				return "";
			case "e": {
				node = writable(node, null);
				if (!node) return "";
				const classes = [];
				const attributes = [];
				const styles = [];
				// A link's address, for its mark (D-086).
				let href = null;
				for (const [kind, name, value] of node.a) {
					if (scope.region && (kind === "on" || kind === "onp" || kind === "onk" || kind === "frame" || kind === "view" || kind === "pt" || kind === "dd" || kind === "ddo")) throw new Error(inRegion(node.tag, name));
					if (kind === "v" && name === "class") classes.push(value);
					else if (kind === "v" && name === "style") styles.push(value);
					// An own `class` (`style`) that may be empty, or computed: in the one attribute, with
					// the `class:name`s (`style:name`s) beside it.
					else if ((name === "class" || name === "style") && (kind === "o" || kind === "vo" || kind === "oo")) {
						const own = kind === "o" ? value : JSON.parse(this.once(value, owner, scope));
						if (own !== "" || kind === "vo") (name === "class" ? classes : styles).push(own);
					} else if (kind === "v") {
						if (name === "href") href = value;
						attributes.push(`${name}="${escape(value)}"`);
					} else if (kind === "o" && value !== "") {
						if (name === "href") href = value;
						attributes.push(`${name}="${escape(value)}"`);
					} else if (kind === "ci" && value) classes.push(name);
					else if (kind === "f" && value) attributes.push(name);
					else if (kind === "vo") {
						const computed = JSON.parse(this.once(value, owner, scope));
						if (name === "href") href = computed;
						attributes.push(`${name}="${escape(computed)}"`);
					} else if (kind === "oo") {
						const optional = JSON.parse(this.once(value, owner, scope));
						if (optional !== "") {
							if (name === "href") href = optional;
							attributes.push(`${name}="${escape(optional)}"`);
						}
					} else if (kind === "fo" && JSON.parse(this.once(value, owner, scope))) attributes.push(name);
					else if (kind === "co" && JSON.parse(this.once(value, owner, scope))) classes.push(name);
					else if (kind === "sv" && value) styles.push(`${name}: ${value}`);
					else if (kind === "so") {
						const styled = JSON.parse(this.once(value, owner, scope));
						if (styled !== "") styles.push(`${name}: ${styled}`);
					}
				}
				// An `<input type="password">`'s name, for the flash's note (`withoutSecrets`).
				if (node.tag.toLowerCase() === "input" && node.a.some(([kind, name, value]) => kind === "v" && name === "type" && String(value).toLowerCase() === "password")) {
					const named = node.a.find(([kind, name]) => kind === "v" && name === "name");
					if (named && named[2] !== "") this.secrets.push(String(named[2]));
				}
				if (classes.length) attributes.unshift(`class="${escape(classes.join(" "))}"`);
				if (styles.length) attributes.push(`style="${escape(styles.join("; "))}"`);
				// A same-app link where the page is, or above it, marked last (D-086), as signals.rs marks it.
				const mark = node.tag === "a" && !ownsCurrent(node) ? this.linkMark(href) : null;
				if (mark) attributes.push(`aria-current="${mark}"`);
				const open = `<${node.tag}${attributes.map((attribute) => ` ${attribute}`).join("")}>`;
				const inner = RCDATA.has(node.tag) ? { ...scope, rcdata: true } : scope;
				return VOID.has(node.tag) ? open : `${open}${node.c.map((child) => this.serverHtml(child, owner, inner)).join("")}</${node.tag}>`;
			}
			default:
				throw new Error(`rocx: unknown node ${node.t}`);
		}
	}

	/**
	 * On the server: the app's markup as HTML for a request (`path`, `headers` as `[name, value]`
	 * pairs), and the answers its reads got, for the page to carry to the browser. All it
	 * made is let go of afterwards. Markup with `<html>` at its top is a whole document, answered as
	 * the server platform answers a page (`Runtime.documentOf`); any other is an app's range
	 * (`<!--app-->…<!--/app-->`, for `hydrate`).
	 *
	 * Rendered against a page the server rendered (the browser's build, as hydrating it would),
	 * `answers` are that page's (`[[name, input, answer]]`, its answers script): each GET is
	 * answered from them and recorded as the page has it, and one the server didn't make fails
	 * (599). `regions` are what the page has inside each `<NoHydration>`, in order
	 * (`Runtime.regionsOf`): each is written as it is there, since the browser's build has a
	 * placeholder in its place; without them, a placeholder renders empty. `scripts` are the
	 * plugins' scripts the server's pages load (`Plugin.scripts`, by URL: `/rocx/plugins/…`), a tag
	 * each before start.js, as the server writes them.
	 */
	renderToString({ path = "/", headers = [], answers = null, regions = null, scripts = [] } = {}, scope = {}) {
		this.given = answers;
		this.regions = regions && [...regions];
		this.pageScripts = scripts;
		try {
			const rendered = this.renderPage(path, headers, scope);
			if (this.regions?.length) throw new Error(`rocx: the page has ${this.regions.length} <NoHydration> more than the app renders`);
			return rendered;
		} finally {
			this.given = null;
			this.regions = null;
		}
	}

	/** What a page has inside each `<NoHydration>`, in order: for `renderToString({ regions })`. */
	static regionsOf(html) {
		return [...html.matchAll(/<!--nohydration-->([\s\S]*?)<!--\/nohydration-->/g)].map((match) => match[1]);
	}

	/** `renderToString`'s render: the page for `path`, as HTML, and its answers. */
	renderPage(path, headers, scope) {
		this.request = wire("GET", path, headers, "");
		this.headers = headers;
		this.recorded = [];
		this.flashed = "";
		this.secrets = [];
		this.titled = null;
		this.headed = [];
		this.built = null;
		this.status = 200;
		const wasOnServer = this.onServer;
		this.onServer = true;
		const root = new Computation(this, { kind: "root", owner: null, scope });
		root.making = making_();
		this.current = root;
		let out;
		try {
			out = this.enter(() => this.ex.mount());
		} catch (error) {
			this.onServer = wasOnServer;
			throw error;
		} finally {
			this.current = null;
		}
		try {
			const markup = this.serverHtml(JSON.parse(out), root, scope);
			const html = DOCUMENT.test(markup) ? Runtime.documentOf(markup, this.recorded, Runtime.withoutSecrets(this.flashed, this.secrets), this.titled, this.pageScripts ?? [], this.headed, this.built) : `<!--app-->${markup}<!--/app-->`;
			return { html, answers: this.recorded };
		} finally {
			this.onServer = wasOnServer;
			root.made = root.making;
			this.dispose(root);
			for (const signal of this.signals.values()) this.releaseSignal(signal);
			this.signals.clear();
			for (const list of this.lists.values()) this.dropList(list);
			this.lists.clear();
		}
	}

	/** The markup with a `<Title>`'s title first in its `<head>` (signals.rs's `titled`): before the
	 * `<head>`'s first `<title>`, or before `</head>`; as it was, with no `<head>`. */
	static titled(markup, title) {
		const end = markup.indexOf("</head>");
		if (end < 0) return markup;
		const own = markup.slice(0, end).search(/<title[\s>]/);
		const at = own >= 0 ? own : end;
		return `${markup.slice(0, at)}<title data-rocx>${title.replace(/&/g, "&amp;").replace(/</g, "&lt;")}</title>${markup.slice(at)}`;
	}

	/** The answers as a script for the page: JSON, with nothing in it that could end the script. */
	static answersScript(answers) {
		return `<script type="application/json" class="rocx-answers">${JSON.stringify(answers).replace(/</g, "\\u003c")}</script>`;
	}

	/** The flash's JSON without the fields the page has as `<input type="password">` (`secrets`), as
	 * signals.rs's `without_secrets` leaves them out: what was typed in one never reaches the page. */
	static withoutSecrets(flash, secrets) {
		if (!flash || !secrets.length) return flash;
		let kept;
		try {
			kept = JSON.parse(flash);
		} catch {
			return flash;
		}
		if (typeof kept?.input !== "string") return flash;
		const decoded = (name) => {
			try {
				return decodeURIComponent(name.replace(/\+/g, " "));
			} catch {
				return name;
			}
		};
		const fields = kept.input.split("&").filter((field) => field !== "");
		const left = fields.filter((field) => !secrets.includes(decoded(field.split("=")[0])));
		if (left.length === fields.length) return flash;
		return JSON.stringify({ ...kept, input: left.join("&") });
	}

	/** The flash a page read, as a script for the browser (signals.rs's `flash_script`): its JSON, as
	 * a JSON string. */
	static flashScript(flash) {
		return `<script type="application/json" class="rocx-flash">${JSON.stringify(flash).replace(/</g, "\\u003c")}</script>`;
	}

	/**
	 * A page's markup as the server platform answers it (signals.rs's `document`): `<!doctype html>`
	 * first, unless the markup begins with one; the title the last `<Title>` rendered said, if one
	 * did, as a `<title data-rocx>` before the `<head>`'s first `<title>` (or at its end); the flash
	 * the page read (if it did), the answers script, the plugins' scripts (`scripts`, by URL) and
	 * the bootstrap (start.js, with the build's id if the page's root told it: `data-build`) just
	 * before the last `</body>`, or at the end with none. The `<Meta>`s, `<Link>`s and `<Style>`s
	 * it rendered (`heads`) go before `</head>`.
	 */
	static documentOf(markup, answers, flash = "", title = null, scripts = [], heads = [], build = null) {
		if (title !== null) markup = Runtime.titled(markup, title);
		markup = Runtime.headed(markup, heads);
		const doctype = /^<!doctype/i.test(markup.trimStart()) ? "" : "<!doctype html>";
		const before = `${flash ? Runtime.flashScript(flash) : ""}${Runtime.answersScript(answers)}${Runtime.scriptTags(scripts)}${startWith(build)}`;
		const at = markup.lastIndexOf("</body>");
		return at < 0 ? `${doctype}${markup}${before}` : `${doctype}${markup.slice(0, at)}${before}${markup.slice(at)}`;
	}

	/** The tags that load the plugins' scripts (files.rs's `script_tags`): a module each, the host's
	 * own (`data-rocx`), so hydrating passes over it. */
	static scriptTags(urls) {
		return urls.map((url) => `<script type="module" data-rocx src="${url.replace(/&/g, "&amp;").replace(/"/g, "&quot;")}"></script>`).join("");
	}

	/**
	 * A component (`{"t":"c","r":id}`): run where it is rendered, once, its reads not tracked, as Solid
	 * runs one; what it renders is built (or, hydrating, found) there, owned by it, so it goes, its
	 * signals with it, when the part it is in does. Its nodes; none if it failed (the nearest
	 * <Errored> shows why).
	 */
	component(node, owner, scope) {
		const computation = new Computation(this, { kind: "component", runner: this.kept.get(node.r), owner, scope });
		computation.making = making_();
		const previous = this.current;
		const place = this.place;
		this.current = computation;
		this.place = null;
		this.stats.runs++;
		try {
			return { computation, nodes: [JSON.parse(this.enter(() => this.ex.run(computation.runner)))] };
		} catch (error) {
			if (error instanceof NotReady) throw new Error("rocx: a component read a value that isn't in yet outside its markup: read it in a hole ({…}), which waits");
			if (!(error instanceof Failed)) throw error;
			this.failed(computation, error);
			this.reclaim(error);
			return { computation, nodes: [] };
		} finally {
			this.current = previous;
			this.place = place;
			computation.made = computation.making;
			computation.making = null;
		}
	}

	/** Mounts the app's markup in `container`. */
	mount(container) {
		const range = makeRange("app");
		container.append(range.fragment);
		this.root = new Computation(this, { kind: "root", owner: null, scope: {}, target: range });
		this.run(this.root);
	}

	live() {
		return Number(this.ex.live_allocations());
	}

	/** For the tests: the host's notes of what runs allocate (web/host/src/track.rs's log), as counts: how
	 * many it keeps, and the room it keeps for them. */
	notes() {
		return { kept: this.ex.notes_kept(), room: this.ex.notes_room() };
	}

	/** How many allocations Roc has made so far: the tests' measure of what a change costs. */
	allocations() {
		return Number(this.ex.allocations());
	}
}
