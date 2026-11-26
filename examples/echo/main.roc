## The smallest app on the server platform: POST /echo answers with the JSON string it was sent, and
## POST /echo/json reads an order (Shop.Order) and writes it back. It's for measuring the server
## itself, and what reading and writing JSON adds (README.md says how): every request goes through
## the generated routes, and nothing else (no routes/+middleware.roc).
app [program] { pf: platform "../../server/platform/main.roc" }

import Generated/App

## Every request goes straight to its route.
program = App.program({
	init!: |_started| Ok({}),
})
