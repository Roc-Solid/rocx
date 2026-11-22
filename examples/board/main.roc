## Board: a live kanban board for a small team. rocx build writes nearly all of the program from
## routes/ (`Generated/App`: every page, endpoint and channel, the migrations in migrations/, and the
## actors the app's modules define); this says the rest: what every request goes through first.
app [program] { guard: "../../packages/guard/main.roc", pf: platform "../../server/platform/main.roc", presence: "../../packages/presence/main.roc" }

import Generated/App
import Middlewares

program = App.program({
	context: |_started| {},
	middleware: Middlewares.default,
})
