import pf.Middleware
import pf.Server
import Generated/Paths

## The site's middleware. `default` runs around every request (`server.roc`); a route file names its
## own (`middleware = Middlewares.member`), which runs after it, around that route.
Middlewares := [].{

	## Around every request: one that would change something, sent by another site's page, is
	## refused (403); every answer tells the browser not to guess a file's type, and to send where it
	## came from only to this site.
	default : Middleware({ facts : Str }, { facts : Str })
	default = Middleware.same_origin({}).then(
		Middleware.headers([
			{ name: "x-content-type-options", value: "nosniff" },
			{ name: "referrer-policy", value: "same-origin" },
		]),
	)

	## A member: someone whose `member` cookie names them, handed on as `context.member`. A browser
	## that isn't is sent to join; anything else is refused (401).
	member : Middleware({ facts : Str }, { facts : Str, member : Str })
	member = Middleware.make(
		|request, context, next!|
			match Server.cookie(request, "member") {
				Ok(name) =>
					if name.is_empty() {
						refuse(request)
					} else {
						next!(request, { facts: context.facts, member: name })
					}
				Err(Missing) => refuse(request)
			},
	)

	## Not a member yet: the joining page. A member is sent on to the members' page.
	visitor : Middleware({ facts : Str }, { facts : Str })
	visitor = Middleware.make(
		|request, context, next!|
			match Server.cookie(request, "member") {
				Ok(name) => if (name.is_empty()) next!(request, context) else Server.redirect(Paths.members)
				Err(Missing) => next!(request, context)
			},
	)
}

refuse : Server.Request -> Server.Response
refuse = |request| if (Server.wants_html(request)) Server.redirect(Paths.members_join) else Server.refused(401, "members only: join at ${Paths.members_join}")
