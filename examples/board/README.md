# Board

A live kanban board for a small team, built with Roc Solid. Boards have columns, columns have cards,
and several people work on one board at once: each sees the others' changes as they happen, and who
else is on the board.

Read it to learn how a Roc Solid app does drag and drop with moves shown before the server confirms
them, live updates on a channel, presence, an edit lock on a card kept in the server's memory, and
forms that work with and without JavaScript. Its ranks (below) show one way to keep a list's order
correct when several people move items at once.

## Run it

From the repository's root, after `just setup`:

```sh
cd examples/board && ../../bin/rocx dev
```

Open http://localhost:8080. `rocx dev` builds the app (the server and the browser's half), serves it
under `--dev`, and builds it again each time you save a file.

Run it from the example's directory. The database is SQLite, `database: Sqlite("data/board.db")` in
`main.roc`, and that path is relative to where the server starts, so the file is
`examples/board/data/board.db` (`*.db` is gitignored). The server makes the file, migrates it and
seeds it as it starts. To put it elsewhere, pass a server option after `--`:
`../../bin/rocx dev -- --database-url sqlite:/tmp/board.db`. `rocx dev --port 8081` serves on
another port.

To be two people at once, open the board in a second browser, or in a private window. The tabs of
one browser share their cookies, and so their session, so they are the same person.

`BOARD_LEASE_TTL_MS` sets how long an edit lease lasts without being renewed (30000 ms by default;
the tests make it short): `BOARD_LEASE_TTL_MS=5000 ../../bin/rocx dev`.

### Build it as it would ship

`rocx dev` builds for development. To build the browser's wasm at its smallest and run the server on
its own, from the repository's root (`just web-host` first, if the browser's host isn't built yet):

```sh
bin/rocx generate examples/board --client examples/board/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/board/build/client/static/rocx/app.wasm examples/board/build/client/main.roc
node server/build.mjs examples/board/main.roc examples/board/build/server
cd examples/board && build/server --port 18120 --static build/client/static
```

Then open http://localhost:18120. `node server/build.mjs … --opt=speed` builds an optimized server.

## A tour

1. Open the app and it asks who you are. Pick Ada, Bo or Cyd (the seeded team), or type a new name
   and pick a colour. Your choice is kept as a session on the server (packages/auth), and its
   cookie holds a random token; there are no passwords.
2. The front page lists the boards. "Acme Rocket Launch" is seeded with four columns and ten cards.
   Make another board with the form below the list.
3. On a board, drag a card to another column, or up and down its own. A mouse works, and so does a
   finger on a phone: hold the card a moment, then drag. The card lands at once and glides into
   place. Open the board in a second browser as someone else: the card moves there too, without a
   reload, and a line at the bottom says who moved what.
4. The header shows who else is on the board. Switch away from one browser's tab, and the other
   browser shows you as away. A card that someone has open shows their face, and a card someone is
   editing says "Ada is editing".
5. Click a card's title to open it beside the board. You can change its title, description,
   assignee, due date, labels and checklist (with a progress bar), and move it with buttons instead
   of dragging. If someone else is editing it, you can read it but not change it until they close
   it. Back closes it, and so do Escape and the ✕. Archive it from there; the archive, folded away
   below the columns, brings a card back or deletes it for good.
6. Add a card at the foot of a column, a column at the board's end, and rename a column with its ✎.
7. Turn JavaScript off: every form still works, and a card opens from its address (`?card=12`).

## What it shows

