# Board

A live kanban board for a small team, in Roc Solid. Boards have columns, columns have cards, and
several people work on one board at once: each sees the others' changes as they happen.

## A tour

1. Open the app and you are asked who you are: pick Ada, Bo or Cyd (the seeded team), or type a
   new name and pick a colour. That's a cookie; there are no passwords.
2. The front page lists the boards. "Acme Rocket Launch" is seeded with four columns and ten cards;
   make another with the form below it.
3. On a board, drag a card to another column, or up and down its own, with a mouse, or on a phone
   with a finger (hold it a moment, then drag: D-055). It lands at once, and glides there. Open the
   board in a second browser as someone else: the card moves there too, without a reload, and a line
   at the bottom says who moved what; switch away from one browser's tab, and the other shows you
   away.
4. The header shows who else is on the board. A card someone has open shows their face; a card
   someone is editing says "Ada is editing".
5. Click a card's title to open it beside the board: its title, description, assignee, due date,
   labels and checklist (with a progress bar), and buttons that move it without dragging. If someone
   else has it open, you can read it but not change it, until they close it. Archive it from there;
   the archive, folded away below the columns, brings it back or deletes it for good.
6. Add a card at the foot of a column, a column at the board's end, and rename a column with its ✎.
7. Turn JavaScript off: every form still works, and a card opens from its address (`?card=12`).

## What it shows

