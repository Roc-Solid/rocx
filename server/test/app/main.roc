## A small app on the server platform, for its tests (`server/test/server.test.mjs`): a page, a
## crash and an overflow, bytes each way, streams of events, Postgres and its transactions, jobs
## (with attempts, time limits and keys, listed and acted on, and the jobs page behind a guard) and
## cron, email, live topics and rooms, actors, pages of components, with server functions answered
## by their routes, requests to other servers, the environment, AES-GCM, random
## bytes, the crypto written in Roc (packages/crypto), S3 storage (packages/s3), and cookies; and what the docs show of them
## (`Samples.roc`), as an app would write it.
app [program] { pf: platform "../../platform/main.roc", crypto: "../../../packages/crypto/main.roc", s3: "../../../packages/s3/main.roc" }

import crypto.Base64
import crypto.Hex
import crypto.Hkdf
import crypto.Hmac
import crypto.Sha256
import s3.S3
import pf.Actor
import pf.AesGcm
import pf.Cron
import pf.Db
import pf.Email
import pf.Env
import pf.Http
import pf.Job
import pf.JobsPage
import pf.Live
import pf.Log
import pf.Random
import pf.Tcp
import pf.Time
import pf.Html
import pf.Solid
import pf.Show
import pf.For
import pf.Errored
import pf.Loading
import pf.HttpStatusCode
import pf.Context
import pf.Server
import pf.Endpoint
import pf.Middleware
import pf.Events
import pf.Router
import Samples
import "migrations/0001_tables.sql" as tables : Str
import "migrations/0002_note_index.sql" as note_index : Str

program = {
	respond!,
	# The app's schema, in the executable: applied once each, in order, when the server starts.
	migrations: [{ name: "0001_tables.sql", sql: tables }, { name: "0002_note_index.sql", sql: note_index }],
	jobs: [Job.handler(note_job), Job.handler(flaky_job), Job.handler(crash_job), Job.handler(mail_job), Job.handler(tick_job), Job.handler(env_job), Job.handler(twice_job), Job.handler(slow_job)],
	crons: [Cron.every("* * * * * *", tick_job, {})],
	# The kinds of actor (`rocx build` lists them for an app it builds).
	actors: [Actor.handler(counter), Actor.handler(mirror({})), Actor.handler(bouncer({})), Actor.handler(ticker)],
	# The log's format: `ROCX_LOG` if it's set, or else pretty on a terminal and JSON elsewhere.
	logs: { format: Auto },
}

