## A day on the calendar: a year, a month (1–12) and a day (1–31), in the proleptic Gregorian
## calendar, with no time and no zone (a birthday, a due date). Days count from 1970-01-01 (Howard
## Hinnant's algorithms), so a moment's day in UTC is `Date.of_millis(ms, 0)`. Plain Roc: the same
## on the server and in the browser.
Date := { year : I64, month : I64, day : I64 }.{

	## The day `year`-`month`-`day`. Out-of-range days roll over, as the arithmetic does:
	## `Date.ymd(2026, 2, 30)` is March 2nd.
	ymd : I64, I64, I64 -> Date
	ymd = |year, month, day| Date.from_days(Date.to_days({ year, month: 1, day: 1 }) + days_before_month(year, month) + day - 1)

	## The day `days` after 1970-01-01 (before it, when negative).
	from_days : I64 -> Date
	from_days = |days| {
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

	## How many days the date is after 1970-01-01.
	to_days : Date -> I64
	to_days = |date| {
		year = if (date.month <= 2) date.year - 1 else date.year
		era = (if (year >= 0) year else year - 399) // 400
		yoe = year - era * 400
		shifted = if (date.month > 2) date.month - 3 else date.month + 9
		doy = (153 * shifted + 2) // 5 + date.day - 1
		doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
		era * 146097 + doe - 719468
	}

	## The day a moment (milliseconds since the epoch) falls on in UTC, or `offset_minutes` east of
	## it (60 for Central European winter time, -300 for New York's).
	of_millis : I64, I64 -> Date
	of_millis = |ms, offset_minutes| Date.from_days(floor_div(ms + offset_minutes * 60000, 86400000))

	## The day of the week: 0 for Sunday to 6 for Saturday.
	weekday : Date -> I64
	weekday = |date| (Date.to_days(date) % 7 + 11) % 7

	## `count` days later (earlier when negative).
	add_days : Date, I64 -> Date
	add_days = |date, count| Date.from_days(Date.to_days(date) + count)

	## `count` months later (earlier when negative), the day kept within the month: January 31st and
	## one month is February 28th (29th in a leap year).
	add_months : Date, I64 -> Date
	add_months = |date, count| {
		index = date.year * 12 + date.month - 1 + count
		year = floor_div(index, 12)
		month = index - year * 12 + 1
		{ year, month, day: I64.min(date.day, Date.days_in_month(year, month)) }
	}

	## How many days from `from` to `to`: negative when `to` is earlier.
	days_between : Date, Date -> I64
	days_between = |from, to| Date.to_days(to) - Date.to_days(from)

	## How many days the month has.
	days_in_month : I64, I64 -> I64
	days_in_month = |year, month|
		if month == 2 {
			if (Date.is_leap_year(year)) 29 else 28
		} else if month == 4 or month == 6 or month == 9 or month == 11 {
			30
		} else {
			31
		}

	is_leap_year : I64 -> Bool
	is_leap_year = |year| (year % 4 == 0 and year % 100 != 0) or year % 400 == 0

	## A date written as ISO 8601 does, `2026-11-21` (as an `<input type="date">` sends it).
	parse_iso : Str -> Try(Date, [BadDate(Str)])
	parse_iso = |text|
		match text.trim().split_on("-") {
			[y, m, d] if y.count_utf8_bytes() >= 4 and m.count_utf8_bytes() == 2 and d.count_utf8_bytes() == 2 =>
				match (I64.from_str(y), I64.from_str(m), I64.from_str(d)) {
					(Ok(year), Ok(month), Ok(day)) if month >= 1 and month <= 12 and day >= 1 and day <= Date.days_in_month(year, month) => Ok({ year, month, day })
					_ => Err(BadDate(text))
				}
			_ => Err(BadDate(text))
		}

	## As ISO 8601 writes it: `2026-11-21`.
	to_iso : Date -> Str
	to_iso = |date| "${pad(date.year, 4)}-${pad(date.month, 2)}-${pad(date.day, 2)}"

	is_eq : Date, Date -> Bool
	is_eq = |a, b| a.year == b.year and a.month == b.month and a.day == b.day
}

## Division rounding down, for moments before the epoch.
floor_div : I64, I64 -> I64
floor_div = |a, b| {
	q = a // b
	if (a % b != 0 and (a < 0) != (b < 0)) q - 1 else q
}

days_before_month : I64, I64 -> I64
days_before_month = |year, month| {
	var $total = 0
	var $m = 1
	while $m < month {
		$total = $total + Date.days_in_month(year, $m)
		$m = $m + 1
	}
	$total
}

pad : I64, U64 -> Str
pad = |n, width| {
	text = n.to_str()
	length = text.count_utf8_bytes()
	if (length >= width) text else Str.repeat("0", width - length).concat(text)
}

expect Date.from_days(0) == Date.ymd(1970, 1, 1)
expect Date.from_days(20777) == Date.ymd(2026, 11, 20)
expect Date.from_days(19782) == Date.ymd(2024, 2, 29)
expect Date.from_days(-1) == Date.ymd(1969, 12, 31)
expect Date.to_days(Date.ymd(2026, 11, 20)) == 20777
expect Date.to_days(Date.ymd(1900, 3, 1)) == -25508
expect Date.to_days(Date.from_days(-719468)) == -719468
expect Date.ymd(2026, 2, 30) == Date.ymd(2026, 3, 2)
expect Date.weekday(Date.ymd(1970, 1, 1)) == 4
expect Date.weekday(Date.ymd(2026, 11, 21)) == 6
expect Date.weekday(Date.ymd(2026, 11, 22)) == 0
expect Date.of_millis(1795211647000, 0) == Date.ymd(2026, 11, 20)
expect Date.of_millis(1795211647000, 180) == Date.ymd(2026, 11, 21)
expect Date.of_millis(-1, 0) == Date.ymd(1969, 12, 31)
expect Date.add_days(Date.ymd(2026, 12, 31), 1) == Date.ymd(2027, 1, 1)
expect Date.add_months(Date.ymd(2026, 1, 31), 1) == Date.ymd(2026, 2, 28)
expect Date.add_months(Date.ymd(2024, 1, 31), 1) == Date.ymd(2024, 2, 29)
expect Date.add_months(Date.ymd(2026, 1, 15), -2) == Date.ymd(2025, 11, 15)
expect Date.days_between(Date.ymd(2026, 1, 1), Date.ymd(2026, 12, 31)) == 364
expect Date.is_leap_year(2000) and !Date.is_leap_year(1900) and Date.is_leap_year(2024)
expect Date.parse_iso("2026-11-21") == Ok(Date.ymd(2026, 11, 21))
expect Date.parse_iso("2026-02-29") == Err(BadDate("2026-02-29"))
expect Date.parse_iso("21.11.2026") == Err(BadDate("21.11.2026"))
expect Date.to_iso(Date.ymd(987, 3, 4)) == "0987-03-04"
