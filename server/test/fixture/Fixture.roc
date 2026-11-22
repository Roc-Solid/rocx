import pf.Db
import pf.Kv
import pf.Plugin
import pf.Server
import "migrations/0001_notes.sql" as notes : Str

## Plugins for the tests: `plugin` adds what a plugin can (a route that shows the app's context, an
## early path under `--dev`, a table, a call, a loop, a start, a check, and a need); `second` and
## `third` a route each, `third` needing `second`, so the order they start in isn't the list's.
Fixture := [].{

	## Where the fixture's routes are, and how it shows the app's context.
	Options(ctx) := { at : Str ?? "/fixture", shown : ctx -> Str }

	plugin : Options(ctx) -> Plugin.Value(ctx)
	plugin = |options| {
		at = options.at
		shown = options.shown
		{
			name: "fixture",
			routes: [
				{ method: "GET", path: "${at}/context", kind: Endpoint, answer!: |request, context| text("${request.route}: ${shown(context)}") },
				{ method: "GET", path: "${at}/notes/[id]", kind: Endpoint, answer!: |request, _| text("note ${request.path.drop_prefix("${at}/notes/")} at ${request.route}") },
				{ method: "GET", path: "${at}/shout", kind: Endpoint, answer!: |request, _| shout!(request) },
				{ method: "GET", path: "${at}/state", kind: Endpoint, answer!: |_, _| state!({}) },
				{ method: "GET", path: "${at}/migrated", kind: Endpoint, answer!: |_, _| migrated!({}) },
			],
			early: [{ method: "GET", path: "/__rocx/fixture", under: [Dev], answer!: |request| text("early ${request.route}") }],
			migrations: [{ name: "0001_notes", sql: notes }],
			calls: [{ name: "fixture.shout", run!: |input| if (input == "crash") crash "the fixture's call crashed" else Ok(input.with_ascii_uppercased()) }],
			loops: [{ name: "fixture.beat", run!: beat! }],
			starts: [start!],
			checks: [{ name: "fixture.look", run!: |{}| Ok("the fixture looked") }],
			needs: [Env("FIXTURE_KEY")],
		}
	}

	## A plugin with one route. (A plugin that is generic in the app's context is a function, even
	## with no options: a value can only have one type.)
	second : {} -> Plugin.Value(ctx)
	second = |{}| { name: "second", routes: [{ method: "GET", path: "/second", kind: Page, answer!: |_, _| text("second") }] }

	## A plugin with one route, which needs `second`.
	third : {} -> Plugin.Value(ctx)
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
