## Points and places: how much a right answer is worth, and who is where on the board. Plain Roc,
## with no effects, so the room's actor on the server and the pages in the browser use the same
## arithmetic, and the `expect`s below pin it down.
Score := [].{

	## The most a right answer can earn: one given the moment the question opens.
	most : U64
	most = 1000

	## The least a right answer earns: one given as the time runs out.
	least : U64
	least = 500

	## What an answer earns. A wrong answer, or none, earns nothing. A right one earns `least`, and
	## the rest of `most` in proportion to the time left: `elapsed` milliseconds after the question
	## opened, of the `limit` it was open for. Rounded to the nearest point, half up.
	points : { right : Bool, elapsed : U64, limit : U64 } -> U64
	points = |{ right, elapsed, limit }|
		if !right {
			0
		} else if limit == 0 {
			Score.least
		} else {
			left = limit - U64.min(elapsed, limit)
			bonus = Score.most - Score.least
			Score.least + (bonus * left * 2 + limit) // (limit * 2)
		}

	## A row of the board: who, and their score.
	Row : { id : Str, name : Str, score : U64 }

	## The board, best first, each with their place. Equal scores share a place, and the next
	## place skips as many as shared it (1, 2, 2, 4), as a race's results do; among equals, the
	## order they are given in (the order they joined) stands.
	ranked : List(Score.Row) -> List({ id : Str, name : Str, score : U64, place : U64 })
	ranked = |rows| {
		# Each row's position given, so equals keep their order whatever the sort does with them.
		sorted = rows.map_with_index(|row, at| (row, at)).sort_with(
			|(a, a_at), (b, b_at)|
				if a.score > b.score {
					Before
				} else if a.score < b.score {
					After
				} else if a_at < b_at {
					Before
				} else if a_at > b_at {
					After
				} else {
					Same
				},
		).map(|(row, _)| row)
		var $placed = []
		var $place = 1
		var $previous = 0
		for row in sorted {
			index = $placed.len()
			$place = if (index == 0 or row.score != $previous) index + 1 else $place
			$previous = row.score
			$placed = $placed.append({ id: row.id, name: row.name, score: row.score, place: $place })
		}
		$placed
	}

	## "1st", "2nd", "3rd", "4th", … "11th", "12th", "13th", … "21st".
	ordinal : U64 -> Str
	ordinal = |n| {
		suffix =
			if n % 100 >= 11 and n % 100 <= 13 {
				"th"
			} else {
				match n % 10 {
					1 => "st"
					2 => "nd"
					3 => "rd"
					_ => "th"
				}
			}
		"${n.to_str()}${suffix}"
	}
}

# A wrong answer earns nothing, however fast.
expect Score.points({ right: Bool.False, elapsed: 0, limit: 20_000 }) == 0

# A right answer at once earns the most; at the buzzer, the least; halfway, halfway between.
expect Score.points({ right: Bool.True, elapsed: 0, limit: 20_000 }) == 1000
expect Score.points({ right: Bool.True, elapsed: 20_000, limit: 20_000 }) == 500
expect Score.points({ right: Bool.True, elapsed: 10_000, limit: 20_000 }) == 750

# Late (the server's clock past the deadline by a little) is still the least, never less.
expect Score.points({ right: Bool.True, elapsed: 25_000, limit: 20_000 }) == 500

# Rounded to the nearest point: a third of the way is 666.67 points of bonus left, so 833.
expect Score.points({ right: Bool.True, elapsed: 1_000, limit: 3_000 }) == 833

# Faster is never worth less.
expect {
	earned = [0, 1, 999, 5_000, 12_345, 19_999, 20_000].map(|ms| Score.points({ right: Bool.True, elapsed: ms, limit: 20_000 }))
	pairs = earned.drop_last(1).map_with_index(|points, i| points >= (earned.get(i + 1) ?? 0))
	pairs.all(|ok| ok)
}

# A question with no time at all still pays the least for a right answer.
expect Score.points({ right: Bool.True, elapsed: 0, limit: 0 }) == 500

# Best first; equal scores share a place, and the next place skips.
expect
	Score.ranked([{ id: "a", name: "Ada", score: 900 }, { id: "b", name: "Bo", score: 1500 }, { id: "c", name: "Cy", score: 900 }, { id: "d", name: "Di", score: 0 }])
		== [
			{ id: "b", name: "Bo", score: 1500, place: 1 },
			{ id: "a", name: "Ada", score: 900, place: 2 },
			{ id: "c", name: "Cy", score: 900, place: 2 },
			{ id: "d", name: "Di", score: 0, place: 4 },
		]

# Everyone level is everyone first, in the order they joined.
expect Score.ranked([{ id: "a", name: "Ada", score: 0 }, { id: "b", name: "Bo", score: 0 }]).map(|row| (row.id, row.place)) == [("a", 1), ("b", 1)]

expect Score.ranked([]) == []

expect [1, 2, 3, 4, 11, 12, 13, 21, 22, 101, 111].map(Score.ordinal) == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st", "111th"]
