import pf.Db
import pf.Endpoint
import pf.Env
import pf.Http
import pf.Log
import pf.Plugin
import pf.Random
import pf.Server
import pf.Time
import crypto.Base64
import StripeRules
import StripeStore
import "migrations/0001_stripe.sql" as table : Str
import "migrations/0002_refunds.sql" as refunds : Str

## Payments and subscriptions through Stripe, as a plugin (D-082): Stripe's hosted Checkout for a
## one-time payment or a subscription (`checkout!`), its hosted Customer Portal for managing one
## (`portal!`), a webhook that keeps the app's tables in step with Stripe, and what the app reads to
## know what someone has paid for (`subscribed!`, `paid_for!`, `subscription!`, `payments!`). No
## card forms: Stripe's pages take the cards.
##
## ```roc
## plugins: [Stripe.plugin({})]    # STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
## # routes/stripe/webhook/+server.roc: where Stripe sends its events (D-116: the app's route)
## respond! = |{ request, .. }| Stripe.webhook_route!(request, Billing.on_event!)
##
## url = Stripe.checkout!({ user: me.id, email: me.email, mode: Subscription, prices: [{ price: "price_…", quantity: 1 }], success_url: "/billing/done", cancel_url: "/pricing" })?
## if Stripe.subscribed!(me.id) … else …
## ```
##
## The webhook (`webhook_route!`, in the app's route file at `webhook_at`, `/stripe/webhook`) is
## where Stripe sends its events: each checked against `STRIPE_WEBHOOK_SECRET`, handled once (a
## second time it is only answered), kept in the package's tables, and handed to the app's
## `on_event!` in the same transaction.
Stripe := [].{

	## The plugin's options: `webhook_at`, where the app's route for the webhook is
	## (`/stripe/webhook`: `routes/stripe/webhook/+server.roc`), which the plugin's look at the keys
	## names: the endpoint's URL to give Stripe is `<public URL><webhook_at>`.
	Options := {
		webhook_at : Str ?? "/stripe/webhook",
	}

	## The webhook, `POST <webhook_at>` (`routes/stripe/webhook/+server.roc`, D-116): an event Stripe
	## sends, checked, handled once and kept, then handed to `on_event!`. Stripe's servers call it,
	## signed in as nobody, so the folder it is in must let them through. 405 for a method but POST.
	##
	## `on_event!` is the app's own handling of each event (a one-time payment fulfilled on
	## `checkout.session.completed`, an email when `invoice.payment_failed`), after the package's
	## and in the same transaction: what it writes, and the jobs it queues, commit with the event's
	## record. An `Err` rolls all of it back and answers 500, so Stripe sends the event again later
	## (for up to three days). Keep slow work (a fetch, sending mail) out of it: queue a job. It runs
	## once an event: one Stripe sends again is answered, not handled again. `|_| Ok({})` for none.
	webhook_route! : Server.Request, (Stripe.Event => Try({}, Str)) => Server.Response
	webhook_route! = |request, on_event!| if (request.method == "POST") webhook!(on_event!, request) else Endpoint.not_allowed(request, ["POST"])

	## What a Checkout Session is made with (`checkout!`):
	## - `user`: the app's id for whoever pays: their customer is made the first time and used every
	##   time after, and it is the session's `client_reference_id`;
	## - `email`: their address, for a customer made now ("": Checkout asks for it);
	## - `mode`: `Payment` (once) or `Subscription`;
	## - `prices`: each of Stripe's prices (`price_…`) and how many;
	## - `success_url`, `cancel_url`: where Checkout goes back to when it is paid, and when they turn
	##   back; a path of this site (`/billing/done`) is put after the public URL, and the success URL
	##   gets `session_id={CHECKOUT_SESSION_ID}` in its query unless it names that already;
	## - `trial_days`: a subscription's free days first (0: none);
	## - `promotion_codes`: whether a promotion code may be typed;
	## - `metadata`: more of the app's own, kept on the session.
	Checkout := {
		user : Str,
		email : Str ?? "",
		mode : [Payment, Subscription],
		prices : List({ price : Str, quantity : U64 }),
		success_url : Str,
		cancel_url : Str,
		trial_days : U64 ?? 0,
		promotion_codes : Bool ?? Bool.False,
		metadata : List((Str, Str)) ?? [],
	}

	## A subscription's status, as Stripe's `incomplete`, `incomplete_expired`, `trialing`, `active`,
	## `past_due`, `canceled`, `unpaid` and `paused` say it; `Other` for one Stripe adds later.
	Status : [Incomplete, IncompleteExpired, Trialing, Active, PastDue, Canceled, Unpaid, Paused, Other(Str)]

	## A price a subscription is for, its product, and how many.
	Item : { price : Str, product : Str, quantity : U64 }

	## A subscription, as the package keeps it: its id (`sub_…`), the app's user and the customer
	## it is for, its status, its items, when its period ends (when it renews, or ends), whether it
	## ends then (cancelled in the portal), when it is set to end (0: it isn't), and when its trial
	## ends (0: none). Times are milliseconds since 1970.
	Subscription : {
		id : Str,
		user : Str,
		customer : Str,
		status : Stripe.Status,
		items : List(Stripe.Item),
		current_period_end_ms : I64,
		cancel_at_period_end : Bool,
		cancel_at_ms : I64,
		trial_end_ms : I64,
	}

	## A Checkout Session: its id (`cs_…`), the app's user and the customer, its mode, its status,
	## whether it is paid (or needs no payment), its total in the currency's smallest unit (1500 for
	## €15.00) and its currency, the subscription it made ("" for none), the prices it was made with
	## (`[]` for a session made elsewhere), and its metadata.
	Session : {
		id : Str,
		user : Str,
		customer : Str,
		mode : [Payment, Subscription, Setup],
		status : [Open, Complete, Expired],
		paid : Bool,
		amount_total : I64,
		currency : Str,
		subscription : Str,
		prices : List({ price : Str, quantity : U64 }),
		metadata : List((Str, Str)),
	}

	## An invoice: its id (`in_…`), its customer, the subscription it bills ("" for none), its status
	## (`paid`, `open`, …), what it asks and what was paid, its currency, the page where it can be
	## paid, how many times its payment was tried, and why it was made (`subscription_cycle`, …).
	Invoice : { id : Str, customer : Str, subscription : Str, status : Str, amount_due : I64, amount_paid : I64, currency : Str, hosted_url : Str, attempt_count : U64, billing_reason : Str }

	## What an event is about, read: a Checkout Session (`checkout.session.*`), a subscription
	## (`customer.subscription.*`), an invoice (`invoice.*`), or something else (its `object`).
	About : [Session(Stripe.Session), Subscription(Stripe.Subscription), Invoice(Stripe.Invoice), Other]

	## An event, as `on_event!` is given it: its id (`evt_…`), its type
	## (`checkout.session.completed`), when it happened (milliseconds since 1970), whether it is
	## live, the app's user it is about ("" when the package doesn't know one), what it is about,
	## read, and its object (`data.object`) as Stripe sent it, JSON, for anything else.
	Event : { id : Str, type : Str, created_ms : I64, livemode : Bool, user : Str, about : Stripe.About, object : Str }

	## A one-time payment that has been paid: its Checkout Session, the prices it was for, its total
	## and currency, and when it was paid (milliseconds since 1970).
	Payment : { session : Str, prices : List({ price : Str, quantity : U64 }), amount_total : I64, currency : Str, paid_ms : I64 }

	## The version of Stripe's API the package asks for (`Stripe-Version`): what its answers look
	## like. Events come as the webhook endpoint's own version says; the package reads both.
	api_version : Str
	api_version = "2025-03-31.basil"

	## The Stripe plugin: the tables (`stripe/0001_stripe` and `stripe/0002_refunds`, the same on
	## SQLite and Postgres), and a look at the keys once the server has started (`stripe.keys`: test or live mode). It needs a database, and
	## `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` set; `STRIPE_API_URL` points it at another
	## API than Stripe's (a test's stand-in).
	plugin : Stripe.Options -> Plugin.Value(context)
	plugin = |options| {
		at = options.webhook_at
		{
			name: "stripe",
			migrations: [{ name: "0001_stripe", sql: table }, { name: "0002_refunds", sql: refunds }],
			checks: [{ name: "stripe.keys", run!: |_context| keys!(at) }],
			needs: [Database, Env("STRIPE_SECRET_KEY"), Env("STRIPE_WEBHOOK_SECRET")],
		}
	}

	## A Checkout Session made for `asked.user` (their customer made the first time, used after):
	## the URL of Stripe's page to send the browser to (`Server.redirect`). `StripeErr` with Stripe's
	## words when Stripe refused (a price that isn't there) or couldn't be reached.
	checkout! : Stripe.Checkout => Try(Str, [StripeErr(Str), DbErr(Str), ..others])
	checkout! = |asked| {
		if asked.user.is_empty() or asked.prices.is_empty() {
			return Err(StripeErr("Stripe.checkout! needs the app's user and at least one price"))
		}
		mode =
			match asked.mode {
				Payment => "payment"
				Subscription => "subscription"
			}
		public = Env.public_url!({})
		form = |customer|
			StripeRules.checkout_form({
				mode: mode,
				customer: customer,
				user: asked.user,
				prices: asked.prices,
				success_url: StripeRules.with_session_id(StripeRules.absolute(asked.success_url, public)),
				cancel_url: StripeRules.absolute(asked.cancel_url, public),
				trial_days: asked.trial_days,
				promotion_codes: asked.promotion_codes,
				metadata: asked.metadata,
			})
		customer = customer_for!(asked.user, asked.email)?
		made =
			match posted!("/v1/checkout/sessions", form(customer), random_key!({})) {
				Err(Refused(_, said)) if StripeRules.no_customer(said) => {
					# The customer is gone at Stripe (deleted, or the test data cleared): another.
					Log.warn!("stripe: a customer Stripe doesn't have was forgotten", { user: asked.user, customer: customer })
					_ = StripeStore.forget!(customer)?
					again = made_customer!(asked.user, asked.email, random_key!({}))?
					posted!("/v1/checkout/sessions", form(again), random_key!({}))
				}
				answered => answered
			}
		text = made.map_err(stripe_err)?
		session = StripeRules.session(text).map_err(|why| StripeErr("Stripe's answer wasn't a Checkout Session: ${why}"))?
		StripeStore.made!({ id: session.id, user: asked.user, customer: if (session.customer.is_empty()) customer else session.customer, mode: mode, prices: Json.to_str(asked.prices), now: now!({}) })?
		if (session.url.is_empty()) Err(StripeErr("Stripe's Checkout Session has no URL")) else Ok(session.url)
	}

	## A Customer Portal session for `user`, coming back to `return_url` (a path of this site, or a
	## URL): the URL of Stripe's page, where they change their plan or card, see their invoices, or
	## cancel. `NoCustomer` when they have never checked out.
	portal! : Str, Str => Try(Str, [NoCustomer, StripeErr(Str), DbErr(Str), ..others])
	portal! = |user, return_url|
		match StripeStore.customer_of!(user).map_err(unread)? {
			Missing => Err(NoCustomer)
			Found(customer) => {
				text = posted!("/v1/billing_portal/sessions", [("customer", customer), ("return_url", StripeRules.absolute(return_url, Env.public_url!({})))], random_key!({})).map_err(stripe_err)?
				url = StripeRules.text(text, ["url"])
				if (url.is_empty()) Err(StripeErr("Stripe's portal session has no URL")) else Ok(url)
			}
		}

	## The Checkout Session `id` (the success page's `?session_id=`), as Stripe says it is now, if it
	## is `user`'s, and kept, with its subscription: so the page Checkout goes back to shows what was
	## bought before Stripe's events have come (they still count when they do). The app's
	## `on_event!` runs for the events alone. `NotYours` for a session that is someone else's, or
	## isn't one.
	checkout_session! : Str, Str => Try(Stripe.Session, [NotYours, StripeErr(Str), DbErr(Str), ..others])
	checkout_session! = |user, id| {
		if !StripeRules.is_session_id(id) or user.is_empty() {
			return Err(NotYours)
		}
		text = fetched!(StripeRules.api_path("/v1/checkout/sessions", id), [("expand[]", "subscription")]).map_err(stripe_err)?
		read = StripeRules.session(text).map_err(|why| StripeErr("Stripe's answer wasn't a Checkout Session: ${why}"))?
		if read.user != user {
			return Err(NotYours)
		}
		now = now!({})
		Db.transaction!(
			|{}| {
				if !read.customer.is_empty() {
					StripeStore.link!({ user: user, customer: read.customer, now: now })?
				}
				StripeStore.seen!({ id: read.id, user: user, customer: read.customer, mode: read.mode, status: read.status, payment_status: read.payment_status, amount_total: read.amount_total, currency: read.currency, subscription: read.subscription, payment_intent: read.payment_intent, now: now })?
				match StripeRules.at(text, ["subscription"]) {
					Ok(object) if object.starts_with("{") =>
						match StripeRules.subscription(object) {
							Ok(subscribed) => StripeStore.fetched_subscription!(row_of(subscribed, user, 0, now))
							Err(_) => Ok({})
						}
					_ => Ok({})
				}
			},
		)?
		session_of!(read)
	}

	## `user`'s subscriptions, the one changed last first: as Stripe's events last said.
	subscriptions! : Str => Try(List(Stripe.Subscription), [DbErr(Str), ..others])
	subscriptions! = |user| {
		rows = StripeStore.subscriptions_of!(user).map_err(unread)?
		Ok(rows.map(subscription_of))
	}

	## `user`'s subscription: the one that hasn't ended (the one changed last, if several), else the
	## one that ended last. `NotSubscribed` when they have none.
	subscription! : Str => Try(Stripe.Subscription, [NotSubscribed, DbErr(Str), ..others])
	subscription! = |user| {
		all = Stripe.subscriptions!(user)?
		match all.find_first(|each| !Stripe.ended(each.status)) {
			Ok(current) => Ok(current)
			Err(_) =>
				match all.first() {
					Ok(last) => Ok(last)
					Err(_) => Err(NotSubscribed)
				}
		}
	}

	## Whether `user` has a subscription that is paid for (`paying`: active, trialing, or past due
	## while Stripe tries the card again). A database that can't be read is a no, and an error on
	## the log.
	subscribed! : Str => Bool
	subscribed! = |user|
		match Stripe.subscriptions!(user) {
			Ok(all) => all.any(|each| Stripe.paying(each.status))
			Err(DbErr(why)) => unread!(why)
		}

	## Whether `user` has paid for `what`, a price (`price_…`) or a product (`prod_…`): a subscription
	## that is `paying` has it among its items, or a one-time payment that has been paid was for the
	## price (and hasn't been refunded in full, nor disputed: `charge.refunded`, `charge.dispute.*`). A database that can't be read is a no, and an error on the log.
	paid_for! : Str, Str => Bool
	paid_for! = |user, what| {
		subscribed =
			match Stripe.subscriptions!(user) {
				Ok(all) => all.any(|each| Stripe.paying(each.status) and each.items.any(|item| item.price == what or item.product == what))
				Err(DbErr(why)) => unread!(why)
			}
		if subscribed {
			Bool.True
		} else {
			match Stripe.payments!(user) {
				Ok(all) => all.any(|each| each.prices.any(|line| line.price == what))
				Err(DbErr(why)) => unread!(why)
			}
		}
	}

	## `user`'s one-time payments that have been paid, the newest first.
	payments! : Str => Try(List(Stripe.Payment), [DbErr(Str), ..others])
	payments! = |user| {
		rows = StripeStore.paid_of!(user).map_err(unread)?
		Ok(rows.map(|row| { session: row.id, prices: prices_of(row.prices), amount_total: row.amount_total, currency: row.currency, paid_ms: row.updated_at }))
	}

	## `user`'s Stripe customer (`cus_…`), for anything else of Stripe's API; `NoCustomer` when they
	## have never checked out.
	customer! : Str => Try(Str, [NoCustomer, DbErr(Str), ..others])
	customer! = |user|
		match StripeStore.customer_of!(user).map_err(unread)? {
			Found(customer) => Ok(customer)
			Missing => Err(NoCustomer)
		}

	## Anything else of Stripe's API that makes something (`/v1/refunds`, with its form's fields),
	## asked as the package asks (the secret key, `Stripe-Version`, a new `Idempotency-Key`, tried
	## again on a network error or a 5xx): Stripe's answer, its JSON (`StripeRules.text` reads a
	## field).
	post! : Str, List((Str, Str)) => Try(Str, [StripeErr(Str), ..others])
	post! = |path, fields| posted!(path, fields, random_key!({})).map_err(stripe_err)

	## As `post!`, with an `Idempotency-Key` of the app's own (`"refund-order-42"`), the same each
	## time the same thing is asked: a job run again after a crash, or a form sent twice, makes one
	## refund, not two (Stripe answers a key it has seen, for 24 hours, as it did the first time).
	## "" makes a new one, as `post!` does.
	post_with! : { path : Str, fields : List((Str, Str)), idempotency_key : Str } => Try(Str, [StripeErr(Str), ..others])
	post_with! = |asked| posted!(asked.path, asked.fields, if (asked.idempotency_key.is_empty()) random_key!({}) else asked.idempotency_key).map_err(stripe_err)

	## Anything else of Stripe's API that reads (`/v1/invoices`, with its query's fields): its JSON.
	get! : Str, List((Str, Str)) => Try(Str, [StripeErr(Str), ..others])
	get! = |path, fields| fetched!(path, fields).map_err(stripe_err)

	## The status Stripe writes as `text` (`past_due`).
	status_of : Str -> Stripe.Status
	status_of = |text|
		match text {
			"incomplete" => Incomplete
			"incomplete_expired" => IncompleteExpired
			"trialing" => Trialing
			"active" => Active
			"past_due" => PastDue
			"canceled" => Canceled
			"unpaid" => Unpaid
			"paused" => Paused
			_ => Other(text)
		}

	## A status as Stripe writes it (`past_due`).
	status_name : Stripe.Status -> Str
	status_name = |given|
		match given {
			Incomplete => "incomplete"
			IncompleteExpired => "incomplete_expired"
			Trialing => "trialing"
			Active => "active"
			PastDue => "past_due"
			Canceled => "canceled"
			Unpaid => "unpaid"
			Paused => "paused"
			Other(text) => text
		}

	## Whether a subscription with this status is paid for: active, trialing, or past due (a payment
	## failed, and Stripe is trying the card again before it gives up, as the account's settings say).
	paying : Stripe.Status -> Bool
	paying = |given|
		match given {
			Active | Trialing | PastDue => Bool.True
			_ => Bool.False
		}

	## Whether a subscription with this status has ended for good: canceled, or never paid.
	ended : Stripe.Status -> Bool
	ended = |given|
		match given {
			Canceled | IncompleteExpired => Bool.True
			_ => Bool.False
		}
}

