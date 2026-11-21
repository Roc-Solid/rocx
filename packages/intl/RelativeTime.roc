import Plural
import NumberFormat

## How far off a moment is, in a locale's words: "in 3 days", "3 days ago", "za 2 godziny",
## "2 godziny temu", "خلال ساعتين" (Arabic's two hours, without a digit). A locale's `Words` have
## each unit's forms for the future and the past, by plural category; `Intl` picks them
## (`intl.relative(-3, Day)`, `intl.ago(then, now)`).
RelativeTime := [].{

	Unit : [Second, Minute, Hour, Day, Week, Month, Year]

	## A locale's words (`Locales.pl.relative`): `{0}` is where the number goes.
	Words : {
		second : { future : Plural.Forms, past : Plural.Forms },
		minute : { future : Plural.Forms, past : Plural.Forms },
		hour : { future : Plural.Forms, past : Plural.Forms },
		day : { future : Plural.Forms, past : Plural.Forms },
		week : { future : Plural.Forms, past : Plural.Forms },
		month : { future : Plural.Forms, past : Plural.Forms },
		year : { future : Plural.Forms, past : Plural.Forms },
		yesterday : Str,
		today : Str,
		tomorrow : Str,
		now : Str,
	}

	## `amount` of `unit` from now: ahead when 0 or more ("in 0 days", as `Intl` has it), behind when
	## less. `rule` is the locale's cardinal plural rule, and `symbols` write the number.
	format : Words, (Plural.Operands -> Plural.Category), NumberFormat.Symbols, I64, Unit -> Str
	format = |words, rule, symbols, amount, unit| {
		both =
			match unit {
				Second => words.second
				Minute => words.minute
				Hour => words.hour
				Day => words.day
				Week => words.week
				Month => words.month
				Year => words.year
			}
		size = if (amount < 0) 0 - amount else amount
		forms = if (amount < 0) both.past else both.future
		chosen = Plural.pick(forms, rule(Plural.operands(size.to_str())))
		chosen.replace_each("{0}", NumberFormat.format(symbols, size.to_dec(), NumberFormat.defaults))
	}

	## Days from today in words where the locale has them: -1 "yesterday", 0 "today", 1 "tomorrow";
	## further off, as `format` writes days.
	days : Words, (Plural.Operands -> Plural.Category), NumberFormat.Symbols, I64 -> Str
	days = |words, rule, symbols, amount|
		if amount == -1 {
			words.yesterday
		} else if amount == 0 {
			words.today
		} else if amount == 1 {
			words.tomorrow
		} else {
			RelativeTime.format(words, rule, symbols, amount, Day)
		}

	## The unit to say a difference of `ms` milliseconds in, and how many: under a minute in
	## seconds, under an hour in minutes, then hours, days (under a week), weeks (under 30 days),
	## months (under a year) and years, each rounded half away from zero. 89 minutes is 1 hour, 90
	## is 2; 59.5 minutes is 1 hour, not 60 minutes.
	between : I64 -> { amount : I64, unit : Unit }
	between = |ms| {
		seconds = rounded(ms, 1000)
		minutes = rounded(ms, 60000)
		hours = rounded(ms, 3600000)
		days_off = rounded(ms, 86400000)
		if I64.abs(seconds) < 60 {
			{ amount: seconds, unit: Second }
		} else if I64.abs(minutes) < 60 {
			{ amount: minutes, unit: Minute }
		} else if I64.abs(hours) < 24 {
			{ amount: hours, unit: Hour }
		} else if I64.abs(days_off) < 7 {
			{ amount: days_off, unit: Day }
		} else if I64.abs(days_off) < 30 {
			{ amount: rounded(ms, 604800000), unit: Week }
		} else {
			# A month is a twelfth of the Gregorian year, 30.436875 days.
			months = rounded(ms, 2629746000)
			if I64.abs(months) < 12 {
				{ amount: months, unit: Month }
			} else {
				{ amount: rounded(ms, 31556952000), unit: Year }
			}
		}
	}
}

## `a / b`, rounded half away from zero (`b` above 0).
rounded : I64, I64 -> I64
rounded = |a, b| if (a >= 0) (a + b // 2) // b else 0 - (0 - a + b // 2) // b

minute : I64
minute = 60000

day : I64
day = 86400000

expect RelativeTime.between(0) == { amount: 0, unit: Second }
expect RelativeTime.between(-45000) == { amount: -45, unit: Second }
expect RelativeTime.between(59499) == { amount: 59, unit: Second }
expect RelativeTime.between(59500) == { amount: 1, unit: Minute }
expect RelativeTime.between(-89 * minute) == { amount: -1, unit: Hour }
expect RelativeTime.between(90 * minute) == { amount: 2, unit: Hour }
expect RelativeTime.between(23 * 60 * minute) == { amount: 23, unit: Hour }
expect RelativeTime.between(-36 * 60 * minute) == { amount: -2, unit: Day }
expect RelativeTime.between(6 * day) == { amount: 6, unit: Day }
expect RelativeTime.between(-10 * day) == { amount: -1, unit: Week }
expect RelativeTime.between(29 * day) == { amount: 4, unit: Week }
expect RelativeTime.between(45 * day) == { amount: 1, unit: Month }
expect RelativeTime.between(-200 * day) == { amount: -7, unit: Month }
expect RelativeTime.between(400 * day) == { amount: 1, unit: Year }
expect RelativeTime.between(-3 * 365 * day) == { amount: -3, unit: Year }
