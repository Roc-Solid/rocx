# guard

Rate limits, feature flags and small request guards for Roc Solid apps, as middleware. A login
form takes 5 tries a minute from each client, an API 100 a minute for each user, and a new
checkout goes to staff first, then to a quarter of everyone. Every answer carries security
headers, and an admin can put the whole site into maintenance.

What a guard decides is plain Roc: a rate limit is state and time in, a decision and the next
state out, so a test runs it with a fake clock, and a flag is decided by the same function on the
server and in the browser.

The user guide, with tables the package worked out and a live rate limit, is the docs site's
Guard page (`/ecosystem/guard`). This README is the reference.

```roc
# Middlewares.roc
import pf.Middleware
import pf.Server
import guard.RateLimit
import guard.Security
import guard.Guard
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
`RateLimit-*` headers. (A browser's plain form goes back to its page with a flash instead.) Every
guard hands on the context it is given, unchanged, so you can put guards anywhere in a chain.

This is `example/Middlewares.roc`. `example/` is a whole app that builds and runs with the package,
and `example/test/` asks it over HTTP.

## Installing it

1. Name the package in the app's header (`main.roc`). The app must be on the server platform,
   since the middleware uses it:

   ```roc
   app [program] { guard: "../packages/guard/main.roc", pf: platform "../server/platform/main.roc" }
   ```

2. `import guard.Guard` (and `guard.FlagStore` for flags) in the server's modules: your middleware,
   your endpoints.
3. `import guard.Flagged` in a `.rocx` file, for `<Flagged>`. `rocx build` copies the component
   into the app.
4. Optional, for an app with a database: list the plugin, so feature flags' overrides outlive a
   restart (see "Changed while the server runs"):

   ```roc
   import guard.FlagStore

   program = App.program({ …, database: Sqlite("data/app.db"), plugins: [FlagStore.plugin({})] })
   ```

`example/` does all four.

## How it is built

**The logic is plain Roc on no platform**, so both halves of an app, and a test, can use it.
`browser.roc` lists these modules for the browser's half.

| Module | What it does |
|---|---|
| `RateLimit` | a limit, as arithmetic: `per_second(n)`, `per_minute(n)`, `per_hour(n)`, `per(n, window_ms)` (token buckets), `.sliding()`; `fresh(now)`, `check(state, now)`, `idle(state, now)`; `headers` and `explain` for a refusal; the `State` and `Decision` records |
| `Tally` | many clients' states by key, bounded: `Tally.empty`, `Tally.hit(tally, limit, key, now, room)`, `len`, `keeps`, `to_str`, `from_str`, `shard(key, count)` |
| `ClientIp` | who sent a request, behind the proxies the app trusts: `ClientIp.of(trust, peer, headers)` with a `Trust` of `Direct`, `Header(name)`, `Hops(n)` or `Proxies(cidrs)`; `forwarded_for(headers)` |
| `Ip` | IPv4 and IPv6 addresses and CIDR ranges: `parse`, `to_str`, `cidr`, `cidrs`, `within`, `within_any`, `key` (an IPv6 client by its /64), `private` |
| `Flag` | a feature flag in code: `Flag.define(name, about, rule)`, `.in_env(env, rule)`, `.rule_in(env)`; the `Rule` record |
| `Flags` | who has a flag on: rules (`on`, `off`, `rollout(percent)`, `only(users, groups)`), `anyone`; `is_on`, `decide`, `rule_for`, `bucket`; `values` and `enabled` (for a page); overrides (`set`, `reset`, `overrides_to_str`, `overrides_from_str`); `describe` (for an admin page) |
| `Security` | security headers: `defaults`, the CSP's `directives`, `directive` to change one, `csp`, `headers(config, { dev })`, `added` |
| `Checks` | plain checks on a request, each `Ok({})` or a `Refusal` (status, headers, body): `methods`, `hosts`, `body_size`, `ips`, `maintenance` |
| `Hash` | a small, stable, non-cryptographic hash of text (FNV-1a, mixed): `of`, and `bucket(text, count)`, which puts a user in or out of a rollout and a key in a tally |

`roc test packages/guard/main.roc` runs their `expect`s.

**The middleware is the server's half.** `Guard` (every guard), `FlagStore` (flags while the server
runs, and the plugin) and `Kept` (the rate limits' tallies between requests) import the server
platform (`Middleware`, `Server`, `Endpoint`, `Time`, `Env`, `Log`, `Kv`, `Db`, `Plugin`). So
`main.roc` names the server platform, and the browser's half of an app sees only `browser.roc`'s
modules.

**The component is a `.rocx` file**, `components/Flagged.rocx`, which `rocx build` copies into the
app (into `Generated/guard/`), as it copies packages/charts' charts.

## Rate limits

```roc
Guard.rate_limit(name, policy, key)                                     # up to 10,000 clients
Guard.rate_limit_with({ name, policy, key, max_keys: 50_000 })
```

- **The policy.** `RateLimit.per_second(n)`, `per_minute(n)`, `per_hour(n)` and `per(n, window_ms)`
  are token buckets: a client may send `n` at once, and then one each `window / n`. `.sliding()`
  counts a sliding window instead: never more than `n` in any window, and no burst at a window's
  edge. Its count is estimated from this window's requests and the last one's (as Cloudflare and
  nginx count), so each client costs two numbers, however high the limit. A refused request isn't
  counted, so hammering doesn't push the next allowed one back. Every number is whole
  (milliseconds), so nothing drifts however long the server runs.
- **The key: who is counted.** `Guard.ip(trust)` counts the client's address (an IPv6 one by its
  /64, the block one household is given). `Guard.user(|context| context.user, trust)` counts the
  signed-in user, or the address when signed out. `Guard.route` counts the method and path, and
  `Guard.both(key, key)` each pair. A key is any `Server.Request, context -> Str`. A request whose
  key is `""` isn't limited.
- **Each limit its own name.** `name` keeps limits' counts apart. Put a limit in a route file's
  `middleware` for one route, or `Guard.under("/api", …)` in the default middleware for a whole
  tree.
- **Answers.** An allowed request gets `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`
  (seconds until the whole limit is back) and `RateLimit-Policy` (`5;w=60`). A refused one gets
  429, those headers, `Retry-After` (exactly the seconds until one more would be allowed), and the
  text `Too many requests: try again in 12 s.` A browser's form posted without the runtime
  (`Endpoint.posted_by` is `PlainForm`) is refused as an endpoint refuses one: a 303 back to its
  page, with what was typed and a flash of the 429 and that line (`Server.flash_back!`), so the
  form shows it where it shows any refusal.
- **Memory stays bounded.** Each limit keeps at most `max_keys` clients. A client whose limit is
  whole again is forgotten first (that changes nothing). Past `max_keys`, the client seen longest
  ago is forgotten (it starts again). A limit's clients are split over 64 tallies, so a request
  reads and writes about a hundred and fifty of them at most.
- **Kept in the server's memory** (`Kv`), each tally under `guard:<limit>/<shard>`, never written
  to the database; a restart starts every limit again. A hit reads its tally and swaps the next one
  in (`Kv.swap!`). Of two requests at once, one wins and the other reads again, so no hit is lost.
  When the tally changed under 50 tries in a row, the request goes on, and the log says so: a
  limiter that fails shouldn't take the site down with it.

### Behind a proxy

A client can send any `X-Forwarded-For` it likes, so the header is read only as far as the app
says its own proxies wrote it:

| `trust` | The client is |
|---|---|
| `Direct` | the connection's address; headers ignored |
| `Header("fly-client-ip")` | what that header says (`cf-connecting-ip`, `x-real-ip`), for a proxy that sets it, replacing the client's |
| `Hops(1)` | the address the outermost of so many proxies saw: that many places from the right of `X-Forwarded-For` |
| `Proxies(Ip.private)` | the first address, from the right, that isn't one of the app's proxies (`Ip.cidrs([…])`) |

The connection's address is the request's `peer` (`Server.Request`). With no proxy in front,
`Direct` is the client. Behind one, `peer` is the proxy, and `Hops` or `Proxies` read past it in
`X-Forwarded-For`. `Proxies` starts at `peer`, so a client that reaches the server directly is
itself the client, whatever it writes in the header.

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

A rule (`Flag.Rule`, `{ on, percent, users, groups }`) says who has a flag on:

- `on`: when it is false, the flag is off for everyone, whatever the rest says (a kill switch).
- `users`: these users have it on.
- `groups`: and anyone in one of these groups.
- `percent`: and this share of everyone else who is signed in. At 100, everyone, signed in or not.

Each user falls in or out of a rollout the same way every time (a hash of the flag's name and
theirs), so raising the share only adds people, and two flags at 50% don't pick the same half. A
visitor who isn't signed in has no id to be counted by, so a rollout reaches them only at 100.

The environment picks among a flag's rules (`in_env`): `APP_ENV` if it is set, or else `dev` when
the server was started with `--dev`, or else `production`.

### Changed while the server runs

What the code says is the default. A rule set while the server runs replaces the code's until it
is reset:

```roc
FlagStore.set!("new_checkout", Flags.rollout(50))?      # from an admin page
FlagStore.reset!("new_checkout")?                         # the code's rule again
FlagStore.describe!(Features.all)                         # each flag: the rule in force, the code's, overridden?
```

An override is kept in the server's memory (`Kv`, under `guard:flags`), so a restart forgets it and
the code's rules stand again. An app with a database can list the package's plugin,
`FlagStore.plugin({})`. Then each override is also a row in the app's database (table
`guard_flags`, migration `guard/0001_flags`, for Postgres, SQLite and Turso), read back into memory
as the server starts, and `set!` and `reset!` write the row and memory in one transaction. The
plugin needs a database: an app without one doesn't list it, and keeps its overrides in memory
alone.

| `FlagStore` | What it does |
|---|---|
| `plugin({})` | the plugin: the `guard_flags` table, loaded as the server starts |
| `is_on!(flag, { user, groups })` | whether `who` has the flag on now |
| `values!(flags, who)` | each flag decided for `who`: what a page sends the browser |
| `describe!(flags)` | each flag as an admin page shows it: the rule in force, the code's, and whether an override replaces it |
| `set!(name, rule)`, `reset!(name)` | an override, and dropping it; `Err(FlagErr(why))` when the database refuses |
| `env!({})`, `overrides!({})`, `settings!({})` | the environment, the overrides, and both together (`Flags.Settings`) |

### On the server

`FlagStore.is_on!(Features.new_checkout, { user, groups })` answers in an endpoint. To keep a whole
route from anyone who doesn't have a flag on (they get 404), use `Guard.feature`:

```roc
# routes/beta/+server.roc: `Middlewares.beta` is Guard.feature(Features.new_checkout, …), above
middleware = Middlewares.beta
```

### In a page

The server decides the flags once for the visitor, and the page shows a part only when its flag is
on. The server renders the page with the flags and puts the answer in it, so the browser hydrates
with the same values, without asking again. The flags are a GET endpoint at a path of its own,
whose handler reads the visitor from its `context`. The layout reads it with `Endpoint.get!`:

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

| `<Flagged>` prop | Is |
|---|---|
| `name : Str` | the flag's name |
| `fallback : Html` | what shows when it is off (nothing, unless given) |
| children | what shows when it is on |

`<FlagsContext>` is `Flagged.flags_context`, a context of `Flags.Values`. Where nothing provides
it, every flag is off. `Flags.enabled(values, name)` reads one flag where an `if` reads better:
`{if (Flags.enabled(flags, "beta")) <Beta /> else <Old />}`.

## Other guards

| Guard | Does |
|---|---|
| `Guard.security_headers(Security.defaults)` | adds `Content-Security-Policy`, `Strict-Transport-Security` (a year), `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN` and `Cross-Origin-Opener-Policy: same-origin` to every answer; a header the answer sets itself is kept. Under `--dev`, no HSTS, and the CSP only reports |
| `Guard.body_limit(bytes)` | refuses a larger body, 413 |
| `Guard.methods(["GET", "POST"])` | refuses any other method, 405, with `Allow` |
| `Guard.hosts(["example.com", "*.example.com"])` | refuses any other `Host`, 400 |
| `Guard.ips({ allow, deny, trust })` | refuses an address in `deny`, or (when `allow` lists any) one not in `allow`, 403 |
| `Guard.maintenance({ flag, message, retry_after_s, except })` | while the flag is on, answers 503 with `Retry-After` and a small page (text for a client that isn't a browser), except under the paths in `except` (`/admin`, `/health`) |
| `Guard.feature(flag, who)` | answers 404 to anyone who doesn't have the flag on |
| `Guard.under("/api", guard)` | runs `guard` for `/api` and the paths under it only (not `/apiary`) |

The default CSP fits a Roc Solid app: scripts and WebAssembly from the site's own origin
(`'wasm-unsafe-eval'`, which a page needs to start wasm under a CSP), styles inline too (components
write `style="…"`), and calls to its own server. To allow images from another host:

```roc
{ ..Security.defaults, content_security_policy: Security.csp(Security.directive(Security.directives, "img-src", ["'self'", "https://images.example.com"])) }
```

## Status

Works today. Every module of the package is tested by its `expect`s, and `example/` by
`example/test/guard.test.mjs`, which asks it over HTTP (`just test-server` runs it). The tests
check that:

- the login limit answers 429 on the sixth try, with `Retry-After` and `RateLimit-Policy`, and a
  plain form's refusal goes back to its page with a flash;
- the admin endpoint answers 403 to anyone but an admin;
- an admin's override turns maintenance mode on (503, but not under `/admin`) and the feature route
  on for everyone, and a reset brings the code's rule back;
- overrides outlive a restart in the example's SQLite file, and a reset one stays reset.

Checked by hand when the package was built, with no automated test: the `/api` limit counting users
and addresses apart, and a page with `<Flagged>` rendering the right part for each user and
hydrating in Chromium under the default CSP.

Not yet:

- The server reads a request's body (up to 16 MiB, or its `--max-body`) before any middleware runs,
  so `body_limit` refuses a large body after it has arrived, not before.
