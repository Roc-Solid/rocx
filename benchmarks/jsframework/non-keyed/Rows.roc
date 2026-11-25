## The js-framework-benchmark's data, as its vanillajs entry makes it: rows of an id (from 1, never
## used twice) and a label of three words picked at random ("pretty red table"), and what each of
## the benchmark's buttons does to them. Plain Roc, the same in both entries (keyed and non-keyed).
## The random words come from a xorshift generator with a fixed seed, so a run's labels are the
## same every time; the benchmark reads only the ids, the row count and the " !!!" an update adds.
Rows := [].{
	Row : { id : U64, label : Str }

	## The generator's state and the next row's id.
	Made : { seed : U64, next_id : U64 }

	start : Made
	start = { seed: 0x9E3779B97F4A7C15, next_id: 1 }

	## `count` rows after `made`, and what comes after them.
	build : Made, U64 -> { rows : List(Row), made : Made }
	build = |made, count| {
		var $seed = made.seed
		var $rows = []
		var $i = 0
		while $i < count {
			s1 = Rows.next($seed)
			s2 = Rows.next(s1)
			s3 = Rows.next(s2)
			$rows = $rows.append({ id: made.next_id + $i, label: "${Rows.pick(Rows.adjectives, s1)} ${Rows.pick(Rows.colours, s2)} ${Rows.pick(Rows.nouns, s3)}" })
			$seed = s3
			$i = $i + 1
		}
		{ rows: $rows, made: { seed: $seed, next_id: made.next_id + count } }
	}

	## Xorshift64: the generator's next state.
	next : U64 -> U64
	next = |x0| {
		x1 = x0.bitwise_xor(x0.shl_wrap(13))
		x2 = x1.bitwise_xor(x1.shr_zf_wrap(7))
		x2.bitwise_xor(x2.shl_wrap(17))
	}

	pick : List(Str), U64 -> Str
	pick = |words, at| words.get(at % words.len()) ?? ""

	## "Update every 10th row": " !!!" added to the label of the first row and every tenth after it.
	updated : List(Row) -> List(Row)
	updated = |rows| rows.map_with_index(|row, i| if (i % 10 == 0) { ..row, label: "${row.label} !!!" } else row)

	## "Swap Rows": the second row and the 999th change places (when there are that many).
	swapped : List(Row) -> List(Row)
	swapped = |rows|
		match (rows.get(1), rows.get(998)) {
			(Ok(second), Ok(last)) => rows.map_with_index(|row, i| if (i == 1) last else if (i == 998) second else row)
			_ => rows
		}

	## A row taken out by its id.
	removed : List(Row), U64 -> List(Row)
	removed = |rows, id| rows.keep_if(|row| row.id != id)

	adjectives : List(Str)
	adjectives = ["pretty", "large", "big", "small", "tall", "short", "long", "handsome", "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful", "mushy", "odd", "unsightly", "adorable", "important", "inexpensive", "cheap", "expensive", "fancy"]

	colours : List(Str)
	colours = ["red", "yellow", "blue", "green", "pink", "brown", "purple", "brown", "white", "black", "orange"]

	nouns : List(Str)
	nouns = ["table", "chair", "house", "bbq", "desk", "car", "pony", "cookie", "sandwich", "burger", "pizza", "mouse", "keyboard"]
}

expect {
	first = Rows.build(Rows.start, 1000)
	second = Rows.build(first.made, 1000)
	first.rows.len() == 1000 and (first.rows.first() ?? { id: 0, label: "" }).id == 1 and (second.rows.first() ?? { id: 0, label: "" }).id == 1001 and second.made.next_id == 2001
}

expect {
	labels = Rows.build(Rows.start, 50).rows.map(|row| row.label)
	labels.all(|label| label.split_on(" ").len() == 3) and labels.drop_first(1).any(|label| Ok(label) != labels.first())
}

expect {
	rows = Rows.build(Rows.start, 25).rows
	marked = Rows.updated(rows).map(|row| row.label.ends_with(" !!!"))
	marked == List.repeat(Bool.False, 25).map_with_index(|_, i| i == 0 or i == 10 or i == 20)
}

expect {
	rows = Rows.build(Rows.start, 1000).rows
	ids = Rows.swapped(rows).map(|row| row.id)
	ids.get(1) == Ok(999) and ids.get(998) == Ok(2) and ids.get(0) == Ok(1)
}

expect Rows.swapped(Rows.build(Rows.start, 10).rows) == Rows.build(Rows.start, 10).rows

expect Rows.removed(Rows.build(Rows.start, 3).rows, 2).map(|row| row.id) == [1, 3]
