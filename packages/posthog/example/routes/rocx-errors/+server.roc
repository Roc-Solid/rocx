import posthog.PostHog

## Where a page's script sends its errors (`POST /rocx-errors`, packages/posthog).
respond! = |{ request, .. }| PostHog.errors_route!(request)
