import pf.Db
import pf.Time
import Calendar
import Registry

## Jobs on a schedule: the jobs plugin's `crons` (`Job.plugin({ jobs: App.jobs, crons: [Cron.every(…)] })`).
## The server queues one each time its schedule comes round, once, even after a restart
## (`CronTicker`); a worker runs it like any other (`Job`).
##
## A schedule is cron's: five fields, `minute hour day month weekday` (`0 3 * * *`: 03:00 every
## day), or six, beginning with seconds (`*/10 * * * * *`: every ten seconds). Times are UTC. A field
## is `*`, a number, a range (`1-5`), a step (`*/15`, `0-30/10`), or a list of them (`1,15,30`);
## months may be named (`JAN`), and weekdays (`MON`; 0 and 7 are Sunday). When both the day and the
## weekday are given, either one matching is enough, as in Unix cron.
Cron := [].{

	## A job of `kind` (`Job.define`), with `input`, on `schedule`.
	every : Str, { name : Str, attempts : U64, timeout_ms : U64, run! : input => Try({}, Str) }, input -> { name : Str, schedule : Str, job : Str, input : Str }
		where [input.Json.Encodable([])]
	every = |schedule, kind, input| { name: "${kind.name} ${schedule}", schedule, job: kind.name, input: Json.to_str(input) }

	## A schedule, read: the values each field allows.
	Schedule : {
		seconds : List(I64),
		minutes : List(I64),
		hours : List(I64),
		days : List(I64),
		months : List(I64),
		weekdays : List(I64),
		any_day : Bool,
		any_weekday : Bool,
	}

	## Reads a schedule, or says what is wrong with it.
	parse : Str -> Try(Schedule, Str)
	parse = |text| {
		fields = text.trim().split_on(" ").keep_if(|field| !field.is_empty())
		match fields {
			[minute, hour, day, month, weekday] => schedule_of("0", minute, hour, day, month, weekday)
			[second, minute, hour, day, month, weekday] => schedule_of(second, minute, hour, day, month, weekday)
			_ => Err("cron has five fields (minute hour day month weekday), or six beginning with seconds; this has ${fields.len().to_str()}")
		}
	}

	## Whether every schedule of `crons` can be read, and names a job of `kinds` (the plugin's: one
	## it doesn't run would be queued and never run): the first that doesn't, and why.
	check : List({ name : Str, schedule : Str, job : Str, input : Str }), List(Str) -> Try({}, Str)
	check = |crons, kinds|
		crons.fold(
			Ok({}),
			|checked, cron|
				match (checked, Cron.parse(cron.schedule)) {
					(Err(why), _) => Err(why)
					(Ok({}), Err(why)) => Err("cron `${cron.schedule}` (${cron.name}): ${why}")
					(Ok({}), Ok(_)) =>
						if kinds.contains(cron.job) {
							Ok({})
						} else {
							Err("cron ${cron.name}: no job is called ${cron.job}: list it in the jobs plugin's `jobs`")
						}
				},
		)

	## The plugin's schedules, each with the next time it comes round (milliseconds since the epoch;
	## `Null` if never: the 30th of February).
	schedules! : {} => List({ name : Str, schedule : Str, job : Str, next_at : [Null, Some(I64)] })
	schedules! = |{}| {
		now = Time.now_millis!({}).to_i64_wrap()
		Registry.schedules!({}).map(
			|each| {
				next_at =
					match Cron.parse(each.schedule) {
						Ok(parsed) =>
							match Cron.after(parsed, now) {
								Ok(at) => Some(at)
								Err(Never) => Null
							}
						Err(_) => Null
					}
				{ name: each.name, schedule: each.schedule, job: each.job, next_at }
			},
		)
	}

	## Queues the job of the schedule called `name` now, besides its own times (tried as many times
	## as its kind says).
	run_now! : Str => Try({}, [NotFound, JobErr(Str), ..others])
	run_now! = |name|
		match Registry.schedules!({}).find_first(|each| each.name == name) {
			Err(_) => Err(NotFound)
			Ok(found) => {
				queued = Db.run!(
					"with queued as (insert into rocx_jobs (kind, input, max_attempts) values ($1, $2, $3::int) returning id) select pg_notify('rocx_jobs', id::text) from queued",
					[Text(found.job), Text(found.input), Int(Registry.attempts!(found.job).to_i64_wrap())],
				)
				match queued {
					Ok(_) => Ok({})
					Err(DbErr(why)) => Err(JobErr(why))
				}
			}
		}

	## The first moment after `ms` (milliseconds since the epoch) the schedule comes round, in
	## milliseconds; or `Err(Never)` if it doesn't within eight years (the 30th of February).
	after : Schedule, I64 -> Try(I64, [Never])
	after = |schedule, ms| {
		start = ms // 1000 + 1
		var $day = start // 86400
		var $from = start % 86400
		var $found = Err(Never)
		var $tries = 0
		while $tries < 2922 and $found == Err(Never) {
			date = Calendar.civil($day)
			if schedule.months.contains(date.month) and day_matches(schedule, date.day, Calendar.weekday($day)) {
				$found =
					match time_of_day(schedule, $from) {
						Ok(seconds) => Ok(($day * 86400 + seconds) * 1000)
						Err(_) => Err(Never)
					}
			} else {
				{}
			}
			$day = $day + 1
			$from = 0
			$tries = $tries + 1
		}
		$found
	}
}

