import pf.Db
import pf.Kv
import pf.Middleware
import pf.Plugin
import pf.Server
import "migrations/0001_notes.sql" as notes : Str
import "static/fixture.js" as fixture_js : List(U8)
import "static/fixture-sw.js" as fixture_sw : List(U8)

## Plugins for the tests: `plugin` adds what a plugin can (routes behind the middleware the app
## gives it, D-114, one showing what that handed on from the app's context, an
## early path under `--dev`, files, one at the root and one a script every page loads, a table, a
## call, a loop, a start, a check, and a need); `second` and `third` a route each, `third` needing
## `second`, so the order they start in isn't the list's; `files` files alone, for an app whose
## every answer is a refusal.
Fixture := [].{

	## What the fixture's routes are behind (`middleware`, the app's to say), where they are, and how
	## it shows what the middleware handed on.
	Options(context, ctx) := { middleware : Middleware(context, ctx), at : Str ?? "/fixture", shown : ctx -> Str }

	plugin : Options(context, ctx) -> Plugin.Value(context)
	plugin = |options| {
		at = options.at
		shown = options.shown
		{
			name: "fixture",
			routes: Plugin.behind(
				options.middleware,
				[
					{ method: "GET", path: "${at}/context", kind: Endpoint, answer!: |request, handed| text("${request.route}: ${shown(handed)}") },
					{ method: "GET", path: "${at}/notes/[id]", kind: Endpoint, answer!: |request, _| text("note ${request.path.drop_prefix("${at}/notes/")} at ${request.route}") },
					{ method: "GET", path: "${at}/shout", kind: Endpoint, answer!: |request, _| shout!(request) },
					{ method: "GET", path: "${at}/state", kind: Endpoint, answer!: |_, _| state!({}) },
					{ method: "GET", path: "${at}/migrated", kind: Endpoint, answer!: |_, _| migrated!({}) },
				],
			),
			early: [{ method: "GET", path: "/__rocx/fixture", under: [Dev], answer!: |request| text("early ${request.route}") }],
			files: Fixture.files_of("fixture"),
			scripts: ["fixture.js"],
			migrations: [{ name: "0001_notes", sql: notes }],
			calls: [{ name: "fixture.shout", run!: |_context, input| if (input == "crash") crash "the fixture's call crashed" else Ok(input.with_ascii_uppercased()) }],
			loops: [{ name: "fixture.beat", run!: |_context| beat!({}) }],
			starts: [|_context| start!({})],
			checks: [{ name: "fixture.look", run!: |_context| Ok("the fixture looked") }],
			needs: [Env("FIXTURE_KEY")],
		}
	}

	## The fixture's files: a script, at `/rocx/plugins/<name>/fixture.js`, and a service worker at
	## the root, `/<name>-sw.js`.
	files_of : Str -> List(Plugin.File)
	files_of = |name| [
		{ path: "fixture.js", at: Plugin, content_type: "text/javascript", body: fixture_js },
		{ path: "${name}-sw.js", at: Root, content_type: "text/javascript", body: fixture_sw },
	]

	## A plugin of files alone, called `name`: its script (which every page loads) and its file at
	## the root.
	files : Str -> Plugin.Value(context)
	files = |name| { name, files: Fixture.files_of(name), scripts: ["fixture.js"] }

	## A plugin with one route. (A plugin that is generic in the app's context is a function, even
	## with no options: a value can only have one type.)
	second : {} -> Plugin.Value(context)
	second = |{}| { name: "second", routes: [{ method: "GET", path: "/second", kind: Page, answer!: |_, _| text("second") }] }

	## A plugin with one route, which needs `second`.
	third : {} -> Plugin.Value(context)
	third = |{}| { name: "third", routes: [{ method: "*", path: "/third", kind: Endpoint, answer!: |request, _| text("third ${request.method}") }], needs: [Plugin("second")] }
}

## The loop: counts once, and is done.
beat! : {} => {}
beat! = |{}| {
	_ = Kv.increment!("fixture:beats", 1, {})
	{}
}

## The start: keeps that it ran, for `state!`.
start! : {} => Try({}, Str)
start! = |{}| {
	Plugin.keep!("fixture:started", "started")
	Ok({})
}

text : Str -> Server.Response
text = |body| Server.response(200, [{ name: "content-type", value: "text/plain; charset=utf-8" }], body)

shout! : Server.Request => Server.Response
shout! = |request| {
	word = request.query.drop_prefix("word=")
	match Plugin.isolated!("fixture.shout", word, 0) {
		Ok(said) => text(said)
		Err(why) => Server.response(500, [], why)
	}
}

state! : {} => Server.Response
state! = |{}| {
	beats : Try(I64, [NotFound, BadValue(Str)])
	beats = Kv.get!("fixture:beats")
	started = Plugin.kept!("fixture:started") ?? "not started"
	text("${started}, ${(beats ?? 0).to_str()} beat")
}

migrated! : {} => Server.Response
migrated! = |{}| {
	found : Try(List({ name : Str }), [DbErr(Str), BadRow(Str)])
	found = Db.all!("select name from rocx_migrations where name like 'fixture/%' order by name", [])
	match found {
		Ok(rows) => text(Str.join_with(rows.map(|row| row.name), ","))
		Err(DbErr(why)) => Server.response(500, [], why)
		Err(BadRow(why)) => Server.response(500, [], why)
	}
}
