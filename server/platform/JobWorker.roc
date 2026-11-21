import Db
import Host
import Live
import Log
import Registry
import Setting

## A job worker: a background loop the server runs `--job-workers` (4) of, each on a thread of its
## own, until it stops.
##
## A worker takes the next job that is due of a kind the app lists (another app may share the
## database) with `for update skip locked`, so no two take the same,
## and runs it in a call of its own (`Host.isolated!`), within its kind's time limit, so a crash in
## it, or its time running out, ends that call, not the worker. One that fails (an `Err`, a crash,
## or "timed out after …") is queued again, `--job-retry-ms` (1000) later, then twice that, and so
## on, until its attempts (its kind's; 5 by default) run out; then it is failed, with why. With
## nothing due, a worker sleeps until the next job is, or until Postgres says one was queued
## (`pg_notify` on `rocx_jobs`, sent when the transaction that queued it commits), or the server
## stops. What it starts and finishes it says on the live topic `rocx:jobs` (the jobs page listens).
JobWorker := [].{

	## Runs jobs of `kinds` until the server stops. The job it is running when it is told to stop, it
	## finishes.
	run! : List(Registry.Kind) => {}
	run! = |listed_kinds| {
		kinds = listed_kinds.map(|kind| kind.name)
		retry_ms = Setting.number!("job-retry-ms", 1000)
		match Host.db_listen!("rocx_jobs") {
			Ok({}) => {}
			Err(why) => Log.line!("rocx jobs: can't hear when a job is queued (looking every second instead): ${why}")
		}
		var $going = Bool.True
		while $going {
			$going =
				if Host.stopping!({}) {
					Bool.False
				} else {
					match take!(kinds) {
						Ok(Some(job)) => {
							Live.publish!("rocx:jobs", "${job.id.to_str()} running")
							finish!(job, attempt!(job, limit(listed_kinds, job.kind)), retry_ms)
							Bool.True
						}
						Ok(None) => Live.next!(due_in!(kinds)) != Gone
						Err(why) => {
							Log.line!("rocx jobs: ${why}")
							Live.next!(1000) != Gone
						}
					}
				}
		}
	}

	## When the server starts: a job of the app's kinds that was running when it last stopped was cut
	## short, so it is queued again; done jobs older than a week go.
	recover! : List(Str) => Try({}, Str)
	recover! = |kinds| {
		requeued = Db.run!("update rocx_jobs set state = 'queued', locked_at = null where state = 'running' and kind = any(string_to_array($1, E'\\n'))", [listed(kinds)])
		match requeued {
			Err(DbErr(why)) => Err("jobs: ${why}")
			Ok(count) => {
				if (count > 0) Log.line!("rocx jobs: ${count.to_str()} cut short by the last stop, queued again") else {}
				match Db.run!("delete from rocx_jobs where state = 'done' and finished_at < now() - interval '7 days'", []) {
					Ok(_) => Ok({})
					Err(DbErr(why)) => Err("jobs: ${why}")
				}
			}
		}
	}
}

## A job a worker has taken.
Taken : { id : I64, kind : Str, input : Str, attempts : U64, max_attempts : U64 }

take! : List(Str) => Try([Some(Taken), None], Str)
take! = |kinds| {
	taken : Try(List(Taken), [DbErr(Str), BadRow(Str)])
	taken = Db.all!(
		"update rocx_jobs set state = 'running', attempts = attempts + 1, locked_at = now() where id = (select id from rocx_jobs where state = 'queued' and run_at <= now() and kind = any(string_to_array($1, E'\\n')) order by run_at, id for update skip locked limit 1) returning id, kind, input, attempts, max_attempts",
		[listed(kinds)],
	)
	match taken {
		Ok([job]) => Ok(Some(job))
		Ok(_) => Ok(None)
		Err(DbErr(why)) => Err(why)
		Err(BadRow(why)) => Err(why)
	}
}

