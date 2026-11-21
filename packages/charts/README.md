# charts

Bar and line charts for Roc Solid apps, drawn as SVG. They render on the server and hydrate in the
browser like any component. When the data changes, the bars and the axis glide to their new
places, and once they get there nothing runs.

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

`roc test packages/charts/main.roc` runs their `expect`s.

**The components are `.rocx` files** (`components/`). They import the platform's `Html` and
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

The axis goes from zero (or the least value, when one is negative) to the greatest value, widened
to round numbers. Each bar can be reached with Tab, and has its label and value for a screen reader.

## `<LineChart>`

| Prop | |
|---|---|
| `data! : () => List(Dec)` | the values, left to right, evenly spaced |
| `label : Str` | what the chart shows, for screen readers |
| `format : Dec -> Str` | a value's text: the ticks', and the one under the pointer |
| `smooth : Bool` | monotone curves through the values instead of straight segments |

The axis goes from the least value to the greatest, widened to round numbers. The columns the
pointer finds a value by are laid out by CSS, so a chart whose values change every frame costs
only its path and its axis.

## Styling

Each chart is `width: 100%`, in a 640 by 320 viewBox, and takes its colours from custom
properties, falling back to the text's colour where they aren't set:

`--chart-color` (bars, the line), `--chart-active` (a pointed-at bar, the point),
`--chart-grid`, `--chart-axis`, `--chart-muted` (tick and bar labels), `--chart-surface` (behind
the point), `--chart-font`.

## Limits, for now

- Values are `Dec`. Roc has no `F64` to `Dec` conversion yet; `(x * 1000.0).round_to_i64_try()`
  then `.to_dec() / 1000.0` makes one.
- rocx writes HTML tags in lower case, so SVG's camel-cased elements (`<linearGradient>`,
  `<clipPath>`) can't be written yet.
