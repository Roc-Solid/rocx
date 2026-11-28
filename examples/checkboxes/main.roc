## Million: a million checkboxes, shared by everyone who has the page open. rocx writes the program
## from routes/ (`Generated/App`: the page, `GET /boxes` and the boxes' channel); every request goes
## straight to its route (it has no routes/+middleware.roc). It keeps nothing in a database: the boxes
## are in the server's memory (`Kv`, `Store`), so a restart clears them. The server opens SQLite's
## `data/app.db` all the same, as an app that names no database does (D-105).
app [program] { pf: platform "../../server/platform/main.roc", virtual: "../../packages/virtual/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
