// The browser's runtime: Solid 2.0-style components written in Roc, run by a wasm module built on
// web/platform. Roc builds markup whose holes are computations (boxes this runtime keeps
// by their pointers); this file runs them, tracks what each reads, runs it again when that changes,
// and patches only its own node. An async read whose value isn't in yet throws (NotReady) through
// the Roc frames: the computation stops, the nearest <Loading> shows its fallback until the first
// values are in, and the computation runs again once its value is. A failure (Failed) shows the
// nearest <Errored>. Handlers run as effects; one that waits for a server function is run again
// when the answer is in, its writes dropped meanwhile (writes apply when a handler is done).
// A component runs where it is rendered, once, its reads untracked (as in Solid), so it sees the
// contexts provided above it; a signal belongs to the run that made it, and goes with it, as do its
// effects (Solid 2.0's split ones: a tracked compute, then an apply after the flush), cleanups,
// timers and listens, a cleanup run before what made it runs again, and when it goes. A form
// posting to an endpoint a component reads the submission of is sent with fetch. An app
// whose root renders a whole document (`<!doctype html><html>…`) hydrates the page the server sent
// (`hydrateDocument`, called by start.js).

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** A read whose value isn't in yet: `wait` settles when it might be. */
/** A split app's main module imports a chunk's placeholders from `placeholder.<chunk>`. */
const PLACEHOLDER = "placeholder.";
/** The chunk of what the build found nothing reaches (src/split.mjs). */
const UNREACHED = "Unreached";

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

/** How a server function is called: POST /rocx/call/name (under the site's base) with the input as
 * JSON; the answer as text. */
async function callServer(name, input, base = "/") {
	const response = await fetch(`${base}rocx/call/${name}`, { method: "POST", headers: { "content-type": "application/json" }, body: input });
	const text = await response.text();
	if (!response.ok) throw new Error(`${response.status}: ${text}`);
	return text;
}

/** A request as the host passes it to Roc (`Host.request!`), as HTTP writes it: `METHOD target`, a
 * header a line, a blank line, then its body. */
const wire = (method, target, headers, body) => [`${method} ${target}`, ...headers.map(([name, value]) => `${name}: ${value}`)].join("\n") + `\n\n${body}`;

let ids = 0;

/** What a run makes, as it makes it: child computations, boxes kept for them, what it reads,
 * signals, and cleanups (a kept box's id, or the runtime's own function). */
const making_ = () => ({ children: [], kept: [], sources: new Set(), signals: [], cleanups: [] });

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
		this.sources = new Set();
		this.observers = new Set();
		/** What the last complete run made: child computations, boxes kept for them, cleanups. */
		this.made = { children: [], kept: [], cleanups: [] };
		/** Server functions' answers, by name and input: a run again reads them. */
		this.calls = new Map();
		this.disposed = false;
		owner?.adopt(this);
	}

	adopt(child) {
		(this.making ?? this.made).children.push(child);
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

	retry() {
		if (this.failed === null) return;
		this.failed = null;
		this.runtime.dispose(this.fallback);
		for (const memo of this.memos) this.runtime.refresh(memo);
		this.memos.clear();
		replaceRange(this.range, this.build());
	}
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
class Mismatch extends Error {}

/** An element the host put in the page, not the app (the bootstrap, the dev reload script). */
const hosts = (node) => node.nodeType === 1 && node.hasAttribute("data-rocx");

/** Text that is only HTML's whitespace, which the parser drops or moves around `<html>`. */
const blank = (text) => /^[\t\n\f\r ]*$/.test(text);

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
	/** Whether all that is left is whitespace (the parser puts what follows `</body>` in it). */
	blankToEnd() {
		for (let node = this.node; node; node = node.nextSibling) if (!hosts(node) && !(node.nodeType === 3 && blank(node.data))) return false;
		return true;
	}
	take(check, what) {
		// The document's doctype, where the markup doesn't take it: the host writes one when the
		// markup begins with none (or with a hole's comment, its own doctype then inside).
		if (this.parent?.nodeType === 9 && this.node?.nodeType === 10 && !check(this.node)) this.node = this.node.nextSibling;
		if (this.rebuild) while (this.node && !check(this.node)) this.node = this.node.nextSibling;
		const node = this.node;
		if (!node || !check(node)) throw new Mismatch(`expected ${what}, found ${node ? node.nodeName : "nothing"}`);
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
		if (this.node !== end) throw new Mismatch(`expected the end of a range, found ${this.node?.nodeName ?? "nothing"}`);
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

const RANGES = new Set(["app", "html", "list", "loading", "errored", "x", "show", "for", "row", "fallback", "nohydration"]);
/** The elements whose content the HTML parser reads as text (RCDATA): the server writes no hole's
 * comments inside one (they would show), and hydrating binds its holes to its text. */
const RCDATA = new Set(["title", "textarea"]);
const VOID = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);
const escape = (text) => String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

/** The bootstrap the host puts before a page's `</body>` (server/host/src/signals.rs's `START`). */
const START = '<script type="module" data-rocx src="/rocx/start.js"></script>';

/** Markup that is a whole document: `<html>` at its top, after a doctype and any holes' comments. */
const DOCUMENT = /^\s*(?:<!--[^>]*-->\s*|<!doctype[^>]*>\s*)*<html[\s>]/i;

/** The SVG namespace: an element inside an <svg> is made in it, or the browser doesn't draw it. */
const SVG = "http://www.w3.org/2000/svg";

/** Parts a walk for transitions passes over: theirs play when they come or go themselves. */
const OWN_PARTS = new Set(["show", "for", "leaving"]);

/** Whether someone asked their system for less motion: then no transition plays. */
const reducedMotion = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;

/** A CSS property as `element.animate` names it: `transform-origin` is `transformOrigin`. */
const camel = (property) => property.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());

/** The scope an element's children are made in: an <svg>'s know they are SVG, so a <For>'s row or
 * a <Show>'s part made inside one later, in the browser, is SVG too. */
const within = (node, scope) => (node.tag === "svg" && !scope.svg ? { ...scope, svg: true } : scope);

export class Runtime {
	/**
	 * `base` is the path the site is served under (`/`, or `/rocx/` for a copy at
	 * `example.github.io/rocx/`): a URL Roc gives that begins with `/` (a server function's, an
	 * endpoint's) is asked for under it.
	 */
	/**
	 * The runtime, its app's wasm loaded from `source`. `effects` are the page's own functions Roc's
	 * handlers may call (`Browser.call!(name, arg)`), by name, each given the argument, parsed; one
	 * not there is looked for on `window.rocxEffects` too, for a page start.js wakes up.
	 */
	/**
	 * A split app (`rocx build --split`): `app.wasm` is the main module, and each page's code is a
	 * chunk of its own (`app.<Page>.wasm`, `app.Shared.wasm`), sharing its memory and table. `chunk`
	 * gives a chunk's bytes (or a `Response`) by its name; `preload` names the ones to have in before
	 * this answers (the page's, which start.js reads from the server's `<link data-rocx-chunk>`s).
	 * Until a chunk is in, the main module calls its functions through placeholders: a call waits
	 * for it, as for a server function's answer, and runs again once it is. `strict`: a call into
	 * `Unreached` (code the build found nothing reaches) throws, rather than only being told.
	 */
	static async load(source, { base = "/", call = (name, input) => callServer(name, input, base), effects = {}, chunk = null, preload = [], strict = false } = {}) {
		let runtime;
		const env = new Proxy({}, { get: (_, name) => (...args) => runtime.imports[name](...args) });
		const resolved = await source;
		const bytes = resolved instanceof Response ? await resolved.arrayBuffer() : resolved;
		const module = await WebAssembly.compile(bytes);
		const placeholders = {};
		for (const wanted of WebAssembly.Module.imports(module)) {
			if (!wanted.module.startsWith(PLACEHOLDER)) continue;
			const owner = wanted.module.slice(PLACEHOLDER.length);
			(placeholders[wanted.module] ??= {})[wanted.name] = () => runtime.placeholder(owner, wanted.name);
		}
		const instance = await WebAssembly.instantiate(module, { env, ...placeholders });
		runtime = new Runtime(instance.exports, call, base);
		runtime.effects = effects;
		runtime.split = { env, source: chunk, strict, owners: new Set(Object.keys(placeholders).map((name) => name.slice(PLACEHOLDER.length))) };
		await Promise.all(preload.map((owner) => runtime.loadChunk(owner)));
		return runtime;
	}

