# Million: a million checkboxes, shared live

A page of a million checkboxes, and everyone who has it open shares them. Check a box, and within a
moment it is checked in every other open page too. Above the grid, how many boxes are checked and
how many pages are open, with a dot that says the page is live.

A million checkboxes would be a million elements, more than a browser wants to hold. The page holds
only the rows that show, about a thousand boxes on a laptop's screen, and makes the next rows as
the grid scrolls to them. The boxes are kept in the server's memory: no database, so a restart
clears them.

## A tour

- **The page** (`routes/+page.rocx`) reads `GET /boxes` as the server renders it, so its first
  rows come in its HTML with the boxes already checked, and then subscribes to the boxes' channel.
- **The grid** is a `<VirtualList>` (packages/virtual): as many rows as a million boxes take, 28
  pixels each, of which it renders only those that show and four more each side. A row's boxes are a
  `<Repeat>`, as many as fit the list's width beside the row's number (`Grid.columns`: 8 to 64), which
  the page hears from the list (`on_view!`). A narrow window has fewer boxes a row and more rows.
- **Checking a box** shows it at once (`Grid.toggled`) and says so on the channel
  (`Endpoint.say!`). The server writes the box's chunk again and sends every page the chunk; the
  page takes the server's version when it comes.
- **The boxes** are a thousand chunks of a thousand (`Grid.roc`): 125 bytes each, kept as hex, and
  "" for a chunk with none checked. Each chunk has a version that goes up with each change, so a page
  that hears a chunk takes it only if it is newer than the one it has, and a box never goes back.
- **The server** keeps each chunk under a key of its own in `Kv` (`Store.roc`), its version beside
  it. A box is written with a compare-and-swap: read the chunk, set the bit, and swap it in only if
  the chunk is still what was read; if another write came first, read it again. Two boxes in
  different chunks never wait on each other. After three lost tries a write waits a millisecond, so
  one that the others keep beating isn't starved.
- **The channel** (`routes/boxes/+server.roc`) is public. Each chunk that changes is published
  latest-first (`Endpoint.publish_latest!`, keyed by the chunk), so a page that falls behind gets
  the newest version of each chunk, not every change in between. Its hooks count the pages open
  (`Kv.increment!`) and tell everyone.

## What it shows

| What | Where |
|---|---|
| A virtual list: only the rows that show, of 25,000 | `<VirtualList>` in `routes/+page.rocx`, from `packages/virtual` |
| `<Repeat>`: a range of rows by index | each row's boxes in `routes/+page.rocx`; the list's rows |
| `on:viewport`: what of an element shows | inside `<VirtualList>`; the page hears it as `on_view!` |
| A grid laid out by the list's width | `Grid.columns`, `Grid.rows`, `Grid.in_row` |
| A page's first rows in its HTML, from an endpoint read where it renders | `Endpoint.get!(Api.get_boxes({}))` |
| A channel with hooks: say, publish latest-first, count who is open | `routes/boxes/+server.roc`, `Store.roc` |
| Shared state with no database: `Kv`, a compare-and-swap, counters | `Store.roc` |
| Optimistic updates the server's version replaces | `Grid.toggled`, `Grid.heard`, `Grid.merged` |
| A signal written only when what it holds changes | the page's `on_view!` |

## Build and run it

You need the repository's toolchain (`just setup`), and nothing else. From the repository's root,
on port 18160:

```sh
bin/rocx build examples/checkboxes --client examples/checkboxes/build/client  # bin/rocx: any repo script builds it
.tools/roc-active build --target=wasm32 --opt=size \
  --output=examples/checkboxes/build/client/static/rocx/app.wasm examples/checkboxes/build/client/main.roc
node server/build.mjs examples/checkboxes/main.roc examples/checkboxes/build/million
cd examples/checkboxes && build/million --port 18160 --static build/client/static --static static
```

Then http://localhost:18160, in two windows side by side.

## Test it

```sh
bin/rocx fmt --check examples/checkboxes
bin/rocx check -- .tools/roc-active test examples/checkboxes/main.roc   # the expects: the grid's bits, versions, layout
node --test 'examples/checkboxes/test/*.test.mjs'                        # over HTTP and the channel, and in Chromium
```

- **`expect`s** in `Grid.roc`: a chunk's hex both ways, a bit set and cleared, a chunk taken only when
  newer, a box checked here then replaced by the server's version, a snapshot read again and merged
  with what was heard, the count, and the layout (columns by width, rows, the last row's boxes).
- **`test/http.test.mjs`** builds the app, starts it, and asks it as a page does: the page rendered
  on the server with its first 33 rows of 40 boxes, none checked; a box said on the channel, every
  subscriber told its chunk one version on, `GET /boxes` with it, the same box said again changing
  nothing, unchecked as the next version, and a box that isn't there refused; the pages open counted
  and told; and two hundred boxes of one chunk said at once from four tabs, none lost.
- **`test/browser.test.mjs`**, in Chromium (skipped without it), hydrating strictly: two tabs, a box
  checked in one shows in the other and both count it; half a million boxes down, the rows there are
  made as the grid scrolls, the first rows gone and the page never holding more than the rows that
  show; a box checked there is checked in the other tab when it scrolls there too; unchecked, the
  count follows.

## How fast

Measured in Chromium at 1920 by 1080 (2,560 boxes on the page), each flush timed: a change heard
from the server takes about 2.5 ms to show, a scroll of five rows about 8.5 ms, and a click about
3.5 ms.

## What it asked of the platform

1. **A way to render a range of rows.** `<For>` takes a list and walks all of it on every change,
   which a million rows can't be. Fixed in the platform: `<Repeat count! from!>`, Solid 2.0's, rows by
   index, kept while their index is in the range.
2. **A way to know what of a box shows.** A handler was given one string, the target's value: no
   scroll position, no size. Fixed in the platform: `on:viewport`, a record of `top`, `left`, `width`
   and `height`, on mount, scroll and resize, once a frame at most.
3. **A flush that scales.** A thousand boxes reading one signal put a thousand computations in the
   flush, and it sorted them all to take each: a scroll step was 170 ms. Fixed in the platform: a
   heap, so it is 8 ms.
4. **A virtual list.** Made of the two above, as a package: `packages/virtual`.
5. **Writing a signal runs its readers even when nothing changed** (a setter can't compare Roc values).
   The page wrote the column count on every scroll, which re-ran every box's holes. The page now
   writes it only when it changes, and `<VirtualList>` writes its own view only when the rows change.
   Open: a signal that compares values that can be compared (`Str`, numbers, records of them).
6. **Kv's compare-and-swap starves a writer under contention.** Four tabs writing one chunk lost a
   box now and then after fifty tries. Worked around here: wait a millisecond after three lost tries,
   and try up to a thousand times.
