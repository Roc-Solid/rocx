## Charts: the arithmetic a chart is drawn with. Scales put a value at a place (`Scale`, `Band`),
## ticks fall on round numbers (`Ticks`), SVG paths go through points (`Path`), numbers become
## labels (`Format`), a value glides to a new one a frame at a time (`Ease`), and a mark keeps its
## key and its colour while the data changes (`Keys`). It is plain Roc, on no platform, so a page
## rendered once and a component in the browser use the same code. Its numbers are `Dec`s, so a
## tick is 0.3 and not 0.30000000000000004.
##
## The components (`<BarChart>`, `<StackedBarChart>`, `<LineChart>`, `<StackedAreaChart>`,
## `<Sparkline>`, `<DonutChart>`, `<ScatterChart>`, `<Heatmap>`) are in `components/`: `rocx generate`
## copies them into each app that names this package, since a package can't import a platform's
## `Html` for both apps at once. See README.md.
package [Band, Ease, Format, Keys, Path, Scale, Ticks] {}
