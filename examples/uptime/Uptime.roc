import Days

## The arithmetic of uptime, plain Roc: what share of checks passed, the days of the 90-day strip,
## each monitor's state now and the banner over them all. The server works these out (Status.roc),
## and the status page and its JSON show them.
##
## A monitor's history is in two places: `daily`, a row for each day the nightly job rolled up, and
## `checks`, every check of the last week. A day is counted from its roll-up when it has one, and
## from its checks when it doesn't yet (today, or a night the job didn't run): `combine`.
Uptime := [].{

	## Checks, and how many of them passed.
	Tally : { checks : U64, up : U64 }

	## A day of a monitor's checks: its date (`2026-11-22`, UTC), how many there were, how many
	## passed, and their latencies added up (for the day's average).
	Day : { day : Str, checks : U64, up : U64, latency_ms_sum : U64 }

	## What a day of the strip shows: how its checks went.
	Level : [Good, Minor, Major, NoData]

	## A monitor's state now.
	## - `Operational`: its last check passed.
	## - `Degraded`: its last check failed, but not enough in a row to open an incident.
	## - `Outage`: it has an open incident.
	## - `Paused`: nobody is checking it.
	## - `Pending`: it hasn't been checked yet.
	State : [Operational, Degraded, Outage, Paused, Pending]

	## The share of checks that passed, in hundredths of a percent, rounded down, so that 100% is
	## shown only when none failed: 1999 of 2000 is 9995 (99.95%).
	hundredths : Uptime.Tally -> Try(U64, [NoData])
	hundredths = |{ checks, up }| if (checks == 0) Err(NoData) else Ok(up * 10_000 // checks)

	## The share as a reader reads it: `99.95%`, `100%`, `—` without checks.
	percent : Uptime.Tally -> Str
	percent = |tally|
		match Uptime.hundredths(tally) {
			Ok(10_000) => "100%"
			Ok(share) => {
				cents = share % 100
				"${(share // 100).to_str()}.${if (cents < 10) "0" else ""}${cents.to_str()}%"
			}
			Err(NoData) => "—"
		}

	## The days rolled up, and the days counted from raw checks (grouped by day): a day rolled up is
	## counted from its roll-up alone (its checks may still be kept), any other from its checks.
	combine : List(Uptime.Day), List(Uptime.Day) -> List(Uptime.Day)
	combine = |rolled, raw| {
		fresh = raw.keep_if(|day| !rolled.any(|done| done.day == day.day))
		rolled.concat(fresh)
	}

	## The tally of the days from `since` on (`2026-11-16`: the last seven days, counting today).
	since : List(Uptime.Day), Str -> Uptime.Tally
	since = |days, first|
		days
			.keep_if(|day| ordinal(day.day) >= ordinal(first))
			.fold({ checks: 0, up: 0 }, |total, day| { checks: total.checks + day.checks, up: total.up + day.up })

	## The strip's days: one for each of `labels` (the dates, oldest first), from the days there are.
	strip : List(Uptime.Day), List(Str) -> List({ day : Str, tally : Uptime.Tally })
	strip = |days, labels|
		labels.map(
			|label| {
				tally = days.keep_if(|day| day.day == label).fold({ checks: 0, up: 0 }, |total, day| { checks: total.checks + day.checks, up: total.up + day.up })
				{ day: label, tally }
			},
		)

	## How a day went: `Good` from 99% up, `Minor` from 95%, `Major` below, `NoData` without checks.
	level_of : Uptime.Tally -> Uptime.Level
	level_of = |tally|
		match Uptime.hundredths(tally) {
			Ok(share) => if (share >= 9_900) Good else if (share >= 9_500) Minor else Major
			Err(NoData) => NoData
		}

	## A level as a class name and a word, for the strip.
	level_name : Uptime.Level -> Str
	level_name = |level|
		match level {
			Good => "good"
			Minor => "minor"
			Major => "major"
			NoData => "none"
		}

	## A monitor's state, from whether it is paused, how its last check went and whether it has an
	## open incident.
	state_of : { paused : Bool, last : [Up, Down, Never], open : Bool } -> Uptime.State
	state_of = |{ paused, last, open }|
		if paused {
			Paused
		} else if open {
			Outage
		} else {
			match last {
				Up => Operational
				Down => Degraded
				Never => Pending
			}
		}

	## A state as the class names and the JSON say it.
	state_name : Uptime.State -> Str
	state_name = |state|
		match state {
			Operational => "operational"
			Degraded => "degraded"
			Outage => "outage"
			Paused => "paused"
			Pending => "pending"
		}

	## A state as the page says it.
	state_label : Uptime.State -> Str
	state_label = |state|
		match state {
			Operational => "Operational"
			Degraded => "Degraded"
			Outage => "Outage"
			Paused => "Paused"
			Pending => "Waiting for its first check"
		}

	## The banner over the page, from every monitor's state (paused and pending ones don't count):
	## its level (`operational`, `degraded`, `partial`, `major`), title and a line under it.
	banner : List(Uptime.State) -> { level : Str, title : Str, detail : Str }
	banner = |states| {
		watched = states.keep_if(|each| each != Paused and each != Pending)
		down = watched.count_if(|each| each == Outage)
		degraded = watched.count_if(|each| each == Degraded)
		if watched.is_empty() {
			{ level: "operational", title: "No services watched yet", detail: "Monitors that are paused or waiting for their first check don't count." }
		} else if down > 0 and down == watched.len() {
			{ level: "major", title: "Major outage", detail: "Every service is down. We're on it." }
		} else if down > 0 {
			{ level: "partial", title: "Partial outage", detail: "${count_of(down, "service is", "services are")} down; the rest are operational." }
		} else if degraded > 0 {
			{ level: "degraded", title: "Degraded performance", detail: "${count_of(degraded, "service has", "services have")} failed a check; no incident yet." }
		} else {
			{ level: "operational", title: "All systems operational", detail: "Every service passed its last check." }
		}
	}

	## The average latency of a tally of days, in milliseconds (`0` without checks).
	average_latency : List(Uptime.Day) -> U64
	average_latency = |days| {
		checks = days.fold(0, |total, day| total + day.checks)
		if (checks == 0) 0 else days.fold(0, |total, day| total + day.latency_ms_sum) // checks
	}

	## Values with the gaps filled by the one before (the first gaps by the first value there is), so
	## a line has no holes: an hour without checks keeps the line where it was.
	filled : List([Value(U64), Gap]) -> List(U64)
	filled = |values| {
		first = values.fold(Gap, |found, value| if (found == Gap) value else found)
		start =
			match first {
				Value(n) => n
				Gap => 0
			}
		var $last = start
		var $out = []
		for value in values {
			match value {
				Value(n) => {
					$last = n
				}
				Gap => {}
			}
			$out = $out.append($last)
		}
		$out
	}
}

## A date as a number that sorts as it does: `2026-11-22` is 20261122.
ordinal : Str -> U64
ordinal = |date| U64.from_str(date.replace_each("-", "")) ?? 0

## `1 service is`, `2 services are`.
count_of : U64, Str, Str -> Str
count_of = |count, one, many| if (count == 1) "1 ${one}" else "${count.to_str()} ${many}"

a_day : Str, U64, U64 -> Uptime.Day
a_day = |date, checks, up| { day: date, checks, up, latency_ms_sum: checks * 100 }

expect Uptime.hundredths({ checks: 2000, up: 1999 }) == Ok(9995)
expect Uptime.hundredths({ checks: 0, up: 0 }) == Err(NoData)
expect Uptime.percent({ checks: 2000, up: 1999 }) == "99.95%"
expect Uptime.percent({ checks: 3, up: 3 }) == "100%"
expect Uptime.percent({ checks: 3, up: 2 }) == "66.66%"
expect Uptime.percent({ checks: 100_000, up: 99_999 }) == "99.99%"
expect Uptime.percent({ checks: 1000, up: 905 }) == "90.50%"
expect Uptime.percent({ checks: 1000, up: 0 }) == "0.00%"
expect Uptime.percent({ checks: 0, up: 0 }) == "—"

# Roll-ups: a day rolled up is counted once, from its roll-up; days not rolled up from their checks.
expect {
	rolled = [a_day("2026-11-20", 2880, 2880), a_day("2026-11-21", 2880, 2870)]
	raw = [a_day("2026-11-21", 2880, 2000), a_day("2026-11-22", 100, 99)]
	Uptime.combine(rolled, raw) == [a_day("2026-11-20", 2880, 2880), a_day("2026-11-21", 2880, 2870), a_day("2026-11-22", 100, 99)]
}
expect Uptime.combine([], [a_day("2026-11-22", 10, 9)]) == [a_day("2026-11-22", 10, 9)]
expect Uptime.since([a_day("2026-11-20", 10, 10), a_day("2026-11-21", 10, 5), a_day("2026-11-22", 10, 9)], "2026-11-21") == { checks: 20, up: 14 }
expect Uptime.since([], "2026-11-21") == { checks: 0, up: 0 }
expect Uptime.strip([a_day("2026-11-21", 10, 9)], ["2026-11-20", "2026-11-21"]) == [{ day: "2026-11-20", tally: { checks: 0, up: 0 } }, { day: "2026-11-21", tally: { checks: 10, up: 9 } }]
expect Uptime.average_latency([a_day("2026-11-21", 10, 9), { day: "2026-11-22", checks: 30, up: 30, latency_ms_sum: 6000 }]) == 175
expect Uptime.average_latency([]) == 0

expect Uptime.level_of({ checks: 1000, up: 990 }) == Good
expect Uptime.level_of({ checks: 1000, up: 989 }) == Minor
expect Uptime.level_of({ checks: 1000, up: 950 }) == Minor
expect Uptime.level_of({ checks: 1000, up: 949 }) == Major
expect Uptime.level_of({ checks: 0, up: 0 }) == NoData

expect Uptime.state_of({ paused: Bool.True, last: Down, open: Bool.True }) == Paused
expect Uptime.state_of({ paused: Bool.False, last: Up, open: Bool.True }) == Outage
expect Uptime.state_of({ paused: Bool.False, last: Down, open: Bool.False }) == Degraded
expect Uptime.state_of({ paused: Bool.False, last: Up, open: Bool.False }) == Operational
expect Uptime.state_of({ paused: Bool.False, last: Never, open: Bool.False }) == Pending

expect Uptime.banner([Operational, Operational, Paused]).title == "All systems operational"
expect Uptime.banner([Operational, Degraded]).detail == "1 service has failed a check; no incident yet."
expect Uptime.banner([Outage, Operational, Degraded]) == { level: "partial", title: "Partial outage", detail: "1 service is down; the rest are operational." }
expect Uptime.banner([Outage, Outage, Paused]).level == "major"
expect Uptime.banner([Paused, Pending]).title == "No services watched yet"

expect Uptime.filled([Gap, Value(5), Gap, Value(7), Gap]) == [5, 5, 5, 7, 7]
expect Uptime.filled([Gap, Gap]) == [0, 0]
expect Days.back(20_779, 1) == ["2026-11-22"]