| Feature | Where to look |
|---|---|
| A page that reads an endpoint as it renders, and a 404 page for a board that isn't there. A page's endpoints are under `api/`, at the page's path (`GET /b/launch` is the page, `GET /api/b/launch` the board as JSON): a path is a page or an endpoint, never both | `routes/(members)/b/[board]/+page.rocx` (`board!`, `Missing`), `routes/(members)/api/b/[board]/+server.roc` (`get!`) |
| Drag and drop: tiles are dragged, a whole column is a drop target, and the card lands where the drag last was. Touch works too, with the same markup | `Ui/CardTile.rocx` (`on:dragstart`, `on:dragenter`), `Ui/ColumnView.rocx` (`on:drop`) |
| A move shown before the server has it: the server's board with the moves still on their way applied (`use_action!`, `use_submissions!`), then the board read again | `routes/(members)/b/[board]/+page.rocx` (`board!`), `Board.moved`, `routes/(members)/api/b/[board]/(writes)/move/+server.roc` |
| The board dimmed while it is read again (`is_pending!`) | `routes/(members)/b/[board]/+page.rocx` (`class:stale`) |
| Cards gliding to their new place, between columns too (`transition:move`, with the card's id as the tile's `key`) | `Ui/CardTile.rocx` |
| Lists that change, as rows kept by their `key` (a `.map` in a list hole, each row's root with `key={…}`) | the columns in `routes/(members)/b/[board]/+page.rocx`, the cards in `Ui/ColumnView.rocx`, the labels in `Ui/CardTile.rocx`, the checklist and people in `Ui/CardPanel.rocx`, the archive in `Ui/Archive.rocx` |
| Live updates: the board's channel, published on after every change; each page reads the board again when it hears one | `routes/(members)/api/b/[board]/+server.roc` (`channel!`), `News.roc` (`News.tell!`), the page's `heard!` |
| Presence: who is on the board, which card each person has open (the room's typed `data`, `Board.Viewing`, which the page says with `here.update!`), and who is away (their tab hidden) | `routes/(members)/api/b/[board]/presence/+server.roc` (packages/presence's hooks), the page's `here` (`Presence.join!`, `<Document on:visibilitychange.visible>`), `Ui/Shared.roc` |
| An edit lease on a card, kept in `Kv` with a time to live | `Lease.roc`, `routes/(members)/api/b/[board]/cards/[card]/lease/+server.roc` and `lease/release/`, `Ui/CardPanel.rocx` (`take!`) |
| A card's changes shown before the server has them, as moves are | `Ui/CardPanel.rocx` (`card!`), `Board.saved`, `Board.labelled`, `Board.ticked` |
| Timers and lifecycle in a component: renew every 10 s (`set_interval!`), focus the title once it shows (`on_settled!`, `Browser.focus!`), let the lease go when closed (`on_cleanup!`) | `Ui/CardPanel.rocx` (`Editor`) |
| Keyboard: Alt+↑ and Alt+↓ move the open card, Escape anywhere closes it | `Ui/CardPanel.rocx` (`on:keydown.Alt+ArrowUp`, `<Document on:keydown.Escape>`) |
| The open card in the address: a link opens it in place and adds a history entry, so Back closes it | `routes/(members)/b/[board]/+page.rocx` (`open!`, `use_search_params!`), `Board.card_in_query` |
| Fractional ranks: a move writes one row, and two cards dropped into one gap at once each get a rank of their own (below) | `Rank.roc`, `Board.rank_for`, `Store.move!` |
| The rules both halves share: the order cards show in, where a move puts a card, a move applied to the page's copy, validation | `Board.roc` |
| Middleware by folder: security headers on every request (`routes/+middleware.roc`), a member check around the boards (the `(members)` group, which adds nothing to the paths: the join page and its endpoint sit outside it), and a rate limit on a board's changes (the `(writes)` group inside `api/b/[board]/`: its cards, columns and moves, but not a card's edit lease, which a page renews while it is open; packages/guard); a change sent by another site's page the platform refuses | `Middlewares.roc` (`default`, `member`, `writes`); `routes/+middleware.roc`, `routes/(members)/+middleware.roc` |
| Who you are: a name and a colour, kept as a session by packages/auth's plugin, with none of its sign-in routes (D-116: nobody signs in by a link or a provider). Joining starts it and ends the one the browser had (`Auth.switch!`), `Auth.required_with` reads it and sends a page asked for without one to join, and a channel's check reads it from the stream's cookies | `main.roc` (`Auth.plugin`), `routes/api/join/+server.roc`, `Middlewares.member` |
| SQLite in the server's process: migrations, transactions that take turns, a `json` column, every query in one module | `main.roc`, `migrations/`, `Store.roc` |
| A seed that can run twice: three people and a board that looks lived in | `migrations/0002_seed.sql` |
| Forms that work without JavaScript: each has `method="post"` and an `action`. With JavaScript, each is sent with `fetch` and the page stays: most through an action (`on:submit`), the rest by the runtime, which sends any form to one of the app's endpoints itself (D-095), their answers read with `use_submission!` | every `<form>` |
| Pure and effectful components: `view` for what only shows its props, `view!` for what keeps state | `Ui/Avatar.rocx` (pure); `Ui/ColumnView.rocx`, `Ui/CardTile.rocx`, `Ui/CardPanel.rocx` (effectful) |
| Scoped styles, light and dark | each component's `<style>`; the colour tokens in `routes/+layout.rocx` |

## How the parts fit

