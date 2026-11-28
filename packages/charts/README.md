# charts

Bar, stacked bar, line, sparkline, donut, scatter and heatmap charts for Roc Solid apps, drawn as
SVG. The server renders them into the page and the browser hydrates them like any other component.
When the data changes, a chart glides to it, a frame at a time; once it gets there, nothing runs.
The docs site's charts page (`/ecosystem/charts`) has each one live, with buttons that give it
other data and restyle it three ways. This README is the reference: every prop, every function of
the arithmetic, and how it works.

## Installing it

Name the package in the app's header (`main.roc`), by its directory's name:

```roc
app [program] { charts: "../packages/charts/main.roc", pf: platform "…/server/platform/main.roc" }
```

`rocx build` writes each component to the app's `Generated/charts/` (`Generated/charts/BarChart.roc`),
and in a `.rocx` file `import charts.BarChart` imports that copy. Its `<style>` joins the app's
stylesheet with the others, and the compiler's reports point at the file here. The browser's half
of the app (which `rocx build --client` writes) names the same packages.

Why copy them? A component imports the platform's `Html` and `Solid`. A Roc package may name a
platform only if it is the very one its app names, and a Roc Solid app is two programs on two
platforms: the server's and the browser's. Copied into each half, `pf` means that half's platform.
The arithmetic (`main.roc`) is plain Roc on no platform, so both halves, and tests, import it as it is.

## A first chart

```roc
import charts.BarChart
import charts.Format

<BarChart data!={rain!()} label="Rain each month, in millimetres" format={|mm| Format.num(mm, 0)} />
```

Every chart takes:

- `data!`, an accessor prop (`() => …`). The chart calls it to read the data and follows it when it
  changes. `data!={rain!()}` passes any expression that reads signals, as a getter written by hand.
- `label`, what the chart shows, for screen readers (`label!` on `<Sparkline>`, which changes with
  its data).
- `format` (`format_x` and `format_y` on `<ScatterChart>`; `format` and `format_x` on
  `<LineChart>`), which writes a value as text: `Format.short` (`1.3k`) unless said, or a function
  of your own, `|mm| "${Format.num(mm, 0)} mm"`.

Values are `Dec`, Roc's decimal. examples/plate (`<BarChart>`, `<LineChart>`), examples/quiz
(`<BarChart>`) and examples/uptime (`<LineChart>`, `<Heatmap>`, `<Sparkline>`) use the package.

## The components

A bar, a column, a slice or a dot belongs to its label: new data moves the mark already drawn
rather than making another. Two items with the same label are two marks (`Keys.unique`).

### `<BarChart>`

| Prop | |
|---|---|
| `data! : () => List(BarChart.Bar)`, `Bar := { label : Str, value : Dec, color : Str ?? "" }` | A bar for each item, in order. A new value glides its bar there. A new bar grows from the axis while the others make room. A bar whose label is gone shrinks into the axis and fades (`transition:out`) while the others close up. A new order slides each bar to its place. A bar is in its `color` (any CSS colour: `"#c0392b"`, `"var(--brand)"`), which it keeps when pointed at, or, left out, the chart's. |
| `label : Str` | What the chart shows, for screen readers. |
| `format : (Dec -> Str) ?? Format.short` | A value as text: on the ticks, and on a bar when it is pointed at or focused. |
| `padding : Dec ?? 0.3` | The share of each bar's slot left empty. |

The axis runs from zero (or from the least value, if one is negative) to the greatest value,
widened to round numbers. Each bar can be reached with Tab, and a screen reader reads its label and
value.

### `<StackedBarChart>`

| Prop | |
|---|---|
| `data! : () => List({ label : Str, values : List(Dec) })` | A column for each item, with one value per series stacked from the axis up. Each part glides to its new size. A new column grows from the axis while the others make room; one whose label is gone shrinks into the axis and fades. A value below zero counts as zero. |
| `series : List(Str)` | The series' names, bottom one first, each in its colour in the legend over the chart. |
| `label : Str` | What the chart shows, for screen readers. |
| `format : (Dec -> Str) ?? Format.short` | A value as text: on the ticks, and a column's total when it is pointed at or focused. |
| `padding : Dec ?? 0.3` | The share of each column's slot left empty. |

