import pf.Env
import pf.Http
import pf.Kv
import pf.Log
import pf.Middleware
import pf.Plugin
import pf.Server
import pf.Time
import Config
import Metric
import Otlp
import Points

## OpenTelemetry metrics on the server, as a plugin (`Otel.plugin({})`): `record!` a measurement,
## `middleware` to time every request (`http.server.request.duration`, by method, route and
## status). A measurement goes into the server's memory (`Kv`, a list of the newest
## `Otel.buffered`); the plugin's loop takes what is there each second into its sums, and sends them
## every `OTEL_METRIC_EXPORT_INTERVAL` to `OTEL_EXPORTER_OTLP_ENDPOINT` as OTLP/HTTP JSON (`Config`),
## and once more as the server stops. With no endpoint, nothing is measured, kept or sent. Nothing
## is written to the database: a restart starts the sums again, as their start time says (OTLP's
## cumulative sums), which a collector reads as a counter that was reset.
Otel := [].{

	## The plugin: its start reads the `OTEL_*` settings once (`Config`), its check says where the
	## metrics go (`otel.metrics`, on the log), and its loop (`otel.export`) adds up and sends.
	##
	##     # main.roc
	##     plugins: [Otel.plugin({})],
	##
	##     # routes/+middleware.roc
	##     middleware = Otel.middleware({}).then(Middlewares.default)
	plugin : {} -> Plugin.Value(context, ctx)
	plugin = |{}| {
		name: "otel",
		starts: [|_context| started!({})],
		checks: [{ name: "otel.metrics", run!: |_context| checked!({}) }],
		loops: [{ name: "otel.export", run!: |_context| exporter!({}) }],
	}

	## A measurement of `instrument`, labelled with `attributes`: added to its sums (a gauge's: its
	## value now), which go out with the next export. Nothing with metrics off; nothing, said once on
	## the log, when the app's plugins don't list `Otel.plugin`.
	##
	##     Otel.record!(signups, 1, [("plan", "pro")])
	##     Otel.record!(waiting, 12, [])
	record! : Metric.Instrument, Dec, List((Str, Str)) => {}
	record! = |instrument, value, attributes|
		match Plugin.kept!(on_key) {
			Ok("on") => Kv.push!(buffer_key, Metric.measure(instrument, value, attributes), { keep: Otel.buffered })
			Ok(_) => {}
			Err(NotFound) =>
				match Kv.add!("otel:unlisted", Bool.True, {}) {
					Ok({}) => Log.warn!("otel: Otel.record! was called, but the app's plugins don't list Otel.plugin({}), so nothing is measured", { instrument: instrument.name })
					Err(Exists) => {}
				}
		}

	## How many measurements wait in memory for the loop at most (it takes them each second): past
	## it, the oldest go, which only a server measuring more than this a second would see.
	buffered : U64
	buffered = 20_000

	## How long the server took to answer a request, in seconds, by `http.request.method`,
	## `http.route` (the route's pattern, `/posts/[id]`, never its path) and
	## `http.response.status_code`, as OpenTelemetry's HTTP conventions name them.
	request_duration : Metric.Instrument
	request_duration = Metric.histogram({ name: "http.server.request.duration", description: "Duration of HTTP server requests.", unit: "s", buckets: Metric.seconds })

	## Times every request it runs around (`request_duration`). First in the app's middleware
	## (routes/+middleware.roc), so it times the rest too:
	##
	##     middleware = Otel.middleware({}).then(Middlewares.default)
	middleware : {} -> Middleware(context, context)
	middleware = |{}|
		Middleware.make(
			|request, context, next!| {
				started = Time.now_nanos!({})
				answer = next!(request, context)
				took = Time.now_nanos!({}) - started
				Otel.record!(Otel.request_duration, took.to_dec() / 1_000_000_000.0, [("http.request.method", method_of(request)), ("http.route", request.route), ("http.response.status_code", answer.status.to_str())])
				answer
			},
		)
}

## Where the plugin's start says whether metrics are on (`on`, `off`), for `record!` to read.
on_key : Str
on_key = "otel:metrics"

## The measurements waiting for the loop, newest first.
buffer_key : Str
buffer_key = "otel:measurements"

## How often the loop takes the measurements waiting: each second (or each export, if sooner).
drain_ms : U64
drain_ms = 1_000

## The plugin's start: whether metrics are on, kept for `record!`.
started! : {} => Try({}, Str)
started! = |{}| {
	Plugin.keep!(on_key, if (settings!({}).is_ok()) "on" else "off")
	Ok({})
}

