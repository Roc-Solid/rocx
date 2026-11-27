## Tasks: a small team's task lists, on Roc Solid. The README says what it shows, and where.
##
## This is the server's program. rocx build writes nearly all of it from the app's routes
## (`routes/`: pages, layouts and endpoints) into `Generated/App`, with the migrations
## (`migrations/*.sql`) embedded, and the middleware around every request (`routes/+middleware.roc`);
## this file says only what the routes can't: what every request's context starts as, the plugins,
## and its database, SQLite (D-045). The browser's program is the same pages, compiled to WebAssembly from the copy
## `rocx build --client` writes.
##
## packages/auth keeps who you said you are (`/me`) as a session in the database, its cookie
## `tasks_session`. Without an `admit!`, nobody signs in by a link or a provider: `/me` starts the
## session itself (`Auth.sign_in!`), for the person picked.
app [program] { auth: "../../packages/auth/main.roc", forms: "../../packages/forms/main.roc", pf: platform "../../server/platform/main.roc", testing: "../../packages/testing/main.roc" }

import auth.Auth
import Generated/App
import Middlewares

program = App.program({
	init!: |_started| Ok({}),
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/tasks.db"),
	# Who you said you are, kept for a year. `/me` is where you say it, so it is the sign-in page.
	plugins: [Auth.plugin({ middleware: Middlewares.default, cookie: "tasks_session", sign_in: "/me", session_ms: 365 * 86_400_000 })],
})
