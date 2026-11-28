import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../../../../../Middlewares

## POST /api/billing/cancel: the subscription ends at its period's end (`Stripe.cancel!`), and the
## account page says so at once; back to /account. Someone with no subscription that hasn't ended
## goes there too.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ context, .. }|
	match Stripe.cancel!(context.user) {
		Ok(_) | Err(NotSubscribed) => Err(Answer(Server.redirect("/account")))
		Err(StripeErr(why)) => Err(Status(502, why))
		Err(DbErr(why)) => Err(Status(503, why))
	}
