import Ticks

## A linear scale: a value in a domain (the data's: 0 to 120 kWh) at a place in a range (the
## screen's: 300 down to 0, since an SVG's y grows downward). `scale.at(value)` is the place.
Scale := { domain : (Dec, Dec), range : (Dec, Dec) }.{

	## The scale from `domain` onto `range`.
	linear : (Dec, Dec), (Dec, Dec) -> Scale
	linear = |domain, range| { domain, range }

	## Where `value` goes: `Scale.linear((0.0, 10.0), (0.0, 200.0)).at(2.5)` is 50. A value outside
	## the domain goes outside the range, in proportion; a domain of one value puts it mid-range.
	at : Scale, Dec -> Dec
	at = |scale, value| {
		(d0, d1) = scale.domain
		(r0, r1) = scale.range
		if d0 == d1 {
			(r0 + r1) / 2.0
		} else {
			r0 + (value - d0) * (r1 - r0) / (d1 - d0)
		}
	}

	## The value at `place`: `at`, the other way.
	invert : Scale, Dec -> Dec
	invert = |scale, place| Scale.linear(scale.range, scale.domain).at(place)

	## The domain widened to ticks (`Ticks.nice`), so the axis starts and ends on one.
	nice : Scale, U64 -> Scale
	nice = |scale, count| {
		(d0, d1) = scale.domain
		Scale.linear(Ticks.nice(d0, d1, count), scale.range)
	}

	## About `count` round values across the domain, for an axis.
	ticks : Scale, U64 -> List(Dec)
	ticks = |scale, count| {
		(d0, d1) = scale.domain
		Ticks.between(d0, d1, count)
	}

	## The least and the greatest of `values`, for a domain: `(0, 0)` for none.
	extent : List(Dec) -> (Dec, Dec)
	extent = |values|
		match values.first() {
			Ok(first) => values.fold((first, first), |(low, high), value| (Dec.min(low, value), Dec.max(high, value)))
			Err(_) => (0.0, 0.0)
		}
}

expect Scale.linear((0.0, 10.0), (0.0, 200.0)).at(2.5) == 50.0
expect Scale.linear((0.0, 10.0), (300.0, 0.0)).at(10.0) == 0.0
expect Scale.linear((0.0, 10.0), (300.0, 0.0)).at(15.0) == -150.0
expect Scale.linear((5.0, 5.0), (0.0, 100.0)).at(7.0) == 50.0
expect Scale.linear((0.0, 10.0), (300.0, 0.0)).invert(150.0) == 5.0
expect Scale.linear((3.0, 97.0), (0.0, 1.0)).nice(5).domain == (0.0, 100.0)
expect Scale.linear((0.0, 1.0), (0.0, 1.0)).ticks(4) == [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
expect Scale.extent([3.0, -1.5, 8.0, 2.0]) == (-1.5, 8.0)
expect Scale.extent([]) == (0.0, 0.0)
