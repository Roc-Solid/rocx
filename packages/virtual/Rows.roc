## Which rows of a virtual list to render, and where: those that show in its box, and a few more each
## side. A list taller than a browser lets an element be is drawn scaled (`most_space`).
Rows := [].{

	## What a list of `count` rows, each `row_height` pixels high, renders when its box is scrolled
	## `top` pixels down and shows `height` pixels: the rows from `first` up to, not including, `end`,
	## with `overscan` more each side, so that a quick scroll shows rows rather than a gap before the
	## next measure; and `offset`, how far down the box's space the first of them goes. A row height
	## of 0 counts as 1. A box is taken to show `most_shown` pixels at most, and to be scrolled no
	## further than its space goes: a list that grew shorter has its box scrolled back by the browser,
	## which says nothing of it (no scroll, and the box's size is the same).
	shown : { count : U64, row_height : U64, top : U64, height : U64, overscan : U64 } -> { first : U64, end : U64, offset : U64 }
	shown = |{ count, row_height, top, height, overscan }| {
		high = U64.max(row_height, 1)
		seen = U64.min(height, Rows.most_shown)
		scrolled = U64.min(top, Rows.space(count, high).minus_saturated(height))
		real = Rows.real_top(count, high, scrolled, seen)
		end = U64.min((real + seen + high - 1) // high + overscan, count)
		first = U64.min((real // high).minus_saturated(overscan), end)
		{ first, end, offset: (scrolled + first * high).minus_saturated(real) }
	}

	## Where in the rows a box scrolled `top` pixels down of its space is: `top` itself, unless the
	## list is drawn scaled, when the box's last scroll reaches the rows' last pixel.
	real_top : U64, U64, U64, U64 -> U64
	real_top = |count, row_height, top, height| {
		total = count * row_height
		made = Rows.space(count, row_height)
		if total <= made or made <= height {
			top
		} else {
			U64.min(top, made - height) * (total - height) // (made - height)
		}
	}

	## How many pixels high a list's space is made: every row's height together, but no more than
	## `most_space`.
	space : U64, U64 -> U64
	space = |count, row_height| U64.min(count * row_height, Rows.most_space)

	## Whether a list is drawn scaled: its rows are higher together than `most_space`. A scaled
	## list's rows move as its box scrolls, so its view changes with every scroll.
	scaled : U64, U64 -> Bool
	scaled = |count, row_height| count * row_height > Rows.most_space

	## The highest a list's space is made, in pixels. Browsers cap how high an element may be (Firefox
	## at about 17.8 million pixels, Chromium at about 33.5 million), so a list higher than this is
	## drawn scaled: its box scrolls through this many pixels, and each pixel scrolled moves through
	## more of the rows than one.
	most_space : U64
	most_space = 10_000_000

	## The most a box is taken to show, in pixels, whatever it measures: a box given no height grows
	## as high as its rows, and would have every row rendered. 4096 is more than any screen shows.
	most_shown : U64
	most_shown = 4096
}

# At the top, 200 pixels of 20-pixel rows: 10 show, and 2 more below.
expect Rows.shown({ count: 10_000, row_height: 20, top: 0, height: 200, overscan: 2 }) == { first: 0, end: 12, offset: 0 }
# 1000 pixels down: rows 50 to 59 show, 48 to 61 are rendered, from 960 pixels down.
expect Rows.shown({ count: 10_000, row_height: 20, top: 1000, height: 200, overscan: 2 }) == { first: 48, end: 62, offset: 960 }
# Part of a row shows at either end: both are rendered.
expect Rows.shown({ count: 10_000, row_height: 20, top: 1010, height: 200, overscan: 0 }) == { first: 50, end: 61, offset: 1000 }
# At the end, no row past the last.
expect Rows.shown({ count: 100, row_height: 20, top: 1800, height: 200, overscan: 4 }) == { first: 86, end: 100, offset: 1720 }
# Scrolled further than the space goes (the list grew shorter): as the browser scrolls it back, to
# the end, or to the top of a list that fits.
expect Rows.shown({ count: 100, row_height: 20, top: 1900, height: 200, overscan: 4 }) == { first: 86, end: 100, offset: 1720 }
expect Rows.shown({ count: 10, row_height: 20, top: 5000, height: 200, overscan: 2 }) == { first: 0, end: 10, offset: 0 }
# A million rows' box scrolled near its end, then a thousand: the last of the thousand.
expect Rows.shown({ count: 1_000, row_height: 36, top: 9_999_000, height: 358, overscan: 4 }) == { first: 986, end: 1_000, offset: 35_496 }
# None at all.
expect Rows.shown({ count: 0, row_height: 20, top: 0, height: 200, overscan: 2 }) == { first: 0, end: 0, offset: 0 }
# A box with no height, as high as its rows: a screenful or so is rendered, not every row.
expect Rows.shown({ count: 25_000, row_height: 28, top: 0, height: 700_000, overscan: 4 }) == { first: 0, end: 151, offset: 0 }
# A row height of 0 counts as 1.
expect Rows.shown({ count: 50, row_height: 0, top: 10, height: 5, overscan: 0 }) == { first: 10, end: 15, offset: 10 }

# A million rows of 36 pixels (36 million) are drawn in 10 million: unscaled below that.
expect Rows.space(1_000_000, 36) == 10_000_000
expect Rows.space(25_000, 28) == 700_000
expect Rows.scaled(1_000_000, 36)
expect !Rows.scaled(25_000, 28)
# Scaled: the top is the top, and the box's last scroll shows the last rows.
expect Rows.shown({ count: 1_000_000, row_height: 36, top: 0, height: 400, overscan: 0 }) == { first: 0, end: 12, offset: 0 }
expect {
	last = Rows.shown({ count: 1_000_000, row_height: 36, top: 10_000_000 - 400, height: 400, overscan: 0 })
	# The rows' last 400 pixels: the last 12 rows (one of them in part), the first of them where the box's top is.
	last.end == 1_000_000 and last.first == 999_988 and last.offset + 400 >= 10_000_000 - 32
}
# Half way, about the middle row, and it is placed where the box's top is.
expect {
	half = Rows.shown({ count: 1_000_000, row_height: 36, top: 5_000_000, height: 400, overscan: 0 })
	half.first >= 500_000 and half.first <= 500_020 and half.offset <= 5_000_000 and half.offset + 36 > 5_000_000
}
