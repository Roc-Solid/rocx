## An app that refuses every request, as a guard that lets nothing through would (`server.test.mjs`),
## with a plugin's files (server/test/fixture's `files`): the host serves them before the app, so
## the refusal never meets them.
app [program] { pf: platform "../../platform/main.roc", fixture: "../fixture/main.roc" }

import fixture.Fixture
import pf.Plugin
import pf.Server

program = {
	# The context is what the server was started with (`--context-file`), as it was before `init!`.
	init!: |started| Ok(started),
	respond!: |_, _| Server.response(403, [{ name: "content-type", value: "text/plain; charset=utf-8" }], "refused"),
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: plugins.map(Plugin.running),
	routes: [],
}

plugins : List(Plugin.Value(Str))
plugins = [Fixture.files("files")]