## Now, in milliseconds since 1970.
now! : {} => I64
now! = |{}| Time.now_millis!({}).to_i64_wrap()

## A new `Idempotency-Key`: a create tried again (after a network error) is made once.
random_key! : {} => Str
random_key! = |{}| "rocx-${Base64.url_encode(Random.bytes!(18))}"

## Where Stripe's API is: `STRIPE_API_URL` (a test's stand-in), else Stripe's.
api_url! : {} => Str
api_url! = |{}| {
	given = (Env.var!("STRIPE_API_URL") ?? "").trim()
	if (given.is_empty()) "https://api.stripe.com" else if (given.ends_with("/")) given.drop_suffix("/") else given
}

## Stripe's answer to `POST <path>` with `fields`, made with the idempotency key `key`.
posted! : Str, List((Str, Str)), Str => Try(Str, [Refused(U16, Str), Unreached(Str)])
posted! = |path, fields, key| asked!(Post, path, fields, key, 3)

## Stripe's answer to `GET <path>` with `fields` in its query.
fetched! : Str, List((Str, Str)) => Try(Str, [Refused(U16, Str), Unreached(Str)])
fetched! = |path, fields| asked!(Get, path, fields, "", 3)

## Stripe's answer to a request: its JSON when it is a success; `Refused(status, json)` when it
## isn't; `Unreached(why)` when there was none. A network error, a 409 (the same key in use), a 429
## or a 5xx is tried again, `tries` times in all, half a second and then a second later, with the
## same idempotency key, unless Stripe says not to (`Stripe-Should-Retry: false`).
asked! : [Get, Post], Str, List((Str, Str)), Str, U64 => Try(Str, [Refused(U16, Str), Unreached(Str)])
asked! = |method, path, fields, key, tries| {
	secret = (Env.var!("STRIPE_SECRET_KEY") ?? "").trim()
	url = "${api_url!({})}${path}"
	headers = [("authorization", "Bearer ${secret}"), ("stripe-version", Stripe.api_version), ("user-agent", "roc-solid-stripe")].concat(if (key.is_empty()) [] else [("idempotency-key", key)])
	answer =
		match method {
			Get => Http.fetch!(url, { headers: headers, query: fields, timeout_ms: 30_000 })
			Post => Http.fetch!(url, { method: Post, headers: headers, body: Http.form(fields), timeout_ms: 30_000 })
		}
	match answer {
		Ok(res) if res.ok => Ok(res.text())
		Ok(res) =>
			if tries > 1 and again(res.status, res.header("stripe-should-retry") ?? "") {
				Time.sleep!(pause(tries))
				asked!(method, path, fields, key, tries - 1)
			} else {
				Err(Refused(res.status, res.text()))
			}
		Err(problem) =>
			if tries > 1 {
				Time.sleep!(pause(tries))
				asked!(method, path, fields, key, tries - 1)
			} else {
				Err(
					Unreached(
						match problem {
							HttpErr(why) => why
							TimedOut => "it didn't answer within 30 s"
							TooLarge => "its answer was too large"
						},
					),
				)
			}
	}
}

