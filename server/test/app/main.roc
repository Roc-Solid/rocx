## A small app on the server platform, for its tests (`server/test/server.test.mjs`): a page, a
## crash and an overflow, bytes each way, streams of events, Postgres and its transactions, jobs
## (with attempts, time limits and keys, listed and acted on, and the jobs page behind a guard) and
## cron, email, live topics and rooms, actors, pages of components, with the endpoints they read
## answered by their routes, requests to other servers, the environment, AES-GCM, random
## bytes, the crypto written in Roc (packages/crypto), files in storage (packages/storage), and cookies; and what the docs show of them
## (`Samples.roc`), as an app would write it.
app [program] { pf: platform "../../platform/main.roc", admin: "../../../packages/admin/main.roc", crypto: "../../../packages/crypto/main.roc", email: "../../../packages/email/main.roc", fixture: "../fixture/main.roc", guard: "../../../packages/guard/main.roc", jobs: "../../../packages/jobs/main.roc", storage: "../../../packages/storage/main.roc" }

import crypto.Base64
import crypto.Hex
import crypto.Hkdf
import crypto.Hmac
import crypto.Sha256
import storage.Storage
import fixture.Fixture
import guard.Security
import jobs.Cron
import jobs.Job
import admin.Admin
import admin.AdminPage
import admin.JobsPage
import email.Email
import pf.Actor
import pf.AesGcm
import pf.Db
import pf.Env
import pf.Http
import pf.HttpResponse
import pf.Kv
import pf.Live
import pf.Log
import pf.Random
import pf.Tcp
import pf.Time
import pf.Html
import pf.Solid
import pf.For
import pf.Errored
import pf.Loading
import pf.HttpStatusCode
import pf.Context
import pf.Server
import pf.Endpoint
import pf.Channel
import pf.Middleware
import pf.Plugin
import pf.Events
import pf.Router
import Samples
import "migrations/0001_tables.sql" as tables : Str
import "migrations/0002_note_index.sql" as note_index : Str
import "migrations/0003_admin.sql" as admin_tables : Str

program = {
	# The context is what the server was started with (`--context-file`), as it was before `init!`.
	init!: |started| Ok(started),
	respond!,
	# The app's database (D-045): Postgres, at --database-url.
	database: Postgres,
	# The app's schema, in the executable: applied once each, in order, when the server starts.
	migrations: [{ name: "0001_tables.sql", sql: tables }, { name: "0002_note_index.sql", sql: note_index }, { name: "0003_admin.sql", sql: admin_tables }],
	# The actors' methods (`rocx build` lists them for an app it builds).
	actors: [Actor.handler(Counter.add), Actor.handler(Counter.get), Actor.handler(Counter.boom), Actor.handler(Counter.nap), Actor.handler(Mirror.relay), Actor.handler(Mirror.itself), Actor.handler(Mirror.cycle), Actor.handler(Bouncer.back), Actor.handler(Ticker.start), Actor.handler(Ticker.tick({})), Actor.handler(Ticker.stop), Actor.handler(Ticker.ticks)],
	# The log's format: `ROCX_LOG` if it's set, or else pretty on a terminal and JSON elsewhere.
	logs: { format: Auto },
	# The plugins (`plugins`): their routes answer in `respond!` (`Plugin.respond!`), the platform
	# runs the rest.
	plugins: plugins.map(Plugin.running),
	routes: [],
}

## The plugins. The jobs (packages/jobs): the kinds its workers run, a schedule, and a short first
## retry (20 ms), so the tests see retries soon. Email (packages/email). The jobs page
## (packages/admin). A plugin package's
## (server/test/fixture): the
## fixture's routes show the server's context as the app has it; `third` needs `second`, so it
## starts after it.
plugins : List(Plugin.Value(Str, Str))
plugins = [
	Job.plugin(
		{
			jobs: [Job.handler(note_job), Job.handler(flaky_job), Job.handler(crash_job), Job.handler(mail_job), Job.handler(tick_job), Job.handler(env_job), Job.handler(twice_job), Job.handler(slow_job)],
			crons: [Cron.every("* * * * * *", tick_job, {})],
			retry_ms: 20,
		},
	),
	# Email (packages/email): SMTP_URL and MAIL_FROM from the environment, the dev mailbox under --dev.
	Email.plugin({}),
	# The jobs page (packages/admin), behind a guard of the app's own, with a link back to the app.
	JobsPage.plugin({ at: "/admin/jobs", guard: admins_only, back: { label: "Acme Tests", href: "/" } }),
	Fixture.plugin({ shown: |context| "the app's context, ${context}" }),
	Fixture.third({}),
	Fixture.second({}),
	# The signed URLs of a file: or memory: bucket (packages/storage), the app's to answer.
	Storage.plugin({}),
]

## Lists as parameters (`Db.array`), against Postgres, as JSON: text and bigint arrays with `= any`,
## `@>` and `unnest`, text with every character an array's syntax has, nulls, booleans, an empty
## list, and what Postgres says of `unnest($1)` with no cast.
arrays! : {} => Try(Str, [DbErr(Str), BadRow(Str)])
arrays! = |{}| {
	awkward = [Text("plain"), Text("two words"), Text("a,b"), Text("{braces}"), Text("say \"hi\""), Text("back\\slash"), Text(""), Text("NULL"), Text("zażółć ✓ 日本")]
	unnested : Try(List({ i : I64, v : Db.Nullable(Str) }), [DbErr(Str), BadRow(Str)])
	unnested = Db.all!("select i, v from unnest($1::text[]) with ordinality as t(v, i) order by i", [Db.array(awkward.append(Null))])
	found : Try(List({ v : Str }), [DbErr(Str), BadRow(Str)])
	found = Db.all!("select v from (values ('two words'), ('a,b'), ('nope'), ('back\\slash'), ('')) as t(v) where v = any($1) order by v", [Db.array(awkward)])
	contains : Try(List({ yes : Bool, no : Bool }), [DbErr(Str), BadRow(Str)])
	contains = Db.all!(
		"select array['two words', 'a,b', 'say \"hi\"']::text[] @> $1 as yes, array['two words']::text[] @> $2 as no",
		[Db.array([Text("a,b"), Text("say \"hi\"")]), Db.array([Text("two words"), Text("two")])],
	)
	numbers : Try(List({ total : I64, nulls : I64, hit : Bool, miss : Bool, holds : Bool }), [DbErr(Str), BadRow(Str)])
	numbers = Db.all!(
		"select (select sum(x)::int8 from unnest($1::int8[]) as x) as total, (select count(*)::int8 from unnest($1::int8[]) as x where x is null) as nulls, 5::int8 = any($2) as hit, 6::int8 = any($2) as miss, array[1, 2, 3]::int8[] @> $3 as holds",
		[Db.array([Int(1), Int(-2), Int(40_000_000_000), Null]), Db.array([Int(4), Int(5)]), Db.array([Int(3), Int(1)])],
	)
	flags : Try(List({ all : Bool, count : I64 }), [DbErr(Str), BadRow(Str)])
	flags = Db.all!("select bool_and(b) as all, count(*)::int8 as count from unnest($1::bool[]) as b", [Db.array([Bool(Bool.True), Bool(Bool.False)])])
	empty : Try(List({ n : I64, none : Bool }), [DbErr(Str), BadRow(Str)])
	empty = Db.all!("select cardinality($1::text[])::int8 as n, not ('x' = any($1::text[])) as none", [Db.array([])])
	uncast : Try(List({ x : Str }), [DbErr(Str), BadRow(Str)])
	uncast = Db.all!("select x from unnest($1) as x", [Db.array([Text("a")])])
	said =
		match uncast {
			Ok(_) => "read"
			Err(DbErr(why)) => why
			Err(BadRow(why)) => why
		}
	Ok(Json.to_str({ unnested: unnested?, found: found?.map(|row| row.v), contains: contains?, numbers: numbers?, flags: flags?, empty: empty?, uncast: said }))
}

respond! : Server.Request, Str => Server.Response
respond! = |request, context| {
	# The host's asks about a channel's subscriptions (`/rocx/live`), as `App.program` and
	# `Generated/Routes` answer them: a subscription's end outside any middleware, the rest behind it.
	asked = Endpoint.channel_asked(request)
	if asked == "close" {
		channel_closed!(request)
	} else if asked != "" {
		channel!(request)
	} else {
		# A page view lets a plain form's flash go, as `App.program` does. A plugin's route first.
		Server.clear_flash(request, Plugin.respond!(plugins, { ..request, route: Plugin.pattern(plugins, request.method, request.path) ?? "" }, context, route!))
	}
}

text : U16, Str -> Server.Response
text = |status, body| Server.response(status, [{ name: "content-type", value: "text/plain; charset=utf-8" }], body)

## A query's parameter (`run=abc&fails=2`), or "".
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

## What's after `prefix` in `path`, or "".
after : Str, Str -> Str
after = |path, prefix|
	match path.split_first(prefix) {
		Ok({ before: "", after: rest }) => rest
		_ => ""
	}

## The answer to a `Try` whose error is a message.
answered : Try(Str, Str) -> Server.Response
answered = |result|
	match result {
		Ok(said) => text(200, said)
		Err(why) => text(500, why)
	}

