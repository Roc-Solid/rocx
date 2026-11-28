import pf.Db
import pf.Log
import pf.Time
import stripe.Stripe
import Plans

## The app's own part of Stripe's events (`Stripe.webhook_route!`'s `on_event!`, given in
## routes/stripe/webhook/+server.roc), after the package has kept what each says, in the same
## transaction.
Billing := [].{

	## An e-book bought (a Checkout Session in payment mode, paid; or paid later, for a payment
	## method that takes days) becomes an order: written once, as its key is the session, and the
	## event is handled once anyway. A renewal that failed is on the log: a real app would mail them
	## (queue a job, here, so the mail goes once the event is kept). An `Err` rolls the event back,
	## and Stripe sends it again later.
	on_event! : Stripe.Event => Try({}, Str)
	on_event! = |event|
		match event.about {
			Session(session) if session.mode == Payment and session.paid and (event.type == "checkout.session.completed" or event.type == "checkout.session.async_payment_succeeded") =>
				ordered!(event.user, session).map_err(|DbErr(why)| "the order couldn't be written: ${why}")
			Invoice(invoice) if event.type == "invoice.payment_failed" => {
				Log.warn!("billing: a payment failed", { user: event.user, invoice: invoice.id, attempts: invoice.attempt_count, pay_at: invoice.hosted_url })
				Ok({})
			}
			_ => Ok({})
		}
}

## The order for a paid Checkout Session: what it was for, its total and currency.
ordered! : Str, Stripe.Session => Try({}, [DbErr(Str)])
ordered! = |user, session| {
	what = Plans.named!(session.prices.map(|line| line.price))
	_ = Db.run!(
		"insert into orders (session_id, user_id, what, amount, currency, created_at) values ($1, $2, $3, $4, $5, $6) on conflict do nothing",
		[Text(session.id), Text(user), Text(what), Int(session.amount_total), Text(session.currency), Int(Time.now_millis!({}).to_i64_wrap())],
	)?
	Ok({})
}
