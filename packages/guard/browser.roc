## Guard as the browser's half of an app sees it: the modules that use no platform (the logic:
## rate limits, client addresses, feature flags, security headers, checks), which a page may use
## (`rocx build --client` names this header there). `main.roc` has these and the server's
## middleware (`Guard`, `Kept`, `FlagStore`).
package [Checks, ClientIp, Flag, Flags, Hash, Ip, RateLimit, Security, Tally] {}