The board's page makes the state its parts share once, in `routes/(members)/b/[board]/+page.rocx`, and hands
it to each component as `shared` (`Ui/Shared.roc` says what is in it). Each entry is an accessor or
a setter: `board!` (the board as it shows), `dragging!` and `over!` (the card being dragged and where
it would land), `open!` (the card that is open), `others!` (who else is on the board). A part that
reads one of them is patched when it changes, and only that part.

### Moves before the server has them

`board!` is a memo: the board as the server last sent it (`Endpoint.read!`), with every move still on
its way applied to it (`moves.pending_inputs!().fold(server, Board.moved)`). A drop calls `move!`,
an action that posts the move without the page waiting. The card shows in its new place at once,
stays there while the post is on its way, and the board is read again once the server has it. The
server (`Store.move!`) and the page (`Board.moved`) both work out the card's rank with
`Board.rank_for`, so the two agree on where a card goes.

### Opening a card

The open card is in the address: `?card=12`. A tile's title is a link to it. With JavaScript, the
link opens the card in place and adds a history entry, so Back closes it. Closing it takes `card`
out of the query (`search.set!([("card", "")])`). Without JavaScript, in a new tab, or from a shared
link, the same address loads the page with the card open.

The page renders the panel as a list of at most one row, keyed by the card's id:

```rocx
{...(if (open!().is_empty()) [] else [open!()]).map(|card|
	<CardPanel key={card} card={card} shared={shared} />
)}
```

Because the row's key is the card, opening another card drops the first panel and makes a new one.
The old panel's cleanup lets its lease go. The new one takes its own lease, has its own submissions,
and shows the new card's values, not what you typed into the other.

Inside, the editor reads its card's id once, with `untrack!(|| found!().id)`. Each panel is for one
card, so one read is what is meant, and `untrack!` says so. Without it, `rocx build` would warn:
a component that reads a row's item, or a match arm's value, only once in its body keeps the first
value while the row or arm stays and the value changes. Each column and each archived card reads its
id once in the same way.

### The edit lease

Only one person edits a card at a time. Opening a card asks the server for its lease (`Lease.roc`),
which is kept in `Kv`, the server's in-memory store, with a time to live. While someone else holds
it, the panel is read-only and says who is editing; it takes the lease as soon as the board says it
is free. The open panel renews the lease every 10 seconds and lets it go when it closes. A tab that
vanishes stops renewing, and the lease runs out 30 seconds later.

