## OpenTelemetry metrics for Roc Solid apps: instruments (`Metric`), what their measurements add up
## to (`Points`), and those sums as OTLP/HTTP JSON (`Otlp`), sent where the standard `OTEL_*`
## environment variables say (`Config`), all plain Roc on no platform; and the plugin that measures,
## adds up and sends, with the middleware that times every request (`Otel`), on the server's
## platform, which the package names (`browser.roc` lists the rest for the browser's half of an
## app, D-033). See README.md.
package [Config, Metric, Otel, Otlp, Points] { pf: platform "../../server/platform/main.roc" }
