import pf.Middleware
import auth.Auth
import otel.Otel

## What runs around the app's answers. `default` runs around every request (main.roc names it);
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

	## The admin's pages and actions, and the jobs page: only with the admin's session
	## (packages/auth's `Auth.required`; Session.roc starts it). A browser without one is sent to sign
	## in (`/admin/sign-in?then=…`), and back here after; anything else is refused (401).
	admin : Middleware({}, {})
	admin = Auth.required(|context, _session| context)
}
