import pf.Middleware
import auth.Auth
import otel.Otel

## What runs around the app's answers, named by directory (D-103): `default` runs around every
## request (routes/+middleware.roc); `admin` around the admin's routes (routes/(admin)/, a group
## that adds nothing to their paths), inside it, and around the jobs page (main.roc gives it).
Middlewares := [].{

	## Around every request (a change sent by another site's page the platform refuses first): timed
	## for the metrics (first, so it times the rest too), and headers that keep the pages out of
	## frames and the browser from guessing types.
	default : Middleware({}, {})
	default =
		Otel.middleware({})
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
