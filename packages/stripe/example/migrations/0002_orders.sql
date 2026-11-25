-- The e-books sold: a row an order, written by Billing.on_event! when Stripe says a Checkout Session
-- was paid. Its key is the session, so an order is written once.
create table orders (
    session_id text primary key,
    user_id text not null,
    what text not null,
    amount bigint not null,
    currency text not null,
    created_at bigint not null
);
