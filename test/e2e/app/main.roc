## An app whose route files are components, for the e2e tests (test/e2e.test.mjs): rocx build writes
## its program (`Generated/App`: its routes, the jobs its modules define, migrations/*.sql), and this
## is all its author writes besides the route files and the modules they use: its context, its
## middleware, and its plugins (the jobs).
app [program] { jobs: "../../../packages/jobs/main.roc", pf: platform "../../../server/platform/main.roc" }

import jobs.Cron
import jobs.Job
import Generated/App
import Middlewares
import Jobs

program = App.program({
	context: |started| { started: started },
	middleware: Middlewares.default,
	# The jobs plugin (packages/jobs): the kinds of job the app's modules define, and a schedule.
	plugins: [Job.plugin({ jobs: App.jobs, crons: [Cron.every("0 3 * * *", Jobs.welcome, { member: "everyone" })] })],
})
