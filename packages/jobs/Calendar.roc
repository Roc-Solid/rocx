## Dates in UTC, from days since the Unix epoch: what cron's schedules need, and the jobs page's
## times. (Howard Hinnant's algorithm, for the proleptic Gregorian calendar.)
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
}

expect Calendar.civil(0) == { year: 1970, month: 1, day: 1 }
expect Calendar.civil(20412) == { year: 2025, month: 11, day: 20 }
expect Calendar.civil(20777) == { year: 2026, month: 11, day: 20 }
expect Calendar.civil(19782) == { year: 2024, month: 2, day: 29 }
expect Calendar.weekday(0) == 4
expect Calendar.weekday(20777) == 5
