import jobs.Job
import pf.Db
import pf.Log
import Alerts
import Checks
import Store

## Acme Status's jobs, run by packages/jobs's workers (main.roc lists the plugin). `rocx build` finds
## each kind at the top of this block and lists it in `App.jobs`.
##
## - `due`, every 10 seconds (main.roc's cron): claims the monitors whose check is due and queues a
##   `check` of each.
## - `check`: checks one monitor (Checks.roc), tried three times if it can't store what it found.
## - `alert`: mails one subscriber about an incident, tried again (five times, waiting longer each
##   time) while the mail server doesn't answer.
## - `nightly`, at 03:00 UTC: rolls each day's checks up into `daily` and deletes checks older than
##   a week.
Jobs := [].{

	## Queues a check of every monitor that is due one.
	due : Job.Kind({})
	due = Job.define_with("due", { attempts: 1, timeout_ms: 30_000 }, |{}| sweep!({}))

	## Checks one monitor.
	check : Job.Kind({ monitor : I64 })
	check = Job.define_with("check", { attempts: 3, timeout_ms: 45_000 }, |{ monitor }| Checks.run!(monitor, alert!))

	## Mails one subscriber that an incident opened or closed.
	alert : Job.Kind({ incident : I64, kind : Str, subscriber : I64 })
	alert = Job.define("alert", |input| Alerts.send!(input))

	## Queues an incident's alerts (what a check does when it opens or closes one, and the admin's
	## "Resolved" update): for a transaction that changes an incident.
	alerts! : I64, [Opened, Closed] => Try({}, [DbErr(Str), BadRow(Str), JobErr(Str)])
	alerts! = |incident, what| alert!(incident, what)

	## Rolls up the days before today, and deletes checks older than a week.
	nightly : Job.Kind({})
	nightly = Job.define(
		"nightly",
		|{}|
			match Store.roll_up!({}) {
				Ok({ days, deleted }) => {
					Log.info!("uptime: rolled up the checks", { days: days, deleted: deleted })
					Ok({})
				}
				Err(DbErr(why)) => Err(why)
			},
	)
}

## The sweep: each monitor due is claimed and its check queued in one transaction, keyed by the
## monitor, so a check still waiting isn't queued twice.
sweep! : {} => Try({}, Str)
sweep! = |{}| {
	queued = Db.transaction!(
		|{}| {
			ids = Store.claim_due!({})?
			for id in ids {
				_ = Job.enqueue_keyed!(Jobs.check, { monitor: id }, { when: Now, key: "check:${id.to_str()}" })?
			}
			Ok({})
		},
	)
	match queued {
		Ok({}) => Ok({})
		Err(DbErr(why)) => Err(why)
		Err(BadRow(why)) => Err(why)
		Err(JobErr(why)) => Err(why)
	}
}

## Queues an incident's alerts, one job a subscriber, in the transaction that opened or closed it,
## so they go only if it commits.
alert! : I64, [Opened, Closed] => Try({}, [DbErr(Str), BadRow(Str), JobErr(Str)])
alert! = |incident, what| {
	kind = Alerts.kind_name(what)
	for subscriber in Store.subscribers!({})? {
		_ = Job.enqueue_keyed!(Jobs.alert, { incident, kind, subscriber: subscriber.id }, { when: Now, key: "alert:${incident.to_str()}:${kind}:${subscriber.id.to_str()}" })?
	}
	Ok({})
}
