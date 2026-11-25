import pf.Db

## packages/stripe's statements, the same on SQLite and on Postgres (its tables keep times as
## milliseconds, given here, so no statement needs `now()`): the app's users' customers, the Checkout
## Sessions, the subscriptions as Stripe's events last said, and the events handled. Each is a
## statement, so inside `Db.transaction!` it is part of the transaction (the webhook's). Errors are
## open unions, so a body can `?` them beside the app's own.
StripeStore := [].{

	## A Checkout Session as its row has it: its prices as JSON (`[{"price":…,"quantity":…}]`).
	CheckoutRow : { id : Str, user_id : Str, customer_id : Str, mode : Str, prices : Str, status : Str, payment_status : Str, amount_total : I64, currency : Str, subscription_id : Str, created_at : I64, updated_at : I64 }

	## A subscription as its row has it: its items as JSON (`[{"price":…,"product":…,"quantity":…}]`),
	## its times in milliseconds (0 for none).
	SubscriptionRow : { id : Str, user_id : Str, customer_id : Str, status : Str, items : Str, current_period_end : I64, cancel_at_period_end : Bool, cancel_at : I64, trial_end : I64, version : I64, updated_at : I64 }

	## The Stripe customer of the app's `user`, if it has one.
	customer_of! : Str => Try([Found(Str), Missing], [DbErr(Str), BadRow(Str), ..others])
	customer_of! = |user| {
		rows : List({ customer_id : Str })
		rows = Db.all!("select customer_id from stripe_customers where user_id = $1", [Text(user)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row.customer_id))
			Err(_) => Ok(Missing)
		}
	}

	## The app's user a Stripe customer is, if the package knows.
	user_of! : Str => Try([Found(Str), Missing], [DbErr(Str), BadRow(Str), ..others])
	user_of! = |customer| {
		rows : List({ user_id : Str })
		rows = Db.all!("select user_id from stripe_customers where customer_id = $1", [Text(customer)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row.user_id))
			Err(_) => Ok(Missing)
		}
	}

	## Records that `customer` is `user`'s, unless the user has one already (or the customer is
	## someone's): the first kept stays.
	link! : { user : Str, customer : Str, now : I64 } => Try({}, [DbErr(Str), ..others])
	link! = |linked| {
		_ = Db.run!("insert into stripe_customers (user_id, customer_id, created_at) values ($1, $2, $3) on conflict do nothing", [Text(linked.user), Text(linked.customer), Int(linked.now)])?
		Ok({})
	}

	## Forgets `customer` (Stripe deleted it): the next checkout of its user makes another.
	forget! : Str => Try(U64, [DbErr(Str), ..others])
	forget! = |customer| Db.run!("delete from stripe_customers where customer_id = $1", [Text(customer)])

	## Records a Checkout Session the app has just made, open.
	made! : { id : Str, user : Str, customer : Str, mode : Str, prices : Str, now : I64 } => Try({}, [DbErr(Str), ..others])
	made! = |session| {
		_ = Db.run!(
			"insert into stripe_checkouts (id, user_id, customer_id, mode, prices, status, payment_status, amount_total, currency, subscription_id, created_at, updated_at) values ($1, $2, $3, $4, $5, 'open', 'unpaid', 0, '', '', $6, $6) on conflict do nothing",
			[Text(session.id), Text(session.user), Text(session.customer), Text(session.mode), Text(session.prices), Int(session.now)],
		)?
		Ok({})
	}

	## Records what Stripe says of a Checkout Session (an event's, or its answer's), made here or
	## not. Its status only leaves `open`, its payment stays `paid`, and its user, customer and
	## subscription, once known, stay: an event that comes late takes nothing back.
	seen! : { id : Str, user : Str, customer : Str, mode : Str, status : Str, payment_status : Str, amount_total : I64, currency : Str, subscription : Str, now : I64 } => Try({}, [DbErr(Str), ..others])
	seen! = |session| {
		_ = Db.run!(
			"insert into stripe_checkouts (id, user_id, customer_id, mode, prices, status, payment_status, amount_total, currency, subscription_id, created_at, updated_at) values ($1, $2, $3, $4, '[]', $5, $6, $7, $8, $9, $10, $10) on conflict (id) do update set user_id = case when stripe_checkouts.user_id = '' then excluded.user_id else stripe_checkouts.user_id end, customer_id = case when excluded.customer_id = '' then stripe_checkouts.customer_id else excluded.customer_id end, status = case when stripe_checkouts.status = 'open' then excluded.status else stripe_checkouts.status end, payment_status = case when stripe_checkouts.payment_status = 'paid' then stripe_checkouts.payment_status else excluded.payment_status end, amount_total = excluded.amount_total, currency = excluded.currency, subscription_id = case when excluded.subscription_id = '' then stripe_checkouts.subscription_id else excluded.subscription_id end, updated_at = excluded.updated_at",
			[Text(session.id), Text(session.user), Text(session.customer), Text(session.mode), Text(session.status), Text(session.payment_status), Int(session.amount_total), Text(session.currency), Text(session.subscription), Int(session.now)],
		)?
		Ok({})
	}

	## The Checkout Session `id`, as kept.
	checkout! : Str => Try([Found(StripeStore.CheckoutRow), Missing], [DbErr(Str), BadRow(Str), ..others])
	checkout! = |id| {
		rows : List(StripeStore.CheckoutRow)
		rows = Db.all!("select id, user_id, customer_id, mode, prices, status, payment_status, amount_total, currency, subscription_id, created_at, updated_at from stripe_checkouts where id = $1", [Text(id)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row))
			Err(_) => Ok(Missing)
		}
	}

	## `user`'s one-time payments that have been paid, the newest first.
	paid_of! : Str => Try(List(StripeStore.CheckoutRow), [DbErr(Str), BadRow(Str), ..others])
	paid_of! = |user| Db.all!("select id, user_id, customer_id, mode, prices, status, payment_status, amount_total, currency, subscription_id, created_at, updated_at from stripe_checkouts where user_id = $1 and mode = 'payment' and payment_status in ('paid', 'no_payment_required') order by updated_at desc, id", [Text(user)])

	## Records a subscription as an event says it, if the event stands as high as the one that last
	## changed it or higher (`row.version`), and the subscription hasn't ended: so an event that
	## comes late never puts an older state back. Its user, once known, stays.
	seen_subscription! : StripeStore.SubscriptionRow => Try({}, [DbErr(Str), ..others])
	seen_subscription! = |row| {
		_ = Db.run!(
			"insert into stripe_subscriptions (id, user_id, customer_id, status, items, current_period_end, cancel_at_period_end, cancel_at, trial_end, version, updated_at) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) on conflict (id) do update set user_id = case when excluded.user_id = '' then stripe_subscriptions.user_id else excluded.user_id end, customer_id = excluded.customer_id, status = excluded.status, items = excluded.items, current_period_end = excluded.current_period_end, cancel_at_period_end = excluded.cancel_at_period_end, cancel_at = excluded.cancel_at, trial_end = excluded.trial_end, version = excluded.version, updated_at = excluded.updated_at where stripe_subscriptions.version <= excluded.version and stripe_subscriptions.status not in ('canceled', 'incomplete_expired')",
			values(row),
		)?
		Ok({})
	}

	## Records a subscription as Stripe's API says it now (a page asked, ahead of the events): its
	## state, but not a version, so any event that comes after it still counts. A new row stands
	## lowest (version 0); a subscription that has ended stays ended.
	fetched_subscription! : StripeStore.SubscriptionRow => Try({}, [DbErr(Str), ..others])
	fetched_subscription! = |row| {
		_ = Db.run!(
			"insert into stripe_subscriptions (id, user_id, customer_id, status, items, current_period_end, cancel_at_period_end, cancel_at, trial_end, version, updated_at) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) on conflict (id) do update set user_id = case when excluded.user_id = '' then stripe_subscriptions.user_id else excluded.user_id end, customer_id = excluded.customer_id, status = excluded.status, items = excluded.items, current_period_end = excluded.current_period_end, cancel_at_period_end = excluded.cancel_at_period_end, cancel_at = excluded.cancel_at, trial_end = excluded.trial_end, updated_at = excluded.updated_at where stripe_subscriptions.status not in ('canceled', 'incomplete_expired')",
			values({ ..row, version: 0 }),
		)?
		Ok({})
	}

	## The version of the event that last changed subscription `id`, if it is kept.
	version_of! : Str => Try([Found(I64), Missing], [DbErr(Str), BadRow(Str), ..others])
	version_of! = |id| {
		rows : List({ version : I64 })
		rows = Db.all!("select version from stripe_subscriptions where id = $1", [Text(id)])?
		match rows.get(0) {
			Ok(row) => Ok(Found(row.version))
			Err(_) => Ok(Missing)
		}
	}

	## `user`'s subscriptions, the one changed last first.
	subscriptions_of! : Str => Try(List(StripeStore.SubscriptionRow), [DbErr(Str), BadRow(Str), ..others])
	subscriptions_of! = |user| Db.all!("select id, user_id, customer_id, status, items, current_period_end, cancel_at_period_end, cancel_at, trial_end, version, updated_at from stripe_subscriptions where user_id = $1 order by updated_at desc, id", [Text(user)])

	## Records that event `id` is being handled: `Bool.True` the first time, `Bool.False` when it was
	## handled before (Stripe sent it again). Inside the webhook's transaction, so an event whose
	## handling fails isn't recorded, and one sent twice at once waits for the first to end. Sweeps
	## out the events handled more than 30 days before `now`.
	first_time! : { id : Str, type : Str, created : I64, now : I64 } => Try(Bool, [DbErr(Str), ..others])
	first_time! = |event| {
		_ = Db.run!("delete from stripe_events where handled_at < $1", [Int(event.now - 30 * 86_400_000)])?
		added = Db.run!("insert into stripe_events (id, event_type, created_at, handled_at) values ($1, $2, $3, $4) on conflict do nothing", [Text(event.id), Text(event.type), Int(event.created), Int(event.now)])?
		Ok(added == 1)
	}
}

## A subscription's row as a statement's parameters, in its columns' order.
values : StripeStore.SubscriptionRow -> List(Db.Value)
values = |row| [Text(row.id), Text(row.user_id), Text(row.customer_id), Text(row.status), Text(row.items), Int(row.current_period_end), Bool(row.cancel_at_period_end), Int(row.cancel_at), Int(row.trial_end), Int(row.version), Int(row.updated_at)]
