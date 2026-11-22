// A Roc Solid app's server under test: started on a port of its own, asked as a browser asks it (a
// cookie jar, forms, JSON, endpoint reads, events), its dev mailbox read, its log parsed. The
// server is the app as built (`node server/build.mjs main.roc build/server`, after `rocx build`).
//
//   const app = await startServer("build/server", { database: db.url });
//   const browser = app.client();
//   const page = await browser.get("/");
//   page.dom.getByRole("heading", { name: "Notes" });
//   assert.equal(await browser.read("/notes/count"), 1);
//   const mail = await app.waitForMail({ to: "ada@example.com" });
//   after(() => app.stop());
import { spawn } from "node:child_process";
import { parse, within } from "./dom.mjs";

/**
 * Starts the server `executable` on a free port (`--port 0`) with `--debug` (the mailbox's JSON) and
 * what `options` say, and resolves once it listens:
 *
 * - `database`: its `--database-url` (a test's own: postgres.mjs's `testDatabase`);
 * - `dev`: `--dev` (the mailbox's pages, crash pages, page reloads);
 * - `statics`: directories it serves files from (`--static`, each);
 * - `context`: a file of what its middleware is given (`--context-file`);
 * - `flags`: any other flags; `env`: added to this process's environment (`ROCX_LOG` is `json`,
 *   so `logs()` can read it, unless `env` says otherwise).
 *
 * A server that exits before it listens rejects, with what it logged.
 */
export async function startServer(executable, { database, dev = false, debug = true, statics = [], context, flags = [], env = {}, cwd } = {}) {
	const args = [
		"--port",
		"0",
		...(debug ? ["--debug"] : []),
		...(dev ? ["--dev"] : []),
		...(database ? ["--database-url", database] : []),
		...(context ? ["--context-file", context] : []),
		...statics.flatMap((dir) => ["--static", dir]),
		...flags,
	];
	const child = spawn(executable, args, { cwd, stdio: ["ignore", "ignore", "pipe"], env: { ...process.env, ROCX_LOG: "json", ...env } });
	let said = "";
	const url = await new Promise((resolve, reject) => {
		child.stderr.on("data", (chunk) => {
			said += chunk;
			const listening = /rocx server: (http:\/\/\S+) /.exec(said);
			if (listening) resolve(listening[1]);
		});
		child.on("error", reject);
		child.on("exit", (code) => reject(new Error(`${executable} exited (${code}) before it listened:\n${said}`)));
	});
	return new Server(url, child, () => said);
}

/** A server started by `startServer`. */
export class Server {
	constructor(url, child, said) {
		/** Where it listens: `http://127.0.0.1:<port>`, its origin too. */
		this.url = url;
		this.origin = url;
		this.child = child;
		/** What it has logged so far, as it wrote it. */
		this.said = said;
	}

	/** The events it has logged so far, each line parsed (`ROCX_LOG=json`); `{ msg }` for a line that isn't JSON. */
	logs() {
		return this.said()
			.split("\n")
			.filter((line) => line.trim())
			.map((line) => {
				try {
					return JSON.parse(line);
				} catch {
					return { msg: line };
				}
			});
	}

	/** Someone at a browser, with a cookie jar of their own. */
	client(options) {
		return new Client(this, options);
	}

	/** What `Email.send!` (packages/email) kept rather than sent (no `SMTP_URL`): every message, oldest first. */
	async mail() {
		const answer = await fetch(`${this.url}/__rocx/mail.json`);
		if (!answer.ok) throw new Error(`the mailbox: ${answer.status} ${await answer.text()} (it needs --debug or --dev)`);
		return answer.json();
	}

	/**
	 * Waits for a message `match` says yes to (a function, or fields to compare: `{ to: "ada@…",
	 * subject: /welcome/i }`), among those after the first `after`, for `ms` at most: the first.
	 */
	async waitForMail(match = () => true, { after = 0, ms = 5000 } = {}) {
		const test = typeof match === "function" ? match : (message) => Object.entries(match).every(([field, wanted]) => (wanted instanceof RegExp ? wanted.test(message[field]) : message[field] === wanted));
		let seen = [];
		try {
			return await until(
				async () => {
					seen = (await this.mail()).slice(after);
					return seen.find(test);
				},
				{ ms, what: "the mail" },
			);
		} catch (error) {
			error.message += `; the mailbox has: ${JSON.stringify(seen.map(({ to, subject }) => ({ to, subject })))}`;
			throw error;
		}
	}

	/** Stops it as a deploy would (SIGTERM, letting what it is answering finish): its exit code. */
	stop() {
		const child = this.child;
		if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(child.exitCode);
		return new Promise((resolve) => {
			child.once("exit", resolve);
			child.kill("SIGTERM");
		});
	}
}

/**
 * Someone at a browser: a cookie jar, and requests that don't follow redirects (a test sees each
 * one; `answer.follow()` takes it). A request that changes something carries the site's `Origin`, as
 * a browser's does, so `Middleware.same_origin` lets it through.
 */
