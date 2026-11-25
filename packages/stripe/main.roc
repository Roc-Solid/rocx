## Stripe: payments and subscriptions for Roc Solid apps, as a plugin (D-082). `Stripe` is the
## plugin, its webhook and the functions an app calls (Checkout, the Customer Portal, who has paid
## for what); `StripeStore` its statements, the same on SQLite and on Postgres (`migrations/`);
## `StripeRules` what is plain Roc, with its `expect`s (a webhook's signature, Stripe's objects read
## from any API version, the order events are kept in, the Checkout Session's form). It names the
## server platform, so only the server's half of an app sees it. README.md is the reference;
## PROPOSALS.md says what comes next.
package [Stripe, StripeRules, StripeStore] { crypto: "../crypto/main.roc", pf: platform "../../server/platform/main.roc" }
