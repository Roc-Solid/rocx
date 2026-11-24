# otel

OpenTelemetry for Roc Solid apps, starting simple: **metrics** sent over OTLP, and **logs**
collected from the server's JSON log. Every request is timed by route, and the app counts what it
likes. Everything goes to any OpenTelemetry Collector, or to a backend that takes OTLP/HTTP
(Grafana Cloud, Honeycomb, Datadog, …).

```roc
# main.roc
program = App.program({
	init!: |started| Ok({ facts: started }),
	middleware: Otel.middleware({}).then(Middlewares.default),
})
```

```roc
# anywhere on the server
signups = Metric.counter({ name: "app.signups", description: "Members who signed up.", unit: "{member}" })

Otel.record!(signups, 1, [("plan", "pro")])
```

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 OTEL_SERVICE_NAME=shop ./server
```

## Metrics

**`Otel.middleware({})`** times every request it runs around, as OpenTelemetry's HTTP conventions
name it: `http.server.request.duration`, a histogram in seconds, by
- `http.request.method` (`_OTHER` for a method HTTP doesn't define),
- `http.route`, the route's pattern (`/posts/[id]`, never `/posts/42`, so a post isn't a series of
  its own; none when nothing answered), from
  `Server.Request`'s `route`,
- `http.response.status_code`.

Put it first, so it times the rest of the middleware too.

**Instruments** (`Metric`): a counter sums what it's given (signups, emails sent); a histogram
counts values into buckets and sums them (how long a checkout took); a gauge keeps the last value
set for each set of attributes (whether a service is up, how many jobs wait), negative values
too. `Metric.seconds` is OpenTelemetry's buckets for durations, 5 ms to 10 s.

```roc
checkout = Metric.histogram({ name: "app.checkout.duration", description: "Checkout.", unit: "s", buckets: Metric.seconds })

started = Time.now_nanos!({})
…
Otel.record!(checkout, (Time.now_nanos!({}) - started).to_dec() / 1_000_000_000, [("method", "card")])

up = Metric.gauge({ name: "app.service.up", description: "Whether the service answered (1) or not (0).", unit: "1" })
Otel.record!(up, 1, [("service", "payments")])
```

A gauge is sent as OTLP's `gauge` (a data point a series, its last value, `asDouble`), again at each
export until it is set to another; counters and histograms are cumulative sums. One name is one
kind: a measurement of another kind under a name already measured is dropped.

Attributes are text. Keep their values few: each combination is a series. A user's id or a URL
would make a series for each, so past 2000 series an instrument drops new ones (`Points.limit`).

**Where they go.** The standard variables, as every OpenTelemetry SDK reads them (`Config`):

| Variable | |
| --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | the collector, `/v1/metrics` added (`http://localhost:4318`) |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | the URL itself, instead |
| `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_METRICS_HEADERS` | `name=value,…`, percent-decoded (`Authorization=Basic%20…`); the second, if set, instead |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` | the service (`unknown_service` without either) |
| `OTEL_METRIC_EXPORT_INTERVAL` | milliseconds between sends (60000, at least 1000) |
| `OTEL_METRIC_EXPORT_TIMEOUT` | milliseconds a send may take (30000) |
| `OTEL_SDK_DISABLED=true`, `OTEL_METRICS_EXPORTER=none` | off |

**With no endpoint, metrics are off**: nothing is measured, kept or sent. That is the default in
development.

**How it works.** Each instrument's sums are an actor's state (`Otel.meter`, keyed by the
instrument's name). A measurement is a `tell!` of its `measured` method, so the request doesn't wait
for it. The actor sets itself a timer (`me.after!`, calling its `exported`) and sends its sums
when it fires, as OTLP/HTTP JSON (`Otlp`). The
sums are cumulative since the actor started, so a send that fails loses nothing: the next one has it
all, and the failure is logged (`otel: the metrics couldn't be sent`). With a database, the
sums outlive a restart, and keep their start time. (The meter's state took a gauge's kind on
2026-11-22, and its actor a new name, `rocx_otel_meter_2`: sums kept before then aren't read, and
start again.)

**What it costs.** One actor message for each measurement, so two for a request that records one
of its own. With a database, the platform writes an actor's state to Postgres after each message
that changes it, so each measurement is also a write: fine for a start. A kind of actor kept only
in memory would remove it (PROPOSALS.md).

## Logs

Nothing to add to the app: let the collector read the server's log. With
`logs: { format: Json }` in the app's `program` (or `ROCX_LOG=json`), each line is one JSON object:

```json
{"time":"2026-11-21T20:14:52.100Z","level":"warn","msg":"gate failed","path":"/admin","error":"no session"}
```

The collector's `filelog` receiver (in `otelcol-contrib`) turns it into an OpenTelemetry log
record: `time` its timestamp, `level` its severity, `msg` its body, and the fields its attributes.
Each line the platform writes counts, including its own and a crash's.

```yaml
receivers:
  filelog:
    include: [/var/log/shop/*.log]
    operators:
      - type: json_parser
        timestamp:
          parse_from: attributes.time
          layout_type: gotime
          layout: "2006-01-02T15:04:05.999Z07:00"
        severity:
          parse_from: attributes.level
      - type: move
        from: attributes.msg
        to: body
      - type: remove
        field: attributes.time
      - type: remove
        field: attributes.level
processors:
  resource:
    attributes:
      - { key: service.name, value: shop, action: upsert }
```

In Docker or Kubernetes, point `include` at the container's log files instead.

## Setup

1. Name the package in the app's header: `otel: "…/packages/otel/main.roc"`.
2. Copy `server/Otel.roc` into the app, beside its main.roc, and `import Otel`. A route file
   imports it by its path (`import ../../Otel`). `rocx build` doesn't copy a package's
   server-only modules yet (PROPOSALS.md), and it lists the meter's methods (`Otel.measured`,
   `Otel.exported({})`) in the app's `program.actors` itself.
3. `Otel.middleware({})` first in the app's middleware.

`example/` does all three (`cp ../server/Otel.roc . && rocx build .`): `GET /hello/<name>` counts
`app.greetings`.

## Checked against

- `roc test packages/otel/main.roc`: instruments, sums, buckets, gauges' last values, the series
  limit, the state as JSON both ways, OTLP's JSON (sums, histograms, gauges), the variables.
- The example, built native, sending to OpenTelemetry Collector 0.165.0 (`otlp` receiver, `debug`
  exporter): sums, histograms, attributes, timestamps and the resource all read back. Also run
  against Postgres, across a restart.
- The logs config above, with otelcol-contrib 0.165.0, on the server's own log.

## Not yet

- **Traces.** They need to know, in `Db.all!` and `Http.fetch!`, which request they run for, with
  nothing passed by hand. Roc has no such context, so that waits on a talk with Roc's designers.
- Up-down counters; exemplars; Prometheus's `/metrics` for pulling instead.
- A job's duration and outcome (a wrapper for `Job.define`).
