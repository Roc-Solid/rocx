app [program] { pf: platform "../../../server/platform/main.roc" }

import pf.Middleware
import pf.Server

## As rocx build's Generated/App has it: what the app says, and the program made from it.
Config(given, handed) := {
	init! : Str => Try(given, Str),
	middleware : Middleware(given, handed),
	plugins : List(Plugged(handed)) ?? [],
}

make : Config(_, _) -> _
make = |config| {
	init!: config.init!,
	respond!: |request, given| {
		Middleware.run!(config.middleware, request, given, |passed, context| respond_with!(config.plugins, passed, context))
	},
	database: Postgres,
	migrations: [],
	actors: [],
	logs: { format: Auto },
	plugins: [],
	routes: claimed(config.plugins),
}

## A plugin as the server platform had one before D-116 (since then a plugin has no routes, and
## this repro keeps the shape with a record of its own): a name, and routes, each a closure.
Plugged(context) : { name : Str, routes : List({ method : Str, path : Str, answer! : Server.Request, context => Server.Response }) }

## The route of `plugins` for `request`, or a 404.
respond_with! : List(Plugged(context)), Server.Request, context => Server.Response
respond_with! = |plugins, request, context|
	match plugins.join_map(|plugin| plugin.routes).find_first(|route| route.method == request.method and route.path == request.path) {
		Ok(route) => (route.answer!)(request, context)
		Err(_) => Server.response(404, [], "fell through")
	}

## What the platform kept of each plugin: its routes' methods and paths, by a `List.map` over the
## plugins (`Plugin.running`, where the crash was).
claimed : List(Plugged(context)) -> List({ method : Str, path : Str, file : Str })
claimed = |plugins| plugins.map(|plugin| plugin.routes.map(|route| { method: route.method, path: route.path, file: plugin.name })).join()

## A plugin whose two routes each run a guard (a middleware) before answering.
guarded : Middleware(context, out) -> Plugged(context)
guarded = |guard| {
	name: "guarded",
	routes: [
		{ method: "GET", path: "/doc", answer!: |request, context| Middleware.run!(guard, request, context, |_, _| Server.response(200, [], "get")) },
		{ method: "POST", path: "/doc", answer!: |request, context| Middleware.run!(guard, request, context, |_, _| Server.response(200, [], "post")) },
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
