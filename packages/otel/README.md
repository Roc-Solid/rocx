# otel

OpenTelemetry for Roc Solid apps: **metrics** sent over OTLP, and **logs** read from the server's
JSON log. The middleware times every request by its route, and the app records numbers of its own.
Everything goes to any OpenTelemetry Collector, or to a backend that accepts OTLP/HTTP (Grafana
Cloud, Honeycomb, Datadog, and others). Traces come later.

The user guide is the docs site's [OpenTelemetry page](https://roc-solid.github.io/ecosystem/otel);
this file is the reference. `examples/uptime` uses it for each check's latency and each monitor's
state.

## Installing it

1. Name the package in the app's header:

   ```roc
   app [program] { otel: "…/packages/otel/main.roc", pf: platform "…/server/platform/main.roc" }
   ```

2. List its plugin, and put `Otel.middleware({})` first in the app's middleware (`import otel.Otel`
   wherever you record):

   ```roc
   # main.roc
   import otel.Otel

   program = App.program({
       init!: |started| Ok({ facts: started }),
       middleware: Otel.middleware({}).then(Middlewares.default),
       plugins: [Otel.plugin({})],
   })
   ```

4. Start the server with a collector to send to:

   ```sh
   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 OTEL_SERVICE_NAME=shop ./server
   ```

Nothing is copied into the app. `example/` does all of this (`rocx build .`): `GET /hello/<name>`
counts `app.greetings`. Without the plugin in the app's list, `Otel.record!` measures nothing, and
says so once on the log.

## API

`Metric`, `Points`, `Otlp` and `Config` are plain Roc on no platform (the browser's half of an app
may import them: `browser.roc`); `Otel` is on the server's platform, which the package names (D-033).

