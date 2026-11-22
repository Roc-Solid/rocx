## Errors reported to PostHog's error tracking, from the app itself (`PostHog.plugin`, a middleware,
## `capture!`): kept in the server's memory and sent as `$exception` events (`Event`), each with a
## fingerprint of its own (`Fingerprint`). It names the server platform, so only an app on it names
## this package; the browser's half doesn't see it.
package [Event, Fingerprint, PostHog] { pf: platform "../../server/platform/main.roc" }
