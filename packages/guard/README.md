# guard

Rate limits, feature flags and small request guards for Roc Solid apps, as middleware. A login
form takes 5 tries a minute from each client; an API, 100 a minute for each user; a new checkout
goes to staff first, then to a quarter of everyone; every answer carries sane security headers;
and the whole site can go into maintenance from an admin page.

```roc
# Middlewares.roc
import pf.Middleware
import pf.Server
import guard.RateLimit
import guard.Security
import Guard
import Features

Middlewares := [].{

	Context : { facts : Str, user : Str }

	## Every request: who is signed in, then the guards.
	default : Middleware({ facts : Str }, Context)
	default =
		signed_in
			.then(Guard.security_headers(Security.defaults))
			.then(Guard.body_limit(1_000_000))
			.then(Guard.maintenance({ flag: Features.maintenance, message: "Back soon.", retry_after_s: 600, except: ["/admin"] }))
			.then(Guard.under("/api", Middlewares.api_limit))

	## 5 a minute from each client, behind one proxy.
	login_limit : Middleware(Context, Context)
	login_limit = Guard.rate_limit("login", RateLimit.per_minute(5), Guard.ip(Hops(1)))

	## 100 a minute for each user, or each address when signed out.
	api_limit : Middleware(Context, Context)
	api_limit = Guard.rate_limit("api", RateLimit.per_minute(100), Guard.user(|context| context.user, Hops(1)))

	## Only for those with the new checkout on.
	beta : Middleware(Context, Context)
	beta = Guard.feature(Features.new_checkout, |context| { user: context.user, groups: [] })

	## Only for the app's admins (ada): anyone else is answered 403.
	admins : Middleware(Context, Context)
	admins = Middleware.make(|request, context, next!| if (context.user == "ada") next!(request, context) else Server.refused(403, "Admins only."))
}

## Who is signed in: the `user` cookie, handed on as `context.user`. A stand-in for the app's own
## sign-in: the cookie isn't signed, so anyone can claim any name. A real app reads its session.
signed_in : Middleware({ facts : Str }, Middlewares.Context)
signed_in = Middleware.make(|request, context, next!| next!(request, { facts: context.facts, user: Server.cookie(request, "user") ?? "" }))
```

```roc
# routes/login/+server.roc
middleware = Middlewares.login_limit
```

The sixth try in a minute is answered `429 Too Many Requests`, with `Retry-After` and the
`RateLimit-*` headers. Every guard hands on the context it is given, so they go anywhere in a
chain. (This is `example/Middlewares.roc`: `example/` is a whole app that builds and runs with the
package. See "Status".)

## Three parts

**The logic is a Roc package** (`main.roc`): plain Roc on no platform. A rate limit is arithmetic
(state and time in, a decision and the next state out), so its tests run with a fake clock, and a
flag is decided by the same function on the server and in the browser.

| Module | What it does |
|---|---|
| `RateLimit` | a limit: `RateLimit.per_minute(5)` (a token bucket: a burst of 5, then one each 12 s), `.sliding()` (at most 5 in any minute); `.check(state, now)` decides one request; `headers` and `explain` say why it was refused |
| `Tally` | many clients' states by key, bounded: idle clients dropped first, then the one seen longest ago; `Tally.hit(tally, limit, key, now, room)` |
| `ClientIp` | who sent a request, behind proxies the app trusts: `Direct`, `Header("fly-client-ip")`, `Hops(1)`, `Proxies(Ip.private)` |
| `Ip` | IPv4 and IPv6 addresses and CIDR ranges: `Ip.parse`, `Ip.cidrs(["10.0.0.0/8"])`, `Ip.within_any`, `Ip.key` (an IPv6 client by its /64) |
| `Flag` | a feature flag in code: `Flag.define(name, about, rule)`, `.in_env("dev", Flags.on)` |
| `Flags` | who has a flag on: rules (`Flags.on`, `off`, `rollout(25)`, `only(users, groups)`), `is_on`, `values` (for the browser), `enabled`, overrides (`set`, `reset`), `describe` (for an admin page) |
| `Security` | security headers: `Security.defaults`, the CSP's `directives`, `directive` to change one, `csp` |
| `Checks` | plain checks on a request: `methods`, `hosts`, `body_size`, `ips`, `maintenance` |

`roc test packages/guard/main.roc` runs their `expect`s.

**The middleware is server-only Roc** (`server/`): `Guard` (every guard), `FlagStore` (flags while
the server runs) and `Kept` (what the guards keep between requests). They import the server
platform (`Middleware`, `Server`, `Time`, `Env`, `Log`, `Actor`), which a package can't: a Roc Solid
app is two apps, and a package may only name the very platform its app does. (`server/main.roc`
names the server platform so that `roc check packages/guard/server/main.roc` checks the three on
their own; it isn't copied.)

**The component is a `.rocx` file** (`components/Flagged.rocx`), which `rocx build` copies into the
app, as it copies packages/charts' charts.

### Using it today

1. Name the package in the app's header (main.roc's, and the browser's, which `rocx build --client`
   writes from it): `guard: "../packages/guard/main.roc"`.
