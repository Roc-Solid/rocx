## Board: a live kanban board for a small team. rocx writes nearly all of the program from routes/
## into `Generated/App` (`rocx generate`; `rocx dev` and `rocx build` do it first): every page,
## endpoint and channel, the migrations in migrations/, and what requests go through (each folder's
## `+middleware.roc`). This says the rest: the plugin, and its database, SQLite (D-045).
##
## packages/auth keeps who joined as whom as a session in the database, its cookie `board_session`.
## The app has no routes for auth's links or providers, so nobody signs in that way: joining
## (`/join`) starts the session itself (`Auth.switch!`, ending the session the browser had), for the
## person picked or made (a row of the app's own `people`).
app [program] { auth: "../../packages/auth/main.roc", guard: "../../packages/guard/main.roc", pf: platform "../../server/platform/main.roc", presence: "../../packages/presence/main.roc" }

import auth.Auth
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/board.db"),
	# Who joined as whom, kept for a year. `/join` is where you say it, so it is the sign-in page:
	# a member's page asked for signed out goes there, and comes back after (`?then=`).
	plugins: [Auth.plugin({ cookie: "board_session", sign_in: "/join", session_ms: 365 * 86_400_000, refusal: "Join first, at /join." })],
})
