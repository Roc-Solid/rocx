## An app that answers its environment's variables, for the server's tests of `.env`
## (`server/test/envfile.test.mjs`, D-088): `GET /env/<NAME>` answers `Env.var!(NAME)`, or
## `(none)`.
app [program] { pf: platform "../../platform/main.roc" }

import pf.Env
import pf.Server

program = {
	init!: |_started| Ok({}),
	respond!: |request, {}| {
		name = request.path.drop_prefix("/env/")
		Server.response(200, [{ name: "content-type", value: "text/plain; charset=utf-8" }], Env.var!(name) ?? "(none)")
	},
	database: Sqlite("data/envfile.db"),
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: [],
	routes: [],
}
