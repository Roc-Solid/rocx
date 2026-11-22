import pf.Middleware
import pf.Server
import Otel
import Session

## What runs around Acme Status's answers. `default` runs around every request (main.roc names it);
## a route file names its own (`middleware = Middlewares.admin`), which runs inside it.
Middlewares := [].{

	## Around every request: timed for the metrics (first, so it times the rest too); a change sent
	## by another site's page refused; and headers that keep the pages out of frames and the browser
	## from guessing types.
	default : Middleware({}, {})
	default =
		Otel.middleware({})
			.then(Middleware.same_origin({}))
			.then(
				Middleware.headers([
					{ name: "x-content-type-options", value: "nosniff" },
					{ name: "x-frame-options", value: "DENY" },
					{ name: "referrer-policy", value: "same-origin" },
				]),
			)

	## The admin's pages and actions, and the jobs page: only with a session (Session.roc). A
	## browser without one is sent to sign in, and back here after; anything else is refused (401).
	admin : Middleware({}, {})
	admin = Middleware.make(
		|request, context, next!|
			if Session.signed_in!(request) {
				next!(request, context)
			} else if Server.wants_html(request) and request.method == "GET" {
				Server.redirect("/admin/sign-in?next=${Server.encode_segment(request.path)}")
			} else {
				Server.refused(401, "Sign in to the admin first: /admin/sign-in")
			},
	)
}
