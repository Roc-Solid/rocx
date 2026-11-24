// What the notes tests share: the app, built once (node --test runs the files at once, and two
// builds of one app at once would write the same files); a server of a test file's own, on a
// SQLite file of its own (no database server is needed); and the ways in: signing in through the
// mailed link (packages/auth's plugin), as a person does, and personal access tokens, as an AI
// client uses them.
import assert from "node:assert/strict";
import { mkdirSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, links, startServer, testSqlite } from "../../../packages/testing/index.mjs";

export const dir = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Why the tests that need the database are skipped, or false: never, as it is a SQLite file of their own. */
export const noDatabase = false;

/** The app, built: `{ server, statics }`. One test file builds it while the others wait. */
export async function built() {
	const lock = join(dir, "build", ".building");
	mkdirSync(join(dir, "build"), { recursive: true });
	for (;;) {
		try {
			mkdirSync(lock);
			break;
		} catch {
			// A lock left by a run that died is let go of after five minutes.
			if (Date.now() - statSync(lock, { throwIfNoEntry: false })?.mtimeMs > 300_000) rmSync(lock, { recursive: true, force: true });
			await new Promise((resolve) => setTimeout(resolve, 250));
		}
	}
	try {
		return await buildForTests(dir);
	} finally {
		rmSync(lock, { recursive: true, force: true });
	}
}

/** The app's server, on a SQLite file of its own, migrated and seeded as it starts. */
export async function started({ env = {} } = {}) {
	const { server, statics } = await built();
	const db = testSqlite();
	const app = await startServer(server, { statics, database: db.url, env: { PUBLIC_URL: "http://notes.example", ...env } });
	return {
		app,
		db,
		async stop() {
			await app.stop();
			await db.drop();
		},
	};
}

/** The sign-in link the app last mailed `email`, after the first `after` messages: its path. */
export async function mailedLink(app, email, after = 0) {
	const mail = await app.waitForMail({ to: email, subject: "Your sign-in link for Notes" }, { after });
	const found = links(mail);
	assert.equal(found.length, 1, JSON.stringify(found));
	const url = new URL(found[0]);
	assert.equal(url.origin, "http://notes.example", "a link goes to the public URL, never to a Host a request names");
	return url.pathname + url.search;
}

/** The session cookie's name (packages/auth's, as main.roc names it). */
export const sessionCookie = "notes_session";

/** The token in a mailed link's path. */
export function tokenOf(link) {
	return new URL(link, "http://x").searchParams.get("token");
}

/**
 * A client signed in as `email`, the way a person signs in: the form, the mail, the link, the
 * button (a plain form, posting the token to packages/auth's /auth/link).
 */
export async function signIn(app, email) {
	const person = app.client();
	const before = (await app.mail()).length;
	await person.get("/sign-in");
	assert.equal((await person.post("/sign-in", { email, then: "/" })).status, 303);
	const link = await mailedLink(app, email, before);
	assert.equal((await person.get(link)).status, 200);
	const used = await person.post("/auth/link", { token: tokenOf(link) });
	assert.equal(used.status, 303, used.text);
	assert.ok(person.cookies.has(sessionCookie));
	return person;
}

/** A personal access token `person` makes in Settings (`access`: `read` or `write`, the box "It may
 * write too" ticked or not): the token. */
export async function makeToken(person, name, access = "write") {
	const made = await person.submit("/settings", access === "write" ? { name, write: "on" } : { name });
	assert.equal(made.status, 200, made.text);
	return made.json().token;
}

/** A client that sends `token` as a bearer token, as an AI client or a script does. */
export function bearer(app, token) {
	return app.client({ headers: { authorization: `Bearer ${token}` } });
}

/** The ids of someone's notes, by title. */
export async function noteIds(db, email) {
	const rows = await db.sql`select n.title, cast(n.id as text) as id from notes n join people p on p.id = n.person_id where p.email = ${email}`;
	return Object.fromEntries(rows.map((row) => [row.title, row.id]));
}
