# presence

Who is here, for Roc Solid apps: who is in a room right now (a name, a colour, a picture and a
status each), who joined and who left, who is typing, and where everyone's cursor is. The user
guide, with a live demo, is the docs site's
[Presence page](https://roc-solid.github.io/ecosystem/presence); this file is the reference.

A room is a route's channel, and the server keeps it in its memory (`Kv`): there is no broker to
run, and nothing is written to the database. A member in two tabs is one face, and leaves when the
last tab does. A page that goes to another room leaves at once. A tab that closes leaves after a
5-second grace, so a reload or a reconnect doesn't flicker. A tab that vanishes without a word (a
laptop shut, a network gone) is swept out when its heartbeats stop.

```roc
import presence.AvatarStack
import presence.TypingIndicator
import presence.Presence
import presence.Wire

here = Presence.join!(Api.channel_rooms_room({ room: room }))

<AvatarStack faces!={(here.members!)().map(Wire.face)} max={4} />
<TypingIndicator names!={Wire.names((here.members!)(), (here.typing!)())} />
```

## Installing it

Name the package in the app's header, by its directory's name. It is not a plugin: there is
nothing to add to the program.

```roc
app [program] { pf: platform "…/server/platform/main.roc", presence: "…/packages/presence/main.roc" }
```

The package has three parts:

- **The logic is plain Roc**, on no platform, so the server's hooks and the browser's stores run
  the same code (the modules below). `browser.roc` lists them for the browser's half.
- **The components and the browser's stores are `.rocx` files** in `components/`. They import the
  platform's `Html` and `Solid`, so `rocx build` copies them into each app that names the package
  (`Generated/presence/`), where `pf` is whichever platform each half is on.
- **The server's side is `PresenceServer`**: a room channel's hooks, with the room kept in `Kv`.
  For it the package names the server platform (`main.roc`); the browser's half never sees it.

## Wiring a room

A room is a route's channel. Its URL names the room, its check lets a member in, and its hooks are
`PresenceServer`'s:

```roc
# routes/rooms/[room]/+server.roc: who is in the room, as a channel
import pf.Server
import pf.Endpoint
import pf.Channel
import presence.PresenceServer
import presence.Wire

channel! : { request : Server.Request, params : { room : Str }, context : { member : Str } } => Try(Channel(Wire.Member({}), Wire.Event(Wire.Meta({})), Wire.Said), Endpoint.Refusal)
channel! = |{ context, .. }| Ok(Channel.allow({ key: context.member, meta: { name: context.member, image: "", color: "", status: "", data: {} } }))

on_open! = PresenceServer.on_open!

on_close! = PresenceServer.on_close!

receive! = PresenceServer.receive!
```

```roc
# routes/rooms/[room]/+page.rocx
import pf.Html
import presence.AvatarStack
import presence.TypingIndicator
import presence.LiveCursors
import presence.Presence
import presence.Wire
import ../../../Generated/Api

view! = |{ params }| {
    here = Presence.join!(Api.channel_rooms_room({ room: params.room }))
    <section>
        <Document on:visibilitychange.visible={here.visible!} />
        <AvatarStack faces!={(here.members!)().map(Wire.face)} />
        <LiveCursors cursors!={Wire.pointers((here.members!)(), (here.cursors!)())} on_move!={here.moved!} on_leave!={here.away!}>
            <textarea aria-label="Say something" on:input={here.typed!} on:blur={here.done!}></textarea>
        </LiveCursors>
        <TypingIndicator names!={Wire.names((here.members!)(), (here.typing!)())} />
    </section>
}
```

examples/board does this for real: `routes/b/[board]/presence/+server.roc` and its page.

**Who a member is** (their key, their name) is always the server's say: the channel's check gives
it, from the middleware's context, never from the page. The page's tab id is its live stream's
(the same across reconnects and reloads), and the room tells the page its own key and tab first
(`Welcome`), then who is here.

**A status** (`away`, `busy`, the card a page has open) is a word the page says, from a handler or
an effect's `apply`:
`create_effect!(|| open!(), |card| (here.status!)(Board.status_of(card)))` (examples/board).

