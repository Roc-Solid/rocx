## Guard: rate limits, feature flags and small request guards, for Roc Solid apps.
##
## - The logic, plain Roc on no platform, so the server and the browser decide alike and a test
##   runs it with a fake clock: rate limits as state in and state out (`RateLimit`, kept for many
##   clients in `Tally`), who a client is behind proxies (`ClientIp`, `Ip`), feature flags (`Flag`,
##   `Flags`), security headers (`Security`) and checks on a request (`Checks`).
## - The middleware that runs them on the server (`Guard`), with what it keeps between requests in
##   the server's memory (`Kept`: the rate limits' tallies; `FlagStore`: the flags' overrides), on
##   `Kv` (D-043). `FlagStore.plugin({})` keeps the overrides in the app's database too (D-057).
##
## It names the server platform, for the middleware; the browser's half sees the modules both
## halves can compile (`browser.roc`). The component that shows a flagged part of a page is
## `components/Flagged.rocx`, which `rocx build` copies into the app. See README.md.
package [Checks, ClientIp, Flag, FlagStore, Flags, Guard, Hash, Ip, Kept, RateLimit, Security, Tally] { pf: platform "../../server/platform/main.roc" }
