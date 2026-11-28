import Host

## The server's key-value store: values by key, kept in its memory for as long as you say, or
## until it stops. Never written anywhere, so a restart forgets them all: for what is cheap to lose
## and read often (a rate limit's counts, a cache, a one-time token, the dev mailbox). What must
## last goes in the database (`Db`).
##
## A value is any type JSON can write, kept as JSON and read back as the type its reader asks for.
## Each operation is atomic: two requests incrementing one counter both count, two adding one key
## let one in, and a value taken is taken once. A key names its owner first, by convention
## (`email:mailbox`, `guard:login:203.0.113.7`), so a package's keys never meet an app's.
##
## The store holds 64 MiB (`--kv-max-mb`, or `KV_MAX_MB`); past that the least recently read or
## written values go, so a cache can't grow without end. One instance of an app means one store.
Kv := [].{

	## How long a value is kept: `ttl_ms` milliseconds; 0, the default, until the server stops.
	Opts := { ttl_ms : U64 ?? 0 }

	## A list's: how many of its newest values it keeps, and how long the list is kept from when it
	## is made (0, the default: until the server stops).
	ListOpts := { keep : U64, ttl_ms : U64 ?? 0 }

	## Keeps `value` under `key` for as long as `opts` says, replacing what was there (and its time
	## to live).
	set! : Str, value, Opts => {} where [value.Json.Encodable([])]
	set! = |key, value, opts| Host.kv_set!(key, Json.to_str(value), opts.ttl_ms)

	## The value under `key`. `NotFound` when there is none, or it has expired; `BadValue` when what
	## is there isn't the type asked for (with why).
	get! : Str => Try(value, [NotFound, BadValue(Str)]) where [value.Json.Parseable([InvalidJson(Str)])]
	get! = |key|
		match Host.kv_get!(key) {
			Err(_) => Err(NotFound)
			Ok(text) => parsed(key, text)
		}

	## Forgets `key`. One that isn't there is forgotten already.
	delete! : Str => {}
	delete! = |key| Host.kv_delete!(key)

	## The value under `key`, forgotten as it is read: of two requests taking it at once, one gets
	## it and the other `NotFound`. What one-time tokens are made of (OAuth's state, a sign-in
	## link's nonce).
	take! : Str => Try(value, [NotFound, BadValue(Str)]) where [value.Json.Parseable([InvalidJson(Str)])]
	take! = |key|
		match Host.kv_take!(key) {
			Err(_) => Err(NotFound)
			Ok(text) => parsed(key, text)
		}

	## Keeps `value` under `key` only if nothing is there (or what was has expired): `Exists`
	## otherwise. Of two requests adding one key at once, one gets `Ok`: a claim, or a request
	## seen once (an idempotency key).
	add! : Str, value, Opts => Try({}, [Exists]) where [value.Json.Encodable([])]
	add! = |key, value, opts| if (Host.kv_add!(key, Json.to_str(value), opts.ttl_ms)) Ok({}) else Err(Exists)

	## Replaces the value under `key` with `value`, and its time to live, only if it is still `was`
	## (compared as JSON, as this module writes it): `Changed` otherwise, or when nothing is there
	## (`add!` puts a first one). A change that reads a value and writes the next one (a tally, a
	## list of overrides) swaps, and on `Changed` reads again: of two at once, one wins and the other
	## tries again with what it wrote, so none is lost (D-043).
	swap! : Str, was, value, Opts => Try({}, [Changed]) where [was.Json.Encodable([]), value.Json.Encodable([])]
	swap! = |key, was, value, opts| if (Host.kv_swap!(key, Json.to_str(was), Json.to_str(value), opts.ttl_ms)) Ok({}) else Err(Changed)

	## Adds `by` to the integer under `key`, starting from 0 when there is none: the new value. A
	## new counter's time to live starts then and isn't moved by later increments, so
	## `increment!(key, 1, { ttl_ms: 60_000 })` counts in windows of a minute (a rate limit).
	## `NotAnInteger` when what is there is something else.
	increment! : Str, I64, Opts => Try(I64, [NotAnInteger(Str)])
	increment! = |key, by, opts|
		match Host.kv_increment!(key, by, opts.ttl_ms) {
			Ok(text) =>
				match I64.from_str(text) {
					Ok(now) => Ok(now)
					Err(_) => Err(NotAnInteger("${key} holds ${text}"))
				}
			Err(why) => Err(NotAnInteger(why))
		}

	## Puts `value` at the front of the list under `key`, keeping its newest `keep` (at least one).
	## A value that isn't a list is replaced by one. A new list's time to live starts then.
	push! : Str, value, ListOpts => {} where [value.Json.Encodable([])]
	push! = |key, value, opts| Host.kv_push!(key, Json.to_str(value), opts.keep, opts.ttl_ms)

	## The list under `key`, newest first; empty when there is none, or it has expired.
	list! : Str => Try(List(value), [BadValue(Str)]) where [value.Json.Parseable([InvalidJson(Str)])]
	list! = |key|
		match Host.kv_get!(key) {
			Err(_) => Ok([])
			Ok(text) =>
				match Json.parse(text) {
					Ok(values) => Ok(values)
					Err(InvalidJson(why)) => Err(BadValue("${key}: ${why}"))
				}
		}
}

## What is under `key`, as the type its reader asks for.
parsed : Str, Str -> Try(value, [NotFound, BadValue(Str)]) where [value.Json.Parseable([InvalidJson(Str)])]
parsed = |key, text|
	match Json.parse(text) {
		Ok(value) => Ok(value)
		Err(InvalidJson(why)) => Err(BadValue("${key}: ${why}"))
	}
