import pf.Middleware
import pf.Server
import pf.Log
import pf.Time
import Session

## What runs around every request (`main.roc` names `Middlewares.default`), before the page or the
## endpoint that answers it.
Middlewares := [].{

	## Around every request: a change sent from another site's page is refused (403); then, when the
	## diary has a password, someone signed in (or the way to sign in); then each answer is logged.
	default : Middleware({}, {})
	default = Middleware.same_origin({}).then(Middlewares.gate).then(Middlewares.logged)

	## When `PLATE_PASSWORD` is set: a browser asking for a page without a session is sent to sign
	## in, and back after; anything else is refused (401). The sign-in page itself, and the
	## runtime's files, are for anyone.
	gate : Middleware({}, {})
	gate = Middleware.make(
		|request, context, next!|
			if Middlewares.is_public(request.path) or Session.open!({}) or Session.signed_in!(request) {
				next!(request, context)
			} else if Server.wants_html(request) and request.method == "GET" {
				Server.redirect("/sign-in?then=${Server.encode_segment(Middlewares.here(request))}")
			} else {
				Server.refused(401, "Sign in first, at /sign-in.")
			},
	)

	## The paths anyone may ask for.
	is_public : Str -> Bool
	is_public = |path| path == "/sign-in" or path.starts_with("/rocx/") or path.starts_with("/__")

	## Where a request asked for, its query too.
	here : Server.Request -> Str
	here = |request| if (request.query.is_empty()) request.path else "${request.path}?${request.query}"

	## Logs each answer: its method, path, status and time (`Log.info!`), and why, when it failed
	## (`Log.error!`).
	logged : Middleware({}, {})
	logged = Middleware.make(
		|request, context, next!| {
			started = Time.now_millis!({})
			answer = next!(request, context)
			ms = Time.now_millis!({}) - started
			if answer.status >= 500 {
				Log.error!("failed", { method: request.method, path: request.path, status: answer.status, ms, error: Server.body_text(answer) })
			} else {
				Log.info!("answered", { method: request.method, path: request.path, status: answer.status, ms })
			}
			answer
		},
	)
}

expect Middlewares.is_public("/sign-in")
expect Middlewares.is_public("/rocx/start.js")
expect !Middlewares.is_public("/")
expect !Middlewares.is_public("/sign-in-elsewhere")
