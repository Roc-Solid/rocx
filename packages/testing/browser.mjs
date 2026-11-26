// A page in a real browser: Chromium's headless shell, or Gecko (Zen, or Firefox) headless,
// driven by the repository's own driver (web/test/browser.mjs, no dependencies: the DevTools
// protocol, and WebDriver BiDi for Gecko). A tab hydrates strictly (a page that isn't what the
// browser's half renders throws, instead of being rendered again), is found in by role and name as
// dom.mjs finds (it reads the live document), and is used with real clicks and keys, and drags (a
// mouse's, and a finger's).
//
//   const browser = await launchBrowser();          // null without Chromium: skip (in CI: an error)
//   const tab = await browser.open(`${app.url}/`);   // hydrated
//   await (await tab.getByRole("button", { name: "Add one" })).click();
//   assert.equal((await tab.findByText("2")).tag, "output");
//   await tab.drag(await tab.getByText("Card"), await tab.getByRole("list", { name: "Done" }));
//   await tab.touchDrag(await tab.getByText("Card"), await tab.getByRole("list", { name: "Done" }));   // by touch
//   assert.deepEqual(tab.errors, []);
//
//   const gecko = await launchBrowser({ engine: "gecko" });   // null without Zen or Firefox
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { repo } from "./build.mjs";
import { QueryError, parse, within } from "./dom.mjs";

/** The driver: web/test/browser.mjs (`findChrome`, `launch`, `findGecko`, `launchGecko`). */
const driver = () => import(pathToFileURL(join(repo, "web", "test", "browser.mjs")).href);

/** Chromium's headless shell: `$CHROME`, or Playwright's cached one; when there is none, null (said
 * once on the console), or an error where browsers are required (`browsersRequired`). */
export async function findChrome() {
	return (await driver()).findChrome();
}

/** A Gecko browser (`$GECKO`, Zen, Firefox, or Playwright's Firefox); when there is none, as `findChrome`. */
export async function findGecko() {
	return (await driver()).findGecko();
}

/**
 * Whether a missing browser fails the tests rather than skipping them: with
 * `ROCX_BROWSERS=required`, and in CI (`CI` set, as GitHub Actions sets it) unless
 * `ROCX_BROWSERS=optional`.
 */
export async function browsersRequired() {
	return (await driver()).browsersRequired();
}

/**
 * A browser, started (`close()` when done): Chromium, or with `engine: "gecko"` Zen or Firefox.
 * When there is none, null, for a test to skip (the run says so once, on the console); where
 * browsers are required (in CI, or with `ROCX_BROWSERS=required`: `browsersRequired`) an error
 * instead, so a broken browser install fails the run rather than skipping its browser tests. Its
 * tabs share their cookies, as one person's browser does: for two people at once, launch twice.
 */
export async function launchBrowser({ engine = "chromium" } = {}) {
	const { findChrome: chrome, launch, findGecko: gecko, launchGecko } = await driver();
	if (engine !== "chromium" && engine !== "gecko") throw new Error(`no browser engine ${JSON.stringify(engine)}: "chromium" or "gecko"`);
	const binary = engine === "gecko" ? gecko() : chrome();
	return binary ? new Browser(engine === "gecko" ? await launchGecko(binary) : await launch(binary), engine) : null;
}

/** What every tab runs before the page does: strict hydration (when asked), and `rocx:ready` noted. */
const BEFORE = (strict) => `${strict ? "window.rocxStrict = true;" : ""} document.addEventListener("rocx:ready", (event) => { window.__rocxReady = { ms: event.detail?.ms ?? 0 }; });`;

/** A started browser: `engine` is "chromium" or "gecko". */
export class Browser {
	constructor(driven, engine = "chromium") {
		this.driven = driven;
		this.engine = engine;
	}

