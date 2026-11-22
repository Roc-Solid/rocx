## Tasks: a small team's task lists, on Roc Solid. The README says what it shows, and where.
##
## This is the server's program. rocx build writes nearly all of it from the app's routes
## (`routes/`: pages, layouts and endpoints) into `Generated/App`, with the migrations
## (`migrations/*.sql`) embedded; this file says only what the routes can't: what every request's
## context starts as, the middleware around every request, and its database, SQLite (D-045). The
## browser's program is the same pages, compiled to WebAssembly from the copy `rocx build --client`
## writes.
app [program] { forms: "../../packages/forms/main.roc", pf: platform "../../server/platform/main.roc", testing: "../../packages/testing/main.roc" }

import Generated/App
import Middlewares

program = App.program({
	context: |_started| {},
	middleware: Middlewares.default,
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/tasks.db"),
})
