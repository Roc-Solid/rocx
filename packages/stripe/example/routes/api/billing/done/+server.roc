import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../../../../Middlewares
import ../../../../Plans

middleware = Middlewares.signed_in

## GET /api/billing/done?session_id=…: for the page Checkout comes back to (/billing/done): what
## was bought, as Stripe says now (`Stripe.checkout_session!`, which keeps it too, so the account
## and the pro pages know before Stripe's events have come). Someone else's session, or none, is a
## 404.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ what : Str, subscription : Bool, paid : Bool }, Endpoint.Refusal)
get! = |{ request, context, .. }| {
	id = Server.form_fields(request.query).find_first(|field| field.name == "session_id").map_ok(|field| field.value) ?? ""
	match Stripe.checkout_session!(context.user, id) {
		Ok(session) => Ok({ what: Plans.named!(session.prices.map(|line| line.price)), subscription: session.mode == Subscription, paid: session.paid })
		Err(NotYours) => Err(NotFound)
		Err(StripeErr(why)) => Err(Status(502, why))
		Err(DbErr(why)) => Err(Status(503, why))
	}
}