## The time limit of the kind called `name`, in milliseconds (0: none).
limit : List(Registry.Kind), Str -> U64
limit = |kinds, name|
	match kinds.find_first(|kind| kind.name == name) {
		Ok(kind) => kind.timeout_ms
		Err(_) => 0
	}

## Runs the job, isolated, within `limit_ms` (0: no limit): Ok, or why it failed (a crash says so;
## a run its limit cut off says "timed out after …").
attempt! : Taken, U64 => Try({}, Str)
attempt! = |job, limit_ms| {
	ran = Host.isolated!("job:${job.kind}", job.input, limit_ms)
	match ran.status {
		0 => Ok({})
		1 => Err(ran.out)
		3 => Err(ran.out)
		_ => Err("crashed: ${ran.out}")
	}
}

finish! : Taken, Try({}, Str), U64 => {}
finish! = |job, outcome, retry_ms| {
	name = "${job.kind} #${job.id.to_str()}"
	match outcome {
		Ok({}) => {
			recorded!(name, Db.run!("update rocx_jobs set state = 'done', finished_at = now(), last_error = null where id = $1", [Int(job.id)]))
			Live.publish!("rocx:jobs", "${job.id.to_str()} done")
		}
		Err(why) if job.attempts < job.max_attempts => {
			wait = backoff(retry_ms, job.attempts)
			recorded!(
				name,
				Db.run!(
					"update rocx_jobs set state = 'queued', last_error = $2, run_at = now() + ($3::bigint * interval '1 millisecond') where id = $1",
					[Int(job.id), Text(why), Text(wait.to_str())],
				),
			)
			Log.line!("rocx jobs: ${name} failed (attempt ${job.attempts.to_str()} of ${job.max_attempts.to_str()}), again in ${wait.to_str()} ms: ${why}")
			Live.publish!("rocx:jobs", "${job.id.to_str()} queued")
			# The other workers, asleep until what was due when they looked, look again.
			recorded!(name, Db.run!("select pg_notify('rocx_jobs', '')", []))
		}
		Err(why) => {
			recorded!(name, Db.run!("update rocx_jobs set state = 'failed', finished_at = now(), last_error = $2 where id = $1", [Int(job.id), Text(why)]))
			Log.line!("rocx jobs: ${name} failed for good after ${job.attempts.to_str()} attempts: ${why}")
			Live.publish!("rocx:jobs", "${job.id.to_str()} failed")
		}
	}
}

recorded! : Str, Try(U64, [DbErr(Str)]) => {}
recorded! = |name, done|
	match done {
		Ok(_) => {}
		Err(DbErr(why)) => Log.line!("rocx jobs: couldn't record how ${name} went: ${why}")
	}

## The kinds, one per line, for `kind = any(string_to_array($1, E'\n'))`.
listed : List(Str) -> [Text(Str)]
listed = |kinds| Text(Str.join_with(kinds, "\n"))

## How long to wait before attempt `attempts + 1`: `retry_ms`, doubled for each attempt after the
## first (twenty times at most).
backoff : U64, U64 -> U64
backoff = |retry_ms, attempts| {
	var $wait = retry_ms
	var $doubled = 1.U64
	while $doubled < attempts and $doubled <= 20 {
		$wait = $wait * 2
		$doubled = $doubled + 1
	}
	$wait
}

## Milliseconds until the next queued job is due: none due, a minute (a job queued meanwhile wakes
## the worker anyway).
due_in! : List(Str) => U64
due_in! = |kinds| {
	due : Try(List({ ms : U64 }), [DbErr(Str), BadRow(Str)])
	due = Db.all!(
		"select coalesce(greatest(0, ceil(extract(epoch from (min(run_at) - now())) * 1000)), 60000)::int8 as \"ms!\" from rocx_jobs where state = 'queued' and kind = any(string_to_array($1, E'\\n'))",
		[listed(kinds)],
	)
	match due {
		Ok([{ ms }]) => U64.min(ms, 60000)
		_ => 1000
	}
}

expect backoff(20, 1) == 20
expect backoff(20, 2) == 40
expect backoff(1000, 4) == 8000
expect backoff(1, 50) == 1048576
