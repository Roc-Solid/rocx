-- Customers whose users the app deleted (D-135, `Stripe.forget!`): Stripe's id for each, and when.
-- An event about one of them (the customer's deletion, its subscription's end, which Stripe sends
-- after `forget!` deleted the customer there) is recorded as handled and kept nowhere else, so it
-- can't bring a forgotten user's rows back. The id names no person: Stripe deleted the customer.
create table stripe_forgotten (
    customer_id text primary key,
    forgotten_at bigint not null
);
