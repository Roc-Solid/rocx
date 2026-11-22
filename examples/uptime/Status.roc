import pf.Db
import pf.Kv
import Days
import Incident
import Report
import Store
import Uptime

## What the pages read, worked out on the server from Store's queries with Uptime's arithmetic:
## the status page (`overview!`), a monitor's page (`detail!`), an incident's (`incident!`) and the
## admin's (`admin!`). The route files answer with them, as JSON or as the page.
Status := [].{

	## The status page.
	overview! : {} => Try(Report.Overview, Store.Problem)
	overview! = |{}| {
		clock = Store.now!({})?
		rows = Store.rows!({})?
		tallies = Store.last_day!({})?
		days = Store.days!({})?
		hourly = Store.hourly!({})?
		found = Store.incidents!(0)?
		labels = Days.back(clock.today, 90)
		monitors = rows.map(|row| { row, monitor: summary(row, { labels, tallies, days, hourly }) })
		groups = rows.fold(
			[],
			|names, row| if (names.contains(row.group_name)) names else names.append(row.group_name),
		)
		Ok({
			banner: Uptime.banner(rows.map(state_of)),
			now: clock.now,
			groups: groups.map(|name| { name, monitors: monitors.keep_if(|each| each.row.group_name == name).map(|each| each.monitor) }),
			incidents: reports(found.incidents, found.updates),
		})
	}

	## A monitor's page: 404 for one that isn't there.
	detail! : I64 => Try(Report.Detail, Store.Problem)
	detail! = |id| {
		about = Store.about!(id)?
		overview = Status.overview!({})?
		monitor = overview.groups.join_map(|group| group.monitors).find_first(|each| each.id == id) ?? missing(about.name)
		clock = Store.now!({})?
		latency = Store.latency!(id)?
		failed = Store.failures!(id)?
		recent = Store.recent!(id)?
		found = Store.incidents!(id)?
		slots = List.repeat(0, 48).map_with_index(|_, index| 47 - index)
		week = Days.back(clock.today, 7)
		Ok({
			monitor,
			group_name: about.group_name,
			interval_s: about.interval_s,
			expected_status: about.expected_status,
			threshold: about.threshold,
			latency: Uptime.filled(slots.map(|slot| latency.find_first(|row| row.slot == slot).map_ok(|row| Value(row.latency_ms)) ?? Gap)),
			week: week.map(Days.label),
			failures: List.repeat(0, 7).map_with_index(
				|_, row|
					List.repeat(0, 24).map_with_index(
						|_, hour|
							failed.find_first(|each| each.days_ago == 6 - row and each.hour == hour).map_ok(|each| each.failed) ?? 0,
					),
			),
			checks: recent.map(
				|check| {
					status =
						match check.status {
							Some(code) => code
							Null => 0
						}
					{ at: check.at, up: check.up, status, latency_ms: check.latency_ms, error: check.error }
				},
			),
			incidents: reports(found.incidents, found.updates),
		})
	}

	## An incident's page: 404 for one that isn't there.
	incident! : I64 => Try(Report.Incident, Store.Problem)
	incident! = |id| {
		found = Store.incident!(id)?
		Ok(report(found.incident, found.updates))
	}

	## The admin's page.
	admin! : {} => Try(Report.Admin, Store.Problem)
	admin! = |{}| {
		rows = Store.admin_rows!({})?
		found = Store.incidents!(0)?
		subscribers = Store.subscriber_count!({})?
		broken : Try(Bool, [NotFound, BadValue(Str)])
		broken = Kv.get!(Status.broken_key)
		Ok({
			monitors: rows.map(
				|row| {
					state = Uptime.state_of({ paused: row.paused, last: last_of(row.last_up), open: row.open })
					{ id: row.id, name: row.name, url: row.url, method: row.method, interval_s: row.interval_s, paused: row.paused, streak: row.streak, state: Uptime.state_name(state), label: Uptime.state_label(state), last_at: row.last_at }
				},
			),
			incidents: reports(found.incidents, found.updates).keep_if(|each| each.open),
			subscribers,
			broken: broken ?? Bool.False,
		})
	}

	## Where the flaky demo's "broken on purpose" switch is kept (`Kv`, so a restart mends it).
	broken_key : Str
	broken_key = "uptime:demo:broken"
}

