// Acme Status over HTTP, as a browser and as other programs ask it, against a database of its own:
// the status page and its JSON, monitors' and incidents' pages, subscribing, the admin's sign-in
// and actions, and, through packages/jobs, a fake target driven up, down and up again: checks
// stored, an incident opened after three failures and closed on recovery, the alert mails, the
// nightly roll-up, and the metrics a collector gets. Needs DATABASE_URL (skipped without it).
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { admin, build, check, fakeTarget, start, watch } from "./uptime.mjs";

const database = Boolean(process.env.DATABASE_URL);
let target;
let running;
let app;
let db;

before(async () => {
	if (!database) return;
	target = await fakeTarget();
	running = await start(await build(), target);
	({ app, db } = running);
});

after(async () => {
	await running?.stop();
	await target?.close();
});

const skip = (t) => (database ? false : (t.skip("needs DATABASE_URL (`just db`)"), true));

/** The monitor called `name` on the status page's JSON, and the JSON. */
async function monitorNamed(name) {
	const overview = await app.client().read("/");
	const monitor = overview.groups.flatMap((group) => group.monitors).find((each) => each.name === name);
	return { overview, monitor };
}

test("the status page: the banner, each monitor by group with its uptime and 90 days, and the past incident", async (t) => {
	if (skip(t)) return;
	const page = await app.client().get("/");
	assert.equal(page.status, 200);
	const { dom } = page;
	assert.match(dom.getByRole("status", { name: "" }).text ?? "", /./);
	dom.getByRole("heading", { level: 1, name: "All systems operational" });
	for (const group of ["Platform", "Websites"]) dom.getByRole("heading", { level: 2, name: group });
	for (const monitor of ["Status page", "Payments API", "example.com"]) dom.getByRole("link", { name: monitor });
	dom.getByRole("heading", { level: 2, name: "Past incidents" });
	dom.getByRole("link", { name: "Payments API is down" });
	assert.equal(dom.getAllByRole("img", { name: /^The last 90 days: / }).length, 3);
	dom.getByLabelText("Get an email when an incident opens or closes");

	// The same as JSON, for programs: the seeded history gives every monitor 90 days.
	const { overview, monitor } = await monitorNamed("Payments API");
	assert.deepEqual(overview.groups.map((group) => group.name), ["Platform", "Websites"]);
	assert.equal(monitor.days.length, 90);
	assert.equal(monitor.trend.length, 24);
	assert.match(monitor.uptime_90d, /^9\d\.\d\d%$/);
	assert.equal(overview.incidents[0].title, "Payments API is down");
	assert.deepEqual(overview.incidents[0].updates.map((update) => update.state), ["resolved", "monitoring", "identified", "investigating"]);
	const paused = (await monitorNamed("example.com")).monitor;
	assert.equal(paused.state, "paused");
});

test("the app's own monitors check /health and /demo/flaky, and the flaky one breaks on purpose", async (t) => {
	if (skip(t)) return;
	assert.deepEqual(await app.client().read("/health"), { ok: true, database: "up" });
	const ids = await db.sql`select id, url from monitors where url like '/%' order by id`;
	for (const { id } of ids) await check(db, Number(id));
	const stored = await db.sql`select m.url, c.up, c.status from checks c join monitors m on m.id = c.monitor_id where m.url like '/%' and c.at > now() - interval '1 minute' order by c.id`;
	assert.ok(stored.some((row) => row.url === "/health" && row.up && row.status === 200), JSON.stringify(stored));

	const person = await admin(app);
	assert.equal((await person.json("/admin/demo", { broken: "yes" })).status, 200);
	const broken = await app.client().request("/demo/flaky");
	assert.equal(broken.status, 503);
	assert.equal((await person.json("/admin/demo", { broken: "no" })).status, 200);
	// About one answer in 250 fails anyway, on purpose: one of three passes.
	const answers = [];
	for (let i = 0; i < 3; i++) answers.push((await app.client().request("/demo/flaky")).status);
	assert.ok(answers.includes(200), JSON.stringify(answers));
});

