import pf.Middleware
import pf.Server
import auth.Auth
import guard.RateLimit
import guard.Security
import guard.Guard
import Board
import Store

## What requests go through: `default` around every one (routes/+middleware.roc); `member` around
## the boards (routes/(members)/+middleware.roc), and `writes` around a board's changes (the
## `(writes)` group in api/b/[board]/), each inside the one before (D-103).
Middlewares := [].{

	## What `member` hands on: who is asking.
	Member : { me : Board.Person }

	## Every request: every answer carries security headers (packages/guard: a CSP that lets the page
	## run its WebAssembly, and no more). One that would change something, sent by another site's
	## page, the platform refuses (403) before it.
	default : Middleware({}, {})
	default = Guard.security_headers(Security.defaults)

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

	## A change to a board, inside `member`: at most 60 at once and then one a second
	## (packages/guard's token bucket, counted for each person), so a stuck script can't flood
	## everyone's board. Reads pass by it.
	writes : Middleware(Middlewares.Member, Middlewares.Member)
	writes = Middleware.when(Server.changes, Guard.rate_limit("writes", RateLimit.per_minute(60), Guard.user(|context| context.me.id, Hops(1))))
}
