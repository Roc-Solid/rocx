## An app on the server platform whose database is SQLite (D-045), for its tests
## (`server/test/sqlite.test.mjs`): its file where its program says, or at `--database-url`;
## parameters bound as what they are, at their names; rows read into records (a column declared
## boolean, one declared json, a real, a null); transactions, and a script that fails; writes taking
## turns, and reads going on beside one; what is notified, heard once its transaction commits; a
## plugin's migrations for SQLite alone; an actor's state, kept; jobs (queued in a transaction or
## not, tried again, keyed, cancelled, moved, cut off past their time limit), cron, and the jobs page.
app [program] { pf: platform "../../platform/main.roc", admin: "../../../packages/admin/main.roc", jobs: "../../../packages/jobs/main.roc" }

import admin.Admin
import admin.AdminPage
import admin.JobsPage
import jobs.Cron
import jobs.Job
import pf.Actor
import pf.Db
import pf.Live
import pf.Middleware
import pf.Plugin
import pf.Random
import pf.Server
import pf.Time
import "migrations/0001_tables.sql" as tables : Str
import "migrations/0002_admin.sql" as admin_tables : Str

program = {
	respond!,
	# A file beside where the server starts, unless --database-url says `sqlite:<path>`.
	database: Sqlite("data/sqlite-test.db"),
	migrations: [{ name: "0001_tables.sql", sql: tables }, { name: "0002_admin.sql", sql: admin_tables }],
	actors: [Actor.handler(counter)],
	logs: { format: Auto },
	plugins: plugins.map(Plugin.running),
	routes: [],
}

## The jobs (packages/jobs), with a schedule each second and a short first retry; the jobs page
## (packages/admin), open to all; and a plugin that works with SQLite alone (`needs`), with a
## migration for each database (the server applies SQLite's) and one for any.
plugins : List(Plugin.Value(Str))
plugins = [
	Job.plugin(
		{
			jobs: [Job.handler(note_job), Job.handler(flaky_job), Job.handler(slow_job), Job.handler(tick_job)],
			crons: [Cron.every("* * * * * *", tick_job, {})],
			retry_ms: 20,
		},
	),
	JobsPage.plugin({ at: "/admin/jobs", guard: Middleware.make(|request, context, next!| next!(request, context)), back: { label: "Tests", href: "/" } }),
	{
		name: "lite",
		needs: [Sqlite],
		migrations: [
			{ name: "0001_lite", sql: "create table lite_only (x integer)", on: Sqlite },
			{ name: "0001_lite", sql: "create table pg_only (x bigserial)", on: Postgres },
			{ name: "0002_any", sql: "create table any_flavor (x integer)" },
		],
	},
]

counter : Actor.Kind({ count : I64 }, [Add(I64)], I64)
counter = Actor.define({
	name: "counter",
	initial: |_key| { count: 0 },
	receive!: |_me, state, message|
		match message {
			Add(by) => { state: { count: state.count + by }, reply: state.count + by },
		},
})

## A plugin's route, or the app's.
respond! : Server.Request, Str => Server.Response
respond! = |request, context| Plugin.respond!(plugins, { ..request, route: Plugin.pattern(plugins, request.method, request.path) ?? "" }, context, route!)