The axis runs from zero to the tallest column, widened to round numbers. Each column can be
reached with Tab, and a screen reader reads its label and each series' value.

### `<LineChart>`

| Prop | |
|---|---|
| `data! : () => List({ x : Dec, y : Dec })` | The points, left to right: each across by its `x` (a number: a day, an hour, a time in milliseconds), to scale, and up by its `y`. New points glide the line to them. With more points or fewer than before, the line jumps to the new data. `LineChart.evenly(values)` puts values one apart (`x` 0, 1, 2…). |
| `label : Str` | What the chart shows, for screen readers. |
| `format : (Dec -> Str) ?? Format.short` | A value (`y`) as text: on the ticks up the side, and over the point under the pointer. |
| `format_x : (Dec -> Str) ?? Format.short` | An `x` as text: on the ticks along the bottom, and the point's under the pointer. |
| `smooth : Bool ?? Bool.False` | Monotone curves through the points (never past one) instead of straight segments. |

The axis up the side runs from the least value to the greatest, widened to round numbers. The one
along the bottom runs from the least `x` to the greatest, so the line spans the plot, with ticks on
round numbers between (`Ticks.between`). Pointing along the chart shows the point nearest the
pointer: its value over the plot and its `x` on the axis, in place of the ticks. The strips the
pointer finds a point by are worked out from where the data puts the points (`Scale.strips`), not
where the line is drawn, so a line that glides to new values doesn't move them. The chart is one
image to a screen reader; its points can't be reached with Tab.

examples/plate draws weight on the days it was logged, a day to scale (`Date.days`, and
`Date.from_days` for its labels); examples/uptime draws response times each half hour, its `x`
the hours before now; the docs' demo is a day's visits, hour by hour, `LineChart.evenly`.

### `<Sparkline>`

| Prop | |
|---|---|
| `data! : () => List(Dec)` | The values, left to right. New values glide the line to them. |
| `label! : () => Str` | What it shows, for screen readers. With no axis to read, say the trend. An accessor, since it changes with the data. |

A small line with no axis, the area under it shaded and a dot on the last value, to sit beside a
number. It spans its values' range, so it shows their shape, not their size.

### `<DonutChart>`

| Prop | |
|---|---|
| `data! : () => List(DonutChart.Slice)`, `Slice := { label : Str, value : Dec, color : Str ?? "" }` | A slice for each item, clockwise from twelve o'clock, its share of the ring its share of the total. A new value glides its slice to its new share. A new slice grows from nothing while the others make room; one whose label is gone shrinks to nothing where it was. A value below zero counts as zero. A slice is in its `color` (any CSS colour), it and its legend line, or, left out, one of the chart's five. |
| `label : Str` | What the chart shows, for screen readers. |
| `format : (Dec -> Str) ?? Format.short` | A value as text: the total, and each slice's value in the legend. |
| `total : Str ?? "Total"` | The word under the total. |
| `thickness : Dec ?? 52` | The ring's width, out of a radius of 150 (SVG units). 150 is a pie. Above 90 the middle has no room, and the total isn't shown. |

The middle shows the total, or, while a slice is pointed at or focused (each can be reached with
Tab) or its line in the legend is pointed at, that slice's share. Shares are whole percents that add
up to 100 (the points left over go to the largest remainders), and "<1%" for a value too small to
make one, whose slice is still drawn, as a sliver (a hundredth of the ring). A slice keeps its colour while
others come and go, and a new slice takes a colour no other slice has, unless the data gives each
its own.

**Colours from the data.** A bar or a slice may carry its colour, as a slice for each party in
its party's colour:

