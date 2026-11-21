## Pages of rows: which page is shown, which rows it has, and the pages to link to, as Django's
## admin links them (the first two, three on each side of this one, the last two).
Paging := [].{

	## A page: its `number` (from 1) of `pages`, of `total` rows, `size` rows a page.
	Page : { number : U64, pages : U64, total : U64, size : U64 }

	## The page `asked` for of `total` rows, `size` a page: the last one if it asks past it, the
	## first if it asks for 0. With no rows, there is still one page, empty.
	of : U64, U64, U64 -> Page
	of = |total, size, asked| {
		each = U64.max(size, 1)
		pages = U64.max(1, (total + each - 1) // each)
		{ number: U64.min(pages, U64.max(1, asked)), pages, total, size: each }
	}

	## How many rows come before the page's first: its `offset`.
	offset : Page -> U64
	offset = |page| (page.number - 1) * page.size

	## The rows the page shows, counted from 1 (`{ first: 51, last: 100 }`); both 0 when there are
	## none.
	shows : Page -> { first : U64, last : U64 }
	shows = |page|
		if page.total == 0 {
			{ first: 0, last: 0 }
		} else {
			{ first: Paging.offset(page) + 1, last: U64.min(page.total, Paging.offset(page) + page.size) }
		}

	## The pages to link to, in order, with a `Gap` where some are left out: all of them when there
	## are ten or fewer.
	links : Page -> List([Number(U64), Gap])
	links = |page| {
		at = page.number
		last = page.pages
		if last <= 10 {
			numbers(1, last)
		} else {
			before = if (at > 6) numbers(1, 2).append(Gap).concat(numbers(at - 3, at)) else numbers(1, at)
			after = if (at + 5 < last) numbers(at + 1, at + 3).append(Gap).concat(numbers(last - 1, last)) else numbers(at + 1, last)
			before.concat(after)
		}
	}
}

## `Number(from)` to `Number(to)`, both included; none if `to` is less.
numbers : U64, U64 -> List([Number(U64), Gap])
numbers = |from, to| {
	var $out = []
	var $at = from
	while $at <= to {
		$out = $out.append(Number($at))
		$at = $at + 1
	}
	$out
}

expect Paging.of(0, 50, 1) == { number: 1, pages: 1, total: 0, size: 50 }
expect Paging.of(137, 50, 9) == { number: 3, pages: 3, total: 137, size: 50 }
expect Paging.of(137, 50, 0).number == 1
expect Paging.of(100, 50, 2).pages == 2
expect Paging.of(5, 0, 1).size == 1
expect Paging.offset(Paging.of(137, 50, 3)) == 100
expect Paging.shows(Paging.of(137, 50, 3)) == { first: 101, last: 137 }
expect Paging.shows(Paging.of(0, 50, 1)) == { first: 0, last: 0 }
expect Paging.links(Paging.of(137, 50, 2)) == [Number(1), Number(2), Number(3)]
expect Paging.links(Paging.of(1000, 10, 1)) == [Number(1), Number(2), Number(3), Number(4), Gap, Number(99), Number(100)]
expect Paging.links(Paging.of(1000, 10, 50)) == [Number(1), Number(2), Gap, Number(47), Number(48), Number(49), Number(50), Number(51), Number(52), Number(53), Gap, Number(99), Number(100)]
expect Paging.links(Paging.of(1000, 10, 100)) == [Number(1), Number(2), Gap, Number(97), Number(98), Number(99), Number(100)]
expect Paging.links(Paging.of(1000, 10, 6)) == [Number(1), Number(2), Number(3), Number(4), Number(5), Number(6), Number(7), Number(8), Number(9), Gap, Number(99), Number(100)]
expect Paging.links(Paging.of(1000, 10, 95)) == [Number(1), Number(2), Gap, Number(92), Number(93), Number(94), Number(95), Number(96), Number(97), Number(98), Number(99), Number(100)]
