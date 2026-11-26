import pf.Db
import pf.Plugin
import pf.Server
import Cron
import CronTicker
import JobSweeper
import JobWorker
import Queue
import Registry
import "migrations/0001_jobs.sql" as jobs_table : Str
import "migrations/0001_jobs_sqlite.sql" as lite_jobs_table : Str

## Work to do outside any request: queued in the app's database (`rocx_jobs`, on Postgres or
## SQLite), run in the background by the
## jobs plugin's workers (`JobWorker`), and run again if it fails (an `Err`, a crash, or its time
## limit passing), a little later each time, as many times as its kind says (five unless it says
## otherwise). Queued in a transaction (`Db.transaction!`), a job is a row in it: there only if it
## commits, and the workers hear of it then.
##
## ```roc
## welcome : Job.Kind(_, { member : I64 })
## welcome = Job.define("welcome", |_context, { member }| { … Email.send!(…) … })
##
## # Once, within 20 minutes: a reminder sent twice is worse than one missed.
## reminder = Job.define_with("reminder", { attempts: 1, timeout_ms: 20 * 60_000 }, |_context, { member }| …)
##
## Job.enqueue!(welcome, { member: 7 }, {})                                             # now
## Job.enqueue!(welcome, { member: 7 }, { when: At(Time.now_millis!({}) + 60_000) })    # a minute from now
## Job.enqueue_keyed!(reminder, { member: "ada" }, { key: "reminder:ada" })             # Queued, or Exists
## Job.cancel!("reminder:ada")
## ```
##
## Each function's error is an open union (`[JobErr(Str), ..others]`), as `Db`'s are, so a
## transaction's body `?`s a job, its statements and the app's own errors together, and the caller
## matches `JobErr` beside `DbErr`.
##
## The app lists the plugin, with the kinds its workers run and its schedules:
##
## ```roc
## plugins: [Job.plugin({ jobs: App.jobs, crons: [Cron.every("0 3 * * *", Jobs.tidy, {})] })]
## ```
##
## `App.jobs` is every kind the app's modules define (`rocx build` finds each `Job.define` and
## `Job.define_with` at the top of a module's block); a program written by hand lists
## `Job.handler(kind)` for each. `list!`, `get!` and `counts!` read the queue, `retry!`,
## `cancel_id!` and `run_now!` act on one job, and `kinds!` and `changes` say what the plugin runs
## and when the queue changes: what a jobs page is made of (packages/admin's `JobsPage`).
Job := [].{

	## A kind of job: its name, how many times one is tried, its time limit (milliseconds, 0 for
	## none) and what running one does, given the app's context (what its `init!` made) and its
	## input. A kind defined without an annotation, or annotated `Job.Kind(_, input)`, takes the
	## context as the app has it.
	Kind(context, input) : { name : Str, attempts : U64, timeout_ms : U64, run! : context, input => Try({}, Str) }

	## A kind as the workers run it (`Job.handler`): its input as JSON.
	Handler(context) : { name : Str, attempts : U64, timeout_ms : U64, run! : context, Str => Try({}, Str) }

	## What the jobs plugin runs: the app's kinds of job (`App.jobs`, which rocx build lists, or
	## `Job.handler(kind)` for each), its schedules (`Cron.every`), how many workers take jobs at
	## once (each a background loop), how long a failed job waits before its second attempt
	## (milliseconds; doubled for each after), and what is done when a job has failed for good,
	## after it is logged (`on_failed!`: nothing more, unless the app says; an error tracker's
	## report, `PostHog.job_failed!`). And how long finished jobs are kept (`JobSweeper`), in
	## milliseconds after they finished: a done one a week (`keep_done_ms`), a failed or canceled
	## one 30 days (`keep_failed_ms`), swept when the server starts and every hour after
	## (`sweep_ms`, more than 0).
	Options(context) := {
		jobs : List(Handler(context)),
		crons : List({ name : Str, schedule : Str, job : Str, input : Str }) ?? [],
		workers : U64 ?? 4,
		retry_ms : U64 ?? 1000,
		on_failed! : (Failure => {}) ?? ignored!,
		keep_done_ms : U64 ?? 604_800_000,
		keep_failed_ms : U64 ?? 2_592_000_000,
		sweep_ms : U64 ?? 3_600_000,
	}

	## A job that failed for good, as the plugin's `on_failed!` is given it: its kind, its id, how
	## many times it was tried and why the last attempt failed (its `Err`, a crash, or "timed out
	## after …"). Its row stays in `rocx_jobs`, failed, until it is tried again (`retry!`) or swept
	## (`keep_failed_ms` after it failed).
	Failure : { kind : Str, id : I64, attempts : U64, error : Str }

	## The jobs plugin: the queue's table (`jobs/0001_jobs`), the workers (`jobs.worker`, with a
	## database and a kind to run: the app's, and those other plugins bring, `Job.adopt!`), the
	## schedules' loop (`jobs.schedules`, with one) and the sweep (`jobs.sweep`, with a database:
	## `JobSweeper`), the call a job runs in (`jobs.run`), and at start what the jobs page reads kept
	## (the kinds, the schedules, how long finished jobs stay: `kinds!`, `Cron.schedules!`, `keeps!`),
	## every schedule checked (a bad one, or one naming a job the plugin doesn't run, stops the
	## server, as a `sweep_ms` of 0 does), and the jobs a stop cut short queued again. Under `--dev`
	## or `--debug`, `POST /__rocx/jobs/wake` tells the workers to look for a due job now, as queuing
	## one does: for a job another process wrote into the queue itself, which on SQLite can't tell
	## them (a test's: packages/testing's `enqueue` and `settleJobs`).
	plugin : Options(context) -> Plugin.Value(context, ctx)
	plugin = |options| {
		handlers = options.jobs
		crons = options.crons
		retry_ms = options.retry_ms
		on_failed! = options.on_failed!
		kinds = handlers.map(|job| { name: job.name, attempts: job.attempts, timeout_ms: job.timeout_ms })
		own = kinds.map(|kind| kind.name)
		# The workers run the app's kinds and other plugins' (`Job.adopt!`, known once every start
		# has run): one with none to run ends at once.
		workers = List.repeat({ name: "jobs.worker", run!: |_context| JobWorker.run!(own, retry_ms, on_failed!) }, options.workers)
		ticker = if (crons.is_empty()) [] else [{ name: "jobs.schedules", run!: |_context| CronTicker.run!(crons) }]
		kept = { keep_done_ms: options.keep_done_ms, keep_failed_ms: options.keep_failed_ms, sweep_ms: options.sweep_ms }
		keeps = { keep_done_ms: kept.keep_done_ms, keep_failed_ms: kept.keep_failed_ms }
		sweeper = { name: "jobs.sweep", run!: |_context| JobSweeper.run!(kept) }
		{
			name: "jobs",
			migrations: [{ name: "0001_jobs", sql: jobs_table, on: Postgres }, { name: "0001_jobs", sql: lite_jobs_table, on: Sqlite }],
			early: [{ method: "POST", path: "/__rocx/jobs/wake", under: [Dev, Debug], answer!: woken! }],
			calls: [{ name: "jobs.run", run!: |context, input| ran!(handlers, context, input) }],
			loops: workers.concat(ticker).append(sweeper),
			starts: [|_context| started!(kinds, crons, keeps, kept.sweep_ms)],
		}
	}

	## A kind of job another plugin brings (push's `push.deliver`), for that plugin's `calls`: the call
	## the workers run each of its jobs in, named as the kind is (`<plugin>.<name>`), its input
	## decoded from JSON. With `Job.adopt!` in its `starts`, and `Plugin("jobs")` in its `needs`:
	##
	## ```roc
	## calls: [Job.call(deliver)],
	## starts: [|_context| Job.adopt!(deliver)],
	## needs: [Plugin("jobs")],
	## ```
	call : Kind(context, input) -> Plugin.Call(context)
		where [input.Json.Parseable([InvalidJson(Str)])]
	call = |kind| {
		handled = Job.handler(kind)
		run_job! = handled.run!
		{ name: kind.name, run!: |context, payload| run_job!(context, payload).map_ok(|{}| "") }
	}

	## Tells the jobs plugin of a kind another plugin brings (`call`), from that plugin's start: its
	## workers run its jobs too, the jobs page lists it, and its jobs a stop cut short are queued
	## again. Without the jobs plugin started first (`Plugin("jobs")` in the plugin's needs), why
	## not.
	adopt! : Kind(context, input) => Try({}, Str)
	adopt! = |kind| {
		if !Registry.installed!({}) {
			return Err("${kind.name} is a job: list Job.plugin({ jobs: App.jobs }) in the app's plugins, and Plugin(\"jobs\") in this plugin's needs")
		}
		Registry.adopt!({ name: kind.name, attempts: kind.attempts, timeout_ms: kind.timeout_ms })
		if Db.connected!({}) {
			JobWorker.recover!([kind.name])
		} else {
			Ok({})
		}
	}

	## A kind of job the plugin runs: its name, attempts and time limit (milliseconds; 0, none).
	KindInfo : { name : Str, attempts : U64, timeout_ms : U64 }

	## The kinds of job the plugin runs.
	kinds! : {} => List(KindInfo)
	kinds! = |{}| Registry.kinds!({})

	## How long the plugin keeps finished jobs, in milliseconds after they finished, before the sweep
	## deletes them (its `keep_done_ms` and `keep_failed_ms`): what the jobs page says.
	keeps! : {} => { keep_done_ms : U64, keep_failed_ms : U64 }
	keeps! = |{}| Registry.keeps!({})

	## The live topic (`Live.listen!`) the workers say on what they start and finish: `<id> running`,
	## `<id> done`, `<id> queued`, `<id> failed`. (The database notifies `rocx_jobs` too, when a job
	## is queued or changed: `Db.listen!`.)
	changes : Str
	changes = "rocx:jobs"

	## A kind tried five times, with no time limit.
	define : Str, (context, input => Try({}, Str)) -> Kind(context, input)
	define = |name, run!| Job.define_with(name, { attempts: 5, timeout_ms: 0 }, run!)

	## A kind tried `attempts` times (one at least), each within `timeout_ms` milliseconds (0: no
	## limit). The first effect that waits past the limit (Postgres, a socket, `Http`) ends the
	## run, which fails with "timed out after …", and is tried again if it has attempts left; Roc
	## that never waits is ended where it runs (D-057), as a crash would end it.
	define_with : Str, { attempts : U64, timeout_ms : U64 }, (context, input => Try({}, Str)) -> Kind(context, input)
	define_with = |name, { attempts, timeout_ms }, run!| { name, attempts: U64.max(attempts, 1), timeout_ms, run! }

	## When a job runs: `Now`, as soon as a worker is free; or `At(ms)`, not before that moment, in
	## milliseconds since the epoch (`Time.now_millis!`), one in the past being due now.
	When : [Now, At(U64)]

	## How a job is queued: `when` it runs, `Now` unless it says. A record whose fields have
	## defaults, so a call says only what it changes (`{}` for none), and more can be said later
	## without any call changing.
	Opts := { when : When ?? Now }

	## How a job is queued with a key (`enqueue_keyed!`): its `key`, which every call says, and `when`
	## it runs, `Now` unless it says.
	KeyedOpts := { key : Str, when : When ?? Now }

	## Queues a job of `kind` with `input`, to run when `opts` says. The workers hear of it
	## (`rocx_jobs` is notified) once it is there for them: now, or when its transaction commits. A `JobErr`
	## when the app has no jobs plugin (`Job.plugin`), or the database refuses.
	enqueue! : Kind(context, input), input, Opts => Try({}, [JobErr(Str), ..others])
		where [input.Json.Encodable([])]
	enqueue! = |kind, input, opts|
		match queue!(kind.name, Json.to_str(input), kind.attempts, opts.when, Null) {
			Ok(_) => Ok({})
			Err(why) => Err(JobErr(why))
		}

	## Queues a job as `enqueue!` does, with a key no other pending job (queued or running) has:
	## `Queued`; or nothing, if one has it (`Exists`). Once that one is done, failed or canceled,
	## the key is free again. A key names what the job is for (`reminder:ada`), so that it can be
	## cancelled or moved by it.
	enqueue_keyed! : Kind(context, input), input, KeyedOpts => Try([Queued, Exists], [JobErr(Str), ..others])
		where [input.Json.Encodable([])]
	enqueue_keyed! = |kind, input, opts|
		match queue!(kind.name, Json.to_str(input), kind.attempts, opts.when, if (opts.key.is_empty()) Null else Text(opts.key)) {
			Ok(0) => Ok(Exists)
			Ok(_) => Ok(Queued)
			Err(why) => Err(JobErr(why))
		}

	## Cancels the queued jobs with `key`: how many there were. One that is running isn't stopped.
	cancel! : Str => Try(U64, [JobErr(Str), ..others])
	cancel! = |key|
		changed!(
			"update rocx_jobs set state = 'canceled', finished_at = now() where unique_key = $1 and state = 'queued' returning id",
			"update rocx_jobs set state = 'canceled', finished_at = $2 where unique_key = $1 and state = 'queued'",
			[Text(key)],
		)

	## Moves the queued job with `key` to run `when` instead: how many there were (0 or 1).
	move! : Str, When => Try(U64, [JobErr(Str), ..others])
	move! = |key, when|
		changed!(
			"update rocx_jobs set run_at = coalesce(to_timestamp($2::bigint / 1000.0), now()) where unique_key = $1 and state = 'queued' returning id",
			"update rocx_jobs set run_at = coalesce($2, $3) where unique_key = $1 and state = 'queued'",
			[Text(key), at(when)],
		)

	## How the workers run jobs of `kind`, for the plugin's `jobs`: their input decoded from JSON.
	handler : Kind(context, input) -> Handler(context)
		where [input.Json.Parseable([InvalidJson(Str)])]
	handler = |kind| {
		name: kind.name,
		attempts: kind.attempts,
		timeout_ms: kind.timeout_ms,
		run!: |context, payload|
			match Json.parse(payload) {
				Ok(input) => (kind.run!)(context, input)
				Err(InvalidJson(why)) => Err("${kind.name}: its input isn't what it takes: ${why}")
			},
	}

	## A job, as the queue has it: its state is `queued`, `running`, `done`, `failed` or `canceled`;
	## `attempts` how many times it has been tried; times in milliseconds since the epoch (`run_at`:
	## when it is due, or was; `locked_at`: when its last attempt began).
	Row : {
		id : I64,
		kind : Str,
		input : Str,
		state : Str,
		attempts : U64,
		max_attempts : U64,
		key : Db.Nullable(Str),
		run_at : I64,
		locked_at : Db.Nullable(I64),
		finished_at : Db.Nullable(I64),
		last_error : Db.Nullable(Str),
		created_at : I64,
	}

	## Which jobs `list!` reads: in a `state`, of a `kind` ("" for any), older than `before_id` (0 for
	## any), `limit` at most (0 for all).
	Filter : { state : Str, kind : Str, before_id : I64, limit : U64 }

	## The jobs `filter` picks, newest first. A page goes on with `before_id` set to the last one's id.
	list! : Filter => Try(List(Row), [JobErr(Str), ..others])
	list! = |filter| {
		filtered =
			if Queue.lite!({}) {
				"where ($1 = '' or state = $1) and ($2 = '' or kind = $2) and ($3 = 0 or id < $3) order by id desc limit case when $4 = 0 then -1 else $4 end"
			} else {
				"where ($1 = '' or state = $1) and ($2 = '' or kind = $2) and ($3::int8 = 0 or id < $3::int8) order by id desc limit nullif($4::int8, 0)"
			}
		rows!("${columns!({})} ${filtered}", [Text(filter.state), Text(filter.kind), Int(filter.before_id), Int(filter.limit.to_i64_wrap())])
	}

	## The job with this id; `NotFound` if there is none.
	get! : I64 => Try(Row, [NotFound, JobErr(Str), ..others])
	get! = |id|
		match rows!("${columns!({})} where id = $1", [Int(id)]) {
			Ok([row]) => Ok(row)
			Ok(_) => Err(NotFound)
			Err(JobErr(why)) => Err(JobErr(why))
		}

	## How many jobs there are of each kind in each state.
	counts! : {} => Try(List({ kind : Str, state : Str, count : U64 }), [JobErr(Str), ..others])
	counts! = |{}| {
		counted : Try(List({ kind : Str, state : Str, count : U64 }), [DbErr(Str), BadRow(Str)])
		counted = Db.all!("select kind, state, count(*) as count from rocx_jobs group by kind, state order by kind, state", [])
		match counted {
			Ok(counts) => Ok(counts)
			Err(DbErr(why)) => Err(JobErr(why))
			Err(BadRow(why)) => Err(JobErr(why))
		}
	}

	## Queues a failed or canceled job again, due now, its attempts back to none. A job with a key
	## another pending job has now can't be.
	retry! : I64 => Try({}, [NotFound, JobErr(Str), ..others])
	retry! = |id|
		acted!(
			id,
			"retried",
			"update rocx_jobs set state = 'queued', attempts = 0, run_at = now(), locked_at = null, finished_at = null where id = $1 and state in ('failed', 'canceled') returning id",
			"update rocx_jobs set state = 'queued', attempts = 0, run_at = $2, locked_at = null, finished_at = null where id = $1 and state in ('failed', 'canceled')",
		)

	## Cancels a queued job.
	cancel_id! : I64 => Try({}, [NotFound, JobErr(Str), ..others])
	cancel_id! = |id|
		acted!(
			id,
			"canceled",
			"update rocx_jobs set state = 'canceled', finished_at = now() where id = $1 and state = 'queued' returning id",
			"update rocx_jobs set state = 'canceled', finished_at = $2 where id = $1 and state = 'queued'",
		)

	## Makes a queued job due now (one queued for later, or waiting to be tried again).
	run_now! : I64 => Try({}, [NotFound, JobErr(Str), ..others])
	run_now! = |id|
		acted!(
			id,
			"run now",
			"update rocx_jobs set run_at = now() where id = $1 and state = 'queued' returning id",
			"update rocx_jobs set run_at = $2 where id = $1 and state = 'queued'",
		)
}

