## The app's program: the server that answers the phone's (and the browser's) requests. `context`
## is what each request's middleware is given, and `middleware` runs around every request (this one
## passes it on to the routes).
app [program] { pf: platform "../../server/platform/main.roc" }

import pf.Middleware
import Generated/App

program = App.program({
	context: |_started| {},
	middleware: Middleware.make(|request, context, next!| next!(request, context)),
})
