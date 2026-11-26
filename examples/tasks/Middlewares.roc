import pf.Middleware
import pf.Server
import pf.Log
import pf.Time
import auth.Auth

## What runs around every request (`main.roc` names `Middlewares.default`), before the page or the
## endpoint that answers it.
Middlewares := [].{

	## What every page and endpoint is handed as its `context`: who you said you are (a person's
	## id, the user of the session `/me` starts), or `""`.
	Context : { me : Str }

	## Around every request: a change sent from another site's page is refused (403), then
	## `identify` hands on who you are, and `logged` logs the answer.
	default : Middleware({}, Middlewares.Context)
	default = Middleware.same_origin({}).then(Middlewares.identify).then(Middlewares.logged)

	## Reads who you are from the request's session (packages/auth, its cookie `tasks_session`) into
	## the context: the person picked at `/me`, or `""` for nobody. It is not a sign-in: anyone may
	## pick anyone (the `notes` example signs people in). The session keeps the person's id on the
	## server, so the cookie holds a random token, not a name to edit.
	identify : Middleware({}, Middlewares.Context)
	identify = Auth.optional(
		|{}, signed|
			match signed {
				SignedIn(session) => { me: session.user }
				SignedOut => { me: "" }
			},
	)

	## Logs each answer: its method, path, status and time, and who asked (`Log.info!`), and what it
	## said when it failed (`Log.error!`): the plain message the client got; why the database failed
	## is logged where it happened (`Store.refusal!`).
	logged : Middleware(Middlewares.Context, Middlewares.Context)
	logged = Middleware.make(
		|request, context, next!| {
			me = context.me
			started = Time.now_millis!({})
			answer = next!(request, context)
			ms = Time.now_millis!({}) - started
			if answer.status >= 500 {
				Log.error!("failed", { method: request.method, path: request.path, status: answer.status, ms, me, error: Server.body_text(answer) })
			} else {
				Log.info!("answered", { method: request.method, path: request.path, status: answer.status, ms, me })
			}
			answer
		},
	)
}