## Inserts a job; how many were queued (0 when a pending job has its key).
queue! : Str, Str, U64, Job.When, Db.Value => Try(U64, Str)
queue! = |kind, input, attempts, when, key| {
	if !Registry.installed!({}) {
		return Err("the app has no jobs plugin to run ${kind}: list Job.plugin({ jobs: App.jobs }) in its plugins")
	}
	params = [Text(kind), Text(input), Int(attempts.to_i64_wrap()), at(when), key]
	queued =
		if Queue.lite!({}) {
			Queue.told!(
				Db.run!(
					"insert into rocx_jobs (kind, input, max_attempts, run_at, unique_key, created_at) values ($1, $2, $3, coalesce($4, $6), $5, $6) on conflict (unique_key) where state in ('queued', 'running') do nothing",
					params.append(Int(Queue.now!({}))),
				),
			)
		} else {
			Db.run!(
				"with queued as (insert into rocx_jobs (kind, input, max_attempts, run_at, unique_key) values ($1, $2, $3::int, coalesce(to_timestamp($4::bigint / 1000.0), now()), $5) on conflict (unique_key) where state in ('queued', 'running') do nothing returning id) select pg_notify('rocx_jobs', id::text) from queued",
				params,
			)
		}
	match queued {
		Ok(count) => Ok(count)
		Err(DbErr(why)) => Err(why)
	}
}

