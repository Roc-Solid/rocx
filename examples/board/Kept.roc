import pf.Actor
import guard.RateLimit
import guard.Tally

## What the guards keep between requests, in the server's memory: each rate limit's tallies, in
## `shards` pieces (a hit reads and writes one, a few hundred clients at most), each an actor's
## state, so one request at a time changes it.
##
## With a database, the platform also writes an actor's state to Postgres (`rocx_actors`) after
## every message that changes it: correct, but a write per limited request (each moves a tally).
## The server's memory, `Kv` (D-028), would do without the writes: PROPOSALS.md ("Memory: state
## between requests"); only this module would change.
Kept := [].{

	## A tally, kept as text (`Tally.to_str`), answering hits (`rocx build` lists it in the app's
	## `program.actors`).
	tallies : Actor.Kind(Str, Hit, RateLimit.Decision)
	tallies = Actor.define({
		name: "rocx_guard_tally",
		initial: |_name| "",
		receive!: |_me, kept, hit| {
			base = RateLimit.per(hit.limit, hit.window_ms)
			policy = if (hit.sliding) base.sliding() else base
			{ decision, tally } = Tally.hit(Tally.from_str(kept), policy, hit.key, hit.now, hit.room)
			{ state: tally.to_str(), reply: decision }
		},
	})

	## Into how many tallies a limit's clients are split.
	shards : U64
	shards = 64

	## One more request from `key`, under the limit called `name`: what `policy` says, keeping at
	## most `max_keys` clients for it. An `Err` when the tally couldn't be reached (its actor didn't
	## answer in 30 s): the caller lets the request through, rather than refuse everyone.
	hit! : Str, RateLimit, Str, U64, U64 => Try(RateLimit.Decision, [KeptErr(Str)])
	hit! = |name, policy, key, now, max_keys| {
		shard = Tally.shard(key, Kept.shards)
		message = {
			limit: policy.limit,
			window_ms: policy.window_ms,
			sliding: policy.algorithm == SlidingWindow,
			key,
			now,
			room: U64.max(max_keys // Kept.shards, 1),
		}
		match Actor.ask!(Kept.tallies, "${name}/${shard.to_str()}", message) {
			Ok(decision) => Ok(decision)
			Err(ActorErr(why)) => Err(KeptErr(why))
		}
	}
}

## A hit, as an actor is sent it: the limit (its numbers: a policy is code, not data), the
## client, the time, and how many clients the tally may keep.
Hit : { limit : U64, window_ms : U64, sliding : Bool, key : Str, now : U64, room : U64 }
