// A real browser for tests, with no dependencies: Chromium's headless shell, driven over the
// DevTools protocol with Node's own WebSocket. $CHROME names the binary; otherwise the one
// Playwright keeps in its cache is used, and the tests that need it are skipped without one.
//
// Gecko too (Zen, or Firefox: `launchGecko`), headless, over WebDriver BiDi, for what only it
// shows: its page has the same methods (`goto`, `eval`, `wait`, `click`, `type`, `press`, `drag`,
// `screenshot`, and those packages/testing uses), but no `send` of the DevTools protocol.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";

/** Where Playwright keeps the browsers it downloads. */
const playwrightCache = () => join(homedir(), process.platform === "darwin" ? "Library/Caches/ms-playwright" : ".cache/ms-playwright");

export function findChrome() {
	if (process.env.CHROME) return process.env.CHROME;
	const cache = playwrightCache();
	if (!existsSync(cache)) return null;
	for (const dir of readdirSync(cache).filter((name) => name.startsWith("chromium_headless_shell-")).sort().reverse()) {
		for (const platform of readdirSync(join(cache, dir))) {
			const binary = join(cache, dir, platform, "chrome-headless-shell");
			if (existsSync(binary)) return binary;
		}
	}
	return null;
}

/** Chromium, headless, with a profile of its own: its tabs share that profile's cookies, so a test
 * of two people (two sessions at once) launches it twice. */
