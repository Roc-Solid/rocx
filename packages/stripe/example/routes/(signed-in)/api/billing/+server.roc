import pf.Server
import pf.Endpoint
import stripe.Stripe
import ../../../../Middlewares
import ../../../../Plans

## GET /api/billing: what the account page shows of billing that only Stripe knows, asked of it
## each time: the card the subscription is charged to (`Stripe.card!`: "visa ending 4242, expires
## 12/2034", "" for none), and the invoices, the newest first (`Stripe.invoices!`), each with its
## number, status, what was paid, its day and its PDF. Stripe out of reach is a 502.
get! : { request : Server.Request, params : {}, context : Middlewares.Me } => Try({ card : Str, invoices : List({ id : Str, number : Str, status : Str, amount_paid : I64, currency : Str, day : Str, pdf : Str }) }, Endpoint.Refusal)
get! = |{ context, .. }| {
	card =
		match Stripe.card!(context.user) {
			Ok(found) => "${found.brand} ending ${found.last4}, expires ${found.exp_month.to_str()}/${found.exp_year.to_str()}"
			Err(NoCard) => ""
			Err(StripeErr(why)) => return Err(Status(502, why))
			Err(DbErr(why)) => return Err(Status(503, why))
		}
	invoices =
		match Stripe.invoices!(context.user) {
			Ok(listed) => listed.map(|invoice| { id: invoice.id, number: invoice.number, status: invoice.status, amount_paid: invoice.amount_paid, currency: invoice.currency, day: Plans.day(invoice.created_ms), pdf: invoice.pdf_url })
			Err(StripeErr(why)) => return Err(Status(502, why))
			Err(DbErr(why)) => return Err(Status(503, why))
		}
	Ok({ card: card, invoices: invoices })
}
