import pf.Env
import pf.Middleware
import pf.Server

## The app's middleware: `default` runs around every request (main.roc); a route file names its own,
## which runs after it.
Middlewares := [].{

	## Around every request: its answer says so.
	default : Middleware({ started : Str }, { started : Str })
	default = Middleware.headers([{ name: "x-app", value: "e2e" }])

	## A member: someone whose `member` cookie names them, handed on as `context.member`; anyone
	## else is refused (401). With `ROCX_E2E_CLOSED=yes` in the server's environment, nobody (503):
	## a route file's middleware may use what only the server has (`pf.Env`), since the browser's
	## copy of the route file leaves it out.
	member : Middleware({ started : Str }, { started : Str, member : Str })
	member = Middleware.make(
		|request, context, next!|
			if Env.var!("ROCX_E2E_CLOSED") == Ok("yes") {
				Server.refused(503, "closed")
			} else {
				match Server.cookie(request, "member") {
					Ok(name) => if (name.is_empty()) Server.refused(401, "members only") else next!(request, { started: context.started, member: name })
					Err(Missing) => Server.refused(401, "members only")
				}
			},
	)
}