	/** Loads a split app's chunk (once): instantiated against the main module, its functions take
	 * their places in the table, and its data in memory. */
	loadChunk(owner) {
		let chunk = this.chunks.get(owner);
		if (chunk) return chunk.promise;
		chunk = { state: "pending" };
		this.chunks.set(owner, chunk);
		const started = performance.now();
		const source = this.split?.source;
		chunk.promise = (source ? Promise.resolve(source(owner)) : Promise.reject(new Error("no one said where the app's chunks are")))
			.then((given) => (given instanceof Response ? (given.ok ? given.arrayBuffer() : Promise.reject(new Error(`${given.status} ${given.statusText}`))) : given))
			.then((bytes) => WebAssembly.instantiate(bytes, { primary: this.ex, env: this.split.env }))
			.then(
				() => {
					chunk.state = "ok";
					this.notify("chunk", { owner, ms: performance.now() - started });
				},
				(error) => {
					chunk.state = "failed";
					chunk.error = `rocx: app.${owner}.wasm didn't load: ${error.message ?? error}`;
					this.notify("chunk", { owner, error: chunk.error, ms: performance.now() - started });
				},
			);
		return chunk.promise;
	}

	/** The main module called a function of a chunk that isn't in: it waits for it, then runs again.
	 * Code the build found nothing reaches (`Unreached`) is never loaded quietly. */
	placeholder(owner, slot) {
		if (owner === UNREACHED) {
			const why = `rocx: the app called code its build found nothing reaches (app.Unreached.wasm, placeholder ${slot}): the split missed a reference`;
			console.error(why);
			if (this.split?.strict || this.onServer) throw new Error(why);
		}
		const chunk = this.chunks.get(owner);
		if (chunk?.state === "failed") throw new Failed(chunk.error);
		if (this.onServer) throw new Error(`rocx: rendering needs app.${owner}.wasm (placeholder ${slot}), which isn't loaded`);
		if (!this.chunks.has(owner)) this.notify("chunk-late", { owner, slot });
		this.loadChunk(owner);
		throw new NotReady(this.chunks.get(owner).promise);
	}

	constructor(exports, call, base = "/") {
		this.ex = exports;
		this.callServer = call;
		/** The path the site is served under, ending with `/`. */
		this.base = base.endsWith("/") ? base : `${base}/`;
		/** Boxes kept for Roc, by id: computations, handlers, fallbacks. */
		this.kept = new Map();
		this.signals = new Map();
		this.memos = new Map();
		/** Each <For>'s rows, by key; its rows' indexes; and, unkeyed, its items by position. */
		this.lists = new Map();
		this.boundaries = new Map();
		/** The browser's timers for Roc's (`Solid.set_timeout!`, `set_interval!`), by the id of the
		 * handler's box: `{ repeat, handle }`. */
		this.timers = new Map();
		/** The page's functions handlers call (`Browser.call!`), and the calls waiting for the patch.
		 * Those named `rocx:…` are the runtime's own: `Audio.play!` is `rocx:audio`. */
		this.effects = {};
		this.calling = [];
		this.builtins = { "rocx:audio": (arg) => this.playAudio(arg) };
		/** Each element's transitions (`transition={…}`), `{ in, out }`, as `Transition.json` writes
		 * them; `animates` once there is one, so an app without any walks nothing for them. */
		this.transitions = new WeakMap();
		this.animates = false;
		/** Elements whose in-transition plays once what this flush changes is on the page. */
		this.entering = [];
		/** The `<Title>`s there are, by the computation of each one's hole: `{ seq, title }`, the
		 * highest `seq` (the last rendered) the document's (`showTitle`); `titled`, rendering as a
		 * server would, the page's. */
		this.titles = new Map();
		this.titleSeqs = 0;
		this.titlesDirty = false;
		this.titled = null;
		/** Rows and parts on their way out, by their first comment: each stays, inert, until its
		 * transitions are over. A <For> putting its rows in order passes over them. */
		this.leaving = new Map();
		/** Letting go of what is inside a part that is leaving: its <For>s' rows stay with it. */
		this.keeping = false;
		/** The computation or handler running now. */
		this.current = null;
		this.dirty = new Set();
		/** Effects whose apply is due, after the flush. */
		this.due = new Set();
		this.flushing = false;
		/** The endpoints whose forms the runtime sends (`use_submission!`), by URL, and how many ask;
		 * the latest submission to each, a source computations read; whether it listens for submits. */
		this.actions = new Map();
		this.submissions = new Map();
		this.submitting = null;
		/** In the browser: the flash the page came with (`Server.flash!`). On the server: the flash
		 * the page being rendered read, for the page to carry. */
		this.flash = "";
		this.flashed = "";
		this.taken = null;
		this.stats = { runs: 0, aborts: 0, patches: 0 };
		/** In the browser: answers the server gave while rendering the page, by name and input. */
		this.answers = new Map();
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
		/** The server function whose call is being answered (`Host.serve!`), and what its middleware
		 * handed on (JSON): none here, since the server platform answers every call. */
		this.serving = { name: "", context: "" };
		/** The status the page is answered with (`<HttpStatusCode>`), rendering as a server would. */
		this.status = 200;
		/** The page the runtime is on: where it listens for forms' submits. */
		this.page = typeof document === "undefined" ? null : document;
		/** Whoever wants to see what the runtime does, as it does it (the docs' inspector): an object
		 * with any of `seeded`, `call`, `answer`, `fetch`, `fetched`, `listen`, `heard`, `patch`,
		 * `row`, `show`, `frame`, `effect` (a call of the page's own function), `apply` (an effect's
		 * apply) and `submit`. */
		this.observer = null;
		/** A split app's chunks (`app.<Page>.wasm`), by name: `{ state, promise, error }`. */
		this.chunks = new Map();
		this.split = null;
		this.imports = this.makeImports();
	}

	notify(kind, detail) {
		if (this.observer) this.observer[kind]?.(detail);
	}

	// ---- Calling Roc ----

	text(ptr, len) {
		return decoder.decode(new Uint8Array(this.ex.memory.buffer, ptr >>> 0, len >>> 0));
	}

