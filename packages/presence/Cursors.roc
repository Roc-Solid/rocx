## Others' cursors over an area, as a page shows them. A place is a share of the area's width and
## height, from 0 to 1, so a cursor points at the same thing on a narrow screen and a wide one, and
## it travels rounded to thousandths (`place`). Each cursor is its member's (`key`): a move puts it
## where it went, and when it was there (`moved`); one that hasn't moved for a while is idle (shown
## faded), and one that hasn't moved for longer is forgotten (`sweep`). Many moves in one batch are
## one per member, each's last (`coalesce`): what a server or a slow page does with a burst.
Cursors := { cursors : List(Cursors.Cursor) }.{

	## Where a member's cursor is, and when it got there.
	Cursor : { key : Str, x : Dec, y : Dec, at : U64 }

	## A cursor that moved, as it is sent.
	Move : { key : Str, x : Dec, y : Dec }

	## A cursor as a page draws it: idle when it hasn't moved for a while.
	Shown : { key : Str, x : Dec, y : Dec, idle : Bool }

	## No cursors.
	none : Cursors
	none = { cursors: [] }

	## The place of a pointer at (`x`, `y`) pixels from an area's top left corner, in an area
	## `width` by `height` pixels: shares of each, from 0 to 1, to thousandths.
	place : { x : Dec, y : Dec }, { width : Dec, height : Dec } -> { x : Dec, y : Dec }
	place = |point, area| {
		of = |at, size| if (size <= 0.0) 0.0 else Cursors.share(at / size)
		{ x: of(point.x, area.width), y: of(point.y, area.height) }
	}

	## `at` as a share from 0 to 1, to thousandths: a thousandth of an area is under a pixel on most
	## screens, and short on the wire.
	share : Dec -> Dec
	share = |at| Dec.round_to(Dec.min(Dec.max(at, 0.0), 1.0), { step: 0.001, ties: AwayFromZero })

	## The cursors with `move` made at `now`: its member's cursor there (and last to be drawn).
	moved : Cursors, Cursors.Move, U64 -> Cursors
	moved = |cursors, move, now| {
		kept = cursors.cursors.drop_if(|cursor| cursor.key == move.key)
		{ cursors: kept.append({ key: move.key, x: Cursors.share(move.x), y: Cursors.share(move.y), at: now }) }
	}

	## The cursors without `key`'s: they left, or their pointer left the area.
	gone : Cursors, Str -> Cursors
	gone = |cursors, key| { cursors: cursors.cursors.drop_if(|cursor| cursor.key == key) }

	## The cursors at `now`, each idle if it hasn't moved for `idle` milliseconds.
	shown : Cursors, U64, U64 -> List(Cursors.Shown)
	shown = |cursors, now, idle|
		cursors.cursors.map(|cursor| { key: cursor.key, x: cursor.x, y: cursor.y, idle: now >= cursor.at + idle })

	## The cursors at `now` without those that haven't moved for `forget` milliseconds.
	sweep : Cursors, U64, U64 -> Cursors
	sweep = |cursors, now, forget| { cursors: cursors.cursors.keep_if(|cursor| now < cursor.at + forget) }

	## When the next cursor turns idle after `idle` milliseconds (`Err(Empty)` when there is no
	## cursor, or all are idle): when a page should look again.
	next_idle : Cursors, U64, U64 -> Try(U64, [Empty])
	next_idle = |cursors, now, idle|
		cursors.cursors
			.map(|cursor| cursor.at + idle)
			.keep_if(|at| at > now)
			.min()
			.map_err(|_| Empty)

	## How many cursors there are.
	count : Cursors -> U64
	count = |cursors| cursors.cursors.len()

	## A burst of moves as one per member: each one's last, in the order they last moved.
	coalesce : List(Cursors.Move) -> List(Cursors.Move)
	coalesce = |moves| moves.fold(
		[],
		|kept, move| kept.drop_if(|other| other.key == move.key).append(move),
	)

	## A share as a CSS percentage: 0.375 is `"37.5%"`.
	percent : Dec -> Str
	percent = |at| "${trimmed(Dec.round_to(at * 100.0, { step: 0.1, ties: AwayFromZero }).to_str())}%"
}

## `"37.50"` → `"37.5"`, `"3.0"` → `"3"`.
trimmed : Str -> Str
trimmed = |text|
	if text.contains(".") {
		var $text = text
		while $text.ends_with("0") {
			$text = $text.drop_suffix("0")
		}
		short = $text.drop_suffix(".")
		if (short == "-0") "0" else short
	} else {
		text
	}

expect Cursors.place({ x: 150.0, y: 50.0 }, { width: 400.0, height: 200.0 }) == { x: 0.375, y: 0.25 }
expect Cursors.place({ x: -20.0, y: 900.0 }, { width: 400.0, height: 200.0 }) == { x: 0.0, y: 1.0 }
expect Cursors.place({ x: 10.0, y: 10.0 }, { width: 0.0, height: 0.0 }) == { x: 0.0, y: 0.0 }
expect Cursors.place({ x: 1.0, y: 2.0 }, { width: 3.0, height: 3.0 }) == { x: 0.333, y: 0.667 }

expect Cursors.percent(0.375) == "37.5%"
expect Cursors.percent(0.0) == "0%"
expect Cursors.percent(1.0) == "100%"
expect Cursors.percent(0.6667) == "66.7%"

# A move puts its member's cursor there; a second move by the same member replaces it.
expect {
	cursors = Cursors.none.moved({ key: "ann", x: 0.1, y: 0.2 }, 1000).moved({ key: "bo", x: 0.5, y: 0.5 }, 1010).moved({ key: "ann", x: 0.3, y: 0.4 }, 1020)
	cursors.shown(1020, 5000) == [{ key: "bo", x: 0.5, y: 0.5, idle: Bool.False }, { key: "ann", x: 0.3, y: 0.4, idle: Bool.False }]
}

# Out of the area: kept at its edge.
expect Cursors.none.moved({ key: "ann", x: 1.5, y: -1.0 }, 0).shown(0, 5000) == [{ key: "ann", x: 1.0, y: 0.0, idle: Bool.False }]

# Idle after a while; forgotten after longer.
expect {
	cursors = Cursors.none.moved({ key: "ann", x: 0.1, y: 0.2 }, 1000).moved({ key: "bo", x: 0.5, y: 0.5 }, 4000)
	idle = cursors.shown(6000, 5000).map(|shown| (shown.key, shown.idle))
	idle == [("ann", Bool.True), ("bo", Bool.False)] and cursors.sweep(31000, 30000).count() == 1 and cursors.sweep(34000, 30000).count() == 0
}

expect {
	cursors = Cursors.none.moved({ key: "ann", x: 0.1, y: 0.2 }, 1000).moved({ key: "bo", x: 0.5, y: 0.5 }, 4000)
	cursors.next_idle(2000, 5000) == Ok(6000) and cursors.next_idle(7000, 5000) == Ok(9000) and cursors.next_idle(9000, 5000) == Err(Empty)
}

expect Cursors.none.moved({ key: "ann", x: 0.1, y: 0.2 }, 0).gone("ann").count() == 0

expect
	Cursors.coalesce([{ key: "a", x: 0.1, y: 0.1 }, { key: "b", x: 0.2, y: 0.2 }, { key: "a", x: 0.3, y: 0.3 }])
		== [{ key: "b", x: 0.2, y: 0.2 }, { key: "a", x: 0.3, y: 0.3 }]

# A move on the wire.
expect Json.to_str({ key: "ann", x: 0.375, y: 0.25 }) == "{\"key\":\"ann\",\"x\":0.375,\"y\":0.25}"
