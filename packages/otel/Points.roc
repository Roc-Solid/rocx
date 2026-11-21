import Metric

## What an app's measurements add up to since `start_nanos`: a series for each instrument and set
## of attributes, as OpenTelemetry's cumulative sums. A counter's series is how many measurements
## and their sum; a histogram's adds how many fell in each bucket. Kept as an actor's state, so it is
## plain data (JSON): `Dec`, not `F64`, which JSON can't always write.
Points := [].{

	Series : {
		name : Str,
		description : Str,
		unit : Str,
		histogram : Bool,
		bounds : List(Dec),
		attributes : List(Metric.Attribute),
		count : U64,
		sum : Dec,
		buckets : List(U64),
	}

	## The series; since when they count (Unix nanoseconds, 0 before the first measurement); when
	## they are next due to be sent (Unix milliseconds, 0 when nothing is scheduled); and how many
	## measurements were dropped (a counter's negative value, an instrument measured as two kinds,
	## or a series past `limit`).
	State : { start_nanos : U64, due_ms : U64, dropped : U64, series : List(Series) }

	empty : State
	empty = { start_nanos: 0, due_ms: 0, dropped: 0, series: [] }

	## How many series are kept at most: a label with a value per user or per URL would make a
	## series for each, and fill memory; past it, new series are dropped, and the ones kept go on.
	limit : U64
	limit = 2000

	## `state` with `measurement` added.
	add : State, Metric.Measurement -> State
	add = |state, measurement| {
		dropped = { ..state, dropped: state.dropped + 1 }
		if !measurement.histogram and measurement.value < 0 {
			dropped
		} else {
			match state.series.find_first_index(|series| series.name == measurement.name and same(series.attributes, measurement.attributes)) {
				Ok(index) =>
					match state.series.get(index) {
						Ok(found) =>
							if found.histogram == measurement.histogram and found.bounds == measurement.bounds {
								{ ..state, series: state.series.update(index, |series| grown(series, measurement)) ?? state.series }
							} else {
								dropped
							}
						Err(_) => dropped
					}
				Err(NotFound) =>
					if state.series.len() >= Points.limit {
						dropped
					} else {
						{ ..state, series: state.series.append(grown(started(measurement), measurement)) }
					}
			}
		}
	}

	## The bucket `value` falls in: the first whose upper bound is at least it, or the last.
	bucket_of : List(Dec), Dec -> U64
	bucket_of = |bounds, value| bounds.find_first_index(|bound| value <= bound) ?? bounds.len()
}

## A series for `measurement`'s instrument and attributes, with nothing in it yet.
started : Metric.Measurement -> Points.Series
started = |measurement| {
	name: measurement.name,
	description: measurement.description,
	unit: measurement.unit,
	histogram: measurement.histogram,
	bounds: measurement.bounds,
	attributes: measurement.attributes,
	count: 0,
	sum: 0,
	buckets: if (measurement.histogram) List.repeat(0, measurement.bounds.len() + 1) else [],
}

grown : Points.Series, Metric.Measurement -> Points.Series
grown = |series, measurement| {
	..series,
	count: series.count + 1,
	sum: series.sum + measurement.value,
	buckets: if (series.histogram) series.buckets.update(Points.bucket_of(series.bounds, measurement.value), |n| n + 1) ?? series.buckets else series.buckets,
}

## The same attributes, in any order.
same : List(Metric.Attribute), List(Metric.Attribute) -> Bool
same = |a, b| a.len() == b.len() and a.all(|attribute| b.contains(attribute))

signups = Metric.counter({ name: "app.signups", description: "", unit: "1" })

took = Metric.histogram({ name: "took", description: "", unit: "s", buckets: [0.1, 1.0] })

## The sums of `measurements`, one after another.
of : List(Metric.Measurement) -> Points.State
of = |measurements| measurements.fold(Points.empty, Points.add)

expect Points.bucket_of([0.1, 1.0], 0.05) == 0
expect Points.bucket_of([0.1, 1.0], 0.1) == 0
expect Points.bucket_of([0.1, 1.0], 0.5) == 1
expect Points.bucket_of([0.1, 1.0], 3.0) == 2
expect Points.bucket_of([], 3.0) == 0

expect {
	state = of([Metric.measure(signups, 1.0, [("plan", "pro")]), Metric.measure(signups, 2.0, [("plan", "pro")]), Metric.measure(signups, 1.0, [("plan", "free")])])
	state.series.map(|series| (series.count, series.sum)) == [(2, 3.0), (1, 1.0)]
}

# Attributes in another order are the same series.
expect of([Metric.measure(signups, 1.0, [("a", "1"), ("b", "2")]), Metric.measure(signups, 1.0, [("b", "2"), ("a", "1")])]).series.len() == 1

expect {
	state = of([Metric.measure(took, 0.05, []), Metric.measure(took, 0.5, []), Metric.measure(took, 5.0, []), Metric.measure(took, 0.07, [])])
	state.series.map(|series| series.buckets) == [[2, 1, 1]] and state.series.map(|series| series.sum) == [5.62]
}

# A counter can't go down; an instrument measured as another kind is dropped.
expect {
	state = of([Metric.measure(signups, -1.0, []), Metric.measure(signups, 1.0, []), Metric.measure({ ..took, name: "app.signups" }, 1.0, [])])
	state.dropped == 2 and state.series.len() == 1
}

# Past the limit, new series are dropped and the kept ones go on.
expect {
	filled = |state, n| if (n == 0) state else filled(Points.add(state, Metric.measure(signups, 1.0, [("n", n.to_str())])), n - 1)
	full = filled(Points.empty, Points.limit)
	more = Points.add(Points.add(full, Metric.measure(signups, 1.0, [("n", "new")])), Metric.measure(signups, 1.0, [("n", Points.limit.to_str())]))
	more.series.len() == Points.limit and more.dropped == 1 and more.series.first().map_ok(|series| series.count) == Ok(2)
}

# It is what an actor keeps: JSON, both ways.
expect {
	state = of([Metric.measure(took, 0.25, [("route", "/posts/[id]")])])
	parsed : Try(Points.State, _)
	parsed = Json.parse(Json.to_str(state))
	parsed == Ok(state)
}