at : Job.When -> Db.Value
at = |when|
	match when {
		Now => Null
		At(ms) => Text(ms.to_str())
	}

## A row of `rocx_jobs` as `Job.Row` reads it: times in milliseconds (on SQLite, as they are kept).
columns! : {} => Str
columns! = |{}|
	if Queue.lite!({}) {
		"select id, kind, input, state, attempts, max_attempts, unique_key as key, run_at, locked_at, finished_at, last_error, created_at from rocx_jobs"
	} else {
		"select id, kind, input, state, attempts, max_attempts, unique_key as key, (extract(epoch from run_at) * 1000)::int8 as run_at, (extract(epoch from locked_at) * 1000)::int8 as locked_at, (extract(epoch from finished_at) * 1000)::int8 as finished_at, last_error, (extract(epoch from created_at) * 1000)::int8 as created_at from rocx_jobs"
	}

rows! : Str, List(Db.Value) => Try(List(Job.Row), [JobErr(Str), ..others])
rows! = |sql, params| {
	found : Try(List(Job.Row), [DbErr(Str), BadRow(Str)])
	found = Db.all!(sql, params)
	match found {
		Ok(rows) => Ok(rows)
		Err(DbErr(why)) => Err(JobErr(why))
		Err(BadRow(why)) => Err(JobErr(why))
	}
}