## The plugin's check: where the metrics go, or why they don't.
checked! : {} => Try(Str, Str)
checked! = |{}|
	match settings!({}) {
		Ok(settings) => Ok("sent to ${settings.endpoint} every ${(settings.interval_ms // 1000).to_str()} s")
		Err(Off) => Ok("off: OTEL_EXPORTER_OTLP_ENDPOINT isn't set, or OTEL_SDK_DISABLED or OTEL_METRICS_EXPORTER=none says so")
	}

## The settings the environment gives (`Config`), or `Err(Off)`.
settings! : {} => Try(Config.Settings, [Off])
settings! = |{}| {
	var $found = []
	for name in Config.variables {
		match Env.var!(name) {
			Ok(value) => {
				$found = $found.append((name, value))
			}
			Err(NotFound) => {}
		}
	}
	Config.from($found, "unknown_service")
}

## The plugin's loop, for as long as the server runs: each second the measurements waiting added to
## the sums (kept here, in the loop's own memory); every export interval, and as the server stops,
## the sums sent; measurements dropped since the last export (`Points.add`'s) said on the log.
exporter! : {} => {}
exporter! = |{}|
	match settings!({}) {
		Err(Off) => {}
		Ok(settings) => {
			step = U64.min(drain_ms, settings.interval_ms)
			var $state = { ..Points.empty, start_nanos: Time.now_nanos!({}) }
			var $since_ms = 0
			var $dropped = 0
			var $going = Bool.True
			while $going {
				$going = waited!(step)
				$state = drained!($state)
				$since_ms = $since_ms + step
				if $since_ms >= settings.interval_ms or !$going {
					send!(settings, $state)
					if $state.dropped > $dropped {
						Log.warn!("otel: measurements were dropped", { dropped: $state.dropped - $dropped, why: "a counter's negative value, an instrument measured as two kinds, or a series past the limit of each instrument's" })
						$dropped = $state.dropped
					}
					$since_ms = 0
				}
			}
		}
	}

## `state` with the measurements waiting added, oldest first (so a gauge ends at its newest value).
drained! : Points.State => Points.State
drained! = |state| {
	taken : Try(List(Metric.Measurement), [NotFound, BadValue(Str)])
	taken = Kv.take!(buffer_key)
	match taken {
		Ok(measurements) => measurements.fold_rev(state, |measurement, sums| Points.add(sums, measurement))
		Err(NotFound) => state
		Err(BadValue(why)) => {
			Log.error!("otel: the measurements waiting couldn't be read, and are dropped", { error: why })
			state
		}
	}
}

## Sleeps `ms`, a quarter of a second at a time: `Bool.False` as soon as the server is stopping.
waited! : U64 => Bool
waited! = |ms| {
	var $left = ms
	var $going = !Plugin.stopping!({})
	while $going and $left > 0 {
		step = U64.min($left, 250)
		Time.sleep!(step)
		$left = $left - step
		$going = !Plugin.stopping!({})
	}
	$going
}

## Sends the sums to the collector. What goes wrong is logged, and the next export sends it all
## again: the sums are cumulative.
send! : Config.Settings, Points.State => {}
send! = |settings, state|
	if state.series.is_empty() {
		{}
	} else {
		body = Otlp.metrics(settings.resource, state, Time.now_nanos!({}))
		request = { method: "POST", url: settings.endpoint, headers: [{ name: "content-type", value: "application/json" }].concat(settings.headers), body: body.to_utf8() }
		match Http.send!(request, { timeout_ms: settings.timeout_ms, max_bytes: 1_048_576, follow_redirects: Bool.False }) {
			Ok(answer) =>
				if answer.status >= 200 and answer.status < 300 {
					{}
				} else {
					Log.warn!("otel: the collector refused the metrics", { endpoint: settings.endpoint, status: answer.status, answer: Str.from_utf8_lossy(answer.body.take_first(300)) })
				}
			Err(HttpErr(why)) => Log.warn!("otel: the metrics couldn't be sent", { endpoint: settings.endpoint, error: why })
			Err(TimedOut) => Log.warn!("otel: the metrics couldn't be sent", { endpoint: settings.endpoint, error: "timed out" })
			Err(TooLarge) => Log.warn!("otel: the collector's answer was too large", { endpoint: settings.endpoint })
		}
	}

## A method OpenTelemetry knows, or `_OTHER`: a client can send any, and each would be a series.
method_of : Server.Request -> Str
method_of = |request|
	if (["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE"].contains(request.method)) request.method else "_OTHER"
