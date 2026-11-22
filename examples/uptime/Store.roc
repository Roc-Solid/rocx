import pf.Db
import pf.Endpoint
import pf.Log
import Incident

## The app in Postgres: every query it makes, in one place. The tables are
## migrations/0001_uptime.sql. A row comes back as the record its query is annotated with, by column
## name (`Db.all!`); a column that may be null is a `Db.Nullable`. Moments are read as text in UTC
## (the migration's `iso()`), days as `2026-11-22` (`utc_day()`).
Store := [].{

	## What a query can fail with: no such row, or the database's own error.
	Problem : [NotFound, DbErr(Str), BadRow(Str)]

	## A monitor, as a check needs it.
	Monitor : { id : I64, name : Str, url : Str, method : Str, expected_status : U64, timeout_ms : U64, threshold : U64, paused : Bool }

	## What a check found: whether it passed, the status it was answered with (`0` for none), how
	## long it took, and what was wrong (`""` when nothing was).
	Found : { up : Bool, status : U64, latency_ms : U64, error : Str }

	## What storing a check did to its monitor's incident: nothing, or which one it opened or closed.
	Outcome : { decision : Incident.Decision, incident : I64 }

	## A monitor on the status page: what it is, where it is, and how it is now.
	Row : { id : I64, name : Str, group_name : Str, paused : Bool, last_up : Db.Nullable(Bool), last_at : Str, last_latency_ms : U64, open : Bool }

	## A monitor's days, rolled up or counted from its checks.
	DayRow : { monitor : I64, day : Str, checks : U64, up : U64, latency_ms_sum : U64 }

	## An incident with what was said about it, newest first.
	IncidentRow : { id : I64, monitor : I64, monitor_name : Str, title : Str, opened_at : Str, closed_at : Db.Nullable(Str), minutes : U64 }

	## One update of an incident.
	UpdateRow : { incident : I64, at : Str, state : Str, body : Str, author : Str }

	## A check, as a monitor's page lists it.
	CheckRow : { at : Str, up : Bool, status : Db.Nullable(U64), latency_ms : U64, error : Str }

	## What a route answers for a query that failed: a 404 for a row that isn't there, a 500 for the
	## rest (the database's error, or the job queue's when it queued alerts), its details in the
	## server's log rather than in the answer.
	refused! : [NotFound, DbErr(Str), BadRow(Str), JobErr(Str)] => Endpoint.Refusal
	refused! = |problem|
		match problem {
			NotFound => NotFound
			DbErr(why) => {
				Log.error!("uptime: a query failed", { error: why })
				Status(500, "Couldn't read or save that just now; try again.")
			}
			BadRow(why) => {
				Log.error!("uptime: a row didn't read", { error: why })
				Status(500, "Couldn't read or save that just now; try again.")
			}
			JobErr(why) => {
				Log.error!("uptime: a job wasn't queued", { error: why })
				Status(500, "Couldn't read or save that just now; try again.")
			}
		}

	# ---- Checking ----

	## The monitors due a check, each claimed for its next one: the sweep (`Jobs.due`) queues a check
	## of each. Two sweeps at once can't claim one monitor twice: the update takes its row's lock.
	## Due again an interval later, less a few seconds, so a monitor every 30 s is checked every 30 s
	## by a sweep every 10 s, not every 40.
	claim_due! : {} => Try(List(I64), [DbErr(Str), BadRow(Str)])
	claim_due! = |{}| {
		rows : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"update monitors set next_check_at = now() + make_interval(secs => interval_s) - interval '5 seconds' where not paused and next_check_at <= now() returning id",
			[],
		)
		Ok(rows?.map(|row| row.id))
	}

	## A monitor, as a check needs it.
	monitor! : I64 => Try(Store.Monitor, Store.Problem)
	monitor! = |id| {
		rows : Try(List(Store.Monitor), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("select id, name, url, method, expected_status, timeout_ms, threshold, paused from monitors where id = $1", [Int(id)])
		first(rows?)
	}

	## Stores what a check of `monitor` found, in one transaction: the check, the monitor's streak of
	## failures, and the incident `Incident.decide` says to open or close, with its update and the
	## alerts it queues (`alert!`, given the incident and whether it opened). If anything fails,
	## none of it stays, and the job is tried again. Its errors are the database's and the job
	## queue's (`alert!`'s), each as it came: the transaction's body `?`s both.
	record! : Store.Monitor, Store.Found, (I64, [Opened, Closed] => Try({}, [DbErr(Str), BadRow(Str), JobErr(Str)])) => Try(Store.Outcome, [DbErr(Str), BadRow(Str), JobErr(Str)])
	record! = |monitor, found, alert!|
		Db.transaction!(
			|{}| {
				status = if (found.status == 0) Null else Int(found.status.to_i64_wrap())
				_ = Db.run!(
					"insert into checks (monitor_id, up, status, latency_ms, error) values ($1, $2, $3, $4, $5)",
					[Int(monitor.id), Bool(found.up), status, Int(found.latency_ms.to_i64_wrap()), Text(found.error)],
				)?
				streaks : Try(List({ streak : U64 }), [DbErr(Str), BadRow(Str)])
				streaks = Db.all!("update monitors set streak = case when $2 then 0 else streak + 1 end where id = $1 returning streak", [Int(monitor.id), Bool(found.up)])
				streak = streaks?.first().map_ok(|row| row.streak) ?? 0
				opens : Try(List({ id : I64, minutes : U64 }), [DbErr(Str), BadRow(Str)])
				opens = Db.all!(
					"select id, floor(extract(epoch from now() - opened_at) / 60)::bigint as minutes from incidents where monitor_id = $1 and closed_at is null",
					[Int(monitor.id)],
				)
				open = opens?.first()
				decision = Incident.decide({ up: found.up, streak, threshold: monitor.threshold, open: open.is_ok() })
				match decision {
					Open => {
						made : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
						made = Db.all!(
							"insert into incidents (monitor_id, title) values ($1, $2) on conflict (monitor_id) where closed_at is null do nothing returning id",
							[Int(monitor.id), Text(Incident.title(monitor.name))],
						)
						match made?.first() {
							Ok({ id }) => {
								said = Incident.opened({ name: monitor.name, failures: streak, problem: found.error })
								_ = Db.run!("insert into incident_updates (incident_id, state, body) values ($1, 'investigating', $2)", [Int(id), Text(said)])?
								alert!(id, Opened)?
								Ok({ decision: Open, incident: id })
							}
							Err(_) => Ok({ decision: Keep, incident: 0 })
						}
					}
					Close => {
						closed : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
						closed = Db.all!("update incidents set closed_at = now() where monitor_id = $1 and closed_at is null returning id", [Int(monitor.id)])
						match closed?.first() {
							Ok({ id }) => {
								minutes = open.map_ok(|row| row.minutes) ?? 0
								said = Incident.closed({ name: monitor.name, minutes, status: found.status, latency_ms: found.latency_ms })
								_ = Db.run!("insert into incident_updates (incident_id, state, body) values ($1, 'resolved', $2)", [Int(id), Text(said)])?
								alert!(id, Closed)?
								Ok({ decision: Close, incident: id })
							}
							Err(_) => Ok({ decision: Keep, incident: 0 })
						}
					}
					Keep => Ok({ decision: Keep, incident: 0 })
				}
			},
		)

	## Rolls every day before today up into `daily` (a day rolled up stays as it was: its checks are
	## all in by then), then deletes the checks older than a week whose day is rolled up. How many
	## days it rolled up, and how many checks it deleted.
	roll_up! : {} => Try({ days : U64, deleted : U64 }, [DbErr(Str)])
	roll_up! = |{}|
		Db.transaction!(
			|{}| {
				days = Db.run!(
					"insert into daily (monitor_id, day, checks, up, latency_ms_sum) select monitor_id, utc_day(at), count(*), count(*) filter (where up), sum(latency_ms) from checks where at < utc_today()::timestamp at time zone 'UTC' group by 1, 2 on conflict (monitor_id, day) do nothing",
					[],
				)?
				deleted = Db.run!(
					"delete from checks c where c.at < now() - interval '7 days' and exists (select 1 from daily d where d.monitor_id = c.monitor_id and d.day = utc_day(c.at))",
					[],
				)?
				Ok({ days, deleted })
			},
		)

	# ---- The status page ----

	## The days since the epoch today (UTC), and the moment now.
	now! : {} => Try({ today : U64, now : Str }, [DbErr(Str), BadRow(Str)])
	now! = |{}| {
		rows : Try(List({ today : U64, now : Str }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("select (utc_today() - date '1970-01-01')::bigint as today, iso(now()) as now", [])
		Ok(rows?.first() ?? { today: 0, now: "" })
	}

	## Every monitor, by group and then as they were added, with its last check and whether it has
	## an open incident.
	rows! : {} => Try(List(Store.Row), [DbErr(Str), BadRow(Str)])
	rows! = |{}|
		Db.all!(
			"select m.id, m.name, m.group_name, m.paused, c.up as last_up, coalesce(iso(c.at), '') as last_at, coalesce(c.latency_ms, 0) as last_latency_ms, exists (select 1 from incidents i where i.monitor_id = m.id and i.closed_at is null) as open from monitors m left join lateral (select up, at, latency_ms from checks where monitor_id = m.id order by at desc limit 1) c on true order by (select min(id) from monitors g where g.group_name = m.group_name), m.id",
			[],
		)

	## Each monitor's checks in the last 24 hours, and how many passed.
	last_day! : {} => Try(List({ monitor : I64, checks : U64, up : U64 }), [DbErr(Str), BadRow(Str)])
	last_day! = |{}| Db.all!("select monitor_id as monitor, count(*) as checks, count(*) filter (where up) as up from checks where at > now() - interval '24 hours' group by 1", [])

	## Each monitor's last 90 days: the days rolled up, and the days counted from the checks kept
	## (`Uptime.combine` puts them together).
	days! : {} => Try({ rolled : List(Store.DayRow), raw : List(Store.DayRow) }, [DbErr(Str), BadRow(Str)])
	days! = |{}| {
		rolled : Try(List(Store.DayRow), [DbErr(Str), BadRow(Str)])
		rolled = Db.all!("select monitor_id as monitor, day::text as day, checks, up, latency_ms_sum from daily where day > utc_today() - 90", [])
		raw : Try(List(Store.DayRow), [DbErr(Str), BadRow(Str)])
		raw = Db.all!(
			"select monitor_id as monitor, utc_day(at)::text as day, count(*) as checks, count(*) filter (where up) as up, sum(latency_ms) as latency_ms_sum from checks where at > now() - interval '90 days' group by 1, 2",
			[],
		)
		Ok({ rolled: rolled?, raw: raw? })
	}

	## Each monitor's average latency of the checks that passed, an hour at a time over the last
	## 24 (`hours_ago` 0 is the last hour).
	hourly! : {} => Try(List({ monitor : I64, hours_ago : U64, latency_ms : U64 }), [DbErr(Str), BadRow(Str)])
	hourly! = |{}|
		Db.all!(
			"select monitor_id as monitor, floor(extract(epoch from now() - at) / 3600)::bigint as hours_ago, avg(latency_ms)::bigint as latency_ms from checks where at > now() - interval '24 hours' and up group by 1, 2",
			[],
		)

	## The incidents open now and those closed in the last 14 days, newest first, with their
	## updates, newest first; or one monitor's of the last 90 days (`monitor` not 0).
	incidents! : I64 => Try({ incidents : List(Store.IncidentRow), updates : List(Store.UpdateRow) }, [DbErr(Str), BadRow(Str)])
	incidents! = |monitor| {
		which = "(i.closed_at is null or i.closed_at > now() - interval '14 days') and $1 = 0 or i.monitor_id = $1 and i.opened_at > now() - interval '90 days'"
		incidents : Try(List(Store.IncidentRow), [DbErr(Str), BadRow(Str)])
		incidents = Db.all!(
			"select i.id, i.monitor_id as monitor, m.name as monitor_name, i.title, iso(i.opened_at) as opened_at, iso(i.closed_at) as closed_at, floor(extract(epoch from coalesce(i.closed_at, now()) - i.opened_at) / 60)::bigint as minutes from incidents i join monitors m on m.id = i.monitor_id where ${which} order by i.opened_at desc limit 20",
			[Int(monitor)],
		)
		updates : Try(List(Store.UpdateRow), [DbErr(Str), BadRow(Str)])
		updates = Db.all!(
			"select u.incident_id as incident, iso(u.at) as at, u.state, u.body, u.author from incident_updates u join incidents i on i.id = u.incident_id where ${which} order by u.at desc, u.id desc",
			[Int(monitor)],
		)
		Ok({ incidents: incidents?, updates: updates? })
	}

	## One incident, with its updates, newest first.
	incident! : I64 => Try({ incident : Store.IncidentRow, updates : List(Store.UpdateRow) }, Store.Problem)
	incident! = |id| {
		incidents : Try(List(Store.IncidentRow), [DbErr(Str), BadRow(Str)])
		incidents = Db.all!(
			"select i.id, i.monitor_id as monitor, m.name as monitor_name, i.title, iso(i.opened_at) as opened_at, iso(i.closed_at) as closed_at, floor(extract(epoch from coalesce(i.closed_at, now()) - i.opened_at) / 60)::bigint as minutes from incidents i join monitors m on m.id = i.monitor_id where i.id = $1",
			[Int(id)],
		)
		incident = first(incidents?)?
		updates : Try(List(Store.UpdateRow), [DbErr(Str), BadRow(Str)])
		updates = Db.all!("select incident_id as incident, iso(at) as at, state, body, author from incident_updates where incident_id = $1 order by at desc, id desc", [Int(id)])
		Ok({ incident, updates: updates? })
	}

	# ---- A monitor's page ----

	## A monitor as its public page shows it: no URL, which may be an address inside the company.
	about! : I64 => Try({ id : I64, name : Str, group_name : Str, interval_s : U64, expected_status : U64, threshold : U64 }, Store.Problem)
	about! = |id| {
		rows : Try(List({ id : I64, name : Str, group_name : Str, interval_s : U64, expected_status : U64, threshold : U64 }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("select id, name, group_name, interval_s, expected_status, threshold from monitors where id = $1", [Int(id)])
		first(rows?)
	}

	## A monitor's average latency of passing checks, half an hour at a time over the last 24 hours
	## (`slot` 0 is the last half hour).
	latency! : I64 => Try(List({ slot : U64, latency_ms : U64 }), [DbErr(Str), BadRow(Str)])
	latency! = |id|
		Db.all!(
			"select floor(extract(epoch from now() - at) / 1800)::bigint as slot, avg(latency_ms)::bigint as latency_ms from checks where monitor_id = $1 and at > now() - interval '24 hours' and up group by 1",
			[Int(id)],
		)

	## A monitor's failed checks over the last 7 days, by day (`days_ago` 0 is today) and hour (UTC).
	failures! : I64 => Try(List({ days_ago : U64, hour : U64, failed : U64 }), [DbErr(Str), BadRow(Str)])
	failures! = |id|
		Db.all!(
			"select utc_today() - utc_day(at) as days_ago, extract(hour from at at time zone 'UTC')::bigint as hour, count(*) as failed from checks where monitor_id = $1 and not up and utc_day(at) > utc_today() - 7 group by 1, 2",
			[Int(id)],
		)

	## A monitor's last 20 checks, the newest first.
	recent! : I64 => Try(List(Store.CheckRow), [DbErr(Str), BadRow(Str)])
	recent! = |id| Db.all!("select iso(at) as at, up, status, latency_ms, error from checks where monitor_id = $1 order by at desc limit 20", [Int(id)])

	# ---- Subscribers ----

	## Subscribes `email` (once, whatever its case): whether it is new.
	subscribe! : Str => Try(Bool, [DbErr(Str)])
	subscribe! = |email| {
		added = Db.run!("insert into subscribers (email) values ($1) on conflict ((lower(email))) do nothing", [Text(email)])?
		Ok(added > 0)
	}

	## Unsubscribes the subscriber whose link has `token`: their address.
	unsubscribe! : Str => Try(Str, Store.Problem)
	unsubscribe! = |token| {
		rows : Try(List({ email : Str }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("delete from subscribers where token = $1 returning email", [Text(token)])
		first(rows?).map_ok(|row| row.email)
	}

	## Every subscriber's address and unsubscribe token.
	subscribers! : {} => Try(List({ id : I64, email : Str, token : Str }), [DbErr(Str), BadRow(Str)])
	subscribers! = |{}| Db.all!("select id, email, token from subscribers order by id", [])

	## The subscriber with `id`, still subscribed.
	subscriber! : I64 => Try({ email : Str, token : Str }, Store.Problem)
	subscriber! = |id| {
		rows : Try(List({ email : Str, token : Str }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("select email, token from subscribers where id = $1", [Int(id)])
		first(rows?)
	}

	# ---- The admin's ----

	## Every monitor, as the admin's page lists it.
	admin_rows! : {} => Try(List({ id : I64, name : Str, url : Str, method : Str, interval_s : U64, paused : Bool, streak : U64, last_up : Db.Nullable(Bool), last_at : Str, open : Bool }), [DbErr(Str), BadRow(Str)])
	admin_rows! = |{}|
		Db.all!(
			"select m.id, m.name, m.url, m.method, m.interval_s, m.paused, m.streak, c.up as last_up, coalesce(iso(c.at), '') as last_at, exists (select 1 from incidents i where i.monitor_id = m.id and i.closed_at is null) as open from monitors m left join lateral (select up, at from checks where monitor_id = m.id order by at desc limit 1) c on true order by m.group_name, m.id",
			[],
		)

	## How many subscribers there are.
	subscriber_count! : {} => Try(U64, [DbErr(Str), BadRow(Str)])
	subscriber_count! = |{}| {
		rows : Try(List({ count : U64 }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("select count(*) as count from subscribers", [])
		Ok(rows?.first().map_ok(|row| row.count) ?? 0)
	}

	## Pauses a running monitor, or runs a paused one again (due at once): whether it is paused now.
	toggle_pause! : I64 => Try(Bool, Store.Problem)
	toggle_pause! = |id| {
		rows : Try(List({ paused : Bool }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("update monitors set paused = not paused, next_check_at = now() where id = $1 returning paused", [Int(id)])
		first(rows?).map_ok(|row| row.paused)
	}

	## Adds an update to an open incident, by `author`; a `resolved` one closes it, and queues the
	## alerts that say so (`alert!`, as `record!` does).
	post_update! : I64, Incident.Stage, Str, Str, (I64, [Opened, Closed] => Try({}, [DbErr(Str), BadRow(Str), JobErr(Str)])) => Try({}, [NotFound, DbErr(Str), BadRow(Str), JobErr(Str)])
	post_update! = |id, stage, body, author, alert!|
		Db.transaction!(
			|{}| {
				rows : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
				rows = Db.all!("select id from incidents where id = $1 and closed_at is null for update", [Int(id)])
				_ = first(rows?)?
				_ = Db.run!("insert into incident_updates (incident_id, state, body, author) values ($1, $2, $3, $4)", [Int(id), Text(Incident.stage_name(stage)), Text(body), Text(author)])?
				if stage == Resolved {
					_ = Db.run!("update incidents set closed_at = now() where id = $1", [Int(id)])?
					alert!(id, Closed)?
					Ok({})
				} else {
					Ok({})
				}
			},
		)
}

## The first row, or `NotFound`.
first : List(a) -> Try(a, [NotFound])
first = |rows|
	match rows.first() {
		Ok(row) => Ok(row)
		Err(_) => Err(NotFound)
	}