export async function launch(binary = findChrome()) {
	const profile = mkdtempSync(join(tmpdir(), "rocx-chrome-"));
	const child = spawn(binary, ["--headless", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
	const endpoint = await new Promise((resolve, reject) => {
		let seen = "";
		child.stderr.on("data", (chunk) => {
			seen += chunk;
			const match = /DevTools listening on (ws:\/\/\S+)/.exec(seen);
			if (match) resolve(match[1]);
		});
		child.on("exit", (code) => reject(new Error(`chrome exited (${code}): ${seen}`)));
	});
	const socket = new WebSocket(endpoint);
	await new Promise((resolve, reject) => {
		socket.onopen = resolve;
		socket.onerror = reject;
	});
	let next = 0;
	const waiting = new Map();
	const listeners = [];
	socket.onmessage = ({ data }) => {
		const message = JSON.parse(data);
		if (message.id !== undefined) {
			const { resolve, reject } = waiting.get(message.id);
			waiting.delete(message.id);
			if (message.error) reject(new Error(message.error.message));
			else resolve(message.result);
		} else for (const listener of listeners) listener(message);
	};
	const send = (method, params = {}, sessionId) =>
		new Promise((resolve, reject) => {
			const id = ++next;
			waiting.set(id, { resolve, reject });
			socket.send(JSON.stringify({ id, method, params, sessionId }));
		});
	return {
		async page() {
			const { targetId } = await send("Target.createTarget", { url: "about:blank" });
			const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
			return new Page(send, sessionId, listeners);
		},
		async close() {
			socket.close();
			child.kill();
			await new Promise((resolve) => child.on("exit", resolve));
			rmSync(profile, { recursive: true, force: true });
		},
	};
}

/** The middle of the element `selector` finds on `page`, scrolled into view at once (`Page.center`). */
function centerOf(page, selector) {
	return page.eval(`(() => {
		const element = document.querySelector(${JSON.stringify(selector)});
		element.scrollIntoView({ block: "center", behavior: "instant" });
		const r = element.getBoundingClientRect();
		return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
	})()`);
}

class Page {
	constructor(send, sessionId, listeners) {
		this.send = (method, params) => send(method, params, sessionId);
		/** What the page logged and threw, for assertions. */
		this.console = [];
		this.errors = [];
		/** Who waits for an event of the protocol's, by its method (`once`). */
		this.waiting = [];
		listeners.push((message) => {
			if (message.sessionId !== sessionId) return;
			if (message.method === "Runtime.consoleAPICalled") this.console.push({ type: message.params.type, text: message.params.args.map((arg) => arg.value ?? arg.description).join(" ") });
			if (message.method === "Runtime.exceptionThrown") this.errors.push(message.params.exceptionDetails.exception?.description ?? message.params.exceptionDetails.text);
			for (const waiter of this.waiting.filter((each) => each.method === message.method)) {
				this.waiting.splice(this.waiting.indexOf(waiter), 1);
				waiter.resolve(message.params);
			}
		});
	}

	/** Runs `source` in every document this page loads, before the document's own scripts. */
	async beforeEachDocument(source) {
		await this.send("Page.enable");
		await this.send("Page.addScriptToEvaluateOnNewDocument", { source });
	}

	/** Forgets every cookie (the browser's: its pages share them). */
	async clearCookies() {
		await this.send("Network.enable");
		await this.send("Network.clearBrowserCookies");
	}

	/** Sets the cookie `name` for `url`'s site. */
	async setCookie(name, value, url) {
		await this.send("Network.setCookie", { name, value, url });
	}

	close() {
		return this.send("Page.close").catch(() => {});
	}

	/** The next event of the protocol's with this method (`Input.dragIntercepted`), its params. */
	once(method, timeout = 3000) {
		return new Promise((resolve, reject) => {
			const waiter = { method, resolve };
			this.waiting.push(waiter);
			setTimeout(() => {
				if (!this.waiting.includes(waiter)) return;
				this.waiting.splice(this.waiting.indexOf(waiter), 1);
				reject(new Error(`no ${method} in ${timeout} ms`));
			}, timeout);
		});
	}

	/** The middle of an element, scrolled into view (at once, even on a page that scrolls smoothly):
	 * where a real pointer would press it. */
	center(selector) {
		return centerOf(this, selector);
	}

	/**
	 * A drag, as a mouse does it, through the browser's own drag and drop: pressed on `from`, moved,
	 * so the browser starts a drag (dragstart, with the data it sets), then over each of `over` (an
	 * element's middle, or `{ x, y }`) and dropped on the last (dragenter, dragover, drop, then
	 * dragend), unless `drop` is false (the drag stays over the last, for `finish`). The drag's data,
	 * as the browser took it from dragstart: `{ items, dragOperationsMask }`. Each event is the
	 * browser's own (trusted): the mouse starts the drag, and the DevTools protocol, which holds the
	 * drag the browser started (`Input.setInterceptDrags`), moves and drops it. (Gecko's page drags
	 * with the DOM's events instead: `GeckoPage.drag`.)
	 */
	async drag(from, over, { drop = true } = {}) {
		await this.send("Input.setInterceptDrags", { enabled: true });
		const start = typeof from === "string" ? await this.center(from) : from;
		const intercepted = this.once("Input.dragIntercepted");
		await this.send("Input.dispatchMouseEvent", { type: "mousePressed", x: start.x, y: start.y, button: "left", buttons: 1, clickCount: 1 });
		await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", x: start.x + 12, y: start.y + 12, button: "left", buttons: 1 });
		const { data } = await intercepted;
		let at = start;
		for (const target of [].concat(over)) {
			at = typeof target === "string" ? await this.center(target) : target;
			await this.send("Input.dispatchDragEvent", { type: "dragEnter", x: at.x, y: at.y, data });
			await this.send("Input.dispatchDragEvent", { type: "dragOver", x: at.x, y: at.y, data });
		}
		this.dragging = { data, at };
		if (drop) await this.finish();
		return data;
	}

	/** The drag `drag` left over its last place, dropped there (or, `cancel`, called off). */
	async finish({ cancel = false } = {}) {
		const { data, at } = this.dragging;
		this.dragging = null;
		await this.send("Input.dispatchDragEvent", { type: cancel ? "dragCancel" : "drop", x: at.x, y: at.y, data });
		await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: at.x, y: at.y, button: "left", buttons: 0, clickCount: 1 });
		await this.send("Input.setInterceptDrags", { enabled: false });
	}

	async goto(url) {
		await this.send("Runtime.enable");
		await this.send("Page.enable");
		await this.send("Page.navigate", { url });
		await this.wait("document.readyState === 'complete'");
	}

	/** The value of `expression` (awaited when it is a promise). */
	async eval(expression) {
		const { result, exceptionDetails } = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
		if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
		return result.value;
	}

	async wait(expression, timeout = 5000) {
		const until = Date.now() + timeout;
		while (Date.now() < until) {
			if (await this.eval(`Boolean(${expression})`)) return;
			await new Promise((resolve) => setTimeout(resolve, 25));
		}
		throw new Error(`timed out waiting for ${expression}`);
	}

	/** A real click, at the middle of the element, through the browser's input pipeline. */
	async click(selector) {
		const { x, y } = await this.center(selector);
		await this.clickAt(x, y);
	}

	/** A real click at a point of the page (CSS pixels from the viewport's top left). */
	async clickAt(x, y) {
		for (const type of ["mousePressed", "mouseReleased"]) await this.send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 });
	}

	/** Typing, as a keyboard would: focus, then text inserted where the caret is. */
	async type(selector, text) {
		await this.eval(`document.querySelector(${JSON.stringify(selector)}).focus()`);
		await this.insertText(text);
	}

	/** Text inserted where the caret is, as typing it does (an `input` event). */
	insertText(text) {
		return this.send("Input.insertText", { text });
	}

	/** A PNG of the page at `width` (the whole page when `full`), in light or dark. */
	async screenshot({ width = 1280, height = 900, full = false, dark = false } = {}) {
		await this.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: dark ? "dark" : "light" }] });
		await this.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
		const pageHeight = full ? await this.eval("document.documentElement.scrollHeight") : height;
		if (full) await this.send("Emulation.setDeviceMetricsOverride", { width, height: pageHeight, deviceScaleFactor: 1, mobile: false });
		const { data } = await this.send("Page.captureScreenshot", { format: "png" });
		return Buffer.from(data, "base64");
	}

	/**
	 * A key, pressed and released, by its `key` as the browser reports it (`" "` is the space bar).
	 * Enter and Space carry their text, as a keyboard's do, so Enter submits forms.
	 */
	async press(key) {
		const keys = { Enter: [13, "Enter", "\r"], Escape: [27, "Escape"], Backspace: [8, "Backspace"], Tab: [9, "Tab"], " ": [32, "Space", " "], ArrowUp: [38, "ArrowUp"], ArrowDown: [40, "ArrowDown"], ArrowLeft: [37, "ArrowLeft"], ArrowRight: [39, "ArrowRight"] };
		const [windowsVirtualKeyCode = 0, code = key, text] = keys[key] ?? [];
		await this.send("Input.dispatchKeyEvent", { type: text ? "keyDown" : "rawKeyDown", key, code, windowsVirtualKeyCode, text });
		await this.send("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode });
	}
}

