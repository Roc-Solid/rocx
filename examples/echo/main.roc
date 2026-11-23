## The smallest app on the server platform: POST /echo answers with the JSON string it was sent, and
## POST /echo/json reads an order (Shop.Order) and writes it back. It's for measuring the server
## itself, and what reading and writing JSON adds (README.md says how): every request goes through
## the generated routes and a middleware that only passes it on, and nothing else.
app [program] { pf: platform "../../server/platform/main.roc" }

import pf.Middleware
import Generated/App

## Every request: a middleware that passes it straight on, then the routes.
program = App.program({
	init!: |_started| Ok({}),
	middleware: Middleware.make(|request, context, next!| next!(request, context)),
})
