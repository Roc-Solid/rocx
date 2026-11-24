## sqlite-vs-turso: one app timing the same database work, in Roc, on SQLite and on Turso (D-046,
## D-049). Its database is SQLite unless `--database-url` says otherwise: `turso:<path>` runs it on
## Turso, its writes at once (MVCC), and `turso:<path>?mvcc=off` on Turso with its writes taking
## turns, as SQLite's do. POST /bench runs every workload (Bench.roc) and answers how long each took;
## site/sqlite-vs-turso.mjs runs it on all three for the docs. README.md says how to run it.
##
## packages/jobs is listed for the sale workloads, which queue a receipt job in a sale's
## transaction (Sales.roc), with no workers: the receipts stay queued, so what is timed is writing
## them, and no worker's writes run beside the workloads'.
app [program] { jobs: "../../packages/jobs/main.roc", pf: platform "../../server/platform/main.roc" }

import jobs.Job
import pf.Middleware
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	middleware: Middleware.make(|request, context, next!| next!(request, context)),
	# A file beside where the server starts (`--database-url turso:<path>` runs it on Turso).
	database: Sqlite("data/bench.db"),
	plugins: [Job.plugin({ jobs: App.jobs, workers: 0 })],
})
