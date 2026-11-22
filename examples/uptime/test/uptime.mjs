// What the app's tests share: the app built one test file at a time (rocx build writes
// Generated/ in the app's own folder, so two files building at once would race: a lock directory
// takes turns), its server started on a database of its own with its static files and an admin
// password, and a fake target: an HTTP server that answers 200 or 500 as a test says, and doubles
// as an OpenTelemetry collector (`POST /v1/metrics`), so checks and metrics need no network.
import { createServer } from "node:http";
import { mkdirSync, rmSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { buildForTests, startServer, testDatabase } from "../../../packages/testing/index.mjs";

/** The app's folder. */
export const dir = join(dirname(fileURLToPath(import.meta.url)), "..");

/** The admin password the tests start the server with. */
export const password = "correct horse battery staple";

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

/**
 * A fake target: `GET /…` answers `target.status` (200 to start with), and `POST /v1/metrics` keeps
 * what an OpenTelemetry exporter sends, in `target.metrics` (each body, parsed). `url`, `close()`.
 */
export async function fakeTarget() {
	const target = { status: 200, asked: 0, metrics: [], url: "", close: () => {} };
	const server = createServer((request, response) => {
		let body = "";
		request.on("data", (chunk) => (body += chunk));
		request.on("end", () => {
			if (request.method === "POST" && request.url === "/v1/metrics") {
				target.metrics.push(JSON.parse(body));
				response.writeHead(200, { "content-type": "application/json" }).end("{}");
				return;
			}
			target.asked += 1;
			response.writeHead(target.status, { "content-type": "text/plain" }).end(target.status === 200 ? "fine" : "broken");
		});
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	target.url = `http://127.0.0.1:${server.address().port}`;
	target.close = () => new Promise((resolve) => server.close(resolve));
	return target;
}

/**
 * The app on a database of its own (`testDatabase`, at `DATABASE_URL`), started with the admin
 * password and its metrics sent to `target` every second. The seeded example.com monitor is paused
 * at once (its first check is a minute after the first start), so no test asks the internet. The
 * app's checks of itself ask where the server says it listens (`Env.public_url!`).
 * `{ app, db, stop() }`.
 */
export async function start(built, target) {
	const db = await testDatabase();
	const app = await startServer(built.server, {
		statics: [...built.statics, join(dir, "static")],
		database: db.url,
		env: { ADMIN_PASSWORD: password, OTEL_EXPORTER_OTLP_ENDPOINT: target.url, OTEL_METRIC_EXPORT_INTERVAL: "1000", OTEL_SERVICE_NAME: "acme-status" },
	});
	await db.sql`update monitors set paused = true where url like 'https://%'`;
	return {
		app,
		db,
		async stop() {
			await app.stop();
			await db.drop();
		},
	};
}

/** A monitor of `target` (`path` on it), checked only when a test queues its check. Its id. */
export async function watch(db, target, { name, path = "/", threshold = 3 }) {
	const [row] = await db.sql`insert into monitors (name, url, interval_s, group_name, threshold, next_check_at) values (${name}, ${`${target.url}${path}`}, 3600, ${"Tests"}, ${threshold}, now() + interval '1 day') returning id`;
	return Number(row.id);
}

/** Checks the monitor `id` now: its job queued, as the sweep queues it, and run. How the jobs ended. */
export async function check(db, id) {
	await db.enqueue("check", { monitor: id });
	return db.settleJobs();
}

/** Someone signed in to the admin: a client with the session's cookie. */
export async function admin(app) {
	const person = app.client();
	await person.get("/admin/sign-in");
	const signed = await person.post("/admin/sign-in", { password, next: "/admin" });
	if (signed.status !== 303 || signed.location !== "/admin") throw new Error(`signing in: ${signed.status} ${signed.location}`);
	return person;
}
