import Db

## Work to do outside any request: queued in Postgres (`rocx_jobs`), run in the background by the
## server's workers (`JobWorker`), and run again if it fails (an `Err`, a crash, or its time limit
## passing), a little later each time, as many times as its kind says (five unless it says
## otherwise). Queued in a transaction (`Db.transaction!`), a job is a row in it: there only if it
## commits, and the workers hear of it then.
##
## ```roc
## welcome : Job.Kind({ member : I64 })
## welcome = Job.define("welcome", |{ member }| { … Email.send!(…) … })
##
## # Once, within 20 minutes: a reminder sent twice is worse than one missed.
## reminder = Job.define_with("reminder", { attempts: 1, timeout_ms: 20 * 60_000 }, |{ member }| …)
##
## Job.enqueue!(welcome, { member: 7 }, { when: Now })
## Job.enqueue!(welcome, { member: 7 }, { when: At(Time.now_millis!({}) + 60_000) })    # a minute from now
## Job.enqueue_keyed!(reminder, { member: "ada" }, { when: Now, key: "reminder:ada" })   # Queued, or Exists
## Job.cancel!("reminder:ada")
## ```
##
## The server runs the kinds the app lists (`program.jobs`, each `Job.handler(kind)`). `list!`,
## `get!` and `counts!` read the queue, and `retry!`, `cancel_id!` and `run_now!` act on one job:
## what the jobs page (`JobsPage`) is made of.
Job := [].{

	## A kind of job: its name, how many times one is tried, its time limit (milliseconds, 0 for
	## none) and what running one does with its input.
	Kind(input) : { name : Str, attempts : U64, timeout_ms : U64, run! : input => Try({}, Str) }

	## A kind tried five times, with no time limit.
	define : Str, (input => Try({}, Str)) -> Kind(input)
	define = |name, run!| Job.define_with(name, { attempts: 5, timeout_ms: 0 }, run!)

	## A kind tried `attempts` times (one at least), each within `timeout_ms` milliseconds (0: no
	## limit). The first effect that waits past the limit (Postgres, a socket, `Http`) ends the
	## run, which fails with "timed out after …", and is tried again if it has attempts left. Roc
	## that loops without an effect can't be cut off.
	define_with : Str, { attempts : U64, timeout_ms : U64 }, (input => Try({}, Str)) -> Kind(input)
	define_with = |name, { attempts, timeout_ms }, run!| { name, attempts: U64.max(attempts, 1), timeout_ms, run! }

	## When a job runs: `Now`, as soon as a worker is free; or `At(ms)`, not before that moment, in
	## milliseconds since the epoch (`Time.now_millis!`), one in the past being due now.
	When : [Now, At(U64)]

	## How a job is queued: `when` it runs. A record, so that more can be said later without every
	## call changing (Roc has no optional arguments, so each call says every field).
	Opts : { when : When }

	## How a job is queued with a key (`enqueue_keyed!`): `when` it runs, and its `key`.
	KeyedOpts : { when : When, key : Str }

	## Queues a job of `kind` with `input`, to run when `opts` says. The workers hear of it
	## (`pg_notify`) once it is there for them: now, or when its transaction commits.
	enqueue! : Kind(input), input, Opts => Try({}, [JobErr(Str)])
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
	enqueue_keyed! : Kind(input), input, KeyedOpts => Try([Queued, Exists], [JobErr(Str)])
		where [input.Json.Encodable([])]
	enqueue_keyed! = |kind, input, opts|
		match queue!(kind.name, Json.to_str(input), kind.attempts, opts.when, if (opts.key.is_empty()) Null else Text(opts.key)) {
			Ok(0) => Ok(Exists)
			Ok(_) => Ok(Queued)
			Err(why) => Err(JobErr(why))
		}

	## Cancels the queued jobs with `key`: how many there were. One that is running isn't stopped.
	cancel! : Str => Try(U64, [JobErr(Str)])
	cancel! = |key| changed!("update rocx_jobs set state = 'canceled', finished_at = now() where unique_key = $1 and state = 'queued' returning id", [Text(key)])

	## Moves the queued job with `key` to run `when` instead: how many there were (0 or 1).
	move! : Str, When => Try(U64, [JobErr(Str)])
	move! = |key, when| changed!("update rocx_jobs set run_at = coalesce(to_timestamp($2::bigint / 1000.0), now()) where unique_key = $1 and state = 'queued' returning id", [Text(key), at(when)])

	## How the server runs jobs of `kind`, for `program.jobs`: their input decoded from JSON.
	handler : Kind(input) -> { name : Str, attempts : U64, timeout_ms : U64, run! : Str => Try({}, Str) }
		where [input.Json.Parseable([InvalidJson(Str)])]
	handler = |kind| {
		name: kind.name,
		attempts: kind.attempts,
		timeout_ms: kind.timeout_ms,
		run!: |payload|
			match Json.parse(payload) {
				Ok(input) => (kind.run!)(input)
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
	list! : Filter => Try(List(Row), [JobErr(Str)])
	list! = |filter|
		rows!(
			"${columns} where ($1 = '' or state = $1) and ($2 = '' or kind = $2) and ($3::int8 = 0 or id < $3::int8) order by id desc limit nullif($4::int8, 0)",
			[Text(filter.state), Text(filter.kind), Int(filter.before_id), Int(filter.limit.to_i64_wrap())],
		)

	## The job with this id; `NotFound` if there is none.
	get! : I64 => Try(Row, [NotFound, JobErr(Str)])
	get! = |id|
		match rows!("${columns} where id = $1", [Int(id)]) {
			Ok([row]) => Ok(row)
			Ok(_) => Err(NotFound)
			Err(JobErr(why)) => Err(JobErr(why))
		}

	## How many jobs there are of each kind in each state.
	counts! : {} => Try(List({ kind : Str, state : Str, count : U64 }), [JobErr(Str)])
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
	retry! : I64 => Try({}, [NotFound, JobErr(Str)])
	retry! = |id|
		acted!(
			id,
			"retried",
			"update rocx_jobs set state = 'queued', attempts = 0, run_at = now(), locked_at = null, finished_at = null where id = $1 and state in ('failed', 'canceled') returning id",
		)

	## Cancels a queued job.
	cancel_id! : I64 => Try({}, [NotFound, JobErr(Str)])
	cancel_id! = |id| acted!(id, "canceled", "update rocx_jobs set state = 'canceled', finished_at = now() where id = $1 and state = 'queued' returning id")

	## Makes a queued job due now (one queued for later, or waiting to be tried again).
	run_now! : I64 => Try({}, [NotFound, JobErr(Str)])
	run_now! = |id| acted!(id, "run now", "update rocx_jobs set run_at = now() where id = $1 and state = 'queued' returning id")
}

## Inserts a job; how many were queued (0 when a pending job has its key).
queue! : Str, Str, U64, Job.When, Db.Value => Try(U64, Str)
queue! = |kind, input, attempts, when, key| {
	queued = Db.run!(
		"with queued as (insert into rocx_jobs (kind, input, max_attempts, run_at, unique_key) values ($1, $2, $3::int, coalesce(to_timestamp($4::bigint / 1000.0), now()), $5) on conflict (unique_key) where state in ('queued', 'running') do nothing returning id) select pg_notify('rocx_jobs', id::text) from queued",
		[Text(kind), Text(input), Int(attempts.to_i64_wrap()), at(when), key],
	)
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

## A row of `rocx_jobs` as `Job.Row` reads it: times in milliseconds.
columns : Str
columns = "select id, kind, input, state, attempts, max_attempts, unique_key as key, (extract(epoch from run_at) * 1000)::int8 as run_at, (extract(epoch from locked_at) * 1000)::int8 as locked_at, (extract(epoch from finished_at) * 1000)::int8 as finished_at, last_error, (extract(epoch from created_at) * 1000)::int8 as created_at from rocx_jobs"

rows! : Str, List(Db.Value) => Try(List(Job.Row), [JobErr(Str)])
rows! = |sql, params| {
	found : Try(List(Job.Row), [DbErr(Str), BadRow(Str)])
	found = Db.all!(sql, params)
	match found {
		Ok(rows) => Ok(rows)
		Err(DbErr(why)) => Err(JobErr(why))
		Err(BadRow(why)) => Err(JobErr(why))
	}
}

## Runs `sql` (an `update … returning id`), then tells the workers and the jobs page (`pg_notify`,
## when its transaction commits): how many jobs it changed.
changed! : Str, List(Db.Value) => Try(U64, [JobErr(Str)])
changed! = |sql, params|
	match Db.run!("with changed as (${sql}) select pg_notify('rocx_jobs', id::text) from changed", params) {
		Ok(count) => Ok(count)
		Err(DbErr(why)) => Err(JobErr(why))
	}

## Acts on job `id` (`sql`, which changes it only in the states it may be in): `NotFound` when there
## is no such job; why not, when it is in another state.
acted! : I64, Str, Str => Try({}, [NotFound, JobErr(Str)])
acted! = |id, done, sql|
	match changed!(sql, [Int(id)]) {
		Ok(0) =>
			match Job.get!(id) {
				Ok(row) => Err(JobErr("job #${id.to_str()} is ${row.state}: it can't be ${done}"))
				Err(NotFound) => Err(NotFound)
				Err(JobErr(why)) => Err(JobErr(why))
			}
		Ok(_) => Ok({})
		Err(JobErr(why)) =>
			if why.starts_with("23505") {
				Err(JobErr("job #${id.to_str()} can't be ${done}: another job with its key is pending"))
			} else {
				Err(JobErr(why))
			}
	}
