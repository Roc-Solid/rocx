## The app's program, written by `rocx dev` because there was none: it is yours to change.
## `context` is what each request's middleware is given (routes/+middleware.roc runs around every
## request, if the app has one); App.program also takes `plugins`, `database`, `cross_site` and `links`.
app [program] { pf: platform "../../server/platform/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
