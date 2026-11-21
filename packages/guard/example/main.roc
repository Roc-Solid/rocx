## An app that uses packages/guard: security headers, a body limit and maintenance mode on every
## request, a limit on /api and on the login route, a route behind a feature flag, and a page that
## shows the new checkout to those who have it on. Its server-only modules aren't copied in by
## rocx build yet (PROPOSALS.md, "Server-only modules in packages"), so copy them by hand first:
##
##     cp ../server/*.roc .
##     rocx build .
app [program] { guard: "../main.roc", pf: platform "../../../server/platform/main.roc" }

import Generated/App
import Middlewares

## Every request: the default middleware, then the routes.
program = App.program({
	context: |started| { facts: started },
	middleware: Middlewares.default,
	crons: [],
})
