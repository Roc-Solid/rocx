## The smallest app on the server platform: one endpoint, POST /echo, which answers with what it was
## sent. It's for measuring the server itself (README.md says how): every request goes through the
## generated routes and a middleware that only passes it on, and nothing else.
app [program] { pf: platform "../../server/platform/main.roc" }

import pf.Middleware
import Generated/App

## Every request: a middleware that passes it straight on, then the routes.
program = App.program({
	context: |_started| {},
	middleware: Middleware.make(|request, context, next!| next!(request, context)),
})
