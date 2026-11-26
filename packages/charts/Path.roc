import Format

## SVG path data, for `<path d={…}>`: lines and curves through points, the area under them, and
## slices of a ring. A point is `(x, y)` in the SVG's own units, written to hundredths.
Path := [].{

	## Straight segments through `points`: `M0,10L5,3L10,7`. No points is `""`.
	line : List((Dec, Dec)) -> Str
	line = |points| Str.join_with(points.map_with_index(|point, i| "${if (i == 0) "M" else "L"}${xy(point)}"), "")

	## Curves through `points`, which go left to right: monotone, so between two points the curve
	## stays between their heights (a rising run doesn't dip first, as a Catmull-Rom curve's can),
	## the way D3's `curveMonotoneX` draws it.
	smooth : List((Dec, Dec)) -> Str
	smooth = |points| {
		count = points.len()
		if count < 3 {
			Path.line(points)
		} else {
			pairs = List.map2(points, points.drop_first(1), |a, b| (a, b))
			# The slope of each segment, and of the curve at each point.
			slopes = pairs.map(|((x0, y0), (x1, y1))| if (x1 == x0) 0.0 else (y1 - y0) / (x1 - x0))
			widths = pairs.map(|((x0, _), (x1, _))| x1 - x0)
			inside = |i| tangent(slopes.get(i - 1) ?? 0.0, slopes.get(i) ?? 0.0, widths.get(i - 1) ?? 0.0, widths.get(i) ?? 0.0)
			last = count - 1
			at_end = |segment, next| {
				((x0, y0), (x1, y1)) = pairs.get(segment) ?? ((0.0, 0.0), (0.0, 0.0))
				if (x1 == x0) next else (3.0 * (y1 - y0) / (x1 - x0) - next) / 2.0
			}
			tangents = points.map_with_index(
				|_, i|
					if i == 0 {
						at_end(0, inside(1))
					} else if i == last {
						at_end(last - 1, inside(last - 1))
					} else {
						inside(i)
					},
			)
			curves = pairs.map_with_index(
				|((x0, y0), (x1, y1)), i| {
					third = (x1 - x0) / 3.0
					m0 = tangents.get(i) ?? 0.0
					m1 = tangents.get(i + 1) ?? 0.0
					"C${xy((x0 + third, y0 + m0 * third))} ${xy((x1 - third, y1 - m1 * third))} ${xy((x1, y1))}"
				},
			)
			start = points.first() ?? (0.0, 0.0)
			"M${xy(start)}${Str.join_with(curves, "")}"
		}
	}

	## The region between straight segments through `points` and the line `y = base` (an axis),
	## for an area chart.
	area : List((Dec, Dec)), Dec -> Str
	area = |points, base| close(Path.line(points), points, base)

	## The same, under `smooth`'s curves.
	smooth_area : List((Dec, Dec)), Dec -> Str
	smooth_area = |points, base| close(Path.smooth(points), points, base)

	## A slice of a ring around (`x`, `y`), from radius `inner` to `outer`, from turn `from` to
	## turn `to`: 0 is twelve o'clock, 0.25 three, 1 all the way round. A donut's piece, or with
	## `inner` 0 a pie's. Nothing to span is `""`.
	arc : { x : Dec, y : Dec, inner : Dec, outer : Dec, from : Dec, to : Dec } -> Str
	arc = |{ x, y, inner, outer, from, to }| {
		at = |radius, turn| (x + radius * Dec.sin(turn * Dec.tau), y - radius * Dec.cos(turn * Dec.tau))
		round = |radius, sweep| "A${Format.coord(radius)},${Format.coord(radius)} 0 1 ${sweep} "
		if to - from <= 0.0 {
			""
		} else if to - from >= 1.0 {
			# A whole ring is two half turns: an arc that ends where it starts draws nothing. The
			# inner circle goes the other way round, so it is a hole.
			outside = "M${xy(at(outer, 0.0))}${round(outer, "1")}${xy(at(outer, 0.5))}${round(outer, "1")}${xy(at(outer, 0.0))}Z"
			if (inner > 0.0) "${outside}M${xy(at(inner, 0.0))}${round(inner, "0")}${xy(at(inner, 0.5))}${round(inner, "0")}${xy(at(inner, 0.0))}Z" else outside
		} else {
			large = if (to - from > 0.5) "1" else "0"
			edge = |radius, sweep, end| "A${Format.coord(radius)},${Format.coord(radius)} 0 ${large} ${sweep} ${xy(end)}"
			outside = "M${xy(at(outer, from))}${edge(outer, "1", at(outer, to))}"
			if (inner > 0.0) "${outside}L${xy(at(inner, to))}${edge(inner, "0", at(inner, from))}Z" else "${outside}L${xy((x, y))}Z"
		}
	}
}

