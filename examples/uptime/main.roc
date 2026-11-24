## Status: an uptime monitor and its public status page. rocx build writes nearly all of the
## program from routes/ (`Generated/App`: every page, endpoint and channel, the migrations in
## migrations/, the jobs Jobs.roc defines and the actor packages/otel's Otel.roc does); this says the
## rest: what every request goes through first, the plugins, and its database, SQLite (D-045).
##
## - packages/jobs runs the jobs: a sweep every 10 seconds that queues the checks due, the checks,
##   the alerts, and a roll-up each night at 03:00 UTC.
## - packages/admin's jobs page shows that queue at /admin/jobs, behind the admin's sign-in.
## - packages/email sends the alerts: over SMTP with `SMTP_URL`, or else kept for the dev mailbox
##   (`/__rocx/mail` under `--dev`).
## - packages/auth keeps the admin's sessions (12 hours, in the `uptime_admin` cookie, their hashes
##   in the database) and ends them at `POST /auth/sign-out`. It has no `admit!`, so nobody signs in
##   by a link or a provider: Session.roc checks `ADMIN_PASSWORD` and starts a session itself.
app [program] { admin: "../../packages/admin/main.roc", auth: "../../packages/auth/main.roc", charts: "../../packages/charts/main.roc", crypto: "../../packages/crypto/main.roc", email: "../../packages/email/main.roc", jobs: "../../packages/jobs/main.roc", otel: "../../packages/otel/main.roc", pf: platform "../../server/platform/main.roc", testing: "../../packages/testing/main.roc" }

import auth.Auth
import email.Email
import jobs.Cron
import jobs.Job
import admin.JobsPage
import Generated/App
import Jobs
import Middlewares

program = App.program({
	init!: |_started| Ok({}),
	middleware: Middlewares.default,
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/uptime.db"),
	plugins: [
		Job.plugin({ jobs: App.jobs, crons: [Cron.every("*/10 * * * * *", Jobs.due, {}), Cron.every("0 3 * * *", Jobs.nightly, {})] }),
		JobsPage.plugin({ at: "/admin/jobs", guard: Middlewares.admin, back: { label: "Status admin", href: "/admin" } }),
		Email.plugin({ from: "Status <status@example.com>" }),
		Auth.plugin({ sign_in: "/admin/sign-in", home: "/admin", cookie: "uptime_admin", session_ms: 12 * 60 * 60 * 1000 }),
	],
})
