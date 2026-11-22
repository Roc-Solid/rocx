## An instrument: something an app measures, named as OpenTelemetry names it
## (`http.server.request.duration`), and how its measurements add up. A counter sums them (members
## who signed up); a histogram counts them into buckets and sums them (how long a request took); a
## gauge keeps the last one (whether a service is up, how many jobs wait).
##
## ```roc
## signups = Metric.counter({ name: "app.signups", description: "Members who signed up", unit: "{member}" })
## checkout = Metric.histogram({ name: "app.checkout.duration", description: "Checkout time", unit: "s", buckets: Metric.seconds })
## waiting = Metric.gauge({ name: "app.jobs.waiting", description: "Jobs queued and not yet run", unit: "{job}" })
## ```
Metric := [].{

	## A counter (`Counter`); a histogram with the upper bounds of its buckets, smallest first (a
	## value goes in the first bucket whose bound is at least it, or in the last one, past every
	## bound); or a gauge (`Gauge`), the last value set.
	Kind : [Counter, Histogram(List(Dec)), Gauge]

	Instrument : { name : Str, description : Str, unit : Str, kind : Kind }

	## An attribute: a measurement's label (`http.route`, `/posts/[id]`).
	Attribute : { key : Str, value : Str }

	## A measurement, as the actor that adds them up is sent it: its instrument, flattened (whether
	## it is a histogram, with its bounds, or a gauge; a counter is neither), its attributes and its
	## value.
	Measurement : { name : Str, description : Str, unit : Str, histogram : Bool, gauge : Bool, bounds : List(Dec), attributes : List(Attribute), value : Dec }

	## A counter: the sum of what it is given, which can't go down (a negative value is dropped).
	counter : { name : Str, description : Str, unit : Str } -> Instrument
	counter = |{ name, description, unit }| { name, description, unit, kind: Counter }

	## A histogram: how many values fell in each bucket (`buckets`, their upper bounds), how many in
	## all, and their sum.
	histogram : { name : Str, description : Str, unit : Str, buckets : List(Dec) } -> Instrument
	histogram = |{ name, description, unit, buckets }| { name, description, unit, kind: Histogram(buckets) }

	## A gauge: the last value set for each set of attributes (any value, negative too), sent as it
	## is at each export, as OpenTelemetry's `Gauge`.
	gauge : { name : Str, description : Str, unit : Str } -> Instrument
	gauge = |{ name, description, unit }| { name, description, unit, kind: Gauge }

	## Buckets for durations in seconds, OpenTelemetry's for HTTP (5 ms to 10 s).
	seconds : List(Dec)
	seconds = [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]

	## A measurement of `instrument`: `value`, labelled with `attributes`. An attribute with an
	## empty value is left out (a request no route matched has no `http.route`).
	measure : Instrument, Dec, List((Str, Str)) -> Measurement
	measure = |instrument, value, attributes| {
		(is_histogram, bounds) =
			match instrument.kind {
				Counter => (Bool.False, [])
				Histogram(given) => (Bool.True, given)
				Gauge => (Bool.False, [])
			}
		{
			name: instrument.name,
			description: instrument.description,
			unit: instrument.unit,
			histogram: is_histogram,
			gauge: instrument.kind == Gauge,
			bounds: bounds,
			attributes: attributes.keep_if(|(_, value_of)| !value_of.is_empty()).map(|(key, value_of)| { key: key, value: value_of }),
			value: value,
		}
	}
}

expect Metric.measure(Metric.counter({ name: "a", description: "", unit: "1" }), 1.0, [("plan", "pro"), ("empty", "")]).attributes == [{ key: "plan", value: "pro" }]
expect !Metric.measure(Metric.counter({ name: "a", description: "", unit: "1" }), 1.0, []).histogram
expect Metric.measure(Metric.histogram({ name: "d", description: "", unit: "s", buckets: Metric.seconds }), 0.2, []).histogram
expect Metric.measure(Metric.histogram({ name: "d", description: "", unit: "s", buckets: [] }), 0.2, []).histogram
expect {
	measured = Metric.measure(Metric.gauge({ name: "g", description: "", unit: "1" }), -2.5, [("monitor", "api")])
	measured.gauge and !measured.histogram and measured.bounds == [] and measured.value == -2.5
}
expect !Metric.measure(Metric.counter({ name: "a", description: "", unit: "1" }), 1.0, []).gauge
expect !Metric.measure(Metric.histogram({ name: "d", description: "", unit: "s", buckets: Metric.seconds }), 0.2, []).gauge
