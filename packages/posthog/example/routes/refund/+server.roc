import pf.Server
import pf.Endpoint
import posthog.PostHog

## GET /refund: an error the app deals with (the refund is queued for a person to look at) but
## wants seen.
get! : { request : Server.Request, params : {}, context : c } => Try(Str, Endpoint.Refusal)
get! = |_input| {
	PostHog.capture!("the payment provider refused a refund", { order: 42, why: "expired card" })
	Ok("A person will look at your refund.")
}
