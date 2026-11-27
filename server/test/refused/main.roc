## An app whose plugins break every rule the server checks when it starts (`server.test.mjs`): it
## never starts, and says why, every problem a line.
app [program] { pf: platform "../../platform/main.roc" }

import pf.Plugin
import pf.Server

program = {
	# The context is what the server was started with (`--context-file`), as it was before `init!`.
	init!: |started| Ok(started),
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
plugins : List(Plugin.Value(Str))
plugins = [
	# A loop not named with the plugin's name first; an early path outside /__rocx/; a file at the
	# root where the app has a route; a file whose path isn't relative.
	{
		name: "clash",
		loops: [{ name: "beat", run!: |_context| {} }],
		early: [{ method: "GET", path: "/mail", under: [Dev], answer!: |_| answer }],
		files: [file("x", Root), file("/abs.js", Plugin)],
	},
	# Two plugins' early paths at one path (a param's name doesn't matter); a variable that isn't set;
	# two files at one place at the root; a script that is none of the plugin's files; a file at the
	# root, in the platform's place.
	{ name: "one", early: [{ method: "*", path: "/__rocx/y/[id]", under: [Dev], answer!: |_| answer }], needs: [Env("REFUSED_UNSET")], files: [file("sw.js", Root)], scripts: ["missing.js"] },
	{ name: "two", early: [{ method: "POST", path: "/__rocx/y/[key]", under: [Dev], answer!: |_| answer }], files: [file("sw.js", Root), file("rocx/start.js", Root)] },
	# A plugin that isn't in the list.
	{ name: "auth", needs: [Plugin("email")] },
	# Needs that go round in a circle.
	{ name: "left", needs: [Plugin("right")] },
	{ name: "right", needs: [Plugin("left")] },
	# A name used twice, and one that isn't a name.
	{ name: "two" },
	{ name: "Bad Name" },
]

file : Str, [Plugin, Root] -> Plugin.File
file = |path, at| { path, at, content_type: "text/javascript", body: [] }

answer : Server.Response
answer = Server.response(200, [], "plugged")