## What `summary` reads besides the monitor's own row.
Read : { labels : List(Str), tallies : List({ monitor : I64, checks : U64, up : U64 }), days : { rolled : List(Store.DayRow), raw : List(Store.DayRow) }, hourly : List({ monitor : I64, hours_ago : U64, latency_ms : U64 }) }

## A monitor as the status page shows it.
summary : Store.Row, Read -> Report.Monitor
summary = |row, { labels, tallies, days, hourly }| {
	mine = |rows| rows.keep_if(|each| each.monitor == row.id).map(|each| { day: each.day, checks: each.checks, up: each.up, latency_ms_sum: each.latency_ms_sum })
	combined = Uptime.combine(mine(days.rolled), mine(days.raw))
	last_day = tallies.find_first(|each| each.monitor == row.id).map_ok(|each| { checks: each.checks, up: each.up }) ?? { checks: 0, up: 0 }
	week_from = labels.get(labels.len() - 7) ?? ""
	state = state_of(row)
	hours = List.repeat(0, 24).map_with_index(|_, index| 23 - index)
	{
		id: row.id,
		name: row.name,
		state: Uptime.state_name(state),
		label: Uptime.state_label(state),
		uptime_24h: Uptime.percent(last_day),
		uptime_7d: Uptime.percent(Uptime.since(combined, week_from)),
		uptime_90d: Uptime.percent(Uptime.since(combined, labels.first() ?? "")),
		last_at: row.last_at,
		latency_ms: row.last_latency_ms,
		trend: Uptime.filled(hours.map(|ago| hourly.find_first(|each| each.monitor == row.id and each.hours_ago == ago).map_ok(|each| Value(each.latency_ms)) ?? Gap)),
		days: Uptime.strip(combined, labels).map(|day| { day: day.day, level: Uptime.level_name(Uptime.level_of(day.tally)), uptime: Uptime.percent(day.tally) }),
	}
}

## A monitor's state now, from its row.
state_of : Store.Row -> Uptime.State
state_of = |row| Uptime.state_of({ paused: row.paused, last: last_of(row.last_up), open: row.open })

## How its last check went.
last_of : Db.Nullable(Bool) -> [Up, Down, Never]
last_of = |last|
	match last {
		Some(up) => if (up) Up else Down
		Null => Never
	}

## Incidents with their updates.
reports : List(Store.IncidentRow), List(Store.UpdateRow) -> List(Report.Incident)
reports = |incidents, updates| incidents.map(|incident| report(incident, updates.keep_if(|update| update.incident == incident.id)))

## An incident with its updates.
report : Store.IncidentRow, List(Store.UpdateRow) -> Report.Incident
report = |incident, updates| {
	closed_at =
		match incident.closed_at {
			Some(at) => at
			Null => ""
		}
	{
		id: incident.id,
		monitor: incident.monitor,
		monitor_name: incident.monitor_name,
		title: incident.title,
		open: closed_at.is_empty(),
		opened_at: incident.opened_at,
		closed_at,
		duration: Days.minutes(U64.max(incident.minutes, 1)),
		updates: updates.map(|update| { at: update.at, state: update.state, label: Incident.label_of(update.state), body: update.body, author: update.author }),
	}
}

## A monitor the status page didn't list (it can't happen: they are read one after the other).
missing : Str -> Report.Monitor
missing = |name| { id: 0, name, state: "pending", label: Uptime.state_label(Pending), uptime_24h: "—", uptime_7d: "—", uptime_90d: "—", last_at: "", latency_ms: 0, trend: [], days: [] }