	/**
	 * A tab at `url`, loaded, and hydrated if the page loads the runtime (`/rocx/start.js`). `strict`
	 * (the default) makes a page that isn't what the browser's half renders throw. `cookies` (a
	 * client's, `[name, value]` pairs or a Map) are set first; the tabs of one browser share cookies,
	 * so each `open` clears them before. `script` (JavaScript) runs in each document the tab loads,
	 * before the page's own scripts.
	 */
	async open(url, { strict = true, cookies = [], script = "", timeout = 10_000 } = {}) {
		const page = await this.driven.page();
		await page.clearCookies();
		await page.beforeEachDocument(`${BEFORE(strict)}\n${script}`);
		for (const [name, value] of cookies) await page.setCookie(name, value, url);
		const tab = new Tab(page);
		await tab.goto(url, { timeout });
		return tab;
	}

	close() {
		return this.driven.close();
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
		/** The driver's page (web/test/browser.mjs): `eval`, `wait`, `screenshot`; Chromium's `send`. */
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

	/** The document as it is now, parsed, with dom.mjs's queries bound to it. Between two documents
	 * (a click that goes to another page) there is none for a moment: an empty one then, which
	 * finds nothing, so `waitFor` looks again. */
	async dom() {
		return within(parse(await this.page.eval(`document.documentElement?.outerHTML ?? "<html></html>"`)));
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

	/**
	 * A drag of `source` onto `target` (each an element this tab found, or a CSS selector), as a
	 * person does it with a mouse, pressed at the middle of one and dropped at the middle of the
	 * other: dragstart, drag, dragenter, dragover, drop (if `target` accepts it: its dragover's
	 * default prevented), dragend, each with its coordinates. Unless `drop` is false: the drag stays
	 * over `target`, for `finish`. In Chromium, real pointer input through the browser's own drag and
	 * drop (every event trusted); in Gecko, which never ends a drag WebDriver starts, the DOM's own
	 * drag events, all carrying one `DataTransfer`, and no pointer or mouse events
	 * (web/test/browser.mjs, `GeckoPage.drag`, says exactly what fires). What the drag carried, as
	 * dragstart set it: `{ items: [{ mimeType, data }] }` (Chromium's has more).
	 */
	async drag(source, target, { drop = true } = {}) {
		const at = async (each) => (typeof each === "string" ? each : await each.selector());
		return this.page.drag(await at(source), [await at(target)], { drop });
	}

	/**
	 * The drag `drag(…, { drop: false })` left over its target, dropped (or, `cancel`, called off:
	 * in Gecko, dragleave on the target and dragend, as the HTML standard has it; in Chromium, whose
	 * DevTools protocol calls a drag off its own way, dragend alone).
	 */
	finish({ cancel = false } = {}) {
		return this.page.finish({ cancel });
	}

	/**
	 * A drag of `source` onto `target` by touch, as a person does it on a phone (D-055): a finger put
	 * down on the middle of one, held `hold` milliseconds (the runtime starts a drag of its own after
	 * a quarter second held still), moved to the middle of the other a frame at a time, and lifted,
	 * unless `lift` is false (it stays down there, for `lift`). `hold: 0` is a swipe, which scrolls
	 * instead. Real touch input in both engines (touch events, and the pointer events the browser
	 * makes of them): the DevTools protocol's in Chromium, WebDriver's touch actions in Gecko.
	 */
	async touchDrag(source, target, { hold = 400, lift = true } = {}) {
		const at = async (each) => (typeof each === "string" || (typeof each === "object" && "x" in each) ? each : await each.selector());
		return this.page.touchDrag(await at(source), [await at(target)], { hold, lift });
	}

	/** The finger `touchDrag(…, { lift: false })` left down, lifted. */
	lift() {
		return this.page.lift();
	}

	close() {
		return this.page.close();
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

	/** A CSS selector of it, by its place in the document (it refuses if it has gone). */
	async selector() {
		await this.#in("return true;");
		return `:root${this.path
			.slice(1)
			.map((index) => ` > :nth-child(${index + 1})`)
			.join("")}`;
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
		await this.tab.page.clickAt(box.x, box.y);
	}

	focus() {
		return this.#in("element.focus(); return true;");
	}

	/** Types `text` where the caret is, as a keyboard does (each `input` event fires). */
	async type(text) {
		await this.focus();
		await this.tab.page.insertText(text);
	}

	/** Replaces what is in a field with `text`, as selecting it all and typing does. */
	async fill(text) {
		await this.#in("element.focus(); element.select?.(); return true;");
		if (text) await this.tab.page.insertText(text);
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
