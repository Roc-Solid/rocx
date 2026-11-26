import pf.Middleware
import pf.Server
import pf.Log
import pf.Time
import auth.Auth
import Session

## What runs around the requests, named by directory (D-103): `default` around every one
## (routes/+middleware.roc), and `gate` around the diary (routes/(diary)/, a group that adds nothing
## to the paths: everything but the sign-in page and its endpoint).
Middlewares := [].{

	## Around every request (a change sent from another site's page the platform refuses first, 403):
	## each answer logged.
	default : Middleware({}, {})
	default = Middlewares.logged

	## The diary, when `PLATE_PASSWORD` is set: packages/auth's `Auth.required` (`signed_in`): a
	## browser asking for a page without a session is sent to sign in (`/sign-in?then=…`), and back
	## after; anything else is refused (401). Without a password, everyone. The sign-in page and its
	## endpoint sit outside its group, and the auth plugin's endpoints (signing out) and the
	## runtime's files outside routes/: they are for anyone.
	gate : Middleware({}, {})
	gate = Middleware.make(
		|request, context, next!|
			if Session.open!({}) {
				next!(request, context)
			} else {
				Middleware.run!(Middlewares.signed_in, request, context, next!)
			},
	)

	## Someone signed in (a session of packages/auth's), or the way to sign in.
	signed_in : Middleware({}, {})
	signed_in = Auth.required(|context, _session| context)

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