2. Copy `server/Guard.roc`, `server/FlagStore.roc` and `server/Kept.roc` into the app, beside its
   main.roc, and import them by name (`import Guard`, `import FlagStore`). `rocx build` doesn't
   copy a package's server-only modules yet: PROPOSALS.md, "Server-only modules in packages", asks
   it to, into the server's half only.
3. `import guard.Flagged` in a `.rocx` file: `rocx build` copies the component.

`example/` does all three: copy those three modules into it, then `rocx build .` there.

## Rate limits

```roc
Guard.rate_limit(name, policy, key)                                     # up to 10,000 clients
Guard.rate_limit_with({ name, policy, key, max_keys: 50_000 })
```

- **The policy.** `RateLimit.per_second(n)`, `per_minute(n)`, `per_hour(n)`, `per(n, window_ms)`
  are token buckets: a client may send `n` at once, and then one each `window / n`. `.sliding()`
  counts a sliding window instead: never more than `n` in any window, and no burst at a window's
  edge. Its count is estimated from this window's requests and the last one's (as Cloudflare and
  nginx count), so each client costs two numbers, however high the limit. A refused request isn't
  counted: hammering doesn't push the next allowed one back.
- **The key: who is counted.** `Guard.ip(trust)` (the client's address; an IPv6 one by its /64,
  the block one household is given), `Guard.user(|context| context.user, trust)` (the signed-in
  user, or the address when signed out), `Guard.route` (the method and path) and
  `Guard.both(key, key)`; or any `Server.Request, context -> Str`. A request whose key is `""`
  isn't limited.
- **Each route its own.** `name` keeps limits apart: name one in a route file's `middleware`, or put
  `Guard.under("/api", …)` in the default middleware for a whole tree.
- **Answers.** Allowed: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset` (seconds until
  the whole limit is back) and `RateLimit-Policy` (`5;w=60`). Refused: 429, those, `Retry-After`
  (seconds until one more would be allowed, exactly), and `Too many requests: try again in 12 s.`
- **Memory stays bounded.** Each limit keeps at most `max_keys` clients. A client whose limit is
  whole again is forgotten first (that changes nothing); past `max_keys`, the one seen longest ago
  (it starts again). The clients are split over 64 tallies, so a request reads and writes about a
  hundred and fifty of them at most.
- **When the count can't be reached** (its actor busy for 30 s), the request goes on, and the log
  says so: a limiter that fails shouldn't take the site down with it.

### Behind a proxy

A client can send any `X-Forwarded-For` it likes, so it is read only as far as the app says its own
proxies wrote it:

| `trust` | The client is |
|---|---|
| `Direct` | the connection's address; headers ignored |
| `Header("fly-client-ip")` | what that header says (`cf-connecting-ip`, `x-real-ip`): a proxy that sets it, replacing the client's |
| `Hops(1)` | the address the outermost of so many proxies saw: that many places from the right of `X-Forwarded-For` |
| `Proxies(Ip.private)` | the first address, from the right, that isn't one of the app's proxies (`Ip.cidrs([…])`) |

The connection's address is the request's `peer` (`Server.Request`, D-041): with no proxy in
front, `Direct` is the client; behind one, `peer` is the proxy, and `Hops` or `Proxies` read past it
in `X-Forwarded-For`. `Proxies` also checks that the connection came from one of the app's proxies,
so a client that reaches the server directly can't name anyone it likes.

## Feature flags

```roc
# Features.roc
Features := [].{
	new_checkout : Flag
	new_checkout = Flag.define("new_checkout", "The one-page checkout", { ..Flags.rollout(25), users: ["ada"], groups: ["staff"] })
		.in_env("dev", Flags.on)

	maintenance : Flag
	maintenance = Flag.define("maintenance", "Down for maintenance", Flags.off)

	all : List(Flag)
	all = [Features.new_checkout, Features.maintenance]
}
```

A rule (`Flag.Rule`) says who has a flag on: `on` (off is off for everyone: a kill switch), then
`users`, `groups`, and `percent` of everyone else signed in. Each user falls in or out of a rollout
the same way every time (a hash of the flag's name and theirs), raising it only adds people, and
two flags at 50% don't pick the same half. Signed out, a visitor has nothing to be counted by: a
rollout reaches them at 100.

What the code says is the default. The environment picks among a flag's rules (`in_env`): `APP_ENV`
if it is set, or else `dev` under `--dev`, or else `production`. A rule set while the server runs
replaces the code's until it is reset, kept in memory and, with a database, in Postgres:

```roc
FlagStore.set!("new_checkout", Flags.rollout(50))?      # from an admin page
FlagStore.reset!("new_checkout")?                         # the code's rule again
FlagStore.describe!(Features.all)                         # each flag: the rule in force, the code's, overridden?
```

**On the server**: `FlagStore.is_on!(Features.new_checkout, { user, groups })` in an endpoint, or
a route only some may reach (anyone else gets 404):

```roc
# routes/beta/+server.roc: `Middlewares.beta` is Guard.feature(Features.new_checkout, …), above
middleware = Middlewares.beta
```

**In a page**: the server decides the flags once for the visitor, and the page shows a part only
when its flag is on. The server renders the page with them and puts the answer in it, so the
browser hydrates with the same values, without asking again. The flags are a GET endpoint at a
path of its own, its handler reading the visitor from its `context`, which the layout reads with
`Endpoint.get!` (D-023):

```roc
# routes/flags/+server.roc: GET /flags (its handler runs on the server only)
get! : { request : Server.Request, params : {}, context : Middlewares.Context } => Try(Flags.Values, Endpoint.Refusal)
get! = |{ context, .. }| Ok(FlagStore.values!(Features.all, { user: context.user, groups: [] }))
```

```roc
# Visitor.rocx: read as the page renders, and carried in the page
flags! : {} => Flags.Values
flags! = |{}| Endpoint.get!(Api.get_flags({}))
```

```roc
# routes/+layout.rocx (needs `import pf.Context` and `import guard.Flagged`)
<FlagsContext value={Visitor.flags!({})}>
	<main>{...children}</main>
