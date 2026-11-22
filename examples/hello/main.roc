## The app's program, written by `rocx dev` because there was none: it is yours to change.
## `context` is what each request's middleware is given, and `middleware` runs around every
## request (this one passes it on to the routes); App.program also takes `plugins` and `openapi`.
app [program] { pf: platform "../../server/platform/main.roc" }

import pf.Middleware
import Generated/App

program = App.program({
	context: |_started| {},
	middleware: Middleware.make(|request, context, next!| next!(request, context)),
})
