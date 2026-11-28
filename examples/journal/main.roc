## Journal: a small publication in two languages, its posts Markdown files in content/. The README
## says what it shows, and where.
##
## This is the server's program. rocx (`rocx dev`, `rocx build`, or `rocx generate` alone) writes
## nearly all of it from routes/ into `Generated/App`: every page and endpoint, the OpenAPI document
## and its Scalar page too (route files, `routes/openapi.json/` and `routes/openapi.html/`), behind
## routes/+middleware.roc's `Middlewares.default` (guard's headers, who the reader is). So this says
## only how it starts. It keeps nothing in a database: the posts are compiled in, and the reactions
## are kept in the server's memory (`Kv`). Naming no database, it still opens SQLite's
## `data/app.db` where it starts (D-105), for the platform's own tables.
app [program] { guard: "../../packages/guard/main.roc", intl: "../../packages/intl/main.roc", markdown: "../../packages/markdown/main.roc", pf: platform "../../server/platform/main.roc", testing: "../../packages/testing/main.roc" }

import Generated/App

program = App.program({
	init!: |_started| Ok({}),
})
