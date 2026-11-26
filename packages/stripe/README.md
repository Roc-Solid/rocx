# stripe

Payments and subscriptions for Roc Solid apps through [Stripe](https://stripe.com), as a plugin
(D-082): Stripe's hosted Checkout for a one-time payment or a subscription, its hosted Customer
Portal for managing one, a webhook that keeps the app's database in step with Stripe, and typed
answers to "what has this user paid for". Cards are typed on Stripe's pages, never the app's.

The package keeps the parts that are easy to get wrong: the webhook's signature (and its age), each
event handled once however often it comes, events that come out of order, one Stripe customer per
user, idempotency keys, the page Checkout goes back to before the events have come. The app keeps
its prices (made in Stripe's Dashboard), its pages, and what it does when someone pays
(`on_event!`).

The docs site's page, `/ecosystem/stripe`, is the guide; this is the reference. `example/` is an app
that sells a subscription and an e-book, and its tests (`example/test`) run it on SQLite and on
Postgres against a stand-in for Stripe's API (`example/test/stand-in.mjs`), never Stripe itself.

## Installing it

1. Name the package in the app's header (it names the server platform, so only the server's half
   of an app sees it), and list its plugin:

   ```roc
   app [program] { auth: "../packages/auth/main.roc", pf: platform "../server/platform/main.roc", stripe: "../packages/stripe/main.roc" }

   program = App.program({
       init!: |_started| Ok({}),
       middleware: Middleware.same_origin({}),
       plugins: [
           Auth.plugin({ admit!: Accounts.admit! }),
           Stripe.plugin({ on_event!: Billing.on_event! }),
       ],
       database: Sqlite("data/app.db"),
   })
   ```

2. Give the server its keys: `STRIPE_SECRET_KEY` (`sk_test_…` while you build, `sk_live_…` in
   production; a restricted key, `rk_…`, with write access to Customers, Checkout Sessions and the
   Customer Portal, and read access to Subscriptions, will do) and `STRIPE_WEBHOOK_SECRET` (the
   webhook endpoint's signing secret, `whsec_…`). The server doesn't start without them, and once it
   has, it logs which mode they are (`stripe.keys`).

3. Send the browser to Checkout from an endpoint of the app's (a plan's button posts to it):

   ```roc
   post! = |{ context, body, .. }|
       match Stripe.checkout!({ user: context.user, email: context.email, mode: Subscription, prices: [{ price: body.price, quantity: 1 }], success_url: "/billing/done", cancel_url: "/pricing" }) {
           Ok(url) => Err(Answer(Server.redirect(url)))
           Err(StripeErr(why)) => Err(Status(502, why))
           Err(DbErr(why)) => Err(Status(503, why))
       }
   ```

4. Ask who has paid: `Stripe.subscribed!(user)`, `Stripe.paid_for!(user, "price_…")` (or a
   product), `Stripe.subscription!(user)`, `Stripe.payments!(user)`. And write `on_event!` for what
   the app does itself when Stripe says something happened (below).

## Developing with the Stripe CLI

Stripe's test mode charges nothing: its test cards (`4242 4242 4242 4242`, any future date, any
CVC) pay on Checkout's page. In the Dashboard, in test mode:

1. Make the products and prices you sell (Product catalog); their ids (`price_…`) are what
   `checkout!` takes.
2. Save the Customer Portal's settings once (Settings, Billing, Customer portal): until they are
   saved, Stripe refuses to make a portal session in test mode.

Then forward Stripe's events to the app as you run it, with the [Stripe CLI](https://docs.stripe.com/stripe-cli):

```sh
stripe login
stripe listen --forward-to localhost:8080/stripe/webhook      # prints the webhook secret: whsec_…
export STRIPE_SECRET_KEY=sk_test_… STRIPE_WEBHOOK_SECRET=whsec_…
rocx dev                                                    # in another terminal
stripe trigger checkout.session.completed                   # an event of your own, to see one arrive
```