## Whether an answer with `status` is tried again, as Stripe's `Stripe-Should-Retry` (`should`, ""
## when it isn't there) says, else for a 409, a 429 or a 5xx.
again : U16, Str -> Bool
again = |status, should|
	if should == "true" {
		Bool.True
	} else if should == "false" {
		Bool.False
	} else {
		status == 409 or status == 429 or status >= 500
	}

## How long to wait before trying again, with `tries` left (3, then 2): half a second, then a second.
pause : U64 -> U64
pause = |tries| if (tries >= 3) 500 else 1000

## What a request that failed says, for the app.
stripe_err : [Refused(U16, Str), Unreached(Str)] -> [StripeErr(Str), ..others]
stripe_err = |problem|
	match problem {
		Refused(status, json) => StripeErr(StripeRules.problem(status, json))
		Unreached(why) => StripeErr("Stripe couldn't be reached: ${why}")
	}

## A row that couldn't be read is the database's error.
unread : [DbErr(Str), BadRow(Str)] -> [DbErr(Str), ..others]
unread = |problem|
	match problem {
		DbErr(why) => DbErr(why)
		BadRow(why) => DbErr(why)
	}

## A check that couldn't read the database: a no, and an error on the log.
unread! : Str => Bool
unread! = |why| {
	Log.error!("stripe: the subscriptions couldn't be read", { error: why })
	Bool.False
}

