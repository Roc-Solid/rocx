import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../../../../../Middlewares

## POST /api/billing/card: off to Stripe's portal, opened at changing the card
## (`Stripe.card_portal!`), coming back to /account once it is changed. Someone who has never
## checked out goes to the pricing page.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ context, .. }|
	match Stripe.card_portal!(context.user, "/account") {
		Ok(url) => Err(Answer(Server.redirect(url)))
		Err(NoCustomer) => Err(Answer(Server.redirect("/")))
		Err(StripeErr(why)) => Err(Status(502, why))
		Err(DbErr(why)) => Err(Status(503, why))
	}