## Runs `sql` (an `update … returning id`), on SQLite `lite_sql` (an `update`, given now after
## `params`), then tells the workers and the jobs page (`rocx_jobs` is notified, when its
## transaction commits): how many jobs it changed.
changed! : Str, Str, List(Db.Value) => Try(U64, [JobErr(Str), ..others])
changed! = |sql, lite_sql, params| {
	done =
		if Queue.lite!({}) {
			Queue.told!(Db.run!(lite_sql, params.append(Int(Queue.now!({})))))
		} else {
			Db.run!("with changed as (${sql}) select pg_notify('rocx_jobs', id::text) from changed", params)
		}
	match done {
		Ok(count) => Ok(count)
		Err(DbErr(why)) => Err(JobErr(why))
	}
}

## Acts on job `id` (`sql`, which changes it only in the states it may be in): `NotFound` when there
## is no such job; why not, when it is in another state.
acted! : I64, Str, Str, Str => Try({}, [NotFound, JobErr(Str), ..others])
acted! = |id, done, sql, lite_sql|
	match changed!(sql, lite_sql, [Int(id)]) {
		Ok(0) =>
			match Job.get!(id) {
				Ok(row) => Err(JobErr("job #${id.to_str()} is ${row.state}: it can't be ${done}"))
				Err(NotFound) => Err(NotFound)
				Err(JobErr(why)) => Err(JobErr(why))
			}
		Ok(_) => Ok({})
		Err(JobErr(why)) =>
			if why.starts_with("23505") or why.contains("UNIQUE constraint failed") {
				Err(JobErr("job #${id.to_str()} can't be ${done}: another job with its key is pending"))
			} else {
				Err(JobErr(why))
			}
	}

