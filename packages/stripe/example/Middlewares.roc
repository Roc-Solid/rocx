import pf.Middleware
import pf.Server
import auth.Auth
import stripe.Stripe
import Accounts
import Plans

## What requests go through, named by directory (D-103): each group's `+middleware.roc` names one,
## `(anyone)` (the pricing page), `(signed-in)` (the account and billing), `(readers)` (the e-book)
## and `(subscribers)` (Pro); a group adds nothing to the path. A post from another site's page the
## platform refuses first; Stripe's webhook has no `Origin`, so it goes through.
Middlewares := [].{

	## Who a signed-in request is: their user's id and address.
	Me : { user : Str, email : Str }

	## Whether a request is signed in, for a page anyone may see.
	Visitor : { signed : Auth.Signed }

	## Signed-in requests only, with their user's row read (`Auth.required_with`): a page's GET goes
	## to the sign-in page (and comes back after), anything else is a 401.
	signed_in : Middleware({}, Middlewares.Me)
	signed_in = Auth.required_with(
		|{}, session|
			match Accounts.user!(session.user) {
				Ok(Found(user)) => Ok({ user: user.id, email: user.email })
				_ => Err(SignedOut)
			},
	)

	## Subscribers only: signed in, as `signed_in`, with a subscription that is paid for
	## (`Stripe.subscribed!`: active, trialing, or past due while Stripe tries the card again).
	## Anyone else goes to the pricing page.
	subscribers : Middleware({}, Middlewares.Me)
	subscribers = Auth.required_with(
		|{}, session|
			match Accounts.user!(session.user) {
				Ok(Found(user)) if Stripe.subscribed!(user.id) => Ok({ user: user.id, email: user.email })
				Ok(Found(_)) => Err(Answer(Server.redirect("/?subscribe=1")))
				_ => Err(SignedOut)
			},
	)

	## Readers of the e-book only: signed in, as `signed_in`, and they have paid for it
	## (`Stripe.paid_for!`, its price). Anyone else goes to the pricing page.
	readers : Middleware({}, Middlewares.Me)
	readers = Auth.required_with(
		|{}, session|
			match Accounts.user!(session.user) {
				Ok(Found(user)) if Stripe.paid_for!(user.id, Plans.ebook!({})) => Ok({ user: user.id, email: user.email })
				Ok(Found(_)) => Err(Answer(Server.redirect("/")))
				_ => Err(SignedOut)
			},
	)

	## Anyone, signed in or not.
	anyone : Middleware({}, Middlewares.Visitor)
	anyone = Auth.optional(|{}, signed| { signed: signed })
}
