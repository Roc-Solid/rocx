## Numbers as text, for labels and for SVG. `Dec.to_str` writes every digit a number has, and a
## whole one with `.0`; these round first, and drop the zeros a reader doesn't need.
Format := [].{

	## `x` to at most `places` decimal places, without trailing zeros: `Format.num(2.50, 2)` is
	## `"2.5"`, `Format.num(3.0, 2)` is `"3"`, `Format.num(1.005, 2)` is `"1.01"` (a half rounds
	## away from zero).
	num : Dec, U64 -> Str
	num = |x, places| trimmed(Dec.round_to(x, { step: unit(places), ties: AwayFromZero }).to_str())

	## To hundredths: plenty for a place on a screen, and short in an SVG path.
	coord : Dec -> Str
	coord = |x| Format.num(x, 2)

	## Thousands as `k`, millions as `M`, billions as `B`, to a decimal place: 1250 is `"1.3k"`,
	## -2500000 is `"-2.5M"`, 950 is `"950"`, and 999.97 is `"1k"`, not `"1000"`.
	short : Dec -> Str
	short = |x| {
		size = Dec.abs(x)
		if size >= 999950000.0 {
			"${Format.num(x / 1000000000.0, 1)}B"
		} else if size >= 999950.0 {
			"${Format.num(x / 1000000.0, 1)}M"
		} else if size >= 999.95 {
			"${Format.num(x / 1000.0, 1)}k"
		} else {
			Format.num(x, 1)
		}
	}

	## A share as a percentage: `Format.percent(0.256, 1)` is `"25.6%"`.
	percent : Dec, U64 -> Str
	percent = |x, places| "${Format.num(x * 100.0, places)}%"

	## Each value's share of them all, as whole percents that add up to 100: each rounded down, and
	## the points left over to the largest remainders (the earlier first on a tie). One with
	## something that comes to none is "<1%"; below zero counts as zero, and nothing at all is "0%"
	## each. A donut's legend and a stacked area chart's say their shares so.
	shares : List(Dec) -> List(Str)
	shares = |values| {
		kept = values.map(|value| Dec.max(value, 0.0))
		total = kept.fold(0.0, |sum, value| sum + value)
		if total <= 0.0 {
			kept.map(|_| "0%")
		} else {
			exact = kept.map(|value| value * 100.0 / total)
			whole = exact.map(|share| Dec.floor(share))
			left = 100.0 - whole.fold(0.0, |sum, share| sum + share)
			var $order = []
			for item in List.map2(exact, whole, |share, down| share - down).map_with_index(|remainder, index| { index, remainder }) {
				at = $order.find_first_index(|other| other.remainder < item.remainder) ?? $order.len()
				$order = $order.take_first(at).append(item).concat($order.drop_first(at))
			}
			var $bumped = []
			for item in $order {
				if $bumped.len().to_dec() < left {
					$bumped = $bumped.append(item.index)
				}
			}
			List.map2(kept, whole, |value, down| (value, down)).map_with_index(
				|(value, down), index| {
					points = if ($bumped.contains(index)) down + 1.0 else down
					if (points == 0.0 and value > 0.0) "<1%" else "${Format.num(points, 0)}%"
				},
			)
		}
	}
}

## The step to round to: 10 to the minus `places` (at most 18 places, all a `Dec` has).
unit : U64 -> Dec
unit = |places| {
	var $step = 1.0
	var $left = U64.min(places, 18)
	while $left > 0 {
		$step = $step / 10.0
		$left = $left - 1
	}
	$step
}

## `"2.50"` → `"2.5"`, `"3.0"` → `"3"`, `"-0.0"` → `"0"`.
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

expect Format.num(2.50, 2) == "2.5"
expect Format.num(3.0, 2) == "3"
expect Format.num(1.005, 2) == "1.01"
expect Format.num(-0.001, 2) == "0"
expect Format.num(1234.5678, 0) == "1235"
expect Format.num(0.1 + 0.2, 3) == "0.3"
expect Format.coord(12.3456) == "12.35"
expect Format.short(950.0) == "950"
expect Format.short(1250.0) == "1.3k"
expect Format.short(999.97) == "1k"
expect Format.short(-2500000.0) == "-2.5M"
expect Format.short(3000000000.0) == "3B"
expect Format.percent(0.256, 1) == "25.6%"

# Whole percents that add up to 100, the points left over to the largest remainders.
expect Format.shares([1.0, 1.0, 1.0]) == ["34%", "33%", "33%"]
expect Format.shares([5.0, 995.0]) == ["1%", "99%"]

# Too small to make a percent, but not nothing; nothing at all; below zero is nothing.
expect Format.shares([2.0, 1989.0]) == ["<1%", "100%"]
expect Format.shares([0.0, 0.0]) == ["0%", "0%"]
expect Format.shares([3.0, -1.0]) == ["100%", "0%"]
