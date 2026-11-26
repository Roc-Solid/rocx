## Pomodoro: a focus timer, in a browser and, the same page, on an Android phone (D-063). rocx build
## writes the program from routes/ (`Generated/App`: the page, `GET /api/today` and
## `POST /api/sessions`); this says what is around it: the database (SQLite, a file beside the
## server: each focus session done is a row) and its plugins, the browser's halves of the sound a
## session's end plays (packages/audio) and the buzz (packages/vibrate). A phone needs neither
## script: its host plays and buzzes itself.
app [program] { audio: "../../packages/audio/main.roc", pf: platform "../../server/platform/main.roc", vibrate: "../../packages/vibrate/main.roc" }

import audio.AudioPlayer
import vibrate.Vibrator
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	database: Sqlite("data/pomodoro.db"),
	plugins: [AudioPlayer.plugin({}), Vibrator.plugin({})],
})
