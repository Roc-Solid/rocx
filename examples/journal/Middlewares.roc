import pf.Middleware
import pf.Random
import pf.Server
import guard.RateLimit
import guard.Security
import guard.Guard

## The journal's middleware: what runs around its answers. `default` runs around every request
## (main.roc names it); a route file names its own (`middleware = Middlewares.reactions_limit`),
## which runs inside it, around that route alone.
Middlewares := [].{

	## What every route is handed: the reader, by the `reader` cookie the journal gives each browser
	## (`""` until it has one). Reactions are remembered and rate limited by it.
	Context : { reader : Str }

	## Around every request: a change sent by another site's page is refused; every answer has
	## guard's security headers; and the reader is known.
	default : Middleware({}, Middlewares.Context)
	default =
		Middleware.same_origin({})
			.then(Middlewares.security)
			.then(Middlewares.reader)

	## guard's security headers (a Content-Security-Policy that lets the page run only its own
	## scripts and wasm, and the rest), but on the OpenAPI page, which loads Scalar from jsDelivr.
	security : Middleware({}, {})
	security = Middleware.make(
		|request, context, next!|
			if request.path == "/openapi.html" {
				next!(request, context)
			} else {
				Middleware.run!(Guard.security_headers(Security.defaults), request, context, next!)
			},
	)

	## The reader: their `reader` cookie, handed on as `context.reader`. A browser's first page gives
	## it one (random, kept a year), for its next requests; until then the reader is `""`.
	reader : Middleware({}, Middlewares.Context)
	reader = Middleware.make(
		|request, _, next!|
			match Server.cookie(request, "reader") {
				Ok(id) if Middlewares.is_reader(id) => next!(request, { reader: id })
				_ =>
					if request.method == "GET" and Server.wants_html(request) {
						answer = next!(request, { reader: "" })
						match Random.seed_u64!() {
							Ok(seed) => Server.set_cookie(answer, "reader", "r${seed.to_str()}", { ..Server.cookie_defaults, max_age_s: 365 * 86400 })
							Err(_) => answer
						}
					} else {
						next!(request, { reader: "" })
					}
			},
	)

	## Whether a cookie's value is a reader's id as `reader` makes them: `r` and digits.
	is_reader : Str -> Bool
	is_reader = |id| id.starts_with("r") and id.count_utf8_bytes() > 1 and id.count_utf8_bytes() < 24 and id.drop_prefix("r").to_utf8().all(|b| b >= '0' and b <= '9')

	## Reactions sent: 20 a minute from each reader, counted by guard (a token bucket, so a burst of
	## 20, then one every 3 s). By the reader's cookie, or, for a request without one, by its address:
	## the connection's (`request.peer`), or behind a proxy the address it saw (`Hops(1)`: the last
	## in `X-Forwarded-For`). Reading the counts isn't limited: every post's page does it.
	reactions_limit : Middleware(Middlewares.Context, Middlewares.Context)
	reactions_limit = Middlewares.writes_only(Guard.rate_limit("reactions", RateLimit.per_minute(20), Guard.user(|context| context.reader, Hops(1))))

	## `guard` around requests that change something (`POST`, …); the rest pass by it.
	writes_only : Middleware(c, c) -> Middleware(c, c)
	writes_only = |guard| Middleware.make(|request, context, next!| if (Server.changes(request)) Middleware.run!(guard, request, context, next!) else next!(request, context))
}

expect Middlewares.is_reader("r1234567890") and !Middlewares.is_reader("r") and !Middlewares.is_reader("admin")
