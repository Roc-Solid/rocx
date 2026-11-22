import pf.Middleware
import pf.Server
import guard.RateLimit
import guard.Security
import Guard
import Board
import Store

## What requests go through: `default` around every one; a route file names the rest
## (`middleware = Middlewares.member`), which run after it, around that route.
Middlewares := [].{

	## What `member` hands on: who is asking.
	Member : { me : Board.Person }

	## The cookie that says who someone is: their person's id, set when they join (no passwords:
	## anyone may be anyone, which is fine for a team's board and nothing else).
	cookie : Str
	cookie = "acme_board_person"

	## Every request: one that would change something, sent by another site's page, is refused
	## (403), and every answer carries security headers (packages/guard: a CSP that lets the page
	## run its WebAssembly, and no more).
	default : Middleware({}, {})
	default = Middleware.same_origin({}).then(Guard.security_headers(Security.defaults))

	## Someone who has joined: their person, handed on as `context.me`. A browser asking for a page
	## is sent to join first (and back here after); anything else is refused (401).
	member : Middleware({}, Middlewares.Member)
	member = Middleware.make(
		|request, {}, next!|
			match Server.cookie(request, Middlewares.cookie) {
				Ok(id) =>
					match Store.person!(id) {
						Ok(me) => next!(request, { me: me })
						Err(_) => refuse(request)
					}
				Err(Missing) => refuse(request)
			},
	)

	## A change to a board: a member, at most 60 at once and then one a second (packages/guard's
	## token bucket, counted for each person), so a stuck script can't flood everyone's board.
	writer : Middleware({}, Middlewares.Member)
	writer = Middlewares.member.then(Guard.rate_limit("writes", RateLimit.per_minute(60), Guard.user(|context| context.me.id, Hops(1))))
}

## Not a member: a browser's page to the joining page, which sends it back here after.
refuse : Server.Request -> Server.Response
refuse = |request|
	if Server.wants_html(request) and request.method == "GET" {
		Server.redirect("/join?then=${Server.encode_segment(if (request.query.is_empty()) request.path else "${request.path}?${request.query}")}")
	} else {
		Server.refused(401, "Join first, at /join.")
	}
