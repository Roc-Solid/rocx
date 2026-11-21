import Date

## Dates and times as a locale writes them, by CLDR's patterns: `MMM d, y` is "Nov 21, 2026" in
## English, `d MMM y` "21 lis 2026" in Polish, `y年M月d日` "2026年11月21日" in Japanese. A locale's
## `Names` has its month and weekday names and its patterns for each style; `Intl` picks them
## (`intl.date(ms, Medium)`).
##
## Pattern letters: `y` year (`yy` its last two digits), `M` month (`MM` two digits, `MMM` short
## name, `MMMM` full name; `L…` the name standing alone, as in "listopad 2026"), `d` day (`dd`),
## `E…` weekday (`EEEE` in full), `H` hour 0–23, `h` hour 1–12, `a` AM or PM, `m` minute, `s`
## second (doubled: two digits). Text in `'…'` is written as it is, `''` is `'`.
DateFormat := [].{

	Style : [Short, Medium, Long, Full]

	## A locale's names and patterns (`Locales.pl.dates`). Months from January, weekdays from Sunday;
	## `months_standalone` is `[]` where the names don't change when they stand alone.
	Names : {
		months : List(Str),
		months_short : List(Str),
		months_standalone : List(Str),
		weekdays : List(Str),
		weekdays_short : List(Str),
		am : Str,
		pm : Str,
		date : { short : Str, medium : Str, long : Str, full : Str },
		time : { short : Str, medium : Str },
		date_time : { short : Str, medium : Str, long : Str, full : Str },
		month_year : Str,
	}

	## A moment taken apart: the day it falls on, its weekday (0 Sunday), and the time of day.
	Fields : { year : I64, month : I64, day : I64, weekday : I64, hour : I64, minute : I64, second : I64 }

	## A moment (milliseconds since the epoch) taken apart in UTC, or `offset_minutes` east of it.
	fields : I64, I64 -> Fields
	fields = |ms, offset_minutes| {
		local = ms + offset_minutes * 60000
		civil = Date.of_millis(local, 0)
		of_day = local - Date.to_days(civil) * 86400000
		seconds = of_day // 1000
		{
			year: civil.year,
			month: civil.month,
			day: civil.day,
			weekday: civil.weekday(),
			hour: seconds // 3600,
			minute: seconds % 3600 // 60,
			second: seconds % 60,
		}
	}

	## A day, at midnight.
	of_date : Date -> Fields
	of_date = |civil| { year: civil.year, month: civil.month, day: civil.day, weekday: civil.weekday(), hour: 0, minute: 0, second: 0 }

	## The date in a style: Short "21.11.2026", Medium "21 lis 2026", Long "21 listopada 2026", Full
	## "sobota, 21 listopada 2026" (Polish).
	date : Names, Fields, Style -> Str
	date = |names, at, style|
		DateFormat.pattern(
			names,
			match style {
				Short => names.date.short
				Medium => names.date.medium
				Long => names.date.long
				Full => names.date.full
			},
			at,
		)

	## The time of day: Short "3:04 PM", Medium "3:04:05 PM" (English); "15:04" in most others.
	time : Names, Fields, [Short, Medium] -> Str
	time = |names, at, style|
		DateFormat.pattern(
			names,
			match style {
				Short => names.time.short
				Medium => names.time.medium
			},
			at,
		)

	## Date and time, joined as the locale joins them for the date's style: "Nov 21, 2026, 3:04 PM",
	## "November 21, 2026 at 3:04 PM".
	date_time : Names, Fields, Style, [Short, Medium] -> Str
	date_time = |names, at, date_style, time_style| {
		glue =
			match date_style {
				Short => names.date_time.short
				Medium => names.date_time.medium
				Long => names.date_time.long
				Full => names.date_time.full
			}
		glue.replace_each("{1}", DateFormat.date(names, at, date_style)).replace_each("{0}", DateFormat.time(names, at, time_style))
	}

	## A month of a year, as a calendar's heading has it: "November 2026", "listopad 2026",
	## "2026年11月".
	month_year : Names, Fields -> Str
	month_year = |names, at| DateFormat.pattern(names, names.month_year, at)

	## `at` written by a CLDR pattern (letters above).
	pattern : Names, Str, Fields -> Str
	pattern = |names, written, at| {
		bytes = written.to_utf8()
		var $out = []
		var $i = 0
		while $i < bytes.len() {
			b = bytes.get($i) ?? 0
			if b == '\'' {
				if (bytes.get($i + 1) ?? 0) == '\'' {
					$out = $out.append('\'')
					$i = $i + 2
				} else {
					# Quoted text, to the next lone quote; '' inside it is a quote.
					var $j = $i + 1
					var $quoting = Bool.True
					while $quoting and $j < bytes.len() {
						c = bytes.get($j) ?? 0
						if c == '\'' and (bytes.get($j + 1) ?? 0) == '\'' {
							$out = $out.append('\'')
							$j = $j + 2
						} else if c == '\'' {
							$quoting = Bool.False
							$j = $j + 1
						} else {
							$out = $out.append(c)
							$j = $j + 1
						}
					}
					$i = $j
				}
			} else if (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') {
				var $run = 1
				while (bytes.get($i + $run) ?? 0) == b {
					$run = $run + 1
				}
				$out = $out.concat(field(names, b, $run, at).to_utf8())
				$i = $i + $run
			} else {
				$out = $out.append(b)
				$i = $i + 1
			}
		}
		Str.from_utf8_lossy($out)
	}
}