```roc
<DonutChart data!={seats!().map(|party| { label: party.name, value: party.seats, color: party.color })} label="Seats by party" />
```

`color` is left out (or `""`) for the chart's own. A record written where the data is passed is a
`DonutChart.Slice` (or a `BarChart.Bar`), with `color` or without; a list already typed as plain
records (`List({ label : Str, value : Dec })`) isn't, so name the chart's type in its annotation
(`List(DonutChart.Slice)`), or build the records where you pass them
(`.map(|{ label, value }| { label, value })`).

### `<ScatterChart>`

| Prop | |
|---|---|
| `data! : () => List({ label : Str, x : Dec, y : Dec })` | A dot for each item, across by its `x` and up by its `y`. New values glide it to its place. A new dot swells from nothing where it goes, and one whose label is gone shrinks away (a `transition` both ways). |
| `label : Str` | What the chart shows, for screen readers. |
| `format_x : (Dec -> Str) ?? Format.short` | A value across: on the ticks along the bottom, and on a dot when it is pointed at or focused. |
| `format_y : (Dec -> Str) ?? Format.short` | A value up: on the ticks up the side, and on a dot. |

Each axis runs from its least value to its greatest, widened to round numbers. Each dot can be
reached with Tab, and a screen reader reads its label and values.

### `<Heatmap>`

| Prop | |
|---|---|
| `data! : () => List(List(Dec))` | A list of values for each row, one value per column. A cell's colour goes from `--chart-heat-low` at zero to `--chart-heat-high` at the greatest value. |
| `rows : List(Str)` | The rows' labels, down the side. |
| `columns : List(Str)` | The columns' labels. Each appears in the readout; along the bottom there is room for about eight, so with more columns only every second or third is shown. |
| `label : Str` | What the chart shows, for screen readers. |
| `format : (Dec -> Str) ?? Format.short` | A value as text: the scale's ends, and the cell pointed at. |

Under the grid are the colour scale and a readout of the cell under the pointer (its row, column
and value). A new value changes a cell's strength (a custom property), and the browser fades the
cell to its new colour with a CSS transition, so Roc runs no frames at all. The cells can't be
reached with Tab; the chart is one image to a screen reader.

## How they move

A chart keeps what it has drawn in a signal, apart from the data. While the two differ, a hole's
`if` holds a hidden element with an `on:frame.ms` handler, which moves the drawing a share of the
remaining way each animation frame (`Ease.toward`). When the drawing reaches the data, the `if`
turns false, the element goes, and the browser is asked for no more frames. Marks that come and go
as elements play a platform `Transition` (`grow`, `fade`, `scale`), which the browser runs; the
heatmap's colours are a CSS transition.

## The arithmetic

`main.roc` is a plain Roc package, on no platform, so a page rendered once, a component in the
browser and the server's code use the same functions, and you can draw charts of your own with them.
Its numbers are `Dec`, so the ticks from 0 to 1 are exactly 0.2, 0.4, 0.6 and 0.8.
`roc test packages/charts/main.roc` runs their `expect`s.