respond! : Str, Str, Str, List(U8), Str => Server.Response
respond! = |method, target, headers, body, context| {
	request = Server.from_http(method, target, headers, body)
	# A page view lets a plain form's flash go, as `App.program` does.
	Server.clear_flash(request, route!(request, context))
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
		("GET", "/context") => text(200, context)
		("GET", "/echo") => text(200, "${request.method} ${request.path}?${request.query} ${Server.text_of(request)}")
		("POST", "/echo") => text(200, "${request.method} ${request.path} ${Server.text_of(request)}")
		# ---- Bytes: a request's body as it came; an answer of bytes ----
		("POST", "/bytes/echo") => Server.bytes(200, [{ name: "content-type", value: "application/octet-stream" }], request.body)
		("POST", "/bytes/sha") => text(200, "${request.body.len().to_str()} ${Sha256.hex(request.body)}")
		(_, "/bytes/counting") => Server.bytes(200, [{ name: "content-type", value: "application/octet-stream" }], counting(number(request.query, "size")))
		# ---- An endpoint's body: read as JSON or a form, or left as it came for its handler ----
		(_, "/endpoint/upload") => Endpoint.respond!(upload_endpoint, request, {})
		(_, "/endpoint/shout") => Endpoint.respond!(shout_endpoint, request, {})

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

		# ---- Postgres ----
		("POST", "/reset") =>
			match Db.script!("truncate notes, job_log, flaky restart identity; delete from rocx_jobs; delete from rocx_outbox") {
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
			done = Db.transaction!(
				|{}| {
					_ = Db.run!("insert into notes (body) values ($1)", [Text("with a job ${run}")])?
					match Job.enqueue!(note_job, { run, said: "committed" }, { when: Now }) {
						Ok({}) => Ok("queued")
						Err(JobErr(why)) => Err(DbErr(why))
					}
				},
			)
			match done {
				Ok(said) => text(202, said)
				Err(DbErr(why)) => text(500, why)
			}
		}
		("POST", "/jobs/rollback") => {
			done = Db.transaction!(
				|{}| {
					match Job.enqueue!(note_job, { run, said: "rolled back" }, { when: Now }) {
						Ok({}) => Err(Refused)
						Err(JobErr(why)) => Err(DbErr(why))
					}
				},
			)
			match done {
				Ok(_) => text(200, "?")
				Err(Refused) => text(409, "refused, rolled back")
				Err(DbErr(why)) => text(500, why)
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
		# The jobs page, behind a guard of the app's own.
		(_, "/admin/jobs") => Middleware.run!(admins_only, request, {}, |passed, _| JobsPage.respond!(passed, { mount: "/admin/jobs" }))
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

		# ---- Actors ----
		("POST", "/actors/boom") => answered_actor(Actor.ask!(counter, run, Boom))
		("POST", "/actors/self") => answered_actor(Actor.ask!(mirror({}), run, Itself(run)))
		("POST", "/actors/relay") => answered_actor(Actor.ask!(mirror({}), run, Relay(run)))
		("POST", "/actors/cycle") => answered_actor(Actor.ask!(mirror({}), run, Cycle(run)))
		("POST", "/actors/tell") => {
			Actor.tell!(counter, run, Add(I64.from_str(param(request.query, "by")) ?? 1))
			text(200, "told")
		}
		("POST", "/actors/later") => {
			ms = U64.from_str(param(request.query, "ms")) ?? 100
			timer = Actor.tell_after!(counter, run, ms, Add(I64.from_str(param(request.query, "by")) ?? 1))
			text(200, timer.to_str())
		}
		("POST", "/actors/cancel") => {
			Actor.cancel!(U64.from_str(param(request.query, "timer")) ?? 0)
			text(200, "cancelled")
		}
		("POST", "/actors/wrong") => answered_actor(Actor.ask!(stale_counter, run, Reset("to what?")))
		("POST", "/actors/wrong-tell") => {
			Actor.tell!(stale_counter, run, Reset("to what?"))
			text(200, "told")
		}
		("POST", "/actors/ghost") => answered_actor(Actor.ask!(ghost, run, Add(1)))
		("POST", "/actors/tick/start") => answered_actor(Actor.ask!(ticker, run, Start(U64.from_str(param(request.query, "ms")) ?? 20)))
		("POST", "/actors/tick/stop") => answered_actor(Actor.ask!(ticker, run, Stop))
		("GET", "/actors/tick") => answered_actor(Actor.ask!(ticker, run, Ticks))
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
			answered_actor(Actor.ask!(counter, after(path, "/actors/count/"), Add(by)))
		}
		("GET", path) if path.starts_with("/actors/count/") => answered_actor(Actor.ask!(counter, after(path, "/actors/count/"), Get))

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

		# ---- Form actions: a plain form's post comes back to its page with a flash ----
		(_, "/flash/join") => Endpoint.respond!(join_endpoint, request, {})
		(_, "/flash/away") => Endpoint.respond!(away_endpoint, request, {})
		("GET", "/flash/page") => page(joining!)

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
		("POST", "/http/form") => answered_http(Http.fetch!(Http.post_form(param(request.query, "url"), [("name", "Ada Lovelace"), ("says", "a&b=c ✓")])))
		("POST", "/http/bytes") =>
		# Bytes each way: these sent, and the answer's as numbers.
			match Http.fetch!({ method: "PUT", url: param(request.query, "url"), headers: [{ name: "content-type", value: "application/octet-stream" }], body: [0, 255, 13, 10, 128] }) {
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

		# ---- Storage: S3, from packages/s3, in the bucket STORAGE_URL names (`stored!`) ----
		(_, path) if path.starts_with("/storage/") => stored!(request)

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
				Ok(said) => text(200, said)
				Err(Refused(status)) => text(502, "refused: ${status.to_str()}")
				Err(_) => text(504, "no answer")
			}
		("GET", "/samples/preview") =>
			match Samples.preview!(param(request.query, "url")) {
				Ok(answer) => text(200, "${answer.status.to_str()} ${Http.header(answer, "location") ?? "-"}")
				Err(TooLarge) => text(502, "too large")
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
		("GET", "/samples/cookies") => Samples.signed_out(Samples.reviewing(Samples.signed_in(text(200, "cookies"), "token"), "review", 1_795_000_000_000))

		# ---- Server functions: their routes ----
		(_, path) if path.starts_with("/rocx/call/") => call!(request, context)

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
admins_only : Middleware({}, {})
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

## What another server answered (its status, its `location` and `x-from`, its body), or why there
## was no answer.
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
bucket! : {} => Try(S3.Bucket, [StorageErr(Str)])
bucket! = |{}| S3.from_url(Env.var!("STORAGE_URL") ?? "", { send!: Http.send!, now!: Time.now_millis! })

## The storage routes (the key, and the rest, in the query; bytes as numbers with `as=numbers`).
## Without a bucket (no STORAGE_URL, or one that can't be read), each says why: a 503.
stored! : Server.Request => Server.Response
stored! = |request|
	match bucket!({}) {
		Err(StorageErr(why)) => text(503, "StorageErr ${why}")
		Ok(bucket) => in_bucket!(bucket, request)
	}

in_bucket! : S3.Bucket, Server.Request => Server.Response
in_bucket! = |bucket, request|
	match (request.method, request.path) {
		("POST", "/storage/put") => {
			bytes = if (param(request.query, "as") == "numbers") from_numbers(Server.text_of(request)) else request.body
			answered_storage(S3.put!(bucket, param(request.query, "key"), bytes, { content_type: param(request.query, "type") }), |{}| "stored")
		}
		("POST", "/storage/fill") =>
		# `size` bytes, each `fill`: an object larger than a request's body carries well as numbers.
			answered_storage(S3.put!(bucket, param(request.query, "key"), filled(request.query), { content_type: "application/octet-stream" }), |{}| "stored")
		("GET", "/storage/get") => answered_storage(S3.get!(bucket, param(request.query, "key")), |bytes| shown_bytes(request.query, bytes))
		("GET", "/storage/sha") => answered_storage(S3.get!(bucket, param(request.query, "key")), |bytes| Sha256.hex(bytes))
		("GET", "/storage/range") => {
			range = { offset: number(request.query, "offset"), length: number(request.query, "length") }
			answered_storage(S3.get_range!(bucket, param(request.query, "key"), range), |got| "${got.size.to_str()} ${shown_bytes(request.query, got.bytes)}")
		}
		("GET", "/storage/head") => answered_storage(S3.head!(bucket, param(request.query, "key")), |info| "${info.size.to_str()} ${info.content_type} ${info.etag}")
		(_, "/storage/serve") => {
			# `whole=1`: the request's range dropped from the record, so the whole object is sent.
			served = if (param(request.query, "whole") == "1") { ..request, headers: request.headers.keep_if(|each| each.name != "range") } else request
			S3.serve!(bucket, param(request.query, "key"), served, { content_type: param(request.query, "type"), cache_control: param(request.query, "cache") })
		}
		("POST", "/storage/delete") => answered_storage(S3.delete!(bucket, param(request.query, "key")), |{}| "deleted")
		("POST", "/storage/start") => answered_storage(S3.start_upload!(bucket, param(request.query, "key"), { content_type: param(request.query, "type") }), |upload| upload)
		("POST", "/storage/part") => answered_storage(S3.upload_part!(bucket, param(request.query, "key"), param(request.query, "upload"), number(request.query, "number"), filled(request.query)), |etag| etag)
		("POST", "/storage/finish") => {
			# The parts, a `number etag` a line.
			parts = Server.text_of(request).split_on("\n").keep_if(|line| !line.is_empty()).map(
				|line|
					match line.split_first(" ") {
						Ok({ before: written, after: etag }) => { number: U64.from_str(written) ?? 0, etag }
						Err(_) => { number: 0, etag: line }
					},
			)
			answered_storage(S3.finish_upload!(bucket, param(request.query, "key"), param(request.query, "upload"), parts), |{}| "finished")
		}
		("POST", "/storage/abort") => answered_storage(S3.abort_upload!(bucket, param(request.query, "key"), param(request.query, "upload")), |{}| "aborted")
		("GET", "/storage/signed") =>
			match S3.signed_url!(bucket, param(request.query, "key"), { method: param(request.query, "method"), expires_s: number(request.query, "expires") }) {
				Ok(url) => text(200, url)
				Err(BadExpiry) => text(400, "BadExpiry")
				Err(StorageErr(why)) => text(503, "StorageErr ${why}")
			}
		# Whether S3 answers, with these keys, for this bucket (what an app's health check asks).
		("GET", "/storage/check") =>
			match S3.check!(bucket) {
				Ok({}) => text(200, "S3 answers, and the bucket is there")
				Err(S3Err(refused)) => text(502, "S3Err ${S3.said(refused)}")
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
note_job : Job.Kind({ run : Str, said : Str })
note_job = Job.define(
	"note",
	|{ run, said }|
		match Db.run!("insert into job_log (kind, said) values ('note', $1)", [Text("${run} ${said}")]) {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		},
)

## Fails `fails` times, then writes to the job log.
flaky_job : Job.Kind({ run : Str, fails : I64 })
flaky_job = Job.define(
	"flaky",
	|{ run, fails }| {
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
crash_job : Job.Kind({ run : Str })
crash_job = Job.define("crash", |{ run }| if (run != "") crash "a job that always crashes" else Ok({}))

## Sends an email.
mail_job : Job.Kind({ to : Str, run : Str })
mail_job = Job.define(
	"mail",
	|{ to, run }|
		match Email.send!({ to, subject: "From a job ${run}", text: "Sent by a job.", html: "" }) {
			Ok({}) => Ok({})
			Err(EmailErr(why)) => Err(why)
		},
)

## Every second (`crons`): a tick in the job log.
tick_job : Job.Kind({})
tick_job = Job.define(
	"tick",
	|{}|
		match Db.run!("insert into job_log (kind, said) values ('tick', 'tick')", []) {
			Ok(_) => Ok({})
			Err(DbErr(why)) => Err(why)
		},
)

## Writes what the environment says to the job log: a variable, and whether the server runs under
## `--dev`.
env_job : Job.Kind({ run : Str, name : Str })
env_job = Job.define(
	"env",
	|{ run, name }| {
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
twice_job : Job.Kind({ run : Str })
twice_job = Job.define_with("twice", { attempts: 2, timeout_ms: 0 }, |{ run }| Err("fails every time (${run})"))

## Waits on Postgres, another server or a socket (`on`) longer than its limit (300 ms), and ignores
## what it is told: the limit cuts it off anyway, and it never writes to the job log. `on: "none"`
## is done in time.
slow_job : Job.Kind({ run : Str, on : Str, url : Str })
slow_job = Job.define_with(
	"slow",
	{ attempts: 2, timeout_ms: 300 },
	|{ run, on, url }| {
		if on == "db" {
			slept : Try(List({ one : I64 }), [DbErr(Str), BadRow(Str)])
			slept = Db.all!("select 1::int8 as one from pg_sleep(30)", [])
			_ = slept
			{}
		} else if on == "http" {
			_ = Http.fetch!(Http.get(url))
			{}
		} else if on == "tcp" {
			match Tcp.connect!("127.0.0.1", U16.from_str(url) ?? 0) {
				Ok(tcp) => {
					_ = tcp.read_until!('\n')
					{}
				}
				Err(_) => {}
			}
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

## A count, one per key, that outlives requests and restarts.
counter : Actor.Kind({ count : I64 }, [Add(I64), Get, Boom], I64)
counter = Actor.define({
	name: "counter",
	initial: |_key| { count: 0 },
	receive!: |_me, state, message|
		match message {
			Add(by) => { state: { count: state.count + by }, reply: state.count + by }
			Get => { state, reply: state.count }
			Boom => if (state.count >= 0) crash "an actor that crashed" else { state, reply: 0 }
		},
})

## The counter as a caller built against an older version of it would see it: the same name, a
## message it doesn't take. Not in `program.actors`: the counter gets the message.
stale_counter : Actor.Kind({ count : I64 }, [Reset(Str)], I64)
stale_counter = Actor.define({ name: "counter", initial: |_key| { count: 0 }, receive!: |_me, state, _message| { state, reply: state.count } })

## A kind the app doesn't list: the host refuses a message to it.
ghost : Actor.Kind({}, [Add(I64)], I64)
ghost = Actor.define({ name: "ghost", initial: |_key| {}, receive!: |_me, state, _message| { state, reply: 0 } })

## Asks others: the counter of the same key (`Relay`), itself (`Itself`, which it can't), or the
## bouncer, which asks it back (`Cycle`, which the bouncer can't).
mirror : {} -> Actor.Kind({}, [Relay(Str), Itself(Str), Cycle(Str)], I64)
mirror = |{}| Actor.define({ name: "mirror", initial: |_key| {}, receive!: mirror_receive! })

mirror_receive! : Actor.Me([Relay(Str), Itself(Str), Cycle(Str)]), {}, [Relay(Str), Itself(Str), Cycle(Str)] => { state : {}, reply : I64 }
mirror_receive! = |_me, state, message|
	match message {
		Relay(key) =>
			match Actor.ask!(counter, key, Get) {
				Ok(count) => { state, reply: count }
				Err(ActorErr(why)) => crash why
			}
		Itself(key) =>
			match Actor.ask!(mirror({}), key, Relay(key)) {
				Ok(count) => { state, reply: count }
				Err(ActorErr(why)) => crash why
			}
		Cycle(key) =>
			match Actor.ask!(bouncer({}), key, Back(key)) {
				Ok(count) => { state, reply: count }
				Err(ActorErr(why)) => crash why
			}
	}

## Asks the mirror of the same key: asked by it, that waits forever, so it is refused.
bouncer : {} -> Actor.Kind({}, [Back(Str)], I64)
bouncer = |{}|
	Actor.define({
		name: "bouncer",
		initial: |_key| {},
		receive!: |_me, state, message|
			match message {
				Back(key) =>
					match Actor.ask!(mirror({}), key, Relay(key)) {
						Ok(count) => { state, reply: count }
						Err(ActorErr(why)) => crash why
					}
			},
	})

## Counts its own ticks: `Start(ms)` sets a timer for itself, and each tick sets the next
## (`Actor.after!`) until `Stop` cancels the one waiting (`Actor.cancel!`).
ticker : Actor.Kind({ ticks : I64, timer : U64, on : Bool }, [Start(U64), Tick(U64), Stop, Ticks], I64)
ticker = Actor.define({
	name: "ticker",
	initial: |_key| { ticks: 0, timer: 0, on: Bool.False },
	receive!: |me, state, message|
		match message {
			Start(ms) => { state: { ticks: state.ticks, timer: Actor.after!(me, ms, Tick(ms)), on: Bool.True }, reply: state.ticks }
			Tick(ms) =>
				if (state.on) {
					{ state: { ticks: state.ticks + 1, timer: Actor.after!(me, ms, Tick(ms)), on: Bool.True }, reply: state.ticks + 1 }
				} else {
					{ state, reply: state.ticks }
				}
			Stop => {
				Actor.cancel!(state.timer)
				{ state: { ticks: state.ticks, timer: 0, on: Bool.False }, reply: state.ticks }
			}
			Ticks => { state, reply: state.ticks }
		},
})

# ---- Components the server renders, and the server functions they call ----

## The probe, on a page of its own, with the page's text after it.
probing! : {} => Html
probing! = |{}| Html.element("html", [], [Html.element("body", [], [Html.component(|| probe!({})), Html.element("p", [], [Html.text("after")])])])

## A server function the probe calls while the server renders it.
shout! : Str => Str
shout! = Server.local("Probe.shout", |_request, word| word.with_ascii_uppercased())

## A server function behind a middleware of its own (`members_only`), as one a route file defines
## runs behind the file's: who the member is, from what the middleware handed on.
member! : {} => Str
member! = Server.local("Probe.member", |request, {}| "member ${Server.context!({}).member}, ${request.method} ${request.path}")

## Who is signed in, behind a gate that sends anyone else to sign in (303), forgetting their stale
## session: what a layout's call meets for a signed-out visitor.
signed_in! : {} => Str
signed_in! = Server.local("Probe.signed_in", |_request, {}| "signed in as ${Server.context!({}).member}")

## The gate: a member goes on; anyone else is sent to `/login`, their `session` cookie cleared.
gate : Middleware({ started : Str }, { started : Str, member : Str })
gate = Middleware.make(
	|request, context, next!|
		match Server.cookie(request, "member") {
			Ok(name) => next!(request, { started: context.started, member: name })
			Err(Missing) => Server.without_cookie(Server.redirect("/login"), "session")
		},
)

## One that takes and answers `F64`s, which JSON writes as numbers: a number it can't (an
## infinity, dividing by zero) is a 500 that says so.
measure! : { seconds : F64, parts : F64 } => { seconds : F64, each : F64 }
measure! = Server.local("Probe.measure", |_request, { seconds, parts }| { seconds, each: seconds / parts })

## One that answers what a `Try` would, as a tag union: the builtin `Try` can't go as JSON.
length! : Str => [Ok(U64), Err([Empty])]
length! = Server.local("Probe.length", |_request, word| if (word.is_empty()) Err(Empty) else Ok(word.count_utf8_bytes()))

## A badge: a nominal type whose JSON encoder and parser are derived, as an app's own types are.
Badge := { name : Str }.{
	encoder_for : _
	parser_for : _
}

## Someone as `badged` hands them on: a badge beside other fields, one an `F64`.
Holder : { name : Str, badge : Badge, since : F64 }

## One whose context, input and answer each hold a nominal type with a derived encoder beside
## other fields, and an `F64`: the platform writes each with `Json.to_str_try`, which crashes the
## compiler for such a value unless its error type is named (test/compiler-bugs/json-to-str-try-nominal).
award! : { badge : Badge, points : F64 } => { badge : Badge, points : F64, holder : Holder }
award! = Server.local("Probe.award", |_request, { badge, points }| { badge, points: points * 2, holder: Server.context!({}).holder })

## Hands on a holder with a badge.
badged : Middleware({ started : Str }, { started : Str, holder : Holder })
badged = Middleware.make(|request, context, next!| next!(request, { started: context.started, holder: { name: "Ada", badge: { name: "admin" }, since: 0.5 } }))

## One that reads a context no middleware in front of it hands on: a 500, naming it.
unguarded! : {} => Str
unguarded! = Server.local("Probe.unguarded", |_request, {}| Server.context!({}).member)

## A member: whoever the `member` cookie names, handed on as `member`; anyone else is refused (401).
members_only : Middleware({ started : Str }, { started : Str, member : Str })
members_only = Middleware.make(
	|request, context, next!|
		match Server.cookie(request, "member") {
			Ok(name) => if (name.is_empty()) Server.refused(401, "members only") else next!(request, { started: context.started, member: name })
			Err(Missing) => Server.refused(401, "members only")
		},
)

## The server functions' routes, as `rocx build` writes them (`Routes`' `/rocx/call/` branch, and
## `Generated/ServerFunctions`): POST only, behind each one's middleware, given what the app handed on.
call! : Server.Request, Str => Server.Response
call! = |request, started| {
	called = Server.decode_segment(request.path.drop_prefix("/rocx/call/"))
	context = { started: started }
	if request.method != "POST" {
		Endpoint.not_allowed(request, ["POST"])
	} else if called == "Probe.shout" {
		Server.serve!(called, request, context, shout!)
	} else if called == "Probe.member" {
		Middleware.run!(members_only, request, context, |passed, handed| Server.serve!(called, passed, handed, member!))
	} else if called == "Probe.signed_in" {
		Middleware.run!(gate, request, context, |passed, handed| Server.serve!(called, passed, handed, signed_in!))
	} else if called == "Probe.unguarded" {
		Server.serve!(called, request, context, unguarded!)
	} else if called == "Probe.measure" {
		Server.serve!(called, request, context, measure!)
	} else if called == "Probe.length" {
		Server.serve!(called, request, context, length!)
	} else if called == "Probe.award" {
		Middleware.run!(badged, request, context, |passed, handed| Server.serve!(called, passed, handed, award!))
	} else {
		Server.refused(404, "no server function is called ${called}")
	}
}

## A context nothing provides: reading it fails, and <Errored> shows why.
missing : Context({ name : Str })
missing = Context.required("Probe.missing")

## Signals, memos, a server function, a keyed <For>, a <Show>, an <Errored> that catches, and
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
			Show.view!({ when!: || count!() > 100, fallback: Html.element("p", [Html.attr("class", "small")], [Html.text("small")]), children: [Html.text("big")] }),
			Errored.view!({
				fallback: |problem, _| Html.element("p", [Html.attr("class", "failed")], [Html.text_of(|| problem)]),
				children: [Html.element("p", [], [Html.text_of(|| Solid.use_context!(missing).name)])],
			}),
			Html.void("input", [Html.flag("disabled", Bool.True), Html.attr("value", "a & b")]),
			# A server function behind its middleware, called while the server renders: answered by
			# its route, in-process, with the page's cookies; refused, the <Errored> shows why.
			Errored.view!({
				fallback: |problem, _| Html.element("p", [Html.attr("class", "refused")], [Html.text_of(|| problem)]),
				children: [Html.element("p", [Html.attr("class", "member")], [Html.text_of(|| member!({}))])],
			}),
			# Where the page is (`Router.location!`): the request's path and query.
			Html.element("p", [Html.attr("class", "at")], [Html.text_of(|| where!({}))]),
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

## A page whose "layout" asks who is signed in, behind a gate (a server function's middleware),
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

## A page that reads GET endpoints as the server renders it: its own data, with the page's query;
## one that refuses, as a value (`read!`) and as a failure an <Errored> shows (`get!`), the same URL
## asked once; and one inside a <NoHydration>, which isn't noted for the browser.
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
## markers, with none inside (a hole, a `<Show>`, a `<For>`, an `<Errored>` that failed, a component,
## one inside another); the server function it calls isn't recorded for the page, the same one
## called outside it is.
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
						Show.view!({ when!: || count!() > 1, fallback: Html.text("few"), children: [Html.text("many")] }),
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
page : ({} => Html) -> Server.Response
page = |view!| { status: 200, headers: [], body: Page(view!) }

## A document with no doctype (the host writes one): a signal, a memo that calls a server function,
## a <Loading> (on the server what is inside renders), an <Errored> that catches a failure, one
## around a server function behind its middleware (refused without a cookie), and where it is.
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