// ---- Gecko: Zen or Firefox, over WebDriver BiDi ----

/**
 * A Gecko browser: `$GECKO`, else Zen or Firefox where they are installed, else the Firefox
 * Playwright keeps in its cache; null when there is none.
 */
export function findGecko() {
	if (process.env.GECKO) return process.env.GECKO;
	const installed =
		process.platform === "darwin" ? ["/Applications/Zen.app/Contents/MacOS/zen", "/Applications/Firefox.app/Contents/MacOS/firefox"] : ["/usr/bin/zen", "/usr/bin/zen-browser", "/usr/bin/firefox"];
	const found = installed.find((binary) => existsSync(binary));
	if (found) return found;
	const cache = playwrightCache();
	if (!existsSync(cache)) return null;
	for (const dir of readdirSync(cache).filter((name) => /^firefox-\d+$/.test(name)).sort().reverse()) {
		const binary = process.platform === "darwin" ? join(cache, dir, "firefox", "Nightly.app", "Contents", "MacOS", "firefox") : join(cache, dir, "firefox", "firefox");
		if (existsSync(binary)) return binary;
	}
	return null;
}

/**
 * Gecko, headless, in a profile of its own, driven over WebDriver BiDi (Node's WebSocket, no
 * geckodriver). Its first page is the tab it opens with, the others new tabs.
 */
