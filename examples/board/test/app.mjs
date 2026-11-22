// What the board's test files share: the app, built once (node --test runs the files at once, and
// two builds of one app at once would write the same files), and a server of a test file's own,
// on a database of its own, with people to be.
import { mkdirSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer, testDatabase } from "../../../packages/testing/index.mjs";

export const dir = join(dirname(fileURLToPath(import.meta.url)), "..");

/** Why the tests that need Postgres are skipped, or false. */
export const noDatabase = !process.env.DATABASE_URL && "needs DATABASE_URL (a Postgres, `just db`)";

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

/** The app's server, on a database of its own, migrated and seeded as it starts. */
export async function started({ env = {} } = {}) {
	const { server, statics } = await built();
	const db = await testDatabase();
	const app = await startServer(server, { statics, database: db.url, env });
	return {
		app,
		db,
		async stop() {
			await app.stop();
			await db.drop();
		},
	};
}

/** A client who is someone: their cookie set as joining would set it (`/join`). */
export async function as(app, db, name) {
	const [person] = await db.sql`select id::text as id from people where name = ${name}`;
	const client = app.client();
	client.cookies.set("acme_board_person", person.id);
	return client;
}

/** The ids of the seeded board's cards and columns, by title and name. */
export async function ids(db) {
	const cards = Object.fromEntries((await db.sql`select title, id::text as id from cards`).map((row) => [row.title, row.id]));
	const columns = Object.fromEntries((await db.sql`select name, id::text as id from columns`).map((row) => [row.name, row.id]));
	return { cards, columns };
}

/** A column's card titles, top to bottom, as the board shows them. */
export function titles(board, column) {
	return board.cards
		.filter((card) => card.column === column && !card.archived)
		.sort((a, b) => (a.rank < b.rank ? -1 : a.rank > b.rank ? 1 : Number(a.id) - Number(b.id)))
		.map((card) => card.title);
}