schedule_of : Str, Str, Str, Str, Str, Str -> Try(Cron.Schedule, Str)
schedule_of = |second, minute, hour, day, month, weekday| {
	seconds = field("seconds", second, 0, 59, [])?
	minutes = field("minutes", minute, 0, 59, [])?
	hours = field("hours", hour, 0, 23, [])?
	days = field("day", day, 1, 31, [])?
	months = field("month", month, 1, 12, ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"])?
	weekdays = field("weekday", weekday, 0, 7, ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"])?
	Ok({
		seconds,
		minutes,
		hours,
		days,
		months,
		# 7 is Sunday too.
		weekdays: if (weekdays.contains(7) and !weekdays.contains(0)) weekdays.drop_last(1).prepend(0) else weekdays.drop_if(|each| each == 7),
		any_day: is_any(day),
		any_weekday: is_any(weekday),
	})
}

is_any : Str -> Bool
is_any = |text| text == "*" or text == "?"

## The values a field allows, in order: each part of a list (`a,b`), a range or a value, stepped.
## `names` stand for numbers from `min` (`JAN` is 1, `SUN` 0).
field : Str, Str, I64, I64, List(Str) -> Try(List(I64), Str)
field = |what, text, min, max, names| {
	parts = text.split_on(",")
	allowed = parts.fold(
		Ok([]),
		|so_far, part|
			match (so_far, part_values(part, min, max, names)) {
				(Err(why), _) => Err(why)
				(Ok(values), Ok(more)) => Ok(values.concat(more))
				(Ok(_), Err(why)) => Err(why)
			},
	)
	match allowed {
		Ok(values) =>
			if values.is_empty() {
				Err("${what}: nothing in `${text}`")
			} else {
				Ok(in_order(values, min, max))
			}
		Err(why) => Err("${what}: ${why}")
	}
}

## Each value once, smallest first.
in_order : List(I64), I64, I64 -> List(I64)
in_order = |values, min, max| {
	var $sorted = []
	var $at = min
	while $at <= max {
		if values.contains($at) {
			$sorted = $sorted.append($at)
		} else {
			{}
		}
		$at = $at + 1
	}
	$sorted
}

part_values : Str, I64, I64, List(Str) -> Try(List(I64), Str)
part_values = |part, min, max, names| {
	(range, step) =
		match part.split_first("/") {
			Ok({ before, after }) => (before, number(after, 0, [])?)
			Err(_) => (part, 1)
		}
	if step < 1 {
		Err("a step of `${part}` is at least 1")
	} else {
		(low, high) =
			if is_any(range) {
				(min, max)
			} else {
				match range.split_first("-") {
					Ok({ before, after }) => (number(before, min, names)?, number(after, min, names)?)
					Err(_) => {
						value = number(range, min, names)?
						# `5/10`: from 5, every 10.
						(value, if (part.contains("/")) max else value)
					}
				}
			}
		if low < min or high > max or low > high {
			Err("`${part}` isn't within ${min.to_str()}-${max.to_str()}")
		} else {
			var $values = []
			var $at = low
			while $at <= high {
				$values = $values.append($at)
				$at = $at + step
			}
			Ok($values)
		}
	}
}

## A number, or one of `names` (counted from `min`).
number : Str, I64, List(Str) -> Try(I64, Str)
number = |text, min, names|
	match I64.from_str(text) {
		Ok(value) => Ok(value)
		Err(_) =>
			match names.find_first_index(|name| name == text.with_ascii_uppercased()) {
				Ok(index) => Ok(min + index.to_i64_wrap())
				Err(_) => Err("`${text}` isn't a number")
			}
	}

day_matches : Cron.Schedule, I64, I64 -> Bool
day_matches = |schedule, day, weekday|
	if schedule.any_day and schedule.any_weekday {
		Bool.True
	} else if schedule.any_day {
		schedule.weekdays.contains(weekday)
	} else if schedule.any_weekday {
		schedule.days.contains(day)
	} else {
		schedule.days.contains(day) or schedule.weekdays.contains(weekday)
	}

## The first second of the day, at `from` or after, the schedule allows.
time_of_day : Cron.Schedule, I64 -> Try(I64, [None])
time_of_day = |schedule, from| {
	var $found = Err(None)
	for hour in schedule.hours {
		if $found == Err(None) and hour * 3600 + 3599 >= from {
			for minute in schedule.minutes {
				if $found == Err(None) and hour * 3600 + minute * 60 + 59 >= from {
					for second in schedule.seconds {
						at = hour * 3600 + minute * 60 + second
						if $found == Err(None) and at >= from {
							$found = Ok(at)
						} else {
							{}
						}
					}
				} else {
					{}
				}
			}
		} else {
			{}
		}
	}
	$found
}

## 2026-11-20 21:54:07 UTC, a Friday.
friday : I64
friday = 1795211647000

next : Str, I64 -> I64
next = |text, ms|
	match Cron.parse(text) {
		Ok(schedule) =>
			match Cron.after(schedule, ms) {
				Ok(at) => at
				Err(Never) => -1
			}
		Err(_) => -2
	}

# 03:00 every day: the next morning.
expect next("0 3 * * *", friday) == 1795230000000
# Every second: the next whole one.
expect next("* * * * * *", friday) == friday + 1000
expect next("*/10 * * * * *", friday) == 1795211650000
# Mondays at 09:00: 2026-11-23.
expect next("0 9 * * MON", friday) == 1795424400000
expect next("0 9 * * 1", friday) == next("0 9 * * mon", friday)
# Sunday as 0 or 7.
expect next("0 0 * * 0", friday) == next("0 0 * * 7", friday)
# New year.
expect next("0 0 1 JAN *", friday) == 1798761600000
# The 30th of February never comes.
expect next("0 0 30 2 *", friday) == -1
expect Cron.parse("0 3 * *").is_err()
expect Cron.parse("61 * * * *").is_err()
expect Cron.parse("*/0 * * * *").is_err()
expect Cron.parse("5-1 * * * *").is_err()
expect Cron.check([{ name: "x", schedule: "* * * * *", job: "x", input: "{}" }], ["x"]) == Ok({})
expect Cron.check([{ name: "nightly", schedule: "0 3 * * *", job: "tidy", input: "{}" }], ["x"]) == Err("cron nightly: no job is called tidy: list it in the jobs plugin's `jobs`")
expect Cron.check([{ name: "x", schedule: "nope", job: "x", input: "{}" }], ["x"]) == Err("cron `nope` (x): cron has five fields (minute hour day month weekday), or six beginning with seconds; this has 1")