`stripe listen` signs what it forwards with a secret of its own (it stays the same from one run to
the next), sends every event type, and writes them as your account's API version unless given
`--latest`; the package reads either.

For production, add an endpoint in the Dashboard (Developers, Webhooks): its URL is
`<public URL>/stripe/webhook`, and its signing secret is that endpoint's `STRIPE_WEBHOOK_SECRET`.
Send it at least these events:

| Event | The package | Usually, the app's `on_event!` |
| --- | --- | --- |
| `checkout.session.completed` | the checkout complete, its customer linked to the user | fulfil a one-time payment that is `paid` |
| `checkout.session.async_payment_succeeded`, `…_failed` | its payment paid (or not) | fulfil it now (or say it failed) |
| `checkout.session.expired` | the checkout expired | |
| `customer.subscription.created`, `.updated`, `.deleted` (and `.paused`, `.resumed`, `.trial_will_end`) | the subscription as the event says it | welcome, goodbye |
| `invoice.paid`, `invoice.payment_failed` | | a receipt; ask them to update their card |
| `customer.deleted` | the user's customer forgotten | |
| `charge.refunded`, `charge.dispute.created`, `charge.dispute.closed` | a one-time payment refunded in full is `refunded`, a disputed one `disputed` (and `paid` again when the dispute is won): neither is paid for (`paid_for!`, `payments!`) | take back what it gave |

## The example

`example/` sells two monthly plans (Basic, Pro) and an e-book: a pricing page whose buttons post to
`/billing/checkout`, the page Checkout goes back to (`/billing/done`), an account page with the
subscription, the orders and the portal's button, a page for subscribers (`/pro`) and the e-book for
those who bought it (`/ebook`). `Billing.on_event!` writes an order when an e-book is paid. People
sign in with packages/auth's dev sign-in, so it runs under `rocx dev` only. With your test mode's
prices:

```sh
cd packages/stripe/example
export STRIPE_SECRET_KEY=sk_test_… STRIPE_WEBHOOK_SECRET=whsec_…   # the second from stripe listen
export STRIPE_PRICE_BASIC=price_… STRIPE_PRICE_PRO=price_… STRIPE_PRICE_EBOOK=price_…
stripe listen --forward-to localhost:8080/stripe/webhook &
rocx dev
```

Its tests need none of that: `node --test 'packages/stripe/example/test/*.test.mjs'` builds it and
runs it against the stand-in, on SQLite, and on Postgres too with `DATABASE_URL` (`just test-server`
runs them).

## The plugin's options

```roc
Stripe.Options := {
    webhook_at : Str ?? "/stripe/webhook",                         # where Stripe sends its events
    on_event! : (Stripe.Event => Try({}, Str)) ?? ignored!,          # the app's own handling of each
}
```

The environment: `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` (needed), and `STRIPE_API_URL`
(Stripe's API by default; a test's stand-in, or `stripe-mock`).

## Checkout

```roc
Stripe.Checkout := {
    user : Str,                                          # the app's id for whoever pays
    email : Str ?? "",                                   # their address, for a customer made now
    mode : [Payment, Subscription],
    prices : List({ price : Str, quantity : U64 }),       # Stripe's price ids, and how many
    success_url : Str,                                   # a path of this site, or a URL
    cancel_url : Str,
    trial_days : U64 ?? 0,                               # a subscription's free days first
    promotion_codes : Bool ?? Bool.False,                # whether a promotion code may be typed
    metadata : List((Str, Str)) ?? [],                   # more of the app's own, on the session
}

Stripe.checkout! : Stripe.Checkout => Try(Str, [StripeErr(Str), DbErr(Str), ..])
```

`checkout!` makes a Checkout Session and gives its URL, for the endpoint to redirect to. Before it,
the user's Stripe customer: the one kept for them, or one made now (their `email`, and the app's
id in its metadata as `app_user_id`), kept in `stripe_customers`, so every checkout and the portal
of one user is one customer. The session carries the user as `client_reference_id`, and in its
metadata and its subscription's (or its payment's). A path (`/billing/done`) is put after the
server's public URL, and the success URL gets `session_id={CHECKOUT_SESSION_ID}` in its query
unless it names `{CHECKOUT_SESSION_ID}` itself: Stripe fills it in. The session is kept
(`stripe_checkouts`, with the prices it was for) until Stripe says how it ended.

