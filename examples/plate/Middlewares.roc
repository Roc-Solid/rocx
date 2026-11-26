import pf.Middleware
import pf.Server
import pf.Log
import pf.Time
import auth.Auth
import Session

## What runs around every request (`main.roc` names `Middlewares.default`), before the page or the
## endpoint that answers it.
Middlewares := [].{

	## Around every request: a change sent from another site's page is refused (403); then, when the
	## diary has a password, someone signed in (or the way to sign in); then each answer is logged.
	default : Middleware({}, {})
	default = Middleware.same_origin({}).then(Middlewares.gate).then(Middlewares.logged)

	## When `PLATE_PASSWORD` is set, packages/auth's `Auth.required` (`signed_in`): a browser asking
	## for a page without a session is sent to sign in (`/sign-in?then=…`), and back after; anything
	## else is refused (401). The sign-in page and its endpoint (`/api/sign-in`), the auth plugin's
	## endpoints (signing out) and the runtime's files are for anyone. Without a password, everything
	## is.
	gate : Middleware({}, {})
	gate = Middleware.make(
		|request, context, next!|
			if Middlewares.is_public(request.path) or Session.open!({}) {
				next!(request, context)
			} else {
				Middleware.run!(Middlewares.signed_in, request, context, next!)
			},
	)

	## Someone signed in (a session of packages/auth's), or the way to sign in.
	signed_in : Middleware({}, {})
	signed_in = Auth.required(|context, _session| context)

	## The paths anyone may ask for.
	is_public : Str -> Bool
	is_public = |path| path == "/sign-in" or path == "/api/sign-in" or path.starts_with("/auth/") or path.starts_with("/rocx/") or path.starts_with("/__")

	## Logs each answer: its method, path, status and time (`Log.info!`), and what it said when it
	## failed (`Log.error!`): the plain message the client got; why the database failed is logged
	## where it happened (`Store.refusal!`).
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
expect Middlewares.is_public("/api/sign-in")
expect Middlewares.is_public("/rocx/start.js")
expect !Middlewares.is_public("/")
expect !Middlewares.is_public("/sign-in-elsewhere")
expect Middlewares.is_public("/auth/sign-out")
expect !Middlewares.is_public("/authors")
