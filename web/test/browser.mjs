// A real browser for tests, with no dependencies: Chromium's headless shell, driven over the
// DevTools protocol with Node's own WebSocket. $CHROME names the binary; otherwise the one
// Playwright keeps in its cache is used, and the tests that need it are skipped without one.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";

export function findChrome() {
	if (process.env.CHROME) return process.env.CHROME;
	const cache = join(homedir(), process.platform === "darwin" ? "Library/Caches/ms-playwright" : ".cache/ms-playwright");
	if (!existsSync(cache)) return null;
	for (const dir of readdirSync(cache).filter((name) => name.startsWith("chromium_headless_shell-")).sort().reverse()) {
		for (const platform of readdirSync(join(cache, dir))) {
			const binary = join(cache, dir, platform, "chrome-headless-shell");
			if (existsSync(binary)) return binary;
		}
	}
	return null;
}

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
		return this.eval(`(() => {
			const element = document.querySelector(${JSON.stringify(selector)});
			element.scrollIntoView({ block: "center", behavior: "instant" });
			const r = element.getBoundingClientRect();
			return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
		})()`);
	}

	/**
	 * A drag, as a mouse does it, through the browser's own drag and drop: pressed on `from`, moved,
	 * so the browser starts a drag (dragstart, with the data it sets), then over each of `over` (an
	 * element's middle, or `{ x, y }`) and dropped on the last (dragenter, dragover, drop, then
	 * dragend), unless `drop` is false (the drag stays over the last, for `finish`). The drag's data,
	 * as the browser took it from dragstart: `{ items, dragOperationsMask }`.
	 */
	async drag(from, over, { drop = true } = {}) {
		await this.send("Input.setInterceptDrags", { enabled: true });
		const start = await this.center(from);
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
		const box = await this.eval(`(() => {
			const element = document.querySelector(${JSON.stringify(selector)});
			element.scrollIntoView({ block: "center", behavior: "instant" });
			const r = element.getBoundingClientRect();
			return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
		})()`);
		for (const type of ["mousePressed", "mouseReleased"]) await this.send("Input.dispatchMouseEvent", { type, x: box.x, y: box.y, button: "left", clickCount: 1 });
	}

	/** Typing, as a keyboard would: focus, then text inserted where the caret is. */
	async type(selector, text) {
		await this.eval(`document.querySelector(${JSON.stringify(selector)}).focus()`);
		await this.send("Input.insertText", { text });
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
