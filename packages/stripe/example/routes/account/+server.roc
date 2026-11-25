import pf.Db
import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../../Middlewares
import ../../Plans

middleware = Middlewares.signed_in

## GET /account: the signed-in user's address; their subscription as the package keeps it (its
## plan, its status as Stripe writes it, the day it renews or ends, and whether it ends then; ""
## for none); whether they have a customer at Stripe (so a portal to go to); and their orders.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ email : Str, plan : Str, status : Str, until : Str, ending : Bool, customer : Bool, orders : List({ id : Str, what : Str, day : Str }) }, Endpoint.Refusal)
get! = |{ context, .. }| {
	orders : Try(List({ session_id : Str, what : Str, created_at : I64 }), _)
	orders = Db.all!("select session_id, what, created_at from orders where user_id = $1 order by created_at desc", [Text(context.user)])
	listed = (orders ?? []).map(|order| { id: order.session_id, what: order.what, day: Plans.day(order.created_at) })
	customer = Stripe.customer!(context.user).is_ok()
	match Stripe.subscription!(context.user) {
		Ok(subscription) => {
			ending = subscription.cancel_at_period_end or subscription.cancel_at_ms != 0 or Stripe.ended(subscription.status)
			until = if (subscription.cancel_at_ms != 0) subscription.cancel_at_ms else subscription.current_period_end_ms
			Ok({ email: context.email, plan: Plans.named!(subscription.items.map(|item| item.price)), status: Stripe.status_name(subscription.status), until: Plans.day(until), ending: ending, customer: customer, orders: listed })
		}
		Err(NotSubscribed) => Ok({ email: context.email, plan: "", status: "", until: "", ending: Bool.False, customer: customer, orders: listed })
		Err(DbErr(why)) => Err(Status(503, why))
	}
}