## `user`'s customer: the one kept, else one made now (with an idempotency key of the user and the
## address, so two checkouts at once make one).
customer_for! : Str, Str => Try(Str, [StripeErr(Str), DbErr(Str), ..others])
customer_for! = |user, email|
	match StripeStore.customer_of!(user).map_err(unread)? {
		Found(customer) => Ok(customer)
		Missing => made_customer!(user, email, StripeRules.customer_key(user, email))
	}

## A customer made at Stripe for `user` (their address, if given, and the app's id in its metadata),
## and kept as theirs: the one kept, if another request kept one first.
made_customer! : Str, Str, Str => Try(Str, [StripeErr(Str), DbErr(Str), ..others])
made_customer! = |user, email, key| {
	fields = (if (email.is_empty()) [] else [("email", email)]).concat([("metadata[${StripeRules.user_key}]", user)])
	text = posted!("/v1/customers", fields, key).map_err(stripe_err)?
	made = StripeRules.text(text, ["id"])
	if !made.starts_with("cus_") {
		return Err(StripeErr("Stripe's answer wasn't a customer"))
	}
	StripeStore.link!({ user: user, customer: made, now: now!({}) })?
	match StripeStore.customer_of!(user).map_err(unread)? {
		Found(kept) => Ok(kept)
		Missing => Ok(made)
	}
}