export class Client {
	constructor(server, { origin = server.origin, headers = {} } = {}) {
		this.server = server;
		this.origin = origin;
		/** Headers every request carries. */
		this.headers = headers;
		/** The cookies the server has set and not cleared, by name. */
		this.cookies = new Map();
		/** The last page it got (`get`), whose URL a form it posts next is sent from (`referer`). */
		this.page = null;
	}

	#keep(response) {
		for (const line of response.headers.getSetCookie()) {
			const [pair, ...attributes] = line.split(";").map((part) => part.trim());
			const at = pair.indexOf("=");
			const name = pair.slice(0, at);
			const gone = attributes.some((attribute) => /^max-age=0$/i.test(attribute) || (/^expires=/i.test(attribute) && Date.parse(attribute.slice(8)) < Date.now()));
			if (gone) this.cookies.delete(name);
			else this.cookies.set(name, pair.slice(at + 1));
		}
	}

	/**
	 * The flash a plain form's post came back with (`post`), as the page it lands on reads it
	 * (`Server.flash!`): `{ url, input, status, body }`, the endpoint's URL, what was typed, and its
	 * result (status 200, its JSON) or refusal (its status, and why). Null when there is none: the
	 * page a browser asks for next lets it go.
	 */
	get flash() {
		const kept = this.cookies.get("rocx-flash");
		return kept ? JSON.parse(decodeURIComponent(kept)) : null;
	}

	/** Sends a request; its answer, read whole (`Answer`). An event stream isn't: `events()` reads one. */
	async request(target, { method = "GET", headers = {}, body } = {}) {
		const changes = !["GET", "HEAD", "OPTIONS"].includes(method.toUpperCase());
		const cookie = [...this.cookies].map(([name, value]) => `${name}=${value}`).join("; ");
		const response = await fetch(new URL(target, this.server.url), {
			method,
			redirect: "manual",
			headers: { ...(cookie ? { cookie } : {}), ...(changes ? { origin: this.origin } : {}), ...this.headers, ...headers },
			body,
		});
		this.#keep(response);
		const bytes = Buffer.from(await response.arrayBuffer());
		return new Answer(this, response, bytes);
	}

	/** A page, as a browser asks for one (`accept: text/html`); a form posted next is sent from it. */
	async get(target, headers = {}) {
		const answer = await this.request(target, { headers: { accept: "text/html", ...headers } });
		if (answer.status === 200 && (answer.headers.get("content-type") ?? "").startsWith("text/html")) this.page = new URL(target, this.server.url).href;
		return answer;
	}

	/**
	 * A form posted from the last page, as a browser without the runtime posts it (urlencoded,
	 * `accept: text/html`): an endpoint answers it by going back to that page with a flash, a 303
	 * (`answer.follow()` lands there).
	 */
	post(target, fields = {}, headers = {}) {
		const body = new URLSearchParams(fields).toString();
		const from = this.page ? { referer: this.page } : {};
		return this.request(target, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", accept: "text/html,application/xhtml+xml,*/*;q=0.8", ...from, ...headers }, body });
	}

	/**
	 * A form as the runtime sends it once the page has hydrated (`x-rocx-submission`): the endpoint's
	 * result or refusal comes back as it is, and its own redirect as `x-rocx-redirect` with a 200.
	 */
	submit(target, fields = {}, headers = {}) {
		const body = new URLSearchParams(fields).toString();
		return this.request(target, { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json", "x-rocx-submission": "1", ...headers }, body });
	}

	/** JSON sent to an endpoint (`method`: POST unless said). */
	json(target, value, method = "POST", headers = {}) {
		return this.request(target, { method, headers: { "content-type": "application/json", accept: "application/json", ...headers }, body: JSON.stringify(value) });
	}

	/** Bytes sent as they are (a file, or a part of one). */
	put(target, bytes, headers = {}) {
		return this.request(target, { method: "PUT", headers, body: bytes });
	}

	/**
	 * Reads a GET endpoint as a page does (`Endpoint.get!`: `accept: application/json`, with the
	 * cookies): its answer, parsed. An answer that isn't a 200 throws a ReadError, with its status
	 * and text.
	 */
	async read(target, headers = {}) {
		const answer = await this.request(target, { headers: { accept: "application/json", ...headers } });
		if (answer.status !== 200) throw new ReadError(target, answer.status, answer.text);
		return answer.json();
	}

	/**
	 * Listens to an endpoint's server-sent events (`events!`), as `Endpoint.listen!` does: each event
	 * `{ event, data, id }` in turn (`for await`, or `next()`); `close()` hangs up, as a page that
	 * goes does.
	 */
	async events(target, headers = {}) {
		const controller = new AbortController();
		const cookie = [...this.cookies].map(([name, value]) => `${name}=${value}`).join("; ");
		const response = await fetch(new URL(target, this.server.url), { headers: { accept: "text/event-stream", ...(cookie ? { cookie } : {}), ...this.headers, ...headers }, signal: controller.signal });
		if (!(response.headers.get("content-type") ?? "").startsWith("text/event-stream")) {
			const said = await response.text();
			controller.abort();
			throw new Error(`${target} isn't a stream of events: ${response.status} ${said.slice(0, 200)}`);
		}
		return new Events(response, controller);
	}
}

/** A read of an endpoint that answered something other than a 200. */
export class ReadError extends Error {
	name = "ReadError";

	constructor(target, status, text) {
		super(`GET ${target}: ${status} ${text}`);
		this.status = status;
		this.text = text;
	}
}

/** A server's answer, read whole. */
export class Answer {
	#dom;

	constructor(client, response, bytes) {
		this.client = client;
		this.status = response.status;
		this.headers = response.headers;
		/** Its body as it came. */
		this.bytes = bytes;
		/** Its body as text. */
		this.text = bytes.toString("utf8");
	}

	/** Where a redirect goes (`location`), or null. */
	get location() {
		return this.headers.get("location");
	}

	/** Its body as JSON. */
	json() {
		return JSON.parse(this.text);
	}

	/** Its body as a page, parsed, with the queries bound to it (dom.mjs's `within`): `answer.dom.getByRole(…)`. */
	get dom() {
		this.#dom ??= within(parse(this.text));
		return this.#dom;
	}

	/** Follows its redirect, as a browser would: a GET of where it goes. */
	follow(headers = {}) {
		if (!this.location) throw new Error(`a ${this.status} isn't a redirect`);
		return this.client.get(this.location, headers);
	}
}

/** Server-sent events, read as they come. */
export class Events {
	#reader;
	#decoder = new TextDecoder();
	#buffer = "";
	#ready = [];
	#done = false;

	constructor(response, controller) {
		this.response = response;
		this.#reader = response.body.getReader();
		this.controller = controller;
	}

	/** The next event (`{ event, data, id }`; `event` is "message" unless the server named it), or null once the stream ends. */
	async next() {
		while (!this.#ready.length && !this.#done) {
			const { value, done } = await this.#reader.read().catch(() => ({ done: true }));
			if (done) {
				this.#done = true;
				break;
			}
			this.#buffer += this.#decoder.decode(value, { stream: true }).replace(/\r\n?/g, "\n");
			let end;
			while ((end = this.#buffer.indexOf("\n\n")) !== -1) {
				const block = this.#buffer.slice(0, end);
				this.#buffer = this.#buffer.slice(end + 2);
				const event = { event: "message", data: [], id: null };
				for (const line of block.split("\n")) {
					if (!line || line.startsWith(":")) continue;
					const colon = line.indexOf(":");
					const field = colon === -1 ? line : line.slice(0, colon);
					const said = colon === -1 ? "" : line.slice(colon + 1).replace(/^ /, "");
					if (field === "data") event.data.push(said);
					else if (field === "event") event.event = said;
					else if (field === "id") event.id = said;
				}
				if (event.data.length) this.#ready.push({ ...event, data: event.data.join("\n") });
			}
		}
		return this.#ready.shift() ?? null;
	}

	/** The next `count` events (fewer if the stream ends first). */
	async take(count) {
		const taken = [];
		while (taken.length < count) {
			const event = await this.next();
			if (!event) break;
			taken.push(event);
		}
		return taken;
	}

	/** Hangs up. */
	close() {
		this.#done = true;
		this.controller.abort();
	}

	async *[Symbol.asyncIterator]() {
		try {
			for (let event = await this.next(); event; event = await this.next()) yield event;
		} finally {
			this.close();
		}
	}
}

/** Waits until `check` (awaited) gives something truthy, asking every 25 ms, for `ms` at most: that value. */
export async function until(check, { ms = 5000, every = 25, what = "the condition" } = {}) {
	const end = Date.now() + ms;
	for (;;) {
		const value = await check();
		if (value) return value;
		if (Date.now() > end) throw new Error(`timed out after ${ms} ms waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, every));
	}
}

/** The links in a message: its HTML's `<a href>`s, or else the URLs in its text (without the full stop after one). */
export function links(message) {
	if (message.html) {
		return within(parse(message.html))
			.queryAllByRole("link")
			.map((link) => link.attr("href"));
	}
	return [...(message.text ?? "").matchAll(/https?:\/\/[^\s<>"')]+/g)].map((match) => match[0].replace(/[.,;:!?]+$/, ""));
}

/**
 * The path of a component's story in a dev build's catalog (`rocx build --dev`): `module` as rocx
 * names it (`Ui/Callout`), the story's `name` ("Tip"), and its `component` when it isn't the module's.
 * A story is the component as it looks, in the app's layout: a test can fetch it, or open it.
 */
export function storyPath(module, name, component = module.split("/").pop()) {
	const kebab = (text) => text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
	return ["/__rocx/stories", module, ...(component === module.split("/").pop() ? [] : [component]), kebab(name)].join("/");
}