</FlagsContext>

# anywhere below it
<Flagged name="new_checkout" fallback={<OldCheckout />}>
	<NewCheckout />
</Flagged>
```

| `<Flagged>` prop | |
|---|---|
| `name : Str` | the flag's name |
| `fallback : Html` | what shows when it is off (nothing, unless given) |
| children | what shows when it is on |

`Flags.enabled(values, name)` reads one where a `<Show>` reads better.

## Other guards

| Guard | |
|---|---|
| `Guard.security_headers(Security.defaults)` | `Content-Security-Policy`, `Strict-Transport-Security` (a year), `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN`, `Cross-Origin-Opener-Policy: same-origin`; a header the answer sets itself is kept. Under `--dev`, no HSTS, and the CSP only reports |
| `Guard.body_limit(bytes)` | a larger body refused, 413 |
| `Guard.methods(["GET", "POST"])` | any other method refused, 405, with `Allow` |
| `Guard.hosts(["example.com", "*.example.com"])` | any other `Host` refused, 400 |
| `Guard.ips({ allow, deny, trust })` | an address in `deny`, or (when `allow` lists any) not in `allow`, refused, 403 |
| `Guard.maintenance({ flag, message, retry_after_s, except })` | while the flag is on, 503 with `Retry-After` and a small page (text for a non-browser), but under `except` (`/admin`, `/health`) |
| `Guard.feature(flag, who)` | 404 for anyone who doesn't have the flag on |
| `Guard.under("/api", guard)` | `guard` for paths under `/api` only |

The default CSP fits a Roc Solid app: its scripts and its WebAssembly from its own origin
(`'wasm-unsafe-eval'`, which a page needs to start wasm under a CSP), styles inline too (components
write `style="…"`), its calls to its own server. To allow images from elsewhere:

```roc
{ ..Security.defaults, content_security_policy: Security.csp(Security.directive(Security.directives, "img-src", ["'self'", "https://images.example.com"])) }
```

## Status

Works today, tested: every module of the package (211 `expect`s), and `example/`, an app with the
server modules copied in by hand. Its admin endpoint answered 403 to anyone but an admin. Its login
limit answered 429 on the sixth try, with the headers above; its `/api` limit counted users and
addresses apart; flags and their overrides, the feature route and maintenance mode worked, set at
runtime; and a page with `<Flagged>` rendered the right part for each user and hydrated strictly in
Chromium, under the default CSP.

Waits on a proposal (PROPOSALS.md):

- **Server-only modules in packages**: until then, `Guard`, `FlagStore` and `Kept` are copied into
  the app by hand.
- **Memory: state between requests**: the platform has a place for it now, `Kv` (D-028), but the
  guards haven't moved onto it. Until they do, they keep their state as actors' state, a message
  for each limited request and each read of the flags. With a database, the platform writes an
  actor's state to Postgres only when a message changes it (D-021): a limited request moves a
  tally, so it costs a write; a flag read changes nothing and writes nothing (setting or resetting
  an override does).
- The server reads a body (up to 16 MiB) before any middleware runs, so `body_limit` refuses a large
  body after it has come, not before (DECISIONS.md, D-014).
