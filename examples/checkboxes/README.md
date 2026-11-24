# Million: a million checkboxes, shared live

A page of a million checkboxes, shared by everyone who has it open. Check a box, and within a moment
it is checked in every other open page too. Above the grid, the page shows how many boxes are
checked, how many pages are open, and a dot that says whether the page is live.

A million checkboxes would be a million elements, more than a browser wants to hold. So the page
renders only the rows that show (about a thousand boxes on a laptop's screen) and makes the next
rows as you scroll to them. The server keeps the boxes in its memory, with no database, so a restart
clears them.

Read it to learn how to render a huge list with packages/virtual (`<VirtualList>`, built on the
platform's `<Repeat>` and `on:viewport`), how to keep shared state in the server's memory (`Kv`)
with a compare-and-swap, and how a channel can send only the latest version of each piece of state.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/checkboxes && ../../bin/rocx dev
```

Open http://localhost:8080 in two windows side by side. `rocx dev` builds the app (the server and
the browser's half), serves it under `--dev` along with the app's `static/` (its stylesheet), and
builds it again each time you save a file. The app has no database, so it doesn't matter where you
start it from; `../../bin/rocx dev examples/checkboxes` from the root works too.

### Build it as it would ship

`rocx dev` builds for development. To build the browser's wasm at its smallest and run the server on
its own, from the repository's root (`just web-host` first, if the browser's host isn't built yet):

```sh
bin/rocx build examples/checkboxes --client examples/checkboxes/build/client
.tools/roc-active build --target=wasm32 --opt=size \
  --output=examples/checkboxes/build/client/static/rocx/app.wasm examples/checkboxes/build/client/main.roc
node server/build.mjs examples/checkboxes/main.roc examples/checkboxes/build/million
cd examples/checkboxes && build/million --port 18160 --static build/client/static --static static
```

Then open http://localhost:18160.

## A tour

1. Open the page in two windows. Each shows the grid, the count of checked boxes, the number of
   pages online (two), and "Live".
2. Check a box in one window. It shows checked at once there, and within a moment in the other
   window, and both counts go up.
3. Scroll far down the grid. Each row starts with the number of its first box; new rows appear as
   you scroll, and the rows you left are dropped from the page.
4. Make the window narrower: each row holds fewer boxes (8 to 64, as many as fit), so there are more
   rows.

## How it works

- **The page** (`routes/+page.rocx`) reads `GET /boxes` as the server renders it, so its first rows
  come in its HTML with the boxes already checked. Then it subscribes to the boxes' channel.
- **The grid** is a `<VirtualList>` (packages/virtual): as many rows as a million boxes take, 28
  pixels each, of which it renders only those that show and four more on each side. A row's boxes
  are a `<Repeat>`, as many as fit the list's width beside the row's number (`Grid.columns`: 8 to
  64). The page learns the width from the list (`on_view!`).
- **Checking a box** shows it at once (`Grid.toggled`) and tells the server on the channel
  (`Endpoint.say!`). The server writes the box's chunk again and sends every page the chunk. The
  page takes the server's version when it comes.
- **The boxes** are a thousand chunks of a thousand (`Grid.roc`): 125 bytes each, sent as hex, and
  `""` for a chunk with none checked. Each chunk has a version that goes up with each change. A page
  that hears a chunk takes it only if it is newer than the one it has, so a box never goes back.
- **The server** keeps each chunk under a key of its own in `Kv` (`Store.roc`), with its version
  beside it. A box is written with a compare-and-swap (`Kv.swap!`): read the chunk, set the bit, and
  swap it in only if the chunk is still what was read. If another write came first, read it again
  and retry. Two boxes in different chunks never wait on each other.
- **The channel** (`routes/boxes/+server.roc`) is public. Each chunk that changes is published
  latest-first (`Endpoint.publish_latest!`, keyed by the chunk), so a page that falls behind gets
  the newest version of each chunk, not every change in between. The channel's hooks count the
  pages open (`Kv.increment!`) and tell everyone.

## What it shows

| Feature | Where to look |
|---|---|
| A virtual list: only the rows that show, of 25,000 (at 40 boxes a row) | `<VirtualList>` in `routes/+page.rocx`, from packages/virtual |
| `<Repeat>`: rows by index, with no list behind them, each kept while its index is in range | each row's boxes in `routes/+page.rocx`; the list's own rows in `packages/virtual/components/VirtualList.rocx` |
| `on:viewport`: what of an element shows (its scroll position and size) | inside `<VirtualList>`; the page hears it as `on_view!` |
| A grid laid out by the list's width | `Grid.columns`, `Grid.rows`, `Grid.in_row` |
| A page's first rows in its HTML, from an endpoint read where it renders | `Endpoint.get!(Api.get_boxes({}))` in `routes/+page.rocx` |
| A channel with hooks: pages say which box they checked, chunks are published latest-first, the pages open are counted | `routes/boxes/+server.roc`, `Store.roc` |
| Shared state with no database: `Kv`, a compare-and-swap, a counter | `Store.roc` |
| Optimistic updates that the server's version replaces | `Grid.toggled`, `Grid.heard`, `Grid.merged` |
| A signal written only when what it holds changes | the page's `on_view!` |

## Test it

From the repository's root:

```sh
just examples checkboxes
```

That builds the app, type-checks both programs, lints it, runs the `expect`s and the node tests. To
run the parts yourself:

```sh
bin/rocx fmt --check examples/checkboxes
bin/rocx check examples/checkboxes   # build it, type-check both programs; problems at their .rocx lines
bin/rocx check -- .tools/roc-active test examples/checkboxes/main.roc   # the expects: the grid's bits, versions, layout
node --test 'examples/checkboxes/test/*.test.mjs'                        # over HTTP and the channel, and in Chromium
```

- **`expect`s** in `Grid.roc`: a chunk's hex both ways, a bit set and cleared, a chunk taken only
  when newer, a box checked here then replaced by the server's version, a snapshot read again and
  merged with what was heard, the count, and the layout (columns by width, rows, the last row's
  boxes).
- **`test/http.test.mjs`** builds the app, starts it, and talks to it as a page does: the page
  rendered on the server with its first 33 rows of 40 boxes, none checked; a box said on the
  channel, every subscriber told its chunk one version on, and `GET /boxes` with it; the same box
  said again changing nothing; unchecked as the next version; a box that isn't there refused; the
  pages open counted and told; and two hundred boxes of one chunk said at once from four tabs, none
  lost.
- **`test/browser.test.mjs`**, in Chromium (skipped without it), hydrating strictly: two tabs; a box
  checked in one shows in the other and both count it; half a million boxes down, the rows there
  are made as the grid scrolls, the first rows are gone, and the page never holds more than the
  rows that show; a box checked there is checked in the other tab when it scrolls there too;
  unchecked, the count follows.

## How fast

Measured in Chromium at 1920 by 1080 (2,560 boxes on the page) when the app was built, each flush
timed: a change heard from the server takes about 2.5 ms to show, a scroll of five rows about
8.5 ms, and a click about 3.5 ms.

## What it asked of the platform

Built in the platform for this app:

1. **A way to render a range of rows.** A list's rows are made from a list value, and a million rows
   would mean a million-item list, walked on every change. The platform now has `<Repeat count!
   from!>` (Solid 2.0's): rows by index, each kept while its index is in the range.
2. **A way to know what of a box shows.** A handler used to get one string, the target's value: no
   scroll position, no size. The platform now has `on:viewport`, which hands a record of `top`,
   `left`, `width` and `height` on mount, on scroll and on resize, at most once a frame.
3. **A flush that scales.** A thousand boxes reading one signal put a thousand computations in the
   flush, which sorted them all to take each one: a scroll step took 170 ms. The flush uses a heap
   now, and the same step takes about 8 ms.
4. **A virtual list**, made of the two above, as a package: packages/virtual.

Still open:

5. **Writing a signal runs its readers even when nothing changed**, because a setter can't compare
   Roc values. The page once wrote the column count on every scroll, which re-ran every box's holes.
   It now writes it only when it changes, and `<VirtualList>` writes its own view only when the rows
   change. Wanted: a signal that compares values that can be compared (`Str`, numbers, records of
   them).
6. **Kv's compare-and-swap can starve a writer under contention.** Four tabs writing one chunk lost
   a box now and then after fifty tries. The app works around it: after three lost tries a write
   waits a millisecond before each next try, and it gives up (and logs a warning) after a thousand.