export async function launchGecko(binary = findGecko()) {
	const profile = mkdtempSync(join(tmpdir(), "rocx-gecko-"));
	const child = spawn(binary, ["--headless", "--no-remote", "--profile", profile, "--remote-debugging-port=0", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
	const endpoint = await new Promise((resolve, reject) => {
		let seen = "";
		child.stderr.on("data", (chunk) => {
			seen += chunk;
			const match = /WebDriver BiDi listening on (ws:\/\/\S+)/.exec(seen);
			if (match) resolve(match[1]);
		});
		child.on("exit", (code) => reject(new Error(`gecko exited (${code}): ${seen}`)));
	});
	const socket = new WebSocket(`${endpoint}/session`);
	await new Promise((resolve, reject) => {
		socket.onopen = resolve;
		socket.onerror = reject;
	});
	let next = 0;
	const waiting = new Map();
	const listeners = [];
	socket.onmessage = ({ data }) => {
		const message = JSON.parse(data);
		if (message.id !== undefined && waiting.has(message.id)) {
			const { resolve, reject } = waiting.get(message.id);
			waiting.delete(message.id);
			if (message.type === "error") reject(new Error(`${message.error}: ${message.message}`));
			else resolve(message.result);
		} else if (message.type === "event") for (const listener of listeners) listener(message);
	};
	const send = (method, params = {}) =>
		new Promise((resolve, reject) => {
			const id = ++next;
			waiting.set(id, { resolve, reject });
			socket.send(JSON.stringify({ id, method, params }));
		});
	await send("session.new", { capabilities: {} });
	await send("session.subscribe", { events: ["log.entryAdded"] });
	let first = (await send("browsingContext.getTree", { maxDepth: 0 })).contexts[0]?.context;
	return {
		async page() {
			const context = first ?? (await send("browsingContext.create", { type: "tab" })).context;
			first = null;
			return new GeckoPage(send, context, listeners);
		},
		async close() {
			await send("session.end").catch(() => {});
			socket.close();
			child.kill();
			await new Promise((resolve) => (child.exitCode !== null ? resolve() : child.on("exit", resolve)));
			rmSync(profile, { recursive: true, force: true });
		},
	};
}

/** WebDriver's codes for the keys `press` knows by name. */
const GECKO_KEYS = { Enter: "\uE007", Escape: "\uE00C", Backspace: "\uE003", Tab: "\uE004", ArrowUp: "\uE013", ArrowDown: "\uE015", ArrowLeft: "\uE012", ArrowRight: "\uE014" };

/** A value BiDi serialized, as `Runtime.evaluate`'s `returnByValue` gives it. */
function fromBidi(value) {
	switch (value?.type) {
		case "undefined":
			return undefined;
		case "null":
			return null;
		case "number":
			return typeof value.value === "number" ? value.value : Number(value.value);
		case "bigint":
			return BigInt(value.value);
		case "array":
		case "set":
			return value.value.map(fromBidi);
		case "object":
		case "map":
			return Object.fromEntries(value.value.map(([key, each]) => [typeof key === "string" ? key : String(fromBidi(key)), fromBidi(each)]));
		case "string":
		case "boolean":
		case "date":
			return value.value;
		default:
			return {};
	}
}

/**
 * A drag made of the DOM's own drag events, in the page, in the order a browser fires them, each
 * with its coordinates, all carrying one shared `DataTransfer` (as one drag's events do), so what
 * dragstart sets, drop reads. `start(at, points)`: the element at `at`, or the nearest draggable
 * one around it (`draggable="true"`, a link, an image), gets dragstart (its `effectAllowed`
 * "uninitialized" until a handler sets it), then drag before each move. At each of `points`, the
 * element there (hit-tested, as the browser finds it) gets dragenter when the drag comes to it (and
 * the one it left, dragleave, after it: the browser's order), then dragover; their `dropEffect` is
 * the default for `effectAllowed` (copy, link, none, or else move) until a handler sets it, and a
 * dragover whose default is prevented accepts the drag with the `dropEffect` it left. `finish`:
 * drop on the last element, if it accepted the drag and `cancel` isn't asked, otherwise dragleave;
 * then dragend on the dragged element, its `dropEffect` the drop's ("none" if nothing took it).
 * Between them the drag is `window.__rocxDrag`.
 */
const DOM_DRAG = String.raw`({
	start(at, points) {
		const pressed = document.elementFromPoint(at.x, at.y);
		const source = pressed?.closest('[draggable="true"], a[href], img');
		if (!source) throw new Error("nothing draggable at (" + at.x + ", " + at.y + "): " + (pressed?.outerHTML.slice(0, 80) ?? "no element"));
		const transfer = new DataTransfer();
		transfer.effectAllowed = "uninitialized";
		const initial = () => (/^copy/.test(transfer.effectAllowed) ? "copy" : /^link/.test(transfer.effectAllowed) ? "link" : transfer.effectAllowed === "none" ? "none" : "move");
		const fire = (type, target, point, { effect = "none", related = null } = {}) => {
			transfer.dropEffect = type === "dragenter" || type === "dragover" ? initial() : effect;
			const event = new DragEvent(type, { bubbles: true, composed: true, cancelable: type !== "dragleave" && type !== "dragend", clientX: point.x, clientY: point.y, screenX: point.x, screenY: point.y, buttons: type === "drop" || type === "dragend" ? 0 : 1, relatedTarget: related, dataTransfer: transfer });
			return !target.dispatchEvent(event);
		};
		if (fire("dragstart", source, at)) return { started: false };
		const drag = (window.__rocxDrag = { source, transfer, fire, target: null, operation: "none", at });
		for (const point of points) {
			fire("drag", source, drag.at);
			const target = document.elementFromPoint(point.x, point.y) ?? document.documentElement;
			if (target !== drag.target) {
				fire("dragenter", target, point, { related: drag.target });
				if (drag.target) fire("dragleave", drag.target, point, { related: target });
				drag.target = target;
			}
			drag.operation = fire("dragover", target, point) ? transfer.dropEffect : "none";
			drag.at = point;
		}
		return { started: true, items: transfer.types.map((type) => ({ mimeType: type, data: transfer.getData(type) })) };
	},
	finish(cancel) {
		const drag = window.__rocxDrag;
		window.__rocxDrag = null;
		if (!drag) return false;
		const dropped = !cancel && drag.operation !== "none";
		if (dropped) drag.fire("drop", drag.target, drag.at, { effect: drag.operation });
		else if (drag.target) drag.fire("dragleave", drag.target, drag.at);
		drag.fire("dragend", drag.source, drag.at, { effect: dropped ? drag.operation : "none" });
		return dropped;
	},
})`;

/** A tab of Gecko's: what `Page` has, over WebDriver BiDi. */
class GeckoPage {
	constructor(send, context, listeners) {
		this.bidi = send;
		this.context = context;
		/** What the page logged and threw, for assertions: `{ type, text }` as Chromium's are. */
		this.console = [];
		this.errors = [];
		listeners.push((message) => {
			if (message.method !== "log.entryAdded" || message.params.source?.context !== context) return;
			const entry = message.params;
			if (entry.type === "console") this.console.push({ type: entry.method === "warn" ? "warning" : entry.method, text: entry.args?.map((arg) => fromBidi(arg) ?? "").join(" ") ?? entry.text });
			else if (entry.type === "javascript" && entry.level === "error") this.errors.push(entry.text);
		});
	}

	async beforeEachDocument(source) {
		await this.bidi("script.addPreloadScript", { functionDeclaration: `() => { ${source}\n}`, contexts: [this.context] });
	}

	async clearCookies() {
		await this.bidi("storage.deleteCookies", {});
	}

	async setCookie(name, value, url) {
		await this.bidi("storage.setCookie", { cookie: { name, value: { type: "string", value }, domain: new URL(url).hostname, path: "/" } });
	}

	close() {
		return this.bidi("browsingContext.close", { context: this.context }).catch(() => {});
	}

	/**
	 * Goes to `url` and waits for it to load. The tab is made the shown one first: headless, Gecko's
	 * tabs are hidden (`document.visibilityState`) until one is, and a hidden one gets a frame about
	 * once a second, so its transitions and animations seem frozen. (One tab of a browser shows at
	 * a time: the one last gone to.)
	 */
	async goto(url) {
		await this.bidi("browsingContext.activate", { context: this.context });
		await this.bidi("browsingContext.navigate", { context: this.context, url, wait: "complete" });
	}

	/** The value of `expression` (awaited when it is a promise). */
	async eval(expression) {
		const result = await this.bidi("script.evaluate", { expression, target: { context: this.context }, awaitPromise: true, serializationOptions: { maxObjectDepth: 32 } });
		if (result.type === "exception") throw new Error(result.exceptionDetails.text);
		return fromBidi(result.result);
	}

	async wait(expression, timeout = 5000) {
		const until = Date.now() + timeout;
		while (Date.now() < until) {
			if (await this.eval(`Boolean(${expression})`)) return;
			await new Promise((resolve) => setTimeout(resolve, 25));
		}
		throw new Error(`timed out waiting for ${expression}`);
	}

	center(selector) {
		return centerOf(this, selector);
	}

	/** WebDriver's input actions, each source's in turn. */
	actions(actions) {
		return this.bidi("input.performActions", { context: this.context, actions });
	}

	async click(selector) {
		const { x, y } = await this.center(selector);
		await this.clickAt(x, y);
	}

	async clickAt(x, y) {
		const at = { x: Math.round(x), y: Math.round(y) };
		await this.actions([{ type: "pointer", id: "mouse", parameters: { pointerType: "mouse" }, actions: [{ type: "pointerMove", ...at }, { type: "pointerDown", button: 0 }, { type: "pointerUp", button: 0 }] }]);
	}

	async type(selector, text) {
		await this.eval(`document.querySelector(${JSON.stringify(selector)}).focus()`);
		await this.insertText(text);
	}

	/** Text typed where the caret is, a key at a time (each `keydown`, `input` and `keyup` fires). */
	insertText(text) {
		return this.actions([{ type: "key", id: "keyboard", actions: [...text].flatMap((value) => [{ type: "keyDown", value }, { type: "keyUp", value }]) }]);
	}

	/** A key, pressed and released, by its `key` as the browser reports it (`" "` is the space bar). */
	press(key) {
		const value = GECKO_KEYS[key] ?? key;
		return this.actions([{ type: "key", id: "keyboard", actions: [{ type: "keyDown", value }, { type: "keyUp", value }] }]);
	}

	/**
	 * A drag: what `Page.drag` does, made of the DOM's own drag events (`DOM_DRAG`), as Gecko can't
	 * be made to: a drag started with WebDriver's pointer actions gets dragstart, dragenter and
	 * dragover, but never drop or dragend, and neither pointer-up nor Escape ends it, headless or
	 * not (Mozilla's bug 1515879: no pref changes it, nor pauses and moves between the actions). So
	 * no pointer or mouse events, either: a real press would start Gecko's own drag, which would
	 * then never end. The events aren't trusted (`isTrusted` is false). The drag's data, as
	 * dragstart left it: `{ items }`.
	 */
	async drag(from, over, { drop = true } = {}) {
		const start = typeof from === "string" ? await this.center(from) : from;
		const points = [];
		for (const target of [].concat(over)) points.push(typeof target === "string" ? await this.center(target) : target);
		const made = await this.eval(`${DOM_DRAG}.start(${JSON.stringify(start)}, ${JSON.stringify(points)})`);
		if (!made.started) throw new Error("the drag didn't start: dragstart's default was prevented");
		if (drop) await this.finish();
		return { items: made.items };
	}

	async finish({ cancel = false } = {}) {
		await this.eval(`${DOM_DRAG}.finish(${cancel})`);
	}

	/** A PNG of the page at `width` (the whole page when `full`). Gecko's BiDi can't emulate dark. */
	async screenshot({ width = 1280, height = 900, full = false, dark = false } = {}) {
		if (dark) throw new Error("Gecko over BiDi can't emulate prefers-color-scheme: take dark screenshots in Chromium");
		await this.bidi("browsingContext.setViewport", { context: this.context, viewport: { width, height } });
		const { data } = await this.bidi("browsingContext.captureScreenshot", { context: this.context, origin: full ? "document" : "viewport" });
		return Buffer.from(data, "base64");
	}
}
