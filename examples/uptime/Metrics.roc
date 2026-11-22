import otel.Metric
import Otel

## What Acme Status measures with packages/otel, sent to any OpenTelemetry collector when
## `OTEL_EXPORTER_OTLP_ENDPOINT` is set (and nothing at all when it isn't):
##
## - `uptime.check.duration`, a histogram of each check's latency in seconds, by monitor and outcome;
## - `uptime.check.up`, each monitor's state as of its last check, 1 up and 0 down.
##
## packages/otel has counters and histograms but no gauge yet, so `uptime.check.up` is a histogram
## with one bucket boundary, 0.5: its last interval's sum over its count is the share of checks that
## passed, and a collector's `max` over a short window is whether it is up (README, "What it asked of
## the platform").
Metrics := [].{

	## Each check's latency, in seconds.
	duration : Metric.Instrument
	duration = Metric.histogram({ name: "uptime.check.duration", description: "How long each check of a monitor took.", unit: "s", buckets: Metric.seconds })

	## 1 for a check that passed, 0 for one that failed.
	up : Metric.Instrument
	up = Metric.histogram({ name: "uptime.check.up", description: "Whether a monitor's check passed (1) or failed (0).", unit: "1", buckets: [0.5] })

	## A check of `monitor` that took `latency_ms` and passed or not.
	record! : Str, U64, Bool => {}
	record! = |monitor, latency_ms, passed| {
		outcome = if (passed) "up" else "down"
		Otel.record!(Metrics.duration, latency_ms.to_dec() / 1000.0, [("monitor", monitor), ("outcome", outcome)])
		Otel.record!(Metrics.up, if (passed) 1.0 else 0.0, [("monitor", monitor)])
	}
}