| Module | Functions |
|---|---|
| `Scale` | `Scale.linear(domain, range)`, a value in a domain at a place in a range; `scale.at(value)`, the place; `scale.invert(place)`, the value; `scale.nice(count)`, the domain widened to round numbers; `scale.ticks(count)`, about `count` round values across it; `Scale.extent(values)`, the least and the greatest (`(0, 0)` for none); `Scale.strips(places, (from, to))`, the stretch of `(from, to)` nearer each place than the places beside it (halfway to each neighbour; the first from `from`, the last to `to`), which a line chart's pointer finds its points by |
| `Band` | `Band.band(count, range, padding)`, `count` equal slots across `range`, a `padding` share of each left empty; `.at(slot)`, where a bar starts; `.width()`, a bar's width; `.slot()`, a slot's width; `.center(slot)`, where its label goes. A count and a slot may be fractions: a chart gliding from seven bars to six has six and a half slots on the way |
| `Ticks` | `Ticks.step(from, to, count)`, the step between about `count` ticks, 1, 2 or 5 times a power of ten; `Ticks.between(from, to, count)`, the ticks; `Ticks.nice(from, to, count)`, the ends widened to ticks |
| `Path` | SVG path data for `<path d={…}>`: `line(points)`, `smooth(points)` (monotone curves, as D3's `curveMonotoneX`), `area(points, base)`, `smooth_area(points, base)`, `arc({ x, y, inner, outer, from, to })` (a donut's slice, or with `inner` 0 a pie's; `from` and `to` in turns, 0 at twelve o'clock) |
| `Format` | `num(x, places)`, at most `places` decimals without trailing zeros (`"2.5"`, not `"2.50"` or `"2.5000000000000000"`); `short(x)`, `"1.3k"`, `"2.5M"`, `"3B"`; `percent(share, places)`, `"25.6%"`; `coord(x)`, to hundredths, for SVG |
| `Ease` | `toward(from, to, ms, close)`, one frame's step of a glide (a fifth of the way in a 16 ms frame, all of it in 80 ms or more, or once within `close`); `share(ms)`, that share |
| `Keys` | `unique(labels)`, a key per label (`Jan#1` for a second `Jan`); `merge(was, now)`, the keys `now`, with each key only `was` has (one on its way out) kept after the key it followed; `slots(was, keys)`, a colour slot for each key that stays with it; `slot_of(slots, key)` |

## Styling

Each chart is `width: 100%` (a donut and its legend share the width, and wrap when it is narrow).
It draws itself from CSS custom properties, falling back to the text's colour or a plain default
for any not set. So a look is a few lines of CSS on any element around the charts. The docs site's
charts page has three (Neon, Blueprint and Paper), each one rule plus a prop or two (`padding`,
`smooth`, `thickness`).

| Property | Sets |
|---|---|
| `--chart-color`, `--chart-active` | bars, lines and dots; a bar or dot pointed at, and the line chart's point (a bar's own `color` comes first) |
| `--chart-1` to `--chart-5` | a donut's slices and a stacked chart's series: a colour that stays with its slice or series (a slice's own `color` comes first) |
| `--chart-heat-low`, `--chart-heat-high` | a heatmap's colours at zero and at the greatest value |
| `--chart-fill`, `--chart-stroke`, `--chart-stroke-width`, `--chart-outline` | the marks' fill opacity and outline; with `--chart-outline: 1`, a slice or a part is outlined in its own colour instead of the surface's |
| `--chart-radius`, `--chart-dot`, `--chart-line-width`, `--chart-area` | bars' corners, dots' radius, lines' width, the shading under a line (0 for none) |
| `--chart-grid`, `--chart-grid-dash`, `--chart-axis`, `--chart-muted` | the grid and its dashes, the axis, the text of ticks and labels |
| `--chart-surface`, `--chart-font`, `--chart-glow` | the background behind the marks (the gaps between slices and parts), the font, a `filter` on the marks (a `drop-shadow`, say) |

## Limits, for now

- Values are `Dec`, and Roc has no `F64` to `Dec` conversion yet. Round to an integer and divide:
  `(x * 1000.0).round_to_i64_try()`, then `.to_dec() / 1000.0`.
- A stacked bar chart has five colours, so a sixth series shares one, and so does a donut's sixth
  slice unless the data gives the slices their colours. Fold the smallest into "Other". When new
  data puts a donut's slices in another order, they jump to their new places rather than glide.
- A heatmap's cells, a line chart's points and a sparkline's can't be reached with Tab: each of
  these charts is one image to a screen reader, named by its label.
- A line chart's ticks along the bottom fall on round numbers of its `x`: days since 1970 in steps
  of 1, 2, 5, 10 or 20, hours in steps of 5, not each Monday or the first of each month.
- rocx requires HTML tags in lower case, so SVG's camel-cased elements (`<linearGradient>`,
  `<clipPath>`) can't be written yet.