test("a monitor's page and its JSON; a 404 for one that isn't there", async (t) => {
	if (skip(t)) return;
	const [{ id }] = await db.sql`select id from monitors where url = '/demo/flaky'`;
	const page = await app.client().get(`/monitors/${id}`);
	assert.equal(page.status, 200);
	page.dom.getByRole("heading", { level: 1, name: "Payments API" });
	for (const heading of ["Response time, last 24 hours", "Failed checks, last 7 days", "90 days", "Last checks", "Incidents, last 90 days"]) page.dom.getByRole("heading", { level: 2, name: heading });
	page.dom.getByRole("img", { name: /^Average response time/ });
	page.dom.getByRole("table");

	const detail = await app.client().read(`/monitors/${id}`);
	assert.equal(detail.latency.length, 48);
	assert.equal(detail.failures.length, 7);
	assert.ok(detail.failures.every((row) => row.length === 24));
	assert.ok(detail.checks.length > 0);
	assert.equal(detail.incidents.length, 1);
	assert.equal(detail.interval_s, 30);

	assert.equal((await app.client().get("/monitors/9999")).status, 404);
	assert.equal((await app.client().get("/incidents/9999")).status, 404);
	assert.equal((await app.client().get("/no/such/page")).status, 404);
});

test("subscribing: a plain form, the runtime's, a wrong address, and the unsubscribe link", async (t) => {
	if (skip(t)) return;
	const person = app.client();
	await person.get("/");
	const posted = await person.post("/subscribe", { email: "grace@example.com" });
	assert.equal(posted.status, 303);
	assert.equal(person.flash.status, 200);
	const back = await posted.follow();
	back.dom.getByText("Subscribed: grace@example.com hears about incidents as they open and close.");

	const again = await person.submit("/subscribe", { email: "GRACE@example.com" });
	assert.equal(again.status, 200);
	const wrong = await person.submit("/subscribe", { email: "grace" });
	assert.equal(wrong.status, 400);
	assert.match(wrong.text, /doesn't look like an email address/);
	const [{ count }] = await db.sql`select count(*)::int as count from subscribers where lower(email) = 'grace@example.com'`;
	assert.equal(count, 1);

	const [{ token }] = await db.sql`select token from subscribers where email = 'grace@example.com'`;
	const page = await person.get(`/unsubscribe?token=${token}`);
	page.dom.getByRole("button", { name: "Unsubscribe" });
	const gone = await person.submit("/unsubscribe", { token });
	assert.equal(gone.status, 200);
	assert.equal(JSON.parse(gone.text), "grace@example.com");
	assert.equal((await person.submit("/unsubscribe", { token })).status, 400);
});

test("the admin: sign-in required, a wrong password told without a flash, then the pages and the tables", async (t) => {
	if (skip(t)) return;
	const stranger = app.client();
	const sent = await stranger.get("/admin");
	assert.equal(sent.status, 303);
	assert.equal(sent.location, "/admin/sign-in?next=%2Fadmin");
	assert.equal((await stranger.request("/admin", { headers: { accept: "application/json" } })).status, 401);
	assert.equal((await stranger.get("/admin/jobs")).status, 303);
	assert.equal((await stranger.get("/admin/db")).status, 303);

	await stranger.get("/admin/sign-in");
	const wrong = await stranger.post("/admin/sign-in", { password: "hunter2", next: "/admin" });
	assert.equal(wrong.status, 303);
	assert.equal(wrong.location, "/admin/sign-in?problem=wrong&next=%2Fadmin");
	assert.equal(stranger.flash, null, "the password isn't kept in a flash");
	(await wrong.follow()).dom.getByRole("alert", { name: "" });

	const person = await admin(app);
	const page = await person.get("/admin");
	assert.equal(page.status, 200);
	page.dom.getByRole("heading", { level: 1, name: "Admin" });
	page.dom.getByRole("button", { name: "Check Payments API now" });
	page.dom.getByRole("button", { name: "Break it" });
	const data = await person.read("/admin");
	assert.ok(data.monitors.some((monitor) => monitor.url === "/demo/flaky"));
	assert.equal((await person.get("/admin/db?table=monitors")).status, 200);
	const jobs = await person.get("/admin/jobs");
	assert.equal(jobs.status, 200);
	assert.match(jobs.text, /check/);

	const out = await person.post("/admin/sign-out", {});
	assert.equal(out.status, 303);
	assert.equal((await person.get("/admin")).status, 303);
});

test("up, down three times, up: checks stored, an incident opened and closed, mailed, and the status page says so", async (t) => {
	if (skip(t)) return;
	await app.client().json("/subscribe", { email: "ada@example.com" });
	const id = await watch(db, target, { name: "Acme Widgets", path: "/widgets" });
	const mailed = (await app.mail()).length;

	target.status = 200;
	await check(db, id);
	assert.equal((await monitorNamed("Acme Widgets")).monitor.state, "operational");

	target.status = 500;
	await check(db, id);
	await check(db, id);
	const failing = await monitorNamed("Acme Widgets");
	assert.equal(failing.monitor.state, "degraded", "two failures: not an incident yet");
	assert.equal(failing.overview.banner.level, "degraded");
	await check(db, id);

	const down = await monitorNamed("Acme Widgets");
	assert.equal(down.monitor.state, "outage");
	assert.equal(down.overview.banner.title, "Partial outage");
	const open = down.overview.incidents.find((incident) => incident.open);
	assert.equal(open.title, "Acme Widgets is down");
	assert.equal(open.updates[0].body, "Acme Widgets failed 3 checks in a row (expected 200, got 500).");
	const opened = await app.waitForMail({ to: "ada@example.com", subject: "[Acme Status] Acme Widgets is down" }, { after: mailed });
	assert.match(opened.text, new RegExp(`${app.url}/incidents/${open.id}`));
	assert.match(opened.text, /unsubscribe\?token=/);
	await app.waitForMail({ to: "oncall@example.com", subject: "[Acme Status] Acme Widgets is down" }, { after: mailed });
	const page = await app.client().get("/");
	page.dom.getByRole("heading", { level: 2, name: "Happening now" });
	page.dom.getByRole("heading", { level: 1, name: "Partial outage" });

	// A fourth failure changes nothing: one incident, one alert each.
	await check(db, id);
	const [{ incidents }] = await db.sql`select count(*)::int as incidents from incidents where monitor_id = ${id}`;
	assert.equal(incidents, 1);

	target.status = 200;
	await check(db, id);
	const up = await monitorNamed("Acme Widgets");
	assert.equal(up.monitor.state, "operational");
	const closed = up.overview.incidents.find((incident) => incident.id === open.id);
	assert.equal(closed.open, false);
	assert.match(closed.updates[0].body, /^Acme Widgets answers again \(200 in \d+ ms\) after 1 minute\.$/);
	const resolved = await app.waitForMail({ to: "ada@example.com", subject: "[Acme Status] Resolved: Acme Widgets is back" }, { after: mailed });
	assert.match(resolved.html, /Acme Widgets is back/);
	const alerts = (await app.mail()).slice(mailed).filter((mail) => mail.to === "ada@example.com");
	assert.equal(alerts.length, 2);

	const stored = await db.sql`select up, status, error from checks where monitor_id = ${id} order by id`;
	assert.deepEqual(stored.map((row) => row.status), [200, 500, 500, 500, 500, 200]);
	assert.equal(stored[1].error, "expected 200, got 500");
	assert.equal(target.asked, 6);
	const done = await db.jobs({ kind: "check" });
	assert.ok(done.every((job) => job.state === "done"), JSON.stringify(done.filter((job) => job.state !== "done")));
});

test("an admin's update on an incident, and a resolved one that closes it and mails", async (t) => {
	if (skip(t)) return;
	const id = await watch(db, target, { name: "Acme Search", path: "/search", threshold: 1 });
	target.status = 500;
	await check(db, id);
	target.status = 200;
	const [{ id: incident }] = await db.sql`select id from incidents where monitor_id = ${id} and closed_at is null`;
	const person = await admin(app);
	const said = await person.submit(`/admin/incidents/${incident}`, { state: "identified", body: "The search index is rebuilding." });
	assert.equal(said.status, 200, said.text);
	const refused = await person.submit(`/admin/incidents/${incident}`, { state: "fixed", body: "?" });
	assert.equal(refused.status, 400);
	let read = await app.client().read(`/incidents/${incident}`);
	assert.deepEqual(read.updates.map((update) => [update.state, update.author]), [["identified", "Acme Status team"], ["investigating", "Acme Status"]]);

	const mailed = (await app.mail()).length;
	assert.equal((await person.submit(`/admin/incidents/${incident}`, { state: "resolved", body: "The index is back." })).status, 200);
	read = await app.client().read(`/incidents/${incident}`);
	assert.equal(read.open, false);
	await db.settleJobs();
	await app.waitForMail({ to: "oncall@example.com", subject: "[Acme Status] Resolved: Acme Search is back" }, { after: mailed });
	assert.equal((await person.submit(`/admin/incidents/${incident}`, { state: "monitoring", body: "Again?" })).status, 409);
	assert.equal((await app.client().submit(`/admin/incidents/${incident}`, { state: "monitoring", body: "Me too" })).status, 401);
});

test("the admin's Check now and Pause", async (t) => {
	if (skip(t)) return;
	const id = await watch(db, target, { name: "Acme Docs", path: "/docs" });
	const person = await admin(app);
	target.status = 200;
	assert.equal((await person.submit(`/admin/monitors/${id}/check`, {})).status, 200);
	await db.settleJobs();
	const [{ count }] = await db.sql`select count(*)::int as count from checks where monitor_id = ${id}`;
	assert.equal(count, 1);

	assert.equal(JSON.parse((await person.submit(`/admin/monitors/${id}/pause`, {})).text), "Paused.");
	assert.equal((await monitorNamed("Acme Docs")).monitor.state, "paused");
	await check(db, id);
	const [{ after }] = await db.sql`select count(*)::int as after from checks where monitor_id = ${id}`;
	assert.equal(after, 1, "a paused monitor's check does nothing");
	assert.equal(JSON.parse((await person.submit(`/admin/monitors/${id}/pause`, {})).text), "Running again.");
	assert.equal((await app.client().submit(`/admin/monitors/${id}/pause`, {})).status, 401);
});

test("the nightly roll-up: past days into `daily`, checks older than a week deleted, today's kept", async (t) => {
	if (skip(t)) return;
	const id = await watch(db, target, { name: "Acme Archive", path: "/archive" });
	await db.query(
		`insert into checks (monitor_id, at, up, status, latency_ms) values (${id}, now() - interval '9 days', true, 200, 100), (${id}, now() - interval '9 days', false, 500, 300), (${id}, now() - interval '2 days', true, 200, 50), (${id}, now(), true, 200, 70)`,
	);
	await db.enqueue("nightly", {});
	const ran = await db.settleJobs();
	assert.ok(ran.some((job) => job.kind === "nightly" && job.state === "done"), JSON.stringify(ran));
	const days = await db.sql`select (utc_today() - day)::int as ago, checks, up, latency_ms_sum::int as latency from daily where monitor_id = ${id} order by day`;
	assert.deepEqual(days, [
		{ ago: 9, checks: 2, up: 1, latency: 400 },
		{ ago: 2, checks: 1, up: 1, latency: 50 },
	]);
	const kept = await db.sql`select (utc_today() - utc_day(at))::int as ago from checks where monitor_id = ${id} order by at`;
	assert.deepEqual(kept.map((row) => row.ago), [2, 0]);

	// Run again, it changes nothing.
	await db.enqueue("nightly", {});
	await db.settleJobs();
	const [{ rows }] = await db.sql`select count(*)::int as rows from daily where monitor_id = ${id}`;
	assert.equal(rows, 2);
	const { monitor } = await monitorNamed("Acme Archive");
	assert.equal(monitor.uptime_90d, "75.00%");
	assert.equal(monitor.uptime_7d, "100%");
});

test("metrics reach the collector: the check latency histogram and the up/down per monitor", async (t) => {
	if (skip(t)) return;
	const id = await watch(db, target, { name: "Acme Metrics", path: "/metrics" });
	target.status = 200;
	await check(db, id);
	const names = () => new Set(target.metrics.flatMap((body) => body.resourceMetrics.flatMap((resource) => resource.scopeMetrics.flatMap((scope) => scope.metrics.map((metric) => metric.name)))));
	// Each instrument's sums are sent every second (OTEL_METRIC_EXPORT_INTERVAL), cumulative: wait
	// for an export that has this monitor's series.
	const seen = () => JSON.stringify(target.metrics).includes('"Acme Metrics"');
	const deadline = Date.now() + 10_000;
	while (!(names().has("uptime.check.duration") && names().has("uptime.check.up") && seen()) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 200));
	assert.ok(names().has("uptime.check.duration"), [...names()].join(", "));
	assert.ok(names().has("uptime.check.up"), [...names()].join(", "));
	assert.ok(names().has("http.server.request.duration"), [...names()].join(", "));
	assert.ok(seen(), "the monitor's own series");
	assert.ok(JSON.stringify(target.metrics).includes('"acme-status"'), "the service's name");
});
