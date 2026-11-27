import posthog.PostHog

## The page's script (`GET /rocx-errors.js`, packages/posthog), which sends to /rocx-errors.
respond! = |{ request, .. }| PostHog.script_route(request)
