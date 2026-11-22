import pf.Db
import pf.Live
import pf.Log
import pf.Time
import Cron
import Queue
import Registry

## The schedules (the jobs plugin's `crons`): a background loop, with a database, that sleeps until
## the next one is due,
## queues its job, and goes back to sleep, until the server stops. A job is queued keyed by its
## schedule and the second it was due (`unique_key`), so a restart in that second, or another
## server, never queues it twice while the first is pending. It is tried as many times as its kind
## says.
CronTicker := [].{
	run! : List({ name : Str, schedule : Str, job : Str, input : Str }) => {}
	run! = |crons| {
		if !Db.connected!({}) {
			return {}
		}
		now = Time.now_millis!({}).to_i64_wrap()
		var $pending = crons.keep_oks(
			|cron|
				match Cron.parse(cron.schedule) {
					Ok(schedule) => Ok({ cron, schedule, due: Cron.after(schedule, now) })
					Err(why) => Err(why)
				},
		)
		var $going = Bool.True
		while $going {
			soonest = $pending.fold(
				Err(Never),
				|earliest, each|
					match (earliest, each.due) {
						(Ok(at), Ok(due)) => Ok(I64.min(at, due))
						(_, Ok(due)) => Ok(due)
						(found, Err(Never)) => found
					},
			)
			$going =
				match soonest {
					# Nothing will ever be due: sleep until the server stops.
					Err(Never) => Live.next!(3600000) != Gone
					Ok(at) => {
						wait = at - Time.now_millis!({}).to_i64_wrap()
						if (wait > 0) Live.next!(wait.to_u64_wrap()) != Gone else Bool.True
					}
				}
			if $going {
				fired = Time.now_millis!({}).to_i64_wrap()
				var $next = []
				for each in $pending {
					$next = $next.append(
						match each.due {
							Ok(due) if due <= fired => {
								queue!(each.cron, due)
								{ ..each, due: Cron.after(each.schedule, due) }
							}
							_ => each
						},
					)
				}
				$pending = $next
			} else {
				{}
			}
		}
	}
}

## Queues the schedule's job, once for the second it was due.
queue! : { name : Str, schedule : Str, job : Str, input : Str }, I64 => {}
queue! = |cron, due| {
	key = "cron:${cron.name}:${(due // 1000).to_str()}"
	params = [Text(cron.job), Text(cron.input), Text(key), Int(Registry.attempts!(cron.job).to_i64_wrap())]
	queued =
		if Queue.lite!({}) {
			Queue.told!(
				Db.run!(
					"insert into rocx_jobs (kind, input, unique_key, max_attempts, run_at, created_at) values ($1, $2, $3, $4, $5, $5) on conflict (unique_key) where state in ('queued', 'running') do nothing",
					params.append(Int(Queue.now!({}))),
				),
			)
		} else {
			Db.run!(
				"with queued as (insert into rocx_jobs (kind, input, unique_key, max_attempts) values ($1, $2, $3, $4::int) on conflict (unique_key) where state in ('queued', 'running') do nothing returning id) select pg_notify('rocx_jobs', id::text) from queued",
				params,
			)
		}
	match queued {
		Ok(_) => {}
		Err(DbErr(why)) => Log.line!("rocx cron: ${cron.name}: ${why}")
	}
}
