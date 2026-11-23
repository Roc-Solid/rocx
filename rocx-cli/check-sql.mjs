// `rocx check --sql [dir] [--engine sqlite|turso] [--verbose] [-- server options…]` (D-058): the
// app's SQL checked by its own database engine. rocx finds each `Db.all!`/`Db.run!` whose SQL is a
// string literal at the call (rocx-cli/Sql.roc); the app's server, built as `rocx dev` builds it,
// describes them (`--describe-sql`) on a scratch database it builds from the program's
// migrations: a SQLite or Turso file it removes after, or a Postgres database it makes on the
// server `--database-url` (DATABASE_URL) names and drops after, unless `--sql-database URL`
// (ROCX_SQL_DATABASE) names one it may migrate. What follows `--` goes to the server as it is.
// Exits 1 when the engine refuses a statement or a call's parameters don't match it.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildHost, nativeTarget, roc, rocxBinary } from "../server/build.mjs";
import { call } from "./rocx.mjs";

const USAGE = "usage: rocx check --sql [dir] [--engine sqlite|turso] [--verbose] [-- server options…]";

/** Runs `command`; throws, with what it printed, saying `what` failed, unless it exits 0 (then it
 * says nothing: the check's report is what is printed). */
function step(command, args, what) {
	const ran = spawnSync(command, args, { encoding: "utf8", maxBuffer: 1 << 28 });
	if (ran.error) throw new Error(`${what}: ${ran.error.message}`);
	if (ran.status !== 0) throw new Error(`${`${ran.stdout ?? ""}${ran.stderr ?? ""}`.trimEnd()}\n${what} failed`);
}

/** The server of the app at `app` (its main.roc), built with Roc's dev backend into `output`, as
 * `rocx dev` builds it: rocx build first, then the host (when it changed), then the app. */
export function buildServer(app, output) {
	step(rocxBinary(), ["build", app], "rocx build");
	buildHost();
	mkdirSync(join(output, ".."), { recursive: true });
	step(rocxBinary(), ["check", "--", roc(), "build", `--target=${nativeTarget()}`, "--opt=dev", `--output=${output}`, join(app, "main.roc")], "the server's build");
}

/** The app at `app` checked with its server `server` (built): `{ lines, ok }`, what to print and
 * whether nothing is wrong. `engine` runs a SQLite app's check on Turso, or a Turso app's on
 * SQLite; `flags` go to the server. Files are named as `cwd` sees them. */
export function checkSql(app, server, { engine = null, verbose = false, flags = [], cwd = process.cwd() } = {}) {
	const { found, statements } = call("sqlScan", relative(cwd, app) || ".");
	if (statements.length === 0) return call("sqlReport", found, { statements: [] }, { verbose });
	const dir = join(app, "build", "sql");
	mkdirSync(dir, { recursive: true });
	const list = join(dir, "statements.json");
	writeFileSync(list, JSON.stringify(statements));
	// The URL's scheme picks the engine; the check makes its own file, wherever this one says.
	const engineFlags = engine ? ["--database-url", `${engine}:check.db`] : [];
	const env = { ...process.env, ROCX_LOG: "json" };
	const ran = spawnSync(server, ["--describe-sql", list, ...engineFlags, ...flags], { cwd, env, encoding: "utf8", maxBuffer: 1 << 28 });
	if (ran.error) throw ran.error;
	if (ran.status !== 0) {
		return { lines: [...errorsOf(ran.stderr), "rocx check --sql: the app's server couldn't describe its statements"], ok: false };
	}
	const described = JSON.parse(ran.stdout);
	writeFileSync(join(dir, "described.json"), JSON.stringify(described, null, 1));
	return call("sqlReport", found, described, { verbose });
}

/** The errors in a server's log (JSON lines), each as a line: its message, then why. */
function errorsOf(log) {
	return log
		.split("\n")
		.filter((line) => line.trim())
		.map((line) => {
			try {
				const event = JSON.parse(line);
				return event.level === "error" ? `${event.msg}${event.error ? `: ${event.error}` : ""}` : null;
			} catch {
				return line;
			}
		})
		.filter((line) => line !== null);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	const args = process.argv.slice(2);
	const dash = args.indexOf("--");
	const own = dash === -1 ? args : args.slice(0, dash);
	const flags = dash === -1 ? [] : args.slice(dash + 1);
	let engine = null;
	let verbose = false;
	const dirs = [];
	for (let i = 0; i < own.length; i++) {
		if (own[i] === "--engine" && ["sqlite", "turso"].includes(own[i + 1])) engine = own[++i];
		else if (own[i] === "--verbose") verbose = true;
		else if (own[i].startsWith("-")) {
			console.error(USAGE);
			process.exit(2);
		} else dirs.push(own[i]);
	}
	if (dirs.length > 1) {
		console.error(USAGE);
		process.exit(2);
	}
	const given = resolve(dirs[0] ?? ".");
	if (!existsSync(join(given, "main.roc"))) {
		console.error(`rocx check --sql: ${dirs[0] ?? "."} has no main.roc: give the app's directory`);
		process.exit(2);
	}
	const app = realpathSync(given);
	try {
		const server = join(app, "build", "sql", "server");
		// No statement to describe, no server to build.
		if (call("sqlScan", relative(process.cwd(), app) || ".").statements.length > 0) buildServer(app, server);
		const { lines, ok } = checkSql(app, server, { engine, verbose, flags });
		for (const line of lines) console.log(line);
		process.exit(ok ? 0 : 1);
	} catch (error) {
		console.error(`rocx check --sql: ${error.message}`);
		process.exit(1);
	}
}
