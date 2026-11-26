import pf.Middleware
import auth.Auth
import Accounts

## What requests go through, named by directory (D-103): `anyone` around the `(anyone)` group (the
## home page), `signed_in` around the `(signed-in)` group; a group adds nothing to the path. A post
## from another site's page the platform refuses first.
Middlewares := [].{

	## Who a signed-in request is: the user it acts as (their id and address), its session's id, and
	## who really signed in (an admin impersonating someone: `Auth.impersonate!`).
	Me : { user : Str, email : Str, session : Str, real_user : Str }

	## Whether a request is signed in, for a page anyone may see.
	Visitor : { signed : Auth.Signed }

	## Signed-in requests only, with their user's row read (`Auth.required_with`): a page's GET goes
	## to the sign-in page (and comes back after), anything else is a 401; a session whose user is
	## gone is ended, and answered the same.
	signed_in : Middleware({}, Middlewares.Me)
	signed_in = Auth.required_with(
		|{}, session|
			match Accounts.user!(session.user) {
				Ok(Found(user)) => Ok({ user: user.id, email: user.email, session: session.id, real_user: session.real_user })
				_ => Err(SignedOut)
			},
	)

	## Anyone, signed in or not.
	anyone : Middleware({}, Middlewares.Visitor)
	anyone = Auth.optional(|{}, signed| { signed: signed })
}
