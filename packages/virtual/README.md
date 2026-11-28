# virtual

`<VirtualList>`: a list of any length that renders only the rows that show. A thousand rows or a
million cost the page the same: the rows inside its box, plus four more on each side. As the box
scrolls, rows that come into view are made and rows that leave are dropped; the rows in between stay
as they are. The user guide, with a live demo, is the docs site's
[Virtual lists page](https://roc-solid.github.io/ecosystem/virtual); this file is the reference.

The component is built from two things the browser platform has: `<Repeat>`, which renders a range
of rows by index and keeps a row while its index stays in the range, and `on:viewport`, which tells
a handler which part of an element shows. Nothing in it needs the host, so it is a package rather
than part of the platform. It isn't a plugin: it adds nothing to the server.

## Installing it

Name the package in the app's header:

```roc
app [program] { pf: platform "…/server/platform/main.roc", virtual: "…/packages/virtual/main.roc" }
```

Then import the component in a `.rocx` file:

```roc
import virtual.VirtualList
```

`rocx generate` (which `rocx dev` and `rocx build` run first) copies `components/VirtualList.rocx`
into each app that names the package (`Generated/virtual/`). A package's header names one platform,
and the component needs the server's `Html` on the server and the browser's in the browser, so it is
compiled as part of the app rather than of the package.

## Using it

```rocx
<VirtualList count={rows!()} row_height={28} class="grid" label="Boxes">
	{|row| <Row index={row} />}
</VirtualList>
```

| Prop | Type | What it is |
|---|---|---|
| `count` | `U64` | How many rows. A getter, like every value prop of an effectful component: the list follows it. |
| `row_height` | `U64` | Each row's height, in pixels. Every row is this high (0 counts as 1). |
| `overscan` | `U64 ?? 4` | Rows rendered beyond those that show, on each side. |
| `first_height` | `U64 ?? 800` | The box height, in pixels, to render rows for before the box is measured: on the server, and until the page has hydrated. |
| `class` | `Str ?? ""` | Classes for the box, added to `virtual-list`. |
| `label` | `Str ?? ""` | The box's `aria-label`; left out when empty. The box has `role="group"`. |
| `on_view!` | `(Html.Viewport => {}) ?? (\|_\| {})` | Called with each measure of the box (`top`, `left`, `width`, `height`, in pixels): the box's width, say, to lay rows out by. |
| the child | `U64 => Html` | A row, given its index from 0. It runs once, when the row is made, as an effectful component does. |

The child is a function child, the component's only child: rocx passes it as the `children` prop of
the component's `view_with!`.

### The box

The box is the component's own `<div>`, which scrolls (`overflow-y: auto; position: relative`).
**Give it a height** through its class. Inside it:

- `div.virtual-list-space` is as tall as all the rows together, `count * row_height` pixels (at most
  10 million: see below). It gives the scrollbar its length.
- `div.virtual-list-rows` holds the rows that are rendered, moved down to where they belong with a
  `transform: translateY(…)`.

A box with no height grows as tall as all its rows and doesn't scroll. The list then renders only
the rows in its first 4,096 pixels (`Rows.most_shown`) and leaves the rest blank, rather than
render every row.

### What the server renders

The server can't measure, so the list renders the rows its first `first_height` pixels would show,
and the browser renders the same rows as it hydrates. Then `on:viewport` measures the box (once it
is on the page, then each time it scrolls or changes size, at most once an animation frame), and the
rows that really show replace them.

### Writing signals from `on_view!`

`on_view!` is called on every scroll. A signal's setter doesn't compare (a memo does, D-109): every
write re-runs whatever reads the signal, whether the value changed or not. So write a signal from it
only when the part of the view you use changes. From `examples/checkboxes`:

```roc
on_view!={|view| if (Grid.columns(view.width) != columns!()) set_columns!(Grid.columns(view.width)) else {}}
```

The list does the same inside: it writes its own view only when the result of `Rows.shown`
changes, so a scroll within one row writes nothing.

## Rows

`Rows` (exposed by `main.roc`) is the arithmetic, plain Roc on no platform. Use it when you need to
know, outside the list, which rows it renders (the docs' demo prints them this way).

| Function | What it answers |
|---|---|
| `shown : { count, row_height, top, height, overscan } -> { first, end, offset }` | The rows a box scrolled `top` pixels down and `height` pixels high renders: from `first` up to, not including, `end` (with `overscan` more each side), the first of them `offset` pixels down the space. `height` is capped at `most_shown`, and `top` at the end of the space (a list that got shorter is scrolled back by the browser, which doesn't report it). |
| `real_top : U64, U64, U64, U64 -> U64` | Where in the rows a box scrolled `top` pixels down is (count, row height, top, height): `top` itself, unless the list is scaled. |
| `space : U64, U64 -> U64` | How tall the space is made for `count` rows of `row_height`: `count * row_height`, at most `most_space`. |
| `scaled : U64, U64 -> Bool` | Whether the list is drawn scaled: its rows together are taller than `most_space`. |
| `most_space : U64` | 10,000,000 pixels. |
| `most_shown : U64` | 4,096 pixels, the most a box is taken to show. |

### Lists taller than a browser allows

Browsers cap how tall an element may be: Firefox at about 17.8 million pixels, Chromium at about
33.5 million. A million rows 36 pixels high are 36 million. So a list taller than 10 million pixels
(`Rows.most_space`) is drawn scaled. Its space is 10 million pixels tall, and each pixel the box
scrolls moves through more than one pixel of rows, so the box's last scroll shows the last row. The
row at the box's top is placed where it should be, and the rendered rows move a little faster than
the scrollbar. Because a scaled list's rows move with every scroll, its view changes with every
scroll too.

## Limits

- Not yet: rows of different heights. Every row is `row_height` high; rows measured as they show
  aren't supported.
- One column of rows. A grid lays out each row itself: `examples/checkboxes` puts a `<Repeat>` of
  boxes in each row, as many as fit the width it hears from `on_view!`.
- A scaled list's scrollbar reaches to within a few rows of any row, not to one exact pixel.

## Tests

- `Rows`' expects: `roc test packages/virtual/main.roc`.
- The platform's `<Repeat>` and `on:viewport`: the scroller test in `web/test/platform.test.mjs`,
  in Chromium. It renders on the server, hydrates, measures, scrolls and resizes, and checks that the
  rows still in range are kept.
- The list in an app: `examples/checkboxes` (a million checkboxes, over HTTP and in Chromium), and
  the docs' demo at `/ecosystem/virtual`, in the site's tests.
