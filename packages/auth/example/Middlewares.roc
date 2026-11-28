import pf.Log
import pf.Middleware
import pf.Server
import auth.Auth
import auth.Roles
import Accounts

## What requests go through, named by directory (D-103): `anyone` around the `(anyone)` group (the
## home page), `signed_in` around the `(signed-in)` group; a group adds nothing to the path. A post
## from another site's page the platform refuses first.
Middlewares := [].{

	## Who a signed-in request is: the user it acts as (their id and address), its session's id, and
	## who really signed in (an admin impersonating someone: `Auth.impersonate!`); the roles the user
	## holds now (`Roles.current!`), and whether who really signed in is an admin (`ADMIN_EMAILS`).
	## What they may do is `Policy.can`'s to say, from these.
	Me : { user : Str, email : Str, session : Str, real_user : Str, roles : List(Accounts.Role), admin : Bool }

	## Whether a request is signed in, for a page anyone may see.
	Visitor : { signed : Auth.Signed }

	## Signed-in requests only, with their user's row and roles read (`Auth.required_with`): a
	## page's GET goes to the sign-in page (and comes back after), anything else is a 401; a session
	## whose user is gone is ended, and answered the same. Roles that can't be read just now are a
	## 503, not none: a request is never let through as someone with less than they hold.
	signed_in : Middleware({}, Middlewares.Me)
	signed_in = Auth.required_with(
		|{}, session|
			match Auth.user!(session.user) {
				Ok(user) => {
					held : Try(List(Accounts.Role), [DbErr(Str), BadRow(Str)])
					held = Roles.current!(user.id)
					match held {
						Ok(roles) => {
							admin = if (session.real_user == user.id) Accounts.listed!(user.email) else Accounts.admin!(session.real_user)
							Ok({ user: user.id, email: user.email, session: session.id, real_user: session.real_user, roles, admin })
						}
						Err(DbErr(why)) | Err(BadRow(why)) => {
							Log.error!("accounts: roles couldn't be read", { error: why })
							Err(Answer(Server.refused(503, "Your account couldn't be read just now. Try again in a minute.")))
						}
					}
				}
				_ => Err(SignedOut)
			},
	)

	## Anyone, signed in or not.
	anyone : Middleware({}, Middlewares.Visitor)
	anyone = Auth.optional(|{}, signed| { signed: signed })
}