Each opening of a card has a token of its own (made from the browser's clock once the panel shows),
which it takes and lets go of the lease with. When it lets go, the server remembers that token as
let go for as long as a lease lasts. So a renewal sent just before the card closed, arriving after
the release, takes nothing.

### Ranks, and why they survive concurrent moves

A card's place in its column is a rank: a string of base-36 digits read as a fraction (`"i"` is
18/36), compared byte by byte (SQLite's own binary collation). Moving a card gives it a rank between
its new neighbours' (`Rank.between("i", "j")` is `"ii"`) and writes that one row. Nothing else is
renumbered, so two people moving different cards never write the same rows. There is always room
between two ranks, because ranks never end in `0` (so `"i"` and `"i0"` can't both exist).

What could still go wrong is two cards dropped into the same gap at the same moment: both would get
the rank between the same two neighbours. So the server works the rank out itself, from the board as
it is when the move arrives, inside a transaction (`Store.lock_column!`). On SQLite a transaction
holds the write lock from its start, so moves take turns, and each sees the one before it. A unique
index on `(column_id, rank)` enforces this for anything else that writes cards.

The page sends what was meant, not a rank: `{ card, column, before }`, "just above that card". A
card dropped above one that someone else has just moved away goes to the end of the column, rather
than somewhere stale. Archived cards keep their ranks, and a new rank is made between every card in
the column, archived or not, so a card brought back goes where it was.

The cost: a card dropped at the same place over and over makes its rank one character longer every
five or six moves. Real boards rarely do that. A board that did would need to rewrite a column's
ranks once in a while, which this app doesn't do.

## Test it

From the repository's root:

```sh
just examples board
```

That builds the app, type-checks both programs, lints it, checks its SQL against SQLite
(`rocx check --sql`), runs the `expect`s and the node tests. To run the parts yourself:

```sh
bin/rocx check examples/board                      # build it, type-check both programs; problems at their .rocx lines
.tools/roc-active test examples/board/main.roc     # the expects: ranks, moves, validation (after a build)
node --test 'examples/board/test/*.test.mjs'       # a SQLite file each; the browser test needs Chromium
```

- `Rank.roc` and `Board.roc` have the `expect`s: ranks always between their neighbours and never
  ending in `0`; fifty cards put at a column's top, at its end, or always second, staying in order
  and short; a move applied twice being the same as once; nudges up and down; validation.
- `test/http.test.mjs` talks to the server as a browser does, with JavaScript and without: joining
  (and never being sent to another site after; its session's cookie a token, not an id, and
  joining as someone else ending the session before), the seeded board (running the seed again adds
  nothing), moves and their ranks, ten moves into one gap at once, refused moves, the edit lease
  (taken, refused to someone else, renewed, released, running out, and a late take after a release
  taking nothing), the channel (members hear each change, a visitor is refused), presence (the card
  a page has open is its typed data, kept as its status changes; a status that isn't one of the
  four, or data past a kibibyte, refused), labels, the checklist, archiving and deleting, the forms
  without JavaScript, and the rate limit.
- `test/browser.test.mjs` puts two people in two browsers on one board: Ada in headless Gecko (Zen
  or Firefox) when there is one, Bo in Chromium. It checks that each sees the other; that a card Ada
  drags moves at once on her page and glides on Bo's; that Bo sees which card Ada has open and that
  she is editing it, and gets to edit it once she closes it; that a card saved and closed at once
  stays free even though a renewal was still on its way; that opening a second card gives a panel
  whose lease and save are the second card's; that a third person opening a card updates the tile's
  avatar stack in place; that touch drags work in both engines; and that a hidden tab shows as away.

The test files build the app once between them. Each starts a server of its own on its own SQLite
file.

Why Gecko: headless Chromium never runs CSS transitions, so the glides are checked in Gecko.
Headless Gecko, in turn, never ends a drag that WebDriver's pointer starts (Mozilla's bug 1515879),
so in Gecko packages/testing's `drag` fires the DOM's own drag events, in the browser's order, with
one `DataTransfer` carried through them. In Chromium it is the browser's own drag and drop.

## Product calls

- No passwords. Picking a name makes you that person, in the colour you picked, even if someone has
  the name already. Everyone who has joined may use every board. Who you picked is still a session
  kept on the server (packages/auth), so the cookie holds a random token, not an id anyone could
  change by hand. It lasts a year, and joining as someone else ends it.
- The edit lease belongs to a person, not a tab: Ada in two tabs can edit in both. It covers the
  card's details, not where the card is, so moving a card someone is editing is allowed.
- A browser without JavaScript never holds a lease. It may change a card unless someone else is
  editing it.
- A card is archived before it can be deleted. Two steps, so a slip loses nothing.
- The last column is where finished work goes: its cards are never overdue.
- Which cards are overdue is decided by the server's date (`today` in the board's data), not the
  browser's, so the page the server renders and the page in the browser agree, even at midnight or
  on a phone whose clock is wrong.
- Writes to a board are limited to a burst of 60 and then one a second for each person. Reading,
  presence and leases aren't counted.
- The header's avatars are the other people on the board; you are the chip beside them.

## What it asked of the platform

The board was built while Roc Solid was young, and it met many gaps on the way. Each has been fixed
in the platform or in rocx since, and the app uses the fix:

- A module below the routes can publish on a route's channel: `News.tell!` publishes on
  `Api.channel_api_b_board`, typed, because `Generated/Api` is the app's contract and imports no route
  file (D-037 in DECISIONS.md).
- Packages bring their own server code: `Middlewares.roc` imports `guard.Guard` and the presence
  route `presence.PresenceServer`, with nothing copied into the app.
- Presence runs on a channel, so a page holds one stream for the board's news and its presence room.
- A page says its presence's typed `data` (`here.update!`), so the card a person has open is
  `Board.Viewing`, and their status stays `Online` or `Away`: it was a status word (`card-12`) once,
  which the tiles had to hide.
- Key handlers can require modifier keys (`on:keydown.Alt+ArrowUp`).
- Client-side navigation: a card's link opens it in place, and Back closes it.
- Focus can be moved from Roc (`Browser.focus!`).
- The browser has a clock (`Time.now_millis!`, `Time.now_nanos!`), which the lease token uses.
- A component's value props are getters, so the tile's avatar stack keeps its place while who has
  the card open changes, and only its label is patched.
- A card gliding out of one column's scrolling list into another's is lifted above the page for its
  glide, so it isn't clipped and the columns can scroll on their own.

Still worth knowing, when you write Roc like this:

- `has` is a keyword in Roc, so a SQL column alias called `has` doesn't parse as a record field.
- `{ me }` alone is a block, not a record. Write `{ me: me }`.
