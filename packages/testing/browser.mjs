// A page in a real browser: Chromium's headless shell, driven by the repository's own DevTools
// driver (web/test/browser.mjs, no dependencies). A tab hydrates strictly (a page that isn't what
// the browser's half renders throws, instead of being rendered again), is found in by role and name
// as dom.mjs finds (it reads the live document), and is used with real clicks and keys.
//
//   const browser = await launchBrowser();          // null without Chromium: skip
//   const tab = await browser.open(`${app.url}/`);   // hydrated
//   await (await tab.getByRole("button", { name: "Add one" })).click();
//   assert.equal((await tab.findByText("2")).tag, "output");
//   assert.deepEqual(tab.errors, []);
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repo } from "./build.mjs";
import { QueryError, parse, within } from "./dom.mjs";

/** The DevTools driver: web/test/browser.mjs (`findChrome`, `launch`). */
const driver = () => import(pathToFileURL(join(repo, "web", "test", "browser.mjs")).href);

/** Chromium's headless shell: `$CHROME`, or Playwright's cached one; null when there is none. */
export async function findChrome() {
	return (await driver()).findChrome();
}

/**
 * Chromium, started (`close()` when done); null when there is none, for a test to skip. Its tabs
 * share their cookies, as one person's browser does: for two people at once, launch twice.
 */
export async function launchBrowser() {
	const { findChrome: find, launch } = await driver();
	const binary = find();
	return binary ? new Browser(await launch(binary)) : null;
}

/** What every tab runs before the page does: strict hydration (when asked), and `rocx:ready` noted. */
const BEFORE = (strict) => `${strict ? "window.rocxStrict = true;" : ""} document.addEventListener("rocx:ready", (event) => { window.__rocxReady = { ms: event.detail?.ms ?? 0 }; });`;

/** A started Chromium. */
export class Browser {
	constructor(chrome) {
		this.chrome = chrome;
	}

	/**
	 * A tab at `url`, loaded, and hydrated if the page loads the runtime (`/rocx/start.js`). `strict`
	 * (the default) makes a page that isn't what the browser's half renders throw. `cookies` (a
	 * client's, `[name, value]` pairs or a Map) are set first; the tabs of one browser share cookies,
	 * so each `open` clears them before.
	 */
	async open(url, { strict = true, cookies = [], timeout = 10_000 } = {}) {
		const page = await this.chrome.page();
		await page.send("Page.enable");
		await page.send("Network.enable");
		await page.send("Network.clearBrowserCookies");
		await page.send("Page.addScriptToEvaluateOnNewDocument", { source: BEFORE(strict) });
		for (const [name, value] of cookies) await page.send("Network.setCookie", { name, value, url });
		const tab = new Tab(page);
		await tab.goto(url, { timeout });
		return tab;
	}

	close() {
		return this.chrome.close();
	}
}

/**
 * The queries a tab has, each as dom.mjs has it, async: getBy…, queryBy…, getAllBy…, queryAllBy…,
 * and findBy… and findAllBy…, which look again until they find (`(query, options, { ms })`).
 */
const KINDS = ["Role", "Text", "LabelText", "TestId"];

/** A tab: its document as it is now, its elements found as a person finds them, and used. */
export class Tab {
	constructor(page) {
		/** The driver's page (web/test/browser.mjs): `send`, `eval`, `wait`, `screenshot`. */
		this.page = page;
		for (const kind of KINDS) {
			for (const form of [`getBy${kind}`, `queryBy${kind}`, `getAllBy${kind}`, `queryAllBy${kind}`]) {
				this[form] = async (...args) => {
					const found = (await this.dom())[form](...args);
					return Array.isArray(found) ? found.map((node) => new Element(this, node)) : found && new Element(this, found);
				};
			}
			this[`findBy${kind}`] = (query, options, wait) => this.waitFor(async (dom) => new Element(this, dom[`getBy${kind}`](query, options)), wait);
			this[`findAllBy${kind}`] = (query, options, wait) => this.waitFor(async (dom) => dom[`getAllBy${kind}`](query, options).map((node) => new Element(this, node)), wait);
		}
	}

	/** What the page logged (`{ type, text }`) and threw: a test checks they are empty. */
	get console() {
		return this.page.console;
	}

	get errors() {
		return this.page.errors;
	}

