// What the pomodoro's tests share: the app built as a deploy builds it (rocx build, the browser's
// wasm, the native server), and its server started on a SQLite file of a test's own.
//
// node --test runs test files at once, and two builds of one app would write its Generated/ at the
// same time, so the build takes a lock (a directory only one process can make), and each file
// builds under it in turn: the second finds nothing changed, and is quick.
import { mkdirSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer, testSqlite } from "../../../packages/testing/index.mjs";

export const dir = join(dirname(fileURLToPath(import.meta.url)), "..");

const wait = (ms) => new Promise((done) => setTimeout(done, ms));

/** The app, built: `{ server, statics }`, the app's own static files (its sound) among them. */
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

/** The app's server on a SQLite file of its own: `{ app, db, stop() }`. */
export async function started() {
	const { server, statics } = await built();
	const db = testSqlite();
	const app = await startServer(server, { statics, database: db.url });
	return {
		app,
		db,
		async stop() {
			await app.stop();
			await db.drop();
		},
	};
}
