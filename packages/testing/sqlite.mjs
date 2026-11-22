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
//
// The job queue (packages/jobs) as postgres.mjs has it: `jobs`, `enqueue` and `settleJobs`. A write
// from this process can't wake the server's workers (SQLite tells only its own process), so these
// ask the server to (`POST /__rocx/jobs/wake`, the jobs plugin's under `--debug`, which
// `startServer` passes): give startServer the database itself, which it then knows the server of.
//
//   const app = await startServer(server, { database: db });
//   await db.enqueue("nightly", {});
//   const ran = await db.settleJobs();
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

/** Now, in milliseconds since the epoch, by SQLite's clock: what the queue's times are on SQLite. */
const now = "cast(unixepoch('subsec') * 1000 as integer)";

/** A database file of a test's own, and a connection to it. */
export class SqliteDatabase {
	#connection = null;

	/** The server on this file, which `startServer(…, { database: db })` sets: the one `enqueue` and `settleJobs` wake. */
	server = null;

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

	/** The jobs in the queue (`rocx_jobs`), oldest first; `kind` and `state` narrow them. */
	jobs({ kind, state } = {}) {
		const where = [kind !== undefined && "kind = ?", state !== undefined && "state = ?"].filter(Boolean);
		const params = [kind, state].filter((value) => value !== undefined);
		return this.query(`select id, kind, input, state, attempts, max_attempts, unique_key as key, last_error from rocx_jobs${where.length ? ` where ${where.join(" and ")}` : ""} order by id`, params);
	}

	/**
	 * Queues a job of `kind` with `input` (as JSON, as `Job.enqueue!` writes it) and wakes the
	 * server's workers: what a cron does at its time, done now. Its id.
	 */
	async enqueue(kind, input = {}, { key = null, attempts = 5 } = {}) {
		const [row] = await this.query("insert into rocx_jobs (kind, input, max_attempts, unique_key) values (?, ?, ?, ?) returning id", [kind, JSON.stringify(input), attempts, key]);
		await this.#wake();
		return row.id;
	}

	/** When the last `settleJobs` found the queue quiet, in milliseconds by SQLite's clock. */
	#settled = null;

	/**
	 * Waits until the server has run every job that is due, and the ones they queued, and returns
	 * the jobs run since the last `settleJobs` (or ever, the first time), as they ended, as
	 * postgres.mjs's does; `later` and `ms` as there.
	 */
	async settleJobs({ later = false, ms = 10_000 } = {}) {
		const since = this.#settled;
		const end = Date.now() + ms;
		for (;;) {
			if (later) await this.query(`update rocx_jobs set run_at = ${now} where state = 'queued' and run_at > ${now}`);
			await this.#wake();
			const [{ waiting, at }] = await this.query(
				`select count(*) as waiting, ${now} as at from rocx_jobs where state = 'running' or (state = 'queued' and run_at <= ${now})${later ? " or state = 'queued'" : ""}`,
			);
			if (waiting === 0) {
				this.#settled = at;
				break;
			}
			if (Date.now() > end) {
				const left = await this.query("select id, kind, state, attempts from rocx_jobs where state in ('queued', 'running') order by id");
				throw new Error(`the jobs didn't settle in ${ms} ms (is each kind in the app's \`jobs\`?): ${JSON.stringify(left)}`);
			}
			await new Promise((resolve) => setTimeout(resolve, 20));
		}
		return this.query(`select id, kind, input, state, attempts, last_error from rocx_jobs where locked_at is not null${since !== null ? " and locked_at >= ?" : ""} order by id`, since !== null ? [since] : []);
	}

	/** Asks the server to wake its job workers. */
	async #wake() {
		if (!this.server) throw new Error("the server's job workers can't hear this process's writes on SQLite: give startServer the database itself (startServer(server, { database: db })), so that it can be asked to wake them");
		const answer = await fetch(`${this.server.url}/__rocx/jobs/wake`, { method: "POST" });
		if (answer.status !== 204) throw new Error(`POST /__rocx/jobs/wake: ${answer.status} ${await answer.text()} (the jobs plugin answers it under --debug or --dev)`);
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
