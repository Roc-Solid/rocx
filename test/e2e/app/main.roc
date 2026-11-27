## An app whose route files are components, for the e2e tests (test/e2e.test.mjs): rocx build writes
## its program (`Generated/App`: its routes, the jobs its modules define, migrations/*.sql), and this
## is all its author writes besides the route files (routes/+middleware.roc around every request)
## and the modules they use: its context, and its plugin (the jobs; the jobs page is a route file).
app [program] { admin: "../../../packages/admin/main.roc", jobs: "../../../packages/jobs/main.roc", pf: platform "../../../server/platform/main.roc" }

import jobs.Cron
import jobs.Job
import Generated/App
import Jobs

program = App.program({
	init!: |started| Ok({ started: started }),
	# Its jobs on Postgres, the test's database (DATABASE_URL).
	database: Postgres,
	# The jobs plugin (packages/jobs): the kinds of job the app's modules define, and a schedule. The
	# jobs page (packages/admin) is a route of the app's, for members only (routes/(staff)/).
	plugins: [
		Job.plugin({ jobs: App.jobs, crons: [Cron.every("0 3 * * *", Jobs.welcome, { member: "everyone" })] }),
	],
})
