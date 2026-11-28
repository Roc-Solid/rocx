## Plate: a food diary on Roc Solid. The README says what it shows, and where.
##
## This is the server's program. rocx writes nearly all of it from the app's routes (`routes/`:
## pages, layouts and endpoints) into `Generated/App`, with the migrations (`migrations/*.sql`, the
## USDA foods among them) embedded; this file says only what the routes can't (the middleware is
## routes/'s: `+middleware.roc` around every request, and the diary's): what every request's context
## starts as, its database, SQLite (D-045), and packages/auth, which keeps the sessions when the
## diary has a password (`PLATE_PASSWORD`: Session.roc checks it, and starts a session itself, since
## the app has no routes for links or providers and nobody signs in that way). The browser's program
## is the same pages, compiled to WebAssembly from the copy rocx writes of them.
app [program] { auth: "../../packages/auth/main.roc", charts: "../../packages/charts/main.roc", crypto: "../../packages/crypto/main.roc", forms: "../../packages/forms/main.roc", pf: platform "../../server/platform/main.roc", testing: "../../packages/testing/main.roc", tools: "../../packages/tools/main.roc" }

import auth.Auth
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/plate.db"),
	plugins: [
		# A session lasts 90 days in the `plate_session` cookie, kept going while it is used; the
		# sign-in page is the plugin's default, `/sign-in`.
		Auth.plugin({ cookie: "plate_session", session_ms: 90 * 24 * 60 * 60 * 1000 }),
	],
})
