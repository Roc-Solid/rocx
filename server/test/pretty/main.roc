## An app whose program says how its log is written (`logs: { format: Pretty }`), for the server's
## tests (`server/test/server.test.mjs`): that wins over what `Auto` would guess, and over
## `ROCX_LOG`.
app [program] { pf: platform "../../platform/main.roc" }

import pf.Log
import pf.Server

program = {
	respond!: |request, _context| {
		Log.info!("an event from Roc", { target: request.path, note: "two words" })
		Server.response(200, [{ name: "content-type", value: "text/plain; charset=utf-8" }], "logged")
	},
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Pretty },
	plugins: [],
	routes: [],
}
