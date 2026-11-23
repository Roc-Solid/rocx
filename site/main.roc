## The site's program, on the server platform (`server/platform`: native code, in a Rust host). rocx
## build writes nearly all of it from site/routes (`Generated/App`: every page and endpoint, behind
## the site's default middleware); this says what only the site can: what its
## middleware is given, which middleware that is, and that it serves its endpoints' OpenAPI
## document, with a page to read it in (`/openapi.json`, and `/openapi.html` in Swagger UI). The browser's half is the same pages, compiled to WebAssembly from the browser's copy
## of the site (`rocx build site --client site/build/client` writes its main.roc).
app [program] { admin: "../packages/admin/main.roc", audio: "../packages/audio/main.roc", charts: "../packages/charts/main.roc", forms: "../packages/forms/main.roc", guard: "../packages/guard/main.roc", intl: "../packages/intl/main.roc", markdown: "../packages/markdown/main.roc", mcp: "../packages/mcp/main.roc", pf: platform "../server/platform/main.roc", presence: "../packages/presence/main.roc", push: "../packages/push/main.roc", testing: "../packages/testing/main.roc", virtual: "../packages/virtual/main.roc" }

import audio.AudioPlayer
import Generated/App
import Middlewares

# The count (Demos/Count.rocx) is on no page: a copy of the site as files can't stream its events.
# The calls page shows its code, so the server's program imports it, and the compiler checks it.
import Demos/Count

## Every request: the site's default middleware, given the facts the build measured (what the
## server was started with, `--context-file`); then the routes. The site has no database tables,
## jobs or schedules; its one plugin is the audio player (packages/audio), whose script plays the
## showcase's sounds.
program = App.program({
	context: |started| { facts: started },
	middleware: Middlewares.default,
	openapi: Page(Swagger),
	plugins: [AudioPlayer.plugin({})],
})
