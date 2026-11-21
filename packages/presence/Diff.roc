import Room

## The changes between two lists of who is here: who left (in the order they were listed before),
## then who joined and whose metadata changed (in the order they are listed after). A page that
## reloads who is here (after a reconnect, say) learns from it what happened while it wasn't
## listening, and `apply` makes the one list from the other with them.
Diff := [].{

	## What changed from `before` to `after`, by key.
	between : List(Room.Here(meta)), List(Room.Here(meta)) -> List(Room.Change(meta))
		where [meta.is_eq : meta, meta -> Bool]
	between = |before, after| {
		left = before.keep_if(|was| !after.any(|is| is.key == was.key)).map(|was| Left(was))
		came =
			after.keep_if(
				|is|
					match before.find_first(|was| was.key == is.key) {
						Ok(was) => was.meta != is.meta
						Err(_) => Bool.True
					},
			)
		joined_or_changed = came.map(|is| if (before.any(|was| was.key == is.key)) Changed(is) else Joined(is))
		left.concat(joined_or_changed)
	}

	## `members` with `change` made: one who joined at the end (or in their place, if they were
	## listed already), one who left gone, one who changed with their new metadata.
	apply : List(Room.Here(meta)), Room.Change(meta) -> List(Room.Here(meta))
	apply = |members, change|
		match change {
			Joined(here) =>
				if members.any(|member| member.key == here.key) {
					members.map(|member| if (member.key == here.key) here else member)
				} else {
					members.append(here)
				}
			Left(here) => members.drop_if(|member| member.key == here.key)
			Changed(here) => members.map(|member| if (member.key == here.key) { ..member, meta: here.meta } else member)
		}

	## Whose change it is.
	key : Room.Change(meta) -> Str
	key = |change|
		match change {
			Joined(here) => here.key
			Left(here) => here.key
			Changed(here) => here.key
		}
}

Meta : { name : Str }

here : Str, Str -> Room.Here(Meta)
here = |key, name| { key, meta: { name }, since: 0 }

expect Diff.between([], []) == []
expect Diff.between([here("a", "Ann")], [here("a", "Ann")]) == []
expect Diff.between([], [here("a", "Ann")]) == [Joined(here("a", "Ann"))]
expect Diff.between([here("a", "Ann")], []) == [Left(here("a", "Ann"))]
expect Diff.between([here("a", "Ann")], [here("a", "Annie")]) == [Changed(here("a", "Annie"))]

expect
	Diff.between([here("a", "Ann"), here("b", "Bo")], [here("b", "Bob"), here("c", "Cy")])
		== [Left(here("a", "Ann")), Changed(here("b", "Bob")), Joined(here("c", "Cy"))]

# Applying the changes between two lists makes the second from the first.
expect {
	before = [here("a", "Ann"), here("b", "Bo"), here("d", "Di")]
	after = [here("b", "Bob"), here("c", "Cy"), here("d", "Di")]
	made = Diff.between(before, after).fold(before, Diff.apply)
	made.len() == after.len() and after.all(|is| made.contains(is))
}

expect Diff.apply([here("a", "Ann")], Joined(here("a", "Annie"))) == [here("a", "Annie")]
expect Diff.apply([here("a", "Ann")], Left(here("b", "Bo"))) == [here("a", "Ann")]
expect Diff.key(Left(here("a", "Ann"))) == "a"
