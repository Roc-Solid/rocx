import pf.Middleware
import auth.Auth

## What requests go through: `default` around every one (main.roc names it); a route file names
## one of the others (`middleware = Middlewares.signed_in`), which runs inside it.
Middlewares := [].{

	## Who a signed-in request is: the app's id for its user, and its session's.
	Me : { user : Str, session : Str }

	## Whether a request is signed in, for a page anyone may see.
	Visitor : { signed : Auth.Signed }

	## Around every request: a post from another site is refused.
	default : Middleware({}, {})
	default = Middleware.same_origin({})

	## Signed-in requests only: a page's GET goes to the sign-in page (and comes back after), anything
	## else is a 401.
	signed_in : Middleware({}, Middlewares.Me)
	signed_in = Auth.required(|{}, session| { user: session.user, session: session.id })

	## Anyone, signed in or not.
	anyone : Middleware({}, Middlewares.Visitor)
	anyone = Auth.optional(|{}, signed| { signed: signed })
}