route! : Server.Request, Str => Server.Response
route! = |request, context| {
	run = param(request.query, "run")
	match (request.method, request.path) {
		("GET", "/") => text(200, "Hello from Roc, natively.")
		# packages/admin's tables admin, on the app's Postgres.
		(_, "/admin/db") => AdminPage.respond!(request, context, db_admin, { all!: Db.all!, run!: Db.run!, random!: Random.bytes!, backend!: Db.backend! })
		("GET", "/context") => text(200, context)
		("GET", "/echo") => text(200, "${request.method} ${request.path}?${request.query} ${Server.text_of(request)}")
		# ---- The connection's address, as the host hands it over, and as `Server.request!` reads it again ----
		("GET", "/peer") => text(200, "${request.peer} ${Server.request!({}).peer}")
		("GET", "/peer-json") => Server.response(200, [{ name: "content-type", value: "application/json" }], "\"${request.peer}\"")
		(_, "/peer-page") => { status: 200, headers: [{ name: "x-page", value: "yes" }], body: Page(peer_page!) }
		("POST", "/echo") => text(200, "${request.method} ${request.path} ${Server.text_of(request)}")
		# ---- Bytes: a request's body as it came; an answer of bytes ----
		("POST", "/bytes/echo") => Server.bytes(200, [{ name: "content-type", value: "application/octet-stream" }], request.body)
		("POST", "/bytes/sha") => text(200, "${request.body.len().to_str()} ${Sha256.hex(request.body)}")
		(_, "/bytes/counting") => Server.bytes(200, [{ name: "content-type", value: "application/octet-stream" }], counting(number(request.query, "size")))
		# ---- An endpoint's body: read as JSON or a form, or left as it came for its handler ----
		(_, "/endpoint/upload") => Endpoint.respond!(upload_endpoint, request, {})
		(_, "/endpoint/shout") => Endpoint.respond!(shout_endpoint, request, {})
		(_, "/endpoint/order") => Endpoint.respond!(order_endpoint, request, {})
		(_, "/endpoint/photo") => Endpoint.respond!(photo_endpoint, request, {})
		(_, "/endpoint/order-json") => Endpoint.respond!(order_json_endpoint, request, {})

		# ---- Forward: a body the host fetches from `url` and sends on, never through Roc ----
		(_, "/forward") => {
			method = param(request.query, "method")
			# The request's range and cache questions, passed on (`bare=1`: none, whatever it sent).
			passed = if (param(request.query, "bare") == "1") [] else Server.passed_on(request)
			upstream = { method: if (method.is_empty()) "GET" else method, url: param(request.query, "url"), headers: [{ name: "x-rocx", value: "yes" }].concat(passed) }
			Server.forward(upstream, [{ name: "content-type", value: "video/mp4" }, { name: "cache-control", value: "private, max-age=60" }, { name: "set-cookie", value: "seen=1" }])
		}
		("GET", "/crash") => crash "on purpose"
		("GET", "/overflow") => {
			# A U64 below zero: Roc crashes rather than wrap.
			taken : U64
			taken = request.query.to_utf8().len()
			text(200, (0.U64 - taken).to_str())
		}
		("GET", "/big") => {
			# Allocates a lot, then crashes: the host frees what the call held.
			rows = strings(2000 + request.query.to_utf8().len(), [])
			if (rows.len() > 10) crash "after allocating ${rows.len().to_str()} strings" else text(200, "")
		}
		("GET", "/now") => text(200, Time.now_millis!({}).to_str())
		("GET", "/log") => {
			Log.line!("a line from Roc")
			text(200, "logged")
		}
		# ---- The log: events with fields, at each level ----
		("GET", "/log/fields") => {
			Log.info!("an event from Roc", { path: request.path, count: 3.U64, ok: Bool.True, note: "two words", msg: "not the message", level: "not the level" })
			# One field: `{ run }` alone would be a block (`run`), not a record.
			Log.warn!("a warning from Roc", { run: run })
			Log.error!("an error from Roc", {})
			Log.debug!("a detail from Roc", { nested: { list: [1.U64, 2] } })
			text(200, "logged")
		}
		# `lines` events, numbered, for the request `run`: the log keeps their order.
		("GET", "/log/burst") => {
			lines = number(request.query, "lines")
			var $line = 1.U64
			while $line <= lines {
				Log.info!("burst", { run, line: $line })
				$line = $line + 1
			}
			text(200, "logged ${lines.to_str()}")
		}
		("GET", "/count") =>
		# A stream is a loop: send, sleep, round again.
			Server.events(
				Events.stream(
					|{ send!, sleep! }| {
						var $count = 1.U64
						while $count <= 3 {
							send!($count.to_str())?
							sleep!(10)
							$count = $count + 1
						}
						Ok({})
					},
				),
			)
		("GET", "/ticks") =>
		# Until the client goes (or ten thousand ticks): then `send!` says so, and `?` ends the
		# loop.
			Server.events(
				Events.stream(
					|{ send!, sleep! }| {
						var $tick = 0.U64
						while $tick < 10_000 {
							send!("tick ${$tick.to_str()}")?
							sleep!(20)
							$tick = $tick + 1
						}
						Ok({})
					},
				),
			)
		("GET", "/list") => Server.events(Events.from_list(["a", "b", "c"], 5))
		("GET", "/stream-crash") =>
			Server.events(
				Events.stream(
					|{ send!, sleep! }| {
						send!("step 0")?
						sleep!(5)
						send!("step 1")?
						crash "a stream's third step"
					},
				),
			)

		# ---- Calls that wait: each pauses, and holds no thread meanwhile (D-027) ----
		# `Live.next!` with no topic to hear is a sleep: `ms` of quiet.
		("GET", "/wait") => {
			_ = Live.next!(number(request.query, "ms"))
			text(200, "waited")
		}
		("GET", "/wait/crash") => {
			_ = Live.next!(number(request.query, "ms"))
			crash "crash ${param(request.query, "id")} after waiting"
		}
		# A stream that says it is open, then waits `ms` (or until its client goes) before it ends.
		("GET", "/wait/stream") => {
			ms = number(request.query, "ms")
			Server.events(
				Events.stream(
					|{ send!, sleep! }| {
						send!("open")?
						sleep!(ms)
						send!("done")?
						Ok({})
					},
				),
			)
		}
		(_, "/wait/page") => page(waiting!)
		("GET", "/wait/refuse") => Endpoint.respond!(refusing_endpoint, request, {})
		("POST", "/wait/tcp") => {
			_ = Live.next!(number(request.query, "ms"))
			answered(tcp_round!(U16.from_str(param(request.query, "port")) ?? 0, param(request.query, "id")))
		}
		# A stack `n` calls deep: a large `n` overflows it.
		("GET", "/deep") => text(200, deep(number(request.query, "n")).to_str())

		# ---- Postgres ----
		("POST", "/reset") =>
			match Db.script!("truncate notes, job_log, flaky restart identity; delete from rocx_jobs") {
				Ok(_) => text(200, "ready")
				Err(DbErr(why)) => text(500, why)
			}
		("POST", "/notes") =>
			match Db.run!("insert into notes (body, note) values ($1, $2)", [Text(Server.text_of(request)), if (request.query == "noted") Text("a note") else Null]) {
				Ok(count) => text(201, "added ${count.to_str()}")
				Err(DbErr(why)) => text(500, why)
			}
		("GET", "/notes") => {
			found : Try(List({ id : I64, body : Str, note : Db.Nullable(Str) }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select id, body, note from notes order by id", [])
			match found {
				Ok(notes) => text(200, Str.join_with(notes.map(|each| "${each.id.to_str()} ${each.body} ${noted(each.note)}"), "\n"))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("GET", "/note") => {
			found : Try(List({ body : Str }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select body from notes where id = $1", [Int(1)])
			match found {
				Ok(notes) => text(200, Str.join_with(notes.map(|each| each.body), "\n"))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("GET", "/nullable") => {
			found : Try(List({ maybe : Str }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select null::text as maybe", [])
			match found {
				Ok(_) => text(200, "read a null as text")
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("GET", "/nullable-marked") => {
			# The old way of saying a column may be null, in its name: refused, with how to say it now.
			found : Try(List({ maybe : Db.Nullable(Str) }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select null::text as \"maybe?\"", [])
			match found {
				Ok(_) => text(200, "read it")
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("GET", "/nullables") => {
			# Nulls and values in the same columns, nested in JSON too, and written back as JSON has them.
			found : Try(List({ n : Db.Nullable(I64), tags : Db.Nullable(List(Str)), doc : Db.Nullable({ a : Db.Nullable(I64) }) }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select * from (values (1::int8, '[\"x\",\"y\"]'::jsonb, '{\"a\":null}'::jsonb), (null, null, null)) as t(n, tags, doc)", [])
			match found {
				Ok(rows) => text(200, Json.to_str(rows))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("GET", "/arrays") =>
			match arrays!({}) {
				Ok(said) => text(200, said)
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		("GET", "/sleep") => {
			slept : Try(List({ done : I64 }), [DbErr(Str), BadRow(Str)])
			slept = Db.all!("select 1::int8 as done from pg_sleep(0.3)", [])
			match slept {
				Ok(_) => text(200, "slept")
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("GET", "/bad-sql") =>
			match Db.run!("insert into nowhere values (1)", []) {
				Ok(_) => text(200, "?")
				Err(DbErr(why)) => text(500, why)
			}

		# ---- Transactions ----
		("POST", "/tx/commit") => {
			done = Db.transaction!(
				|{}| {
					_ = Db.run!("insert into notes (body) values ($1)", [Text("committed ${run}")])?
					_ = Db.run!("insert into notes (body) values ($1)", [Text("also committed ${run}")])?
					Ok("committed")
				},
			)
			match done {
				Ok(said) => text(200, said)
				Err(DbErr(why)) => text(500, why)
			}
		}
		("POST", "/tx/rollback") => {
			done = Db.transaction!(
				|{}| {
					_ = Db.run!("insert into notes (body) values ($1)", [Text("rolled back ${run}")])?
					Err(Refused)
				},
			)
			match done {
				Ok(_) => text(200, "?")
				Err(Refused) => text(409, "refused, rolled back")
				Err(DbErr(why)) => text(500, why)
			}
		}
		("POST", "/tx/crash") => {
			done = Db.transaction!(
				|{}| {
					_ = Db.run!("insert into notes (body) values ($1)", [Text("crashed ${run}")])?
					if (run != "") crash "in a transaction" else Ok("?")
				},
			)
			match done {
				Ok(said) => text(200, said)
				Err(DbErr(why)) => text(500, why)
			}
		}
		("POST", "/tx/failing-statement") => {
			done = Db.transaction!(
				|{}| {
					_ = Db.run!("insert into notes (body) values ($1)", [Text("before a bad statement ${run}")])?
					_ = Db.run!("insert into nowhere values (1)", [])?
					Ok("?")
				},
			)
			match done {
				Ok(said) => text(200, said)
				Err(DbErr(why)) => text(500, why)
			}
		}
		("GET", "/tx/notes") => {
			found : Try(List({ body : Str }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select body from notes where body like $1 order by id", [Text("%${run}")])
			match found {
				Ok(notes) => text(200, Str.join_with(notes.map(|each| each.body), "\n"))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}

		# ---- Jobs ----
		("POST", "/jobs/note") =>
			match Job.enqueue!(note_job, { run, said: Server.text_of(request) }, { when: Now }) {
				Ok({}) => text(202, "queued")
				Err(JobErr(why)) => text(500, why)
			}
		("POST", "/jobs/later") =>
			match Job.enqueue!(note_job, { run, said: "later" }, { when: At(Time.now_millis!({}) + 400) }) {
				Ok({}) => text(202, "queued")
				Err(JobErr(why)) => text(500, why)
			}
		("POST", "/jobs/flaky") => {
			fails : I64
			fails = I64.from_str(param(request.query, "fails")) ?? 0
			match Job.enqueue!(flaky_job, { run, fails }, { when: Now }) {
				Ok({}) => text(202, "queued")
				Err(JobErr(why)) => text(500, why)
			}
		}
		("POST", "/jobs/crash") =>
			match Job.enqueue!(crash_job, { run: run }, { when: Now }) {
				Ok({}) => text(202, "queued")
				Err(JobErr(why)) => text(500, why)
			}
		("POST", "/jobs/commit") => {
			# One body `?`s Db and Job, with nothing mapped: the transaction's error is both (and
			# any error of the app's own), and the caller matches each.
			done = Db.transaction!(
				|{}| {
					_ = Db.run!("insert into notes (body) values ($1)", [Text("with a job ${run}")])?
					Job.enqueue!(note_job, { run, said: "committed" }, { when: Now })?
					Ok("queued")
				},
			)
			match done {
				Ok(said) => text(202, said)
				Err(DbErr(why)) => text(500, why)
				Err(JobErr(why)) => text(500, why)
			}
		}
		("POST", "/jobs/rollback") => {
			# A note and a job, then the app's own error (`Refused`), a statement that fails
			# (`DbErr`), or the queue refusing a job in a transaction Postgres has aborted (`JobErr`):
			# each rolls back what came before, and the caller matches each case.
			how = param(request.query, "how")
			done = Db.transaction!(
				|{}| {
					_ = Db.run!("insert into notes (body) values ($1)", [Text("rolled back ${run}")])?
					if how == "statement" {
						_ = Db.run!("insert into nowhere values (1)", [])?
					}
					if how == "queue" {
						aborted : Try(U64, [DbErr(Str)])
						aborted = Db.run!("insert into nowhere values (1)", [])
						_ = aborted
					}
					Job.enqueue!(note_job, { run, said: "rolled back" }, { when: Now })?
					if how == "" or how == "refused" Err(Refused) else Ok("?")
				},
			)
			match done {
				Ok(said) => text(200, said)
				Err(Refused) => text(409, "Refused")
				Err(DbErr(why)) => text(500, "DbErr: ${why}")
				Err(JobErr(why)) => text(500, "JobErr: ${why}")
			}
		}
		("GET", "/jobs/log") => {
			found : Try(List({ kind : Str, said : Str }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select kind, said from job_log where said like $1 order by id", [Text("${run} %")])
			match found {
				Ok(rows) => text(200, Str.join_with(rows.map(|row| "${row.kind}: ${row.said}"), "\n"))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("GET", "/jobs/state") => {
			found : Try(List({ state : Str, attempts : I32, error : Str }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select state, attempts, coalesce(last_error, '') as error from rocx_jobs where input like $1 order by id", [Text("%\"${run}\"%")])
			match found {
				Ok(rows) => text(200, Str.join_with(rows.map(|row| "${row.state} ${row.attempts.to_str()} ${row.error}"), "\n"))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		# A job of a kind this app doesn't list, as another app sharing the database would queue.
		("POST", "/jobs/foreign") =>
			match Db.run!("with queued as (insert into rocx_jobs (kind, input) values ('another-app', $1) returning id) select pg_notify('rocx_jobs', id::text) from queued", [Text("{\"run\":\"${run}\"}")]) {
				Ok(_) => text(202, "queued")
				Err(DbErr(why)) => text(500, why)
			}
		("DELETE", "/jobs/foreign") =>
			match Db.run!("delete from rocx_jobs where kind = 'another-app' and input like $1", [Text("%\"${run}\"%")]) {
				Ok(count) => text(200, count.to_str())
				Err(DbErr(why)) => text(500, why)
			}
		("POST", "/jobs/twice") =>
			match Job.enqueue!(twice_job, { run: run }, { when: Now }) {
				Ok({}) => text(202, "queued")
				Err(JobErr(why)) => text(500, why)
			}
		("POST", "/jobs/slow") =>
			match Job.enqueue!(slow_job, { run, on: param(request.query, "on"), url: param(request.query, "url") }, { when: Now }) {
				Ok({}) => text(202, "queued")
				Err(JobErr(why)) => text(500, why)
			}
		# A note job with a key, now or `in` milliseconds: queued, or not (a pending one has the key).
		("POST", "/jobs/keyed") =>
			match Job.enqueue_keyed!(note_job, { run, said: Server.text_of(request) }, { when: later!(request.query), key: param(request.query, "key") }) {
				Ok(Queued) => text(202, "queued")
				Ok(Exists) => text(200, "exists")
				Err(JobErr(why)) => text(500, why)
			}
		("POST", "/jobs/cancel") =>
			match Job.cancel!(param(request.query, "key")) {
				Ok(count) => text(200, count.to_str())
				Err(JobErr(why)) => text(500, why)
			}
		("POST", "/jobs/move") =>
			match Job.move!(param(request.query, "key"), later!(request.query)) {
				Ok(count) => text(200, count.to_str())
				Err(JobErr(why)) => text(500, why)
			}
		("GET", "/jobs/list") => {
			filter = {
				state: param(request.query, "state"),
				kind: param(request.query, "kind"),
				before_id: I64.from_str(param(request.query, "before")) ?? 0,
				limit: U64.from_str(param(request.query, "limit")) ?? 0,
			}
			match Job.list!(filter) {
				Ok(rows) => text(200, Str.join_with(rows.map(described_job), "\n"))
				Err(JobErr(why)) => text(500, why)
			}
		}
		("GET", "/jobs/get") =>
			match Job.get!(I64.from_str(param(request.query, "id")) ?? 0) {
				Ok(row) => text(200, described_job(row))
				Err(NotFound) => text(404, "not found")
				Err(JobErr(why)) => text(500, why)
			}
		("GET", "/jobs/counts") =>
			match Job.counts!({}) {
				Ok(counts) => text(200, Str.join_with(counts.map(|each| "${each.kind} ${each.state} ${each.count.to_str()}"), "\n"))
				Err(JobErr(why)) => text(500, why)
			}
		# Postgres's backends still running the slow job's statement.
		("GET", "/jobs/sleepers") => {
			found : Try(List({ sleepers : I64 }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select count(*) as sleepers from pg_stat_activity where state = 'active' and query like '%pg_sleep(30)%' and pid <> pg_backend_pid()", [])
			match found {
				Ok(rows) => text(200, Str.join_with(rows.map(|row| row.sleepers.to_str()), ""))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		# The jobs page mounted by the app itself, behind a guard of its own (its plugin is at /admin/jobs).
		(_, "/admin/mounted") => Middleware.run!(admins_only, request, context, |passed, _| JobsPage.respond!(passed, { mount: "/admin/mounted" }))
		("GET", "/jobs/ticks") => {
			found : Try(List({ ticks : I64 }), [DbErr(Str), BadRow(Str)])
			found = Db.all!("select count(*) as ticks from job_log where kind = 'tick'", [])
			match found {
				Ok(rows) => text(200, Str.join_with(rows.map(|row| row.ticks.to_str()), ""))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}

		# ---- Email ----
		("POST", "/mail") =>
			match Email.send!({ to: param(request.query, "to"), subject: "Hello ${run}", text: Server.text_of(request), html: "<p>${Server.text_of(request)}</p>" }) {
				Ok({}) => text(200, "sent")
				Err(EmailErr(why)) => text(500, why)
			}
		("POST", "/jobs/mail") =>
			match Job.enqueue!(mail_job, { to: param(request.query, "to"), run }, { when: Now }) {
				Ok({}) => text(202, "queued")
				Err(JobErr(why)) => text(500, why)
			}

		# ---- Live ----
		("GET", "/online") =>
		# Who is here: this stream counts until it ends, and hears when others come and go.
			Server.events(
				Events.stream(
					|{ send!, .. }| {
						Live.join!("online")
						var $open = Bool.True
						while $open {
							send!(Live.count!("online").to_str())?
							$open = Live.next!(15_000) != Gone
						}
						Ok({})
					},
				),
			)
		("GET", "/online/count") => text(200, Live.count!("online").to_str())
		("GET", "/shouts") =>
			Server.events(
				Events.stream(
					|{ send!, .. }| {
						Live.listen!("shouts")
						send!("listening")?
						var $open = Bool.True
						while $open {
							match Live.next!(15_000) {
								Heard({ message, .. }) => send!(message)?
								Quiet => send!("quiet")?
								Gone => {
									$open = Bool.False
								}
							}
						}
						Ok({})
					},
				),
			)
		("POST", "/shout") => {
			Live.publish!("shouts", Server.text_of(request))
			text(200, "shouted")
		}

		# ---- Channels: published from a request (a job or an actor would do the same) ----
		("POST", "/news/publish") => {
			Endpoint.publish!(org_news(param(request.query, "org")), { title: param(request.query, "title"), n: number(request.query, "n") })
			text(200, "published")
		}
		("POST", "/news/flood") => {
			# `count` messages of `size` bytes, as fast as they go: ordered, or latest-wins (one key).
			news = org_news(param(request.query, "org"))
			filler = Str.repeat("x", number(request.query, "size"))
			latest = param(request.query, "latest") == "yes"
			var $n = 1
			while $n <= number(request.query, "count") {
				said = { title: filler, n: $n }
				if latest Endpoint.publish_latest!(news, "one", said) else Endpoint.publish!(news, said)
				$n = $n + 1
			}
			text(200, "flooded")
		}
		("POST", "/clock/publish") => {
			Endpoint.publish!(clock, Time.now_millis!({}))
			text(200, "published")
		}

		# ---- Actors ----
		("POST", "/actors/boom") => answered_actor(Counter.boom.ask!(run, {}))
		("POST", "/actors/self") => answered_actor(Mirror.itself.ask!(run, run))
		("POST", "/actors/relay") => answered_actor(Mirror.relay.ask!(run, run))
		("POST", "/actors/cycle") => answered_actor(Mirror.cycle.ask!(run, run))
		("POST", "/actors/tell") => {
			Counter.add.tell!(run, I64.from_str(param(request.query, "by")) ?? 1)
			text(200, "told")
		}
		("POST", "/actors/later") => {
			ms = U64.from_str(param(request.query, "ms")) ?? 100
			timer = Counter.add.tell_after!(run, ms, I64.from_str(param(request.query, "by")) ?? 1)
			text(200, timer.to_str())
		}
		("POST", "/actors/cancel") => {
			Actor.cancel!(U64.from_str(param(request.query, "timer")) ?? 0)
			text(200, "cancelled")
		}
		# The counter's turn taking `ms` milliseconds (Postgres sleeps): what is sent meanwhile waits.
		("POST", "/actors/nap") => answered_actor(Counter.nap.ask!(run, I64.from_str(param(request.query, "ms")) ?? 100))
		# The timers kept for the counter called `run` (D-057).
		("GET", "/actors/timers") => {
			kept : Try(List({ timers : I64 }), [DbErr(Str), BadRow(Str)])
			kept = Db.all!("select count(*) as timers from rocx_actor_timers where key = $1", [Text(run)])
			match kept {
				Ok(rows) => text(200, Str.join_with(rows.map(|row| row.timers.to_str()), ""))
				Err(DbErr(why)) => text(500, why)
				Err(BadRow(why)) => text(500, why)
			}
		}
		("POST", "/actors/wrong") => answered_actor(stale_add.ask!(run, "to what?"))
		("POST", "/actors/missing") => answered_actor(counter_reset.ask!(run, {}))
		("POST", "/actors/wrong-tell") => {
			stale_add.tell!(run, "to what?")
			text(200, "told")
		}
		("POST", "/actors/ghost") => answered_actor(Ghost.add.ask!(run, 1))
		("POST", "/actors/tick/start") => answered_actor(Ticker.start.ask!(run, U64.from_str(param(request.query, "ms")) ?? 20))
		("POST", "/actors/tick/stop") => answered_actor(Ticker.stop.ask!(run, {}))
		("GET", "/actors/tick") => answered_actor(Ticker.ticks.ask!(run, {}))
		("POST", "/actors/poke") =>
			# The counter's state, written to Postgres behind its back: an actor that is awake keeps
			# the state it has; one let go reads this when it wakes.
			match Db.run!("update rocx_actors set state = $1 where kind = 'counter' and key = $2", [Text("{\"count\":${param(request.query, "count")}}"), Text(run)]) {
				Ok(_) => text(200, "poked")
				Err(DbErr(why)) => text(500, why)
			}
		("POST", path) if path.starts_with("/actors/count/") => {
			by : I64
			by = I64.from_str(param(request.query, "by")) ?? 1
			answered_actor(Counter.add.ask!(after(path, "/actors/count/"), by))
		}
		("GET", path) if path.starts_with("/actors/count/") => answered_actor(Counter.get.ask!(after(path, "/actors/count/"), {}))

		# ---- Endpoint reads: a page reads GET endpoints as the server renders it (D-023) ----
		("GET", "/reads") if !Server.wants_html(request) => Endpoint.respond!(reads_endpoint, request, {})
		(_, "/reads") => page(reading!)
		("GET", "/reads/member") => Middleware.run!(gate, request, { started: context }, |passed, handed| Endpoint.respond!(member_endpoint, passed, handed))
		("GET", "/reads/missing") => Endpoint.respond!(missing_endpoint, request, {})
		("GET", "/reads/flash") => Endpoint.respond!(flash_endpoint, request, {})
		(_, "/reads-gated") => { status: 200, headers: [{ name: "x-page", value: "yes" }], body: Page(read_gated!) }
		(_, "/reads-flash") => page(read_flash!)

		# ---- Pages of components: the host renders them (any method; HEAD isn't rendered) ----
		(_, "/probe") => page(probing!)
		(_, "/page") => { status: 200, headers: [{ name: "x-page", value: "yes" }], body: Page(document!) }
		(_, "/page-gone") => page(gone!)
		(_, "/page-crash") => page(crashing!)
		(_, "/page-mount-crash") => page(mount_crashing!)
		(_, "/page-unhandled") => page(unhandled!)
		(_, "/page-effects") => page(effects!)
		(_, "/page-rcdata") => page(rcdata!)
		(_, "/page-region") => page(region!)
		(_, "/page-region-handler") => page(region_handler!)
		(_, "/page-gated") => { status: 200, headers: [{ name: "x-page", value: "yes" }], body: Page(gated!) }
		(_, "/page-app") => page(app_page!)
		# packages/guard's headers, its CSP enforced: every script on the page is the site's own.
		(_, "/page-guarded") => { status: 200, headers: Security.headers(Security.defaults, { dev: Bool.False }), body: Page(document!) }

		# ---- Form actions: a plain form's post comes back to its page with a flash ----
		(_, "/flash/join") => Endpoint.respond!(join_endpoint, request, {})
		(_, "/flash/away") => Endpoint.respond!(away_endpoint, request, {})
		("GET", "/flash/page") => page(joining!)
		("GET", "/flash/sign-in") => page(signing_in!)

		# ---- TCP ----
		("POST", "/tcp") =>
			match tcp_round!(U16.from_str(param(request.query, "port")) ?? 0, Server.text_of(request)) {
				Ok(said) => text(200, said)
				Err(why) => text(500, why)
			}
		("POST", "/tcp-left-open") =>
		# Connects and writes, and never closes: the host closes it when this call ends.
			match Tcp.connect!("127.0.0.1", U16.from_str(param(request.query, "port")) ?? 0) {
				Ok(tcp) => {
					_ = tcp.write_utf8!("left open\n")
					text(200, "written")
				}
				Err(TcpErr(why)) => text(500, why)
			}

		# ---- HTTP: requests to other servers ----
		("POST", "/http") => {
			# `url`, asked with `Http.fetch!`: `method` (GET unless it says), a header of its own and a
			# token, a `content-type` if `type` says one, query pairs if `query=yes`, the body `send`
			# says, and `timeout`, `max`, `follow=no` and `proxy` (`direct`, or a URL) if given (the
			# defaults if not).
			asked = request.query
			given_type = if (param(asked, "type").is_empty()) [] else [("Content-Type", param(asked, "type"))]
			init : Http.Init
			init = {
				method: method_of(param(asked, "method")),
				headers: [("x-rocx", "yes"), ("authorization", "Bearer sesame")].concat(given_type),
				query: if (param(asked, "query") == "yes") [("city", "São Paulo"), ("a&b", "c=d ✓")] else [],
				body: body_of(param(asked, "send"), Server.text_of(request)),
			}
			timed = match U64.from_str(param(asked, "timeout")) {
				Ok(ms) => { ..init, timeout_ms: ms }
				Err(_) => init
			}
			limited = match U64.from_str(param(asked, "max")) {
				Ok(bytes) => { ..timed, max_bytes: bytes }
				Err(_) => timed
			}
			directed = if (param(asked, "follow") == "no") { ..limited, redirect: Manual } else limited
			proxied =
				match param(asked, "proxy") {
					"" => directed
					"direct" => { ..directed, proxy: Direct }
					named => { ..directed, proxy: Via(named) }
				}
			answered_fetch(Http.fetch!(param(asked, "url"), proxied))
		}
		("POST", "/http/chunks") => {
			# `url`'s answer a chunk at a time (`Http.fetch_chunks!`): its status, how many chunks came
			# and what they said; `stop` ends it after that many, `crash` crashes there, `timeout` and
			# `max` as `/http`'s (no limits if not given).
			asked = request.query
			stop = U64.from_str(param(asked, "stop")) ?? 0
			init : Http.Init
			init = { timeout_ms: U64.from_str(param(asked, "timeout")) ?? 0, max_bytes: U64.from_str(param(asked, "max")) ?? 0 }
			step! = |seen, received|
				match received {
					Head(res) => Ok({ ..seen, status: res.status, from: res.header("x-from") ?? "-" })
					Chunk(bytes) =>
						if stop > 0 and seen.chunks >= stop {
							if (param(asked, "crash") == "yes") crash "a step that crashes" else Err(Enough(seen.chunks))
						} else {
							Ok({ ..seen, chunks: seen.chunks + 1, said: seen.said.concat(bytes) })
						}
				}
			match Http.fetch_chunks!(param(asked, "url"), init, { status: 0, from: "", chunks: 0, said: [] }, step!) {
				Ok(seen) => text(200, "${seen.status.to_str()} ${seen.from} ${seen.chunks.to_str()} chunks\n${Str.from_utf8_lossy(seen.said)}")
				Err(Stopped(Enough(count))) => text(200, "stopped after ${count.to_str()}")
				Err(TimedOut) => text(504, "timed out")
				Err(TooLarge) => text(502, "too large")
				Err(HttpErr(why)) => text(502, "no answer: ${why}")
			}
		}
		("POST", "/http/plain") =>
		# `Http.fetch!(url, {})`: a GET, with every default.
			match Http.fetch!(param(request.query, "url"), {}) {
				Ok(res) => text(200, "${res.status.to_str()} ${if (res.ok) "ok" else "not ok"}\n${res.text()}")
				Err(_) => text(502, "no answer")
			}
		("POST", "/http/json") => {
			# A forecast read as JSON of a type: what it says, or why it isn't that.
			match weather!(param(request.query, "url")) {
				Ok({ tomorrow, high }) => text(200, "${tomorrow} ${high.to_str()}")
				Err(InvalidJson(why)) => text(200, "not JSON of that shape: ${why}")
				Err(_) => text(502, "no answer")
			}
		}
		("POST", "/http/bytes") =>
		# Bytes each way: these sent, and the answer's as numbers.
			match Http.fetch!(param(request.query, "url"), { method: Put, headers: [("content-type", "application/octet-stream")], body: Http.bytes([0, 255, 13, 10, 128]) }) {
				Ok(response) => text(200, numbers(response.bytes()))
				Err(_) => text(502, "no answer")
			}

		# ---- HTTP, the deprecated API (D-024): each `fetch!` underneath, still answering ----
		("POST", "/http/old") => {
			# GET `url` (or POST it this request's body as JSON, `method=POST`; or HEAD it), with a
			# header of its own, as `opts` says.
			url = param(request.query, "url")
			opts = {
				timeout_ms: U64.from_str(param(request.query, "timeout")) ?? Http.defaults.timeout_ms,
				max_bytes: U64.from_str(param(request.query, "max")) ?? Http.defaults.max_bytes,
				follow_redirects: param(request.query, "follow") != "no",
			}
			outgoing =
				match param(request.query, "method") {
					"POST" => Http.post_json(url, Server.text_of(request))
					"HEAD" => { ..Http.get(url), method: "HEAD" }
					_ => Http.get(url)
				}
			answered_http(Http.send!(Http.with_header(Http.with_header(outgoing, "x-rocx", "yes"), "authorization", "Bearer sesame"), opts))
		}
		("POST", "/http/old/form") => answered_http(Http.send_request!(Http.post_form(param(request.query, "url"), [("name", "Ada Lovelace"), ("says", "a&b=c ✓")])))
		("POST", "/http/old/bytes") =>
			match Http.send_request!({ method: "PUT", url: param(request.query, "url"), headers: [{ name: "content-type", value: "application/octet-stream" }], body: [0, 255, 13, 10, 128] }) {
				Ok(response) => text(200, numbers(response.body))
				Err(_) => text(502, "no answer")
			}

		# ---- The environment ----
		("GET", "/env") =>
			match Env.var!(param(request.query, "name")) {
				Ok(value) => text(200, "found ${value}")
				Err(NotFound) => text(200, "not found")
			}
		("GET", "/env/dev") => text(200, if (Env.dev!({})) "dev" else "not dev")
		("GET", "/env/public-url") => text(200, Env.public_url!({}))
		("POST", "/jobs/env") =>
			match Job.enqueue!(env_job, { run, name: param(request.query, "name") }, { when: Now }) {
				Ok({}) => text(202, "queued")
				Err(JobErr(why)) => text(500, why)
			}

		# ---- AES-GCM, random bytes ----
		("POST", "/aes/seal") =>
		# Bytes as numbers, `1,2,3`, each way: the key in the query, what to seal the body.
			match AesGcm.seal!(from_numbers(param(request.query, "key")), request.body) {
				Ok(sealed) => text(200, numbers(sealed))
				Err(BadKey) => text(400, "BadKey")
			}
		("POST", "/aes/open") =>
			match AesGcm.open!(from_numbers(param(request.query, "key")), from_numbers(Server.text_of(request))) {
				Ok(opened) => text(200, Str.from_utf8_lossy(opened))
				Err(BadKey) => text(400, "BadKey")
				Err(Forged) => text(400, "Forged")
			}
		("POST", "/crypto") =>
		# The crypto written in Roc, compiled: the body's SHA-256, its HMAC and an HKDF under the
		# key (hex, in the query), its Base64; and whether each decodes to what was encoded.
			match Hex.decode(param(request.query, "key")) {
				Err(InvalidHex) => text(400, "the key isn't hex")
				Ok(key) => {
					body = request.body
					mac = Hmac.sha256(key, body)
					derived = Hkdf.sha256(key, "salt".to_utf8(), "info".to_utf8(), 42) ?? []
					decoded = Base64.decode(Base64.encode(body)) == Ok(body) and Base64.url_decode(Base64.url_encode(body)) == Ok(body) and Hex.decode(Hex.encode(body)) == Ok(body)
					checked = Hmac.verify_sha256(key, body, mac) and !Hmac.verify_sha256(key, body.append(0), mac)
					said = [Sha256.hex(body), Hex.encode(mac), Hex.encode(derived), Base64.encode(body), Base64.url_encode(body), if (decoded) "decoded" else "not decoded", if (checked) "verified" else "not verified"]
					text(200, Str.join_with(said, "\n"))
				}
			}
		("GET", "/random") => text(200, numbers(Random.bytes!(U64.from_str(param(request.query, "count")) ?? 0)))

		# ---- Storage: packages/storage, in the bucket STORAGE_URL names (`stored!`) ----
		(_, path) if path.starts_with("/storage/") => stored!(request)

		# ---- The key-value store (the key, a value as text, `ttl` and `keep` in the query) ----
		(_, path) if path.starts_with("/kv/") => kept!(request)

		# ---- Cookies: each kind the platform writes ----
		("GET", "/cookies") => {
			given = Server.redirect("/")
			plain = Server.with_cookie(given, "plain", "a b;c")
			lasting = Server.set_cookie(plain, "__Host-session", "token", { ..Server.cookie_defaults, secure: Bool.True, max_age_s: 30 * 86_400 })
			ending = Server.set_cookie(lasting, "until", "1", { ..Server.cookie_defaults, expires_ms: 1_795_000_000_000, same_site: Strict, http_only: Bool.False })
			shared = Server.set_cookie(ending, "shared", "x", { ..Server.cookie_defaults, domain: "example.com", path: "/docs", same_site: None, secure: Bool.True })
			cleared = Server.clear_cookie(shared, "__Host-session", { ..Server.cookie_defaults, secure: Bool.True })
			Server.without_cookie(cleared, "plain")
		}

		# ---- What the docs show (Samples.roc), run ----
		("GET", "/samples/forecast") =>
			match Samples.forecast!(param(request.query, "api"), param(request.query, "city")) {
				Ok(said) => text(200, said.tomorrow)
				Err(Refused(status)) => text(502, "refused: ${status.to_str()}")
				Err(InvalidJson(_)) => text(502, "not a forecast")
				Err(_) => text(504, "no answer")
			}
		("POST", "/samples/order") =>
			match Samples.order!(param(request.query, "shop"), param(request.query, "token"), { item: "tea", count: 2 }) {
				Ok(id) => text(200, "ordered and cancelled ${id}")
				Err(Refused(status)) => text(502, "refused: ${status.to_str()}")
				Err(InvalidJson(_)) => text(502, "no order id")
				Err(_) => text(504, "no answer")
			}
		("GET", "/samples/preview") =>
			match Samples.preview!(param(request.query, "url")) {
				Ok(answer) => text(200, "${answer.status.to_str()} ${answer.header("location") ?? "-"}")
				Err(TooLarge) => text(502, "too large")
				Err(_) => text(504, "no answer")
			}
		("GET", "/samples/lines") =>
			match Samples.lines!(param(request.query, "url")) {
				Ok(count) => text(200, "${count.to_str()} lines")
				Err(Stopped(Refused(status))) => text(502, "refused: ${status.to_str()}")
				Err(_) => text(504, "no answer")
			}
		("GET", "/samples/partner") =>
			match Samples.partner!(param(request.query, "url")) {
				Ok(answer) => text(200, "${answer.status.to_str()} ${answer.text()}")
				Err(HttpErr(why)) => text(502, why)
				Err(_) => text(504, "no answer")
			}
		("GET", "/samples/origin") => text(200, Samples.origin!({}))
		("POST", "/samples/dev") => Samples.dev_sign_in!(Server.text_of(request))
		("GET", "/samples/token") => text(200, "${Samples.token!({})} ${Samples.digest(param(request.query, "of"))}")
		("GET", "/samples/link") => text(200, Samples.signed_link!(param(request.query, "member"), number(request.query, "until")))
		("GET", "/samples/link/check") =>
			match Samples.link_member!(param(request.query, "link"), number(request.query, "now")) {
				Ok(member) => text(200, member)
				Err(BadLink) => text(403, "BadLink")
				Err(Expired) => text(410, "Expired")
			}
		("POST", "/samples/seal") =>
			match Samples.seal!(Server.text_of(request)) {
				Ok(kept) => text(200, kept)
				Err(BadKey) => text(500, "BadKey")
			}
		("POST", "/samples/unseal") =>
			match Samples.unseal!(Server.text_of(request)) {
				Ok(secret) => text(200, secret)
				Err(Forged) => text(400, "Forged")
				Err(_) => text(400, "unreadable")
			}
		("PUT", "/samples/avatar") => answered_storage(Samples.save_avatar!(param(request.query, "member"), request), |{}| "saved")
		("GET", "/samples/avatar") => answered_storage(Samples.avatar_size!(param(request.query, "member")), |said| said)
		("POST", "/samples/avatar/take") => answered_storage(Samples.take_avatar!(param(request.query, "member")), |bytes| Str.from_utf8_lossy(bytes))
		("GET", "/samples/upload-link") =>
			match Samples.upload_link!(param(request.query, "key")) {
				Ok(url) => text(200, url)
				Err(_) => text(503, "no link")
			}
		("POST", "/samples/parts") => answered_storage(Samples.save_in_parts!(param(request.query, "key"), [request.body]), |{}| "saved")
		(_, "/samples/video") => Samples.serve_video!(param(request.query, "key"), request)
		(_, "/samples/video/whole") => Samples.serve_whole!(param(request.query, "key"), request)
		("POST", "/samples/digest") => Samples.upload_digest(request)
		(_, "/samples/cdn") => Samples.from_cdn(request, param(request.query, "url"))
		("POST", "/samples/try") => text(200, if (Samples.may_try!(param(request.query, "address"))) "go on" else "wait")
		("POST", "/samples/sign-in") => text(200, Samples.begin_sign_in!({}))
		("GET", "/samples/sign-in/back") =>
			match Samples.finish_sign_in!(param(request.query, "state")) {
				Ok({}) => text(200, "signed in")
				Err(UnknownState) => text(400, "UnknownState")
			}
		("GET", "/samples/cookies") => Samples.signed_out(Samples.reviewing(Samples.signed_in(text(200, "cookies"), "token"), "review", 1_795_000_000_000))

		# ---- The probes' endpoints, which its pages read ----
		("GET", path) if path.starts_with("/probe/shout/") => Endpoint.respond!(shout_at(""), request, {})
		("GET", "/probe/member") => Middleware.run!(members_only, request, { started: context }, |passed, handed| Endpoint.respond!(member_probe, passed, handed))
		("GET", "/probe/signed_in") => Middleware.run!(gate, request, { started: context }, |passed, handed| Endpoint.respond!(signed_in_probe, passed, handed))
		("POST", "/probe/measure") => Endpoint.respond!(measure_endpoint, request, {})
		("POST", "/probe/length") => Endpoint.respond!(length_endpoint, request, {})
		("POST", "/probe/award") => Middleware.run!(badged, request, { started: context }, |passed, handed| Endpoint.respond!(award_endpoint, passed, handed))

		_ => text(404, "No page at ${request.path}.")
	}
}

## When a job is to run: now, or `in` milliseconds (a query's parameter).
later! : Str => Job.When
later! = |query|
	match U64.from_str(param(query, "in")) {
		Ok(ms) if ms > 0 => At(Time.now_millis!({}) + ms)
		_ => Now
	}

## A job as the tests read it: its id, kind, state, attempts, key and last error.
described_job : Job.Row -> Str
described_job = |row| {
	key =
		match row.key {
			Some(said) => said
			Null => "-"
		}
	error =
		match row.last_error {
			Some(why) => why
			Null => "-"
		}
	"${row.id.to_str()} ${row.kind} ${row.state} ${row.attempts.to_str()}/${row.max_attempts.to_str()} ${key} ${error}"
}

## Admins only: a request saying `x-admin: yes`; anyone else is refused (403).
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

admins_only : Middleware(Str, Str)
admins_only = Middleware.make(|request, context, next!| if (Server.header(request, "x-admin") == Ok("yes")) next!(request, context) else Server.refused(403, "admins only"))

## Says a line to a server on this machine, and reads its answer: a line, then three bytes more.
tcp_round! : U16, Str => Try(Str, Str)
tcp_round! = |port, said|
	match Tcp.connect!("127.0.0.1", port) {
		Err(TcpErr(why)) => Err(why)
		Ok(tcp) => {
			written = tcp.write_utf8!("${said}\n")
			line = tcp.read_until!('\n')
			more = tcp.read_exactly!(3)
			tcp.close!()
			match (written, line, more) {
				(Ok({}), Ok(bytes), Ok(rest)) => Ok("${Str.from_utf8_lossy(bytes).trim()} ${Str.from_utf8_lossy(rest)}")
				(Err(TcpErr(why)), _, _) => Err(why)
				(_, Err(_), _) => Err("no line came back")
				(_, _, Err(_)) => Err("the rest didn't come")
			}
		}
	}

## What another server answered `Http.fetch!` (its status, its `location` and `x-from`, its body), or
## why there was no answer.
answered_fetch : Try(HttpResponse, [HttpErr(Str), TimedOut, TooLarge]) -> Server.Response
answered_fetch = |result|
	match result {
		Ok(res) => {
			shown = |name| res.header(name) ?? "-"
			text(200, "${res.status.to_str()} ${shown("location")} ${shown("x-from")}\n${res.text()}")
		}
		Err(TimedOut) => text(504, "timed out")
		Err(TooLarge) => text(502, "too large")
		Err(HttpErr(why)) => text(502, "no answer: ${why}")
	}

## Tomorrow's weather from `url`, read as JSON of that type.
weather! : Str => Try({ tomorrow : Str, high : I64 }, [HttpErr(Str), TimedOut, TooLarge, InvalidJson(Str)])
weather! = |url| Http.fetch!(url, {})?.json()

## A method as `/http`'s `method` names it: GET if it names none.
method_of : Str -> Http.Method
method_of = |named|
	match named {
		"" | "GET" => Get
		"POST" => Post
		"PUT" => Put
		"PATCH" => Patch
		"DELETE" => Delete
		"HEAD" => Head
		"OPTIONS" => Options
		_ => Other(named)
	}

## A body as `/http`'s `send` names it, with `said` (the request's text) for `text`: none if it
## names none.
body_of : Str, Str -> Http.Body
body_of = |named, said|
	match named {
		"json" => Http.json({ a: 1.I64 })
		"form" => Http.form([("name", "Ada Lovelace"), ("says", "a&b=c ✓")])
		"text" => Http.plain_text(said)
		"bytes" => Http.bytes([0, 255, 13, 10, 128])
		_ => Empty
	}

## What another server answered the deprecated `Http.send!` (as `answered_fetch` shows it).
answered_http : Try(Http.Response, [HttpErr(Str), TimedOut, TooLarge]) -> Server.Response
answered_http = |result|
	match result {
		Ok(response) => {
			shown = |name| Http.header(response, name) ?? "-"
			text(200, "${response.status.to_str()} ${shown("location")} ${shown("x-from")}\n${Http.text(response)}")
		}
		Err(TimedOut) => text(504, "timed out")
		Err(TooLarge) => text(502, "too large")
		Err(HttpErr(why)) => text(502, "no answer: ${why}")
	}

## A storage call's answer: what it gave, as `said` says; or its error, its tag first.
answered_storage = |result, said|
	match result {
		Ok(value) => text(200, said(value))
		Err(NotFound) => text(404, "NotFound")
		Err(S3Err({ status, code, message })) => text(502, "S3Err ${status.to_str()} ${code}: ${message}")
		Err(StorageErr(why)) => text(503, "StorageErr ${why}")
	}

## The bucket STORAGE_URL names, made as an app makes one: its URL, and the platform's effects.
bucket! : {} => Try(Storage.Bucket, [StorageErr(Str)])
bucket! = |{}| Storage.from_url(Env.var!("STORAGE_URL") ?? "")

## The storage routes (the key, and the rest, in the query; bytes as numbers with `as=numbers`).
## Without a bucket (no STORAGE_URL, or one that can't be read), each says why: a 503.
stored! : Server.Request => Server.Response
stored! = |request|
	match bucket!({}) {
		Err(StorageErr(why)) => text(503, "StorageErr ${why}")
		Ok(bucket) => in_bucket!(bucket, request)
	}

in_bucket! : Storage.Bucket, Server.Request => Server.Response
in_bucket! = |bucket, request|
	match (request.method, request.path) {
		("POST", "/storage/put") => {
			bytes = if (param(request.query, "as") == "numbers") from_numbers(Server.text_of(request)) else request.body
			answered_storage(Storage.put!(bucket, param(request.query, "key"), bytes, { content_type: param(request.query, "type") }), |{}| "stored")
		}
		("POST", "/storage/fill") =>
		# `size` bytes, each `fill`: an object larger than a request's body carries well as numbers.
			answered_storage(Storage.put!(bucket, param(request.query, "key"), filled(request.query), { content_type: "application/octet-stream" }), |{}| "stored")
		("GET", "/storage/get") => answered_storage(Storage.get!(bucket, param(request.query, "key")), |bytes| shown_bytes(request.query, bytes))
		("GET", "/storage/sha") => answered_storage(Storage.get!(bucket, param(request.query, "key")), |bytes| Sha256.hex(bytes))
		("GET", "/storage/range") => {
			range = { offset: number(request.query, "offset"), length: number(request.query, "length") }
			answered_storage(Storage.get_range!(bucket, param(request.query, "key"), range), |got| "${got.size.to_str()} ${shown_bytes(request.query, got.bytes)}")
		}
		("GET", "/storage/head") => answered_storage(Storage.head!(bucket, param(request.query, "key")), |info| "${info.size.to_str()} ${info.content_type} ${info.etag}")
		(_, "/storage/serve") => {
			# `whole=1`: the request's range dropped from the record, so the whole object is sent.
			served = if (param(request.query, "whole") == "1") { ..request, headers: request.headers.keep_if(|each| each.name != "range") } else request
			Storage.serve!(bucket, param(request.query, "key"), served, { content_type: param(request.query, "type"), cache_control: param(request.query, "cache") })
		}
		("POST", "/storage/delete") => answered_storage(Storage.delete!(bucket, param(request.query, "key")), |{}| "deleted")
		("POST", "/storage/start") => answered_storage(Storage.start_upload!(bucket, param(request.query, "key"), { content_type: param(request.query, "type") }), |upload| upload)
		("POST", "/storage/part") => answered_storage(Storage.upload_part!(bucket, param(request.query, "key"), param(request.query, "upload"), number(request.query, "number"), filled(request.query)), |etag| etag)
		("POST", "/storage/finish") => {
			# The parts, a `number etag` a line.
			parts = Server.text_of(request).split_on("\n").keep_if(|line| !line.is_empty()).map(
				|line|
					match line.split_first(" ") {
						Ok({ before: written, after: etag }) => { number: U64.from_str(written) ?? 0, etag }
						Err(_) => { number: 0, etag: line }
					},
			)
			answered_storage(Storage.finish_upload!(bucket, param(request.query, "key"), param(request.query, "upload"), parts), |{}| "finished")
		}
		("POST", "/storage/abort") => answered_storage(Storage.abort_upload!(bucket, param(request.query, "key"), param(request.query, "upload")), |{}| "aborted")
		("GET", "/storage/signed") =>
			match Storage.signed_url!(bucket, param(request.query, "key"), { method: param(request.query, "method"), expires_s: number(request.query, "expires") }) {
				Ok(url) => text(200, url)
				Err(BadExpiry) => text(400, "BadExpiry")
				Err(StorageErr(why)) => text(503, "StorageErr ${why}")
			}
		# Whether the bucket answers: S3, with these keys, for this bucket; a directory, written to (what
		# an app's health check asks).
		("GET", "/storage/check") =>
			match Storage.check!(bucket) {
				Ok({}) => text(200, "the bucket answers")
				Err(S3Err(refused)) => text(502, "S3Err ${Storage.said(refused)}")
				Err(StorageErr(why)) => text(503, "StorageErr ${why}")
			}
		_ => text(404, "no such storage route")
	}

## Bytes as text, or as numbers (`as=numbers`).
shown_bytes : Str, List(U8) -> Str
shown_bytes = |query, bytes| if (param(query, "as") == "numbers") numbers(bytes) else Str.from_utf8_lossy(bytes)

## A number in the query, or 0.
number : Str, Str -> U64
number = |query, name| U64.from_str(param(query, name)) ?? 0

## An upload, a `PUT` of bytes of any type: its body isn't read as JSON (its arg is `{}`), and the
## handler reads the bytes as they came.
upload_endpoint : Endpoint({}, {}, { size : U64, sha : Str })
upload_endpoint = Endpoint.local("PUT", "/endpoint/upload", |request, {}, {}| Ok({ size: request.body.len(), sha: Sha256.hex(request.body) }))

## An endpoint that reads JSON (or a form): the word, shouted.
shout_endpoint : Endpoint({}, { word : Str }, Str)
shout_endpoint = Endpoint.local("POST", "/endpoint/shout", |_, {}, { word }| Ok(word.with_ascii_uppercased()))

## An order, typed (D-038): a plain form, the runtime's form, an action and a script's JSON all post
## the same record, the form's fields read by its types.
Order : { item : Str, count : U64, price : Dec, gift : Bool, toppings : List(Str), size : [Small, Large] }

## POST /endpoint/order: the order, as the handler was given it.
order_endpoint : Endpoint({}, Order, Str)
order_endpoint = Endpoint.local("POST", "/endpoint/order", |_, {}, order| Ok(said_of(order)))

## POST /endpoint/photo: a form with a file (multipart, D-054): its title, the file's name as its
## field reads it, and the file as `Server.file` gives it, kept in a bucket in memory
## (`Storage.put_upload!`) and read back; it says its submission reads `/photos` again.
photo_endpoint : Endpoint({}, { title : Str, photo : Str }, { title : Str, photo : Str, type : Str, size : U64, sha : Str, files : U64 })
photo_endpoint = Endpoint.local(
	"POST",
	"/endpoint/photo",
	|request, {}, given| {
		Router.revalidate!(["/photos"])
		match Server.file(request, "photo") {
			Ok(upload) => {
				bucket = Storage.from_url("memory:photos") ?? crash "memory: is a bucket"
				kept =
					match Storage.put_upload!(bucket, "photos/${upload.name}", upload) {
						Ok({}) => Storage.get!(bucket, "photos/${upload.name}") ?? []
						Err(_) => []
					}
				Ok({ title: given.title, photo: given.photo, type: upload.type, size: kept.len(), sha: Sha256.hex(kept), files: Server.files(request).len() })
			}
			Err(NoFile) => Err(BadRequest("no photo"))
		}
	},
)

## POST /endpoint/order-json: the same, made as a function generic in its arg makes one
## (`local_json`): a form's fields are read as strings.
order_json_endpoint : Endpoint({}, { item : Str, count : Str }, Str)
order_json_endpoint = Endpoint.local_json("POST", "/endpoint/order-json", |_, {}, order| Ok("${order.count} ${order.item}"))

said_of : Order -> Str
said_of = |order| {
	size =
		match order.size {
			Small => "small"
			Large => "large"
		}
	"${order.count.to_str()} ${size} ${order.item} at ${order.price.to_str()}${if (order.gift) ", a gift" else ""}, with ${Str.join_with(order.toppings, " and ")}"
}

## `size` bytes counting up, 0 to 255 and again: every byte, and not text.
counting : U64 -> List(U8)
counting = |size| {
	var $out = []
	var $at = 0.U64
	while $at < size {
		$out = $out.append(($at % 256).to_u8_wrap())
		$at = $at + 1
	}
	$out
}

## `size` bytes, each `fill` (from the query).
filled : Str -> List(U8)
filled = |query| List.repeat(U8.from_str(param(query, "fill")) ?? 0, number(query, "size"))

## Bytes as numbers, `0,255,13`, and back.
numbers : List(U8) -> Str
numbers = |bytes| Str.join_with(bytes.map(|byte| byte.to_str()), ",")

from_numbers : Str -> List(U8)
from_numbers = |said| if (said.is_empty()) [] else said.split_on(",").map(|each| U8.from_str(each) ?? 0)

answered_actor : Try(I64, [ActorErr(Str)]) -> Server.Response
answered_actor = |result|
	match result {
		Ok(count) => text(200, count.to_str())
		Err(ActorErr(why)) => text(500, why)
	}

noted : Db.Nullable(Str) -> Str
noted = |note|
	match note {
		Null => "-"
		Some(said) => said
	}

strings : U64, List(Str) -> List(Str)
strings = |n, made| if (n == 0) made else strings(n - 1, made.append("row ${n.to_str()}"))

# ---- Jobs ----

## Writes what it was told to the job log.
note_job : Job.Kind(_, { run : Str, said : Str })
note_job = Job.define(
	"note",
	|_context, { run, said }|
		match Db.run!("insert into job_log (kind, said) values ('note', $1)", [Text("${run} ${said}")]) {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		},
)

## Fails `fails` times, then writes to the job log.
flaky_job : Job.Kind(_, { run : Str, fails : I64 })
flaky_job = Job.define(
	"flaky",
	|_context, { run, fails }| {
		tried : Try(List({ tries : I64 }), [DbErr(Str), BadRow(Str)])
		tried = Db.all!("insert into flaky (name, tries) values ($1, 1) on conflict (name) do update set tries = flaky.tries + 1 returning tries::int8", [Text(run)])
		match tried {
			Ok([{ tries }]) if tries <= fails => Err("not yet (try ${tries.to_str()})")
			Ok(_) =>
				match Db.run!("insert into job_log (kind, said) values ('flaky', $1)", [Text("${run} done")]) {
					Ok(_) => Ok({})
					Err(DbErr(why)) => Err(why)
				}
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
		}
	},
)

## Crashes, every time.
crash_job : Job.Kind(_, { run : Str })
crash_job = Job.define("crash", |_context, { run }| if (run != "") crash "a job that always crashes" else Ok({}))

## Sends an email.
mail_job : Job.Kind(_, { to : Str, run : Str })
mail_job = Job.define(
	"mail",
	|_context, { to, run }|
		match Email.send!({ to, subject: "From a job ${run}", text: "Sent by a job.", html: "" }) {
			Ok({}) => Ok({})
			Err(EmailErr(why)) => Err(why)
		},
)

## Every second (`crons`): a tick in the job log.
tick_job : Job.Kind(_, {})
tick_job = Job.define(
	"tick",
	|_context, {}|
		match Db.run!("insert into job_log (kind, said) values ('tick', 'tick')", []) {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		},
)

## Writes what the environment says to the job log: a variable, and whether the server runs under
## `--dev`.
env_job : Job.Kind(_, { run : Str, name : Str })
env_job = Job.define(
	"env",
	|_context, { run, name }| {
		value =
			match Env.var!(name) {
				Ok(found) => found
				Err(NotFound) => "(none)"
			}
		dev = if (Env.dev!({})) "dev" else "not dev"
		match Db.run!("insert into job_log (kind, said) values ('env', $1)", [Text("${run} ${value}, ${dev}")]) {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		}
	},
)

## Fails every time: tried as many times as its kind says (two), then failed for good.
twice_job : Job.Kind(_, { run : Str })
twice_job = Job.define_with("twice", { attempts: 2, timeout_ms: 0 }, |_context, { run }| Err("fails every time (${run})"))

## Waits on Postgres, another server or a socket (`on`) longer than its limit (300 ms), and ignores
## what it is told: the limit cuts it off anyway, and it never writes to the job log. `spin` and
## `grow` never wait: Roc that loops forever, the first on numbers alone, the second making and
## dropping text; the limit cuts them off too (D-057). `on: "none"` is done in time.
slow_job : Job.Kind(_, { run : Str, on : Str, url : Str })
slow_job = Job.define_with(
	"slow",
	{ attempts: 2, timeout_ms: 300 },
	|_context, { run, on, url }| {
		if on == "db" {
			slept : Try(List({ one : I64 }), [DbErr(Str), BadRow(Str)])
			slept = Db.all!("select 1::int8 as one from pg_sleep(30)", [])
			_ = slept
			{}
		} else if on == "http" {
			_ = Http.fetch!(url, {})
			{}
		} else if on == "tcp" {
			match Tcp.connect!("127.0.0.1", U16.from_str(url) ?? 0) {
				Ok(tcp) => {
					_ = tcp.read_until!('\n')
					{}
				}
				Err(_) => {}
			}
		} else if on == "spin" {
			var $n = 1
			while $n != 0 {
				$n = ($n * 31 + 7) % 1_000_003 + 1
			}
			_ = $n
			{}
		} else if on == "grow" {
			var $text = ""
			var $n = 1
			while $n != 0 {
				$text = if ($text.count_utf8_bytes() > 4096) "" else Str.concat($text, "grown ${$n.to_str()} ")
				$n = ($n % 1000) + 1
			}
			_ = $text
			{}
		} else {
			{}
		}
		match Db.run!("insert into job_log (kind, said) values ('slow', $1)", [Text("${run} finished")]) {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		}
	},
)

# ---- Actors ----

## A count, one per key, that outlives requests and restarts: a kind (D-068, a type with `name` and
## `initial`) and its methods.
Counter := [].{
	name = |{}| "counter"
	initial = |_key| { count: 0 }

	## The type of its methods: the kind, the app's context (`--context-file`'s text), the key, the
	## count; then each one's input and reply.
	Method(input, reply) : Actor.Method(Counter, Str, Str, { count : I64 }, input, reply)

	## Crashes: the state stays as it was.
	boom : Counter.Method({}, I64)
	boom = Actor.method("boom", |{ state, .. }| if (state.count >= 0) crash "an actor that crashed" else { state, reply: 0 })

	## A turn taking `input` milliseconds (Postgres sleeps).
	nap : Counter.Method(I64, I64)
	nap = Actor.method(
		"nap",
		|{ state, input, .. }| {
			napped : Try(List({ one : I64 }), [DbErr(Str), BadRow(Str)])
			napped = Db.all!("select 1::int8 as one from pg_sleep($1::float8 / 1000)", [Int(input)])
			_ = napped
			{ state, reply: state.count }
		},
	)

	## Adds `input` to the count: the count after.
	add : Counter.Method(I64, I64)
	add = Actor.method("add", |{ state, input, .. }| { state: { count: state.count + input }, reply: state.count + input })

	## The count.
	get : Counter.Method({}, I64)
	get = Actor.method("get", |{ state, .. }| { state, reply: state.count })
}

## The counter's `add` as a caller built against an older version of it would see it: the same kind
## and method, an input it doesn't take. Not in `program.actors`: the counter's `add` gets the call.
stale_add : Counter.Method(Str, I64)
stale_add = Actor.method("add", |{ state, .. }| { state, reply: state.count })

## A method the counter doesn't have (a caller built against a newer version of it).
counter_reset : Counter.Method({}, I64)
counter_reset = Actor.method("reset", |{ .. }| { state: { count: 0 }, reply: 0 })

## A kind the app doesn't list: the host refuses a call to it.
Ghost := [].{
	name = |{}| "ghost"
	initial = |_key| {}

	add : Actor.Method(Ghost, Str, Str, {}, I64, I64)
	add = Actor.method("add", |{ state, .. }| { state, reply: 0 })
}

## Asks others: the counter of the same key (`relay`), itself (`itself`, which it can't), or the
## bouncer, which asks it back (`cycle`, which the bouncer can't).
Mirror := [].{
	name = |{}| "mirror"
	initial = |_key| {}

	Method(input, reply) : Actor.Method(Mirror, Str, Str, {}, input, reply)

	relay : Mirror.Method(Str, I64)
	relay = Actor.method("relay", |{ state, input, .. }| { state, reply: asked(Counter.get.ask!(input, {})) })

	itself : Mirror.Method(Str, I64)
	itself = Actor.method("itself", |{ state, input, .. }| { state, reply: asked(Mirror.relay.ask!(input, input)) })

	cycle : Mirror.Method(Str, I64)
	cycle = Actor.method("cycle", |{ state, input, .. }| { state, reply: asked(Bouncer.back.ask!(input, input)) })
}

## Asks the mirror of the same key: asked by it, that waits forever, so it is refused.
Bouncer := [].{
	name = |{}| "bouncer"
	initial = |_key| {}

	back : Actor.Method(Bouncer, Str, Str, {}, Str, I64)
	back = Actor.method("back", |{ state, input, .. }| { state, reply: asked(Mirror.relay.ask!(input, input)) })
}

## What another actor answered; its refusal crashes the turn, which tells the asker why.
asked : Try(I64, [ActorErr(Str)]) -> I64
asked = |answer|
	match answer {
		Ok(count) => count
		Err(ActorErr(why)) => crash why
	}

## Counts its own ticks: `start` sets a timer for itself, and each tick sets the next
## (`me.after!`) until `stop` cancels the one waiting (`Actor.cancel!`).
Ticker := [].{
	name = |{}| "ticker"
	initial = |_key| { ticks: 0, timer: 0, on: Bool.False }

	Method(input, reply) : Actor.Method(Ticker, Str, Str, { ticks : I64, timer : U64, on : Bool }, input, reply)

	start : Ticker.Method(U64, I64)
	start = Actor.method("start", |{ me, state, input, .. }| { state: { ticks: state.ticks, timer: me.after!(input, Ticker.tick({}), input), on: Bool.True }, reply: state.ticks })

	## A tick sets the next: a method that names itself, so a function of `{}`.
	tick : {} -> Ticker.Method(U64, I64)
	tick = |{}|
		Actor.method(
			"tick",
			|{ me, state, input, .. }|
				if (state.on) {
					{ state: { ticks: state.ticks + 1, timer: me.after!(input, Ticker.tick({}), input), on: Bool.True }, reply: state.ticks + 1 }
				} else {
					{ state, reply: state.ticks }
				},
		)

	stop : Ticker.Method({}, I64)
	stop = Actor.method(
		"stop",
		|{ state, .. }| {
			Actor.cancel!(state.timer)
			{ state: { ticks: state.ticks, timer: 0, on: Bool.False }, reply: state.ticks }
		},
	)

	ticks : Ticker.Method({}, I64)
	ticks = Actor.method("ticks", |{ state, .. }| { state, reply: state.ticks })
}

# ---- Components the server renders, and the endpoints they read ----

## The probe, on a page of its own, with the page's text after it.
probing! : {} => Html
probing! = |{}| Html.element("html", [], [Html.element("body", [], [Html.component(|| probe!({})), Html.element("p", [], [Html.text("after")])])])

## GET /probe/shout/:word: the word, shouted. The probe reads it while the server renders it.
shout_at : Str -> Endpoint({}, {}, Str)
shout_at = |word| Endpoint.local("GET", "/probe/shout/${Server.encode_segment(word)}", |request, {}, {}| Ok(Server.decode_segment(request.path.drop_prefix("/probe/shout/")).with_ascii_uppercased()))

shout! : Str => Str
shout! = |word| Endpoint.get!(shout_at(word))

## GET /probe/member, behind a middleware of its own (`members_only`), as a route file's endpoint
## is behind the file's: who the member is, from what the middleware handed on, and the request.
member_probe : Endpoint({ started : Str, member : Str }, {}, Str)
member_probe = Endpoint.local("GET", "/probe/member", |request, handed, {}| Ok("member ${handed.member}, ${request.method} ${request.path}"))

member! : {} => Str
member! = |{}| Endpoint.get!(member_probe)

## ---- Channels (D-020), as `Generated/Api` and `Generated/Routes` would answer them ----

## A member, as their cookies say: their name, their org, and when their session ends (`until`, ms
## since the epoch; none: never).
Member : { name : Str, org : Str, until : U64 }

## What is published on an org's news.
News : { title : Str, n : U64 }

## What a page may say on an org's news.
Said : [Hello(Str), Fail]

## The members' middleware: their cookies, or 401.
member_of : Middleware(Str, Member)
member_of = Middleware.make(
	|request, _context, next!|
		match Server.cookie(request, "member") {
			Ok(name) => next!(request, { name, org: Server.cookie(request, "org") ?? "", until: U64.from_str(Server.cookie(request, "until") ?? "") ?? 9_999_999_999_999 })
			Err(Missing) => Server.refused(401, "sign in")
		},
)

## An org's news, at /news/<org>: its check lets in a member of the org, as who they are, while
## their session lasts.
org_news : Str -> Endpoint(Member, {}, Channel(Str, News, Said))
org_news = |org|
	Endpoint.local(
		"CHANNEL",
		"/news/${Server.encode_segment(org)}",
		|_request, member, {}|
			if member.org != org {
				Err(Forbidden)
			} else if Time.now_millis!({}) > member.until {
				Err(Status(401, "the session has ended"))
			} else {
				Ok(Channel.allow(member.name))
			},
	)

## The clock, at /clock: anyone, no hooks.
clock : Endpoint(Str, {}, Channel({}, U64, []))
clock = Endpoint.local("CHANNEL", "/clock", |_request, _context, {}| Ok(Channel.allow({})))

## The host's asks about a subscription: each channel's check behind its middleware, then its hooks.
## An org's news sends a subscriber a welcome first (`on_open!`, which logs who, from which tab), and
## hears what pages say (`receive!`): a hello is published to the org, `Fail` is refused.
channel! : Server.Request => Server.Response
channel! = |request| {
	segments = request.path.split_on("/").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)
	if segments.len() == 2 and segments.get(0) == Ok("news") {
		org = segments.get(1) ?? ""
		Middleware.run!(
			member_of,
			request,
			"",
			|passed, member|
				Endpoint.channel!(
					org_news(org),
					passed,
					member,
					{
						opened!: |who, tab| {
							Log.info!("channel opened", { channel: passed.path, who, tab })
							[{ title: "welcome, ${who} (${if (tab.is_empty()) "no tab" else "a tab"})", n: 0 }]
						},
						received!: Endpoint.receiving(
							org_news(org),
							|who, _tab, said|
								match said {
									Hello(words) => {
										Endpoint.publish!(org_news(org), { title: "${who} says ${words}", n: 0 })
										Ok({})
									}
									Fail => Err(BadRequest("not that"))
								},
						),
						closes: Bool.True,
					},
				),
		)
	} else if segments == ["clock"] {
		Endpoint.channel!(clock, request, "", { opened!: |_who, _tab| [], received!: |_who, _tab, _said| Err(Status(404, "/clock takes nothing pages say")), closes: Bool.False })
	} else {
		text(404, "no channel at ${request.path}")
	}
}

## A subscription has ended: an org's news logs who, from which tab, and why (its `on_close!`).
channel_closed! : Server.Request => Server.Response
channel_closed! = |request| {
	segments = request.path.split_on("/").keep_if(|segment| !segment.is_empty()).map(Server.decode_segment)
	if segments.len() == 2 and segments.get(0) == Ok("news") {
		Endpoint.closed!(
			org_news(segments.get(1) ?? ""),
			request,
			|who, tab, why| {
				reason =
					match why {
						Dropped => "dropped"
						Gone => "gone"
						Refused(said) => "refused: ${said}"
					}
				Log.info!("channel closed", { channel: request.path, who, tab, why: reason })
			},
		)
	} else {
		Server.response(204, [], "")
	}
}

## GET /probe/signed_in: who is signed in, behind a gate that sends anyone else to sign in (303),
## forgetting their stale session: what a layout's read meets for a signed-out visitor.
signed_in_probe : Endpoint({ started : Str, member : Str }, {}, Str)
signed_in_probe = Endpoint.local("GET", "/probe/signed_in", |_, handed, {}| Ok("signed in as ${handed.member}"))

signed_in! : {} => Str
signed_in! = |{}| Endpoint.get!(signed_in_probe)

## The gate: a member goes on; anyone else is sent to `/login`, their `session` cookie cleared.
gate : Middleware({ started : Str }, { started : Str, member : Str })
gate = Middleware.make(
	|request, context, next!|
		match Server.cookie(request, "member") {
			Ok(name) => next!(request, { started: context.started, member: name })
			Err(Missing) => Server.without_cookie(Server.redirect("/login"), "session")
		},
)

## POST /probe/measure: takes and answers `F64`s, which JSON writes as numbers: a number it can't
## (an infinity, dividing by zero) is a 500 that says so.
measure_endpoint : Endpoint({}, { seconds : F64, parts : F64 }, { seconds : F64, each : F64 })
measure_endpoint = Endpoint.local("POST", "/probe/measure", |_, {}, { seconds, parts }| Ok({ seconds, each: seconds / parts }))

## POST /probe/length: answers a `Try`, as JSON `{"Ok":…}` or `{"Err":…}`.
length_endpoint : Endpoint({}, Str, Try(U64, [Empty]))
length_endpoint = Endpoint.local("POST", "/probe/length", |_, {}, word| Ok(if (word.is_empty()) Err(Empty) else Ok(word.count_utf8_bytes())))

## A badge: a nominal type whose JSON encoder and parser are derived, as an app's own types are.
Badge := { name : Str }.{
	encoder_for : _
	parser_for : _
}

## Someone as `badged` hands them on: a badge beside other fields, one an `F64`.
Holder : { name : Str, badge : Badge, since : F64 }

## POST /probe/award: its context, body and answer each hold a nominal type with a derived encoder
## beside other fields, and an `F64`: the platform writes the answer with `Json.to_str_try`, which
## crashes the compiler for such a value unless its error type is named
## (test/compiler-bugs/json-to-str-try-nominal).
award_endpoint : Endpoint({ started : Str, holder : Holder }, { badge : Badge, points : F64 }, { badge : Badge, points : F64, holder : Holder })
award_endpoint = Endpoint.local("POST", "/probe/award", |_, handed, { badge, points }| Ok({ badge, points: points * 2, holder: handed.holder }))

## Hands on a holder with a badge.
badged : Middleware({ started : Str }, { started : Str, holder : Holder })
badged = Middleware.make(|request, context, next!| next!(request, { started: context.started, holder: { name: "Ada", badge: { name: "admin" }, since: 0.5 } }))

## A member: whoever the `member` cookie names, handed on as `member`; anyone else is refused (401).
members_only : Middleware({ started : Str }, { started : Str, member : Str })
members_only = Middleware.make(
	|request, context, next!|
		match Server.cookie(request, "member") {
			Ok(name) => if (name.is_empty()) Server.refused(401, "members only") else next!(request, { started: context.started, member: name })
			Err(Missing) => Server.refused(401, "members only")
		},
)

## A context nothing provides: reading it fails, and <Errored> shows why.
missing : Context({ name : Str })
missing = Context.required("Probe.missing")

## Signals, memos, an endpoint read, a keyed <For>, an if's part, an <Errored> that catches, and
## attributes of each kind.
probe! : {} => Html
probe! = |{}| {
	(count!, _set_count!) = Solid.create_signal!(41.U64)
	doubled! = Solid.create_memo!(|| count!() * 2)
	(names!, _set_names!) = Solid.create_signal!(["ada", "grace"])
	shouted! = Solid.create_memo!(|| shout!("hello"))
	Html.element(
		"div",
		[Html.attr("class", "probe"), Html.class_of("big", || count!() > 40), Html.attr_of("title", || "count ${count!().to_str()}")],
		[
			Html.element("p", [], [Html.text_of(|| (count!() + 1).to_str())]),
			Html.element("p", [], [Html.text_of(|| doubled!().to_str())]),
			Html.element("p", [], [Html.text_of(|| shouted!())]),
			Html.element(
				"ul",
				[],
				[
					For.view_with_keyed!({
						each!: || names!(),
						keyed: |name| name,
						fallback: Html.text("none"),
						children: |name!, index!| Html.element("li", [], [Html.text_of(|| "${index!().to_str()} ${name!()}")]),
					}),
				],
			),
			# What a hole's if writes (D-070): the part its branch makes, the else its other branch.
			Html.branched(|| Ok(if (count!() > 100) "0" else "1"), || if (count!() > 100) Html.text("big") else Html.element("p", [Html.attr("class", "small")], [Html.text("small")])),
			# An if with an else if, the part of the first branch that holds; and a part keyed by a value
			# (the case its text): a part each.
			Html.branched(|| Ok(if (count!() > 100) "0" else if (count!() > 10) "1" else "2"), || if (count!() > 100) Html.text("big") else if (count!() > 10) Html.element("p", [Html.attr("class", "matched")], [Html.text_of(|| count!().to_str())]) else Html.text("none")),
			Html.switched(|| if (count!() > 10) Ok(Str.inspect(count!())) else Err(None), || Html.element("p", [Html.attr("class", "keyed")], [Html.text(count!().to_str())]), Html.empty({})),
			# A store's parts (D-053): read once here, where nothing runs again, and holes all the same.
			{
				(store, _) = Solid.create_store!({ name: "ada", n: 41.U64 })
				Html.element("p", [Html.attr("class", "store")], [Html.text_of(|| store.get!(|s| s.name)), Html.text_of(|| store.get!(|s| s.n).to_str())])
			},
			Errored.view!({
				fallback: |problem, _| Html.element("p", [Html.attr("class", "failed")], [Html.text_of(|| problem)]),
				children: [Html.element("p", [], [Html.text_of(|| Solid.use_context!(missing).name)])],
			}),
			Html.void("input", [Html.flag("disabled", Bool.True), Html.attr("value", "a & b")]),
			# An endpoint behind its middleware, read while the server renders: answered by its route,
			# in-process, with the page's cookies; refused, the <Errored> shows why.
			Errored.view!({
				fallback: |problem, _| Html.element("p", [Html.attr("class", "refused")], [Html.text_of(|| problem)]),
				children: [Html.element("p", [Html.attr("class", "member")], [Html.text_of(|| member!({}))])],
			}),
			# Where the page is (`Router.location!`): the request's path and query.
			Html.element("p", [Html.attr("class", "at")], [Html.text_of(|| where!({}))]),
			# Holes that read nothing that changes (D-052): static, written without comments.
			Html.element("p", [Html.attr("class", "untracked")], [Html.text_of(|| Solid.untrack!(|| count!()).to_str())]),
			Html.html_of(|| Html.element("b", [], [Html.text("static")])),
			# Raw text, a doctype and the static attributes, as the walker renders them.
			Html.doctype({}),
			Html.element("style", [Html.class_if("on", Bool.True), Html.class_if("off", Bool.False), Html.attr("class", "s")], [Html.source_text("p > b { content: \"&\" }")]),
			Html.element("a", [Html.optional("title", ""), Html.optional("href", "javascript:x"), Html.optional("rel", "next")], [Html.text("<a & b>")]),
		],
	)
}

## Where the page is, as `Router.location!` says.
where! : {} => Str
where! = |{}| {
	at = Router.location!({})
	"${at.path} ? ${at.query}"
}

# ---- Pages of components: what a route answers with `Page`, which the host renders ----

## A page whose "layout" asks who is signed in, behind a gate (an endpoint's middleware),
## with an <Errored> around it, and one around nothing: for a signed-out visitor, the gate's redirect
## is the page's answer, caught or not.
gated! : {} => Html
gated! = |{}|
	Html.element(
		"html",
		[],
		[
			Html.element(
				"body",
				[],
				[
					Html.element("header", [], [Html.text_of(|| signed_in!({}))]),
					Errored.view!({ fallback: |problem, _| Html.text_of(|| problem), children: [Html.element("p", [], [Html.text_of(|| signed_in!({}))])] }),
				],
			),
		],
	)

# ---- Endpoint reads (D-023): a page's data from a GET endpoint, read as the server renders it ----

## GET /reads, asked for JSON (a browser's GET of /reads is the page): what the page shows, from the
## request the in-process GET is: the page's query, and its cookie and a header. Asked as a cache
## asks (`if-none-match`), it answers 304, which a page's read would fail on.
reads_endpoint : Endpoint({}, {}, { weeks : Str, member : Str, probe : Str })
reads_endpoint = Endpoint.local(
	"GET",
	"/reads",
	|request, {}, {}|
		if Server.header(request, "if-none-match").is_ok() {
			Err(Answer(Server.response(304, [], "")))
		} else {
			Ok({ weeks: param(request.query, "weeks"), member: Server.cookie(request, "member") ?? "nobody", probe: Server.header(request, "x-probe") ?? "" })
		},
)

## GET /reads/member, behind the gate: who is signed in (a signed-out visitor is sent to /login).
member_endpoint : Endpoint({ started : Str, member : Str }, {}, Str)
member_endpoint = Endpoint.local("GET", "/reads/member", |_, handed, {}| Ok("member ${handed.member}"))

## GET /reads/missing: a refusal, 404.
missing_endpoint : Endpoint({}, {}, Str)
missing_endpoint = Endpoint.local("GET", "/reads/missing", |_, {}, {}| Err(NotFound))

## GET /reads/flash: the flash a plain form's post left in the page's cookie, as the handler reads it.
flash_endpoint : Endpoint({}, {}, Str)
flash_endpoint = Endpoint.local(
	"GET",
	"/reads/flash",
	|_, {}, {}|
		match Server.flash!({}) {
			Ok(flash) => Ok("${flash.url} ${flash.status.to_str()} ${flash.body}")
			Err(NoFlash) => Ok("no flash")
		},
)

## A page that reads GET endpoints as the server renders it: its own data, with the page's query,
## never pending (`is_pending!`: the server renders final values); one that refuses, as a value
## (`read!`) and as a failure an <Errored> shows (`get!`), the same URL asked once; and one inside a
## <NoHydration>, which isn't noted for the browser.
reading! : {} => Html
reading! = |{}| {
	data! = Solid.create_memo!(|| Endpoint.get!(Endpoint.with_query(reads_endpoint, Router.location!({}).query)))
	Html.element(
		"html",
		[],
		[
			Html.element(
				"body",
				[],
				[
					Html.element("p", [Html.attr("class", "data")], [Html.text_of(|| "${data!().weeks} ${data!().member} ${data!().probe}")]),
					Html.element(
						"p",
						[Html.attr("class", "pending")],
						[
							Html.text_of(
								||
									if Solid.is_pending!(data!) {
										"pending"
									} else {
										"settled"
									},
							),
						],
					),
					Html.element(
						"p",
						[Html.attr("class", "missing")],
						[
							Html.text_of(
								||
									match Endpoint.read!(missing_endpoint) {
										Ok(found) => found
										Err(problem) => Server.explain(problem)
									},
							),
						],
					),
					Errored.view!({ fallback: |problem, _| Html.element("p", [Html.attr("class", "refused")], [Html.text_of(|| problem)]), children: [Html.text_of(|| Endpoint.get!(missing_endpoint))] }),
					Html.no_hydration([Html.element("p", [Html.attr("class", "static")], [Html.text_of(|| Endpoint.get!(Endpoint.with_query(reads_endpoint, "weeks=region")).weeks)])]),
				],
			),
		],
	)
}

## A page that reads the address its GET came from, as the server renders it: the in-process read
## has the page's.
peer_page! : {} => Html
peer_page! = |{}| Html.element("html", [], [Html.element("body", [], [Html.element("p", [Html.attr("class", "peer")], [Html.text_of(|| Endpoint.get!(peer_endpoint))])])])

peer_endpoint : Endpoint({}, {}, Str)
peer_endpoint = Endpoint.remote("GET", "/peer-json")

## A page whose layout reads an endpoint behind the gate, with an <Errored> around it: for a
## signed-out visitor, the gate's redirect is the page's answer (D-019).
read_gated! : {} => Html
read_gated! = |{}|
	Html.element(
		"html",
		[],
		[
			Html.element(
				"body",
				[],
				[Errored.view!({ fallback: |problem, _| Html.text_of(|| problem), children: [Html.element("header", [], [Html.text_of(|| Endpoint.get!(member_endpoint))])] })],
			),
		],
	)

## A page that reads an endpoint whose handler reads the flash a plain form's post left.
read_flash! : {} => Html
read_flash! = |{}| Html.element("html", [], [Html.element("body", [], [Html.element("p", [Html.attr("class", "flash")], [Html.text_of(|| Endpoint.get!(flash_endpoint))])])])

## A page whose `<title>` and `<textarea>` (RCDATA: the parser reads markup there as text) hold
## holes: written without comments.
rcdata! : {} => Html
rcdata! = |{}| {
	(count!, _set_count!) = Solid.create_signal!(2.U64)
	Html.element(
		"html",
		[],
		[
			Html.element("head", [], [Html.element("title", [], [Html.text_of(|| count!().to_str()), Html.text(" notes")])]),
			Html.element("body", [], [Html.element("textarea", [], [Html.text_of(|| "<b>${count!().to_str()}</b>")]), Html.element("p", [], [Html.text_of(|| count!().to_str())])]),
		],
	)
}

## A page with a `<NoHydration>`, which the browser never hydrates: static markup between its
## markers, with none inside (a hole, an `if`'s part, a `<For>`, an `<Errored>` that failed, a component,
## one inside another); the GET it reads isn't recorded for the page, the same one read outside it
## is.
region! : {} => Html
region! = |{}| {
	(count!, _set_count!) = Solid.create_signal!(3.U64)
	(names!, _set_names!) = Solid.create_signal!(["ada", "grace"])
	Html.element(
		"html",
		[],
		[
			Html.element(
				"body",
				[],
				[
					Html.element("p", [Html.attr("class", "count")], [Html.text_of(|| count!().to_str())]),
					Html.no_hydration([
						Html.element("p", [], [Html.text_of(|| count!().to_str()), Html.text(" & "), Html.text_of(|| shout!("quiet"))]),
						Html.branched(|| Ok(if (count!() > 1) "0" else "1"), || if (count!() > 1) Html.text("many") else Html.text("few")),
						Html.element(
							"ul",
							[],
							[
								For.view_with_keyed!({
									each!: || names!(),
									keyed: |name| name,
									fallback: Html.text("none"),
									children: |name!, _index!| Html.element("li", [], [Html.text_of(|| name!())]),
								}),
							],
						),
						Errored.view!({
							fallback: |problem, _| Html.element("i", [], [Html.text_of(|| problem)]),
							children: [Html.text_of(|| Solid.use_context!(missing).name)],
						}),
						Html.component(|| Html.element("b", [], [Html.text_of(|| "made once")])),
						Html.no_hydration([Html.text("nested")]),
					]),
					Html.element("p", [Html.attr("class", "loud")], [Html.text_of(|| shout!("page"))]),
				],
			),
		],
	)
}

## A page with a handler inside its `<NoHydration>` (a component put it there): it would never run,
## so the server refuses to render it.
region_handler! : {} => Html
region_handler! = |{}|
	Html.element(
		"html",
		[],
		[Html.element("body", [], [Html.no_hydration([Html.component(|| Html.element("button", [Html.on("click", || {})], [Html.text("dead")]))])])],
	)

## A page with an effect, a cleanup and a timer, none of which runs on the server: what they would
## write isn't written.
effects! : {} => Html
effects! = |{}| {
	(said!, set_said!) = Solid.create_signal!("not run")
	Solid.create_effect!(|| said!(), |_| set_said!("an effect ran"))
	Solid.on_cleanup!(|| set_said!("a cleanup ran"))
	_ = Solid.set_interval!(1, || set_said!("a timer ran"))
	_ = Solid.set_timeout!(1, || set_said!("a timeout ran"))
	Html.element("html", [], [Html.element("body", [], [Html.element("p", [Html.attr("class", "said")], [Html.text_of(|| said!())])])])
}

## POST /flash/join, from the joining page's form (`name=Ada`): a welcome, or a refusal.
join_endpoint : Endpoint({}, { name : Str }, Str)
join_endpoint = Endpoint.local(
	"POST",
	"/flash/join",
	|_, {}, { name }|
		if name.trim().is_empty() {
			Err(BadRequest("a member has a name"))
		} else if name == "Al" {
			Err(Conflict("Al is taken"))
		} else {
			Ok("Welcome, ${name}")
		},
)

## POST /flash/away: an answer of its own, a redirect that sets a cookie.
away_endpoint : Endpoint({}, {}, Str)
away_endpoint = Endpoint.local("POST", "/flash/away", |_, {}, {}| Err(Answer(Server.with_cookie(Server.redirect("/members"), "member", "Ada"))))

## A sign-in page: the joining form with a password, each field filled in again from the submission
## (`field!`), as a careless page would: the password never is (`Html` leaves its `value` out), and
## the page's note of the flash for the browser leaves it out too.
signing_in! : {} => Html
signing_in! = |{}| {
	submission = Router.use_submission!(join_endpoint)
	problem =
		match submission.error!() {
			Ok(said) => Server.explain(said)
			Err(NoError) => ""
		}
	Html.element(
		"html",
		[],
		[
			Html.element(
				"body",
				[],
				[
					Html.element(
						"form",
						[Html.attr("method", "post"), Html.attr("action", Endpoint.url_of(join_endpoint))],
						[
							Html.void("input", [Html.attr("name", "name"), Html.attr_of("value", || submission.field!("name"))]),
							Html.void("input", [Html.attr("type", "password"), Html.attr("name", "secret"), Html.attr_of("value", || submission.field!("secret"))]),
						],
					),
					Html.element("p", [Html.attr("class", "problem")], [Html.text(problem)]),
				],
			),
		],
	)
}

## The joining page: the flash as it came (`Server.flash!`), and the form's submission
## (`use_submission!`): what was typed, and the refusal or the welcome.
joining! : {} => Html
joining! = |{}| {
	submission = Router.use_submission!(join_endpoint)
	flashed =
		match Server.flash!({}) {
			Ok(flash) => "${flash.url} ${flash.status.to_str()} ${Str.join_with(flash.fields.map(|field| "${field.name}=${field.value}"), "&")}"
			Err(NoFlash) => "no flash"
		}
	problem =
		match submission.error!() {
			Ok(said) => Server.explain(said)
			Err(NoError) => ""
		}
	welcome =
		match submission.result!() {
			Ok(said) => said
			Err(NoResult) => ""
		}
	typed =
		match submission.input!() {
			Ok({ name }) => name
			Err(NoInput) => "(nothing)"
		}
	Html.element(
		"html",
		[],
		[
			Html.element(
				"body",
				[],
				[
					Html.element("p", [Html.attr("class", "flash")], [Html.text(flashed)]),
					Html.element(
						"form",
						[Html.attr("method", "post"), Html.attr("action", Endpoint.url_of(join_endpoint))],
						[Html.void("input", [Html.attr("name", "name"), Html.attr_of("value", || submission.field!("name"))])],
					),
					Html.element("p", [Html.attr("class", "problem")], [Html.text(problem)]),
					Html.element("p", [Html.attr("class", "welcome")], [Html.text(welcome)]),
					Html.element("p", [Html.attr("class", "typed")], [Html.text(typed)]),
					Html.element("p", [Html.attr("class", "pending")], [Html.text(if (submission.pending!()) "pending" else "not pending")]),
				],
			),
		],
	)
}

## A page of components, answered 200 unless it says otherwise (`<HttpStatusCode>`).
## A page that waits as it renders: in a memo, in a read its <Errored> catches (the endpoint refuses,
## after waiting too), and in a hole after them, which crashes after its wait with `crash=yes`. Each
## says which request it is (`id`), so a test can tell them apart when many render at once.
waiting! : {} => Html
waiting! = |{}| {
	at = Router.location!({})
	id = param(at.query, "id")
	ms = number(at.query, "ms")
	waited! = Solid.create_memo!(
		|| {
			_ = Live.next!(ms)
			"waited ${id}"
		},
	)
	Html.element(
		"html",
		[],
		[
			Html.element(
				"body",
				[],
				[
					Html.element("p", [Html.attr("class", "waited")], [Html.text_of(|| waited!())]),
					Errored.view!({
						fallback: |problem, _| Html.element("p", [Html.attr("class", "refused")], [Html.text_of(|| problem)]),
						children: [Html.text_of(|| Endpoint.get!(Endpoint.with_query(refusing_endpoint, at.query)))],
					}),
					Html.element(
						"p",
						[Html.attr("class", "after")],
						[
							Html.text_of(
								|| {
									_ = Live.next!(ms)
									if (param(at.query, "crash") == "yes") crash "crash ${id} as it rendered" else "after ${id}"
								},
							),
						],
					),
				],
			),
		],
	)
}

## Refuses (409) after waiting `ms`, saying which request it was (`id`).
refusing_endpoint : Endpoint({}, {}, Str)
refusing_endpoint = Endpoint.local(
	"GET",
	"/wait/refuse",
	|request, {}, {}| {
		_ = Live.next!(number(request.query, "ms"))
		Err(Conflict("refused ${param(request.query, "id")}"))
	},
)

## `n` calls deep, each doing something with what the one below it gave back (so it can't be a loop).
deep : U64 -> U64
deep = |n|
	if (n == 0) 0 else {
		below = deep(n - 1)
		if (below > 1000) below - 1000 else below + 7
	}

page : ({} => Html) -> Server.Response
page = |view!| { status: 200, headers: [], body: Page(view!) }

## A document with no doctype (the host writes one): a signal, a memo that reads an endpoint, a
## <Loading> (on the server what is inside renders), an <Errored> that catches a failure, one around
## an endpoint behind its middleware (refused without a cookie), and where it is.
## A page whose root tells the app, as `Generated/Root.roc` does (`Router.app!`, D-040): its
## bootstrap carries the build's id (`data-build`), for the browser to check a page it fetches against.
app_page! : {} => Html
app_page! = |{}| {
	Router.app!({ build: "7f3a91c2", dev: Bool.False, routes: "{\"pages\":[{\"path\":\"/page-app\",\"levels\":[]}],\"error\":null}" })
	Html.element("html", [], [Html.element("body", [], [Html.element("p", [], [Html.text_of(|| if (Router.is_routing!({})) "routing" else "here")])])])
}

document! : {} => Html
document! = |{}| {
	(count!, _set_count!) = Solid.create_signal!(1.U64)
	shouted! = Solid.create_memo!(|| shout!("page"))
	Html.element(
		"html",
		[Html.attr("lang", "en")],
		[
			Html.element("head", [], [Html.element("title", [], [Html.text("A page")])]),
			Html.element(
				"body",
				[],
				[
					Html.element("p", [Html.attr("class", "count")], [Html.text_of(|| count!().to_str())]),
					Loading.view!({ fallback: Html.text("loading"), children: [Html.element("p", [Html.attr("class", "shouted")], [Html.text_of(|| shouted!())])] }),
					Errored.view!({
						fallback: |problem, _| Html.element("p", [Html.attr("class", "failed")], [Html.text_of(|| problem)]),
						children: [Html.element("p", [], [Html.text_of(|| Solid.use_context!(missing).name)])],
					}),
					Errored.view!({
						fallback: |problem, _| Html.element("p", [Html.attr("class", "refused")], [Html.text_of(|| problem)]),
						children: [Html.element("p", [Html.attr("class", "member")], [Html.text_of(|| member!({}))])],
					}),
					Html.element("p", [Html.attr("class", "at")], [Html.text_of(|| where!({}))]),
				],
			),
		],
	)
}

## A page that isn't there: its doctype its own (the host writes none), its status 404.
gone! : {} => Html
gone! = |{}|
	Html.join([
		Html.doctype({}),
		Html.element("html", [], [Html.element("body", [], [Html.component(|| HttpStatusCode.view!({ code: 404 })), Html.element("h1", [], [Html.text("Not here")])])]),
	])

## A page whose hole crashes as the host renders it.
crashing! : {} => Html
crashing! = |{}| {
	(on!, _set_on!) = Solid.create_signal!(Bool.True)
	Html.element("html", [], [Html.element("body", [], [Html.element("p", [], [Html.text_of(|| if (on!()) crash "a page that crashed" else "")])])])
}

## A page that crashes as it is made, after allocating.
mount_crashing! : {} => Html
mount_crashing! = |{}| {
	rows = strings(300 + Router.location!({}).path.to_utf8().len(), [])
	if (rows.len() > 10) crash "a page that crashed as it was made, after ${rows.len().to_str()} strings" else Html.empty({})
}

## A page with a failure no <Errored> catches.
unhandled! : {} => Html
unhandled! = |{}| Html.element("html", [], [Html.element("body", [], [Html.element("p", [], [Html.text_of(|| Solid.use_context!(missing).name)])])])

## The key-value store's routes: each operation, a text value (`value`), its time to live (`ttl`)
## and a list's length (`keep`) in the query; what came back, as text.
kept! : Server.Request => Server.Response
kept! = |request| {
	key = param(request.query, "key")
	opts = { ttl_ms: number(request.query, "ttl") }
	# `size`: that many x's, for values too large for a query.
	size = number(request.query, "size")
	value = if (size > 0) Str.repeat("x", size) else param(request.query, "value")
	match request.path {
		"/kv/set" => {
			Kv.set!(key, value, opts)
			text(200, "set")
		}
		"/kv/get" =>
			match Kv.get!(key) {
				Ok(found) => text(200, found)
				Err(NotFound) => text(404, "NotFound")
				Err(BadValue(why)) => text(500, "BadValue ${why}")
			}
		"/kv/take" =>
			match Kv.take!(key) {
				Ok(found) => text(200, found)
				Err(NotFound) => text(404, "NotFound")
				Err(BadValue(why)) => text(500, "BadValue ${why}")
			}
		"/kv/delete" => {
			Kv.delete!(key)
			text(200, "deleted")
		}
		"/kv/add" =>
			match Kv.add!(key, value, opts) {
				Ok({}) => text(200, "added")
				Err(Exists) => text(409, "Exists")
			}
		"/kv/increment" =>
			match Kv.increment!(key, I64.from_str(param(request.query, "by")) ?? 1, opts) {
				Ok(now) => text(200, now.to_str())
				Err(NotAnInteger(why)) => text(409, "NotAnInteger ${why}")
			}
		"/kv/push" => {
			Kv.push!(key, value, { keep: number(request.query, "keep"), ttl_ms: number(request.query, "ttl") })
			text(200, "pushed")
		}
		"/kv/list" =>
			match Kv.list!(key) {
				Ok(values) => text(200, Str.join_with(values, ","))
				Err(BadValue(why)) => text(500, "BadValue ${why}")
			}
		"/kv/count" =>
			# A number kept as JSON reads back as one; a string doesn't.
			match Kv.get!(key) {
				Ok(count) => text(200, (count + 0.I64).to_str())
				Err(NotFound) => text(404, "NotFound")
				Err(BadValue(why)) => text(500, "BadValue ${why}")
			}
		_ => text(404, "no such kv route")
	}
}
