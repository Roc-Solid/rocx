## Million: a million checkboxes, shared by everyone who has the page open. rocx build writes the
## program from routes/ (`Generated/App`: the page, `GET /boxes` and the boxes' channel); this says
## only that every request goes straight to its route. It needs no database: the boxes are kept in
## the server's memory (`Kv`, `Store`), so a restart clears them.
app [program] { pf: platform "../../server/platform/main.roc", virtual: "../../packages/virtual/main.roc" }

import pf.Middleware
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	middleware: Middleware.make(|request, context, next!| next!(request, context)),
})
