import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../Accounts
import ../Middlewares
import ../Plans

middleware = Middlewares.anyone

## GET /: what the pricing page shows: who is signed in ("" for nobody), what there is to buy, and
## the plan they are subscribed to ("" for none).
get! : { request : Server.Request, params : {}, context : Middlewares.Visitor } => Try({ email : Str, plans : List({ name : Str, price : Str, subscription : Bool, cost : Str, blurb : Str }), current : Str }, Endpoint.Refusal)
get! = |{ context, .. }| {
	plans = Plans.all!({})
	match context.signed {
		SignedIn(session) =>
			match Accounts.user!(session.user) {
				Ok(Found(user)) => {
					current =
						match Stripe.subscription!(user.id) {
							Ok(subscription) if Stripe.paying(subscription.status) => Plans.named!(subscription.items.map(|item| item.price))
							_ => ""
						}
					Ok({ email: user.email, plans: plans, current: current })
				}
				_ => Ok({ email: "", plans: plans, current: "" })
			}
		SignedOut => Ok({ email: "", plans: plans, current: "" })
	}
}