## The prices a checkout's row keeps (JSON); none when they can't be read.
prices_of : Str -> List({ price : Str, quantity : U64 })
prices_of = |json| {
	read : Try(List({ price : Str, quantity : U64 }), _)
	read = Json.parse(json)
	read ?? []
}

## A subscription as an event or Stripe's API says it, as its row: for `user`, at `version`, kept at
## `now`; its times in milliseconds.
row_of : StripeRules.Subscription, Str, I64, I64 -> StripeStore.SubscriptionRow
row_of = |read, user, version, now| {
	id: read.id,
	user_id: user,
	customer_id: read.customer,
	status: read.status,
	items: Json.to_str(read.items),
	current_period_end: read.current_period_end * 1000,
	cancel_at_period_end: read.cancel_at_period_end,
	cancel_at: read.cancel_at * 1000,
	trial_end: read.trial_end * 1000,
	version: version,
	updated_at: now,
}

## A subscription's row, as the app is given it.
subscription_of : StripeStore.SubscriptionRow -> Stripe.Subscription
subscription_of = |row| {
	read : Try(List(Stripe.Item), _)
	read = Json.parse(row.items)
	{
		id: row.id,
		user: row.user_id,
		customer: row.customer_id,
		status: Stripe.status_of(row.status),
		items: read ?? [],
		current_period_end_ms: row.current_period_end,
		cancel_at_period_end: row.cancel_at_period_end,
		cancel_at_ms: row.cancel_at,
		trial_end_ms: row.trial_end,
	}
}

