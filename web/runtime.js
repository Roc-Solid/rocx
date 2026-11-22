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

/** What a run makes, as it makes it: child computations, boxes kept for them, what it reads,
 * signals, cleanups (a kept box's id, or the runtime's own function), and what its `is_pending!`
 * calls answered (`queries`). */
const making_ = () => ({ children: [], kept: [], sources: new Set(), signals: [], cleanups: [], queries: [] });

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
		/** Its requests' answers, by method, URL and body: a run again reads them. */
		this.calls = new Map();
		this.disposed = false;
		/** Run untracked (a <For>'s row, a <Show>'s function child: Solid's mapArray and untrack,
		 * D-039): what it reads doesn't run it again; only a read that waits does, once it is in. */
		this.untracked = false;
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

/** What `js_fetch` answers (usize's largest, on wasm32) for a request whose caller unwinds. */
const WAITS = 0xffffffff;

/** The computations that run again when what they read changes: the ones a submission's result
 * reads again (`revalidate`). A component, the root and a handler run once. */
const READERS = new Set(["memo", "text", "attr", "flag", "class", "optional", "style", "html", "show", "for", "reaction", "transition"]);

/** A submission as Roc reads it (`Host.submission!`), its id too in a list (`Host.submissions!`). */
const submissionJson = ({ id, state, input, json, status, body }, listed = false) => JSON.stringify(listed ? { id, state, input, json, status, body } : { state, input, json, status, body });

/** The latest submission, once it is forgotten: none, and not the flash either. */
const CLEARED = submissionJson({ state: "cleared", input: "", json: false, status: 0, body: "" });

/** The events of drag and drop whose handlers the runtime takes part in (`dragAndDrop`). */
const DRAG_EVENTS = new Set(["dragstart", "dragenter", "dragleave", "drop"]);

/** What a drop target says it will do with a drag the source allows `allowed` for: a move, unless
 * only a copy or a link is allowed. */
const dropEffect = (allowed) => (/move|all|uninitialized/i.test(allowed ?? "all") ? "move" : /copy/i.test(allowed) ? "copy" : /link/i.test(allowed) ? "link" : "none");

/** A CSS property as `element.animate` names it: `transform-origin` is `transformOrigin`. */
const camel = (property) => property.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());

/** The scope an element's children are made in: an <svg>'s know they are SVG, so a <For>'s row or
 * a <Show>'s part made inside one later, in the browser, is SVG too. */
const within = (node, scope) => (node.tag === "svg" && !scope.svg ? { ...scope, svg: true } : scope);

/**
 * The tab's channels (`Endpoint.subscribe!`, `say!`, `resync!`): every subscription in the tab on
 * one stream, `GET /rocx/live?tab=…&c=<url>&c=<url>…` (server-sent events), whatever its number,
 * so a page's channels take one of the six connections a browser makes to a host. Two subscribers
 * to one channel share it.
 *
 * - What the page subscribes to changes as effects run and components go. Once the render that
 *   changed it is done, the hub opens the stream again with the new set, only if the set did change
 *   (the server keeps nothing per stream, so this works through any proxy).
 * - Each time it opens, the server sends each channel `resync` (then the route's `on_open!`
 *   messages), or `refused`; then the channel's messages as they are published (`message`), and
 *   `ended` for one its check refuses at a beat (`: beat` comments, every 15 s).
 * - When the stream drops, the hub opens it again after a wait that doubles each time (from 0.5 s
 *   to 30 s), and once it has stayed up 10 s, starts over at 0.5 s.
 * - Each subscriber hears its events one at a time, in order: the next once its handler is done
 *   (a handler waiting for an answer runs again first).
 * - What the page says (`say!`), and its asks for a resync (`resync!`, a new subscriber to a channel
 *   already open), go in one `POST /rocx/live/send` a frame.
 * - The tab's id (`tab`, random, kept in sessionStorage, so a reload keeps it) names the tab to the
 *   server's hooks.
 * - Where no server answers (a static copy of the site: a 404, a 405, or a page that isn't a
 *   stream), every subscriber hears `Refused(404, …)` and the hub asks for nothing more.
 */
