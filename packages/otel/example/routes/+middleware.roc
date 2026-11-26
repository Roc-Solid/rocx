import otel.Otel

## Every request timed: `http.server.request.duration`, by method, route and status.
middleware = Otel.middleware({})
