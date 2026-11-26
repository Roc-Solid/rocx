## A day on the calendar, as `<input type="date">` sends it: `2026-11-21`, a year from 1 to 9999.
## Days compare (`start.is_before(end)`), count (`Date.days_between(start, end)`), are numbers and
## back (`Date.days`, `Date.from_days`: a line chart's axis of days) and write themselves back the
## same way (`date.to_str()`).
Date := { year : I64, month : I64, day : I64 }.{

	## The day `text` names (`2026-02-28`), if it is one: `2026-02-30` isn't.
	from_str : Str -> Try(Date, [NotDate])
	from_str = |text| {
		bytes = text.to_utf8()
		if bytes.len() != 10 or bytes.get(4) != Ok('-') or bytes.get(7) != Ok('-') {
			Err(NotDate)
		} else {
			y = whole(bytes.sublist({ start: 0, len: 4 }))?
			m = whole(bytes.sublist({ start: 5, len: 2 }))?
			d = whole(bytes.sublist({ start: 8, len: 2 }))?
			if y < 1 or m < 1 or m > 12 or d < 1 or d > days_in(y, m) {
				Err(NotDate)
			} else {
				Ok({ year: y, month: m, day: d })
			}
		}
	}

	## As `<input type="date">` writes it: `2026-01-09`.
	to_str : Date -> Str
	to_str = |date| "${padded(date.year, 4)}-${padded(date.month, 2)}-${padded(date.day, 2)}"

	year : Date -> I64
	year = |date| date.year

	## 1 for January.
	month : Date -> I64
	month = |date| date.month

	day : Date -> I64
	day = |date| date.day

	## Days since 1970-01-01 (before it, fewer than none).
	days : Date -> I64
	days = |date| {
		# Howard Hinnant's days_from_civil: years start in March, so a leap day ends one.
		y = if (date.month <= 2) date.year - 1 else date.year
		era = (if (y >= 0) y else y - 399) // 400
		year_of_era = y - era * 400
		day_of_year = (153 * (if (date.month > 2) date.month - 3 else date.month + 9) + 2) // 5 + date.day - 1
		day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
		era * 146097 + day_of_era - 719468
	}

	## The day `count` days after 1970-01-01 (before it, for fewer than none): `Date.days`, the
	## other way. A day outside the years 1 to 9999 is still a date, which `to_str` writes as best it
	## can.
	from_days : I64 -> Date
	from_days = |count| {
		# Howard Hinnant's civil_from_days: years start in March, so a leap day ends one.
		z = count + 719468
		era = (if (z >= 0) z else z - 146096) // 146097
		day_of_era = z - era * 146097
		year_of_era = (day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096) // 365
		day_of_year = day_of_era - (365 * year_of_era + year_of_era // 4 - year_of_era // 100)
		shifted = (5 * day_of_year + 2) // 153
		m = if (shifted < 10) shifted + 3 else shifted - 9
		{ year: year_of_era + era * 400 + (if (m <= 2) 1 else 0), month: m, day: day_of_year - (153 * shifted + 2) // 5 + 1 }
	}

	## How many days from `start` to `end`: 1 from one day to the next; less than none backwards.
	days_between : Date, Date -> I64
	days_between = |start, end| Date.days(end) - Date.days(start)

	is_eq : Date, Date -> Bool
	is_eq = |a, b| a.year == b.year and a.month == b.month and a.day == b.day

	is_before : Date, Date -> Bool
	is_before = |a, b| Date.days(a) < Date.days(b)

	is_after : Date, Date -> Bool
	is_after = |a, b| Date.days(a) > Date.days(b)
}

## Digits as a number; anything else isn't a date.
whole : List(U8) -> Try(I64, [NotDate])
whole = |bytes|
	bytes.fold_try(
		0,
		|sum, byte|
			if byte >= '0' and byte <= '9' {
				Ok(sum * 10 + (byte - '0').to_i64())
			} else {
				Err(NotDate)
			},
	)

days_in : I64, I64 -> I64
days_in = |year, month|
	if month == 2 {
		if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28
	} else if month == 4 or month == 6 or month == 9 or month == 11 {
		30
	} else {
		31
	}

padded : I64, U64 -> Str
padded = |number, width| {
	text = number.to_str()
	size = text.count_utf8_bytes()
	if (size >= width) text else "${Str.repeat("0", width - size)}${text}"
}

day_of : Str -> Date
day_of = |text|
	match Date.from_str(text) {
		Ok(date) => date
		Err(NotDate) => crash "not a date: ${text}"
	}

expect Date.from_str("2026-11-21").map_ok(Date.to_str) == Ok("2026-11-21")
expect Date.from_str("0001-01-09").map_ok(Date.to_str) == Ok("0001-01-09")
expect Date.from_str("2024-02-29").is_ok()
expect Date.from_str("2000-02-29").is_ok()
expect Date.from_str("1900-02-29") == Err(NotDate)
expect Date.from_str("2026-02-29") == Err(NotDate)
expect Date.from_str("2026-04-31") == Err(NotDate)
expect Date.from_str("2026-13-01") == Err(NotDate)
expect Date.from_str("2026-00-10") == Err(NotDate)
expect Date.from_str("0000-01-01") == Err(NotDate)
expect Date.from_str("2026-1-01") == Err(NotDate)
expect Date.from_str("2026/01/01") == Err(NotDate)
expect Date.from_str("20x6-01-01") == Err(NotDate)
expect Date.from_str("") == Err(NotDate)
expect Date.days(day_of("1970-01-01")) == 0
expect Date.days(day_of("1970-01-02")) == 1
expect Date.days(day_of("1969-12-31")) == -1
expect Date.days(day_of("2000-03-01")) == 11017
expect Date.days_between(day_of("2024-02-28"), day_of("2024-03-01")) == 2
expect Date.from_days(0).to_str() == "1970-01-01"
expect Date.from_days(-1).to_str() == "1969-12-31"
expect Date.from_days(11016).to_str() == "2000-02-29"
expect Date.from_days(11017).to_str() == "2000-03-01"
expect Date.from_days(-719162).to_str() == "0001-01-01"
# Each day of four years, there and back: the leap day, and every month's end, in place.
expect {
	var $n = 20000
	var $same = Bool.True
	while $n < 21461 {
		$same = $same and Date.days(Date.from_days($n)) == $n
		$n = $n + 1
	}
	$same
}
expect Date.days_between(day_of("2026-12-31"), day_of("2027-01-01")) == 1
expect day_of("2026-11-21").is_before(day_of("2026-11-22"))
expect !day_of("2026-11-21").is_before(day_of("2026-11-21"))
expect day_of("2027-01-01").is_after(day_of("2026-12-31"))
expect day_of("2026-11-21") == day_of("2026-11-21")
expect day_of("2026-11-21").month() == 11
