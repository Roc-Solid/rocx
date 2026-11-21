# charts

Bar, stacked bar, line, sparkline, donut, scatter and heatmap charts for Roc Solid apps, drawn as
SVG. They render on the server
and hydrate in the browser like any component. When the data changes, they glide to it, a frame
at a time, and once they get there nothing runs. The docs site's charts page (`/ecosystem/charts`)
has each one live, with buttons that give it other data and restyle it three ways.

```roc
import charts.BarChart
import charts.Format

<BarChart data!={rain!()} label="Rain each month, in millimetres" format={|mm| Format.num(mm, 0)} />
```

## Two halves

**The arithmetic is a Roc package** (`main.roc`): plain Roc on no platform, so a page rendered
once, a component in the browser and the server's code all use the same functions. Its numbers are
`Dec`, Roc's decimal, so the ticks from 0 to 1 are 0.2, 0.4, 0.6 and 0.8, exactly.

| Module | What it does |
|---|---|
| `Scale` | `Scale.linear(domain, range)`: `scale.at(value)` is a place, `scale.invert(place)` a value; `.nice(count)` widens the domain to round numbers, `.ticks(count)` lists them; `Scale.extent(values)` |
| `Band` | `Band.band(count, range, padding)`: a slot for each bar; `.at(slot)`, `.width()`, `.center(slot)`; a count and a slot may be fractions, as they are while a chart glides |
| `Ticks` | `Ticks.step`, `Ticks.between`, `Ticks.nice`: about `count` ticks at 1, 2 or 5 times a power of ten |
| `Path` | SVG path data: `line`, `smooth` (monotone curves, as D3's `curveMonotoneX`), `area`, `smooth_area`, `arc` (a pie's or a donut's slice) |
| `Format` | `num(x, places)` (`"2.5"`, not `"2.50"` or `"2.5000000000000000"`), `short` (`"1.3k"`, `"2.5M"`), `percent`, `coord` |
| `Ease` | `toward(from, to, ms, close)`: one frame's share of a glide, which ends |
| `Keys` | what keeps a mark its own: `unique` (a key per label, `Jan#1` for a second `Jan`), `merge` (the new keys, with the ones going where they were), `slots` (a colour that stays with its key) |

`roc test packages/charts/main.roc` runs their `expect`s.

**The components are `.rocx` files** (`components/`: `BarChart`, `StackedBarChart`,
`LineChart`, `Sparkline`, `DonutChart`, `ScatterChart`, `Heatmap`). They import the platform's `Html` and
`Solid`, and a Roc package can't do that for a Roc Solid app: the compiler lets a package name a
platform, but only the very one the app names, and an app is two apps, one on the web platform
(the browser's) and one on the server's. So `rocx build` copies them into the app, where `pf` means
whichever platform each half is on:

1. Name the package in both of the app's headers (`client.roc` and `server.roc`), by its
   directory's name:

   ```roc
   app [...] { charts: "../packages/charts/main.roc", pf: platform "…" }
   ```

2. `rocx build` writes each component to the app's `Generated/charts/` (`Generated/charts/BarChart.roc`),
   and in a `.rocx` file, `import charts.BarChart` imports that copy. Its `<style>` goes in the
   app's stylesheet with the others, and the compiler's reports point at the file here.

## `<BarChart>`

| Prop | |
|---|---|
| `data! : () => List({ label : Str, value : Dec })` | a bar for each, in order, kept by its label: a new value glides its bar there; a new bar grows from the axis as the others make room; one whose label is gone shrinks into the axis as it fades (`transition:out`) while the others close up; a new order slides each bar to its place |
| `label : Str` | what the chart shows, for screen readers |
| `format : Dec -> Str` | a value's text: the ticks', and a bar's when it is pointed at or focused |
| `padding : Dec ?? 0.3` | the share of each bar's slot left empty |

The axis goes from zero (or the least value, when one is negative) to the greatest value, widened
to round numbers. Each bar can be reached with Tab, and has its label and value for a screen reader.

## `<StackedBarChart>`

| Prop | |
|---|---|
| `data! : () => List({ label : Str, values : List(Dec) })` | a column for each, its values stacked from the axis up, one for each series, kept by its label: each part glides to its new size; a new column grows from the axis as the others make room; one whose label is gone shrinks into it as it fades. A value below zero counts as zero |
| `series : List(Str)` | the series' names, the bottom one first, each in its colour, in the legend over the chart |
| `label : Str` | what the chart shows, for screen readers |
| `format : Dec -> Str` | a value's text: the ticks', and a column's total when it is pointed at or focused |
| `padding : Dec ?? 0.3` | the share of each column's slot left empty |

The axis goes from zero to the tallest column, widened to round numbers. Each column can be
reached with Tab, and has its label and each series' value for a screen reader.

## `<LineChart>`

| Prop | |
|---|---|
| `data! : () => List(Dec)` | the values, left to right, evenly spaced: new values glide the line to them (as many as before; more or fewer are drawn at once) |
| `label : Str` | what the chart shows, for screen readers |
| `format : Dec -> Str` | a value's text: the ticks', and the one under the pointer |
| `smooth : Bool` | monotone curves through the values instead of straight segments |

The axis goes from the least value to the greatest, widened to round numbers. The columns the
pointer finds a value by are laid out by CSS, so a chart whose values change every frame costs
only its path and its axis.

## `<Sparkline>`

| Prop | |
|---|---|
| `data! : () => List(Dec)` | the values, left to right: new values glide the line to them |
| `label! : () => Str` | what it shows, for screen readers: the trend, since there is no axis to read (an accessor, as it changes with the data) |

A small line with no axis, the area under it shaded and a dot on the last value, for beside a
number: it spans its values' range, so it shows their shape, not their size.

## `<DonutChart>`

| Prop | |
|---|---|
| `data! : () => List({ label : Str, value : Dec })` | a slice for each, clockwise from twelve o'clock, as big a share of the ring as its value is of them all, kept by its label: a new value glides its slice to its new share; a new slice grows from nothing as the others make room; one whose label is gone shrinks to nothing where it was. A value below zero counts as zero |
| `label : Str` | what the chart shows, for screen readers |
| `format : Dec -> Str` | a value's text: the total's, and each slice's in the legend |
| `total : Str ?? "Total"` | the word under the total |
| `thickness : Dec ?? 52` | the ring's, of its 150 radius; 150 is a pie, which has no middle |

The middle says the total, or, while a slice is pointed at or focused (each can be reached with
Tab), or its line in the legend is pointed at, that slice's share. A slice keeps its colour while
others come and go, and a new one takes a colour no slice has.

## `<ScatterChart>`

| Prop | |
|---|---|
| `data! : () => List({ label : Str, x : Dec, y : Dec })` | a dot for each, across by its `x` and up by its `y`, kept by its label: new values glide it to its place; a new dot swells from nothing where it goes, and one whose label is gone shrinks away (a `transition` both ways) |
| `label : Str` | what the chart shows, for screen readers |
| `format_x : Dec -> Str` | a value across: the ticks along the bottom, and a dot's when it is pointed at or focused |
| `format_y : Dec -> Str` | a value up: the ticks up the side, and a dot's |

Each axis goes from its least value to its greatest, widened to round numbers. Each dot can be
reached with Tab, and has its label and values for a screen reader.

## `<Heatmap>`

| Prop | |
|---|---|
| `data! : () => List(List(Dec))` | a list of values for each row, one for each column: each cell's colour, from `--chart-heat-low` at zero to `--chart-heat-high` at the greatest value |
| `rows : List(Str)` | the rows' labels, down the side |
| `columns : List(Str)` | the columns' labels: each in the readout, and about eight along the bottom (every second or third, when there are more) |
| `label : Str` | what the chart shows, for screen readers |
| `format : Dec -> Str` | a value's text: the scale's ends, and the cell pointed at |

Under the grid, the scale, and the cell the pointer is on. A new value changes a cell's strength (a
custom property), and the browser fades it to its new colour, a CSS transition, so Roc runs no
frames at all.

## Styling

Each chart is `width: 100%` (a donut and its legend share the width, and wrap when it is narrow)
and draws itself from custom properties, falling back to the text's colour, or to a plain default,
where one isn't set. So a look is a few lines of CSS on anything around the charts; the docs
site's charts page has three (Neon, Blueprint and Paper), each one rule and a prop or two
(`padding`, `smooth`, `thickness`).

| Property | |
|---|---|
| `--chart-color`, `--chart-active` | bars, the lines, dots; a pointed-at bar or dot, the point |
| `--chart-1` to `--chart-5` | the slices', the series': a colour that stays with its slice or series |
| `--chart-heat-low`, `--chart-heat-high` | a heatmap's ends: zero, and the greatest value |
| `--chart-fill`, `--chart-stroke`, `--chart-stroke-width`, `--chart-outline` | marks' fill opacity and outline; with `--chart-outline: 1`, a slice or a part is outlined in its own colour instead of the surface's |
| `--chart-radius`, `--chart-dot`, `--chart-line-width`, `--chart-area` | bars' corners, dots' radius, lines' width, the shade under a line (0 for none) |
| `--chart-grid`, `--chart-grid-dash`, `--chart-axis`, `--chart-muted` | the grid and its dashes, the axis, ticks' and labels' text |
| `--chart-surface`, `--chart-font`, `--chart-glow` | behind the marks (the gaps between slices and parts), the font, a `filter` on the marks (a `drop-shadow`, say) |

## Limits, for now

- Values are `Dec`. Roc has no `F64` to `Dec` conversion yet; `(x * 1000.0).round_to_i64_try()`
  then `.to_dec() / 1000.0` makes one.
- A donut and a stacked bar chart have five colours: a sixth slice or series shares one. Fold the
  smallest into "Other". When the data puts a donut's slices in another order, they take their new
  places at once.
- A heatmap's cells, and the sparkline's points, can't be reached with Tab: each is one image to a
  screen reader, named by its label.
- rocx writes HTML tags in lower case, so SVG's camel-cased elements (`<linearGradient>`,
  `<clipPath>`) can't be written yet.
