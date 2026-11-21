## An instrument: something an app measures, named as OpenTelemetry names it
## (`http.server.request.duration`), and how its measurements add up. A counter sums them (members
## who signed up); a histogram counts them into buckets and sums them (how long a request took).
##
## ```roc
## signups = Metric.counter({ name: "app.signups", description: "Members who signed up", unit: "{member}" })
## checkout = Metric.histogram({ name: "app.checkout.duration", description: "Checkout time", unit: "s", buckets: Metric.seconds })
## ```
Metric := [].{

	## A counter (`Counter`), or a histogram with the upper bounds of its buckets, smallest first
	## (a value goes in the first bucket whose bound is at least it, or in the last one, past
	## every bound).
	Kind : [Counter, Histogram(List(Dec))]

	Instrument : { name : Str, description : Str, unit : Str, kind : Kind }

	## An attribute: a measurement's label (`http.route`, `/posts/[id]`).
	Attribute : { key : Str, value : Str }

	## A measurement, as the actor that adds them up is sent it: its instrument, flattened, its
	## attributes and its value.
	Measurement : { name : Str, description : Str, unit : Str, histogram : Bool, bounds : List(Dec), attributes : List(Attribute), value : Dec }

	counter : { name : Str, description : Str, unit : Str } -> Instrument
	counter = |{ name, description, unit }| { name, description, unit, kind: Counter }

	histogram : { name : Str, description : Str, unit : Str, buckets : List(Dec) } -> Instrument
	histogram = |{ name, description, unit, buckets }| { name, description, unit, kind: Histogram(buckets) }

	## Buckets for durations in seconds, OpenTelemetry's for HTTP (5 ms to 10 s).
	seconds : List(Dec)
	seconds = [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0]

	## A measurement of `instrument`: `value`, labelled with `attributes`. An attribute with an
	## empty value is left out (a request no route matched has no `http.route`).
	measure : Instrument, Dec, List((Str, Str)) -> Measurement
	measure = |instrument, value, attributes| {
		bounds =
			match instrument.kind {
				Counter => []
				Histogram(given) => given
			}
		{
			name: instrument.name,
			description: instrument.description,
			unit: instrument.unit,
			histogram: !bounds.is_empty() or instrument.kind != Counter,
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
