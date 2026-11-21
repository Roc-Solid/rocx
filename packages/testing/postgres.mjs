// Postgres for tests, with no dependencies: a database of a test's own (made, then dropped), its
// rows read as objects, and the platform's job queue run to quiet. A client of a few lines over
// Node's sockets: the simple query protocol, and SCRAM-SHA-256, MD5 or a password in the clear.
//
//   const db = await testDatabase();                 // DATABASE_URL, a fresh database in it
//   const app = await startServer(server, { database: db.url });
//   await db.sql`insert into notes (body) values (${"hi"})`;
//   const ran = await db.settleJobs();               // every job due run, and what they queued: those
//   after(() => db.drop());
import { createHash, createHmac, pbkdf2Sync, randomBytes } from "node:crypto";
import { connect as connectSocket } from "node:net";

/** A value as a literal in SQL: a string quoted (its quotes doubled), a number as it is, null as NULL. */
export function literal(value) {
	if (value === null || value === undefined) return "NULL";
	if (typeof value === "number") {
		if (!Number.isFinite(value)) throw new Error(`${value} can't be written in SQL`);
		return String(value);
	}
	if (typeof value === "bigint") return String(value);
	if (typeof value === "boolean") return value ? "TRUE" : "FALSE";
	if (value instanceof Date) return literal(value.toISOString());
	if (Buffer.isBuffer(value) || value instanceof Uint8Array) return `'\\x${Buffer.from(value).toString("hex")}'::bytea`;
	if (typeof value === "object") return literal(JSON.stringify(value));
	const text = String(value);
	if (text.includes("\0")) throw new Error("a string with a NUL in it can't be written in SQL");
	return `'${text.replaceAll("'", "''")}'`;
}

/** A name in SQL (a table's, a database's), quoted. */
export function ident(name) {
	return `"${String(name).replaceAll('"', '""')}"`;
}

/** The text of a tagged template, each value in it written as a literal. */
export function sqlText(strings, values) {
	return strings.reduce((out, part, i) => out + part + (i < values.length ? literal(values[i]) : ""), "");
}

/** Reads a column's text as its type says: numbers, booleans and JSON as JavaScript's; the rest as text. */
function value(text, type) {
	if (text === null) return null;
	switch (type) {
		case 16:
			return text === "t";
		case 20: {
			const big = BigInt(text);
			return big >= BigInt(Number.MIN_SAFE_INTEGER) && big <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(big) : big;
		}
		case 21:
		case 23:
		case 26:
		case 700:
		case 701:
		case 1700:
			return Number(text);
		case 114:
		case 3802:
			return JSON.parse(text);
		default:
			return text;
	}
}

/** One connection to Postgres. */
export class Connection {
	#socket;
	#buffer = Buffer.alloc(0);
	#messages = [];
	#waiting = null;
	#closed = null;
	#queue = Promise.resolve();

	constructor(socket, url) {
		this.#socket = socket;
		/** The URL it was opened with. */
		this.url = url;
		socket.on("data", (chunk) => {
			this.#buffer = Buffer.concat([this.#buffer, chunk]);
			while (this.#buffer.length >= 5) {
				const length = this.#buffer.readInt32BE(1);
				if (this.#buffer.length < 1 + length) break;
				this.#messages.push({ type: String.fromCharCode(this.#buffer[0]), body: this.#buffer.subarray(5, 1 + length) });
				this.#buffer = this.#buffer.subarray(1 + length);
			}
			this.#wake();
		});
		const end = (why) => {
			this.#closed ??= why;
			this.#wake();
		};
		socket.on("error", (error) => end(error));
		socket.on("close", () => end(new Error("the connection to Postgres closed")));
	}

	#wake() {
		const waiting = this.#waiting;
		this.#waiting = null;
		waiting?.();
	}

