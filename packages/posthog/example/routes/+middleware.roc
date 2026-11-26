import pf.Middleware
import pf.Server
import posthog.PostHog

## Who asks, from the `x-user` header ("" for nobody).
who : Middleware({ started : Str }, { started : Str, user : Str })
who = Middleware.make(|request, context, next!| next!(request, { started: context.started, user: Server.header(request, "x-user") ?? "" }))

## Every request: who asks, then every 5xx answer reported, with them.
middleware = who.then(PostHog.middleware(|context| context.user))
