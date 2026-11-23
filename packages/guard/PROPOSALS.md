# guard: proposals

What packages/guard needs from outside its folder. Nothing here is implemented: the package works
without it today, in the ways README.md's "Status" says, and each proposal says what would get
better.

## Server-only modules in packages

**Done (D-033, D-043).** A package may name the server platform, with a `browser.roc` for the
browser's half (D-033); guard does (D-043), so an app imports `guard.Guard` and copies nothing.
What still kept guard copied, its state in actors (whose kinds `rocx build` finds only in the
app's files), is gone too: see "Memory" below.

## The client's address

**Done (D-041).** The host hands Roc one record for each request, the connection's address in it,
and `Server.Request` has it as `peer` (`""` in the browser and for a request made by hand; a GET a
page reads as the server renders it has the page's). The field was chosen over an effect
(`Server.peer!`), which this proposal had recommended: the request says where it came from, as it
says its headers, and a middleware or a test sees it without asking the host. `Guard`'s `peer`
reads it, so `Guard.ip(Direct)` limits by address, and `Proxies(…)` checks that a connection came
from one of the app's proxies.

## Memory: state between requests

**Done (D-043).** `Kept` keeps each limit's tallies in `Kv` and changes one with `Kv.swap!`, a
compare-and-swap the platform added for it (a read, a pure change, and a swap that fails if
another request changed it first, read again then), so the package's token bucket and sliding
window are as they were, with no message, no call of its own and no write to Postgres per limited
request. `FlagStore` keeps the overrides in `Kv` the same way.

**Overrides that outlive a restart: done (D-057).** An app with a database lists the package's
plugin (`FlagStore.plugin({})`, D-033): its table, `guard_flags` (migration `guard/0001_flags`, for
Postgres and for SQLite and Turso), a row a flag, read into `Kv` at its start; `set!` and `reset!`
write the flag's row and change `Kv` in one transaction. Without it, `Kv` alone.

## Open questions

1. **Which `RateLimit` headers.** The package sends the IETF draft's headers as most APIs send them
   today: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`, `RateLimit-Policy: 5;w=60`.
   The draft's latest version folds them into `RateLimit: "default";r=4;t=12` and a structured
   `RateLimit-Policy`. Keep the separate headers, or send the new pair (or offer both)?
2. **Where the flags' overrides live.** Answered (D-057): in memory (`Kv`), and, for an app that
   lists the package's plugin, in a table of their own too (packages ship migrations as plugins,
   D-033).
3. **Which environment variable names the environment.** The package reads `APP_ENV`, or else `dev`
   under `--dev`, or else `production`. Should the platform name it (`Env.name!`), so every
   package reads the same one?
4. **Failing open.** When a limit's count can't be reached (its actor busy for 30 s), the request is
   let through and logged, rather than refused. Right for a login form too?
5. **HSTS.** The default is a year, without `includeSubDomains` or `preload`, so one site can't put
   its subdomains on HTTPS-only by accident. Stricter by default?