	async #next() {
		while (!this.#messages.length) {
			if (this.#closed) throw this.#closed;
			await new Promise((resolve) => (this.#waiting = resolve));
		}
		return this.#messages.shift();
	}

	#send(type, body) {
		const head = Buffer.alloc(type ? 5 : 4);
		if (type) head.write(type, 0, "latin1");
		head.writeInt32BE(body.length + 4, type ? 1 : 0);
		this.#socket.write(Buffer.concat([head, body]));
	}

	/** Signs in as `user` with `password` to `database`. */
	async start(user, password, database) {
		const params = Buffer.from(`user\0${user}\0database\0${database}\0client_encoding\0UTF8\0\0`);
		const version = Buffer.alloc(4);
		version.writeInt32BE(196608);
		this.#send("", Buffer.concat([version, params]));
		let scram = null;
		for (;;) {
			const { type, body } = await this.#next();
			if (type === "E") throw new Error(`Postgres refused: ${errorText(body)}`);
			if (type === "Z") return this;
			if (type !== "R") continue;
			const code = body.readInt32BE(0);
			if (code === 3) this.#send("p", Buffer.from(`${password}\0`));
			else if (code === 5) {
				const inner = createHash("md5").update(password + user).digest("hex");
				this.#send("p", Buffer.from(`md5${createHash("md5").update(Buffer.concat([Buffer.from(inner), body.subarray(4, 8)])).digest("hex")}\0`));
			} else if (code === 10) {
				const mechanisms = body.subarray(4).toString().split("\0");
				if (!mechanisms.includes("SCRAM-SHA-256")) throw new Error(`Postgres wants ${mechanisms.filter(Boolean).join(", ")}; this client signs in with SCRAM-SHA-256`);
				scram = { nonce: randomBytes(18).toString("base64") };
				scram.first = `n=,r=${scram.nonce}`;
				const first = Buffer.from(`n,,${scram.first}`);
				const length = Buffer.alloc(4);
				length.writeInt32BE(first.length);
				this.#send("p", Buffer.concat([Buffer.from("SCRAM-SHA-256\0"), length, first]));
			} else if (code === 11) {
				const server = body.subarray(4).toString();
				const fields = Object.fromEntries(server.split(",").map((part) => [part[0], part.slice(2)]));
				if (!fields.r.startsWith(scram.nonce)) throw new Error("Postgres answered SCRAM with another nonce");
				const salted = pbkdf2Sync(password.normalize("NFKC"), Buffer.from(fields.s, "base64"), Number(fields.i), 32, "sha256");
				const clientKey = createHmac("sha256", salted).update("Client Key").digest();
				const stored = createHash("sha256").update(clientKey).digest();
				const withoutProof = `c=biws,r=${fields.r}`;
				const said = `${scram.first},${server},${withoutProof}`;
				const signature = createHmac("sha256", stored).update(said).digest();
				const proof = Buffer.from(clientKey.map((byte, i) => byte ^ signature[i]));
				scram.server = createHmac("sha256", createHmac("sha256", salted).update("Server Key").digest()).update(said).digest("base64");
				this.#send("p", Buffer.from(`${withoutProof},p=${proof.toString("base64")}`));
			} else if (code === 12) {
				if (body.subarray(4).toString() !== `v=${scram.server}`) throw new Error("Postgres's SCRAM signature isn't the one its password makes");
			} else if (code !== 0) throw new Error(`Postgres asked for a way of signing in this client doesn't have (${code})`);
		}
	}

	/**
	 * Runs `text` (one statement or several, `;` between): the rows of the last that returned any,
	 * each an object by column name, its values as their types say (numbers, booleans, JSON; the
	 * rest as text). Queries on one connection run one at a time.
	 */
	query(text) {
		const run = this.#queue.then(() => this.#query(text));
		this.#queue = run.catch(() => {});
		return run;
	}

	async #query(text) {
		this.#send("Q", Buffer.from(`${text}\0`));
		let columns = [];
		let rows = [];
		let result = [];
		let problem = null;
		for (;;) {
			const { type, body } = await this.#next();
			if (type === "T") {
				columns = [];
				rows = [];
				let at = 2;
				for (let i = 0; i < body.readInt16BE(0); i++) {
					const end = body.indexOf(0, at);
					columns.push({ name: body.toString("utf8", at, end), type: body.readInt32BE(end + 7) });
					at = end + 19;
				}
			} else if (type === "D") {
				const row = {};
				let at = 2;
				for (let i = 0; i < body.readInt16BE(0); i++) {
					const length = body.readInt32BE(at);
					at += 4;
					row[columns[i].name] = value(length === -1 ? null : body.toString("utf8", at, at + length), columns[i].type);
					if (length > 0) at += length;
				}
				rows.push(row);
			} else if (type === "C") {
				if (columns.length) result = rows;
				columns = [];
			} else if (type === "E") {
				problem = new Error(`${errorText(body)}\n  in: ${text}`);
			} else if (type === "Z") {
				if (problem) throw problem;
				return result;
			}
		}
	}

	/** A query written as a tagged template, each value in it a literal: db.sql`… where id = ${id}`. */
	sql(strings, ...values) {
		return this.query(sqlText(strings, values));
	}

