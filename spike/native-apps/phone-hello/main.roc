## The app's program: the server that answers the phone's (and the browser's) requests. `init!`
## makes the context each request's middleware is given; with no middleware of its own, every request
## goes on to the routes.
app [program] { pf: platform "../../../server/platform/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
