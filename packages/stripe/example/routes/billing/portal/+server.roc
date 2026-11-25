import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../../../Middlewares

middleware = Middlewares.signed_in

## POST /billing/portal: off to Stripe's Customer Portal (their plan, their card, their invoices,
## cancelling), coming back to /account. Someone who has never checked out goes to the pricing page.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ context, .. }|
	match Stripe.portal!(context.user, "/account") {
		Ok(url) => Err(Answer(Server.redirect(url)))
		Err(NoCustomer) => Err(Answer(Server.redirect("/")))
		Err(StripeErr(why)) => Err(Status(502, why))
		Err(DbErr(why)) => Err(Status(503, why))
	}