route! : Server.Request, Str => Server.Response
route! = |request, context| {
	query = request.query
	match (request.method, request.path) {
		("GET", "/flavor") =>
			text(
				200,
				match Db.backend!({}) {
					Postgres => "postgres"
					Sqlite => "sqlite"
					None => "none"
				},
			)

		# ---- Parameters, bound as what they are; rows, read into records ----
		("POST", "/items") => {
			note = param(query, "note")
			weight = param(query, "weight")
			added : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
			added = Db.all!(
				"insert into items (name, count, done, note, meta, weight) values ($1, $2, $3, $4, $5, $6) returning id",
				[
					Text(param(query, "name")),
					Int(I64.from_str(param(query, "count")) ?? 0),
					Bool(param(query, "done") == "yes"),
					if (note.is_empty()) Null else Text(note),
					Text("{\"tags\":[\"a\",\"b\"]}"),
					if (weight.is_empty()) Null else Text(weight),
				],
			)
			lines(added, |row| row.id.to_str())
		}
		("GET", "/items") => {
			found : Try(List({ id : I64, name : Str, count : I64, done : Bool, note : Db.Nullable(Str), meta : Db.Nullable({ tags : List(Str) }), weight : Db.Nullable(Dec) }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select id, name, count, done, note, meta, weight from items order by id", [])
			lines(found, |row| "${row.id.to_str()} ${row.name} ${row.count.to_str()} ${if (row.done) "done" else "open"} ${shown(row.note)} ${tagged(row.meta)} ${weighed(row.weight)}")
		}
		# `$2` before `$1`, and `$1` twice: each bound at its name.
		("GET", "/params/order") => {
			ordered : Try(List({ second : Str, first : Str, again : Str }), [DbErr(Str), BadRow(Str)])
			ordered = Db.all!("select $2 as second, $1 as first, $1 as again", [Text("a"), Text("b")])
			lines(ordered, |row| "${row.second} ${row.first} ${row.again}")
		}
		# What each parameter is, in SQLite: an Int and a Bool are integers, a Text text.
		("GET", "/params/types") => {
			typed : Try(List({ i : Str, b : Str, t : Str, n : Str }), [DbErr(Str), BadRow(Str)])
			typed = Db.all!("select typeof($1) as i, typeof($2) as b, typeof($3) as t, typeof($4) as n", [Int(7), Bool(Bool.True), Text("7"), Null])
			lines(typed, |row| "${row.i} ${row.b} ${row.t} ${row.n}")
		}
		("GET", "/params/missing") => {
			missing : Try(List({ x : Str }), [DbErr(Str), BadRow(Str)])
			missing = Db.all!("select $2 as x", [Text("a")])
			lines(missing, |row| row.x)
		}
		("GET", "/params/unused") => {
			unused : Try(List({ x : Str }), [DbErr(Str), BadRow(Str)])
			unused = Db.all!("select $1 as x", [Text("a"), Text("b")])
			lines(unused, |row| row.x)
		}
		# A boolean SQLite works out is 0 or 1: an `I64`.
		("GET", "/exists") => {
			exists : Try(List({ found : I64 }), [DbErr(Str), BadRow(Str)])
			exists = Db.all!("select exists (select 1 from items where name = $1) as found", [Text(param(query, "name"))])
			lines(exists, |row| row.found.to_str())
		}
		# How many rows a statement changed (`run!`): an update's, none for a table made.
		("POST", "/changed") => {
			made = Db.run!("create table if not exists scratch (x integer)", []) ?? 99
			updated = Db.run!("update items set count = count + 1 where name = $1", [Text(param(query, "name"))]) ?? 99
			text(200, "${made.to_str()} ${updated.to_str()}")
		}

		# ---- Transactions, and a script that fails ----
		("POST", "/tx") => {
			name = param(query, "name")
			failing = param(query, "fail") == "yes"
			outcome = Db.transaction!(
				|{}| {
					_ = Db.run!("insert into items (name) values ($1)", [Text(name)])?
					if failing Err(DbErr("on purpose")) else Ok({})
				},
			)
			match outcome {
				Ok({}) => text(200, "committed")
				Err(DbErr(why)) => text(200, "rolled back: ${why}")
			}
		}
		("POST", "/script/bad") =>
			match Db.script!("insert into counters (name, value) values ('half', 1); insert into nowhere values (1)") {
				Ok({}) => text(200, "ran")
				Err(DbErr(why)) => text(200, "failed: ${why}")
			}
		("GET", "/counters") => {
			named : Try(List({ name : Str, value : I64 }), [DbErr(Str), BadRow(Str)])
			named = Db.all!("select name, value from counters order by name", [])
			lines(named, |row| "${row.name}=${row.value.to_str()}")
		}

		# ---- Writes take turns; reads go on beside one ----
		# Reads the counter, waits `ms`, writes it back one more: in a transaction, which holds the
		# write lock from its start, so many at once each see the one before.
		("POST", "/bump") => {
			pause = number(query, "ms")
			bumped = Db.transaction!(
				|{}| {
					now : List({ value : I64 })
					now = Db.all!("select value from counters where name = 'hits'", [])?
					was =
						match now.get(0) {
							Ok(row) => row.value
							Err(_) => 0
						}
					if pause > 0 {
						_ = Live.next!(pause)
						{}
					}
					_ = Db.run!("update counters set value = $1 where name = 'hits'", [Int(was + 1)])?
					Ok(was + 1)
				},
			)
			match bumped {
				Ok(value) => text(200, value.to_str())
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("GET", "/count") => {
			counted : Try(List({ n : I64 }), [DbErr(Str), BadRow(Str)])
			counted = Db.all!("select count(*) as n from items", [])
			lines(counted, |row| row.n.to_str())
		}

		# ---- What is notified: heard once its transaction commits, never if it rolls back ----
		("GET", "/listen") =>
			match Db.listen!("pings") {
				Err(DbErr(why)) => text(500, why)
				Ok({}) => {
					until = Time.now_millis!({}) + number(query, "ms")
					var $heard = []
					var $going = Bool.True
					while $going {
						now = Time.now_millis!({})
						if now >= until {
							$going = Bool.False
						} else {
							match Live.next!(until - now) {
								Heard(said) => {
									$heard = $heard.append(said.message)
								}
								_ => {}
							}
						}
					}
					text(200, Str.join_with($heard, ","))
				}
			}
		("POST", "/notify") => {
			payload = param(query, "payload")
			match param(query, "mode") {
				"outside" => notified(Db.notify!("pings", payload))
				"commit" => notified(Db.transaction!(|{}| Db.notify!("pings", payload)))
				"rollback" =>
					notified(
						Db.transaction!(
							|{}| {
								_ = Db.notify!("pings", payload)?
								Err(DbErr("rolled back on purpose"))
							},
						),
					)
				"crash" =>
					notified(
						Db.transaction!(
							|{}| {
								_ = Db.notify!("pings", payload)?
								if payload != "" crash "a crash in a transaction" else Ok({})
							},
						),
					)
				_ => text(400, "which mode?")
			}
		}

		# ---- The schema: the app's, the platform's, and the plugin's for SQLite ----
		("GET", "/tables") => {
			named : Try(List({ name : Str }), [DbErr(Str), BadRow(Str)])
			named = Db.all!("select name from sqlite_master where type = 'table' and name not like 'sqlite_%' order by name", [])
			lines(named, |row| row.name)
		}
		("GET", "/migrated") => {
			named : Try(List({ name : Str }), [DbErr(Str), BadRow(Str)])
			named = Db.all!("select name from rocx_migrations order by name", [])
			lines(named, |row| row.name)
		}

		# ---- An actor's state, kept in the database ----
		("POST", "/actors/add") =>
			match Actor.ask!(counter, param(query, "key"), Add(1)) {
				Ok(count) => text(200, count.to_str())
				Err(ActorErr(why)) => text(500, why)
			}

		# ---- Jobs ----
		("POST", "/jobs/note") => enqueued(Job.enqueue!(note_job, { said: param(query, "said") }, { when: Now }))
		# Queued in a transaction: there only if it commits.
		("POST", "/jobs/note-tx") => {
			failing = param(query, "fail") == "yes"
			said = param(query, "said")
			outcome = Db.transaction!(
				|{}| {
					Job.enqueue!(note_job, { said: said }, { when: Now })?
					if failing Err(JobErr("on purpose")) else Ok({})
				},
			)
			match outcome {
				Ok({}) => text(200, "committed")
				Err(JobErr(why)) => text(200, "rolled back: ${why}")
				Err(DbErr(why)) => text(500, why)
			}
		}
		("POST", "/jobs/flaky") => enqueued(Job.enqueue!(flaky_job, { name: param(query, "name"), fails: I64.from_str(param(query, "fails")) ?? 0 }, { when: Now }))
		("POST", "/jobs/slow") => enqueued(Job.enqueue!(slow_job, { said: param(query, "said") }, { when: Now }))
		# Keyed, `in_ms` from now: `Queued`, or `Exists` while one with the key is pending.
		("POST", "/jobs/keyed") => {
			due = Time.now_millis!({}) + number(query, "in_ms")
			match Job.enqueue_keyed!(note_job, { said: param(query, "said") }, { when: At(due), key: param(query, "key") }) {
				Ok(Queued) => text(200, "queued")
				Ok(Exists) => text(200, "exists")
				Err(JobErr(why)) => text(500, why)
			}
		}
		("POST", "/jobs/cancel") => counted(Job.cancel!(param(query, "key")))
		("POST", "/jobs/move") => counted(Job.move!(param(query, "key"), Now))
		("POST", "/jobs/retry") =>
			match Job.retry!(I64.from_str(param(query, "id")) ?? 0) {
				Ok({}) => text(200, "retried")
				Err(NotFound) => text(404, "no such job")
				Err(JobErr(why)) => text(409, why)
			}
		("GET", "/jobs/log") => {
			logged : Try(List({ kind : Str, said : Str }), [DbErr(Str), BadRow(Str)])
			logged = Db.all!("select kind, said from job_log where kind <> 'tick' order by id", [])
			lines(logged, |row| "${row.kind} ${row.said}")
		}
		("GET", "/jobs/ticks") => {
			ticks : Try(List({ n : I64 }), [DbErr(Str), BadRow(Str)])
			ticks = Db.all!("select count(*) as n from job_log where kind = 'tick'", [])
			lines(ticks, |row| row.n.to_str())
		}
		# The queue, as `Job.list!` reads it: `id kind state attempts`, newest first, and `last_error`.
		("GET", "/jobs/list") =>
			match Job.list!({ state: param(query, "state"), kind: param(query, "kind"), before_id: 0, limit: 0 }) {
				Ok(rows) => text(200, Str.join_with(rows.map(|row| "${row.id.to_str()} ${row.kind} ${row.state} ${row.attempts.to_str()} ${shown(row.last_error)}"), "\n"))
				Err(JobErr(why)) => text(500, why)
			}
		("GET", "/jobs/counts") =>
			match Job.counts!({}) {
				Ok(rows) => text(200, Str.join_with(rows.map(|row| "${row.kind} ${row.state} ${row.count.to_str()}"), "\n"))
				Err(JobErr(why)) => text(500, why)
			}
		# packages/admin's tables admin, on the app's SQLite.
		(_, "/admin/db") => AdminPage.respond!(request, context, db_admin, { all!: Db.all!, run!: Db.run!, random!: Random.bytes!, backend!: Db.backend! })
		_ => text(404, "no such route")
	}
}

## packages/admin's tables admin at /admin/db (`server/test/admin-checks.mjs`), open to all: an
## author, and books with a foreign key, a check that is a choice, a boolean, a number and JSON.
db_admin : Admin.Config(Str)
db_admin = {
	mount: "/admin/db",
	access: |_| Edit,
	tables: [
		{ name: "admin_books", list: ["id", "title", "author_id", "state", "done", "price"], search: ["title"] },
		{ name: "admin_authors", title: "name" },
	],
}

text : U16, Str -> Server.Response
text = |status, body| Server.response(status, [{ name: "content-type", value: "text/plain; charset=utf-8" }], body)

## Each row, as `line` says, a line each; or the error, a 500.
lines : Try(List(row), [DbErr(Str), BadRow(Str)]), (row -> Str) -> Server.Response
lines = |rows, line|
	match rows {
		Ok(found) => text(200, Str.join_with(found.map(line), "\n"))
		Err(DbErr(why)) => text(500, why)
		Err(BadRow(why)) => text(500, why)
	}

enqueued : Try({}, [JobErr(Str)]) -> Server.Response
enqueued = |result|
	match result {
		Ok({}) => text(200, "queued")
		Err(JobErr(why)) => text(500, why)
	}

counted : Try(U64, [JobErr(Str)]) -> Server.Response
counted = |result|
	match result {
		Ok(count) => text(200, count.to_str())
		Err(JobErr(why)) => text(500, why)
	}

## Writes what it was given to the job log.
note_job : Job.Kind({ said : Str })
note_job = Job.define(
	"note",
	|{ said }|
		match Db.run!("insert into job_log (kind, said) values ('note', $1)", [Text(said)]) {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		},
)

## Fails `fails` times, then writes to the job log.
flaky_job : Job.Kind({ name : Str, fails : I64 })
flaky_job = Job.define(
	"flaky",
	|{ name, fails }| {
		tried : Try(List({ tries : I64 }), [DbErr(Str), BadRow(Str)])
		tried = Db.all!("insert into flaky (name, tries) values ($1, 1) on conflict (name) do update set tries = tries + 1 returning tries", [Text(name)])
		match tried {
			Ok([{ tries }]) if tries <= fails => Err("not yet (try ${tries.to_str()})")
			Ok(_) =>
				match Db.run!("insert into job_log (kind, said) values ('flaky', $1)", [Text("${name} done")]) {
					Ok(_) => Ok({})
					Err(DbErr(why)) => Err(why)
				}
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
		}
	},
)

## Writes to the job log in a transaction, then counts for far longer than its 300 ms: cut off, its
## statement interrupted, its transaction rolled back with its connection. Tried once.
slow_job : Job.Kind({ said : Str })
slow_job = Job.define_with(
	"slow",
	{ attempts: 1, timeout_ms: 300 },
	|{ said }| {
		counted_up = Db.transaction!(
			|{}| {
				_ = Db.run!("insert into job_log (kind, said) values ('slow', $1)", [Text(said)])?
				many : List({ n : I64 })
				many = Db.all!("with recursive c(x) as (select 1 union all select x + 1 from c where x < 1000000000) select count(*) as n from c", [])?
				Ok(many)
			},
		)
		match counted_up {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
		}
	},
)

## The schedule's job: a tick in the job log.
tick_job : Job.Kind({})
tick_job = Job.define(
	"tick",
	|{}|
		match Db.run!("insert into job_log (kind, said) values ('tick', 'tick')", []) {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		},
)

notified : Try({}, [DbErr(Str)]) -> Server.Response
notified = |result|
	match result {
		Ok({}) => text(200, "notified")
		Err(DbErr(why)) => text(200, why)
	}

shown : Db.Nullable(Str) -> Str
shown = |note|
	match note {
		Null => "-"
		Some(said) => said
	}

tagged : Db.Nullable({ tags : List(Str) }) -> Str
tagged = |meta|
	match meta {
		Null => "-"
		Some(read) => Str.join_with(read.tags, "+")
	}

weighed : Db.Nullable(Dec) -> Str
weighed = |weight|
	match weight {
		Null => "-"
		Some(kg) => kg.to_str()
	}

## A query's parameter (`name=a&count=2`), or "".
param : Str, Str -> Str
param = |query, name| {
	var $found = ""
	for pair in query.split_on("&") {
		match pair.split_first("=") {
			Ok({ before: key, after: value }) =>
				if key == name {
					$found = Server.decode_segment(value)
				} else {
					{}
				}
			Err(_) => {}
		}
	}
	$found
}

number : Str, Str -> U64
number = |query, name| U64.from_str(param(query, name)) ?? 0
