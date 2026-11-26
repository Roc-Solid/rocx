## Journal: a small publication in two languages, its posts Markdown files in content/. rocx
## build writes nearly all of the program from routes/ (`Generated/App`: every page and endpoint,
## behind routes/+middleware.roc's `Middlewares.default`: guard's headers, who the reader is); this
## says what only the journal can: that it serves its JSON API's OpenAPI document, with Scalar to
## read it in (`/openapi.json`, `/openapi.html`). It needs no database: the posts are compiled in, and the reactions are kept in
## the server's memory (`Kv`).
app [program] { guard: "../../packages/guard/main.roc", intl: "../../packages/intl/main.roc", markdown: "../../packages/markdown/main.roc", pf: platform "../../server/platform/main.roc", testing: "../../packages/testing/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	openapi: Page(Scalar),
})