	/** Goes to `url`, and waits for it to load and, if it loads the runtime, to hydrate. */
	async goto(url, { timeout = 10_000 } = {}) {
		await this.page.goto(url);
		const hydrates = await this.page.eval(`Boolean(document.querySelector('script[src$="rocx/start.js"]'))`);
		if (!hydrates) return;
		try {
			await this.page.wait("window.__rocxReady", timeout);
		} catch {
			throw new Error(`${url} didn't hydrate in ${timeout} ms; it threw ${JSON.stringify(this.errors)}, and logged ${JSON.stringify(this.console)}`);
		}
	}

	/** The document as it is now, parsed, with dom.mjs's queries bound to it. */
	async dom() {
		return within(parse(await this.page.eval("document.documentElement.outerHTML")));
	}

	/** What a reader reads on the page now. */
	async text() {
		return (await this.dom()).scope.text;
	}

	/**
	 * Waits until `check(dom)` (the document now, queried as `dom()` is) gives something truthy
	 * without throwing, looking again every 25 ms for `ms` at most: that value. Its last error, if it
	 * never does.
	 */
	async waitFor(check, { ms = 5000 } = {}) {
		const end = Date.now() + ms;
		let last = null;
		for (;;) {
			try {
				const value = await check(await this.dom());
				if (value) return value;
				last = null;
			} catch (error) {
				if (!(error instanceof QueryError)) throw error;
				last = error;
			}
			if (Date.now() > end) throw last ?? new Error(`timed out after ${ms} ms waiting for the page`);
			await new Promise((resolve) => setTimeout(resolve, 25));
		}
	}

	/** The paths the page fetched since it loaded (its scripts, its wasm, what it asked the server). */
	requested() {
		return this.page.eval('performance.getEntriesByType("resource").map((entry) => new URL(entry.name).pathname)');
	}

	/** A PNG of the page (web/test/browser.mjs's options: `width`, `height`, `full`, `dark`). */
	screenshot(options) {
		return this.page.screenshot(options);
	}

	close() {
		return this.page.send("Page.close").catch(() => {});
	}
}

/**
 * An element of the page as it was when it was found (`tag`, `text`, `attr`, `role`, `name`, `node`),
 * and what a person does to it, through the browser's input: `click`, `fill`, `type`, `press`. It is
 * found again by its place in the document when used, and one that has gone, or become another
 * element, refuses.
 */
export class Element {
	constructor(tab, node) {
		this.tab = tab;
		/** The node dom.mjs parsed. */
		this.node = node;
		this.tag = node.tag;
		this.text = node.text;
		this.role = node.role;
		this.name = node.name;
		this.path = node.path;
	}

	attr(name) {
		return this.node.attr(name);
	}

	/** Runs `body` (JavaScript, with `element` the live element) in the page: its value. */
	async #in(body) {
		const value = await this.tab.page.eval(`(() => {
			let element = document;
			for (const index of ${JSON.stringify(this.path)}) element = element?.children[index];
			if (!element || element.tagName.toLowerCase() !== ${JSON.stringify(this.tag)}) return { gone: true };
			return { value: (() => { ${body} })() };
		})()`);
		if (value.gone) throw new Error(`the <${this.tag}> ${JSON.stringify(this.text)} isn't on the page any more`);
		return value.value;
	}

	/**
	 * A real click, at its middle, through the browser's input (after scrolling it into view). The
	 * scroll is instant whatever the page's CSS says: with `scroll-behavior: smooth` the element
	 * would still be on its way when it is measured, and the click would land where it was.
	 */
	async click() {
		const box = await this.#in('element.scrollIntoView({ block: "center", behavior: "instant" }); const r = element.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 };');
		for (const type of ["mousePressed", "mouseReleased"]) await this.tab.page.send("Input.dispatchMouseEvent", { type, x: box.x, y: box.y, button: "left", clickCount: 1 });
	}

	focus() {
		return this.#in("element.focus(); return true;");
	}

	/** Types `text` where the caret is, as a keyboard does (each `input` event fires). */
	async type(text) {
		await this.focus();
		await this.tab.page.send("Input.insertText", { text });
	}

	/** Replaces what is in a field with `text`, as selecting it all and typing does. */
	async fill(text) {
		await this.#in("element.focus(); element.select?.(); return true;");
		if (text) await this.tab.page.send("Input.insertText", { text });
		else await this.tab.page.press("Backspace");
	}

	/** A key, pressed and released, with it focused (`"Enter"`, `"Escape"`, `"ArrowUp"`, `" "`). */
	async press(key) {
		await this.focus();
		await this.tab.page.press(key);
	}

	/** Its value now (a field's, as typed), not as it was found. */
	value() {
		return this.#in("return element.value ?? null;");
	}

	/** Whether it is ticked now (a checkbox, a radio). */
	checked() {
		return this.#in("return Boolean(element.checked);");
	}
}
