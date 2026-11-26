## What the status page shows, and its JSON says (`GET /api`): the
## shapes, on no platform, so the server builds them (Status.roc) and the browser's components read
## them. Moments are ISO text in UTC (`Days.moment` shows them); uptimes are text already
## (`99.95%`, `—`), worked out by `Uptime.percent`.
Report := [].{

	## What the live channel says (`routes/api/live/+server.roc`, `News.tell!`): which monitor, and what
	## happened: `up` or `down` (a check), `opened` or `closed` (its incident), `paused`, `resumed`
	## or `updated` (the admin). Here, not in News, which imports `Generated/Api`: Api imports the
	## module this type is in, so it can't be one that imports Api (D-037).
	News : { monitor : I64, name : Str, what : Str }

	## One day of the 90-day strip: its date, how it went (`good`, `minor`, `major`, `none`) and its
	## uptime.
	Day : { day : Str, level : Str, uptime : Str }

	## A monitor as the status page shows it: its state (`operational`, `degraded`, `outage`,
	## `paused`, `pending`) and the words for it, its uptime over 24 hours, 7 and 90 days, its last
	## check, its average latency each hour of the last 24 (oldest first), and its 90 days.
	Monitor : { id : I64, name : Str, state : Str, label : Str, uptime_24h : Str, uptime_7d : Str, uptime_90d : Str, last_at : Str, latency_ms : U64, trend : List(U64), days : List(Report.Day) }

	## Monitors under a heading.
	Group : { name : Str, monitors : List(Report.Monitor) }

	## What was said about an incident: when, its stage (`investigating`, …) and its label, by whom.
	Update : { at : Str, state : Str, label : Str, body : Str, author : Str }

	## An incident: open or closed, how long it lasted (or has lasted), and its updates, newest first.
	Incident : { id : I64, monitor : I64, monitor_name : Str, title : Str, open : Bool, opened_at : Str, closed_at : Str, duration : Str, updates : List(Report.Update) }

	## The banner over the page (`Uptime.banner`).
	Banner : { level : Str, title : Str, detail : Str }

	## The status page: the banner, when it was worked out, the groups of monitors, and the incidents
	## open now or closed in the last 14 days.
	Overview : { banner : Report.Banner, now : Str, groups : List(Report.Group), incidents : List(Report.Incident) }

	## A check, as a monitor's page lists it: `status` 0 for no answer.
	Check : { at : Str, up : Bool, status : U64, latency_ms : U64, error : Str }

	## A monitor's page: what the status page shows of it, how it is checked, its latency every half
	## hour of the last day (oldest first), its failed checks by day and hour over the last week
	## (`week`: the days' labels, oldest first; `failures`: a row of 24 hours for each), its last
	## checks and its incidents of the last 90 days.
	Detail : { monitor : Report.Monitor, group_name : Str, interval_s : U64, expected_status : U64, threshold : U64, latency : List(U64), week : List(Str), failures : List(List(U64)), checks : List(Report.Check), incidents : List(Report.Incident) }

	## A monitor on the admin's page.
	AdminMonitor : { id : I64, name : Str, url : Str, method : Str, interval_s : U64, paused : Bool, streak : U64, state : Str, label : Str, last_at : Str }

	## The admin's page: every monitor, the open incidents, how many subscribers there are, and
	## whether the flaky demo is broken on purpose.
	Admin : { monitors : List(Report.AdminMonitor), incidents : List(Report.Incident), subscribers : U64, broken : Bool }
}
