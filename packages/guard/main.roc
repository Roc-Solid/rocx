## Guard: rate limits, feature flags and small request guards, for Roc Solid apps. This is the
## logic, plain Roc on no platform, so the server and the browser decide alike and a test runs it
## with a fake clock: rate limits as state in and state out (`RateLimit`, kept for many clients in
## `Tally`), who a client is behind proxies (`ClientIp`, `Ip`), feature flags (`Flag`, `Flags`),
## security headers (`Security`) and checks on a request (`Checks`).
##
## The middleware that runs them on the server (`server/Guard.roc`, `server/FlagStore.roc`) imports
## the server platform, which a package can't; the component that shows a flagged part of a page
## (`components/Flagged.rocx`), the web platform's `Html`. See README.md and PROPOSALS.md.
package [Checks, ClientIp, Flag, Flags, Hash, Ip, RateLimit, Security, Tally] {}
