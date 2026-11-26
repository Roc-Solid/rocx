// What the quiz's tests share: the app built as a deploy builds it (rocx build, the browser's wasm,
// the native server), its server started on a SQLite file of a test's own, and a few helpers to play
// it over HTTP as the pages do: a tab's channel stream (`/rocx/live`) and what a page says on it.
//
// node --test runs test files at once, and two builds of one app would write its Generated/ at the
// same time, so the build takes a lock (a directory only one process can make), and each file
// builds under it in turn: the second finds nothing changed, and is quick.
import { existsSync, mkdirSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, repo, serverBuild, startServer, testSqlite } from "../../../packages/testing/index.mjs";

export const dir = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Why these tests can't run here, or false. */
export const skip = await (async () => {
	const { nativeTarget, roc } = await serverBuild();
	try {
		roc();
	} catch {
		return "no roc (run `just setup`, or set ROC)";
	}
	if (!existsSync(join(repo, "server", "platform", "targets", nativeTarget(), "libhost.a"))) return "the server's host isn't built (`just test` builds it)";
	if (!existsSync(join(repo, "web", "platform", "targets", "wasm32", "host.wasm"))) return "the browser's host isn't built (`just test` builds it)";
	return false;
})();

const wait = (ms) => new Promise((done) => setTimeout(done, ms));

/** The app, built: `{ server, statics }`, the app's own static files (styles, sounds) among them. */
export async function built() {
	const out = join(dir, "build", "test");
	const lock = join(dir, "build", "test.lock");
	mkdirSync(dirname(lock), { recursive: true });
	for (let tries = 0; ; tries++) {
		try {
			mkdirSync(lock);
			break;
		} catch (error) {
			if (error.code !== "EEXIST" || tries > 3000) throw error;
			// A lock older than a build could take is a run that died holding it.
			if (Date.now() - statSync(lock, { throwIfNoEntry: false })?.mtimeMs > 10 * 60_000) rmSync(lock, { recursive: true, force: true });
			await wait(100);
		}
	}
	try {
		const { server, statics } = await buildForTests(dir, { out });
		return { server, statics: [...statics, join(dir, "static")] };
	} finally {
		rmSync(lock, { recursive: true, force: true });
	}
}

/**
 * The app's server on a SQLite file of its own, a question open `questionMs` and its answer shown
 * `revealMs` (`QUIZ_QUESTION_MS`, `QUIZ_REVEAL_MS`): `{ app, db, stop() }`.
 */
export async function started({ questionMs = 4000, revealMs = 300, flags = [] } = {}) {
	const { server, statics } = await built();
	const db = testSqlite();
	const app = await startServer(server, { statics, database: db.url, flags, env: { QUIZ_QUESTION_MS: String(questionMs), QUIZ_REVEAL_MS: String(revealMs) } });
	return {
		app,
		db,
		async stop() {
			await app.stop();
			await db.drop();
		},
	};
}

/**
 * A tab following room `code` as `client` (its cookies): the channel's stream, as the runtime's hub
 * opens it. `next(match)` waits for the next view (the parsed message) that `match` says yes to,
 * passing over the others; `close()` hangs up, as a tab that closes does.
 */
export async function follow(client, code, tab) {
	const events = await client.events(`/rocx/live?tab=${tab}&c=${encodeURIComponent(`/api/rooms/${code}`)}`);
	return {
		tab,
		async next(match = () => true, { ms = 15000 } = {}) {
			const deadline = Date.now() + ms;
			for (;;) {
				const left = deadline - Date.now();
				if (left <= 0) throw new Error(`room ${code}: no view came that matched within ${ms} ms`);
				const event = await Promise.race([events.next(), wait(left).then(() => "late")]);
				if (event === "late") continue;
				if (!event) throw new Error(`room ${code}: the stream ended`);
				if (event.event !== "message") continue;
				const view = JSON.parse(event.data.split("\n").slice(1).join("\n"));
				if (match(view)) return view;
			}
		},
		close: () => events.close(),
	};
}

/** Says `message` on room `code`'s channel from `tab`, as a page's `Endpoint.say!` does: the answer. */
export function say(client, code, tab, message) {
	return client.request(`/rocx/live/send?tab=${tab}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify([{ channel: `/api/rooms/${code}`, message }]) });
}

/** The stage a view is at: "Lobby", "Asking", "Revealing", "Finished" or "Vacant". */
export const stage = (view) => (typeof view.stage === "string" ? view.stage : Object.keys(view.stage)[0]);

/** A host's new room for the set called `title`: its code. */
export async function openRoom(host, title) {
	const sets = await host.read("/api/host");
	const set = sets.find((each) => each.title === title);
	if (!set) throw new Error(`no set called ${title}: ${JSON.stringify(sets.map((each) => each.title))}`);
	await host.get("/host");
	const opened = await host.post("/api/rooms", { set: String(set.id) });
	if (opened.status !== 303) throw new Error(`POST /api/rooms: ${opened.status} ${opened.text}`);
	return opened.location.split("/").pop();
}
