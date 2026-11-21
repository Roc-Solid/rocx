## A rate limit, as arithmetic: what one client's limit says about one more request, given what
## it kept from the ones before and the time. No clock and no memory here: the time comes in, the
## next state goes out, so a test runs it with a fake clock. `Tally` keeps the states of many
## clients; the server's middleware (`server/Guard.roc`) keeps the tallies between requests.
##
##     login = RateLimit.per_minute(5)                # 5 at once, then one every 12 s
##     api = RateLimit.per_minute(100).sliding()      # at most 100 in any minute
##
##     { decision, state } = login.check(state, now)  # `login.fresh(now)` for a new client
##     if decision.allowed { … } else { RateLimit.headers(login, decision) … 429 }
##
## Every number is whole: times in milliseconds, a token bucket's tokens in thousandths of a
## millisecond's worth (see `State`), so nothing drifts, however long a server runs.
RateLimit := { limit : U64, window_ms : U64, algorithm : [TokenBucket, SlidingWindow] }.{

	## What a limit keeps for one client between requests. Its fields mean what its algorithm says:
	##
	## - a token bucket: `count` is how full it is, where one request's token is `window_ms`
	##   (a whole bucket is `limit * window_ms`), and `at` when it was last filled;
	## - a sliding window: `at` is when the current window began (a multiple of `window_ms`),
	##   `count` the requests counted in it, and `previous` those in the window before.
	State : { at : U64, count : U64, previous : U64 }

	## What a limit says about a request:
	##
	## - `allowed`: whether it may go on (an allowed one is counted; a refused one isn't);
	## - `limit`: the requests the limit allows in a window;
	## - `remaining`: how many more it would allow now (after this one, if allowed);
	## - `reset_ms`: until the whole limit is there again, as if the client had sent nothing;
	## - `retry_after_ms`: refused, until one more would be allowed; 0 when allowed.
	Decision : { allowed : Bool, limit : U64, remaining : U64, reset_ms : U64, retry_after_ms : U64 }

	## `limit` requests per `window_ms` milliseconds, as a token bucket: a burst of `limit` at once,
	## then one each `window_ms / limit`. A `limit` of 0 refuses every request; a `window_ms` of 0
	## is read as 1.
	per : U64, U64 -> RateLimit
	per = |limit, window_ms| { limit, window_ms: U64.max(window_ms, 1), algorithm: TokenBucket }

	## `limit` requests a second.
	per_second : U64 -> RateLimit
	per_second = |limit| RateLimit.per(limit, 1000)

	## `limit` requests a minute: `RateLimit.per_minute(5)` for a login form.
	per_minute : U64 -> RateLimit
	per_minute = |limit| RateLimit.per(limit, 60000)

	## `limit` requests an hour.
	per_hour : U64 -> RateLimit
	per_hour = |limit| RateLimit.per(limit, 3600000)

	## The same limit, counted in a sliding window instead: at most `limit` in any `window_ms`,
	## with no burst past it at the edge of a window. A window's count is estimated (as Cloudflare
	## and nginx count) from the current window's requests and the window before's, weighted by
	## how much of it the sliding window still covers: two numbers a client, however high the
	## limit.
	sliding : RateLimit -> RateLimit
	sliding = |policy| { ..policy, algorithm: SlidingWindow }

	## What a client the limit hasn't seen keeps, at `now`: a full bucket, an empty window.
	fresh : RateLimit, U64 -> State
	fresh = |policy, now|
		match policy.algorithm {
			TokenBucket => { at: now, count: capacity(policy), previous: 0 }
			SlidingWindow => { at: now - now % policy.window_ms, count: 0, previous: 0 }
		}

	## What the limit says about one more request at `now`, and what to keep for the next. A
	## clock that went back (`now` before what was kept) is read as standing still.
	check : RateLimit, State, U64 -> { decision : Decision, state : State }
	check = |policy, state, now|
		match policy.algorithm {
			TokenBucket => bucket(policy, state, now)
			SlidingWindow => window(policy, state, now)
		}

	## Whether forgetting a client's state at `now` changes nothing: its bucket is full again, or
	## its windows are both past. A tally drops such clients first.
	idle : RateLimit, State, U64 -> Bool
	idle = |policy, state, now|
		match policy.algorithm {
			TokenBucket => filled(policy, state, now) >= capacity(policy)
			SlidingWindow => now >= state.at + 2 * policy.window_ms
		}

	## The headers that tell a client about its limit (the IETF draft's, as most APIs send them):
	## `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset` (seconds until the whole limit
	## is back) and `RateLimit-Policy` (`5;w=60`: 5 in 60 seconds); and, refused, `Retry-After`
	## (seconds until one more would be allowed, at least 1).
	headers : RateLimit, Decision -> List({ name : Str, value : Str })
	headers = |policy, decision| {
		told = [
			{ name: "ratelimit-limit", value: decision.limit.to_str() },
			{ name: "ratelimit-remaining", value: decision.remaining.to_str() },
			{ name: "ratelimit-reset", value: seconds(decision.reset_ms).to_str() },
			{ name: "ratelimit-policy", value: "${policy.limit.to_str()};w=${seconds(policy.window_ms).to_str()}" },
		]
		if decision.allowed {
			told
		} else {
			told.append({ name: "retry-after", value: U64.max(seconds(decision.retry_after_ms), 1).to_str() })
		}
	}

	## Why a refused request was refused, for its body: `Too many requests: try again in 12 s.`
	explain : Decision -> Str
	explain = |decision| "Too many requests: try again in ${U64.max(seconds(decision.retry_after_ms), 1).to_str()} s."
}