## What `on_failed!` does when the app doesn't say: nothing (the worker has logged it).
ignored! : Job.Failure => {}
ignored! = |_failure| {}

## `POST /__rocx/jobs/wake`: the workers told to look for a due job now (`rocx_jobs` notified, as
## queuing one does); 204, or 503 with why.
woken! : Server.Request => Server.Response
woken! = |_request|
	match Db.notify!("rocx_jobs", "") {
		Ok({}) => Server.response(204, [], "")
		Err(DbErr(why)) => Server.response(503, [], why)
	}

## Runs a job (the plugin's call `jobs.run`): `input` is its kind, a newline, and its input as JSON.
ran! : List(Job.Handler(context)), context, Str => Try(Str, Str)
ran! = |handlers, context, input| {
	(kind, payload) =
		match input.split_first("\n") {
			Ok({ before, after }) => (before, after)
			Err(_) => (input, "")
		}
	match handlers.find_first(|job| job.name == kind) {
		Ok(job) =>
			match (job.run!)(context, payload) {
				Ok({}) => Ok("")
				Err(why) => Err(why)
			}
		Err(_) => Err("no job is called ${kind}: list it in the jobs plugin's `jobs`")
	}
}

## The plugin's start: what it runs and how long it keeps finished jobs kept, its schedules and how
## often it sweeps checked, and (with a database) the jobs a stop cut short queued again.
started! : List(Registry.Kind), List(Registry.Schedule), Registry.Keeps, U64 => Try({}, Str)
started! = |kinds, crons, keeps, sweep_ms| {
	names = kinds.map(|kind| kind.name)
	Registry.keep!(kinds, crons, keeps)
	Cron.check(crons, names)?
	if sweep_ms == 0 {
		return Err("jobs: sweep_ms is 0: say how often finished jobs are swept, in milliseconds (an hour unless the plugin's options say)")
	}
	if Db.connected!({}) {
		JobWorker.recover!(names)
	} else {
		Ok({})
	}
}