	/** Calls an export; an abort leaves Roc's stack pointer where the unwound frames left it: restore it. */
	enter(call) {
		const sp = this.ex.__stack_pointer.value;
		try {
			call();
			return this.text(this.ex.result_ptr(), this.ex.result_len());
		} catch (error) {
			this.ex.__stack_pointer.value = sp;
			throw error;
		}
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
				(this.current?.making?.kept ?? []).push(id);
				return id;
			},
			js_signal_new: (ptr) => {
				const id = ++ids;
				this.signals.set(id, { id, value: ptr, observers: new Set() });
				// It belongs to the run that made it: when that run's part goes, it goes too.
				this.current?.making?.signals?.push(id);
				return id;
			},
			js_signal_get: (id) => {
				const signal = this.signals.get(id);
				if (!signal) throw new Error("rocx: a signal was read after the part that made it went away");
				this.track(signal);
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
				const memo = new Computation(this, { kind: "memo", runner: ptr, owner: this.current, scope: this.current?.scope ?? {} });
				memo.state = "pending";
				memo.value = 0;
				this.memos.set(memo.id, memo);
				this.run(memo);
				return memo.id;
			},
			js_memo_done: (ptr) => {
				if (this.current?.next) this.ex.release(this.current.next);
				this.current.next = ptr;
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
				const probe = { kind: "probe", memos: new Set(), calls: new Map() };
				const previous = this.current;
				this.current = probe;
				try {
					this.enter(() => this.ex.run(ptr));
				} catch (error) {
					if (!(error instanceof NotReady || error instanceof Failed)) throw error;
				} finally {
					this.current = previous;
					this.ex.release(ptr);
				}
				for (const memo of probe.memos) this.later({ refresh: memo });
			},
			js_call: (namePtr, nameLen, inputPtr, inputLen) => this.call(text(namePtr, nameLen), text(inputPtr, inputLen)),
			js_fail: (ptr, len) => {
				throw new Failed(text(ptr, len));
			},
			js_event_value: () => this.give(this.current?.event ?? ""),
			js_boundary: () => this.current.boundary.id,
			js_problem: () => this.give(this.current.boundary.failed ?? ""),
			js_retry: (id) => this.later({ retry: this.boundaries.get(id) }),
			js_request: () => this.give(this.request),
			// A server copy's call, answered (`Server.local`): rendering as a server would, `call`
			// recorded it already, from the page's answers (and not inside a <NoHydration>, which the
			// browser never hydrates). The server platform's host records its own.
			js_record: () => {},
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
			js_row_set: (id, keyPtr, keyLen, ptr) => {
				const items = this.lists.get(id).items;
				const at = text(keyPtr, keyLen);
				const item = items.get(at);
				if (!item) return items.set(at, { value: ptr, observers: new Set() });
				this.ex.release(item.value);
				item.value = ptr;
				for (const observer of item.observers) this.schedule(observer);
			},
			js_row_get: (id, keyPtr, keyLen) => {
				const item = this.lists.get(id).items.get(text(keyPtr, keyLen));
				this.track(item);
				return item.value;
			},
			// A provider's value: kept while the run that made it is, as a computation's box is.
			js_context_value: (ptr) => {
				const id = ++ids;
				this.kept.set(id, ptr);
				(this.current?.making?.kept ?? []).push(id);
				return id;
			},
			js_context_find: (ptr, len) => this.current?.scope?.contexts?.[text(ptr, len)] ?? 0,
			js_context_get: (id) => this.kept.get(id),
			js_fetch: (mp, ml, up, ul, hp, hl, bp, bl) => this.fetchFor(text(mp, ml), text(up, ul), text(hp, hl), text(bp, bl)),
			js_listen: (up, ul, ptr) => this.listenTo(text(up, ul), ptr),
			js_timer: (ms, repeat, ptr) => this.startTimer(ms, repeat === 1, ptr),
			js_clear_timer: (id) => this.clearTimer(id),
			js_browser_call: (np, nl, ap, al) => {
				const name = text(np, nl);
				const handler = this.current;
				// Only a handler acts: a computation runs again whenever what it read changes.
				if (handler?.kind !== "handler") throw new Failed(`Browser.call!("${name}") is a handler's: call it from an event, a frame or a timer, not while computing`);
				handler.writes.push({ effect: name, arg: text(ap, al) });
			},
			js_serve: (np, nl, cp, cl) => {
				this.serving = { name: text(np, nl), context: text(cp, cl) };
			},
			js_serving: () => this.give(this.serving.name),
			js_context: () => this.give(this.serving.context),
			js_location: () => this.give(this.location()),
			js_status: (code) => {
				if (this.onServer) this.status = code;
			},
			// An effect: owned by the component or computation running, its compute run now. On the
			// server, nothing (Solid's server doesn't run effects).
			js_effect_new: (ptr) => {
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
				this.run(effect);
			},
			js_cleanup: (ptr) => {
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
				if (!this.onServer) return this.give(this.flash);
				const found = text(ptr, len);
				if (found) this.flashed = found;
				return this.give(found);
			},
			js_action: (ptr, len) => {
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
			js_submission: (ptr, len) => {
				if (this.onServer) return this.give("");
				const source = this.submissionOf(this.actionKey(text(ptr, len)));
				this.track(source);
				return this.give(source.value ? JSON.stringify(source.value) : "");
			},
			js_submission_clear: (ptr, len) => {
				if (!this.onServer) this.later({ cleared: this.actionKey(text(ptr, len)) });
			},
			// A <Title>'s hole: rendering as a server would, the page's title (the last one rendered);
			// in the browser, its computation's, until it runs again or goes (`showTitle`).
			js_title: (ptr, len) => {
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
		};
	}

