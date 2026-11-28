import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../../../../../Middlewares

## POST /api/billing/keep: a subscription set to end goes on after all (`Stripe.keep!`); back to
## /account.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : {} } => Try({}, Endpoint.Refusal)
post! = |{ context, .. }|
	match Stripe.keep!(context.user) {
		Ok(_) | Err(NotSubscribed) => Err(Answer(Server.redirect("/account")))
		Err(StripeErr(why)) => Err(Status(502, why))
		Err(DbErr(why)) => Err(Status(503, why))
	}