## Whole seconds, rounded up: a client told to wait 1.2 s waits 2.
seconds : U64 -> U64
seconds = |ms| U64.div_ceil_by(ms, 1000)

## A whole bucket: `limit` tokens, each `window_ms` units.
capacity : RateLimit -> U64
capacity = |policy| policy.limit * policy.window_ms

## How full the bucket is at `now`: what it kept, and `limit` units for each millisecond since, up
## to a whole bucket. Past a whole window it is full whatever it kept, so the multiplication
## stops there and can't overflow.
filled : RateLimit, State, U64 -> U64
filled = |policy, state, now| {
	elapsed = U64.min(U64.minus_saturated(now, state.at), policy.window_ms)
	U64.min(capacity(policy), state.count + elapsed * policy.limit)
}

## A token bucket: one token (`window_ms` units) a request, `limit` units back each millisecond.
bucket : RateLimit, State, U64 -> { decision : Decision, state : State }
bucket = |policy, state, now| {
	at = U64.max(now, state.at)
	level = filled(policy, state, now)
	cost = policy.window_ms
	refill = U64.max(policy.limit, 1)
	if policy.limit > 0 and level >= cost {
		left = level - cost
		{
			decision: { allowed: Bool.True, limit: policy.limit, remaining: left // cost, reset_ms: U64.div_ceil_by(capacity(policy) - left, refill), retry_after_ms: 0 },
			state: { at, count: left, previous: 0 },
		}
	} else {
		retry = if (policy.limit == 0) policy.window_ms else U64.div_ceil_by(cost - level, refill)
		{
			decision: { allowed: Bool.False, limit: policy.limit, remaining: 0, reset_ms: U64.max(U64.div_ceil_by(capacity(policy) - level, refill), retry), retry_after_ms: retry },
			state: { at, count: level, previous: 0 },
		}
	}
}

## A sliding window: this window's count and the last one's, the last weighted by how much of it
## the window ending now still covers. Compared multiplied through by `window_ms`, so exactly.
window : RateLimit, State, U64 -> { decision : Decision, state : State }
window = |policy, kept, now| {
	size = policy.window_ms
	limit = policy.limit
	started = now - now % size
	# The windows as they stand at `now`: the same, the next (this one's count is now the last's),
	# or later (both past). A clock that went back stays in the window it kept.
	state =
		if started <= kept.at {
			kept
		} else if started == kept.at + size {
			{ at: started, count: 0, previous: kept.count }
		} else {
			{ at: started, count: 0, previous: 0 }
		}
	into = U64.min(U64.minus_saturated(now, state.at), size - 1)
	# Requests in the window ending now, times `size`.
	weighted = state.previous * (size - into) + state.count * size
	if weighted + size <= limit * size {
		counted = { ..state, count: state.count + 1 }
		used = weighted + size
		{
			decision: { allowed: Bool.True, limit, remaining: (limit * size - used) // size, reset_ms: until_clear(counted, size, into), retry_after_ms: 0 },
			state: counted,
		}
	} else {
		retry = window_retry(state, limit, size, into)
		{
			decision: { allowed: Bool.False, limit, remaining: 0, reset_ms: U64.max(until_clear(state, size, into), retry), retry_after_ms: retry },
			state,
		}
	}
}

## Until nothing counted so far is in the window: when this window has requests, the end of the
## next; when only the last one has, the end of this one.
until_clear : RateLimit.State, U64, U64 -> U64
until_clear = |state, size, into|
	if state.count > 0 {
		size - into + size
	} else if state.previous > 0 {
		size - into
	} else {
		0
	}

## How long until one more request fits, `into` milliseconds into the current window. Refused
## requests aren't counted, so only time changes the sum: the last window's weight shrinks as this
## one goes on, and at its end this window's count becomes the last's.
window_retry : RateLimit.State, U64, U64, U64 -> U64
window_retry = |state, limit, size, into|
	if limit == 0 {
		size - into
	} else if state.count + 1 <= limit {
		# This window has room: wait until the last's weight is small enough,
		# previous * (size - t) <= (limit - count - 1) * size, at `t` into it (at most its end).
		needed = size - ((limit - state.count - 1) * size) // state.previous
		needed - into
	} else {
		# This window is full: in the next, its count is the last's, and weighs
		# count * (size - t) <= (limit - 1) * size at `t` into it.
		needed = size - ((limit - 1) * size) // state.count
		size - into + needed
	}

## Requests at the given times (milliseconds), each checked as the last left it, from a new
## client: whether each was allowed.
run : RateLimit, List(U64) -> List(Bool)
run = |policy, times| {
	var $state = policy.fresh(times.first() ?? 0)
	var $allowed = []
	for now in times {
		{ decision, state } = policy.check($state, now)
		$state = state
		$allowed = $allowed.append(decision.allowed)
	}
	$allowed
}

## The decision for one more request at `now`, after requests at `times`.
after : RateLimit, List(U64), U64 -> RateLimit.Decision
after = |policy, times, now| {
	var $state = policy.fresh(times.first() ?? now)
	for at in times {
		$state = policy.check($state, at).state
	}
	policy.check($state, now).decision
}

## Whether a refused request's `retry_after_ms` is exact: refused a millisecond before it, allowed
## at it.
retry_is_exact : RateLimit, List(U64), U64 -> Bool
retry_is_exact = |policy, times, now| {
	refused = after(policy, times, now)
	wait = refused.retry_after_ms
	!refused.allowed and wait > 0 and !after(policy, times, now + wait - 1).allowed and after(policy, times, now + wait).allowed
}

# A token bucket, 5 a minute: a burst of 5, then one each 12 s.
login = RateLimit.per_minute(5)
expect run(login, [0, 0, 0, 0, 0, 0]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False]
expect run(login, [0, 0, 0, 0, 0, 11999, 12000, 12001]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.True, Bool.False]
expect after(login, [0, 0, 0, 0, 0], 0).retry_after_ms == 12000
expect retry_is_exact(login, [0, 0, 0, 0, 0], 0)
expect retry_is_exact(login, [0, 0, 0, 0, 0], 5000)
expect after(login, [0, 0], 0).remaining == 2
expect after(login, [], 0) == { allowed: Bool.True, limit: 5, remaining: 4, reset_ms: 12000, retry_after_ms: 0 }
# Refused: reset is when the whole bucket is back (5 tokens, 60 s), retry when one is (12 s).
expect after(login, [0, 0, 0, 0, 0], 0) == { allowed: Bool.False, limit: 5, remaining: 0, reset_ms: 60000, retry_after_ms: 12000 }
# A refused request costs nothing: hammering doesn't push the next allowed one back.
expect run(login, [0, 0, 0, 0, 0, 1000, 2000, 3000, 12000]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.False, Bool.False, Bool.True]
# A long pause fills the bucket to its brim, not past it.
expect run(login, [0, 0, 0, 0, 0, 999999999, 999999999, 999999999, 999999999, 999999999, 999999999]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False]
# A clock that goes back stands still: no tokens from it, none lost.
expect run(login, [60000, 60000, 60000, 60000, 60000, 1000, 72000]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.True]
# A limit that doesn't divide its window: 7 a minute, one each 8571.4 ms.
expect retry_is_exact(RateLimit.per_minute(7), [0, 0, 0, 0, 0, 0, 0], 100)
expect run(RateLimit.per_minute(7), [0, 0, 0, 0, 0, 0, 0, 0, 8571, 8572]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.False, Bool.True]
# 0 refuses all; a big limit over a long window doesn't overflow.
expect run(RateLimit.per_minute(0), [0, 100000]) == [Bool.False, Bool.False]
expect after(RateLimit.per_minute(0), [], 0).retry_after_ms == 60000
expect run(RateLimit.per(1000000, 86400000), [0, 1, 2]) == [Bool.True, Bool.True, Bool.True]
expect RateLimit.idle(login, login.fresh(0), 0)
expect !RateLimit.idle(login, login.check(login.fresh(0), 0).state, 11999)
expect RateLimit.idle(login, login.check(login.fresh(0), 0).state, 12000)

# A sliding window, 4 a second: never more than 4 in any second, even across a window's edge,
# where a fixed window would allow 8.
api = RateLimit.per_second(4).sliding()
expect run(api, [0, 0, 0, 0, 0]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.False]
expect run(api, [900, 900, 900, 900, 1000, 1000]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.False]
# The last window's 4 weigh less as this one goes on: one fits once they weigh 3 or less.
expect run(api, [900, 900, 900, 900, 1249, 1250]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.False, Bool.True]
expect retry_is_exact(api, [900, 900, 900, 900], 1000)
expect retry_is_exact(api, [0, 0, 0, 0], 500)
expect retry_is_exact(api, [0, 0, 1000, 1000, 1000], 1100)
expect retry_is_exact(api, [100, 200, 300, 999, 1000, 1001, 1500, 1600], 1700)
# Refused for a full window, it waits for the next, and for the full one's weight to shrink.
expect after(api, [0, 0, 0, 0], 0).retry_after_ms == 1250
# After two windows of quiet, all of it again; a client it saw is idle then.
expect run(api, [0, 0, 0, 0, 2000, 2000, 2000, 2000, 2000]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.True, Bool.False]
expect RateLimit.idle(api, api.check(api.fresh(500), 500).state, 2000)
expect !RateLimit.idle(api, api.check(api.fresh(500), 500).state, 1999)
expect after(api, [0], 0) == { allowed: Bool.True, limit: 4, remaining: 2, reset_ms: 2000, retry_after_ms: 0 }
expect run(api, [5000, 4000, 4000, 4000, 4000]) == [Bool.True, Bool.True, Bool.True, Bool.True, Bool.False]
expect run(RateLimit.per_second(0).sliding(), [0, 5000]) == [Bool.False, Bool.False]
expect retry_is_exact(RateLimit.per_minute(3).sliding(), [10000, 20000, 30000], 40000)
expect retry_is_exact(RateLimit.per_minute(3).sliding(), [10000, 20000, 30000], 70000)
# Room in this window, but the last one's weight with this one's count fills it.
expect retry_is_exact(RateLimit.per_minute(3).sliding(), [10000, 20000, 30000, 85000], 86000)
expect after(RateLimit.per_minute(3).sliding(), [10000, 20000, 30000, 85000], 86000).retry_after_ms == 14000

# Headers: the limit's, and Retry-After when refused (at least a second).
expect RateLimit.headers(login, after(login, [], 0)) == [
	{ name: "ratelimit-limit", value: "5" },
	{ name: "ratelimit-remaining", value: "4" },
	{ name: "ratelimit-reset", value: "12" },
	{ name: "ratelimit-policy", value: "5;w=60" },
]
expect RateLimit.headers(login, after(login, [0, 0, 0, 0, 0], 11500)).find_first(|each| each.name == "retry-after") == Ok({ name: "retry-after", value: "1" })
expect RateLimit.explain(after(login, [0, 0, 0, 0, 0], 0)) == "Too many requests: try again in 12 s."
