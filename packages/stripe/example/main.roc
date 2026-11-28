## packages/stripe's example: an app that sells a subscription (Basic or Pro, monthly) and an e-book
## (once), through Stripe's hosted Checkout. The plugin brings the rest (D-082), with the webhook a
## route of the app's (routes/stripe/webhook/, the package's handler, D-116) that keeps its tables in
## step with Stripe: the customers, the Customer Portal, and what the app reads
## to know who has paid for what. `Billing.on_event!` is the app's own part of each event: an
## e-book bought becomes an order. People sign in with packages/auth's dev sign-in (`rocx dev`: any
## address at once); `Accounts.admit!` keeps a row for each.
##
## Its pages: the pricing page (`/`), Checkout's way back (`/billing/done`), the account (`/account`:
## the subscription, cancelled or kept from there, its card and invoices, the orders, a button to
## the portal), a page for subscribers (`/pro`) and the e-book, for those who bought it (`/ebook`).
app [program] { auth: "../../auth/main.roc", crypto: "../../crypto/main.roc", pf: platform "../../../server/platform/main.roc", stripe: "../main.roc" }

import auth.Auth
import stripe.Stripe
import Generated/App

program = App.program({
	init!: |_started| Ok({}),
	plugins: [
		Auth.plugin({}),
		# STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET, from the environment (README.md: the Stripe CLI's
		# `stripe listen` gives the second).
		Stripe.plugin({}),
	],
	database: Sqlite("data/stripe.db"),
})
