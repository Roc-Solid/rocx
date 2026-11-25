# packages/stripe: what comes next

What isn't built, each with what it needs. The first version (D-082) is Checkout, the Customer
Portal, the webhook and the checks for who has paid: what a small SaaS needs to charge from its first
day. None of these needs the platform.

## 1. Fulfilling from the page Checkout goes back to

`checkout_session!` keeps the session and its subscription, so `subscribed!` and `paid_for!` are
right at once, but the app's `on_event!` runs for the events alone. Stripe suggests fulfilling from
both, whichever comes first, idempotently. The package could run the app's own step once per
completed checkout (the first of the event and the page), keyed by the row's change from `open` to
`complete` in `stripe_checkouts`. Worth it once an app's fulfilment must show on that page (a
download link made then and there).

## 2. Stripe Tax

`automatic_tax[enabled]=true` on the session (and an address collected), and the customer's address
kept up to date (`customer_update[address]=auto`). Options on `Checkout`; nothing to keep beyond
what the session's `total_details` say. Needs the account's tax registrations, which are the app's
to make in the Dashboard.

## 3. Metered and per-seat billing

Per-seat is already a quantity (`prices: [{ price, quantity: 5 }]`), changed in the portal. Metered
billing reports usage: Stripe's Billing Meters (`POST /v1/billing/meter_events`, an event name, the
customer, a value), best sent in batches from a job. A `Stripe.meter!(user, event, value)` that
queues them, and a loop (or the jobs plugin) that sends them.

## 4. Changing a plan from the app

The portal changes plans, as the Dashboard allows. An app with its own plan page would call
`POST /v1/subscriptions/<id>` with the new item's price and `proration_behavior`; `post!` can, today.
A typed `Stripe.change!(user, price)` would read the subscription's item from the package's table.

## 5. Connect

Payments on behalf of others (marketplaces): connected accounts, their onboarding (Account Links),
`Stripe-Account` on requests, and a second webhook for their events. A package of its own, or a
module here; not for the first version.

## 6. Embedded Checkout and Elements

Checkout inside the app's page (`ui_mode: embedded`) needs Stripe.js in the browser, a client secret
and a script of the plugin's (as push's is). The hosted page is enough to start; this is for an
app that wants to keep its own frame around the payment.

## 7. Invoices and refunds, typed

`invoice.paid` and `invoice.payment_failed` reach `on_event!`, read; a list of a customer's invoices
and refunds go through `get!` and `post!`. Typed functions (`Stripe.invoices!(user)`,
`Stripe.refund!(payment)`) if apps ask for them.

## Open questions

- Should `past_due` count as paying (`Stripe.paying`)? It does now: Stripe tries the card again for
  a while, as the account's settings say, and cutting someone off at the first failed payment is
  harsh. An app can read `status` itself to be stricter.
- Should `rocx new` offer the plugin (a pricing page and an account page with the portal's button)?
