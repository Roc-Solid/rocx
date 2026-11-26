-- The PaymentIntent (`pi_…`) a one-time payment's checkout was paid by, so a charge's event, which
-- names it, finds the checkout: refunded in full (`charge.refunded`), its `payment_status` is
-- `refunded`; disputed (`charge.dispute.created`), `disputed`, and `paid` again if the dispute is
-- won (`charge.dispute.closed`). Neither is paid (`Stripe.paid_for!`, `Stripe.payments!`). '' for
-- a checkout of no PaymentIntent (a subscription's, or one not paid). The same on SQLite and Postgres.
alter table stripe_checkouts add column payment_intent text not null default '';
create index stripe_checkouts_payment_intent on stripe_checkouts (payment_intent);
