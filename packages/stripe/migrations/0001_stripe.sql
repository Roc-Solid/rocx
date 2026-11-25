-- packages/stripe's tables (D-082), the same on SQLite and on Postgres: every time is milliseconds
-- since 1970, given by the package, so its statements are the same on both. The webhook keeps them
-- in step with Stripe; the app reads them, never Stripe, to know who has paid.

-- Which Stripe customer each of the app's users is: made by the first checkout, and every checkout
-- and portal after uses it. Deleted when Stripe says the customer was (`customer.deleted`).
create table stripe_customers (
    user_id text primary key,
    customer_id text not null unique,
    created_at bigint not null
);

-- The Checkout Sessions the app made (`Stripe.checkout!`) and those Stripe told it of: whose, what
-- for (`prices`, JSON: each price and quantity asked for; `[]` for a session made elsewhere), and how
-- they ended. `status` only goes from `open` to `complete` or `expired`, and `payment_status` stays
-- `paid` once it is, so an event that comes late can't take either back.
create table stripe_checkouts (
    id text primary key,
    user_id text not null,
    customer_id text not null,
    mode text not null,
    prices text not null,
    status text not null,
    payment_status text not null,
    amount_total bigint not null,
    currency text not null,
    subscription_id text not null,
    created_at bigint not null,
    updated_at bigint not null
);
create index stripe_checkouts_user on stripe_checkouts (user_id);

-- Subscriptions as Stripe's events last said (`customer.subscription.*`): whose, their status as
-- Stripe writes it, their items (JSON: price, product, quantity), when the period ends, and whether
-- and when they end. `version` is the event's time in seconds × 4 plus its kind (created 0, any other
-- 1, deleted 2): an event changes the row only if its version is as high or higher, so one that
-- comes late never puts an older state back; and a subscription that has ended stays ended.
create table stripe_subscriptions (
    id text primary key,
    user_id text not null,
    customer_id text not null,
    status text not null,
    items text not null,
    current_period_end bigint not null,
    cancel_at_period_end boolean not null,
    cancel_at bigint not null,
    trial_end bigint not null,
    version bigint not null,
    updated_at bigint not null
);
create index stripe_subscriptions_user on stripe_subscriptions (user_id);
create index stripe_subscriptions_customer on stripe_subscriptions (customer_id);

-- The events the webhook has handled, by their id, so one sent again is answered and not handled
-- twice. Swept after 30 days (Stripe sends an event again for three days at most).
create table stripe_events (
    id text primary key,
    event_type text not null,
    created_at bigint not null,
    handled_at bigint not null
);
create index stripe_events_handled on stripe_events (handled_at);
