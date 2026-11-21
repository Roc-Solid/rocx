## Keys: what keeps a mark its own while the data changes. A bar, a slice or a dot is its label's,
## so a new value moves it and doesn't make another; a slice keeps its colour as others come and go.
Keys := [].{

	## Each label as a key: the label, or, after the first with that label, the label numbered
	## (`Jan#1`), so each mark has a key of its own.
	unique : List(Str) -> List(Str)
	unique = |labels| {
		var $seen = []
		var $keys = []
		for label in labels {
			count = $seen.count_if(|seen| seen == label)
			$seen = $seen.append(label)
			$keys = $keys.append(if (count == 0) label else "${label}#${count.to_str()}")
		}
		$keys
	}

	## The keys `now`, in their order, and each key only `was` has (one on its way out) after the
	## key it followed there: where a slice that is going shrinks, between the ones it was between.
	merge : List(Str), List(Str) -> List(Str)
	merge = |was, now| {
		var $keys = now
		var $after = 0
		for key in was {
			match $keys.find_first_index(|k| k == key) {
				Ok(at) => {
					$after = at + 1
				}
				Err(_) => {
					$keys = $keys.take_first($after).append(key).concat($keys.drop_first($after))
					$after = $after + 1
				}
			}
		}
		$keys
	}

	## A slot (a colour) for each key: the one it had in `was`, or the first that no other key has.
	## So a slice keeps its colour while others come and go, and a new one takes a freed colour.
	slots : List((Str, U64)), List(Str) -> List((Str, U64))
	slots = |was, keys| {
		var $slots = was.keep_if(|(key, _)| keys.contains(key))
		for key in keys {
			if !$slots.any(|(k, _)| k == key) {
				var $free = 0
				while $slots.any(|(_, slot)| slot == $free) {
					$free = $free + 1
				}
				$slots = $slots.append((key, $free))
			}
		}
		$slots
	}

	## The slot `key` has: 0 when it has none.
	slot_of : List((Str, U64)), Str -> U64
	slot_of = |given, key| given.find_first(|(k, _)| k == key).map_ok(|(_, found)| found) ?? 0
}

expect Keys.unique(["a", "b", "a", "a"]) == ["a", "b", "a#1", "a#2"]
expect Keys.unique([]) == []
expect Keys.merge(["a", "b", "c"], ["a", "c"]) == ["a", "b", "c"]
expect Keys.merge(["a", "b", "c"], ["c", "a"]) == ["c", "a", "b"]
expect Keys.merge(["x", "a"], ["a", "n"]) == ["x", "a", "n"]
expect Keys.merge([], ["a"]) == ["a"]
expect Keys.slots([], ["a", "b"]) == [("a", 0), ("b", 1)]
expect Keys.slots([("a", 0), ("b", 1), ("c", 2)], ["c", "d", "a"]) == [("a", 0), ("c", 2), ("d", 1)]
expect Keys.slot_of([("a", 0), ("b", 3)], "b") == 3
expect Keys.slot_of([], "b") == 0
