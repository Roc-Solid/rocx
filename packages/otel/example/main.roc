## An app that uses packages/otel: every request timed (`http.server.request.duration`), and a
## counter of its own (`app.greetings`), sent to the collector `OTEL_EXPORTER_OTLP_ENDPOINT` names.
## Its server-only module isn't copied in by rocx build yet, so copy it by hand first:
##
##     cp ../server/Otel.roc .
##     rocx build .
app [program] { otel: "../main.roc", pf: platform "../../../server/platform/main.roc" }

import Generated/App
import Otel

## Every request timed, then the routes.
program = App.program({
	context: |started| { facts: started },
	middleware: Otel.middleware({}),
	crons: [],
})
