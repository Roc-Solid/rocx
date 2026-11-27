import pf.Db
import pf.Kv
import pf.Plugin
import pf.Server
import "migrations/0001_notes.sql" as notes : Str
import "static/fixture.js" as fixture_js : List(U8)
import "static/fixture-sw.js" as fixture_sw : List(U8)

## Plugins for the tests: `plugin` adds what a plugin can (no routes, D-116: its handlers are the
## app's to call from routes of its own, `shout_route!` and the rest; an
## early path under `--dev`, files, one at the root and one a script every page loads, a table, a
## call, a loop, a start, a check, and a need); `second` and `third` a route each, `third` needing
## `second`, so the order they start in isn't the list's; `files` files alone, for an app whose
## every answer is a refusal.
Fixture := [].{

	plugin : {} -> Plugin.Value(context)
	plugin = |{}| {
		{
			name: "fixture",
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

	## A plugin with nothing but its name. (A plugin that is generic in the app's context is a
	## function, even with no options: a value can only have one type.)
	second : {} -> Plugin.Value(context)
	second = |{}| { name: "second" }

	## A plugin that needs `second`.
	third : {} -> Plugin.Value(context)
	third = |{}| { name: "third", needs: [Plugin("second")] }

	## The fixture's call (`fixture.shout`), run in a call of its own with `?word=`: its answer, or
	## why it failed (a crash, with `crash`). For a route of the app's (D-116).
	shout_route! : Server.Request => Server.Response
	shout_route! = |request| shout!(request)

	## What the fixture's start and loop did. For a route of the app's.
	state_route! : Server.Request => Server.Response
	state_route! = |_| state!({})

	## Which migrations of the fixture's were applied. For a route of the app's.
	migrated_route! : Server.Request => Server.Response
	migrated_route! = |_| migrated!({})
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
