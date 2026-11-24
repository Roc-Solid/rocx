import pf.Actor
import pf.Env
import pf.Http
import pf.Log
import pf.Middleware
import pf.Server
import pf.Time
import otel.Config
import otel.Metric
import otel.Otlp
import otel.Points

## OpenTelemetry metrics on the server: `record!` a measurement, `middleware` to time every request
## (`http.server.request.duration`, by method, route and status). Each instrument's sums are an
## actor's state (its name is the key), which a measurement is told to and which sends them, every
## `OTEL_METRIC_EXPORT_INTERVAL`, to `OTEL_EXPORTER_OTLP_ENDPOINT` as OTLP/HTTP JSON (`Config`).
## With no endpoint, nothing is measured, kept or sent.
##
## With a database, the platform writes an actor's state to it after each message that changes
## it: a write for each measurement. Cheap enough for a start; a kind kept only in memory is the
## platform's to add.
Otel := [].{

	## The sums of the instrument its key names, and when they are next sent. Its name says which
	## shape of state it keeps: one kept before gauges (`rocx_otel_meter`) wouldn't read as this, so
	## it is let be, and the sums start again. Its methods (`measured`, `exported`) are what `rocx
	## build` lists in the app's `program.actors`.
	meter : Actor.Kind(Str, Points.State)
	meter = Actor.define({ name: "rocx_otel_meter_2", initial: |_name| Points.empty })

	## The type of the meter's methods: the app's context, which a package doesn't know (so it is
	## the alias's parameter, `_` where it is used), the instrument's name, the sums, and each
	## method's input and reply.
	Method(context, input, reply) : Actor.Method(context, Str, Points.State, input, reply)

	## Measurements to add to the sums.
	measured : Otel.Method(_, List(Metric.Measurement), {})
	measured = Actor.method(Otel.meter, "measured", |{ me, state, input, .. }| { state: metered!(me, state, input, Bool.False), reply: {} })

	## The time to send the sums has come (the meter's own timer, `scheduled!`). A function of `{}`:
	## the timer it sets names it.
	exported : {} -> Otel.Method(_, {}, {})
	exported = |{}| Actor.method(Otel.meter, "exported", |{ me, state, .. }| { state: metered!(me, state, [], Bool.True), reply: {} })

	## A measurement of `instrument`, labelled with `attributes`: added to its sums (a gauge's: its
	## value now), which go out with the next export. Nothing, with metrics off.
	##
	##     Otel.record!(signups, 1, [("plan", "pro")])
	##     Otel.record!(waiting, 12, [])
	record! : Metric.Instrument, Dec, List((Str, Str)) => {}
	record! = |instrument, value, attributes|
		match settings!({}) {
			Ok(_) => Actor.tell!(Otel.measured, instrument.name, [Metric.measure(instrument, value, attributes)])
			Err(Off) => {}
		}

	## How long the server took to answer a request, in seconds, by `http.request.method`,
	## `http.route` (the route's pattern, `/posts/[id]`, never its path) and
	## `http.response.status_code`, as OpenTelemetry's HTTP conventions name them.
	request_duration : Metric.Instrument
	request_duration = Metric.histogram({ name: "http.server.request.duration", description: "Duration of HTTP server requests.", unit: "s", buckets: Metric.seconds })

	## Times every request it runs around (`request_duration`). First in the app's middleware, so it
	## times the rest too:
	##
	##     middleware: Otel.middleware({}).then(Middlewares.default)
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

## How late an export may be before a measurement takes it as lost (its timer went with a restart)
## and sets another; if it was only late, it is let go when it comes (`exported`).
late_ms : U64
late_ms = 5_000

## A turn of the meter: `measurements` added; then, if it is time to (`export`), the sums sent and
## the next export scheduled, or one scheduled if none is (or the one that was went with a restart).
metered! : Actor.Me(Str, Points.State), Points.State, List(Metric.Measurement), Bool => Points.State
metered! = |me, state, measurements, export| {
	now_ms = Time.now_millis!({})
	started = if (state.start_nanos == 0) { ..state, start_nanos: Time.now_nanos!({}) } else state
	added = measurements.fold(started, Points.add)
	match settings!({}) {
		Err(Off) => { ..added, due_ms: 0 }
		Ok(settings) =>
			if export {
				# A timer that isn't the one due (one set again after a restart, while the old one was
				# still on its way) is let go, so one timer goes on.
				if now_ms + 1_000 < added.due_ms {
					added
				} else {
					send!(Actor.key_of(me), settings, added)
					scheduled!(me, settings, added, now_ms)
				}
			} else if added.due_ms == 0 or now_ms > added.due_ms + late_ms {
				# Nothing is scheduled, or what was went with a restart (a timer is in memory).
				scheduled!(me, settings, added, now_ms)
			} else {
				added
			}
	}
}

## The next export in an interval: a timer to the meter itself.
scheduled! : Actor.Me(Str, Points.State), Config.Settings, Points.State, U64 => Points.State
scheduled! = |me, settings, state, now_ms| {
	_ = Actor.after!(me, settings.interval_ms, Otel.exported({}), {})
	{ ..state, due_ms: now_ms + settings.interval_ms }
}

## Sends the sums of `instrument` to the collector. What goes wrong is logged, and the next export
## sends it all again: the sums are cumulative.
send! : Str, Config.Settings, Points.State => {}
send! = |instrument, settings, state|
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
					Log.warn!("otel: the collector refused the metrics", { instrument: instrument, endpoint: settings.endpoint, status: answer.status, answer: Str.from_utf8_lossy(answer.body.take_first(300)) })
				}
			Err(HttpErr(why)) => Log.warn!("otel: the metrics couldn't be sent", { instrument: instrument, endpoint: settings.endpoint, error: why })
			Err(TimedOut) => Log.warn!("otel: the metrics couldn't be sent", { instrument: instrument, endpoint: settings.endpoint, error: "timed out" })
			Err(TooLarge) => Log.warn!("otel: the collector's answer was too large", { instrument: instrument, endpoint: settings.endpoint })
		}
	}

## A method OpenTelemetry knows, or `_OTHER`: a client can send any, and each would be a series.
method_of : Server.Request -> Str
method_of = |request|
	if (["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE"].contains(request.method)) request.method else "_OTHER"