**A hidden tab** is `away` once the page says whether it shows, in one line:
`<Document on:visibilitychange.visible={here.visible!} />`. While it is hidden its beats say `away`
and its cursor goes; the status it had comes back as it shows again. That line is the app's to
write, not the store's doing: what a hidden tab means is the app's choice (`away`, `idle`, or
nothing, for a page on a wall screen). This follows Solid's way of composing small primitives
(solid-primitives' `createPageVisibility` beside the store, not inside it).

**The app's own metadata** goes in `data` (`Wire.Meta(d)`): a team, a role, a seat, typed, carried
through the room and its channel as it is. `d` is any type JSON can carry both ways and that can be
compared with `==`; `{}` for none. The hooks and the stores are generic in it; the components read
the rest of `Meta`.

## How a room holds together

- **Joining.** A tab joins as its subscription opens (`on_open!`): it is sent its key and tab, then
  a snapshot of who is here. A member who was here already keeps the status they had.
- **Leaving.** A tab leaves when its subscription ends (`on_close!`). If the page dropped the
  room's subscription while the tab stays (`Dropped`: it went to another room), it leaves at once.
  If the tab's stream went (`Gone`), it leaves after a 5-second grace, so a page that reloads or
  reconnects doesn't flicker out and in. The host tells a tab's hooks in order: an old
  subscription's end before a new one's start.
- **Heartbeats.** A page says it is here every 15 s (`Here`, with its status). A tab whose page
  vanished without a word is swept out 75 s after its last word, however long its connection
  lingers. A browser may hold a hidden tab's timers back to once a minute; 75 s is that minute and a
  beat to spare.
- **Changes.** Each change reads the room from `Kv` (under `presence:<the channel's URL>`), sweeps
  it, changes it and swaps it back (`Kv.swap!`), reading it again if another change got there first,
  so two tabs joining at once both count. Then it publishes what changed on the channel, numbered.
  A page that misses a number asks for a snapshot again (`Endpoint.resync!`).
- **Typing and cursors** are said and passed on, never kept. A cursor is published latest-wins
  (`Endpoint.publish_latest!`): a tab that falls behind gets each member's newest place.
- **Forgetting.** A room nobody speaks in for a quarter of an hour is dropped from `Kv`. One made
  again numbers on from the time, so a page's copy sees the gap and asks again.

## Components

### `<AvatarStack>`

| Prop | |
|---|---|
| `faces! : () => List(Stack.Face)` | who is here, in order: `{ key, name, image, color, status }` (`Wire.face` makes one from a member). A face whose `image` is `""` shows initials on its `color` (or, when that is `""` too, a colour picked from its key) |
| `max : U64 ?? 5` | how many places, the `+N` included |
| `label : Str ?? ""` | what a screen reader hears for the stack (when empty: `"Ann, Bo and 2 others are here"`) |

A face with a status gets a class (`status-away`) and a dot: orange for `away` (the face dimmed
too), red for `busy`, green for any other word. No status, no dot. The `+N`'s tooltip names the
people it stands for. A face that comes grows in; one that goes fades out.

### `<TypingIndicator>`

| Prop | |
|---|---|
| `names! : () => List(Str)` | who is typing (`Wire.names(members, keys)` turns keys into names) |
| `say : (List(Str) -> Str) ?? Typing.sentence` | writes the sentence; the default is English |

Three bobbing dots and the sentence. It keeps its line's height when no one is typing, so nothing
under it jumps, and a screen reader hears it change (`aria-live="polite"`).

### `<LiveCursors>`

| Prop | |
|---|---|
| `cursors! : () => List(LiveCursors.Pointer)` | others' cursors, `{ key, name, color, x, y, idle }`; `x` and `y` are fractions of the area, 0 to 1 (`Wire.pointers(members, cursors)` makes them) |
| `children : List(Html)` | the area they point at |
| `on_move! : (Html.Point => {}) ?? \|_\| {}` | this page's pointer over the area, as fractions of it, at most once a frame (`on:pointermove.point`): pass `here.moved!` |
| `on_leave! : (() => {}) ?? \|\| {}` | the pointer left the area: pass `here.away!` |

Each cursor is an arrow in its member's colour, with their name beside it. It glides between the
places it is sent, fades when idle, and takes no pointer events. `here.moved!` sends your own place
at once, then at most 20 times a second, keeping the last one, so it ends where the pointer stopped.
`<LiveCursors>` listens to the pointer, so it must be outside a `<NoHydration>` (which runs no
handler).

## Stores

Called in a component, as `create_signal!` is (`components/Presence.rocx`):

| Store | Gives |
|---|---|
| `join!(channel)` | the room on a route's channel, joined while the component is there: everything `create_room!` gives, fed by the channel, plus what this tab says: `status!(word)`, `typed!()` and `done!()` (a typist, pinging every 3 s at most), `moved!(point)` and `away!()` (a pointer, 20 times a second at most), `visible!(shown)` (`away` while hidden). It says it is here every 15 s |
| `create_room!(on_gap!)` | all the parts at once, fed by `heard!(event)`: `members!`, `synced!`, `me!` (`{ key, tab }`), `typing!` (keys, your own left out), `cursors!` (others'), `lost!`. Someone who leaves stops typing and loses their cursor. `on_gap!` runs when a change was missed |
| `create_presence!(on_gap!)` | `members!`, `synced!`, `receive!(message)`, `lost!` (who was here stays on show until the next snapshot) |
| `create_typing!(ttl)` | `who!`, `started!(key)`, `stopped!(key)`; a ping lasts `ttl` ms |
| `create_typist!(every, send!)` | `typed!()`, `done!()`; `send!` is given `Started` (at once, then at most every `every` ms) or `Stopped` |
| `create_cursors!({ idle, forget })` | `shown!` (each idle once still for `idle` ms), `moved!(move)`, `gone!(key)`; a cursor still for `forget` ms is forgotten |
| `create_pointer!(every, send!)` | `moved!(point)` (sent at once, then at most every `every` ms, the latest held and sent when due), `away!()` (what is held dropped); `send!` is given `Moved(point)` or `Away` |

`join!` uses a typing ping of 7 s, and cursors that go idle after 5 s and are forgotten after 30 s.

**Call a store once per handler.** A write applies when its handler is done (Solid 2.0's
batching), so a second call in the same handler sees the store as it was before the first, and the
first is lost. A channel hands each event to a handler of its own, so a page fed by one never does
this. A page that makes several events at once sends each from a handler of its own
(`set_timeout!(0, …)`).

A store whose entries expire (typing, idle cursors) keeps a clock of its own: a timer that ticks
every quarter second, only while something can expire. `create_pointer!` reads the browser's clock
(`Time.now_millis!`).

## Modules

Plain Roc, no platform. Each function that depends on time takes it as an argument (`now`, in
milliseconds), so the tests run on a clock they are given and a timeout is tested without waiting
for one. `roc test packages/presence/main.roc` runs their `expect`s.

| Module | What it does |
|---|---|
| `Room` | The room, as the server keeps it. `empty(settings)`; `join`, `update` (new metadata), `heartbeat`, `leave` (gone after `grace`, unless back by then), `quit` (gone at once: the page dropped the room), `sweep` (tabs unheard for `timeout` go). Each returns the changes others should hear (`Joined`, `Left`, `Changed`) and numbers the room's state (`version`). `signal` does what a `Signal` says; `members`, `count`, `is_here`; `deadline`, when the next sweep could find someone; `save`/`load` for JSON. `Room.defaults`: a 75 s timeout and a 5 s grace; `beat_every(settings)`: a fifth of the timeout, 15 s |
| `Mirror` | A page's copy: `empty`, then `receive` a `Snapshot` and the numbered `Delta`s after it. It drops what is older than its snapshot, and returns `Err(Gap)` when a number is skipped. A snapshot after a reconnect returns what changed meanwhile. `members`, `count`, `is_synced`, `unsynced`; on the server, `snapshot(room)` and `deltas(room, changes)` |
| `Diff` | `between(before, after)`: who left, joined and changed; `apply` one change to a list; `key` of a change |
| `Throttle` | At most one send every `every` ms: the first at once, the latest held and sent when due (`new`, `push`, `flush`, `drop`, `is_holding`, `due`). A cursor at 20 a second ends where the pointer stopped |
| `Cursors` | Others' cursors: `place` (a pointer's pixels as fractions of the area, 0 to 1, to thousandths), `moved`, `gone`, `shown` (idle after a while), `sweep` (forgotten after longer), `next_idle`, `count`, `coalesce` (a burst, one move per member), `percent` |
| `Typing` | Who is typing: `new(ttl)`, `started` (a ping, which lasts `ttl`), `stopped`, `who`, `sweep`, `deadline`; `sentence`: `"Ann and Bo are typing…"` |
| `Typist` | A page's own side: `new(every)`, `typed(now)` says when to ping (at once, then at most every `every`), `done` when to say it stopped, `rest` after a quiet spell, `is_pinging` |
| `Stack` | An avatar stack's arithmetic: `split` (who fits, and `+N`), `initials` (`"Ada Lovelace"` is `"AL"`), `color` (the same key, the same colour, from a palette white text reads on), `color_of` (a face's own colour, or its key's), `names`, `label` |
| `Wire` | What a room's channel carries. To a page, `Event`: `Welcome` (the page's key and tab), `Presence(Snapshot \| Delta)`, `Typing`, `Moved`, `Away`. From one, `Said`: `Here({ status })` (its beat, and its status), `Typing(Bool)`, `Moved({ x, y })`, `Away`. Who is in it, `Member(d)`: a key, and `Meta(d)` (name, image, color, status, and the app's `data`). `face`, `names`, `name` and `pointers` feed the components |
| `PresenceServer` | The server's side (server platform only): `on_open!`, `on_close!` and `receive!`, a room channel's hooks, and `RoomChannel(c, d)`, the channel's type |

## Styling

`--avatar-size` (2rem), `--avatar-overlap`, `--avatar-ring` (the ring between faces: set it to the
page's background), `--avatar-font`, `--avatar-more`, `--avatar-status`, `--avatar-away`,
`--avatar-busy`; `--typing-color`, `--typing-size`; `--cursor-glide` (0.12s), `--cursor-font`.
Under `prefers-reduced-motion` the dots stop bobbing and the cursors jump instead of gliding.

## Status

Works today:

- the modules and their `expect`s (`roc test packages/presence/main.roc`);
- the three components and the stores, built by `rocx build` into an app, both halves
  type-checked;
- the room on a channel (`PresenceServer`): in examples/board, two people in their own browsers
  each see the other (on the tab's one stream, beside the board's own channel), see which card each
  has open (the status), see one away while their tab is hidden, and see a third who closes their
  browser leave once the grace is up;
- your own cursor (`on_move!`), `away` while a tab is hidden (`visible!`), and the app's own
  metadata (`Wire.Meta(d)`'s `data`). The docs' demo sends your pointer as a room does.

Not yet (PROPOSALS.md has the options): the live stream itself as the heartbeat, instead of a beat
every 15 s (C8), and a room named by the page's path, for a "who's viewing this page" stack without
a route of its own (question 1).
