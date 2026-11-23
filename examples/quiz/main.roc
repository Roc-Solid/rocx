## Pinwheel, a live quiz for a room full of phones: the server's program. rocx build writes nearly
## all of it from routes/ (`Generated/App`: every page, endpoint and channel; the room's actor kind,
## found in Rooms.roc; the migrations in migrations/). This says what only the app can: what every
## request is handed (the visitor, from their cookie: `Visitor.middleware`), its database, SQLite
## (D-045), and its one plugin, the audio player (packages/audio, D-051).
##
## The browser's half is the same pages, compiled to WebAssembly from the copy `rocx build
## examples/quiz --client <out>` writes. README.md says how to build, run and test it.
app [program] { audio: "../../packages/audio/main.roc", charts: "../../packages/charts/main.roc", forms: "../../packages/forms/main.roc", pf: platform "../../server/platform/main.roc", presence: "../../packages/presence/main.roc" }

import audio.AudioPlayer
import Generated/App
import Visitor

program = App.program({
	init!: |_started| Ok({}),
	middleware: Visitor.middleware,
	# A file beside where the server starts (`--database-url sqlite:<path>` puts it elsewhere).
	database: Sqlite("data/quiz.db"),
	# The player for its sounds (packages/audio): a script every page loads.
	plugins: [AudioPlayer.plugin({})],
})
