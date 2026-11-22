import pf.Middleware
import pf.Server
import pf.Log
import pf.Time

## What runs around every request (`main.roc` names `Middlewares.default`), before the page or the
## endpoint that answers it.
Middlewares := [].{

	## What every page and endpoint is handed as its `context`: who you said you are (a person's
	## id, from the `acme-person` cookie that `/me` sets), or `""`.
	Context : { me : Str }

	## The cookie that remembers who you are. Not a sign-in: anyone may say they are anyone (the
	## `notes` example signs people in).
	cookie : Str
	cookie = "acme-person"

	## Around every request: a change sent from another site's page is refused (403), then
	## `identify` hands on who you are and logs the answer.
	default : Middleware({}, Middlewares.Context)
	default = Middleware.same_origin({}).then(Middlewares.identify)

	## Reads who you are from the cookie into the context, and logs each answer: its method, path,
	## status and time, and who asked (`Log.info!`), and why, when it failed (`Log.error!`).
	identify : Middleware({}, Middlewares.Context)
	identify = Middleware.make(
		|request, {}, next!| {
			me = Server.cookie(request, Middlewares.cookie) ?? ""
			started = Time.now_millis!({})
			answer = next!(request, { me: me })
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
