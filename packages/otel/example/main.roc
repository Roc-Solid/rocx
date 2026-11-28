## An app that uses packages/otel: every request timed (`http.server.request.duration`), and a
## counter of its own (`app.greetings`), sent to the collector `OTEL_EXPORTER_OTLP_ENDPOINT` names
## by the package's plugin (`rocx dev`).
app [program] { otel: "../main.roc", pf: platform "../../../server/platform/main.roc" }

import Generated/App
import otel.Otel

## Every request timed (routes/+middleware.roc), then the routes.
program = App.program({
	init!: |started| Ok({ facts: started }),
	plugins: [Otel.plugin({})],
})
