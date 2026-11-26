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

	## Around each of `places` (left to right), the stretch of `(from, to)` nearer it than the places
	## beside it: from halfway to the one before to halfway to the one after, the first from `from`
	## and the last to `to`. One place alone has the whole of it. What a line chart's pointer finds
	## its points by: `Scale.strips([48.0, 143.0, 620.0], (48.0, 620.0))`.
	strips : List(Dec), (Dec, Dec) -> List((Dec, Dec))
	strips = |places, (from, to)| {
		count = places.len()
		places.map_with_index(
			|place, i| {
				start = if (i == 0) from else (place + (places.get(i - 1) ?? place)) / 2.0
				end = if (i + 1 == count) to else (place + (places.get(i + 1) ?? place)) / 2.0
				(start, end)
			},
		)
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

# Points on days 0, 1 and 6 of a week, to scale on a plot from 0 to 600: the first's strip reaches
# halfway to the second, and the last's from halfway to the one before it.
expect {
	across = Scale.linear(Scale.extent([0.0, 1.0, 6.0]), (0.0, 600.0))
	places = [0.0, 1.0, 6.0].map(|day| across.at(day))
	places == [0.0, 100.0, 600.0] and Scale.strips(places, (0.0, 600.0)) == [(0.0, 50.0), (50.0, 350.0), (350.0, 600.0)]
}
expect Scale.strips([20.0], (0.0, 40.0)) == [(0.0, 40.0)]
expect Scale.strips([], (0.0, 40.0)) == []
