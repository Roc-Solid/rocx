## Million: a million checkboxes, shared by everyone who has the page open. rocx build writes the
## program from routes/ (`Generated/App`: the page, `GET /boxes` and the boxes' channel); every
## request goes straight to its route (it has no routes/+middleware.roc). It needs no database: the boxes are kept in
## the server's memory (`Kv`, `Store`), so a restart clears them.
app [program] { pf: platform "../../server/platform/main.roc", virtual: "../../packages/virtual/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
