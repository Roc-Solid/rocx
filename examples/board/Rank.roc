## Fractional ranks: where a card sits in its column. A rank is a string of base-36 digits
## (`0`–`9`, then `a`–`z`) read as a fraction (`"i"` is 18/36, `"i8"` a little more), and cards are
## ordered by their ranks byte by byte (SQLite's own collation, `Rank.compare` here).
##
## Moving a card writes one row: its new rank, made between its new neighbours' (`between`). The
## other cards keep theirs, so two people moving different cards never touch the same rows, and
## there is always room: between `"i"` and `"j"` is `"ii"`, between `"i"` and `"ii"` is `"i9"`, and
## so on. A rank never ends in `0` (`"i0"` would be the same fraction as `"i"`), so every two
## different ranks have another between them.
Rank := [].{

	## The digits, in the order they sort.
	digits : List(U8)
	digits = "0123456789abcdefghijklmnopqrstuvwxyz".to_utf8()

	## A rank strictly between `low` and `high`: `low` `""` is the column's start, and `high` `""`
	## its end. `low` must sort before `high` (the server makes sure: moves into a column take turns).
	between : Str, Str -> Str
	between = |low, high| Str.from_utf8_lossy(midpoint(low.to_utf8(), high.to_utf8()))

	## Which of two ranks sorts first, byte by byte, as SQLite's own collation sorts them.
	compare : Str, Str -> [Before, Same, After]
	compare = |a, b| compare_bytes(a.to_utf8(), b.to_utf8())

	## Whether `rank` is a rank: digits only, and not ending in `0`.
	is_valid : Str -> Bool
	is_valid = |rank| {
		bytes = rank.to_utf8()
		!bytes.is_empty() and bytes.all(|byte| Rank.digits.contains(byte)) and bytes.last() != Ok('0')
	}
}

## The digits between `low` and `high`, each read as a fraction (`[]` as `high`: 1, past every
## rank). Where they share a first digit it is kept; where their first digits are two or more apart,
## the one in the middle will do; where they are next to each other, either `high`'s first digit
## alone (when `high` has more after it) or `low`'s, followed by a rank after the rest of `low`.
midpoint : List(U8), List(U8) -> List(U8)
midpoint = |low, high|
	match high.first() {
		Ok(top) => {
			bottom = low.first() ?? '0'
			if bottom == top {
				[top].concat(midpoint(low.drop_first(1), high.drop_first(1)))
			} else {
				spread(value(bottom), value(top), low, high)
			}
		}
		Err(_) => spread(value(low.first() ?? '0'), 36, low, high)
	}

## `midpoint` where the first digits differ: `bottom` is `low`'s (0 when it has none), `top`
## `high`'s (36 when there is no `high`).
spread : U64, U64, List(U8), List(U8) -> List(U8)
spread = |bottom, top, low, high|
	if top - bottom > 1 {
		[digit((bottom + top) // 2)]
	} else if high.len() > 1 {
		high.take_first(1)
	} else {
		[digit(bottom)].concat(midpoint(low.drop_first(1), []))
	}

## A digit's value: `0` is 0, `z` 35.
value : U8 -> U64
value = |char| if (char >= 'a') (char - 'a').to_u64() + 10 else (char - '0').to_u64()

## The digit for a value from 0 to 35.
digit : U64 -> U8
digit = |n| Rank.digits.get(n) ?? 'z'

compare_bytes : List(U8), List(U8) -> [Before, Same, After]
compare_bytes = |a, b|
	match (a.first(), b.first()) {
		(Err(_), Err(_)) => Same
		(Err(_), Ok(_)) => Before
		(Ok(_), Err(_)) => After
		(Ok(x), Ok(y)) =>
			if x < y {
				Before
			} else if x > y {
				After
			} else {
				compare_bytes(a.drop_first(1), b.drop_first(1))
			}
	}

## Whether `between(low, high)` lands where it should: after `low`, before `high`, a rank.
fits : Str, Str -> Bool
fits = |low, high| {
	mid = Rank.between(low, high)
	after_low = low.is_empty() or Rank.compare(low, mid) == Before
	before_high = high.is_empty() or Rank.compare(mid, high) == Before
	after_low and before_high and Rank.is_valid(mid)
}

## The ranks `count` cards get, each put after the one before (`fold` over a column's end).
appended : U64 -> List(Str)
appended = |count| List.repeat("", count).fold([], |ranks, _| ranks.append(Rank.between(ranks.last() ?? "", "")))

## The ranks `count` cards get, each put before the one before (always at the top).
prepended : U64 -> List(Str)
prepended = |count| List.repeat("", count).fold([], |ranks, _| ranks.prepend(Rank.between("", ranks.first() ?? "")))

## The ranks `count` cards get, each put between the first two (always second).
squeezed : U64 -> List(Str)
squeezed = |count|
	List.repeat("", count).fold(
		["h", "i"],
		|ranks, _| {
			mid = Rank.between(ranks.first() ?? "", ranks.get(1) ?? "")
			ranks.insert(1, mid) ?? ranks
		},
	)

## Whether every rank in `ranks` sorts before the next.
ascending : List(Str) -> Bool
ascending = |ranks| ranks.fold({ ok: Bool.True, last: "" }, |so_far, rank| { ok: so_far.ok and (so_far.last.is_empty() or Rank.compare(so_far.last, rank) == Before), last: rank }).ok

# An empty column's first card is in the middle.
expect Rank.between("", "") == "i"
# Two digits apart or more: the one between.
expect Rank.between("a", "e") == "c"
expect Rank.between("", "i") == "9"
expect Rank.between("i", "") == "r"
# Next to each other: one digit more.
expect Rank.between("i", "j") == "ii"
expect Rank.between("i", "ii") == "i9"
expect Rank.between("z", "") == "zi"
expect Rank.between("", "1") == "0i"
# A shared first digit is kept.
expect Rank.between("ab", "ad") == "ac"
expect Rank.between("a", "a1") == "a0i"

# Wherever a card goes, its rank fits between its neighbours'.
expect fits("", "")
expect fits("", "0i")
expect fits("0i", "1")
expect fits("i", "i1")
expect fits("hzzz", "i")
expect fits("i", "izzz")
expect fits("y", "z")
expect fits("z", "")
expect fits("zz", "")
expect fits("3", "3001")

# Fifty cards put at a column's end, at its top, or always second: always in order, and short.
expect ascending(appended(50)) and appended(50).all(Rank.is_valid)
expect ascending(prepended(50)) and prepended(50).all(Rank.is_valid)
expect ascending(squeezed(50)) and squeezed(50).all(Rank.is_valid)
expect appended(50).all(|rank| rank.to_utf8().len() <= 12)
expect prepended(50).all(|rank| rank.to_utf8().len() <= 12)

expect Rank.compare("i", "ii") == Before
expect Rank.compare("j", "ii") == After
expect Rank.compare("i", "i") == Same
expect Rank.compare("9", "a") == Before

expect Rank.is_valid("i")
expect !Rank.is_valid("i0")
expect !Rank.is_valid("")
expect !Rank.is_valid("I")
