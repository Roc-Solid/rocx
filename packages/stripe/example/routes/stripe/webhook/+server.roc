import stripe.Stripe
import ../../../Billing

## Where Stripe sends its events (`POST /stripe/webhook`, packages/stripe): each checked and kept,
## then `Billing.on_event!`, the app's own part, in the same transaction.
respond! = |{ request, .. }| Stripe.webhook_route!(request, Billing.on_event!)
