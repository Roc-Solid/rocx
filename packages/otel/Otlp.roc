import Metric
import Points

## The sums (`Points`) as OpenTelemetry's protocol has them sent over HTTP as JSON (OTLP/HTTP, to
## `/v1/metrics`): one resource (the service: `service.name` and the other resource attributes),
## one scope (`rocx.otel`), a metric for each instrument, a data point for each series. Sums and
## histograms are cumulative (`aggregationTemporality` 2): each request says what has added up since
## `start_nanos`, so one that is lost loses nothing.
Otlp := [].{

	## The request's body for the sums in `state`, as of `now_nanos` (Unix nanoseconds).
	metrics : List(Metric.Attribute), Points.State, U64 -> Str
	metrics = |resource, state, now_nanos| {
		names = state.series.fold([], |seen, series| if (seen.contains(series.name)) seen else seen.append(series.name))
		written = names.map(|name| metric(state.series.keep_if(|series| series.name == name), state.start_nanos, now_nanos))
		"{\"resourceMetrics\":[{\"resource\":{\"attributes\":${attributes(resource)}},\"scopeMetrics\":[{\"scope\":{\"name\":\"rocx.otel\",\"version\":\"0.1.0\"},\"metrics\":[${Str.join_with(written, ",")}]}]}]}"
	}
}

## One instrument's series, all of the same name.
metric : List(Points.Series), U64, U64 -> Str
metric = |series, start, now|
	match series.first() {
		Err(_) => ""
		Ok(first) => {
			head = "\"name\":${quoted(first.name)},\"description\":${quoted(first.description)},\"unit\":${quoted(first.unit)}"
			points = Str.join_with(series.map(|one| point(one, start, now)), ",")
			if first.histogram {
				"{${head},\"histogram\":{\"aggregationTemporality\":2,\"dataPoints\":[${points}]}}"
			} else {
				"{${head},\"sum\":{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\":[${points}]}}"
			}
		}
	}

point : Points.Series, U64, U64 -> Str
point = |series, start, now| {
	head = "\"attributes\":${attributes(series.attributes)},\"startTimeUnixNano\":${big(start)},\"timeUnixNano\":${big(now)}"
	if series.histogram {
		buckets = Str.join_with(series.buckets.map(big), ",")
		bounds = Str.join_with(series.bounds.map(Json.to_str), ",")
		"{${head},\"count\":${big(series.count)},\"sum\":${Json.to_str(series.sum)},\"bucketCounts\":[${buckets}],\"explicitBounds\":[${bounds}]}"
	} else {
		"{${head},\"asDouble\":${Json.to_str(series.sum)}}"
	}
}

attributes : List(Metric.Attribute) -> Str
attributes = |list| {
	written = list.map(|attribute| "{\"key\":${quoted(attribute.key)},\"value\":{\"stringValue\":${quoted(attribute.value)}}}")
	"[${Str.join_with(written, ",")}]"
}

quoted : Str -> Str
quoted = |text| Json.to_str(text)

## A 64-bit integer, written as a string, as protobuf's JSON writes one.
big : U64 -> Str
big = |n| "\"${n.to_str()}\""

expect {
	signups = Metric.counter({ name: "app.signups", description: "Members", unit: "1" })
	state = { ..Points.add(Points.empty, Metric.measure(signups, 2.0, [("plan", "pro")])), start_nanos: 5 }
	Otlp.metrics([{ key: "service.name", value: "shop" }], state, 9)
		== "{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"shop\"}}]},\"scopeMetrics\":[{\"scope\":{\"name\":\"rocx.otel\",\"version\":\"0.1.0\"},\"metrics\":[{\"name\":\"app.signups\",\"description\":\"Members\",\"unit\":\"1\",\"sum\":{\"aggregationTemporality\":2,\"isMonotonic\":true,\"dataPoints\":[{\"attributes\":[{\"key\":\"plan\",\"value\":{\"stringValue\":\"pro\"}}],\"startTimeUnixNano\":\"5\",\"timeUnixNano\":\"9\",\"asDouble\":2.0}]}}]}]}]}"
}

expect {
	took = Metric.histogram({ name: "took", description: "", unit: "s", buckets: [0.1, 1.0] })
	state = Points.add(Points.add(Points.empty, Metric.measure(took, 0.05, [("route", "/a")])), Metric.measure(took, 0.5, [("route", "/b")]))
	written = Otlp.metrics([], state, 1)
	written.contains("\"metrics\":[{\"name\":\"took\",\"description\":\"\",\"unit\":\"s\",\"histogram\":{\"aggregationTemporality\":2,\"dataPoints\":[{\"attributes\":[{\"key\":\"route\",\"value\":{\"stringValue\":\"/a\"}}],\"startTimeUnixNano\":\"0\",\"timeUnixNano\":\"1\",\"count\":\"1\",\"sum\":0.05,\"bucketCounts\":[\"1\",\"0\",\"0\"],\"explicitBounds\":[0.1,1.0]},{")
}

# A name or value with quotes in it stays JSON.
expect attributes([{ key: "q\"", value: "a\nb" }]) == "[{\"key\":\"q\\\"\",\"value\":{\"stringValue\":\"a\\nb\"}}]"