	/** Where a cleanup made now goes: the running computation's run, or an effect's apply. */
	cleanupsOf(current) {
		return current?.making?.cleanups ?? current?.cleanups ?? null;
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

	submissionOf(key) {
		let source = this.submissions.get(key);
		if (!source) this.submissions.set(key, (source = { value: null, seq: 0, observers: new Set() }));
		return source;
	}

	setSubmission(source, value) {
		source.value = value;
		for (const observer of source.observers) this.schedule(observer);
	}

	/** Listens for forms submitted on the page, once: `submitted` sends the ones it should. */
	listenForSubmits() {
		if (this.submitting || typeof this.page?.addEventListener !== "function") return;
		this.submitting = (event) => this.submitted(event);
		this.page.addEventListener("submit", this.submitting);
	}

	/**
	 * A form submitted: sent with fetch if it posts (not multipart) to an endpoint a component reads
	 * the submission of, on this site, and no handler prevented its submit. Its fields go as a form
	 * does, URL-encoded, with `accept: application/json` and `x-rocx-submission: 1`, so the endpoint
	 * answers its result, or its refusal, rather than sending the browser back with a flash. Any
	 * other form is the browser's.
	 */
	submitted(event) {
		if (event.defaultPrevented) return;
		const form = event.target;
		if (!form || form.localName !== "form") return;
		const submitter = event.submitter ?? null;
		const of = (name, attribute) => (submitter?.hasAttribute(attribute) ? submitter.getAttribute(attribute) : form.getAttribute(name)) ?? "";
		if (of("method", "formmethod").toLowerCase() !== "post") return;
		if (["multipart/form-data", "text/plain"].includes(of("enctype", "formenctype").toLowerCase())) return;
		const url = new URL(of("action", "formaction"), location.href);
		if (url.origin !== location.origin) return;
		const key = `${this.unbased(url.pathname)}${url.search}`;
		if (!this.actions.has(key)) return;
		event.preventDefault();
		this.submit(key, url.href, new URLSearchParams(new FormData(form, submitter ?? undefined)).toString());
	}

	/**
	 * Sends a form's fields to an endpoint, the latest submission to it pending until its answer is
	 * in: 200, its result (JSON); any other status, a refusal; none, status 0 and why. A redirect of
	 * the endpoint's own (`x-rocx-redirect`), or one fetch followed (middleware's), is where the
	 * browser goes. An answer to a submission that isn't the latest is dropped.
	 */
	submit(key, href, input) {
		const source = this.submissionOf(key);
		const seq = ++source.seq;
		this.setSubmission(source, { state: "pending", input, status: 0, body: "" });
		const asked = performance.now();
		this.notify("submit", { url: key, input });
		fetch(href, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json", "x-rocx-submission": "1" }, body: input }).then(
			async (response) => {
				const to = response.headers.get("x-rocx-redirect");
				if (to !== null || response.redirected) {
					this.notify("submitted", { url: key, input, status: response.status, redirect: to ?? response.url, ms: performance.now() - asked });
					location.assign(to !== null ? new URL(this.under(to), location.href).href : response.url);
					return;
				}
				const body = await response.text();
				this.notify("submitted", { url: key, input, status: response.status, body, ms: performance.now() - asked });
				if (source.seq === seq) this.setSubmission(source, { state: "done", input, status: response.status, body });
			},
			(error) => {
				const why = `POST ${key}: ${error?.message ?? error}`;
				this.notify("submitted", { url: key, input, error: why, ms: performance.now() - asked });
				if (source.seq === seq) this.setSubmission(source, { state: "done", input, status: 0, body: why });
			},
		);
	}

	/** A read in a computation: it runs again when what it read changes. */
	track(source) {
		const reader = this.current;
		if (!reader?.making) return;
		reader.making.sources.add(source);
	}

	/** In a handler, applied when it is done; elsewhere, now. */
	later(write) {
		if (this.current?.kind === "handler") this.current.writes.push(write);
		else this.apply([write]);
	}

	/** Where the page is (`Router.location!`): rendering as a server would, the request's path and
	 * query; in the browser, `location.pathname` without the site's base, and `location.search`. A
	 * trailing slash is dropped. So the browser sees what the server does. */
	location() {
		const target = this.onServer ? (/^\S+ (\S*)/.exec(this.request)?.[1] ?? "/") : typeof location === "undefined" ? "/" : `${this.unbased(location.pathname)}${location.search}`;
		const [path, query] = target.split(/\?(.*)/s);
		const trimmed = path.length > 1 ? path.replace(/\/+$/, "") || "/" : path || "/";
		return query === undefined ? trimmed : `${trimmed}?${query}`;
	}

	/**
	 * A server function's answer, for the running computation or handler: from its calls if in, or
	 * asked for now. Rendering as a server would, it is the answer the page recorded
	 * (`renderToString({ answers })`): the server platform answers a call by its route, natively.
	 */
	call(name, input) {
		if (this.onServer) {
			// Rendering from a page's answers: only those, recorded as the page has them; any other is a
			// call the server didn't make, a 599.
			const found = this.given?.find(([named, asked]) => named === name && asked === input);
			if (!found) throw new Failed(`599: ${name}(${input}) wasn't answered as the server rendered the page`);
			if (!this.current?.scope?.region) this.recorded.push(found);
			return this.give(found[2]);
		}
		const asking = this.current;
		const key = `${name}\n${input}`;
		let answer = asking.calls.get(key);
		if (!answer && this.answers.has(key)) {
			// The server answered it while rendering the page: read here, not asked again.
			answer = { state: "ok", value: this.answers.get(key) };
			asking.calls.set(key, answer);
			this.notify("seeded", { name, input, value: answer.value });
		}
		if (!answer) {
			answer = { state: "pending" };
			const asked = performance.now();
			this.notify("call", { name, input });
			answer.promise = this.callServer(name, input).then(
				(value) => {
					Object.assign(answer, { state: "ok", value });
					this.notify("answer", { name, input, value, ms: performance.now() - asked });
				},
				(error) => {
					Object.assign(answer, { state: "failed", error: `${name} failed: ${error.message ?? error}` });
					this.notify("answer", { name, input, error: answer.error, ms: performance.now() - asked });
				},
			);
			asking.calls.set(key, answer);
		}
		asking.used?.add(key);
		if (answer.state === "pending") throw new NotReady(answer.promise);
		if (answer.state === "failed") throw new Failed(answer.error);
		return this.give(answer.value);
	}

	/**
	 * An HTTP request for the running computation or handler (`Call.fetch!`): its answer, as
	 * `{"status":…,"body":…}`, from its calls if in, or asked for now (and it waits, as for a server
	 * function's).
	 */
	fetchFor(method, url, headerLines, body) {
		const asking = this.current;
		const key = `${method} ${url}\n${body}`;
		let answer = asking.calls.get(key);
		if (!answer) {
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
			asking.calls.set(key, answer);
		}
		asking.used?.add(key);
		if (answer.state === "pending") throw new NotReady(answer.promise);
		if (answer.state === "failed") throw new Failed(answer.error);
		return this.give(answer.value);
	}

	/** `url` under the site's base, if it begins with `/` (and isn't `//host/…`). */
	under(url) {
		return url.startsWith("/") && !url.startsWith("//") ? `${this.base}${url.slice(1)}` : url;
	}

	/** A path the browser shows, the site's base taken off: under `/rocx/`, `/rocx/syntax` is
	 * `/syntax` and `/rocx` is `/`; a path not under it stays as it is. */
	unbased(path) {
		const base = this.base.slice(0, -1);
		if (!base || (path !== base && !path.startsWith(this.base))) return path;
		return path.slice(base.length) || "/";
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
		else this.current?.owner?.made?.kept.push(id);
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

	/**
	 * A sound file, played (`Audio.play!`): any the browser can, fetched the first time and kept by it,
	 * at a volume and a rate, its pitch moving with its speed. Until the reader has done something on
	 * the page the browser refuses to play it, and that is no failure.
	 */
	playAudio({ url, volume = 1, rate = 1 }) {
		if (typeof Audio === "undefined") return;
		const sound = new Audio(this.under(url));
		sound.volume = Math.min(Math.max(volume, 0), 1);
		sound.preservesPitch = false;
		sound.playbackRate = Math.min(Math.max(rate, 0.0625), 16);
		sound.play()?.catch((error) => {
			if (error?.name !== "NotAllowedError") console.error(`rocx: the sound ${url} can't be played: ${error?.message ?? error}`);
		});
	}

	// ---- Running ----

	/** Runs a computation. A complete run replaces what the last one made; one that aborts or fails
	 * keeps it. The last complete run's cleanups run first, as Solid runs them before a run again. */
	run(computation) {
		if (computation.disposed) return;
		this.cleanUp(computation.made.cleanups);
		const making = making_();
		const previous = this.current;
		this.current = computation;
		computation.making = making;
		computation.used = new Set();
		this.stats.runs++;
		let out;
		let outcome = "ok";
		let failure = null;
		try {
			out = this.enter(() => (computation.kind === "root" ? this.ex.mount() : this.ex.run(computation.runner)));
		} catch (error) {
			if (error instanceof NotReady) {
				outcome = "pending";
				this.stats.aborts++;
				error.wait.then(() => this.schedule(computation));
			} else if (error instanceof Failed) {
				outcome = "failed";
				failure = error;
			} else throw error;
		} finally {
			this.current = previous;
		}
		// What it reads now is what it depends on, whatever the outcome.
		for (const source of computation.sources) source.observers.delete(computation);
		computation.sources = making.sources;
		for (const source of computation.sources) source.observers.add(computation);
		if (outcome === "ok") {
			computation.making = making;
			try {
				this.settle(computation, out);
			} finally {
				// Even if settling threw (hydrating found a mismatch): what it made is the computation's
				// now, so disposing it lets go of all of it.
				const old = computation.made;
				computation.made = making;
				computation.making = null;
				this.drop(old);
			}
			// Answers this run didn't ask for are stale.
			for (const key of computation.calls.keys()) if (!computation.used.has(key)) computation.calls.delete(key);
			computation.scope.loading?.done(computation);
		} else {
			computation.making = null;
			this.drop(making);
			if (computation.kind === "memo") {
				if (computation.next) this.ex.release(computation.next);
				computation.next = 0;
			}
			if (outcome === "pending" && computation.kind === "root") {
				// Run again, a component would make its memos again, and ask the server again, forever.
				throw new Error("rocx: a component read a value that isn't in yet outside its markup: read it in a hole ({…}), which waits");
			}
			// An effect is no part of the markup: it holds no <Loading>.
			if (outcome === "pending") {
				if (computation.kind !== "reaction") computation.scope.loading?.wait(computation);
			} else this.failed(computation, failure);
		}
	}

	/** A complete run's answer, applied: the node patched, or the memo's value set. */
	settle(computation, out) {
		const { kind, target, name } = computation;
		if (kind === "memo") {
			if (computation.value) this.ex.release(computation.value);
			computation.value = computation.next;
			computation.next = 0;
			computation.state = "ok";
			computation.settle?.();
			computation.settled = computation.settle = null;
			for (const observer of computation.observers) this.schedule(observer);
			return;
		}
		if (kind === "reaction") {
			// Its apply (the box its compute kept, by id), run after the flush.
			computation.apply = Number(out);
			this.due.add(computation);
			this.wake();
			return;
		}
		if (kind === "show") return this.settleShow(computation, JSON.parse(out));
		if (kind === "for") return this.settleFor(computation, JSON.parse(out));
		if (kind === "transition") return this.setTransition(target, name, JSON.parse(out));
		if (kind === "text" || kind === "attr" || kind === "flag" || kind === "class" || kind === "optional" || kind === "style") {
			// A value the node has already isn't a patch (a hole runs again whenever what it read
			// was written, which may be with the same value).
			const value = JSON.parse(out);
			if (computation.adopting && kind === "text") {
				computation.adopting = false;
				target.data = value;
				return;
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
			return;
		}
		if (target?.document) return this.settleDocument(computation, JSON.parse(out));
		if (kind === "html" || kind === "root") {
			const parsed = JSON.parse(out);
			const nodes = Array.isArray(parsed) ? parsed : [parsed];
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
			const fragment = document.createDocumentFragment();
			for (const node of nodes) fragment.append(this.build(node, computation, computation.scope));
			replaceRange(target, fragment);
		}
	}

	failed(computation, failure) {
		const memo = computation.kind === "memo" ? computation : failure.memo;
		computation.scope.loading?.done(computation);
		if (computation.kind === "memo") {
			computation.state = "failed";
			computation.error = failure.message;
			computation.settle?.();
			computation.settled = computation.settle = null;
			for (const observer of computation.observers) this.schedule(observer);
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
			this.ex.release(signal.value);
		}
	}

	dispose(computation) {
		if (!computation || computation.disposed) return;
		computation.disposed = true;
		for (const source of computation.sources) source.observers.delete(computation);
		computation.scope.loading?.done(computation);
		if (computation.kind === "reaction") {
			// Its last apply's cleanups; its compute is its own box, as a memo's is.
			this.due.delete(computation);
			this.cleanUp(computation.cleanups);
			this.ex.release(computation.runner);
		}
		this.drop(computation.made);
		// What it shows (a <Show>'s part, a <For>'s rows) is its own, not its last run's.
		if (computation.part) this.dispose(computation.part);
		if (computation.list) this.dropList(computation.list);
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
		const oldest = (set) => [...set].sort((a, b) => a.id - b.id)[0];
		for (;;) {
			if (this.dirty.size) {
				const next = oldest(this.dirty);
				this.dirty.delete(next);
				this.run(next);
			} else if (this.due.size) {
				const next = oldest(this.due);
				this.due.delete(next);
				this.applyReaction(next);
			} else break;
		}
		this.flushing = false;
		if (this.entering.length) this.playEntering();
		// The title before the page's functions, so one sees the page as the flush left it.
		if (this.titlesDirty) this.showTitle();
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

	/**
	 * The page's functions the handlers that are done called (`Browser.call!`), in order, now that the
	 * page is patched with what they wrote. One that isn't there, or throws, is told on the console.
	 */
	callEffects() {
		const calls = this.calling;
		this.calling = [];
		for (const { effect: name, arg } of calls) {
			this.notify("effect", { name, arg });
			const effect = name.startsWith("rocx:") ? this.builtins[name] : (this.effects[name] ?? globalThis.rocxEffects?.[name]);
			if (typeof effect !== "function") {
				console.error(`rocx: no effect is called ${name}: give the runtime one (Runtime.load(wasm, { effects: { ${name}(arg) {…} } }))`);
				continue;
			}
			try {
				effect(JSON.parse(arg));
			} catch (error) {
				console.error(`rocx: the effect ${name} failed:`, error);
			}
		}
	}

	/** An effect's apply: its last apply's cleanups first, then the box its compute kept, as a
	 * handler (untracked; its writes applied when it is done), owning what it starts. */
	applyReaction(effect) {
		if (effect.disposed || !this.kept.has(effect.apply)) return;
		this.cleanUp(effect.cleanups);
		this.notify("apply", { id: effect.id });
		this.handle(effect.apply, "", effect.scope, { owner: effect, cleanups: effect.cleanups });
	}

	/** Computes a memo again, asking the server again. A failed one waits from now on, so what reads
	 * it next (an <Errored> trying again) waits for the new answer instead of failing again. */
	refresh(memo) {
		memo.calls.clear();
		if (memo.state === "failed") {
			memo.state = "pending";
			memo.error = null;
		}
		this.schedule(memo);
	}

	/** Writes a handler made, applied together once it is done. */
	apply(writes) {
		for (const write of writes) {
			if (write.signal) {
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
				const source = this.submissionOf(write.cleared);
				source.seq++;
				this.setSubmission(source, { state: "cleared", input: "", status: 0, body: "" });
			}
		}
	}

	/** Runs a handler (the id of its box). If it waits for a server function's answer, its writes are
	 * dropped, and it runs again once the answer is in. Its `owner` is the computation a timer it
	 * starts belongs to; an effect's apply passes its `cleanups`, where what it starts goes (dropped
	 * too, run, if it waits); `done`, if any, is called once it has run (or failed). */
	handle(runner, event, scope = null, { owner = null, cleanups = null, done = null } = {}) {
		// Its scope: the contexts and region where it was bound.
		const handler = { kind: "handler", runner, calls: new Map(), writes: [], event, scope, owner, cleanups };
		const go = () => {
			const previous = this.current;
			this.current = handler;
			handler.writes = [];
			const mark = cleanups?.length ?? 0;
			try {
				this.enter(() => this.ex.run(this.kept.get(handler.runner)));
			} catch (error) {
				for (const write of handler.writes) if (write.signal) this.ex.release(write.value);
				if (cleanups) {
					this.current = previous;
					this.cleanUp(cleanups.splice(mark));
				}
				if (error instanceof NotReady) {
					this.stats.aborts++;
					error.wait.then(() => this.kept.has(handler.runner) && go());
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

	// ---- <Show> and <For> ----

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
		const { node, target, scope } = computation;
		const outs = first || adopting ? [] : this.transitioned(target, "out");
		if (outs.length) {
			const going = { start: target.start, end: document.createComment("/leaving") };
			target.start = document.createComment("show");
			target.end.before(going.end, target.start);
			this.keep(() => this.dispose(computation.part));
			this.leave(going, outs);
		} else this.dispose(computation.part);
		if (holds && node.with) {
			// A function child: made when it shows, by its own computation (it reads the narrowed value).
			const made = new Computation(this, { kind: "html", runner: this.kept.get(node.with), owner: null, scope, target });
			made.adopting = adopting;
			computation.part = made;
			this.run(made);
		} else computation.part = this.part(holds ? node.c : [node.fallback], scope, target, adopting);
		if (!first && !adopting) this.entered(target);
		if (!adopting) this.notify("show", { holds, nodes: inside(target) });
	}

	/**
	 * A <For>'s rows, from what its list says now (`[{k, r}]`): a row whose key is still there is
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
		const cursor = adopting ? new Cursor(target.start.nextSibling) : null;
		const kept = computation.making.kept;
		const rows = new Map();
		entries.forEach(({ k, r }, index) => {
			let row = list.rows.get(k);
			const mine = kept.indexOf(r);
			if (mine >= 0) kept.splice(mine, 1);
			if (row) {
				// Still there: the box this run made for it isn't needed.
				this.ex.release(this.kept.get(r));
				this.kept.delete(r);
				const at = list.indexes.get(k);
				if (at.value !== index) {
					at.value = index;
					for (const observer of at.observers) this.schedule(observer);
				}
			} else {
				list.indexes.set(k, { value: index, observers: new Set() });
				const range = adopting ? { start: cursor.comment("row"), end: cursor.closing("row") } : makeRange("row");
				row = { key: k, runner: r, range, fresh: !adopting };
				row.computation = new Computation(this, { kind: "html", runner: this.kept.get(r), owner: null, scope, target: range });
				row.computation.adopting = adopting;
				this.run(row.computation);
				if (later && !adopting) this.entered(range);
				if (adopting) cursor.node = range.end.nextSibling;
			}
			rows.set(k, row);
		});
		for (const [key, row] of list.rows) if (!rows.has(key)) this.dropRow(list, row, true);
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
		// Rows in order: one already where it goes stays; the others move (or arrive) there. A row on
		// its way out stays where it is, passed over.
		let at = target.start.nextSibling;
		const pass = () => {
			while (this.leaving.has(at)) at = this.leaving.get(at).end.nextSibling;
		};
		pass();
		for (const row of rows.values()) {
			if (row.range.start === at) {
				at = row.range.end.nextSibling;
				pass();
			} else {
				if (row.range.start.parentNode === null || row.range.start.parentNode.nodeType === 11) at.before(row.range.fragment ?? collectRange(row.range));
				else at.before(collectRange(row.range));
				this.stats.patches++;
				this.notify("row", { what: row.fresh ? "made" : "moved", key: row.key, nodes: inside(row.range) });
			}
			row.fresh = false;
		}
	}

	/** A row goes: at once, or (`animated`, its key gone from the list) once the transitions out of
	 * what is in it are over. Inside a part that is leaving, it stays, to go with the part. */
	dropRow(list, row, animated = false) {
		this.notify("row", { what: "dropped", key: row.key, nodes: [] });
		const outs = animated && !this.keeping ? this.transitioned(row.range, "out") : [];
		if (outs.length) this.keep(() => this.dispose(row.computation));
		else this.dispose(row.computation);
		this.ex.release(this.kept.get(row.runner));
		this.kept.delete(row.runner);
		list.indexes.delete(row.key);
		if (outs.length) this.leave(row.range, outs);
		else if (!this.keeping) removeRange(row.range);
	}

	/** A <For> goes: its rows, and its items. Its id stays: what made it still names it, and may
	 * build it again (an <Errored> trying again). */
	dropList(list) {
		for (const row of list.rows.values()) this.dropRow(list, row);
		for (const item of list.items.values()) this.ex.release(item.value);
		list.items.clear();
		list.rows.clear();
	}

	// ---- Transitions ----

	/** An element's transition (`way`: "in", "out" or "both"), from the markup or a computation. */
	setTransition(element, way, spec) {
		let own = this.transitions.get(element);
		if (!own) this.transitions.set(element, (own = { in: null, out: null }));
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
				this.run(computation);
				return text;
			}
			case "h":
			case "l": {
				const range = makeRange(node.t === "h" ? "html" : "list");
				this.run(new Computation(this, { kind: "html", runner: this.kept.get(node.r), owner, scope, target: range }));
				return range.fragment;
			}
			case "f": {
				const fragment = document.createDocumentFragment();
				for (const child of node.c) fragment.append(this.build(child, owner, scope));
				return fragment;
			}
			case "e":
				return this.element(node, owner, scope);
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

	element(node, owner, scope) {
		const element = node.tag === "script" ? inertScript() : node.tag === "svg" || scope.svg ? document.createElementNS(SVG, node.tag) : document.createElement(node.tag);
		// Its classes in one `class`, first, as the server writes them.
		const classes = [];
		for (const [kind, name, value] of node.a) {
			if (kind === "v" && name === "class") classes.push(value);
			else if (kind === "ci" && value) classes.push(name);
		}
		if (classes.length) element.setAttribute("class", classes.join(" "));
		for (const [kind, name, value] of node.a) {
			if (kind === "v" && name !== "class") element.setAttribute(name, value);
			else if (kind === "o" && value !== "") element.setAttribute(name, value);
			else if (kind === "f") element.toggleAttribute(name, value);
			else if (kind === "sv" && value) element.style.setProperty(name, value);
		}
		this.bind(element, node, owner, scope);
		const inside = within(node, scope);
		for (const child of node.c) element.append(this.build(child, owner, inside));
		return element;
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
				cursor.comment("x");
				let text = cursor.node?.nodeType === 3 ? cursor.take(() => true, "text") : null;
				const end = cursor.comment("/x");
				if (!text) end.before((text = document.createTextNode("")));
				this.run(new Computation(this, { kind: "text", runner: this.kept.get(node.r), owner, scope, target: text }));
				return;
			}
			case "h":
			case "l": {
				const label = node.t === "h" ? "html" : "list";
				const start = cursor.comment(label);
				const end = cursor.closing(label);
				const computation = new Computation(this, { kind: "html", runner: this.kept.get(node.r), owner, scope, target: { start, end } });
				computation.adopting = true;
				this.run(computation);
				cursor.node = end.nextSibling;
				return;
			}
			case "f":
				for (const child of node.c) this.adopt(child, owner, scope, cursor);
				return;
			case "e": {
				// The parser makes the `<head>` a document leaves out: an empty one is passed over.
				if (node.tag === "body" && cursor.top && cursor.node?.localName === "head" && !cursor.node.firstChild) cursor.node = cursor.node.nextSibling;
				const element = cursor.take((found) => found.nodeType === 1 && found.localName === node.tag, `<${node.tag}>`);
				this.bind(element, node, owner, scope);
				const inner = within(node, scope);
				if (RCDATA.has(node.tag) && node.c.some((child) => child.t !== "s" && child.t !== "raw")) return this.adoptText(element, node, owner, inner);
				if (cursor.rebuild && node.tag === "head") return this.keepHead(element, node, owner, inner);
				if (cursor.rebuild && node.tag === "body") return this.renderBody(element, node, owner, inner);
				const inside = new Cursor(element.firstChild, element, cursor.rebuild && element === element.ownerDocument.documentElement);
				for (const child of node.c) this.adopt(child, owner, inner, inside);
				if (inside.node && !inside.rebuild && !(node.tag === "body" && cursor.top && inside.blankToEnd())) throw new Mismatch(`<${node.tag}> has more than the server's markup says`);
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
	 * (server functions it called), then binds every computation to the server's nodes, running
	 * each once. If the DOM isn't what the markup says, it renders the app again, and says so.
	 */
	hydrate(container) {
		this.seed(container);
		const seeded = new Map(this.answers);
		const start = [...container.childNodes].find((node) => node.nodeType === 8 && node.data === "app");
		const end = [...container.childNodes].find((node) => node.nodeType === 8 && node.data === "/app");
		this.root = new Computation(this, { kind: "root", owner: null, scope: {}, target: { start, end } });
		this.root.adopting = true;
		try {
			if (!start || !end) throw new Mismatch("no <!--app--> in the page");
			this.run(this.root);
		} catch (error) {
			if (!(error instanceof Mismatch)) throw error;
			console.warn(`rocx: the page isn't what the app renders (${error.message}); rendering it again`);
			this.dispose(this.root);
			// Rendering again, the server's answers are still the ones to read, and its regions stay.
			this.answers = seeded;
			this.keepingRegions(container, () => {
				container.replaceChildren();
				this.mount(container);
			});
		}
		this.answers.clear();
	}

	/**
	 * Hydrates the document the server rendered (start.js calls it): reads and removes the answers
	 * the server put in the page, runs the app's root (`main!`) once, and binds every computation to
	 * the server's nodes, from `document.childNodes` down: the doctype to the DocumentType node,
	 * `<html>` to `documentElement`, passing over the host's elements (`[data-rocx]`). If the page
	 * isn't what the app renders (an extension added a node; the parser repaired the markup), it says
	 * so and renders `<body>`'s children again, from the same answers, leaving `<head>` alone, since
	 * rendering it again would run its scripts again and flash its styles. `strict` (the tests')
	 * throws instead.
	 */
	hydrateDocument(doc = document, { strict = false } = {}) {
		this.page = doc;
		this.seed(doc);
		const seeded = new Map(this.answers);
		const root = () => new Computation(this, { kind: "root", owner: null, scope: {}, target: { document: doc } });
		this.root = root();
		this.root.adopting = true;
		try {
			this.run(this.root);
		} catch (error) {
			if (!(error instanceof Mismatch)) throw error;
			this.dispose(this.root);
			if (strict) throw new Error(`rocx: the page isn't what the app renders (${error.message})`);
			console.warn(`rocx: the page isn't what the app renders (${error.message}); rendering <body> again`);
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
		}
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
			if (cursor.node) throw new Mismatch("<head> has more than the server's markup says");
		} catch (error) {
			if (!(error instanceof Mismatch)) throw error;
			console.warn(`rocx: <head> isn't what the app renders either (${error.message}); it stays as the server sent it`);
			this.dispose(part);
			const unseen = new Computation(this, { kind: "boundary", owner, scope });
			const copy = document.createDocumentFragment();
			for (const child of node.c) copy.append(this.build(child, unseen, scope));
		}
	}

	/** Rendering a page again: `<body>`'s children made anew; the host's elements (`[data-rocx]`) and
	 * the server's `<NoHydration>` regions stay. */
	renderBody(body, node, owner, scope) {
		const fragment = this.keepingRegions(body, () => {
			const made = document.createDocumentFragment();
			for (const child of node.c) made.append(this.build(child, owner, scope));
			return made;
		});
		body.replaceChildren(fragment, ...[...body.childNodes].filter(hosts));
	}

	/** Binds an element's computed attributes and handlers (made, or found when hydrating). */
	bind(element, node, owner, scope) {
		for (const [kind, name, value, wanted] of node.a) {
			if (kind === "vo" || kind === "fo" || kind === "co" || kind === "oo" || kind === "so") {
				const computed = { vo: "attr", fo: "flag", co: "class", oo: "optional", so: "style" }[kind];
				this.run(new Computation(this, { kind: computed, runner: this.kept.get(value), owner, scope, target: element, name }));
			} else if (kind === "on") {
				// By the box's id: when its owner runs again the box is released, and the element replaced.
				element.addEventListener(name, (event) => {
					// A handler for one key (`on:keydown.ArrowUp`): that key only, and the browser doesn't
					// also do what it would (an arrow key a game takes doesn't scroll the page).
					if (wanted !== undefined && event.key !== wanted) return;
					if (name === "submit" || wanted !== undefined) event.preventDefault();
					const target = event.target;
					const input = target?.type === "checkbox" ? String(target.checked) : String(target?.value ?? "");
					if (this.kept.has(value)) this.handle(value, input, scope, { owner });
				});
			} else if (kind === "onk") {
				// A handler given the key (`on:keydown.key`).
				element.addEventListener(name, (event) => {
					if (this.kept.has(value)) this.handle(value, event.key ?? "", scope, { owner });
				});
			} else if (kind === "tr") this.setTransition(element, name, value);
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
			}
		}
	}

	// ---- On the server ----

	/** Runs a hole once, for its answer (a failure throws). */
	once(runner, owner, scope, boundary = null) {
		const computation = new Computation(this, { kind: "once", runner: this.kept.get(runner), owner, scope });
		computation.boundary = boundary;
		computation.making = making_();
		const previous = this.current;
		this.current = computation;
		try {
			return this.enter(() => this.ex.run(computation.runner));
		} finally {
			this.current = previous;
			computation.made = computation.making;
			computation.making = null;
		}
	}

	/** A node of the markup's JSON as HTML, every hole run once, with the comments hydration finds holes by. */
	html(node, owner, scope) {
		const all = (nodes) => nodes.map((child) => this.html(child, owner, scope)).join("");
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
			case "x":
				return mark("x", escape(JSON.parse(this.once(node.r, owner, scope))));
			case "h":
			case "l": {
				const label = node.t === "h" ? "html" : "list";
				const parsed = JSON.parse(this.once(node.r, owner, scope));
				return mark(label, (Array.isArray(parsed) ? parsed : [parsed]).map((child) => this.html(child, owner, scope)).join(""));
			}
			case "f":
				return all(node.c);
			case "loading":
				// On the server every server function is a call: nothing waits, and what is inside renders.
				return mark("loading", all(node.c));
			case "show": {
				const holds = JSON.parse(this.once(node.r, owner, scope));
				const shown = !holds ? this.html(node.fallback, owner, scope) : node.with ? this.html(JSON.parse(this.once(node.with, owner, scope)), owner, scope) : all(node.c);
				return mark("show", shown);
			}
			case "for": {
				const list = this.lists.get(node.id);
				const entries = JSON.parse(this.once(node.r, owner, scope));
				const rows = entries.map(({ k, r }, index) => {
					list.indexes.set(k, { value: index, observers: new Set() });
					return mark("row", this.html(JSON.parse(this.once(r, owner, scope)), owner, scope));
				});
				return mark("for", rows.length ? rows.join("") : mark("fallback", this.html(node.fallback, owner, scope)));
			}
			case "errored":
				try {
					return mark("errored", all(node.c));
				} catch (error) {
					if (!(error instanceof Failed)) throw error;
					const fallback = JSON.parse(this.once(node.r, owner, scope, { id: 0, failed: error.message }));
					const shown = this.html(fallback, owner, scope);
					return scope.rcdata || scope.region ? shown : `<!--errored:failed-->${shown}<!--/errored-->`;
				}
			case "c":
				return this.html(JSON.parse(this.once(node.r, owner, scope)), owner, scope);
			case "nh": {
				// Static markup in its markers (one inside another is its part); or, rendering against a
				// page (`renderToString({ regions })`), the page's own, as it has it.
				if (scope.region || scope.rcdata) return all(node.c);
				if (this.regions) {
					if (!this.regions.length) throw new Error("rocx: the app renders more <NoHydration>s than the page has");
					return `<!--nohydration-->${this.regions.shift()}<!--/nohydration-->`;
				}
				const inner = { ...scope, region: true };
				return `<!--nohydration-->${node.c.map((child) => this.html(child, owner, inner)).join("")}<!--/nohydration-->`;
			}
			case "ctx":
				return node.c.map((child) => this.html(child, owner, provided(scope, node))).join("");
			case "e": {
				const classes = [];
				const attributes = [];
				const styles = [];
				for (const [kind, name, value] of node.a) {
					if (scope.region && (kind === "on" || kind === "onk" || kind === "frame")) throw new Error(inRegion(node.tag, name));
					if (kind === "v" && name === "class") classes.push(value);
					else if (kind === "v" && name === "style") styles.push(value);
					else if (kind === "v") attributes.push(`${name}="${escape(value)}"`);
					else if (kind === "o" && value !== "") attributes.push(`${name}="${escape(value)}"`);
					else if (kind === "ci" && value) classes.push(name);
					else if (kind === "f" && value) attributes.push(name);
					else if (kind === "vo") attributes.push(`${name}="${escape(JSON.parse(this.once(value, owner, scope)))}"`);
					else if (kind === "oo") {
						const optional = JSON.parse(this.once(value, owner, scope));
						if (optional !== "") attributes.push(`${name}="${escape(optional)}"`);
					} else if (kind === "fo" && JSON.parse(this.once(value, owner, scope))) attributes.push(name);
					else if (kind === "co" && JSON.parse(this.once(value, owner, scope))) classes.push(name);
					else if (kind === "sv" && value) styles.push(`${name}: ${value}`);
					else if (kind === "so") {
						const styled = JSON.parse(this.once(value, owner, scope));
						if (styled !== "") styles.push(`${name}: ${styled}`);
					}
				}
				if (classes.length) attributes.unshift(`class="${escape(classes.join(" "))}"`);
				if (styles.length) attributes.push(`style="${escape(styles.join("; "))}"`);
				const open = `<${node.tag}${attributes.map((attribute) => ` ${attribute}`).join("")}>`;
				const inner = RCDATA.has(node.tag) ? { ...scope, rcdata: true } : scope;
				return VOID.has(node.tag) ? open : `${open}${node.c.map((child) => this.html(child, owner, inner)).join("")}</${node.tag}>`;
			}
			default:
				throw new Error(`rocx: unknown node ${node.t}`);
		}
	}

	/**
	 * On the server: the app's markup as HTML for a request (`path`, `headers` as `[name, value]`
	 * pairs), and the answers its server functions gave, for the page to carry to the browser. All it
	 * made is let go of afterwards. Markup with `<html>` at its top is a whole document, answered as
	 * the server platform answers a page (`Runtime.documentOf`); any other is an app's range
	 * (`<!--app-->…<!--/app-->`, for `hydrate`).
	 *
	 * Rendered against a page the server rendered (the browser's build, as hydrating it would),
	 * `answers` are that page's (`[[name, input, answer]]`, its answers script): each call is
	 * answered from them and recorded as the page has it, and a call the server didn't make fails
	 * (599). `regions` are what the page has inside each `<NoHydration>`, in order
	 * (`Runtime.regionsOf`): each is written as it is there, since the browser's build has a
	 * placeholder in its place; without them, a placeholder renders empty.
	 */
	renderToString({ path = "/", headers = [], answers = null, regions = null } = {}, scope = {}) {
		this.given = answers;
		this.regions = regions && [...regions];
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
		this.titled = null;
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
			const markup = this.html(JSON.parse(out), root, scope);
			const html = DOCUMENT.test(markup) ? Runtime.documentOf(markup, this.recorded, this.flashed, this.titled) : `<!--app-->${markup}<!--/app-->`;
			return { html, answers: this.recorded };
		} finally {
			this.onServer = wasOnServer;
			root.made = root.making;
			this.dispose(root);
			for (const signal of this.signals.values()) this.ex.release(signal.value);
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

	/** The flash a page read, as a script for the browser (signals.rs's `flash_script`): the cookie's
	 * JSON, as a JSON string. */
	static flashScript(flash) {
		return `<script type="application/json" class="rocx-flash">${JSON.stringify(flash).replace(/</g, "\\u003c")}</script>`;
	}

	/**
	 * A page's markup as the server platform answers it (signals.rs's `document`): `<!doctype html>`
	 * first, unless the markup begins with one; the title the last `<Title>` rendered said, if one
	 * did, as a `<title data-rocx>` before the `<head>`'s first `<title>` (or at its end); the flash
	 * the page read (if it did), the answers script and the bootstrap (start.js) just before the
	 * last `</body>`, or at the end with none.
	 */
	static documentOf(markup, answers, flash = "", title = null) {
		if (title !== null) markup = Runtime.titled(markup, title);
		const doctype = /^<!doctype/i.test(markup.trimStart()) ? "" : "<!doctype html>";
		const scripts = `${flash ? Runtime.flashScript(flash) : ""}${Runtime.answersScript(answers)}${START}`;
		const at = markup.lastIndexOf("</body>");
		return at < 0 ? `${doctype}${markup}${scripts}` : `${doctype}${markup.slice(0, at)}${scripts}${markup.slice(at)}`;
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
		this.current = computation;
		this.stats.runs++;
		try {
			return { computation, nodes: [JSON.parse(this.enter(() => this.ex.run(computation.runner)))] };
		} catch (error) {
			if (error instanceof NotReady) throw new Error("rocx: a component read a value that isn't in yet outside its markup: read it in a hole ({…}), which waits");
			if (!(error instanceof Failed)) throw error;
			this.failed(computation, error);
			return { computation, nodes: [] };
		} finally {
			this.current = previous;
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
}
