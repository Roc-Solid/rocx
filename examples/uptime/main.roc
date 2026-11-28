## Status: an uptime monitor and its public status page. rocx writes nearly all of the program
## from routes/ (`Generated/App`: every page, endpoint and channel, the migrations in
## migrations/ and the jobs Jobs.roc defines; what every request goes through, routes/+middleware.roc,
## and the admin's, routes/(admin)/+middleware.roc); this says the rest: the plugins, and its
## database, SQLite (D-045).
##
## - packages/jobs runs the jobs: a sweep every 10 seconds that queues the checks due, the checks,
##   the alerts, and a roll-up each night at 03:00 UTC.
## - packages/admin's jobs page shows that queue at /admin/jobs (its route,
##   routes/(admin)/admin/jobs/), behind the admin's sign-in; `links` lists it under `--dev`.
## - packages/email sends the alerts: over SMTP with `SMTP_URL`, or else, under `--dev`, kept for
##   the dev mailbox (`/__rocx/mail`); a server with neither doesn't start.
## - packages/auth keeps the admin's sessions (12 hours, in the `uptime_admin` cookie, their hashes
##   in the database) and ends them at `POST /auth/sign-out` (its route, routes/auth/sign-out/). It
##   has no routes for links or providers, so nobody signs in that way: Session.roc checks
##   `ADMIN_PASSWORD` and starts a session itself.
## - packages/otel sends the metrics (each request's time, each check's latency, each monitor's
##   state) to the collector `OTEL_EXPORTER_OTLP_ENDPOINT` names; without it, nothing is measured.
app [program] { admin: "../../packages/admin/main.roc", auth: "../../packages/auth/main.roc", charts: "../../packages/charts/main.roc", crypto: "../../packages/crypto/main.roc", email: "../../packages/email/main.roc", jobs: "../../packages/jobs/main.roc", otel: "../../packages/otel/main.roc", pf: platform "../../server/platform/main.roc", testing: "../../packages/testing/main.roc" }

import auth.Auth
import email.Email
import jobs.Cron
import jobs.Job
import otel.Otel
import Generated/App
import Jobs

program = App.program({
	init!: |_started| Ok({}),
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/uptime.db"),
	# Under --dev, the jobs page (its route, routes/(admin)/admin/jobs/) among the places to open.
	links: [{ label: "Jobs", path: "/admin/jobs" }],
	plugins: [
		# A job each ten seconds (`Jobs.due`): done ones are kept an hour, not the plugin's week.
		Job.plugin({ jobs: App.jobs, crons: [Cron.every("*/10 * * * * *", Jobs.due, {}), Cron.every("0 3 * * *", Jobs.nightly, {})], keep_done_ms: 60 * 60 * 1000 }),
		Email.plugin({ from: "Status <status@example.com>" }),
		Auth.plugin({ sign_in: "/admin/sign-in", home: "/admin", cookie: "uptime_admin", session_ms: 12 * 60 * 60 * 1000 }),
		Otel.plugin({}),
	],
})