| Feature | Where |
|---|---|
| Fractional ranks: a move writes one row, and two cards dropped in one gap at once each get a rank of their own (below) | `Rank.roc` (with its `expect`s), `Board.rank_for`, `Store.move!` |
| The rules both halves share: the order cards show in, where a move puts a card, a move applied to the page's copy, validation | `Board.roc` |
| Drag and drop (D-029): tiles are dragged, a column is a drop target, the drop lands where the drag last was; by touch too (D-055), with no change to the markup | `Ui/CardTile.rocx`, `Ui/ColumnView.rocx` |
| A move shown before the server has it, kept while it is on its way (`use_action!`, `use_submissions!`, D-030), and the board read again after | `routes/b/[board]/+page.rocx` (`board!`), `routes/b/[board]/move/+server.roc` |
| Cards glide to their new place, between columns too (`transition:move` and `key`, D-031) | `Ui/CardTile.rocx` |
| Everyone sees each change live: the board's channel (D-020), published after every change | `routes/b/[board]/+server.roc` (`channel!`), `News.roc`, the page's `heard!` |
| Presence: who is on the board, who has which card open, and who is away (their tab hidden: `<Document on:visibilitychange.visible>`) (packages/presence, on a channel) | `routes/b/[board]/presence/+server.roc` (the package's hooks), the page's `here` (`Presence.join!`), `Ui/Shared.roc` |
| An edit lease on a card, in `Kv` with a time to live (D-028), taken and let go with a token of each opening of the card, so a late take can't outlive a close | `Lease.roc`, `routes/b/[board]/cards/[card]/lease/` (`+server.roc`, `release/`), `Ui/CardPanel.rocx` (`take!`) |
| Changes shown before the server has them in the open card (labels, ticks, its fields), as moves are | `Ui/CardPanel.rocx` (`card!`), `Board.saved`, `Board.labelled`, `Board.ticked` |
| Rate limits on writes (packages/guard) and security headers | `Middlewares.roc` (`writer`, `default`) |
| Who you are: a name and a colour in a cookie; members only | `routes/join/`, `Middlewares.member` |
| SQLite in the server's process (`database: Sqlite("data/board.db")`, D-045): migrations, transactions that take turns, a `json` column, every query in one module | `main.roc`, `migrations/`, `Store.roc` |
| An idempotent seed: three people and a board that looks lived in | `migrations/0002_seed.sql` |
| Forms without JavaScript, and the same forms sent by the page with it | every `<form>`: `method="post"` and an `on:submit` |
| Pure and effectful components: `view` for what only shows its props, `view!` for what keeps state | `Ui/Avatar.rocx` (pure); `Ui/ColumnView.rocx`, `Ui/CardPanel.rocx` (effectful) |
| Scoped styles and a design of its own, light and dark | each component's `<style>`; the tokens in `routes/+layout.rocx` |
| A page for a board that isn't there (404) | `Missing` in `routes/b/[board]/+page.rocx` |

### Ranks, and why they survive concurrent moves

A card's place in its column is a rank: a string of base-36 digits read as a fraction (`"i"` is
18/36), compared byte by byte (SQLite's own collation, binary). Moving a card gives it a rank between
its new neighbours' (`Rank.between("i", "j")` is `"ii"`), and writes that one row. Nothing else is
renumbered, so two people moving different cards never write the same rows, and there is always
room between two ranks (ranks never end in `0`, so `"i"` and `"i0"` can't both exist).

What could still go wrong is two cards dropped into the same gap at the same moment: both would get
the rank between the same two neighbours. So the server works the rank out itself, from the board as
it is when the move arrives, inside a transaction (`Store.lock_column!`), which on SQLite holds the
write lock from its start: moves take turns, and each sees the one before it.
A unique index on `(column_id, rank)` says so to anything else that writes cards. The page sends what
was meant (`{ card, column, before }`: "just above that card"), not a rank, so a card dropped above
one that someone else has just moved away goes to the end of the column, rather than somewhere
stale. Archived cards keep their ranks, and a new rank is made between every card in the column,
archived or not, so bringing one back puts it where it was.

The cost: a card dropped at the same place over and over makes its rank a character longer every
five or six moves. Real boards don't do that much; a board that did would rewrite a column's ranks
once in a while (not done here).

## Build and run

The toolchain once (`just setup`), and the platforms' hosts (`just test` builds both). Nothing
else: the board is a SQLite file, `data/board.db` from where the server starts
(`--database-url sqlite:<path>` puts it elsewhere). From the repository's root:

```sh
bin/rocx build examples/board --client examples/board/build/client
.tools/roc-active build --target=wasm32 --opt=size --output=examples/board/build/client/static/rocx/app.wasm examples/board/build/client/main.roc
node server/build.mjs examples/board/main.roc examples/board/build/server
cd examples/board && build/server --port 18120 --static build/client/static
```

Then open http://localhost:18120. The server makes the file, and migrates and seeds it, as it
starts. Open it
in a second browser (or a private window: one browser's tabs share their cookies, so they are one
person) to be two people at once.

`BOARD_LEASE_TTL_MS` sets how long an edit lease lasts unrenewed (30000; the tests make it short).

## Test

```sh
.tools/roc-active test examples/board/main.roc     # the expects: ranks, moves, validation
node --test 'examples/board/test/*.test.mjs'       # a SQLite file each; the browser test needs Chromium
```

- `Rank.roc` and `Board.roc` have the `expect`s: ranks always between their neighbours and never
  ending in `0`, fifty cards put at a column's top, end or always second staying in order and short,
  moves applied twice being moves applied once, nudges up and down, validation.
- `test/http.test.mjs` asks the server as a browser does, with JavaScript and without: joining (and
  never being sent to another site after), the seeded board (and the seed run again adding nothing),
  moves and their ranks (between neighbours, at either end, before a card that has moved away, one
  row written), ten moves into one gap at once, refused moves, the edit lease (taken, refused to
  someone else, renewed, released, and running out; a take its card sent before it closed, arriving
  after the release, takes nothing, and the next opening takes it), the channel (a member hears
  each change, a visitor is refused), labels, the checklist, archiving and deleting, the forms
  without JavaScript, and the rate limit.
- `test/browser.test.mjs`: two people in two browsers on one board, Ada in headless Gecko (Zen or
  Firefox) when there is one and Bo in Chromium. Each sees the other, the board's channel and its
  presence room on one stream; Ada drags a card to another column, it shows there at once for her
  and moves on Bo's page (gliding on both) without a reload; Ada opens a card, Bo's board shows she
  has it open and is editing it, Bo opens it read-only, it opens for him when she closes it, and his
  edit shows on her board; Bo, then Ada, saves a card and closes it at once while the renewal the
  save made is held back on its way, and the other sees the card free, and it stays free; a third
  person comes, and once their browser closes and the grace is up, leaves everyone's stack; Bo
  drags a card to another column by touch (Chromium) and Ada another (Gecko when there is one), real
  touch input through packages/testing's `touchDrag`; Bo's tab hidden shows him away on Ada's page.

The test files build the app once between them, each with a SQLite file and a server of its own.

**In a Firefox-based browser.** Headless Chromium never runs CSS transitions, so Ada's half of the
browser test runs in headless Gecko (Zen, or Firefox) when there is one, over WebDriver BiDi
(packages/testing's `launchBrowser({ engine: "gecko" })`), with Bo in Chromium: Zen's page hydrates
with no warnings, Ada's drag shows the card in its new column at once and it glides there, and Bo
sees it moved. Headless Gecko never ends a drag that WebDriver's pointer starts (no `drop`, no
`dragend`; neither pointer-up nor Escape reaches its drag session, and no pref or pacing of the
actions changes that: Mozilla's bug 1515879), so packages/testing's `drag` makes a drag in Gecko of
the DOM's own drag events, in the browser's order, with one `DataTransfer` carried through them; in
Chromium it is the browser's own drag and drop. Fixed: the test used to drag with the DevTools
protocol alone, and the Zen check was a script of its own. Frames Zen took showed one real glitch
Chromium couldn't: a card gliding into another column was invisible on its way, clipped by the
column's card list, which was a scroll box. The platform lifts such a glide above the page since,
so a column's cards scroll on their own again and the card is seen all the way.

## Product calls

- No passwords: picking a name is being that person, and picking a name someone has makes you them,
  in the colour you picked. Everyone who has joined may use every board.
- The edit lease is a person's, not a tab's: Ada in two tabs edits in both. It covers the card's
  details, not where it is: moving a card someone is editing is allowed. Opening a card takes it
  (when free); the open card renews it every 10 s and lets it go when closed; a tab that vanishes
  stops renewing, and the lease runs out 30 s later. Someone waiting with the card open gets it as
  soon as the board says it is free, or at their next renewal once it has run out. A card closed
  lets its lease go for good, though a renewal it sent (the board read again after a save) reaches
  the server after: each opening takes and lets go with a token of its own, and the server keeps
  the lease marked as let go by it for as long as a lease lasts.
- A browser without JavaScript never holds a lease: it may change a card unless someone else is
  editing it.
- A card is archived before it can be deleted: two steps, so a slip loses nothing.
- The last column is where finished work goes: its cards are never overdue.
- Writes to a board are limited to 60 at once and then one a second for each person; reading,
  presence and leases aren't counted.
- The header's avatars are the others on the board; you are the chip beside them.

## What it asked of the platform

What the app met, and how it works around each:

- **Packages' server modules were copied in by hand.** packages/presence's room (`PresenceServer`)
  imported the server platform and kept its state in an actor, whose kind `rocx build` finds only in
  the app's own files, so the file was copied into the app, with a test failing when it drifted.
  (Fixed since: guard keeps its state in `Kv` and names the server platform itself, D-043, and so
  does presence, on a channel; the header names both, and the routes import `guard.Guard` and
  `presence.PresenceServer`. No copies are left.)
- **A handler can't name another route's channel.** Every write publishes on the board's channel,
  but route files can't import `Generated/Api` (it is made of them). (Fixed in the platform since:
  `Generated/Api` is the app's contract and imports no route file, D-037; `News.tell!` publishes on
  `Api.channel_b_board({ board })`, and `CardPanel`'s submissions are typed by it in both copies.)
  The workaround was `News.channel`, which built the same endpoint by its path,
  `Endpoint.remote("CHANNEL", "/b/<board>")`, so moving the channel's route meant changing it there too.
- **An import a doc comment mentions stays in the browser's copy.** The front page's `##` comment
  named `Middlewares.member`; the browser's copy then kept `import ../Middlewares` (which reaches
  `pf.Actor` through Guard), and `rocx build` warned that the browser's build couldn't compile it.
  Workaround: the comment says "its middleware". (Fixed in rocx since: what a comment or a string
  says doesn't keep an import in the browser's copy.)
- **Key handlers saw only `event.key`, no modifier keys,** so there was no Alt+↑ to move a card from
  the keyboard. An open card has Up, Down and "To the end of" buttons, which are forms, so they work
  without JavaScript, by keyboard and on touch screens (which started no drag in many mobile
  browsers; since D-055 a held finger drags, in every browser).
  (Fixed in the platform since: `on:keydown.Alt+ArrowUp` runs with exactly Alt held, so the open
  card takes Alt+↑ and Alt+↓ too.)
- **No client-side navigation.** Opening a card in place doesn't change the address, and Back
  doesn't close it. Workaround: a card's link is `?card=12`, which a click opens in place
  (`on:click.prevent`) and a new tab, a shared link or a browser without JavaScript open as a page.
- **No way to move focus from Roc.** An open card didn't take the keyboard's focus (there was no
  focus effect, and `Browser.call!` needs a script of the page's own, which this app doesn't serve),
  so keyboard users tabbed to it. (Fixed in the platform since: `Browser.focus!(id)`, so a card that
  opens focuses its title, from the `on_settled!` that starts renewing its lease. And Escape closes
  it from anywhere on the page, not only from inside it: `<Document on:keydown.Escape={close!} />`
  in the panel, while it is open.)
- **Presence wasn't on channels**: its glue was an event stream per tab beside `/rocx/live`, a beat
  posted every 15 s, and a post when a card opened, three routes. (Fixed since: presence runs on a
  channel, its hooks the package's, so the page holds one stream, and what it says, its beat and the
  card it has open, goes over it.)
- **The browser had no clock.** The board's data carries the server's date (`today`), which says
  which cards are overdue. (The platform has one since, `Time.now_millis!`, for handlers and
  effects; `today` stays the server's, since it decides what the page shows, and the browser's own
  date would make a page that differs from the server's at midnight, or on a phone whose clock is
  off.)
- **A value prop was read once outside a hole**, which was easy to miss: the tile's "Ada has this
  card open" label, a plain `label` prop of `<AvatarStack>` inside a `<Show>`, was made once, empty,
  and never changed. The workaround rendered the stack in a hole, made anew when who has the card
  open changed. (Fixed in the platform since: a value prop is a getter, as Solid's are (D-039). The
  stack is in the tile's markup again with a plain `label`, kept while who has the card open
  changes, its label patched; the browser test checks it with a third person opening the card.)
- **A glide was clipped by a box that scrolls** (D-031's own limit): seen in Zen as cards vanishing
  on their way into another column, so columns didn't scroll on their own. (Fixed in the platform
  since: one gliding out of a box that scrolls into another glides above the page, lifted out of
  both, so a column's cards scroll again, its name and add form kept in sight.)
- **Fixed: under `--dev`, Firefox reported the dev server's inline reload script** against
  packages/guard's CSP (report-only under `--dev`, so nothing broke): a console error on every page.
  The script is a file of the site's own now (`/__reload.js`), which `script-src 'self'` allows; in
  headless Zen the board's pages report nothing.
- **Roc on the way:** `has` is a keyword (a SQL column alias called `has` didn't parse as a record
  field); `{ me }` alone is a block, not a record (`{ me: me }`); whitespace at the end of an
  element's text went, so `<span>You are </span>` lost its space (`{"You are "}` keeps it; fixed in
  rocx since: a space on the tag's line stays); and in
  the browser's copy every endpoint read and submission list needed its type written down
  (`moves : Submissions(Board.Move, Str)`, `home! : {} => …`), as D-030 said (fixed in the platform
  since: the browser's copy of `Api` has each endpoint's types, D-037).
