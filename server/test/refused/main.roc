## An app whose plugins break every rule the server checks when it starts (`server.test.mjs`): it
## never starts, and says why, every problem a line.
app [program] { pf: platform "../../platform/main.roc" }

import pf.Plugin
import pf.Server

program = {
	respond!: |_, _| Server.response(200, [], "never"),
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: plugins.map(Plugin.running),
	# As `rocx build` writes `Routes.claims`: the app's own page at /x.
	routes: [{ method: "GET", path: "/x", file: "routes/x/+page.rocx" }],
}

## Each breaks a rule, or two.
plugins : List(Plugin.Value({}))
plugins = [
	# A route the app has; a loop not named with the plugin's name first; an early path outside /__rocx/.
	{ name: "clash", routes: [route("GET", "/x")], loops: [{ name: "beat", run!: |{}| {} }], early: [{ method: "GET", path: "/mail", under: [Dev], answer!: |_| answer }] },
	# Two plugins at one path (a param's name doesn't matter); a variable that isn't set.
	{ name: "one", routes: [route("*", "/y/[id]")], needs: [Env("REFUSED_UNSET")] },
	{ name: "two", routes: [route("POST", "/y/[key]")] },
	# A plugin that isn't in the list.
	{ name: "auth", needs: [Plugin("email")] },
	# Needs that go round in a circle.
	{ name: "left", needs: [Plugin("right")] },
	{ name: "right", needs: [Plugin("left")] },
	# A name used twice, and one that isn't a name.
	{ name: "two" },
	{ name: "Bad Name" },
]

route : Str, Str -> Plugin.Route({})
route = |method, path| { method, path, kind: Endpoint, answer!: |_, _| answer }

answer : Server.Response
answer = Server.response(200, [], "plugged")