## A Checkout Session as Stripe says it, as the app is given it, with the prices it was made with
## (kept when the app made it).
session_of! : StripeRules.Session => Try(Stripe.Session, [DbErr(Str), ..others])
session_of! = |read| {
	prices =
		match StripeStore.checkout!(read.id).map_err(unread)? {
			Found(row) => prices_of(row.prices)
			Missing => []
		}
	Ok({
		id: read.id,
		user: read.user,
		customer: read.customer,
		mode: match read.mode {
			"subscription" => Subscription
			"setup" => Setup
			_ => Payment
		},
		status: match read.status {
			"complete" => Complete
			"expired" => Expired
			_ => Open
		},
		paid: read.payment_status == "paid" or read.payment_status == "no_payment_required",
		amount_total: read.amount_total,
		currency: read.currency,
		subscription: read.subscription,
		prices: prices,
		metadata: read.metadata,
	})
}

## The app's user a customer is, "" when the package doesn't know (or there is no customer).
known! : Str => Try(Str, [DbErr(Str), ..others])
known! = |customer|
	if customer.is_empty() {
		Ok("")
	} else {
		match StripeStore.user_of!(customer).map_err(unread)? {
			Found(user) => Ok(user)
			Missing => Ok("")
		}
	}

## What an event is about, read before its transaction: a subscription, a Checkout Session, an
## invoice, a customer deleted, or anything else (its customer, if it names one).
Read : [Sub(StripeRules.Subscription), Sess(StripeRules.Session), Inv(StripeRules.Invoice), Deleted(Str), Charged([Refunded(Str), Disputed(Str), Settled(Str), Unchanged], Str), Else(Str)]

## The plugin's webhook: the event checked against `STRIPE_WEBHOOK_SECRET` (else a 400), handled
## once, a 200 when it is (or was before), a 500 when it couldn't be, so Stripe sends it again.
webhook! : (Stripe.Event => Try({}, Str)), Server.Request => Server.Response
webhook! = |on_event!, request| {
	secret = (Env.var!("STRIPE_WEBHOOK_SECRET") ?? "").trim()
	signed = Server.header(request, "stripe-signature") ?? ""
	match StripeRules.verify(signed, request.body, secret, now!({}) // 1000) {
		Err(problem) => {
			why =
				match problem {
					Unsigned => "it isn't signed (Stripe-Signature, with t= and v1=)"
					Stale(age) => "its signature is ${age.to_str()} s old, more than ${StripeRules.tolerance_s.to_str()}"
					Forged => "its signature isn't the webhook secret's (STRIPE_WEBHOOK_SECRET)"
				}
			Log.warn!("stripe: a webhook was refused", { reason: why })
			Server.refused(400, "Refused: ${why}.")
		}
		Ok({}) =>
			match StripeRules.event(Server.text_of(request)) {
				Err(why) => {
					Log.warn!("stripe: a webhook was refused", { reason: why })
					Server.refused(400, "Refused: ${why}.")
				}
				Ok(event) => handled!(on_event!, event)
			}
	}
}

