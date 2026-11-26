import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../../../../Middlewares
import ../../../../Plans

middleware = Middlewares.signed_in

## POST /api/billing/checkout, from a plan's button (`price`): off to Stripe's Checkout for it,
## coming back to /billing/done once it is paid, or to / if they turn back. A subscription or a
## payment as the plan is, never as the form says; someone subscribed already changes plan in the
## portal (their account page). A price the page doesn't offer is a 400; Stripe refusing, or out of
## reach, a 502.
post! : { request : Server.Request, params : {}, context : Middlewares.Me, body : { price : Str } } => Try({}, Endpoint.Refusal)
post! = |{ context, body, .. }|
	match Plans.of!(body.price) {
		Err(NotFound) => Err(BadRequest("There is no such plan."))
		Ok(plan) if plan.subscription and Stripe.subscribed!(context.user) => Err(Answer(Server.redirect("/account")))
		Ok(plan) => {
			bought = Stripe.checkout!({
				user: context.user,
				email: context.email,
				mode: if (plan.subscription) Subscription else Payment,
				prices: [{ price: plan.price, quantity: 1 }],
				success_url: "/billing/done",
				cancel_url: "/",
			})
			match bought {
				Ok(url) => Err(Answer(Server.redirect(url)))
				Err(StripeErr(why)) => Err(Status(502, why))
				Err(DbErr(why)) => Err(Status(503, why))
			}
		}
	}
