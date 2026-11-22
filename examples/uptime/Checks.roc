import pf.Env
import pf.Http
import pf.Log
import pf.Time
import Metrics
import News
import Store

## A check of one monitor, as the `check` job runs it (Jobs.roc): ask its URL (`Http.fetch!`), judge
## the answer, store it with what it does to the monitor's incident (`Store.record!`), then tell the
## open pages (`News.tell!`) and the metrics (`Metrics.record!`).
Checks := [].{

	## The biggest answer a check reads: a page bigger than this fails it.
	max_bytes : U64
	max_bytes = 5 * 1024 * 1024

	## What an answer was: a status, or why there was none.
	Answer : [Answered(U64), NoAnswer(Str)]

	## Checks the monitor `id`. One deleted or paused since it was queued is let be. An `Err` (the
	## check couldn't be stored) has the job tried again. `alert!` queues an incident's alerts.
	run! : I64, (I64, [Opened, Closed] => Try({}, [DbErr(Str), BadRow(Str), JobErr(Str)])) => Try({}, Str)
	run! = |id, alert!|
		match Store.monitor!(id) {
			Err(NotFound) => Ok({})
			Err(DbErr(why)) => Err(why)
			Err(BadRow(why)) => Err(why)
			Ok(monitor) =>
				if monitor.paused {
					Ok({})
				} else {
					# A URL that starts with `/` is this app's own (`/health`): where the app is,
					# as the server says (`--public-url`, or where it listens).
					url = if (monitor.url.starts_with("/")) "${Env.public_url!({})}${monitor.url}" else monitor.url
					found = Checks.probe!(monitor, url)
					match Store.record!(monitor, found, alert!) {
						Ok(outcome) => {
							told!(monitor, found, outcome)
							Ok({})
						}
						Err(DbErr(why)) => Err(why)
						Err(BadRow(why)) => Err(why)
						Err(JobErr(why)) => Err(why)
					}
				}
		}

	## Asks `url` as the monitor says, and judges the answer.
	probe! : Store.Monitor, Str => Store.Found
	probe! = |monitor, url| {
		started = Time.now_nanos!({})
		asked = Http.fetch!(
			url,
			{
				method: method(monitor.method),
				headers: [("user-agent", "Status/1.0 (uptime check)")],
				timeout_ms: monitor.timeout_ms,
				max_bytes: Checks.max_bytes,
			},
		)
		latency_ms = (Time.now_nanos!({}) - started) // 1_000_000
		answer =
			match asked {
				Ok(res) => Answered(res.status.to_u64())
				Err(HttpErr(why)) => NoAnswer(why)
				Err(TimedOut) => NoAnswer("no answer in ${(monitor.timeout_ms // 1000).to_str()} s")
				Err(TooLarge) => NoAnswer("the answer was over 5 MiB")
			}
		Checks.judge(monitor.expected_status, answer, latency_ms)
	}

	## Whether an answer passes: the status the monitor expects, and what was wrong if it isn't.
	judge : U64, Checks.Answer, U64 -> Store.Found
	judge = |expected, answer, latency_ms|
		match answer {
			Answered(status) =>
				if status == expected {
					{ up: Bool.True, status, latency_ms, error: "" }
				} else {
					{ up: Bool.False, status, latency_ms, error: "expected ${expected.to_str()}, got ${status.to_str()}" }
				}
			NoAnswer(why) => { up: Bool.False, status: 0, latency_ms, error: why }
		}
}

## Tells the open pages and the metrics what a stored check found.
told! : Store.Monitor, Store.Found, Store.Outcome => {}
told! = |monitor, found, outcome| {
	what =
		match outcome.decision {
			Open => "opened"
			Close => "closed"
			Keep => if (found.up) "up" else "down"
		}
	News.tell!({ monitor: monitor.id, name: monitor.name, what })
	Metrics.record!(monitor.name, found.latency_ms, found.up)
	match outcome.decision {
		Open => Log.warn!("uptime: an incident opened", { monitor: monitor.name, incident: outcome.incident, error: found.error })
		Close => Log.info!("uptime: an incident closed", { monitor: monitor.name, incident: outcome.incident })
		Keep => {}
	}
}

method : Str -> Http.Method
method = |name|
	match name {
		"HEAD" => Head
		"POST" => Post
		_ => Get
	}

expect Checks.judge(200, Answered(200), 42) == { up: Bool.True, status: 200, latency_ms: 42, error: "" }
expect Checks.judge(200, Answered(503), 12) == { up: Bool.False, status: 503, latency_ms: 12, error: "expected 200, got 503" }
expect Checks.judge(204, Answered(204), 7).up
expect Checks.judge(200, NoAnswer("connection refused"), 3) == { up: Bool.False, status: 0, latency_ms: 3, error: "connection refused" }