## A signed event handled: read (and, for a subscription, asked of Stripe again when it ties with
## the change kept), then recorded, kept and handed to `on_event!` in one transaction.
handled! : (Stripe.Event => Try({}, Str)), StripeRules.Event => Server.Response
handled! = |on_event!, event| {
	outcome =
		match read!(event) {
			Err(Unreadable(why)) => Err(Unreadable(why))
			Ok(ready) => Db.transaction!(|{}| recorded!(on_event!, event, ready))
		}
	fields = { event: event.id, type: event.type }
	match outcome {
		Ok(Handled(user)) => {
			Log.info!("stripe: an event was handled", { event: event.id, type: event.type, user: user })
			Server.response(200, [{ name: "content-type", value: "application/json" }], "{\"received\":true}")
		}
		Ok(Replayed) => {
			Log.debug!("stripe: an event came again, handled before", fields)
			Server.response(200, [{ name: "content-type", value: "application/json" }], "{\"received\":true}")
		}
		Err(Unreadable(why)) => {
			Log.error!("stripe: an event couldn't be read", { event: event.id, type: event.type, error: why })
			Server.refused(500, "The event couldn't be read: ${why}")
		}
		Err(Hook(why)) => {
			Log.error!("stripe: the app's on_event! failed", { event: event.id, type: event.type, error: why })
			Server.refused(500, "The app couldn't handle the event: ${why}")
		}
		Err(DbErr(why)) => {
			Log.error!("stripe: an event couldn't be kept", { event: event.id, type: event.type, error: why })
			Server.refused(500, "The event couldn't be kept just now.")
		}
	}
}

## What `event` is about, read. A subscription's change that stands level with the one kept (two
## in one second, this one perhaps the older) is asked of Stripe again, which says which is last.
read! : StripeRules.Event => Try(Read, [Unreadable(Str)])
read! = |event|
	if event.type.starts_with("customer.subscription.") {
		said = StripeRules.subscription(event.object).map_err(|why| Unreadable(why))?
		level =
			match StripeStore.version_of!(said.id) {
				Ok(Found(kept)) => kept == StripeRules.version(event.created, event.type) and StripeRules.rank(event.type) == 1
				_ => Bool.False
			}
		if level {
			# Once, not three times: Stripe is waiting for the webhook's answer.
			match asked!(Get, StripeRules.api_path("/v1/subscriptions", said.id), [], "", 1) {
				Ok(text) => Ok(Sub(StripeRules.subscription(text) ?? said))
				Err(_) => {
					Log.warn!("stripe: a subscription couldn't be asked again; the event's state is kept", { subscription: said.id, event: event.id })
					Ok(Sub(said))
				}
			}
		} else {
			Ok(Sub(said))
		}
	} else if event.type.starts_with("checkout.session.") {
		StripeRules.session(event.object).map_ok(|session| Sess(session)).map_err(|why| Unreadable(why))
	} else if event.type.starts_with("invoice.") {
		match StripeRules.invoice(event.object) {
			Ok(invoice) => Ok(Inv(invoice))
			Err(_) => Ok(Else(StripeRules.id_at(event.object, ["customer"])))
		}
	} else if event.type == "customer.deleted" {
		Ok(Deleted(StripeRules.text(event.object, ["id"])))
	} else if event.type == "charge.refunded" or event.type.starts_with("charge.dispute.") {
		Ok(Charged(StripeRules.charge_change(event.type, event.object), StripeRules.id_at(event.object, ["customer"])))
	} else {
		Ok(Else(StripeRules.id_at(event.object, ["customer"])))
	}

## `event` recorded (`Replayed` when it was before), what it says kept, and `on_event!` given it:
## inside the webhook's transaction, so all of it commits, or none.
recorded! : (Stripe.Event => Try({}, Str)), StripeRules.Event, Read => Try([Handled(Str), Replayed], [DbErr(Str), Hook(Str), ..others])
recorded! = |on_event!, event, ready| {
	now = now!({})
	first = StripeStore.first_time!({ id: event.id, type: event.type, created: event.created * 1000, now: now })?
	if !first {
		return Ok(Replayed)
	}
	(user, about) = kept!(event, ready, now)?
	match on_event!({ id: event.id, type: event.type, created_ms: event.created * 1000, livemode: event.livemode, user: user, about: about, object: event.object }) {
		Ok({}) => Ok(Handled(user))
		Err(why) => Err(Hook(why))
	}
}

