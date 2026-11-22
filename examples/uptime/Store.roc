import pf.Db
import pf.Endpoint
import pf.Log
import pf.Time
import Incident

## The app in SQLite (D-045): every query it makes, in one place. The tables are
## migrations/0001_uptime.sql. A row comes back as the record its query is annotated with, by column
## name (`Db.all!`); a column that may be null is a `Db.Nullable`. A moment is kept as milliseconds
## since the epoch, now given from here (`Time.now_millis!`), and read as text in UTC (`iso`, SQLite's
## strftime); a day as `2026-11-22` (`day`, SQLite's date). A day, an hour or a slot back from now is
## integer arithmetic on milliseconds. A boolean worked out in a statement (`exists (…)`) is 0 or 1.
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
	## of each. Two sweeps at once can't claim one monitor twice: SQLite's writes take turns. Due
	## again an interval later, less a few seconds, so a monitor every 30 s is checked every 30 s by a
	## sweep every 10 s, not every 40.
	claim_due! : {} => Try(List(I64), [DbErr(Str), BadRow(Str)])
	claim_due! = |{}| {
		rows : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"update monitors set next_check_at = $1 + interval_s * 1000 - 5000 where not paused and next_check_at <= $1 returning id",
			[Int(clock_ms!({}))],
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
				now_ms = clock_ms!({})
				status = if (found.status == 0) Null else Int(found.status.to_i64_wrap())
				_ = Db.run!(
					"insert into checks (monitor_id, at, up, status, latency_ms, error) values ($1, $2, $3, $4, $5, $6)",
					[Int(monitor.id), Int(now_ms), Bool(found.up), status, Int(found.latency_ms.to_i64_wrap()), Text(found.error)],
				)?
				streaks : Try(List({ streak : U64 }), [DbErr(Str), BadRow(Str)])
				streaks = Db.all!("update monitors set streak = case when $2 then 0 else streak + 1 end where id = $1 returning streak", [Int(monitor.id), Bool(found.up)])
				streak = streaks?.first().map_ok(|row| row.streak) ?? 0
				opens : Try(List({ id : I64, minutes : U64 }), [DbErr(Str), BadRow(Str)])
				opens = Db.all!(
					"select id, max(0, ($2 - opened_at) / 60000) as minutes from incidents where monitor_id = $1 and closed_at is null",
					[Int(monitor.id), Int(now_ms)],
				)
				open = opens?.first()
				decision = Incident.decide({ up: found.up, streak, threshold: monitor.threshold, open: open.is_ok() })
				match decision {
					Open => {
						made : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
						made = Db.all!(
							"insert into incidents (monitor_id, title, opened_at) values ($1, $2, $3) on conflict (monitor_id) where closed_at is null do nothing returning id",
							[Int(monitor.id), Text(Incident.title(monitor.name)), Int(now_ms)],
						)
						match made?.first() {
							Ok({ id }) => {
								said = Incident.opened({ name: monitor.name, failures: streak, problem: found.error })
								_ = Db.run!("insert into incident_updates (incident_id, at, state, body) values ($1, $2, 'investigating', $3)", [Int(id), Int(now_ms), Text(said)])?
								alert!(id, Opened)?
								Ok({ decision: Open, incident: id })
							}
							Err(_) => Ok({ decision: Keep, incident: 0 })
						}
					}
					Close => {
						closed : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
						closed = Db.all!("update incidents set closed_at = $2 where monitor_id = $1 and closed_at is null returning id", [Int(monitor.id), Int(now_ms)])
						match closed?.first() {
							Ok({ id }) => {
								minutes = open.map_ok(|row| row.minutes) ?? 0
								said = Incident.closed({ name: monitor.name, minutes, status: found.status, latency_ms: found.latency_ms })
								_ = Db.run!("insert into incident_updates (incident_id, at, state, body) values ($1, $2, 'resolved', $3)", [Int(id), Int(now_ms), Text(said)])?
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
				now_ms = clock_ms!({})
				# Today began at midnight UTC: a whole number of days since the epoch.
				today_ms = now_ms // day_ms * day_ms
				days = Db.run!(
					"insert into daily (monitor_id, day, checks, up, latency_ms_sum) select monitor_id, ${day("at")}, count(*), count(*) filter (where up), sum(latency_ms) from checks where at < $1 group by 1, 2 on conflict (monitor_id, day) do nothing",
					[Int(today_ms)],
				)?
				deleted = Db.run!(
					"delete from checks where at < $1 and exists (select 1 from daily d where d.monitor_id = checks.monitor_id and d.day = ${day("checks.at")})",
					[Int(now_ms - 7 * day_ms)],
				)?
				Ok({ days, deleted })
			},
		)

	# ---- The status page ----

	## The days since the epoch today (UTC), and the moment now.
	now! : {} => Try({ today : U64, now : Str }, [DbErr(Str), BadRow(Str)])
	now! = |{}| {
		rows : Try(List({ today : U64, now : Str }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!("select $1 / ${day_ms.to_str()} as today, ${iso("$1")} as now", [Int(clock_ms!({}))])
		Ok(rows?.first() ?? { today: 0, now: "" })
	}

	## Every monitor, by group and then as they were added, with its last check and whether it has
	## an open incident.
	rows! : {} => Try(List(Store.Row), [DbErr(Str), BadRow(Str)])
	rows! = |{}| {
		rows : Try(List({ id : I64, name : Str, group_name : Str, paused : Bool, last_up : Db.Nullable(Bool), last_at : Str, last_latency_ms : U64, open : I64 }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"select m.id, m.name, m.group_name, m.paused, c.up as last_up, coalesce(${iso("c.at")}, '') as last_at, coalesce(c.latency_ms, 0) as last_latency_ms, exists (select 1 from incidents i where i.monitor_id = m.id and i.closed_at is null) as open from monitors m left join checks c on ${last_check} order by (select min(id) from monitors g where g.group_name = m.group_name), m.id",
			[],
		)
		Ok(rows?.map(|row| { id: row.id, name: row.name, group_name: row.group_name, paused: row.paused, last_up: row.last_up, last_at: row.last_at, last_latency_ms: row.last_latency_ms, open: row.open != 0 }))
	}

	## Each monitor's checks in the last 24 hours, and how many passed.
	last_day! : {} => Try(List({ monitor : I64, checks : U64, up : U64 }), [DbErr(Str), BadRow(Str)])
	last_day! = |{}| Db.all!("select monitor_id as monitor, count(*) as checks, count(*) filter (where up) as up from checks where at > $1 group by 1", [Int(clock_ms!({}) - day_ms)])

	## Each monitor's last 90 days: the days rolled up, and the days counted from the checks kept
	## (`Uptime.combine` puts them together).
	days! : {} => Try({ rolled : List(Store.DayRow), raw : List(Store.DayRow) }, [DbErr(Str), BadRow(Str)])
	days! = |{}| {
		now_ms = clock_ms!({})
		rolled : Try(List(Store.DayRow), [DbErr(Str), BadRow(Str)])
		rolled = Db.all!("select monitor_id as monitor, day, checks, up, latency_ms_sum from daily where day > ${day("$1")}", [Int(now_ms - 90 * day_ms)])
		raw : Try(List(Store.DayRow), [DbErr(Str), BadRow(Str)])
		raw = Db.all!(
			"select monitor_id as monitor, ${day("at")} as day, count(*) as checks, count(*) filter (where up) as up, sum(latency_ms) as latency_ms_sum from checks where at > $1 group by 1, 2",
			[Int(now_ms - 90 * day_ms)],
		)
		Ok({ rolled: rolled?, raw: raw? })
	}

	## Each monitor's average latency of the checks that passed, an hour at a time over the last
	## 24 (`hours_ago` 0 is the last hour).
	hourly! : {} => Try(List({ monitor : I64, hours_ago : U64, latency_ms : U64 }), [DbErr(Str), BadRow(Str)])
	hourly! = |{}|
		Db.all!(
			"select monitor_id as monitor, max(0, ($1 - at) / 3600000) as hours_ago, cast(round(avg(latency_ms)) as integer) as latency_ms from checks where at > $1 - ${day_ms.to_str()} and up group by 1, 2",
			[Int(clock_ms!({}))],
		)

	## The incidents open now and those closed in the last 14 days, newest first, with their
	## updates, newest first; or one monitor's of the last 90 days (`monitor` not 0).
	incidents! : I64 => Try({ incidents : List(Store.IncidentRow), updates : List(Store.UpdateRow) }, [DbErr(Str), BadRow(Str)])
	incidents! = |monitor| {
		now_ms = clock_ms!({})
		which = "(i.closed_at is null or i.closed_at > $2 - ${(14 * day_ms).to_str()}) and $1 = 0 or i.monitor_id = $1 and i.opened_at > $2 - ${(90 * day_ms).to_str()}"
		incidents : Try(List(Store.IncidentRow), [DbErr(Str), BadRow(Str)])
		incidents = Db.all!("${incident_columns} where ${which} order by i.opened_at desc limit 20", [Int(monitor), Int(now_ms)])
		updates : Try(List(Store.UpdateRow), [DbErr(Str), BadRow(Str)])
		updates = Db.all!(
			"select u.incident_id as incident, ${iso("u.at")} as at, u.state, u.body, u.author from incident_updates u join incidents i on i.id = u.incident_id where ${which} order by u.at desc, u.id desc",
			[Int(monitor), Int(now_ms)],
		)
		Ok({ incidents: incidents?, updates: updates? })
	}

	## One incident, with its updates, newest first.
	incident! : I64 => Try({ incident : Store.IncidentRow, updates : List(Store.UpdateRow) }, Store.Problem)
	incident! = |id| {
		incidents : Try(List(Store.IncidentRow), [DbErr(Str), BadRow(Str)])
		incidents = Db.all!("${incident_columns} where i.id = $1", [Int(id), Int(clock_ms!({}))])
		incident = first(incidents?)?
		updates : Try(List(Store.UpdateRow), [DbErr(Str), BadRow(Str)])
		updates = Db.all!("select incident_id as incident, ${iso("at")} as at, state, body, author from incident_updates where incident_id = $1 order by incident_updates.at desc, id desc", [Int(id)])
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
			"select max(0, ($2 - at) / 1800000) as slot, cast(round(avg(latency_ms)) as integer) as latency_ms from checks where monitor_id = $1 and at > $2 - ${day_ms.to_str()} and up group by 1",
			[Int(id), Int(clock_ms!({}))],
		)

	## A monitor's failed checks over the last 7 days, by day (`days_ago` 0 is today) and hour (UTC).
	failures! : I64 => Try(List({ days_ago : U64, hour : U64, failed : U64 }), [DbErr(Str), BadRow(Str)])
	failures! = |id|
		Db.all!(
			"select max(0, $2 / ${day_ms.to_str()} - at / ${day_ms.to_str()}) as days_ago, at / 3600000 % 24 as hour, count(*) as failed from checks where monitor_id = $1 and not up and at / ${day_ms.to_str()} > $2 / ${day_ms.to_str()} - 7 group by 1, 2",
			[Int(id), Int(clock_ms!({}))],
		)

	## A monitor's last 20 checks, the newest first.
	recent! : I64 => Try(List(Store.CheckRow), [DbErr(Str), BadRow(Str)])
	recent! = |id| Db.all!("select ${iso("at")} as at, up, status, latency_ms, error from checks where monitor_id = $1 order by checks.at desc, id desc limit 20", [Int(id)])

	# ---- Subscribers ----

	## Subscribes `email` (once, whatever its case): whether it is new.
	subscribe! : Str => Try(Bool, [DbErr(Str)])
	subscribe! = |email| {
		added = Db.run!("insert into subscribers (email) values ($1) on conflict (lower(email)) do nothing", [Text(email)])?
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
	admin_rows! = |{}| {
		rows : Try(List({ id : I64, name : Str, url : Str, method : Str, interval_s : U64, paused : Bool, streak : U64, last_up : Db.Nullable(Bool), last_at : Str, open : I64 }), [DbErr(Str), BadRow(Str)])
		rows = Db.all!(
			"select m.id, m.name, m.url, m.method, m.interval_s, m.paused, m.streak, c.up as last_up, coalesce(${iso("c.at")}, '') as last_at, exists (select 1 from incidents i where i.monitor_id = m.id and i.closed_at is null) as open from monitors m left join checks c on ${last_check} order by m.group_name, m.id",
			[],
		)
		Ok(rows?.map(|row| { id: row.id, name: row.name, url: row.url, method: row.method, interval_s: row.interval_s, paused: row.paused, streak: row.streak, last_up: row.last_up, last_at: row.last_at, open: row.open != 0 }))
	}

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
		rows = Db.all!("update monitors set paused = not paused, next_check_at = $2 where id = $1 returning paused", [Int(id), Int(clock_ms!({}))])
		first(rows?).map_ok(|row| row.paused)
	}

	## Adds an update to an open incident, by `author`; a `resolved` one closes it, and queues the
	## alerts that say so (`alert!`, as `record!` does). The transaction holds SQLite's write lock
	## from its start, so the incident read open stays open until it ends.
	post_update! : I64, Incident.Stage, Str, Str, (I64, [Opened, Closed] => Try({}, [DbErr(Str), BadRow(Str), JobErr(Str)])) => Try({}, [NotFound, DbErr(Str), BadRow(Str), JobErr(Str)])
	post_update! = |id, stage, body, author, alert!|
		Db.transaction!(
			|{}| {
				now_ms = clock_ms!({})
				rows : Try(List({ id : I64 }), [DbErr(Str), BadRow(Str)])
				rows = Db.all!("select id from incidents where id = $1 and closed_at is null", [Int(id)])
				_ = first(rows?)?
				_ = Db.run!("insert into incident_updates (incident_id, at, state, body, author) values ($1, $2, $3, $4, $5)", [Int(id), Int(now_ms), Text(Incident.stage_name(stage)), Text(body), Text(author)])?
				if stage == Resolved {
					_ = Db.run!("update incidents set closed_at = $2 where id = $1", [Int(id), Int(now_ms)])?
					alert!(id, Closed)?
					Ok({})
				} else {
					Ok({})
				}
			},
		)
}

## Now, in milliseconds since the epoch: what a moment is in the tables.
clock_ms! : {} => I64
clock_ms! = |{}| Time.now_millis!({}).to_i64_wrap()

## A day in milliseconds.
day_ms : I64
day_ms = 86_400_000

## The SQL for moment `at` (milliseconds) as ISO 8601 in UTC, `2026-11-22T14:05:09Z`; null for null.
iso : Str -> Str
iso = |at| "strftime('%Y-%m-%dT%H:%M:%SZ', ${at} / 1000, 'unixepoch')"

## The SQL for the day of moment `at` (milliseconds) in UTC, `2026-11-22`.
day : Str -> Str
day = |at| "date(${at} / 1000, 'unixepoch')"

## The join of a monitor `m` to its last check `c` (SQLite has no lateral join): the newest of its
## checks, by `checks_by_monitor`.
last_check : Str
last_check = "c.id = (select id from checks where monitor_id = m.id order by at desc, id desc limit 1)"

## An incident `i` with its monitor's name and how many minutes it lasted, or has lasted until
## now (`$2`), for a `where`.
incident_columns : Str
incident_columns = "select i.id, i.monitor_id as monitor, m.name as monitor_name, i.title, ${iso("i.opened_at")} as opened_at, ${iso("i.closed_at")} as closed_at, max(0, (coalesce(i.closed_at, $2) - i.opened_at) / 60000) as minutes from incidents i join monitors m on m.id = i.monitor_id"

expect iso("at") == "strftime('%Y-%m-%dT%H:%M:%SZ', at / 1000, 'unixepoch')"

## The first row, or `NotFound`.
first : List(a) -> Try(a, [NotFound])
first = |rows|
	match rows.first() {
		Ok(row) => Ok(row)
		Err(_) => Err(NotFound)
	}
