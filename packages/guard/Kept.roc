import pf.Kv
import RateLimit
import Tally

## What the guards keep between requests: each rate limit's tallies, in `shards` pieces (a hit
## reads and writes one, a few hundred clients at most), in the server's memory (`Kv`, D-043),
## under `guard:<limit>/<shard>`. A hit reads its tally, decides, and swaps the next one in
## (`Kv.swap!`): of two requests at once, one wins and the other reads again, so no hit is lost and
## nothing is written to the database. A restart starts every limit again.
Kept := [].{

	## Into how many tallies a limit's clients are split.
	shards : U64
	shards = 64

	## How many times a hit reads its tally again when another request changed it first, before
	## it gives up (and the request goes on, as when the count can't be reached).
	tries : U64
	tries = 50

	## One more request from `key`, under the limit called `name`: what `policy` says, keeping at
	## most `max_keys` clients for it. An `Err` when the tally changed under every try: the caller
	## lets the request through, rather than refuse everyone.
	hit! : Str, RateLimit, Str, U64, U64 => Try(RateLimit.Decision, [KeptErr(Str)])
	hit! = |name, policy, key, now, max_keys| {
		at = "guard:${name}/${Tally.shard(key, Kept.shards).to_str()}"
		room = U64.max(max_keys // Kept.shards, 1)
		var $left = Kept.tries
		while $left > 0 {
			was : Try(Str, [NotFound, BadValue(Str)])
			was = Kv.get!(at)
			text = was ?? ""
			{ decision, tally } = Tally.hit(Tally.from_str(text), policy, key, now, room)
			stored =
				match was {
					Ok(_) => Kv.swap!(at, text, tally.to_str(), {})
					Err(_) => Kv.add!(at, tally.to_str(), {}).map_err(|_| Changed)
				}
			if stored.is_ok() {
				return Ok(decision)
			}
			$left = $left - 1
		}
		Err(KeptErr("${at} changed under each of ${Kept.tries.to_str()} tries"))
	}
}
