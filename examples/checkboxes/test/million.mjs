// What Million's tests share: the app built once at a time (rocx build writes Generated/ in the
// app's own folder, so two test files building at once would race; a lock directory takes turns),
// and its server started with the app's own files (`static/`) beside the built wasm. No database:
// the boxes are the server's memory, new with each server.
import { mkdirSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer } from "../../../packages/testing/index.mjs";

/** The app's folder. */
export const dir = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The app, built (`rocx build`, the browser's wasm, the server): `{ server, statics }`. */
export async function build() {
	const lock = join(dir, "build", "building.lock");
	mkdirSync(join(dir, "build"), { recursive: true });
	for (;;) {
		try {
			mkdirSync(lock);
			break;
		} catch {
			// A lock left by a build that died is ten minutes old: take it.
			if (Date.now() - (statSync(lock, { throwIfNoEntry: false })?.mtimeMs ?? Date.now()) > 10 * 60 * 1000) rmSync(lock, { recursive: true, force: true });
			await new Promise((resolve) => setTimeout(resolve, 200));
		}
	}
	try {
		return await buildForTests(dir);
	} finally {
		rmSync(lock, { recursive: true, force: true });
	}
}

/** The built app's server, on a free port, serving the wasm and `static/`. */
export async function start(built, options = {}) {
	return startServer(built.server, { statics: [...built.statics, join(dir, "static")], ...options });
}

/** The chunk `index` is in, and the bit its box is: what `Grid` says, for checking what the server sends. */
export function checkedIn(bits, index) {
	if (!bits) return false;
	const at = index % 1000;
	const byte = parseInt(bits.slice(2 * Math.floor(at / 8), 2 * Math.floor(at / 8) + 2), 16);
	return (byte & (1 << at % 8)) !== 0;
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * A tab following the boxes' channel as `client`: the channel's stream, as the runtime's hub opens
 * it. `next(match)` waits for the next message (parsed: `{ Changed: chunk }` or `{ Online: n }`)
 * that `match` says yes to, passing over the others; `close()` hangs up, as a tab that closes does.
 */
export async function follow(client, tab) {
	const events = await client.events(`/rocx/live?tab=${tab}&c=${encodeURIComponent("/boxes")}`);
	return {
		tab,
		async next(match = () => true, { ms = 10000 } = {}) {
			const deadline = Date.now() + ms;
			for (;;) {
				const left = deadline - Date.now();
				if (left <= 0) throw new Error(`${tab}: no message came that matched within ${ms} ms`);
				const event = await Promise.race([events.next(), wait(left).then(() => "late")]);
				if (event === "late") continue;
				if (!event) throw new Error(`${tab}: the stream ended`);
				if (event.event !== "message") continue;
				const message = JSON.parse(event.data.split("\n").slice(1).join("\n"));
				if (match(message)) return message;
			}
		},
		close: () => events.close(),
	};
}

/** Says each of `messages` on the boxes' channel from `tab`, in one post, as a page's `Endpoint.say!` calls in one frame are: the answer. */
export function say(client, tab, ...messages) {
	return client.request(`/rocx/live/send?tab=${tab}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(messages.map((message) => ({ channel: "/boxes", message }))) });
}

/** A box checked, or unchecked, as the page says it. */
export const box = (index, on = true) => ({ Set: { index, on } });