| Function | What it does |
|---|---|
| `Metric.counter({ name, description, unit })` | A counter: the sum of what it is given. It can't go down; a negative value is dropped. |
| `Metric.histogram({ name, description, unit, buckets })` | A histogram: how many values fell in each bucket (`buckets` are upper bounds, smallest first; a value past every bound goes in the last), how many in all, and their sum. |
| `Metric.gauge({ name, description, unit })` | A gauge: the last value set for each set of attributes, negative values too. |
| `Metric.seconds` | OpenTelemetry's buckets for durations in seconds, 5 ms to 10 s. |
| `Otel.plugin({})` | The plugin: reads the `OTEL_*` settings once at start, says where the metrics go (the `otel.metrics` check, on the log), and runs the loop that adds them up and sends them. |
| `Otel.record!(instrument, value, attributes)` | Records a `Dec` value with `(key, value)` attributes. An attribute with an empty value is left out. Does nothing with metrics off. |
| `Otel.middleware({})` | Times every request it runs around ([below](#every-request)). |
| `Otel.request_duration` | The middleware's instrument, `http.server.request.duration`. |

```roc
signups = Metric.counter({ name: "app.signups", description: "Members who signed up.", unit: "{member}" })
Otel.record!(signups, 1, [("plan", "pro")])

checkout = Metric.histogram({ name: "app.checkout.duration", description: "Checkout.", unit: "s", buckets: Metric.seconds })
started = Time.now_nanos!({})
…
Otel.record!(checkout, (Time.now_nanos!({}) - started).to_dec() / 1_000_000_000, [("method", "card")])

up = Metric.gauge({ name: "app.service.up", description: "Whether the service answered (1) or not (0).", unit: "1" })
Otel.record!(up, 1, [("service", "payments")])
```

The other modules are what `Otel` is built on, and what its expects test: `Points` (the sums:
`Points.empty`, `Points.add`, `Points.limit`), `Otlp.metrics` (the sums as OTLP/HTTP
JSON) and `Config.from` (the settings the environment gives, or `Err(Off)`).

### Attributes and series

Attributes are text. Each combination of attribute values is a separate series, so keep their
values few: a user's id or a URL would make a series for each. An instrument keeps at most 2000
series (`Points.limit`) and drops new ones past that; the ones it has go on, and the log says how
many were dropped at each export (`otel: measurements were dropped`).

One name is one kind of instrument: a value recorded under a name already measured as another kind
is dropped.

## Every request

`Otel.middleware({})` records `http.server.request.duration`, a histogram in seconds, with the
attributes OpenTelemetry's HTTP conventions name:

- `http.request.method` (`_OTHER` for a method HTTP doesn't define, since a client can send any);
- `http.route`, the route's pattern from `Server.Request`'s `route` (`/posts/[id]`, never
  `/posts/42`, so each post isn't a series of its own; left out when no route matched);
- `http.response.status_code`.

Put it first, so it times the rest of the middleware too.

## Where they go

The standard variables, read as every OpenTelemetry SDK reads them (`Config`):

| Variable | What it sets |
| --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | The collector; `/v1/metrics` is added (`http://localhost:4318`). |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | The full URL, used instead when set. |
| `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_METRICS_HEADERS` | Headers, `name=value,…`, each value percent-decoded (`Authorization=Basic%20…`). The second, if set, is used instead. |
| `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES` | The service's name (or `service.name` in the attributes; `unknown_service` without either) and attributes (`key=value,…`). |
| `OTEL_METRIC_EXPORT_INTERVAL` | Milliseconds between sends (60000, at least 1000). |
| `OTEL_METRIC_EXPORT_TIMEOUT` | Milliseconds a send may take (30000). |
| `OTEL_SDK_DISABLED=true`, `OTEL_METRICS_EXPORTER=none` | Off. |

**With no endpoint, metrics are off**: nothing is measured, kept or sent. That is the default in
development.

## How it works

A value recorded is put at the front of a list in the server's memory (`Kv.push!`, under
`otel:measurements`, its newest 20,000 kept: `Otel.buffered`), so the request doesn't wait for it.
The plugin's loop (`otel.export`) takes that list each second (`Kv.take!`) and adds it to the sums
it keeps in its own memory (`Points`), oldest first; every `OTEL_METRIC_EXPORT_INTERVAL`, and once
more as the server stops, it sends them all in one request as OTLP/HTTP JSON (`Otlp`).

Counters and histograms are cumulative sums since the loop started. So a send that fails loses
nothing: the next one carries it all, and the failure is logged as a warning
(`otel: the metrics couldn't be sent`, or `otel: the collector refused the metrics` with its
status). A gauge is sent as OTLP's `gauge`, one data point per series with its last value
(`asDouble`), again at each export until it is set to another value. A restart starts the sums
again, with a new start time, which a collector reads as a counter that was reset.

**What it costs.** One `Kv.push!` per value recorded, so two for a request that records one of its
own: no database write, and nothing in the request's way. A server that records more than 20,000
values in a second loses the oldest of them.

## Logs

Nothing to add to the app: let the collector read the server's log. The log is JSON when stderr
isn't a terminal (the platform's default, `Auto`), when `ROCX_LOG=json` is set, or when the program
says `{ ..App.program(…), logs: { format: Json } }`. Each line is one JSON object:

```json
{"time":"2026-11-21T20:14:52.100Z","level":"warn","msg":"gate failed","path":"/admin","error":"no session"}
```

The collector's `filelog` receiver (in `otelcol-contrib`) turns each line into an OpenTelemetry log
record: `time` its timestamp, `level` its severity, `msg` its body, and the other fields its
attributes. Every line counts, the platform's own and a crash's included.

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

## Checked against

- `roc test packages/otel/main.roc`: instruments, sums, buckets, gauges' last values, the series
  limit (each instrument's), the state as JSON both ways, OTLP's JSON (sums, histograms, gauges),
  the variables.
- examples/uptime's tests: the plugin sends every second to a stand-in collector; the latency
  histogram, the request histogram, and a gauge that goes from 1 to 0.
- The example, built native, sending to OpenTelemetry Collector 0.165.0 (`otlp` receiver, `debug`
  exporter): sums, histograms, attributes, timestamps and the resource all read back. Also run
  against Postgres, across a restart.
- The logs configuration above, with otelcol-contrib 0.165.0, on the server's own log.

## Not yet

- **Traces.** They need to know, in `Db.all!` and `Http.fetch!`, which request they run for, without
  the app passing it by hand. Roc has no such context, so traces wait on a talk with Roc's designers.
- Up-down counters; exemplars; Prometheus's `/metrics` for pulling instead.
- A job's duration and outcome (a wrapper for `Job.define`).
