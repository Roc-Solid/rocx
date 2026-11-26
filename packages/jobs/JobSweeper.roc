import pf.Db
import pf.Live
import pf.Log
import pf.Plugin
import Queue

## The sweep (the jobs plugin's loop `jobs.sweep`): with a database, it deletes the jobs that have
## been finished long enough, when the server starts and every `sweep_ms` (an hour) after, until
## the server stops. A done job goes `keep_done_ms` (a week) after it finished; a failed or canceled
## one `keep_failed_ms` (30 days) after, for longer, since someone may want to read why it failed or
## try it again. A queued or running job is never swept, nor is one of any kind left alone: a kind
## the app no longer runs has its old jobs swept too. The rows go a thousand a statement, so on
## SQLite a large sweep lets other writes in between.
JobSweeper := [].{

	## Sweeps now, then every `sweep_ms`, until the server stops; at once nothing, with no database.
	run! : { keep_done_ms : U64, keep_failed_ms : U64, sweep_ms : U64 } => {}
	run! = |{ keep_done_ms, keep_failed_ms, sweep_ms }| {
		if !Db.connected!({}) {
			return {}
		}
		var $going = Bool.True
		while $going {
			match JobSweeper.sweep!(keep_done_ms, keep_failed_ms) {
				Ok(0) => {}
				Ok(count) => Log.info!("rocx jobs: finished jobs swept", { count: count, keep_done_ms: keep_done_ms, keep_failed_ms: keep_failed_ms })
				Err(DbErr(why)) => Log.error!("rocx jobs: couldn't sweep finished jobs", { error: why })
			}
			$going = !Plugin.stopping!({}) and Live.next!(sweep_ms) != Gone
		}
	}

	## Deletes the done jobs that finished more than `keep_done_ms` ago, and the failed and canceled
	## ones more than `keep_failed_ms` ago, a thousand a statement: how many.
	sweep! : U64, U64 => Try(U64, [DbErr(Str)])
	sweep! = |keep_done_ms, keep_failed_ms| {
		now = Queue.now!({})
		params = [Int(cutoff(now, keep_done_ms)), Int(cutoff(now, keep_failed_ms))]
		sql =
			if Queue.lite!({}) {
				"delete from rocx_jobs where id in (select id from rocx_jobs where (state = 'done' and finished_at < $1) or (state in ('failed', 'canceled') and finished_at < $2) limit ${batch.to_str()})"
			} else {
				"delete from rocx_jobs where id in (select id from rocx_jobs where (state = 'done' and finished_at < to_timestamp($1::bigint / 1000.0)) or (state in ('failed', 'canceled') and finished_at < to_timestamp($2::bigint / 1000.0)) limit ${batch.to_str()})"
			}
		var $swept = 0
		var $more = Bool.True
		while $more {
			count = Db.run!(sql, params)?
			$swept = $swept + count
			$more = count == batch and !Plugin.stopping!({})
		}
		Ok($swept)
	}
}

## How many rows one statement of the sweep deletes at most.
batch : U64
batch = 1000

## The moment `keep_ms` before `now`, in milliseconds since the epoch: the epoch itself when
## `keep_ms` reaches back further.
cutoff : I64, U64 -> I64
cutoff = |now, keep_ms| if (keep_ms >= now.to_u64_wrap()) 0 else now - keep_ms.to_i64_wrap()

expect cutoff(10_000, 3_000) == 7_000
expect cutoff(10_000, 0) == 10_000
expect cutoff(10_000, 10_000) == 0
expect cutoff(10_000, 18_446_744_073_709_551_615) == 0
