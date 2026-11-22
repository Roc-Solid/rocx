## Reactions to a post (👏 ❤️ 💡 😄): the kinds, what the server answers, what a reader sends, and how
## a toggle still on its way changes what is shown. Plain Roc, shared: the server counts with it
## (`Reactions.roc`, in `Kv`) and the browser's island shows a toggle before the server has it
## (`apply`, over `use_submissions!`'s inputs on their way).
Reaction := [].{

	## A kind of reaction: its id (the catalog's `react.<id>` names it) and its emoji.
	Kind : { id : Str, emoji : Str }

	kinds : List(Reaction.Kind)
	kinds = [
		{ id: "clap", emoji: "👏" },
		{ id: "heart", emoji: "❤️" },
		{ id: "idea", emoji: "💡" },
		{ id: "smile", emoji: "😄" },
	]

	## What the server answers for a post: each kind's count, in the order of `kinds`, and the kinds
	## this reader has given.
	Tally : { counts : List({ kind : Str, count : I64 }), mine : List(Str) }

	## What a reader sends: a kind, and whether it is to be given (`"true"`) or taken back
	## (`"false"`). Text, not a `Bool`, so a plain form posts the same fields when there is no
	## JavaScript.
	Toggle : { kind : Str, on : Str }

	## Whether `id` is one of the kinds.
	known : Str -> Bool
	known = |id| Reaction.kinds.any(|kind| kind.id == id)

	## Whether a toggle says to give (`"true"`) or take back (`"false"`): anything else is neither.
	direction : Str -> Try(Bool, [Neither])
	direction = |on| if (on == "true") Ok(Bool.True) else if (on == "false") Ok(Bool.False) else Err(Neither)

	## How many of `kind` the post has.
	count_of : Reaction.Tally, Str -> I64
	count_of = |tally, kind| tally.counts.find_first(|each| each.kind == kind).map_ok(|each| each.count) ?? 0

	## Whether this reader has given `kind`.
	given : Reaction.Tally, Str -> Bool
	given = |tally, kind| tally.mine.contains(kind)

	## The tally with a toggle applied, as the server will have it. Applying it twice changes
	## nothing more (the page may read the server's new tally while a toggle is still on its way):
	## giving what is given, or taking back what isn't, is no change.
	apply : Reaction.Tally, Reaction.Toggle -> Reaction.Tally
	apply = |tally, { kind, on }| {
		had = Reaction.given(tally, kind)
		match Reaction.direction(on) {
			Ok(wanted) if wanted != had => {
				step = if (wanted) 1 else -1
				counts = tally.counts.map(|each| if (each.kind == kind) { kind, count: I64.max(each.count + step, 0) } else each)
				mine = if (wanted) tally.mine.append(kind) else tally.mine.drop_if(|each| each == kind)
				{ counts, mine }
			}
			_ => tally
		}
	}

	## Where a post's counts start, the first time the server is asked about them: a few, the same
	## every time for the same post, so the journal looks read on its first run.
	seed : Str, Str -> I64
	seed = |slug, kind| {
		hash = "${slug}/${kind}".to_utf8().fold(7, |so_far, byte| (so_far * 31 + byte.to_u64()) % 1000003)
		span = if (kind == "clap") 24 else if (kind == "heart") 12 else 7
		(hash % span).to_i64_wrap() + (if (kind == "clap") 4 else 0)
	}
}

empty : Reaction.Tally
empty = { counts: Reaction.kinds.map(|kind| { kind: kind.id, count: 2 }), mine: [] }

expect Reaction.count_of(Reaction.apply(empty, { kind: "clap", on: "true" }), "clap") == 3
expect Reaction.given(Reaction.apply(empty, { kind: "clap", on: "true" }), "clap")
expect Reaction.apply(Reaction.apply(empty, { kind: "clap", on: "true" }), { kind: "clap", on: "true" }) == Reaction.apply(empty, { kind: "clap", on: "true" })
expect Reaction.apply(Reaction.apply(empty, { kind: "idea", on: "true" }), { kind: "idea", on: "false" }) == empty
expect Reaction.apply(empty, { kind: "heart", on: "false" }) == empty
expect Reaction.apply(empty, { kind: "heart", on: "maybe" }) == empty
expect Reaction.seed("slow-bread", "clap") == Reaction.seed("slow-bread", "clap") and Reaction.seed("slow-bread", "clap") >= 4
expect Reaction.known("smile") and !Reaction.known("boo")