## `x,y`, each to hundredths.
xy : (Dec, Dec) -> Str
xy = |(x, y)| "${Format.coord(x)},${Format.coord(y)}"

## A line's path, down to `base` at its last point, back along it to its first, and closed.
close : Str, List((Dec, Dec)), Dec -> Str
close = |line, points, base|
	match (points.first(), points.last()) {
		(Ok((first, _)), Ok((last, _))) => "${line}L${xy((last, base))}L${xy((first, base))}Z"
		_ => ""
	}

## The curve's slope at a point between a segment of slope `s0` and width `h0` and one of slope
## `s1` and width `h1`: flat at a peak or a trough, otherwise no steeper than either segment
## (Fritsch and Carlson's condition, which keeps the curve monotone).
tangent : Dec, Dec, Dec, Dec -> Dec
tangent = |s0, s1, h0, h1|
	if s0 * s1 <= 0.0 or h0 + h1 == 0.0 {
		0.0
	} else {
		p = (s0 * h1 + s1 * h0) / (h0 + h1)
		steepest = Dec.min(Dec.min(Dec.abs(s0), Dec.abs(s1)), Dec.abs(p) / 2.0)
		if (s0 > 0.0) 2.0 * steepest else -2.0 * steepest
	}

expect Path.line([(0.0, 10.0), (5.0, 3.0), (10.0, 7.0)]) == "M0,10L5,3L10,7"
expect Path.line([]) == ""
expect Path.line([(1.234, 5.678)]) == "M1.23,5.68"
expect Path.area([(0.0, 10.0), (5.0, 3.0), (10.0, 7.0)], 20.0) == "M0,10L5,3L10,7L10,20L0,20Z"
expect Path.area([], 20.0) == ""
# A peak: flat at the top, and as steep at each end as the segment's line through it allows.
expect Path.smooth([(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)]) == "M0,0C0.33,0.5 0.67,1 1,1C1.33,1 1.67,0.5 2,0"
# A straight run stays straight.
expect Path.smooth([(0.0, 0.0), (1.0, 1.0), (2.0, 2.0)]) == "M0,0C0.33,0.33 0.67,0.67 1,1C1.33,1.33 1.67,1.67 2,2"
expect Path.smooth([(0.0, 0.0), (1.0, 1.0)]) == "M0,0L1,1"
# Points unevenly spaced (a line chart's days to scale): a straight run stays straight, each curve a
# third of its own width.
expect Path.smooth([(0.0, 0.0), (1.0, 1.0), (4.0, 4.0)]) == "M0,0C0.33,0.33 0.67,0.67 1,1C2,2 3,3 4,4"
# A rise over a long gap, then a short one: no dip below the first point, nor past the last.
expect Path.smooth([(0.0, 10.0), (6.0, 4.0), (7.0, 0.0)]) == "M0,10C2,9 4,8 6,4C6.33,3.33 6.67,1.67 7,0"
expect Path.arc({ x: 0.0, y: 0.0, inner: 0.0, outer: 10.0, from: 0.0, to: 0.25 }) == "M0,-10A10,10 0 0 1 10,0L0,0Z"
expect Path.arc({ x: 50.0, y: 50.0, inner: 20.0, outer: 40.0, from: 0.25, to: 1.0 }) == "M90,50A40,40 0 1 1 50,10L50,30A20,20 0 1 0 70,50Z"
expect Path.arc({ x: 0.0, y: 0.0, inner: 0.0, outer: 10.0, from: 0.5, to: 0.5 }) == ""
expect Path.arc({ x: 0.0, y: 0.0, inner: 5.0, outer: 10.0, from: 0.0, to: 1.0 }) == "M0,-10A10,10 0 1 1 0,10A10,10 0 1 1 0,-10ZM0,-5A5,5 0 1 0 0,5A5,5 0 1 0 0,-5Z"
