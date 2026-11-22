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

**What is left.** The overrides no longer outlive a restart (an actor kept them in Postgres when the
app had a database). A plugin (D-033) with a table, `guard/0001_flags`, could load them into `Kv` at
its start and write them as they change, for an app that lists it.

## Open questions

1. **Which `RateLimit` headers.** The package sends the IETF draft's headers as most APIs send them
   today: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`, `RateLimit-Policy: 5;w=60`.
   The draft's latest version folds them into `RateLimit: "default";r=4;t=12` and a structured
   `RateLimit-Policy`. Keep the separate headers, or send the new pair (or offer both)?
2. **Where the flags' overrides live.** Today they are an actor's state, so with a database they
   are kept in `rocx_actors` and outlive a restart, without the package shipping a migration (a
   package can't ship one yet). Is that the right home, or should flags get a table of their own
   (and packages a way to add migrations)?
3. **Which environment variable names the environment.** The package reads `APP_ENV`, or else `dev`
   under `--dev`, or else `production`. Should the platform name it (`Env.name!`), so every
   package reads the same one?
4. **Failing open.** When a limit's count can't be reached (its actor busy for 30 s), the request is
   let through and logged, rather than refused. Right for a login form too?
5. **HSTS.** The default is a year, without `includeSubDomains` or `preload`, so one site can't put
   its subdomains on HTTPS-only by accident. Stricter by default?