	/** Ends the connection. */
	async close() {
		if (this.#closed) return;
		this.#send("X", Buffer.alloc(0));
		this.#socket.end();
		await new Promise((resolve) => (this.#socket.closed ? resolve() : this.#socket.once("close", resolve)));
	}
}

function errorText(body) {
	const fields = {};
	for (let at = 0; at < body.length && body[at] !== 0; ) {
		const end = body.indexOf(0, at + 1);
		fields[String.fromCharCode(body[at])] = body.toString("utf8", at + 1, end);
		at = end + 1;
	}
	return [fields.M, fields.D && `(${fields.D})`, fields.C && `[${fields.C}]`].filter(Boolean).join(" ");
}

/** A connection to the database at `url` (`postgres://user:password@host:port/database`). */
export async function connect(url) {
	const parsed = new URL(url);
	const user = decodeURIComponent(parsed.username) || "postgres";
	const password = decodeURIComponent(parsed.password);
	const database = decodeURIComponent(parsed.pathname.slice(1)) || user;
	const socket = connectSocket(Number(parsed.port || 5432), parsed.hostname);
	await new Promise((resolve, reject) => {
		socket.once("connect", resolve);
		socket.once("error", reject);
	});
	return new Database(socket, url).start(user, password, database);
}

/**
 * A database, with the platform's job queue (`rocx_jobs`, made by the server's migrations) at hand:
 * `jobs`, `enqueue`, `settleJobs`.
 */
export class Database extends Connection {
	/** The jobs in the queue (`rocx_jobs`), oldest first; `kind` and `state` narrow them. */
	jobs({ kind, state } = {}) {
		const where = [kind !== undefined && `kind = ${literal(kind)}`, state !== undefined && `state = ${literal(state)}`].filter(Boolean);
		return this.query(`select id, kind, input, state, attempts, max_attempts, unique_key as key, last_error from rocx_jobs${where.length ? ` where ${where.join(" and ")}` : ""} order by id`);
	}

	/**
	 * Queues a job of `kind` with `input` (as JSON, as `Job.enqueue!` writes it) and wakes the
	 * server's workers, as `Job.enqueue!` does: what a cron does at its time (`Cron.every(schedule,
	 * kind, input)`), done now. Its id.
	 */
	async enqueue(kind, input = {}, { key = null, attempts = 5 } = {}) {
		const [row] = await this.query(
			`with queued as (insert into rocx_jobs (kind, input, max_attempts, unique_key) values (${literal(kind)}, ${literal(JSON.stringify(input))}, ${literal(attempts)}, ${literal(key)}) returning id) select id, pg_notify('rocx_jobs', id::text) from queued`,
		);
		return row.id;
	}

	/** When the last `settleJobs` found the queue quiet, by the database's clock. */
	#settled = null;

	/**
	 * Waits until the server has run every job that is due, and the ones they queued, and returns
	 * the jobs run since the last `settleJobs` (or ever, the first time), as they ended: `state`
	 * done, failed, or queued again for a retry. With `later`, jobs queued for later and retries are
	 * made due too, again until none is left: the queue run to its end. A job of a kind no worker
	 * runs keeps it from settling: it times out after `ms`, saying which.
	 */
	async settleJobs({ later = false, ms = 10_000 } = {}) {
		const since = this.#settled;
		const end = Date.now() + ms;
		for (;;) {
			if (later) await this.query("update rocx_jobs set run_at = now() where state = 'queued' and run_at > now()");
			await this.query("select pg_notify('rocx_jobs', '')");
			const [{ waiting, at }] = await this.query(
				`select count(*)::int as waiting, clock_timestamp()::text as at from rocx_jobs where state = 'running' or (state = 'queued' and run_at <= now())${later ? " or state = 'queued'" : ""}`,
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
		return this.query(`select id, kind, input, state, attempts, last_error from rocx_jobs where locked_at is not null${since ? ` and locked_at >= ${literal(since)}::timestamptz` : ""} order by id`);
	}
}

/**
 * A database of the test's own: made in the Postgres at `url` (`DATABASE_URL` by default) with a
 * name no other test has, connected to, and `drop()`ped when the test is done (connections to it
 * ended). `url` is its own URL, for the server under test (`--database-url`). With `template`, it
 * starts as a copy of that database: migrate one once, then copy it for each test.
 */
export async function testDatabase(url = process.env.DATABASE_URL, { template, prefix = "rocx_test" } = {}) {
	if (!url) throw new Error("no DATABASE_URL: a Postgres the tests may make databases in (`just db` starts one)");
	const admin = await connect(url);
	const name = `${prefix}_${Date.now().toString(36)}_${randomBytes(4).toString("hex")}`;
	await admin.query(`create database ${ident(name)}${template ? ` template ${ident(template)}` : ""}`);
	const own = new URL(url);
	own.pathname = `/${encodeURIComponent(name)}`;
	const db = await connect(own.toString());
	db.name = name;
	db.drop = async () => {
		await db.close();
		await admin.query(`drop database if exists ${ident(name)} with (force)`);
		await admin.close();
	};
	return db;
}
