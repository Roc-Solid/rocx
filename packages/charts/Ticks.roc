## Where an axis's ticks go: on round numbers, 1, 2 or 5 times a power of ten, about as many as
## asked for. Counted in `Dec`, so the ticks from 0 to 1 are 0.2, 0.4, 0.6 and 0.8, exactly.
Ticks := [].{

	## The step between about `count` ticks from `from` to `to`: `Ticks.step(0.0, 100.0, 5)` is
	## 20, `Ticks.step(0.0, 1.0, 4)` is 0.2. Nothing to span (or no ticks wanted) is a step of 0.
	step : Dec, Dec, U64 -> Dec
	step = |from, to, count| {
		span = Dec.abs(to - from)
		if span == 0.0 or count == 0 {
			0.0
		} else {
			raw = span / count.to_dec()
			power = power_of_ten(raw)
			ratio = raw / power
			# Round in proportion: 7.07 is about √50, between 5 and 10; 3.16 √10; 1.41 √2.
			if ratio >= 7.07 {
				power * 10.0
			} else if ratio >= 3.16 {
				power * 5.0
			} else if ratio >= 1.41 {
				power * 2.0
			} else {
				power
			}
		}
	}

	## About `count` ticks from `from` to `to`: every multiple of the step between them, ends
	## included. `Ticks.between(0.0, 10.0, 5)` is `[0, 2, 4, 6, 8, 10]`.
	between : Dec, Dec, U64 -> List(Dec)
	between = |from, to, count| {
		low = Dec.min(from, to)
		high = Dec.max(from, to)
		size = Ticks.step(low, high, count)
		if size == 0.0 {
			[low]
		} else {
			last = Dec.floor(high / size)
			var $ticks = []
			var $k = Dec.ceiling(low / size)
			while $k <= last {
				$ticks = $ticks.append($k * size)
				$k = $k + 1.0
			}
			$ticks
		}
	}

	## `from` and `to` widened to ticks, so an axis starts and ends on one: `Ticks.nice(3.0,
	## 97.0, 5)` is `(0, 100)`.
	nice : Dec, Dec, U64 -> (Dec, Dec)
	nice = |from, to, count| {
		# Widening can change the step (12 to 99 in 20s is 0 to 100, which is in 20s too; but not
		# always), so widen again until it doesn't.
		var $low = Dec.min(from, to)
		var $high = Dec.max(from, to)
		var $tries = 0
		var $settled = Bool.False
		while !$settled and $tries < 4 {
			size = Ticks.step($low, $high, count)
			if size == 0.0 {
				$settled = Bool.True
			} else {
				low = Dec.floor($low / size) * size
				high = Dec.ceiling($high / size) * size
				$settled = low == $low and high == $high
				$low = low
				$high = high
			}
			$tries = $tries + 1
		}
		if from <= to {
			($low, $high)
		} else {
			($high, $low)
		}
	}
}

## The power of ten at or under `raw`: 18.8 → 10, 0.25 → 0.1. A `Dec` goes no finer than 10⁻¹⁸.
power_of_ten : Dec -> Dec
power_of_ten = |raw| {
	var $power = 1.0
	while $power <= raw / 10.0 {
		$power = $power * 10.0
	}
	while $power > raw and $power > 0.000000000000000001 {
		$power = $power / 10.0
	}
	$power
}

expect Ticks.step(0.0, 100.0, 5) == 20.0
expect Ticks.step(0.0, 1.0, 4) == 0.2
expect Ticks.step(0.0, 1.0, 10) == 0.1
expect Ticks.step(0.0, 7.0, 5) == 1.0
expect Ticks.step(0.0, 0.0, 5) == 0.0
expect Ticks.step(-50.0, 50.0, 4) == 20.0
expect Ticks.between(0.0, 10.0, 5) == [0.0, 2.0, 4.0, 6.0, 8.0, 10.0]
expect Ticks.between(0.0, 1.0, 5) == [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
expect Ticks.between(0.1, 0.35, 5) == [0.1, 0.15, 0.2, 0.25, 0.3, 0.35]
expect Ticks.between(10.0, 0.0, 5) == [0.0, 2.0, 4.0, 6.0, 8.0, 10.0]
expect Ticks.between(-3.0, 3.0, 3) == [-2.0, 0.0, 2.0]
expect Ticks.between(4.0, 4.0, 5) == [4.0]
expect Ticks.nice(3.0, 97.0, 5) == (0.0, 100.0)
expect Ticks.nice(0.0, 113.0, 5) == (0.0, 120.0)
expect Ticks.nice(97.0, 3.0, 5) == (100.0, 0.0)
expect Ticks.nice(-0.37, 0.92, 5) == (-0.4, 1.0)
