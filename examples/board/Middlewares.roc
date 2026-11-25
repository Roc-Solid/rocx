import pf.Middleware
import auth.Auth
import guard.RateLimit
import guard.Security
import guard.Guard
import Board
import Store

## What requests go through: `default` around every one; a route file names the rest
## (`middleware = Middlewares.member`), which run after it, around that route.
Middlewares := [].{

	## What `member` hands on: who is asking.
	Member : { me : Board.Person }

	## Every request: one that would change something, sent by another site's page, is refused
	## (403), and every answer carries security headers (packages/guard: a CSP that lets the page
	## run its WebAssembly, and no more).
	default : Middleware({}, {})
	default = Middleware.same_origin({}).then(Guard.security_headers(Security.defaults))

	## Someone who has joined: their person, handed on as `context.me`. Who they are is their
	## session (packages/auth, its cookie `board_session`), which joining starts: there are no
	## passwords, and anyone may be anyone, which is fine for a team's board and nothing else. The
	## session keeps the person's id on the server, so the cookie holds a random token, not an id to
	## edit. Without one, a browser asking for a page is sent to join first (and back here after);
	## anything else is refused (401). A channel's check runs it too, with the stream's cookies.
	member : Middleware({}, Middlewares.Member)
	member = Auth.required_with(
		|{}, session|
			match Store.person!(session.user) {
				Ok(me) => Ok({ me: me })
				Err(_) => Err(SignedOut)
			},
	)

	## A change to a board: a member, at most 60 at once and then one a second (packages/guard's
	## token bucket, counted for each person), so a stuck script can't flood everyone's board.
	writer : Middleware({}, Middlewares.Member)
	writer = Middlewares.member.then(Guard.rate_limit("writes", RateLimit.per_minute(60), Guard.user(|context| context.me.id, Hops(1))))
}
