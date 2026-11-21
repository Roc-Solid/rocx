## OpenTelemetry metrics for Roc Solid apps: instruments (`Metric`), what their measurements add up
## to (`Points`), and those sums as OTLP/HTTP JSON (`Otlp`), sent where the standard `OTEL_*`
## environment variables say (`Config`). This is the logic, plain Roc on no platform; the actor
## that keeps the sums and sends them, and the middleware that times every request, import the
## server platform (`server/Otel.roc`). See README.md.
package [Config, Metric, Otlp, Points] {}
