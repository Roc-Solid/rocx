# virtual

A list of any length that renders only the rows that show. A thousand rows or a million cost the
page the same: the rows in its box, and four more each side. As the box scrolls, rows that come into
view are made, rows that leave go, and the others stay as they are.

It is a component made of two things the platform has: `<Repeat>`, which renders a range of rows
by index and keeps a row while its index is in the range, and `on:viewport`, which tells a handler
what of an element shows. Nothing in it needs the host, so it is a package, not the platform's.

## Installing

Name it in the app's header, then import what you use:

```roc
app [program] { pf: platform "../server/platform/main.roc", virtual: "../packages/virtual/main.roc" }
```

```roc
import virtual.VirtualList
```

`rocx build` copies `components/VirtualList.rocx` into the app (`Generated/virtual/`), since a
package can't import a platform's `Html` for the server and the browser at once.

## Using it

```rocx
<VirtualList count={rows!()} row_height={28} class="grid" label="Boxes">
	{|row| <Row index={row} />}
</VirtualList>
```

| Prop | What |
|---|---|
| `count` | How many rows. A getter, as every value prop is: the list follows it. |
| `row_height` | Each row's height, in pixels. Every row is this high. |
| `overscan` | Rows rendered beyond those that show, each side. 4 unless it says. |
| `first_height` | The height the list renders rows for before it is measured, in pixels: on the server, and until the page has hydrated. 800 unless it says. |
| `class` | Classes for the box, beside `virtual-list`. |
| `label` | The box's `aria-label`, if it has one. |
| `on_view!` | Hears each measure (`Html.Viewport`: `top`, `left`, `width`, `height`): the box's width, say, to lay rows out by. |
| the child | `{|index| …}`: a row, given its index. It runs when the row is made, as a component does. |

The box is the component's own `<div>`, which scrolls (`overflow-y: auto`): **give it a height**, by
its class. A box with none grows as high as all its rows, and doesn't scroll; the list then renders
the rows of its first 4,096 pixels (`Rows.most_shown`) and leaves the rest blank, rather than render
every row. Inside it, one `<div>` as high as every row together (`count * row_height` pixels, up
to 10 million: see below) holds the rows that are rendered, moved down to where they go.

### What the server renders

The server can't measure, so the list renders the rows its first `first_height` pixels would show,
and the browser renders the same rows as it hydrates. Then `on:viewport` measures the box, and the
rows that really show replace them.

### Writing signals from `on_view!`

`on_view!` hears every scroll, and a signal's setter can't compare Roc values: every write runs what
reads the signal, a change or not. So write a signal from it only when what you take from the view
changes:

```roc
on_view!={|view| if (Grid.columns(view.width) != columns!()) set_columns!(Grid.columns(view.width)) else {}}
```

The list itself does the same: it writes its own view only when the range of rows changes.

## Rows

`Rows` is the arithmetic, plain Roc on no platform:

- `Rows.shown({ count, row_height, top, height, overscan })` is the range a box scrolled `top`
  pixels down, `height` pixels high, renders, `{ first, end, offset }`: rows `first` up to, not
  including, `end`, the first of them `offset` pixels down the box's space.
- `Rows.space(count, row_height)` is how high that space is made, and `Rows.scaled` whether the
  list is drawn scaled.

### Lists higher than a browser allows

Browsers cap how high an element may be: Firefox at about 17.8 million pixels, Chromium at about
33.5 million. A million rows 36 pixels high are 36 million. So a list higher than 10 million pixels
(`Rows.most_space`) is drawn scaled: its space is 10 million pixels high, and each pixel the box
scrolls moves through more of the rows than one, so the box's last scroll shows the last row. The
rows that show are placed so that the one at the box's top is where it should be, and they move as
the box scrolls, a little faster than the scrollbar.

## Limits

- Every row is `row_height` high. Rows of their own heights, measured as they show, aren't there yet.
- One column of rows. A grid lays its rows out itself: examples/checkboxes renders as many boxes in a
  row as fit the list's width, which it hears from `on_view!`.
- A scaled list (above) can't be scrolled to one exact pixel of its rows by its scrollbar, only to
  within a few rows of it.

## Tested

- `Rows`' expects (`roc test packages/virtual/main.roc`).
- The platform's `<Repeat>` and `on:viewport`: web/test/platform.test.mjs's scroller, in Chromium:
  rendered on the server, hydrated, measured, scrolled and resized, the rows still in range kept.
- The list in an app: examples/checkboxes, a million checkboxes, over HTTP and in Chromium; and the
  docs' demo, /ecosystem/virtual, in the site's tests.
