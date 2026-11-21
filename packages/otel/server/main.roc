## OpenTelemetry on the server platform: `record!` a measurement, the middleware that times every
## request, and the actor that keeps each instrument's sums and sends them (`Otel`). A package that
## names the server platform, so that `roc check packages/otel/server/main.roc` checks it on its
## own. An app copies it in by hand for now: see ../README.md, "Setup".
package [Otel] { otel: "../main.roc", pf: platform "../../../server/platform/main.roc" }