## What `count` of the letter `letter` stand for.
field : DateFormat.Names, U8, U64, DateFormat.Fields -> Str
field = |names, letter, count, at| {
	twelve = if (at.hour % 12 == 0) 12 else at.hour % 12
	if letter == 'y' {
		if (count == 2) pad(at.year % 100, 2) else pad(at.year, count)
	} else if letter == 'M' or letter == 'L' {
		if count >= 4 {
			standalone = if (letter == 'L' and !names.months_standalone.is_empty()) names.months_standalone else names.months
			name_at(standalone, at.month - 1)
		} else if count == 3 {
			name_at(names.months_short, at.month - 1)
		} else {
			pad(at.month, count)
		}
	} else if letter == 'd' {
		pad(at.day, count)
	} else if letter == 'E' or letter == 'c' {
		if (count >= 4) name_at(names.weekdays, at.weekday) else name_at(names.weekdays_short, at.weekday)
	} else if letter == 'a' {
		if (at.hour < 12) names.am else names.pm
	} else if letter == 'H' {
		pad(at.hour, count)
	} else if letter == 'h' {
		pad(twelve, count)
	} else if letter == 'K' {
		pad(at.hour % 12, count)
	} else if letter == 'k' {
		pad(if (at.hour == 0) 24 else at.hour, count)
	} else if letter == 'm' {
		pad(at.minute, count)
	} else if letter == 's' {
		pad(at.second, count)
	} else {
		Str.from_utf8_lossy(List.repeat(letter, count))
	}
}

name_at : List(Str), I64 -> Str
name_at = |names, index| names.get(index.to_u64_wrap()) ?? "?"

pad : I64, U64 -> Str
pad = |n, width| {
	text = n.to_str()
	length = text.count_utf8_bytes()
	if (length >= width) text else Str.repeat("0", width - length).concat(text)
}

en : DateFormat.Names
en = {
	months: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
	months_short: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
	months_standalone: [],
	weekdays: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
	weekdays_short: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
	am: "AM",
	pm: "PM",
	date: { short: "M/d/yy", medium: "MMM d, y", long: "MMMM d, y", full: "EEEE, MMMM d, y" },
	time: { short: "h:mm a", medium: "h:mm:ss a" },
	date_time: { short: "{1}, {0}", medium: "{1}, {0}", long: "{1} at {0}", full: "{1} at {0}" },
	month_year: "MMMM y",
}

# 2026-11-21 15:04:05 UTC, a Saturday.
moment : I64
moment = 1795273445000

expect DateFormat.fields(moment, 0) == { year: 2026, month: 11, day: 21, weekday: 6, hour: 15, minute: 4, second: 5 }
expect DateFormat.fields(moment, 600) == { year: 2026, month: 11, day: 22, weekday: 0, hour: 1, minute: 4, second: 5 }
expect DateFormat.fields(-1000, 0) == { year: 1969, month: 12, day: 31, weekday: 3, hour: 23, minute: 59, second: 59 }
expect DateFormat.date(en, DateFormat.fields(moment, 0), Short) == "11/21/26"
expect DateFormat.date(en, DateFormat.fields(moment, 0), Full) == "Saturday, November 21, 2026"
expect DateFormat.time(en, DateFormat.fields(moment, 0), Short) == "3:04 PM"
expect DateFormat.time(en, DateFormat.fields(moment - 15 * 3600000, 0), Medium) == "12:04:05 AM"
expect DateFormat.date_time(en, DateFormat.fields(moment, 0), Long, Short) == "November 21, 2026 at 3:04 PM"
expect DateFormat.month_year(en, DateFormat.of_date(Date.ymd(2026, 1, 5))) == "January 2026"
expect DateFormat.pattern(en, "d' de 'MMMM' de 'y", DateFormat.of_date(Date.ymd(2026, 1, 5))) == "5 de January de 2026"
expect DateFormat.pattern(en, "HH:mm 'o''clock' ''", DateFormat.fields(moment, 0)) == "15:04 o'clock '"
expect DateFormat.pattern(en, "dd.MM.yyyy", DateFormat.of_date(Date.ymd(987, 3, 4))) == "04.03.0987"
