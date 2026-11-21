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
