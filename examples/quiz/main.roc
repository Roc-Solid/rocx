## Pinwheel, a live quiz for a room full of phones: the server's program. rocx build writes nearly
## all of it from routes/ (`Generated/App`: every page, endpoint and channel; the room's actor kind,
## found in Rooms.roc; the migrations in migrations/). This says what only the app can: what every
## request is handed (the visitor, from their cookie: `Visitor.middleware`), and its database,
## SQLite (D-045).
##
## The browser's half is the same pages, compiled to WebAssembly from the copy `rocx build
## examples/quiz --client <out>` writes. README.md says how to build, run and test it.
app [program] { charts: "../../packages/charts/main.roc", forms: "../../packages/forms/main.roc", pf: platform "../../server/platform/main.roc", presence: "../../packages/presence/main.roc" }

import Generated/App
import Visitor

program = App.program({
	context: |_started| {},
	middleware: Visitor.middleware,
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/quiz.db"),
})
