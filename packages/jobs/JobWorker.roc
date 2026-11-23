import pf.Db
import pf.Live
import pf.Log
import pf.Plugin
import Queue
import Registry

## A job worker: a background loop the jobs plugin runs `workers` (4) of, each a call of its own,
## until the server stops; it ends at once without a database, or with no kind of job to run.
##
## A worker takes the next job that is due of a kind the app lists (another app may share the
## database) with `for update skip locked` on Postgres, so no two take the same (on SQLite writes
## take turns, so the update that takes it is enough),
## and runs it in a call of its own (the plugin's call `jobs.run`, `Plugin.isolated!`), within its
## kind's time limit, so a crash in it, or its time running out, ends that call, not the worker. One
## that fails (an `Err`, a crash, or "timed out after …") is queued again, `retry_ms` (1000) later,
## then twice that, and so on, until its attempts (its kind's; 5 by default) run out; then it is
## failed, with why. With
## nothing due, a worker sleeps until the next job is, or until the database says one was queued
## (`rocx_jobs` notified, when the transaction that queued it commits), or the server
## stops. What it starts and finishes it says on the live topic `rocx:jobs` (the jobs page listens).
JobWorker := [].{

	## Runs jobs of the kinds the plugin runs until the server stops: the app's (`own`, each in the
	## plugin's call `jobs.run`) and those other plugins brought (`Job.adopt!`, each in the call of
	## its name), as kept when every start had run. A failed one again `retry_ms` later (doubled for
	## each attempt after), and `on_failed!` with one that failed for good. The job it is running when
	## it is told to stop, it finishes. With no database, or no kind to run, it ends at once.
	run! : List(Str), U64, ({ kind : Str, id : I64, attempts : U64, error : Str } => {}) => {}
	run! = |own, retry_ms, on_failed!| {
		listed_kinds = Registry.kinds!({})
		if !Db.connected!({}) or listed_kinds.is_empty() {
			return {}
		}
		kinds = listed_kinds.map(|kind| kind.name)
		match Db.listen!("rocx_jobs") {
			Ok({}) => {}
			Err(DbErr(why)) => Log.warn!("rocx jobs: can't hear when a job is queued, so looks every second instead", { error: why })
		}
		var $going = Bool.True
		while $going {
			$going =
				if Plugin.stopping!({}) {
					Bool.False
				} else {
					match take!(kinds) {
						Ok(Some(job)) => {
							Live.publish!("rocx:jobs", "${job.id.to_str()} running")
							finish!(job, attempt!(job, own.contains(job.kind), limit(listed_kinds, job.kind)), retry_ms, on_failed!)
							Bool.True
						}
						Ok(None) => Live.next!(due_in!(kinds)) != Gone
						Err(why) => {
							Log.error!("rocx jobs: couldn't take a job", { error: why })
							Live.next!(1000) != Gone
						}
					}
				}
		}
	}

	## When the server starts (with a database): a job of the plugin's kinds that was running when it
	## last stopped was cut short, so it is queued again; done jobs older than a week go.
	recover! : List(Str) => Try({}, Str)
	recover! = |kinds| {
		lite = Queue.lite!({})
		requeued =
			if lite {
				Db.run!("update rocx_jobs set state = 'queued', locked_at = null where state = 'running' and kind in (select value from json_each($1))", [Queue.kinds(kinds)])
			} else {
				Db.run!("update rocx_jobs set state = 'queued', locked_at = null where state = 'running' and kind = any(string_to_array($1, E'\\n'))", [listed(kinds)])
			}
		match requeued {
			Err(DbErr(why)) => Err("jobs: ${why}")
			Ok(count) => {
				if (count > 0) Log.warn!("rocx jobs: jobs cut short by the last stop, queued again", { count: count }) else {}
				swept =
					if lite {
						Db.run!("delete from rocx_jobs where state = 'done' and finished_at < $1", [Int(Queue.now!({}) - 7 * 24 * 3_600_000)])
					} else {
						Db.run!("delete from rocx_jobs where state = 'done' and finished_at < now() - interval '7 days'", [])
					}
				match swept {
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
	taken =
		if Queue.lite!({}) {
			Db.all!(
				"update rocx_jobs set state = 'running', attempts = attempts + 1, locked_at = $2 where id = (select id from rocx_jobs where state = 'queued' and run_at <= $2 and kind in (select value from json_each($1)) order by run_at, id limit 1) returning id, kind, input, attempts, max_attempts",
				[Queue.kinds(kinds), Int(Queue.now!({}))],
			)
		} else {
			Db.all!(
				"update rocx_jobs set state = 'running', attempts = attempts + 1, locked_at = now() where id = (select id from rocx_jobs where state = 'queued' and run_at <= now() and kind = any(string_to_array($1, E'\\n')) order by run_at, id for update skip locked limit 1) returning id, kind, input, attempts, max_attempts",
				[listed(kinds)],
			)
		}
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

## Runs the job, isolated, within `limit_ms` (0: no limit): one of the app's kinds (`own`) in the
## plugin's call `jobs.run` (its kind, a newline, its input), another plugin's in the call of its
## kind's name (`Job.call`), given its input. Ok, or why it failed (a crash says so; a run its limit
## cut off says "timed out after …").
attempt! : Taken, Bool, U64 => Try({}, Str)
attempt! = |job, own, limit_ms| {
	ran = if (own) Plugin.isolated!("jobs.run", "${job.kind}\n${job.input}", limit_ms) else Plugin.isolated!(job.kind, job.input, limit_ms)
	match ran {
		Ok(_) => Ok({})
		Err(why) => Err(why)
	}
}

finish! : Taken, Try({}, Str), U64, ({ kind : Str, id : I64, attempts : U64, error : Str } => {}) => {}
finish! = |job, outcome, retry_ms, on_failed!| {
	lite = Queue.lite!({})
	now = Queue.now!({})
	match outcome {
		Ok({}) => {
			recorded!(
				job,
				if lite {
					Db.run!("update rocx_jobs set state = 'done', finished_at = $2, last_error = null where id = $1", [Int(job.id), Int(now)])
				} else {
					Db.run!("update rocx_jobs set state = 'done', finished_at = now(), last_error = null where id = $1", [Int(job.id)])
				},
			)
			Live.publish!("rocx:jobs", "${job.id.to_str()} done")
		}
		Err(why) if job.attempts < job.max_attempts => {
			wait = backoff(retry_ms, job.attempts)
			recorded!(
				job,
				if lite {
					Db.run!("update rocx_jobs set state = 'queued', last_error = $2, run_at = $3 where id = $1", [Int(job.id), Text(why), Int(now + wait.to_i64_wrap())])
				} else {
					Db.run!(
						"update rocx_jobs set state = 'queued', last_error = $2, run_at = now() + ($3::bigint * interval '1 millisecond') where id = $1",
						[Int(job.id), Text(why), Text(wait.to_str())],
					)
				},
			)
			Log.warn!("rocx jobs: a job failed, and runs again", { kind: job.kind, id: job.id, attempt: job.attempts, of: job.max_attempts, again_in_ms: wait, error: why })
			Live.publish!("rocx:jobs", "${job.id.to_str()} queued")
			# The other workers, asleep until what was due when they looked, look again.
			recorded!(
				job,
				match Db.notify!("rocx_jobs", "") {
					Ok({}) => Ok(0)
					Err(DbErr(unheard)) => Err(DbErr(unheard))
				},
			)
		}
		Err(why) => {
			recorded!(
				job,
				if lite {
					Db.run!("update rocx_jobs set state = 'failed', finished_at = $3, last_error = $2 where id = $1", [Int(job.id), Text(why), Int(now)])
				} else {
					Db.run!("update rocx_jobs set state = 'failed', finished_at = now(), last_error = $2 where id = $1", [Int(job.id), Text(why)])
				},
			)
			Log.error!("rocx jobs: a job failed for good", { kind: job.kind, id: job.id, attempts: job.attempts, error: why })
			Live.publish!("rocx:jobs", "${job.id.to_str()} failed")
			on_failed!({ kind: job.kind, id: job.id, attempts: job.attempts, error: why })
		}
	}
}

recorded! : Taken, Try(U64, [DbErr(Str)]) => {}
recorded! = |job, done|
	match done {
		Ok(_) => {}
		Err(DbErr(why)) => Log.error!("rocx jobs: couldn't record how a job went", { kind: job.kind, id: job.id, error: why })
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
	due =
		if Queue.lite!({}) {
			Db.all!(
				"select coalesce(max(0, min(run_at) - $2), 60000) as ms from rocx_jobs where state = 'queued' and kind in (select value from json_each($1))",
				[Queue.kinds(kinds), Int(Queue.now!({}))],
			)
		} else {
			Db.all!(
				"select coalesce(greatest(0, ceil(extract(epoch from (min(run_at) - now())) * 1000)), 60000)::int8 as ms from rocx_jobs where state = 'queued' and kind = any(string_to_array($1, E'\\n'))",
				[listed(kinds)],
			)
		}
	match due {
		Ok([{ ms }]) => U64.min(ms, 60000)
		_ => 1000
	}
}

expect backoff(20, 1) == 20
expect backoff(20, 2) == 40
expect backoff(1000, 4) == 8000
expect backoff(1, 50) == 1048576
