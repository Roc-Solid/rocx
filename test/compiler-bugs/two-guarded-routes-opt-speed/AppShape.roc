app [program] { pf: platform "../../../server/platform/main.roc" }

import pf.Middleware
import pf.Plugin
import pf.Server

## As rocx build's Generated/App has it: what the app says, and the program made from it.
Config(given, handed) := {
	init! : Str => Try(given, Str),
	middleware : Middleware(given, handed),
	plugins : List(Plugin.Value(given, handed)) ?? [],
}

make : Config(_, _) -> _
make = |config| {
	init!: config.init!,
	respond!: |request, given| {
		Middleware.run!(config.middleware, request, given, |passed, context| Plugin.respond!(config.plugins, passed, context, |_, _| Server.response(404, [], "fell through")))
	},
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: config.plugins.map(Plugin.running),
	routes: [],
}

## A plugin whose two routes each run a guard (a middleware) before answering.
guarded : Middleware(ctx, out) -> Plugin.Value(context, ctx)
guarded = |guard| {
	name: "guarded",
	routes: [
		{ method: "GET", path: "/doc", kind: Page, answer!: |request, context| Middleware.run!(guard, request, context, |_, _| Server.response(200, [], "get")) },
		{ method: "POST", path: "/doc", kind: Page, answer!: |request, context| Middleware.run!(guard, request, context, |_, _| Server.response(200, [], "post")) },
	],
}

headed : Middleware({ started : Str }, { started : Str })
headed = Middleware.headers([{ name: "x-app", value: "repro" }])

## With `--opt=speed`, the server crashes (SIGSEGV) as it starts, before it logs a line.
program = make({
	init!: |started| Ok({ started: started }),
	middleware: headed,
	plugins: [guarded(headed)],
})
