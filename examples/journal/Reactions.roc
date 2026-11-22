import pf.Kv
import Reaction

## Reactions, counted in the server's memory (`Kv`, D-028): cheap to lose, read on every post's
## page. Each count is a counter (`Kv.increment!`); whether a reader has given a kind is a mark
## that only one request can set (`Kv.add!`) and only one can take back (`Kv.take!`), so a reader
## clicking twice at once counts once. A counter starts at `Reaction.seed` the first time it is
## asked for (`Kv.add!` again: only the first asker sets it), which makes this idempotent seeding.
## Memory only: a restart starts the counts again from their seeds. Server-only (it imports
## `pf.Kv`), so only `+server.roc` files import it.
Reactions := [].{

	## The post's counts, and the kinds `reader` has given (none for `""`).
	tally! : Str, Str => Reaction.Tally
	tally! = |slug, reader| {
		var $counts = []
		var $mine = []
		for kind in Reaction.kinds {
			$counts = $counts.append({ kind: kind.id, count: count!(slug, kind.id) })
			if !reader.is_empty() and marked!(slug, kind.id, reader) {
				$mine = $mine.append(kind.id)
			}
		}
		{ counts: $counts, mine: $mine }
	}

	## A reader's toggle: `on: "true"` gives the kind (once, however often it is sent),
	## `"false"` takes it back. The counts after it.
	toggle! : Str, Str, Reaction.Toggle => Reaction.Tally
	toggle! = |slug, reader, { kind, on }| {
		_ = count!(slug, kind)
		key = mark_key(slug, kind, reader)
		if on == "true" {
			match Kv.add!(key, Bool.True, {}) {
				Ok({}) => {
					_ = Kv.increment!(count_key(slug, kind), 1, {})
					{}
				}
				Err(Exists) => {}
			}
		} else {
			taken : Try(Bool, [NotFound, BadValue(Str)])
			taken = Kv.take!(key)
			match taken {
				Ok(_) => {
					_ = Kv.increment!(count_key(slug, kind), -1, {})
					{}
				}
				Err(_) => {}
			}
		}
		Reactions.tally!(slug, reader)
	}
}

## A kind's count for the post, started at its seed the first time.
count! : Str, Str => I64
count! = |slug, kind| {
	key = count_key(slug, kind)
	_ = Kv.add!(key, Reaction.seed(slug, kind), {})
	found : Try(I64, [NotFound, BadValue(Str)])
	found = Kv.get!(key)
	found ?? 0
}

## Whether `reader` has given `kind` to the post.
marked! : Str, Str, Str => Bool
marked! = |slug, kind, reader| {
	found : Try(Bool, [NotFound, BadValue(Str)])
	found = Kv.get!(mark_key(slug, kind, reader))
	found.is_ok()
}

count_key : Str, Str -> Str
count_key = |slug, kind| "journal:reactions:${slug}:${kind}"

mark_key : Str, Str, Str -> Str
mark_key = |slug, kind, reader| "journal:reacted:${slug}:${kind}:${reader}"
