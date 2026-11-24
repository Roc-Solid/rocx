import pf.Server
import Days
import Report

## The words the pages put around the numbers: plain Roc, on no platform, so the server and the
## browser write them alike.
Words := [].{

	## A latency: `168 ms`, or `<1 ms` for a check of this machine.
	latency : U64 -> Str
	latency = |ms| if (ms == 0) "<1 ms" else "${ms.to_str()} ms"

	## The 90-day strip, for a screen reader: how many days went how.
	strip : List(Report.Day) -> Str
	strip = |days| {
		count = |level| days.count_if(|each| each.level == level)
		parts = [("good", "fine"), ("minor", "with some downtime"), ("major", "with a lot of downtime"), ("none", "without checks")]
			.keep_if(|(level, _)| count(level) > 0)
			.map(|(level, words)| "${count(level).to_str()} ${words}")
		"The last ${days.len().to_str()} days: ${Str.join_with(parts, ", ")}."
	}

	## A day of the strip, for its tooltip: `Nov 10: 99.62%`, or `Nov 10: no checks`.
	day : Report.Day -> Str
	day = |each| if (each.level == "none") "${Days.label(each.day)}: no checks" else "${Days.label(each.day)}: ${each.uptime}"

	## What the live channel said, as the page announces it (`aria-live`).
	news : { name : Str, what : Str } -> Str
	news = |{ name, what }|
		match what {
			"opened" => "${name} is down: an incident is open."
			"closed" => "${name} is back: its incident is resolved."
			"down" => "${name} failed a check."
			"paused" => "${name} is paused."
			"resumed" => "${name} is checked again."
			"updated" => "There is news about ${name}."
			_ => ""
		}

	## A query's value for `name` (`token=abc&x=1`, `token`: `abc`), decoded; `""` when it has none.
	query_value : Str, Str -> Str
	query_value = |query, name| {
		pairs = query.drop_prefix("?").split_on("&")
		found = pairs.find_first(|pair| pair.starts_with("${name}="))
		match found {
			Ok(pair) => Server.decode_segment(pair.drop_prefix("${name}=").replace_each("+", " "))
			Err(_) => ""
		}
	}

	## How often a monitor is checked: `every 30 s`, `every 5 min`, `every 2 h`.
	every : U64 -> Str
	every = |seconds|
		if seconds % 3600 == 0 {
			"every ${(seconds // 3600).to_str()} h"
		} else if seconds % 60 == 0 {
			"every ${(seconds // 60).to_str()} min"
		} else {
			"every ${seconds.to_str()} s"
		}
}

expect Words.latency(0) == "<1 ms"
expect Words.latency(168) == "168 ms"
expect Words.strip([{ day: "2026-11-20", level: "good", uptime: "100%" }, { day: "2026-11-21", level: "good", uptime: "100%" }, { day: "2026-11-22", level: "minor", uptime: "98.10%" }]) == "The last 3 days: 2 fine, 1 with some downtime."
expect Words.day({ day: "2026-11-10", level: "minor", uptime: "98.10%" }) == "Nov 10: 98.10%"
expect Words.day({ day: "2026-11-10", level: "none", uptime: "—" }) == "Nov 10: no checks"
expect Words.news({ name: "Payments API", what: "opened" }) == "Payments API is down: an incident is open."
expect Words.news({ name: "Payments API", what: "up" }) == ""
expect Words.query_value("token=abc&x=1", "token") == "abc"
expect Words.query_value("?then=%2Fadmin%2Fjobs", "then") == "/admin/jobs"
expect Words.query_value("x=1", "token") == ""
expect Words.every(30) == "every 30 s"
expect Words.every(300) == "every 5 min"
expect Words.every(7200) == "every 2 h"