## What `event` says, kept in the package's tables: the app's user it is about, and what it is
## about, as `on_event!` is given it.
kept! : StripeRules.Event, Read, I64 => Try((Str, Stripe.About), [DbErr(Str), ..others])
kept! = |event, ready, now|
	match ready {
		Sess(read) => {
			user = if (read.user.is_empty()) known!(read.customer)? else read.user
			if !user.is_empty() and !read.customer.is_empty() {
				StripeStore.link!({ user: user, customer: read.customer, now: now })?
			}
			StripeStore.seen!({ id: read.id, user: user, customer: read.customer, mode: read.mode, status: read.status, payment_status: read.payment_status, amount_total: read.amount_total, currency: read.currency, subscription: read.subscription, payment_intent: read.payment_intent, now: now })?
			typed = session_of!({ ..read, user: user })?
			Ok((user, Session(typed)))
		}
		Sub(read) => {
			linked = known!(read.customer)?
			user = if (linked.is_empty()) read.user else linked
			row = row_of(read, user, StripeRules.version(event.created, event.type), now)
			StripeStore.seen_subscription!(row)?
			Ok((user, Subscription(subscription_of(row))))
		}
		Inv(read) => {
			user = known!(read.customer)?
			Ok((user, Invoice(read)))
		}
		Deleted(customer) => {
			user = known!(customer)?
			_ = StripeStore.forget!(customer)?
			Ok((user, Other))
		}
		Charged(change, customer) => {
			changed =
				match change {
					Refunded(intent) => StripeStore.charged!(intent, Refunded, now)?
					Disputed(intent) => StripeStore.charged!(intent, Disputed, now)?
					Settled(intent) => StripeStore.charged!(intent, Settled, now)?
					Unchanged => ""
				}
			user = if (changed.is_empty()) known!(customer)? else changed
			Ok((user, Other))
		}
		Else(customer) => {
			user = known!(customer)?
			Ok((user, Other))
		}
	}

## The look at the keys once the server has started (`stripe.keys`): test or live mode, or what is
## wrong with them.
keys! : Str => Try(Str, Str)
keys! = |at| {
	key = (Env.var!("STRIPE_SECRET_KEY") ?? "").trim()
	hook = (Env.var!("STRIPE_WEBHOOK_SECRET") ?? "").trim()
	live = key.starts_with("sk_live_") or key.starts_with("rk_live_")
	test = key.starts_with("sk_test_") or key.starts_with("rk_test_")
	if !live and !test {
		Err("STRIPE_SECRET_KEY isn't a secret key (sk_test_…, sk_live_…, or a restricted rk_…)")
	} else if !hook.starts_with("whsec_") {
		Err("STRIPE_WEBHOOK_SECRET isn't a webhook signing secret (whsec_…)")
	} else if live and Env.dev!({}) {
		Err("live keys under --dev: its payments are real")
	} else {
		Ok("${if (live) "live" else "test"} mode, Stripe-Version ${Stripe.api_version}, webhooks at POST ${at}")
	}
}

expect Stripe.status_of("past_due") == PastDue and Stripe.status_of("paused") == Paused and Stripe.status_of("new_one") == Other("new_one")
expect ["incomplete", "incomplete_expired", "trialing", "active", "past_due", "canceled", "unpaid", "paused", "x"].all(|text| Stripe.status_name(Stripe.status_of(text)) == text)
expect Stripe.paying(Active) and Stripe.paying(Trialing) and Stripe.paying(PastDue) and !Stripe.paying(Unpaid) and !Stripe.paying(Canceled) and !Stripe.paying(Incomplete)
expect Stripe.ended(Canceled) and Stripe.ended(IncompleteExpired) and !Stripe.ended(Unpaid)
expect again(500, "") and again(429, "") and again(409, "") and !again(400, "") and !again(500, "false") and again(400, "true")
expect prices_of("[{\"price\":\"price_a\",\"quantity\":2}]") == [{ price: "price_a", quantity: 2 }] and prices_of("nonsense") == []
expect {
	row = row_of({ id: "sub_1", customer: "cus_1", status: "active", items: [{ price: "price_pro", product: "prod_pro", quantity: 1 }], current_period_end: 1700000000, cancel_at_period_end: Bool.True, cancel_at: 0, trial_end: 0, user: "" }, "u1", 6800000001, 5)
	subscription_of(row) == { id: "sub_1", user: "u1", customer: "cus_1", status: Active, items: [{ price: "price_pro", product: "prod_pro", quantity: 1 }], current_period_end_ms: 1700000000000, cancel_at_period_end: Bool.True, cancel_at_ms: 0, trial_end_ms: 0 }
}