`StripeErr` carries Stripe's own words (`No such price: 'price_x'`), or why it couldn't be reached.
A customer Stripe no longer has (deleted in the Dashboard, or test data cleared) is forgotten and
made again, and the session made with the new one.

Choose the mode from your own plan, never from the form: a price is Stripe's, but whether a button
subscribes or buys once is the app's. A user subscribed already changes plan in the portal; the
example's endpoint sends them to their account instead of to Checkout again.

## The page Checkout goes back to

```roc
Stripe.checkout_session! : Str, Str => Try(Stripe.Session, [NotYours, StripeErr(Str), DbErr(Str), ..])
```

Checkout goes back to the success URL as soon as it is paid, often before Stripe's events have come.
`checkout_session!(user, id)`, with the page's `?session_id=`, asks Stripe for the session (and its
subscription) and keeps both, so the page, and `subscribed!` after it, already say what was bought.
`NotYours` for a session of another user, or an id that isn't one. The events still count when
they come (their state is newer); `on_event!` runs for the events alone, so fulfil there.

## The Customer Portal

```roc
Stripe.portal! : Str, Str => Try(Str, [NoCustomer, StripeErr(Str), DbErr(Str), ..])
```

`portal!(user, return_url)` gives the URL of Stripe's portal for the user's customer: their plan,
their card, their invoices, cancelling. What they change there comes back as events. `NoCustomer`
when they have never checked out. What the portal offers is set in the Dashboard.

## Who has paid

All of these read the package's tables, never Stripe:

| Function | Is |
| --- | --- |
| `subscribed! : Str => Bool` | whether the user has a subscription that is `paying` |
| `paid_for! : Str, Str => Bool` | whether they pay for a price or a product (`price_…`, `prod_…`): a `paying` subscription with it among its items, or a one-time payment for the price that was paid (and not refunded in full, nor disputed) |
| `subscription! : Str => Try(Stripe.Subscription, [NotSubscribed, DbErr(Str), ..])` | their subscription: the one that hasn't ended (the one changed last, if several), else the one that ended last |
| `subscriptions! : Str => Try(List(Stripe.Subscription), [DbErr(Str), ..])` | all of them, the one changed last first |
| `payments! : Str => Try(List(Stripe.Payment), [DbErr(Str), ..])` | their one-time payments that were paid, the newest first |
| `customer! : Str => Try(Str, [NoCustomer, DbErr(Str), ..])` | their Stripe customer (`cus_…`) |

`subscribed!` and `paid_for!` are a no when the database can't be read (and an error on the log),
so a page they guard stays shut.

```roc
Stripe.Subscription : {
    id : Str, user : Str, customer : Str,
    status : Stripe.Status,
    items : List({ price : Str, product : Str, quantity : U64 }),
    current_period_end_ms : I64,      # when it renews, or ends
    cancel_at_period_end : Bool,      # cancelled in the portal: it ends then
    cancel_at_ms : I64,               # when it is set to end (0: it isn't)
    trial_end_ms : I64,               # 0: no trial
}

Stripe.Status : [Incomplete, IncompleteExpired, Trialing, Active, PastDue, Canceled, Unpaid, Paused, Other(Str)]
Stripe.Payment : { session : Str, prices : List({ price : Str, quantity : U64 }), amount_total : I64, currency : Str, paid_ms : I64 }
```

`Stripe.paying(status)` is `Active`, `Trialing` or `PastDue`: a payment that failed keeps access
while Stripe tries the card again, as the account's settings say (Billing, Revenue recovery); then
the subscription is `Unpaid` or `Canceled`. An app stricter than that reads `status` itself.
`Stripe.ended(status)` is `Canceled` or `IncompleteExpired`. `status_of` and `status_name` turn
Stripe's words (`past_due`) into a status and back. Amounts are in the currency's smallest unit
(1500 for $15.00), times in milliseconds since 1970.

