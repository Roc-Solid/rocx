## An app whose program says how its log is written (`logs: { format: Pretty }`), for the server's
## tests (`server/test/server.test.mjs`): that wins over what `Auto` would guess, and over
## `ROCX_LOG`.
app [program] { pf: platform "../../platform/main.roc" }

import pf.Log
import pf.Server

program = {
	respond!: |_method, target, _headers, _body, _context| {
		Log.info!("an event from Roc", { target, note: "two words" })
		Server.response(200, [{ name: "content-type", value: "text/plain; charset=utf-8" }], "logged")
	},
	migrations: [],
	jobs: [],
	crons: [],
	actors: [],
	logs: { format: Pretty },
}
