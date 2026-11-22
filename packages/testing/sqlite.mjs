// SQLite for tests (D-045), as postgres.mjs is for Postgres: a database file of a test's own, in a
// directory of its own (made, then removed), for a server whose program says `database: Sqlite(…)`,
// and read and written beside it with Node's own SQLite (`node:sqlite`), its rows as objects. The
// server makes the file (its migrations) when it starts; the tests' connection opens it when first
// used, and waits its turn to write as the server's connections do.
//
//   const db = testSqlite();
//   const app = await startServer(server, { database: db.url });   // --database-url sqlite:<file>
//   await db.sql`update foods set kcal = 1000 where id = ${id}`;
//   after(() => db.drop());
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/** A value as `node:sqlite` binds it: a boolean as 1 or 0, a date as ISO text, an object as JSON. */
function bound(value) {
	if (value === undefined) return null;
	if (typeof value === "boolean") return value ? 1 : 0;
	if (value instanceof Date) return value.toISOString();
	if (value !== null && typeof value === "object" && !(value instanceof Uint8Array)) return JSON.stringify(value);
	return value;
}

/** A database file of a test's own, and a connection to it. */
export class SqliteDatabase {
	#connection = null;

	constructor(dir) {
		/** The directory it is in, removed by `drop()`. */
		this.dir = dir;
		/** The file. */
		this.path = join(dir, "test.db");
		/** Its URL, for the server under test (`--database-url`). */
		this.url = `sqlite:${this.path}`;
	}

	async #open() {
		if (!this.#connection) {
			const { DatabaseSync } = await import("node:sqlite");
			this.#connection = new DatabaseSync(this.path, { timeout: 10_000 });
		}
		return this.#connection;
	}

	/** Runs `sql` with `params` (`?` in it): the rows it reads, as objects (none for a write). */
	async query(sql, params = []) {
		const connection = await this.#open();
		return connection
			.prepare(sql)
			.all(...params.map(bound))
			.map((row) => ({ ...row }));
	}

	/** `query` as a tagged template: each `${value}` a parameter. */
	sql(strings, ...values) {
		return this.query(strings.join("?"), values);
	}

	/** Closes the connection (the file stays). */
	close() {
		this.#connection?.close();
		this.#connection = null;
	}

	/** Closes the connection and removes the file, with its directory. */
	async drop() {
		this.close();
		rmSync(this.dir, { recursive: true, force: true });
	}
}

/** A database file of the test's own, in a new directory under the system's temporary one. */
export function testSqlite({ prefix = "rocx-test-" } = {}) {
	return new SqliteDatabase(mkdtempSync(join(tmpdir(), prefix)));
}