A gate is middleware: the example's `subscribers` is `Auth.required_with` with
`Stripe.subscribed!` in its step, answering anyone else with a redirect to the pricing page.

## The webhook

`POST <webhook_at>`, behind the app's middleware (a request without an `Origin`, as Stripe's is,
passes `Middleware.same_origin`; middleware that wants every request signed in would refuse it).

1. **Its signature.** `Stripe-Signature` is `t=<seconds>,v1=<signature>[,v1=…]`. One `v1` must be
   the HMAC-SHA256, under `STRIPE_WEBHOOK_SECRET`, of `<t>.` followed by the request's body as it
   came (the bytes: never parsed and written again), compared in constant time; and `t` at most five
   minutes old, so a request someone kept can't be sent again later. Anything else is a 400, and a
   warning on the log.
2. **Once.** The event's id is recorded (`stripe_events`) in the transaction that handles it: one
   that comes again is answered 200 and not handled again, and two copies at once wait for each
   other.
3. **Kept.** In the same transaction: a Checkout Session's state (`stripe_checkouts`) and its
   customer linked to its user; a subscription's state (`stripe_subscriptions`); a deleted customer
   forgotten.
4. **The app's `on_event!`**, still in the transaction, with the event read (`Stripe.Event`). Its
   `Err`, or a database error, rolls all of it back and answers 500: Stripe sends the event again
   later, for up to three days. Otherwise a 200, `{"received":true}`.

```roc
Stripe.Event : { id : Str, type : Str, created_ms : I64, livemode : Bool, user : Str, about : Stripe.About, object : Str }
Stripe.About : [Session(Stripe.Session), Subscription(Stripe.Subscription), Invoice(Stripe.Invoice), Other]
Stripe.Session : { id : Str, user : Str, customer : Str, mode : [Payment, Subscription, Setup], status : [Open, Complete, Expired], paid : Bool, amount_total : I64, currency : Str, subscription : Str, prices : List({ price : Str, quantity : U64 }), metadata : List((Str, Str)) }
Stripe.Invoice : { id : Str, customer : Str, subscription : Str, status : Str, amount_due : I64, amount_paid : I64, currency : Str, hosted_url : Str, attempt_count : U64, billing_reason : Str }
```

