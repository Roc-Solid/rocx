app [program] { pf: platform "../../../server/platform/main.roc" }

import pf.Middleware
import pf.Plugin
import pf.Server


make : List(Plugin.Value(Str)) -> _
make = |plugins| {
	init!: |started| Ok(started),
	respond!: |request, started| {
		Plugin.respond!(plugins, request, started, |_, _| Server.response(404, [], "fell through"))
	},
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: plugins.map(Plugin.running),
	routes: [],
}

## A plugin whose two routes each run a guard (a middleware) before answering.
guarded : Middleware(context, out) -> Plugin.Value(context)
guarded = |guard| {
	name: "guarded",
	routes: [
		{ method: "GET", path: "/doc", kind: Page, answer!: |request, context| Middleware.run!(guard, request, context, |_, _| Server.response(200, [], "get")) },
		{ method: "POST", path: "/doc", kind: Page, answer!: |request, context| Middleware.run!(guard, request, context, |_, _| Server.response(200, [], "post")) },
	],
}

## A middleware whose function captures nothing: this one works.
headed : Middleware(Str, Str)
headed = Middleware.make(|request, context, next!| next!(request, context))

program = make([guarded(headed)])
