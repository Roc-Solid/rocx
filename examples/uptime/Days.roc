## Days and moments as Acme Status shows them, in UTC: the browser has no clock of the server's,
## and a status page read in several time zones is clearest in one. Postgres writes a day as
## `2026-11-22` and a moment as `2026-11-22T14:05:09Z` (Store's queries ask it to); these read
## them, and count days from the epoch, as the 90-day strip needs.
Days := [].{

	## The day `count` days after 1970-01-01, as `2026-11-22` (Howard Hinnant's `civil_from_days`).
	civil : U64 -> Str
	civil = |count| {
		z = count + 719_468
		era = z // 146_097
		doe = z - era * 146_097
		yoe = (doe - doe // 1460 + doe // 36_524 - doe // 146_096) // 365
		doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
		mp = (5 * doy + 2) // 153
		day = doy - (153 * mp + 2) // 5 + 1
		month = if (mp < 10) mp + 3 else mp - 9
		year = yoe + era * 400 + (if (month <= 2) 1 else 0)
		"${year.to_str()}-${two(month)}-${two(day)}"
	}

	## The `count` days up to `today` (days since the epoch), the oldest first.
	back : U64, U64 -> List(Str)
	back = |today, count| List.repeat(0, count).map_with_index(|_, index| Days.civil(today + index + 1 - count))

	## `2026-11-10` as `Nov 10`.
	label : Str -> Str
	label = |day| {
		parts = day.split_on("-")
		month = U64.from_str(parts.get(1) ?? "") ?? 0
		date = U64.from_str(parts.get(2) ?? "") ?? 0
		"${months.get(month - 1) ?? "?"} ${date.to_str()}"
	}

	## `2026-11-10T14:05:09Z` as `Nov 10, 14:05 UTC`.
	moment : Str -> Str
	moment = |at| {
		parts = at.split_on("T")
		day = parts.get(0) ?? ""
		time = parts.get(1) ?? ""
		"${Days.label(day)}, ${Str.from_utf8_lossy(time.to_utf8().take_first(5))} UTC"
	}

	## `2026-11-10T14:05:09Z` as `14:05:09`: when a check of today was made.
	clock : Str -> Str
	clock = |at| {
		time = at.split_on("T").get(1) ?? ""
		Str.from_utf8_lossy(time.to_utf8().take_first(8))
	}

	## Minutes as a reader says them: `1 minute`, `23 minutes`, `2 h 5 min`, `3 days`.
	minutes : U64 -> Str
	minutes = |count|
		if count == 1 {
			"1 minute"
		} else if count < 60 {
			"${count.to_str()} minutes"
		} else if count < 48 * 60 {
			rest = count % 60
			if (rest == 0) "${(count // 60).to_str()} h" else "${(count // 60).to_str()} h ${rest.to_str()} min"
		} else {
			"${(count // 1440).to_str()} days"
		}
}

months : List(Str)
months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

two : U64 -> Str
two = |n| if (n < 10) "0${n.to_str()}" else n.to_str()

expect Days.civil(0) == "1970-01-01"
expect Days.civil(20_414) == "2025-11-22"
expect Days.civil(20_779) == "2026-11-22"
expect Days.civil(11_016) == "2000-02-29"
expect Days.back(20_779, 3) == ["2026-11-20", "2026-11-21", "2026-11-22"]
expect Days.label("2026-11-10") == "Nov 10"
expect Days.label("2027-01-03") == "Jan 3"
expect Days.moment("2026-11-10T14:05:09Z") == "Nov 10, 14:05 UTC"
expect Days.clock("2026-11-10T14:05:09Z") == "14:05:09"
expect Days.minutes(1) == "1 minute"
expect Days.minutes(23) == "23 minutes"
expect Days.minutes(125) == "2 h 5 min"
expect Days.minutes(180) == "3 h"
expect Days.minutes(4 * 1440) == "4 days"
