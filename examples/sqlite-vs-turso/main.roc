## sqlite-vs-turso: one app timing the same database work, in Roc, on SQLite and on Turso (D-046,
## D-049). Its database is SQLite unless `--database-url` says otherwise: `turso:<path>` runs it on
## Turso, its writes at once (MVCC), and `turso:<path>?mvcc=off` on Turso with its writes taking
## turns, as SQLite's do. POST /bench runs every workload (Bench.roc) and answers how long each took;
## site/sqlite-vs-turso.mjs runs it on all three for the docs. README.md says how to run it.
app [program] { pf: platform "../../server/platform/main.roc" }

import pf.Middleware
import Generated/App

program = App.program({
	context: |_started| {},
	middleware: Middleware.make(|request, context, next!| next!(request, context)),
	# A file beside where the server starts (`--database-url turso:<path>` runs it on Turso).
	database: Sqlite("data/bench.db"),
})