`user` is the app's user the event is about: the session's `client_reference_id`, or the user whose
customer it names ("" when the package knows none: a customer made in the Dashboard). A session's
`prices` are those it was made with (none for one made elsewhere, a Payment Link's); `paid` is
`paid` or `no_payment_required`. `object` is the event's `data.object`, as Stripe sent it:
`StripeRules.text(event.object, ["field", "inside"])` reads anything else.

```roc
on_event! : Stripe.Event => Try({}, Str)
on_event! = |event|
    match event.about {
        Session(session) if session.mode == Payment and session.paid and event.type == "checkout.session.completed" =>
            Orders.fulfil!(event.user, session).map_err(|DbErr(why)| why)
        Invoice(invoice) if event.type == "invoice.payment_failed" =>
            Job.enqueue!(Jobs.card_failed, { user: event.user, pay_at: invoice.hosted_url }, {}).map_err(|JobErr(why)| why)
        _ => Ok({})
    }
```

Keep slow work (a fetch, sending mail) out of `on_event!`: queue a job, which commits with the
event. On Turso, a transaction that loses to another's write runs again, and `on_event!` with it.

**Events out of order.** Stripe doesn't promise any order, and sends an event again until it is
answered. A subscription's row keeps a version: the event's time in seconds, four times over, plus
its kind (`created` 0, any other 1, `deleted` 2). An event changes the row only if its version is as
high or higher, so one that comes late never puts an older state back; a subscription that has
ended stays ended. Two changes in the same second stand level: the package then asks Stripe for the
subscription as it is now, and keeps that. A Checkout Session only goes from `open` to `complete`
or `expired`, and stays `paid` once it is. What `checkout_session!` kept counts as older than any
event.

**API versions.** The package asks for `Stripe-Version: 2025-03-31.basil` (`Stripe.api_version`).
Events come in the webhook endpoint's own version; the package reads a subscription's period end and
an invoice's subscription from where either version keeps them (since basil, on the items and on
the invoice's `parent`).

## Anything else of Stripe's API

`Stripe.post!(path, fields)` and `Stripe.get!(path, query)` ask Stripe's API as the package does
(the secret key, `Stripe-Version`, an `Idempotency-Key` on a POST, tried again on a network error,
a 409, a 429 or a 5xx, unless Stripe says not to): Stripe's JSON, or `StripeErr`.
`StripeRules.text`, `int`, `bool`, `id_at`, `at` and `elements` read it.

`post!`'s idempotency key is new each call, so it guards against a retry of that call, not against
the app asking again (a job run again after a crash, a form sent twice). For a create the app may ask
twice, `Stripe.post_with!` takes a key of the app's own, the same each time the same thing is asked:
Stripe answers a key it has seen (for 24 hours) as it did the first time, and makes nothing more.

```roc
refund = Stripe.post_with!({ path: "/v1/refunds", fields: [("payment_intent", intent)], idempotency_key: "refund-order-${order.id}" })?
```

## The tables

`stripe/0001_stripe` and `stripe/0002_refunds`, the same on SQLite and on Postgres (times are
milliseconds, given by the package):

- `stripe_customers`: `user_id`, `customer_id`, `created_at`;
- `stripe_checkouts`: `id`, `user_id`, `customer_id`, `mode`, `prices` (JSON), `status`,
  `payment_status` (`paid`, or `refunded` and `disputed` once a charge's event says so),
  `amount_total`, `currency`, `subscription_id`, `payment_intent`, `created_at`, `updated_at`;
- `stripe_subscriptions`: `id`, `user_id`, `customer_id`, `status`, `items` (JSON),
  `current_period_end`, `cancel_at_period_end`, `cancel_at`, `trial_end`, `version`, `updated_at`;
- `stripe_events`: `id`, `event_type`, `created_at`, `handled_at`; swept after 30 days.

## Safety

- **No card ever reaches the app**: Checkout and the portal are Stripe's pages.
- **The webhook takes Stripe's word only**: a signature of the very bytes it was sent, under the
  endpoint's secret, compared in constant time, at most five minutes old. Without
  `STRIPE_WEBHOOK_SECRET` nothing is accepted (and the server doesn't start).
- **What the app reads is its own database**, kept by signed events, so a page that checks
  `subscribed!` doesn't wait on Stripe, and nothing the browser sends decides who has paid.
- **A checkout belongs to its user**: `checkout_session!` refuses another user's session.
- **Idempotency keys** on every create: a request tried again after a network error makes one
  customer, one session. A customer's key is the same for the same user and address, so two
  checkouts at once make one customer.
- **Test and live keys** are told apart at start; live keys under `--dev` are a warning on the log.

## Testing an app

`STRIPE_API_URL` points the package at a stand-in. `example/test/stand-in.mjs` is one: Node, no
dependencies, the endpoints the package calls answering with Stripe's objects, a `complete(id)` that
does what paying on Checkout's page does, `update`, `deleteCustomer`, `event(type, object)` and
`sign(body)` (a `Stripe-Signature` as Stripe makes it). Copy it into an app's tests. `stripe-mock`
(Stripe's own) answers every endpoint with fixed objects, but keeps no state.

## Status

Built and tested (D-082): Checkout (payments and subscriptions, trials, promotion codes), the
Customer Portal, the webhook (signatures, once, out of order), the tables on SQLite and Postgres, the
checks for who has paid. Not yet: Stripe Tax, metered billing, Connect, embedded Checkout, refunds
and invoices beyond `post!`. PROPOSALS.md has them.
