import Host
import Server

## What a package adds to an app, as one value the app lists (`App.program({ plugins: [...] })`):
## its routes, which answer inside the app's middleware; paths answered before the app, under
## `--dev` or `--debug` (`early`); files served as they are, before the app and its middleware
## (`files`), and those of them every page loads (`scripts`); its tables (`migrations`); named
## functions run in a call of their own (`calls`); background loops; work run once the server has
## started (`starts`) and checks run after (`checks`); and what it needs that the compiler can't see
## (`needs`). Every field but `name` has a default, so a plugin says only what it adds. A package
## makes one from options of its own, whose fields without a default are required
## (`JobsPage.plugin({ guard })`).
##
## ```roc
## plugin : Options -> Plugin.Value(context, ctx)
## plugin = |options| {
##     name: "acme",
##     routes: [{ method: "GET", path: options.at, kind: Page, answer!: |request, _ctx| page!(request) }],
##     migrations: [{ name: "0001_notes", sql: notes }],
##     loops: [{ name: "acme.sync", run!: |_context| sync!({}) }],
##     needs: [Database, Env("ACME_KEY")],
## }
## ```
##
## A plugin's calls, loops, starts and checks are given the app's context (what its `init!` made,
## `context`), as its jobs and actors are; its routes are given what the app's middleware hands
## them (`ctx`). A plugin knows the type of neither.
##
## When the server starts it checks every plugin at once, and any problem stops it, with the whole
## list: a name used twice; a call, loop or check not named `<plugin>.<name>`; an early path not
## under `/__rocx/`; two routes at one method and path (the app's and a plugin's, or two plugins');
## a file's path that isn't one (`/sw.js`, `../x`), two files at one path, a file at the root where
## the app has a route (or another plugin one), a script that is none of the plugin's files; a need
## not met (an environment variable unset, no database or one of the other flavor, a plugin not in
## the list); needs that go round in a circle. It orders the plugins by what they need (the list's order
## breaking ties), applies their migrations after the platform's and before the app's, each
## recorded as `<plugin>/<name>`, makes the app's context (its `init!`), runs their `starts` with
## it (an `Err` stops the server), and logs a line a plugin saying what it added.
Plugin := [].{

	## A plugin. `context` is the app's context (its `init!`'s), which its calls, loops, starts and
	## checks are given; `ctx` is what the app's middleware hands a route (the signed-in user). It
	## knows the type of neither.
	Value(context, ctx) := {
		name : Str,
		routes : List(Route(ctx)) ?? [],
		early : List(Early) ?? [],
		files : List(File) ?? [],
		scripts : List(Str) ?? [],
		migrations : List(Migration) ?? [],
		calls : List(Call(context)) ?? [],
		loops : List(Loop(context)) ?? [],
		starts : List(Start(context)) ?? [],
		checks : List(Check(context)) ?? [],
		needs : List(Need) ?? [],
	}

	## A route, which answers once the app's middleware has passed the request on: what that
	## middleware handed on is `ctx`. Its `path` may have `[param]` segments, matched as the app's
	## are, and `request.route` is it. GET answers HEAD too; `*` any method. A `Page` or an
	## `Endpoint`, as the app's are.
	Route(ctx) : { method : Str, path : Str, kind : [Page, Endpoint], answer! : Server.Request, ctx => Server.Response }

	## A path the platform answers before the app, only when the server was started with one of
	## the flags in `under` (`--dev`, `--debug`): under `/__rocx/`, so the app's paths and its
	## middleware never meet it. Without the flag the path is the app's, as any other.
	Early : { method : Str, path : Str, under : List([Dev, Debug]), answer! : Server.Request => Server.Response }

	## A file the plugin serves as it is (a script, a service worker, an icon), its bytes embedded
	## when the app is built (`import "static/sw.js" as sw : List(U8)`): at
	## `/rocx/plugins/<plugin>/<path>`, or at `/<path>` when it is `at: Root`, for a file the web
	## fixes the place of (a service worker, whose scope is where it is; `.well-known/…`). The host
	## answers it before the app and its middleware, so an app's guard never blocks it: `GET` and
	## `HEAD`, with `content_type` and an ETag of its bytes (304 when the browser has them); any
	## other method, 405. `path` is relative (`push-sw.js`, `icons/bell.svg`).
	File : { path : Str, at : [Plugin, Root], content_type : Str, body : List(U8) }

	## A table: its SQL, applied once, recorded as `<plugin>/<name>`. `on` says which database it is
	## for (D-045): `Any` (the default), `Postgres` or `Sqlite` (Turso's too: its SQL is SQLite's,
	## D-046); the server applies those of its own, so a plugin that works with both lists one of
	## each under one name.
	Migration := { name : Str, sql : Str, on : [Any, Postgres, Sqlite] ?? Any }

	## A function the plugin runs in a call of its own (`Plugin.isolated!`), named
	## `<plugin>.<name>`, given the app's context and its input: its answer, or why it failed. A
	## crash in it ends that call only.
	Call(context) : { name : Str, run! : context, Str => Try(Str, Str) }

	## A background loop, named `<plugin>.<name>`, run on a call of its own when the server has
	## started, until it returns or the server stops (`Plugin.stopping!`); one that crashes starts
	## again a second later. It is given the app's context.
	Loop(context) : { name : Str, run! : context => {} }

	## Work done once the server has started, after every migration and the app's `init!`, in the
	## plugins' order, given the app's context: an `Err` stops the server, with why.
	Start(context) : context => Try({}, Str)

	## A look at something the plugin depends on (an SMTP server), named `<plugin>.<name>`, run once
	## in the background after the server has started: what it says is logged, an `Err` as a
	## warning. "" says nothing. A failing check doesn't stop the server. It is given the app's
	## context.
	Check(context) : { name : Str, run! : context => Try(Str, Str) }

	## What a plugin needs that the compiler can't see: an environment variable that is set; a
	## database, any (`Database`), or one flavor (`Postgres`, `Sqlite`: a package may work with one
	## alone, D-045; Turso meets `Sqlite`, D-046); another plugin in the app's list (which then comes
	## first).
	Need : [Env(Str), Database, Postgres, Sqlite, Plugin(Str)]

	## What the platform keeps of a plugin (`program.plugins`): all but its routes, which the app's
	## `respond!` answers (`Plugin.respond!`); their methods and paths, for the checks.
	Running(context) : {
		name : Str,
		claims : List({ method : Str, path : Str }),
		early : List(Early),
		files : List(File),
		scripts : List(Str),
		migrations : List(Migration),
		calls : List(Call(context)),
		loops : List(Loop(context)),
		starts : List(Start(context)),
		checks : List(Check(context)),
		needs : List(Need),
	}

	## What the platform keeps of `plugin`.
	running : Value(context, ctx) -> Running(context)
	running = |plugin| {
		name: plugin.name,
		claims: plugin.routes.map(|route| { method: route.method, path: route.path }),
		early: plugin.early,
		files: plugin.files,
		scripts: plugin.scripts,
		migrations: plugin.migrations,
		calls: plugin.calls,
		loops: plugin.loops,
		starts: plugin.starts,
		checks: plugin.checks,
		needs: plugin.needs,
	}

	## Where `file` of the plugin called `plugin` is served: `/rocx/plugins/<plugin>/<path>`, or
	## `/<path>` at the root.
	url : Str, File -> Str
	url = |plugin, file|
		match file.at {
			Plugin => "/rocx/plugins/${plugin}/${file.path}"
			Root => "/${file.path}"
		}

	## Answers `request` with the first plugin route that matches its method and path, given the
	## app's context; with `otherwise!` (the app's routes) when none does.
	respond! : List(Value(context, ctx)), Server.Request, ctx, (Server.Request, ctx => Server.Response) => Server.Response
	respond! = |plugins, request, context, otherwise!|
		match plugins.join_map(|plugin| plugin.routes).find_first(|route| method_matches(route.method, request.method) and Plugin.matches(route.path, request.path)) {
			Ok(route) => (route.answer!)(request, context)
			Err(_) => otherwise!(request, context)
		}

	## The path of the plugin route that answers `method` and `path` (`/admin/jobs`), for
	## `request.route`.
	pattern : List(Value(context, ctx)), Str, Str -> Try(Str, [NotFound])
	pattern = |plugins, method, path|
		match plugins.join_map(|plugin| plugin.routes).find_first(|route| method_matches(route.method, method) and Plugin.matches(route.path, path)) {
			Ok(route) => Ok(route.path)
			Err(_) => Err(NotFound)
		}

	## Whether `path` is one `pattern` stands for: segment by segment, a `[param]` one standing for
	## any one segment.
	matches : Str, Str -> Bool
	matches = |route_path, path| {
		wanted = route_path.split_on("/")
		given = path.split_on("/")
		if wanted.len() != given.len() {
			Bool.False
		} else {
			wanted.map_with_index(|segment, i| { segment, i }).all(|each| is_param(each.segment) or Ok(each.segment) == given.get(each.i))
		}
	}

	## Runs the call named `name` (`<plugin>.<name>`) with `input`, in a call of its own, within
	## `limit_ms` milliseconds (0: no limit): `Ok` with its answer, or why not: its `Err`, the crash
	## that ended it (`crashed: …`), or "timed out after …" (the first effect that waited past the
	## limit cut it off).
	isolated! : Str, Str, U64 => Try(Str, Str)
	isolated! = |name, input, limit_ms| {
		ran = Host.isolated!(name, input, limit_ms)
		match ran.status {
			0 => Ok(ran.out)
			1 => Err(ran.out)
			3 => Err(ran.out)
			_ => Err("crashed: ${ran.out}")
		}
	}

	## Whether the server is stopping: a loop's cue to end.
	stopping! : {} => Bool
	stopping! = |{}| Host.stopping!({})

	## Keeps `value` in the server's memory under `key` (the plugin's name first: `jobs:kinds`), for
	## its modules to read (`kept!`): what a plugin's `starts` keep of its options. Set a handful of
	## times, at start: each value set stays until the server stops.
	keep! : Str, Str => {}
	keep! = |key, value| Host.store_set!(key, value)

	## What `keep!` kept under `key`; `NotFound` if nothing was.
	kept! : Str => Try(Str, [NotFound])
	kept! = |key|
		match Host.store_get!(key) {
			Ok(value) => Ok(value)
			Err(_) => Err(NotFound)
		}
}

## Whether a route for `wanted` answers `method`.
method_matches : Str, Str -> Bool
method_matches = |wanted, method| wanted == "*" or wanted == method or (wanted == "GET" and method == "HEAD")

is_param : Str -> Bool
is_param = |segment| segment.starts_with("[") and segment.ends_with("]")

expect Plugin.matches("/admin/jobs", "/admin/jobs")
expect !Plugin.matches("/admin/jobs", "/admin/jobs/1")
expect Plugin.matches("/push/[id]", "/push/7")
expect !Plugin.matches("/push/[id]", "/push")
expect method_matches("GET", "HEAD")
expect Plugin.url("push", { path: "push.js", at: Plugin, content_type: "text/javascript", body: [] }) == "/rocx/plugins/push/push.js"
expect Plugin.url("push", { path: "push-sw.js", at: Root, content_type: "text/javascript", body: [] }) == "/push-sw.js"
expect !method_matches("POST", "GET")
