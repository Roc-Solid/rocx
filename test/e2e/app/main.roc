## An app whose route files are components, for the e2e tests (test/e2e.test.mjs): rocx build writes
## its program (`Generated/App`: its routes, the jobs its modules define, migrations/*.sql), and this
## is all its author writes besides the route files and the modules they use.
app [program] { pf: platform "../../../server/platform/main.roc" }

import pf.Cron
import Generated/App
import Middlewares
import Jobs

program = App.program({
	context: |started| { started: started },
	middleware: Middlewares.default,
	crons: [Cron.every("0 3 * * *", Jobs.welcome, { member: "everyone" })],
})
