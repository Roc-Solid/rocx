## Dates in UTC, from days since the Unix epoch: what cron's schedules and an email's `Date`
## header need. (Howard Hinnant's algorithm, for the proleptic Gregorian calendar.)
Calendar := [].{

	## The year, month (1–12) and day (1–31) of a day counted from 1970-01-01.
	civil : I64 -> { year : I64, month : I64, day : I64 }
	civil = |days| {
		z = days + 719468
		era = (if (z >= 0) z else z - 146096) // 146097
		doe = z - era * 146097
		yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
		doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
		mp = (5 * doy + 2) // 153
		day = doy - (153 * mp + 2) // 5 + 1
		month = if (mp < 10) mp + 3 else mp - 9
		year = yoe + era * 400
		{ year: if (month <= 2) year + 1 else year, month, day }
	}

	## The day of the week, 0 for Sunday to 6 for Saturday (1970-01-01 was a Thursday).
	weekday : I64 -> I64
	weekday = |days| (days % 7 + 11) % 7

	## A moment (milliseconds since the epoch) as email has it: `Fri, 20 Nov 2026 21:54:07 +0000`.
	rfc5322 : I64 -> Str
	rfc5322 = |ms| {
		seconds = ms // 1000
		days = seconds // 86400
		of_day = seconds % 86400
		date = Calendar.civil(days)
		weekday_name = names(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], Calendar.weekday(days))
		month_name = names(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], date.month - 1)
		"${weekday_name}, ${date.day.to_str()} ${month_name} ${date.year.to_str()} ${two(of_day // 3600)}:${two(of_day % 3600 // 60)}:${two(of_day % 60)} +0000"
	}
}

names : List(Str), I64 -> Str
names = |all, index|
	match all.get(index.to_u64_wrap()) {
		Ok(name) => name
		Err(_) => "?"
	}

two : I64 -> Str
two = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

expect Calendar.civil(0) == { year: 1970, month: 1, day: 1 }
expect Calendar.civil(20412) == { year: 2025, month: 11, day: 20 }
expect Calendar.civil(20777) == { year: 2026, month: 11, day: 20 }
expect Calendar.civil(19782) == { year: 2024, month: 2, day: 29 }
expect Calendar.weekday(0) == 4
expect Calendar.weekday(20777) == 5
expect Calendar.rfc5322(1795211647000) == "Fri, 20 Nov 2026 21:54:07 +0000"
