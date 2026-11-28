## Pinwheel, a live quiz for a room full of phones: the server's program. rocx writes nearly all of
## it from routes/ into `Generated/App` (`rocx generate`; `rocx dev` and `rocx build` do it first):
## every page, endpoint and channel; the room's actor kind, found in Rooms.roc; the migrations in
## migrations/; what every request is handed, the visitor from their cookie (routes/+middleware.roc's
## `Visitor.middleware`). This says what only the app can: its database, SQLite (D-045), and its one
## plugin, the audio player (packages/audio, D-051).
##
## The browser's half is the same pages, compiled to WebAssembly from the copy rocx writes under
## build/. README.md says how to build, run and test it.
app [program] { audio: "../../packages/audio/main.roc", charts: "../../packages/charts/main.roc", forms: "../../packages/forms/main.roc", pf: platform "../../server/platform/main.roc", presence: "../../packages/presence/main.roc" }

import audio.AudioPlayer
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/quiz.db"),
	# The player for its sounds (packages/audio): a script every page loads.
	plugins: [AudioPlayer.plugin({})],
})
