import pf.Middleware
import pf.Server
import pf.Time
import pf.Env
import pf.Log
import guard.Checks
import guard.ClientIp
import guard.Flag
import guard.Flags
import guard.Ip
import guard.RateLimit
import guard.Security
import FlagStore
import Kept

## Guards, as middleware: each runs around a request, and lets it on or refuses it. Name them in
## the app's default middleware (every request) or in a route file's (that route):
##
##     # Middlewares.roc
##     default = Guard.security_headers(Security.defaults)
##         .then(Guard.body_limit(1_000_000))
##         .then(Guard.maintenance({ flag: Features.maintenance, message: "Back soon.", retry_after_s: 600, except: ["/admin"] }))
##
##     login_limit = Guard.rate_limit("login", RateLimit.per_minute(5), Guard.ip(Hops(1)))
##
##     # routes/login/+server.roc
##     middleware = Middlewares.login_limit
##
## Every guard hands on the context it was given, unchanged (`Middleware(c, c)`), so they go
## anywhere in a chain.
Guard := [].{

	## Who a rate limit counts a request as: its key, from the request and the context its
	## middleware so far handed on. A request whose key is `""` isn't limited.
	Key(c) : Server.Request, c -> Str

	## Refuses a client past `policy` with a 429 (`Retry-After`, `RateLimit-*`), and tells an
	## allowed one where it stands (`RateLimit-*`). `name` keeps this limit's count apart from
	## other limits' (`"login"`, `"api"`); `key` says who is counted (`Guard.ip`, `Guard.user`).
	## Keeps up to 10,000 clients (`rate_limit_with` for more or fewer).
	rate_limit : Str, RateLimit, Key(c) -> Middleware(c, c)
	rate_limit = |name, policy, key| Guard.rate_limit_with({ name, policy, key, max_keys: 10000 })

	## `rate_limit`, keeping up to `max_keys` clients: past them, the one seen longest ago is
	## forgotten (and starts again). Clients whose limit is back to whole are forgotten first.
	## When the count can't be reached, the request goes on, and the log says why.
	rate_limit_with : { name : Str, policy : RateLimit, key : Key(c), max_keys : U64 } -> Middleware(c, c)
	rate_limit_with = |config|
		Middleware.make(
			|request, context, next!| {
				policy = config.policy
				who = (config.key)(request, context)
				if who.is_empty() {
					next!(request, context)
				} else {
					match Kept.hit!(config.name, policy, who, Time.now_millis!({}), config.max_keys) {
						Ok(decision) =>
							if decision.allowed {
								answer = next!(request, context)
								{ ..answer, headers: answer.headers.concat(RateLimit.headers(policy, decision)) }
							} else {
								Log.info!("guard: rate limited", { limit: config.name, path: request.path, retry_after_ms: decision.retry_after_ms })
								Server.response(429, RateLimit.headers(policy, decision).append({ name: "content-type", value: "text/plain; charset=utf-8" }), RateLimit.explain(decision))
							}
						Err(KeptErr(why)) => {
							Log.warn!("guard: rate limit not checked; let through", { limit: config.name, error: why })
							next!(request, context)
						}
					}
				}
			},
		)

	## The client's address, as `trust` says to find it (`ClientIp`): an IPv6 one by its /64.
	## `""` (not limited) when it can't be told.
	ip : ClientIp.Trust -> Key(c)
	ip = |trust|
		|request, _context|
			match ClientIp.of(trust, peer(request), request.headers) {
				Ok(found) => Ip.key(found)
				Err(Unknown) => ""
			}

	## The signed-in user, as `user` reads them from the context (`|context| context.member`);
	## signed out (`""`), the client's address, as `ip`.
	user : (c -> Str), ClientIp.Trust -> Key(c)
	user = |of, trust|
		|request, context| {
			id = of(context)
			if id.is_empty() {
				address = (Guard.ip(trust))(request, context)
				if (address.is_empty()) "" else "ip:${address}"
			} else {
				"user:${id}"
			}
		}

	## Each method and path counted apart: with another key, `Guard.both(Guard.ip(trust),
	## Guard.route)`, each client's count on each route.
	route : Key(c)
	route = |request, _context| "${request.method} ${request.path}"

	## Both keys: counted apart for each pair. `""` when either is.
	both : Key(c), Key(c) -> Key(c)
	both = |first, second|
		|request, context| {
			a = first(request, context)
			b = second(request, context)
			if (a.is_empty() or b.is_empty()) "" else "${a}|${b}"
		}

	## `middleware` for requests whose path is `prefix` or under it (`"/api"`: `/api`, `/api/x`, not
	## `/apiary`); others pass by it.
	under : Str, Middleware(c, c) -> Middleware(c, c)
	under = |prefix, middleware| {
		trimmed = prefix.drop_suffix("/")
		Middleware.make(
			|request, context, next!|
				if request.path == trimmed or request.path.starts_with("${trimmed}/") {
					Middleware.run!(middleware, request, context, next!)
				} else {
					next!(request, context)
				},
		)
	}

	## Every answer with the headers `config` says (`Security.defaults`), but those it sets itself.
	## Under `--dev`, no HSTS, and the CSP only reports (`Security.headers`).
	security_headers : Security.Config -> Middleware(c, c)
	security_headers = |config|
		Middleware.make(
			|request, context, next!| {
				answer = next!(request, context)
				{ ..answer, headers: Security.added(answer.headers, Security.headers(config, { dev: Env.dev!({}) })) }
			},
		)

	## A body larger than `max` bytes refused, 413. (The server refuses one past 16 MiB before the
	## app sees it.)
	body_limit : U64 -> Middleware(c, c)
	body_limit = |max| checked(|request, _| Checks.body_size(max, request.headers, request.body.len()))

	## Only these methods; any other refused, 405, with `Allow`.
	methods : List(Str) -> Middleware(c, c)
	methods = |allowed| checked(|request, _| Checks.methods(allowed, request.method))

	## Only requests for these hosts (`example.com`, `*.example.com`, `localhost:3000`); any other
	## `Host` refused, 400.
	hosts : List(Str) -> Middleware(c, c)
	hosts = |allowed| checked(|request, _| Checks.hosts(allowed, request.headers))

	## Requests from addresses in `deny` refused, 403; and, if `allow` lists any, from addresses
	## not in it. `Ip.cidrs` reads the lists; `trust` says how to find the client's address.
	ips : { allow : List(Ip.Cidr), deny : List(Ip.Cidr), trust : ClientIp.Trust } -> Middleware(c, c)
	ips = |{ allow, deny, trust }| checked(|request, _| Checks.ips({ allow, deny }, ClientIp.of(trust, peer(request), request.headers)))

	## While `flag` is on (an admin turns it on: `FlagStore.set!`), every request but those under
	## `except` (`/admin`, to turn it off again; `/health`) is answered 503, with `message` (a page
	## for a browser) and `Retry-After`.
	maintenance : { flag : Flag, message : Str, retry_after_s : U64, except : List(Str) } -> Middleware(c, c)
	maintenance = |config|
		Middleware.make(
			|request, context, next!| {
				spared = config.except.any(|prefix| request.path == prefix.drop_suffix("/") or request.path.starts_with("${prefix.drop_suffix("/")}/"))
				if !spared and FlagStore.is_on!(config.flag, Flags.anyone) {
					answered(Checks.maintenance(config.message, config.retry_after_s, Server.wants_html(request)))
				} else {
					next!(request, context)
				}
			},
		)

	## Only for those who have `flag` on (`who` reads them from the context); anyone else is
	## answered 404, as if the route weren't there.
	feature : Flag, (c -> Flags.Who) -> Middleware(c, c)
	feature = |flag, who|
		Middleware.make(
			|request, context, next!|
				if FlagStore.is_on!(flag, who(context)) {
					next!(request, context)
				} else {
					Server.refused(404, "Not found.")
				},
		)
}

## A guard from a check: on when it passes, its refusal when it doesn't.
checked : (Server.Request, c -> Try({}, Checks.Refusal)) -> Middleware(c, c)
checked = |check|
	Middleware.make(
		|request, context, next!|
			match check(request, context) {
				Ok({}) => next!(request, context)
				Err(refused) => answered(refused)
			},
	)

answered : Checks.Refusal -> Server.Response
answered = |refused| Server.response(refused.status, refused.headers, refused.body)

## The address the connection came from. The server platform doesn't pass it on yet
## (PROPOSALS.md, "The client's address"), so it is `""`: `Direct` can't tell who a client is,
## and `Hops` and `Proxies` read `X-Forwarded-For` alone.
peer : Server.Request -> Str
peer = |_request| ""