class Hub {
	constructor(runtime) {
		this.runtime = runtime;
		/** By URL: `{ subscribers, open, refused, ended }`, `open` once this stream sent its resync. */
		this.channels = new Map();
		/** The stream: the URLs it carries (sorted, a line each), how to stop it, when it opened. */
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

	/** The tab's id: random, made once per tab, kept in sessionStorage (a reload keeps it). */
	tab() {
		if (this.tabId) return this.tabId;
		const fresh = () => [...crypto.getRandomValues(new Uint8Array(12))].map((byte) => byte.toString(16).padStart(2, "0")).join("");
		try {
			this.tabId = sessionStorage.getItem("rocx-tab") || fresh();
			sessionStorage.setItem("rocx-tab", this.tabId);
		} catch {
			this.tabId = fresh();
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
		this.channels.delete(subscriber.url);
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
		// A wait before the next try is under way: it opens the stream with the set as it is then.
		if (this.unavailable || this.retrying) return;
		const urls = [...this.channels.keys()].sort();
		const key = urls.join("\n");
		if ((this.stream?.key ?? "") === key) return;
		this.stream?.controller.abort();
		this.stream = null;
		if (urls.length) this.connect(urls, key);
	}

	async connect(urls, key) {
		const controller = new AbortController();
		const stream = { key, controller, opened: performance.now() };
		this.stream = stream;
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
					if (data.length && this.stream === stream) this.dispatch(field("event")[0] ?? "message", data[0], data.slice(1).join("\n"));
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

	/** An event of the stream, for the channel at `url`. */
	dispatch(kind, url, said) {
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

	/** An item for the next post (`POST /rocx/live/send`): sent once this frame is done. */
	post(item) {
		if (this.unavailable) return;
		this.outbox.push(item);
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
		const items = this.outbox.splice(0);
		if (!items.length) return;
		this.stats.posts++;
		try {
			const response = await fetch(this.runtime.under(`/rocx/live/send?tab=${encodeURIComponent(this.tab())}`), { method: "POST", headers: { "content-type": "application/json" }, body: `[${items.join(",")}]` });
			if (response.status === 200) {
				const { refused = [] } = await response.json();
				for (const { index, status, why } of refused) console.warn(`rocx: ${JSON.parse(items[index]).channel} refused what was said: ${status} ${why}`);
			} else if (response.status === 404 || response.status === 405) this.unavailable ??= [404, "no server answers channels here (a static copy of the site?)"];
			else if (!response.ok) console.warn(`rocx: what was said wasn't heard: ${response.status} ${await response.text()}`);
		} catch {
			// Offline: what was said is lost, as it would be if the tab closed.
		}
	}
}

export class Runtime {
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
		let runtime;
		const env = new Proxy({}, { get: (_, name) => (...args) => runtime.imports[name](...args) });
		const resolved = await source;
		const bytes = resolved instanceof Response ? await resolved.arrayBuffer() : resolved;
		const { instance } = await WebAssembly.instantiate(bytes, { env });
		runtime = new Runtime(instance.exports, base);
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
		 * transitions are over. A <For> putting its rows in order passes over them. `leavingNodes`:
		 * the range each one's top nodes are in. */
		this.leaving = new Map();
		this.leavingNodes = new WeakMap();
		/** Each element's name on the page (`key={…}`), and the elements that glide when they move
		 * (`transition:move`); where those were before the flush first changed the page (`measure`),
		 * and the glide each is playing. */
		this.keys = new WeakMap();
		this.gliders = new Set();
		this.measured = null;
		this.glides = new WeakMap();
		/** Whether a flush is running its computations now: the page changes only then. */
		this.inFlush = false;
		/** The drop targets a drag is over now (`depth` above 0), told it left when the drag ends. */
		this.overs = new Set();
		this.dragEnds = null;
		/** Letting go of what is inside a part that is leaving: its <For>s' rows stay with it. */
		this.keeping = false;
		/** The computation or handler running now. */
		this.current = null;
		this.dirty = new Set();
		/** Effects whose apply is due, after the flush. */
		this.due = new Set();
		this.flushing = false;
		/** The endpoints whose forms the runtime sends (`use_submission!`, `use_submissions!`), by URL,
		 * and how many ask; the submissions to each (forms', actions'), a source computations read;
		 * whether it listens for submits. */
		this.actions = new Map();
		this.submissions = new Map();
		this.submitting = null;
		/** The computations that read a GET from the server (`Endpoint.get!`): what a submission's
		 * result has read again before it is done (`revalidate`). */
		this.readers = new Set();
		/** Why the last request `js_fetch` answered "waits" for unwinds its caller (`js_waits`). */
		this.waiting = null;
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
		/** While hydrating: what the page asked the server for that it didn't carry (`asked`), which
		 * strict hydration refuses. */
		this.hydrating = null;
		/** The status the page is answered with (`<HttpStatusCode>`), rendering as a server would. */
		this.status = 200;
		/** The page the runtime is on: where it listens for forms' submits. */
		this.page = typeof document === "undefined" ? null : document;
		/** Whoever wants to see what the runtime does, as it does it (the docs' inspector): an object
		 * with any of `seeded`, `call`, `answer`, `fetch`, `fetched`, `listen`, `heard`, `patch`,
		 * `row`, `show`, `frame`, `effect` (a call of the page's own function), `apply` (an effect's
		 * apply), `submit`, `submitted`, `revalidate` (a submission's result reading the page's reads
		 * again), `glide` (an element moving), and the hub's `subscribe`, `unsubscribe`, `connect`
		 * and `dropped`. */
		this.observer = null;
		/** The tab's channels (`Endpoint.subscribe!`): one stream for all of them. */
		this.hub = new Hub(this);
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
				// Whether it has a value and waits for a new one (`refreshing`), or it or a memo it reads
				// does (`stale`): what is_pending! answers, its readers tracking `pending`.
				memo.refreshing = memo.stale = false;
				memo.pending = { observers: new Set() };
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
				if (!making) {
					this.ex.release(ptr);
					return answer ? 1 : 0;
				}
				const id = ++ids;
				this.kept.set(id, ptr);
				making.kept.push(id);
				making.queries.push({ probe: id, memos, answer });
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
			js_listen: (up, ul, ptr) => this.listenTo(text(up, ul), ptr),
			js_subscribe: (up, ul, ptr) => this.hub.subscribe(text(up, ul), ptr),
			js_say: (up, ul, sp, sl) => this.hub.say(text(up, ul), text(sp, sl)),
			js_resync: (up, ul) => this.hub.resync(text(up, ul)),
			js_live_publish: () => {
				throw new Failed("Endpoint.publish! is the server's: a page says things on a channel with Endpoint.say!");
			},
			js_timer: (ms, repeat, ptr) => this.startTimer(ms, repeat === 1, ptr),
			js_clear_timer: (id) => this.clearTimer(id),
			js_browser_call: (np, nl, ap, al) => {
				const name = text(np, nl);
				const handler = this.current;
				// Only a handler acts: a computation runs again whenever what it read changes.
				if (handler?.kind !== "handler") throw new Failed(`Browser.call!("${name}") is a handler's: call it from an event, a frame or a timer, not while computing`);
				handler.writes.push({ effect: name, arg: text(ap, al) });
			},
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
			// The latest submission to an endpoint: none once it is forgotten (`clear!`), until the next.
			js_submission: (ptr, len) => {
				if (this.onServer) return this.give("");
				const source = this.submissionOf(this.actionKey(text(ptr, len)));
				this.track(source);
				if (source.cleared) return this.give(CLEARED);
				const latest = source.list.at(-1);
				return this.give(latest ? submissionJson(latest) : "");
			},
			js_submissions: (ptr, len) => {
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
		const fields = new URLSearchParams(new FormData(form, submitter ?? undefined)).toString();
		this.submit(key, url.href, { headers: { "content-type": "application/x-www-form-urlencoded" }, body: fields, input: fields, json: false });
	}

	/** An action (`use_action!`), sent: its arg as JSON in its body, as `Endpoint.send!` sends it. */
	sendAction({ method, url, body, input }) {
		const href = typeof location === "undefined" ? this.under(url) : new URL(this.under(url), location.href).href;
		const headers = method === "GET" || method === "HEAD" ? {} : { "content-type": "application/json" };
		this.submit(this.actionKey(url), href, { method, headers, body, input, json: true });
	}

	/**
	 * Sends a submission to an endpoint (a form's fields, or an action's arg), a new one in its
	 * list, pending until it is answered: 200, its result (JSON); any other status, a refusal; none,
	 * status 0 and why. Several may be on their way at once, each answered on its own. A result has
	 * the page's reads read again (`revalidate`) before the submission is done, so what shows the
	 * server's data and the submission's end changes at once. A redirect of the endpoint's own
	 * (`x-rocx-redirect`), or one fetch followed (middleware's), is where the browser goes.
	 */
	submit(key, href, { method = "POST", headers = {}, body, input, json }) {
		const source = this.submissionOf(key);
		const entry = { id: ++ids, state: "pending", input, json, status: 0, body: "" };
		source.list.push(entry);
		source.cleared = false;
		this.submissionsChanged(source);
		const asked = performance.now();
		this.notify("submit", { method, url: key, input, id: entry.id });
		const done = (status, said) => {
			Object.assign(entry, { state: "done", status, body: said });
			// Forgotten meanwhile: nothing reads it.
			if (source.list.includes(entry)) this.submissionsChanged(source);
		};
		fetch(href, { method, headers: { ...headers, accept: "application/json", "x-rocx-submission": "1" }, body: method === "GET" || method === "HEAD" ? undefined : body }).then(
			async (response) => {
				const to = response.headers.get("x-rocx-redirect");
				if (to !== null || response.redirected) {
					this.notify("submitted", { url: key, input, id: entry.id, status: response.status, redirect: to ?? response.url, ms: performance.now() - asked });
					location.assign(to !== null ? new URL(this.under(to), location.href).href : response.url);
					return;
				}
				const said = await response.text();
				this.notify("submitted", { url: key, input, id: entry.id, status: response.status, body: said, ms: performance.now() - asked });
				if (response.status === 200) this.revalidate(() => done(200, said));
				else done(response.status, said);
			},
			(error) => {
				const why = `${method} ${key}: ${error?.message ?? error}`;
				this.notify("submitted", { url: key, input, id: entry.id, error: why, ms: performance.now() - asked });
				done(0, why);
			},
		);
	}

	/**
	 * Reads the page's reads again (Solid Router revalidating after an action), then `done`: every
	 * computation that read a GET from the server (`Endpoint.get!`, `read!`) asks it again, its last
	 * value shown meanwhile, and `done` runs once each has its answer (or failed, or went), in the
	 * run of the last one, so whatever reads both sees the new data and the submission's end
	 * together.
	 */
	revalidate(done) {
		const targets = [...this.readers].filter((computation) => !computation.disposed && [...computation.calls.keys()].some((key) => key.startsWith("GET ")));
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

	/** A computation read again for a submission (`revalidate`) has its answer, failed, or went. */
	revalidated(computation) {
		const waiting = computation.revalidating;
		if (!waiting) return;
		computation.revalidating = null;
		for (const one of waiting) one();
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
	 * An HTTP request for the running computation or handler (`Call.fetch!`): its answer, as
	 * `{"status":…,"body":…}`, from its calls if in, or asked for now (and it waits, as for a server
	 * read's). A GET the server made as it rendered the page (`Endpoint.get!`: noted under
	 * `GET <url>`) is read from the page's answers, not asked again. Rendering as a server would, it
	 * is the answer the page recorded (`renderToString({ answers })`): the server platform answers a
	 * GET by its route, natively, and anything else is a 599.
	 */
	fetchFor(method, url, headerLines, body) {
		if (this.onServer) {
			const found = this.given?.find(([named, asked]) => named === `${method} ${url}` && asked === body);
			if (!found) throw new Failed(`599: ${method} ${url} wasn't answered as the server rendered the page`);
			// Noted once, as the server notes a GET once a render.
			if (!this.current?.scope?.region && !this.recorded.includes(found)) this.recorded.push(found);
			return this.give(found[2]);
		}
		const asking = this.current;
		const key = `${method} ${url}\n${body}`;
		let answer = asking.calls.get(key);
		if (!answer && this.answers.has(key)) {
			// The server answered it while rendering the page: read here, not asked again.
			answer = { state: "ok", value: this.answers.get(key) };
			asking.calls.set(key, answer);
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
			asking.calls.set(key, answer);
		}
		asking.used?.add(key);
		if (method === "GET" && READERS.has(asking.kind)) this.readers.add(asking);
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
		computation.used = new Set();
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
		for (const source of computation.sources) source.observers.delete(computation);
		computation.sources = computation.untracked ? new Set() : making.sources;
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
				computation.queries = making.queries;
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
		for (const observer of memo.observers) if (observer.kind === "memo") this.restale(observer);
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
		if (kind === "key") return this.keys.set(target, JSON.parse(out));
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
			this.measure();
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
		this.readers.delete(computation);
		this.revalidated(computation);
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
		const oldest = (set) => [...set].sort((a, b) => a.id - b.id)[0];
		this.inFlush = true;
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
		this.inFlush = false;
		this.flushing = false;
		// What moved glides, before what came plays its transition in (one that is a moved element's
		// doesn't).
		if (this.measured) this.glide();
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
		}
	}

	/** Runs a handler (the id of its box). If it waits for an answer from the server, its writes are
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
				if (error instanceof NotReady || error instanceof Failed) this.reclaim(error);
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
		if (!first && !adopting) this.measure();
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
			// Made once, as a component is: its holes, and the getters it gives its components, follow.
			made.untracked = true;
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
		// Rows that go, come or move change the page: where what glides is, first.
		if (later && !adopting && (entries.length !== list.rows.size || entries.some(({ k }, index) => list.indexes.get(k)?.value !== index || !list.rows.has(k)))) this.measure();
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
				// Made once, as Solid's mapArray makes a row: its holes, and the getters it gives its
				// components, follow its item (D-039).
				row.computation.untracked = true;
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
		for (const element of this.gliders) if (element.isConnected) this.measured.set(element, still ? null : element.getBoundingClientRect());
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
	 * for less motion; an element taken off the page is forgotten.
	 */
	glide() {
		const before = this.measured;
		this.measured = null;
		const still = reducedMotion();
		// The ones that went (taken away, or on their way out), by key: where they were.
		const went = new Map();
		for (const [element, box] of before) {
			if (!box || (element.isConnected && !this.leavingRangeOf(element))) continue;
			const key = this.keys.get(element);
			if (key !== undefined) went.set(key, { element, box });
		}
		const moves = [];
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
				this.entering = this.entering.filter(([entering]) => entering !== element);
				this.leavingRangeOf(pair.element)?.finish();
			}
			if (box) moves.push([element, box]);
		}
		if (!moves.length) return;
		// Glides playing stop, then every box is read at once: one layout.
		for (const [element] of moves) this.glides.get(element)?.cancel();
		const boxes = moves.map(([element]) => element.getBoundingClientRect());
		const moving = new Map();
		moves.forEach(([element, box], index) => {
			const dx = box.left - boxes[index].left;
			const dy = box.top - boxes[index].top;
			if (Math.abs(dx) >= 0.5 || Math.abs(dy) >= 0.5) moving.set(element, [dx, dy]);
		});
		for (const [element, [dx, dy]] of moving) {
			let carried = false;
			for (let parent = element.parentElement; parent && !carried; parent = parent.parentElement) carried = moving.has(parent);
			if (carried || typeof element.animate !== "function") continue;
			const spec = this.transitions.get(element)?.move ?? {};
			try {
				const animation = element.animate([{ translate: `${dx}px ${dy}px` }, { translate: "0px 0px" }], {
					duration: spec.ms ?? 250,
					delay: spec.delay ?? 0,
					easing: spec.easing || "ease-out",
					fill: "backwards",
				});
				this.glides.set(element, animation);
				animation.finished.then(
					() => this.glides.get(element) === animation && this.glides.delete(element),
					() => {},
				);
				this.notify("glide", { node: element, dx, dy, key: this.keys.get(element) });
			} catch {
				// An easing the browser doesn't know: no glide, rather than an error.
			}
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
		this.hydrating = null;
		if (strict && hydrating.asked.length) throw Runtime.askedAgain(hydrating.asked);
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
		this.seed(doc);
		const seeded = new Map(this.answers);
		const root = () => new Computation(this, { kind: "root", owner: null, scope: {}, target: { document: doc } });
		this.root = root();
		this.root.adopting = true;
		const hydrating = (this.hydrating = { asked: [] });
		const askedAgain = () => Runtime.askedAgain(hydrating.asked);
		try {
			this.run(this.root);
			if (strict && hydrating.asked.length) throw askedAgain();
		} catch (error) {
			if (!(error instanceof Mismatch)) throw error;
			this.dispose(this.root);
			if (strict && hydrating.asked.length) throw askedAgain();
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
			this.hydrating = null;
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
		// Drag and drop: an element with a drop handler is a drop target, and one with a dragstart
		// handler starts a drag in every browser (`dragAndDrop`). Its dragenter and dragleave handlers
		// are the element's own, as mouseenter and mouseleave are.
		let drag = null;
		for (const [kind, name] of node.a) {
			if ((kind === "on" || kind === "onp") && DRAG_EVENTS.has(name)) {
				drag ??= { drop: false, start: false, enter: [], leave: [], depth: 0 };
				if (name === "drop") drag.drop = true;
				if (name === "dragstart") drag.start = true;
			}
		}
		for (const [kind, name, value, wanted] of node.a) {
			if (kind === "vo" || kind === "fo" || kind === "co" || kind === "oo" || kind === "so") {
				const computed = { vo: "attr", fo: "flag", co: "class", oo: "optional", so: "style" }[kind];
				this.run(new Computation(this, { kind: computed, runner: this.kept.get(value), owner, scope, target: element, name }));
			} else if (kind === "on" || kind === "onp") {
				// By the box's id: when its owner runs again the box is released, and the element replaced.
				const handler = (event) => {
					// A handler for one key (`on:keydown.ArrowUp`): that key only, and the browser doesn't
					// also do what it would (an arrow key a game takes doesn't scroll the page).
					if (wanted !== undefined && event.key !== wanted) return;
					// `.prevent`: what the browser would do (follow a link) is the handler's to do.
					if (kind === "onp" || name === "submit" || wanted !== undefined) event.preventDefault();
					const target = event.target;
					// A drop's value is the text dropped (from another page, or another program).
					const input = event.type === "drop" ? (event.dataTransfer?.getData("text/plain") ?? "") : target?.type === "checkbox" ? String(target.checked) : String(target?.value ?? "");
					if (this.kept.has(value)) this.handle(value, input, scope, { owner });
				};
				if (drag && name === "dragenter") drag.enter.push(handler);
				else if (drag && name === "dragleave") drag.leave.push(handler);
				else element.addEventListener(name, handler);
			} else if (kind === "k") this.keys.set(element, name);
			else if (kind === "ko") this.run(new Computation(this, { kind: "key", runner: this.kept.get(name), owner, scope, target: element }));
			else if (kind === "onk") {
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
		if (drag) this.dragAndDrop(element, drag);
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
		if (drag.start)
			element.addEventListener("dragstart", (event) => {
				if (event.dataTransfer && !event.dataTransfer.types.length) event.dataTransfer.setData("application/x-rocx", "rocx");
			});
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
				// On the server every read is answered as it is made: nothing waits, and what is inside renders.
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
					if (scope.region && (kind === "on" || kind === "onp" || kind === "onk" || kind === "frame")) throw new Error(inRegion(node.tag, name));
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
			this.reclaim(error);
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
