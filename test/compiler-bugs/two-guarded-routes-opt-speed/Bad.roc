app [program] { pf: platform "../../../server/platform/main.roc" }

import pf.Middleware
import pf.Plugin
import pf.Server

## A program made from plugins, as rocx's Generated/App makes one: their routes answer requests, and
## the platform keeps the rest (`Plugin.running`).
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

## A middleware whose function captures a list (`Middleware.headers` adds these headers).
headed : Middleware(Str, Str)
headed = Middleware.headers([{ name: "x-app", value: "repro" }])

## With `--opt=speed`, the server crashes (SIGSEGV) as it starts, before it logs a line.
program = make([guarded(headed)])
