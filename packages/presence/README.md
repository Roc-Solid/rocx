# presence

Who is here, for Roc Solid apps: who is in a room right now, with a name, a colour, a picture and
a status each; who joined and who left; who is typing; and where everyone's cursor is. A member in
two tabs is one face, and leaves when the last tab does. A page that goes to another room leaves at
once; one that closes leaves after a few seconds' grace (so a reload or a reconnect doesn't
flicker); one that vanishes without a word (a laptop shut, a network gone) is swept out when its
heartbeats stop.

```roc
import presence.AvatarStack
import presence.TypingIndicator
import presence.Presence
import presence.Wire

here = Presence.join!(Api.channel_rooms_room({ room: room }))

<AvatarStack faces!={(here.members!)().map(Wire.face)} max={4} />
<TypingIndicator names!={Wire.names((here.members!)(), (here.typing!)())} />
```

A room is a route's channel (D-020), and the server keeps it in its memory (`Kv`): one server
instance, so there is no broker to run, and nothing is written to Postgres.

## Three parts

**The logic is plain Roc**, on no platform, so the server's hooks and the browser's components run
the same code. Its tests run on a clock they are given (`now`, in milliseconds), so a timeout is
tested without waiting for one.

| Module | What it does |
|---|---|
| `Room` | The room, as the server keeps it: `join`, `update` (new metadata), `heartbeat`, `leave` (gone after `grace`, unless back by then), `quit` (gone at once: the page dropped the room), `sweep` (tabs unheard for `timeout` go). Each answers the changes others should hear, `Joined`, `Left`, `Changed`, and numbers the room's state (`version`). `signal` does what a `Signal` says; `deadline` is when the next sweep could find someone; `save`/`load` for JSON. `Room.defaults`: a 75 s timeout, a 5 s grace, a beat every 15 s (`beat_every`) |
| `Mirror` | A page's copy: takes a `Snapshot` and the numbered `Delta`s after it; drops what is older than its snapshot, and answers `Err(Gap)` when a number is skipped. A snapshot after a reconnect answers what changed meanwhile |
| `Diff` | `between(before, after)`: who left, joined and changed; `apply` one change to a list |
| `Throttle` | At most one send every `every` ms, the first at once, the latest held and sent when due (`push`, `flush`): a cursor at 20 a second ends where the pointer stopped |
| `Cursors` | Others' cursors: `place` (a pointer's pixels as shares of the area, 0 to 1, to thousandths), `moved`, `gone`, `shown` (idle after a while), `sweep` (forgotten after longer), `coalesce` (a burst, one per member), `percent` |
| `Typing` | Who is typing: `started` (a ping, which lasts `ttl`), `stopped`, `who`, `deadline`; `sentence`: `"Ann and Bo are typing…"` |
| `Typist` | A page's own side: `typed(now)` says when to ping (at once, then at most every `every`), `done` when to say it stopped, `rest` after a quiet spell |
| `Stack` | An avatar stack's arithmetic: `split` (who fits, and `+N`), `initials` (`"Ada Lovelace"` is `"AL"`), `color` (the same key, the same colour, from a palette white text reads on), `names`, `label` |
| `Wire` | What a room's channel carries: to a page, `Event`: `Welcome` (the page's key and tab), `Presence(Snapshot \| Delta)`, `Typing`, `Moved`, `Away`; from one, `Said`: `Here({ status })` (its beat, and its status), `Typing(Bool)`, `Moved({ x, y })`, `Away`; who is in it, `Member` (a key, and `Meta`: name, image, color, status); `face`, `names`, `pointers` to feed the components |

`roc test packages/presence/main.roc` runs their `expect`s.

**The components and the browser's stores are `.rocx` files** (`components/`). They import the
platform's `Html` and `Solid`, so, as with charts, `rocx build` copies them into each app that names
the package (`Generated/presence/`), where `pf` is whichever platform each half is on.

**The server's side is `PresenceServer`**: a room channel's hooks, with the room kept in `Kv`. The
package names the server platform for it (D-033, as guard does), and the browser's half sees the
modules both halves compile (`browser.roc`), so an app names the package once in its header, by its
directory's name, and imports `presence.PresenceServer` in a route file:

```roc
app [program] { presence: "../packages/presence/main.roc", pf: platform "…" }
```

## Wiring a room

A room is a route's channel: its check lets a member in, and its hooks are `PresenceServer`'s. Its
URL is the room.

```roc
# routes/rooms/[room]/+server.roc: who is in the room, as a channel
import pf.Server
import pf.Endpoint
import pf.Channel
import presence.PresenceServer
import presence.Wire

channel! : { request : Server.Request, params : { room : Str }, context : { member : Str } } => Try(Channel(Wire.Member, Wire.Event(Wire.Meta), Wire.Said), Endpoint.Refusal)
channel! = |{ context, .. }| Ok(Channel.allow({ key: context.member, meta: { name: context.member, image: "", color: "", status: "" } }))

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
        <AvatarStack faces!={(here.members!)().map(Wire.face)} />
        <LiveCursors cursors!={Wire.pointers((here.members!)(), (here.cursors!)())}>
            <textarea aria-label="Say something" on:input={here.typed!} on:blur={here.done!}></textarea>
        </LiveCursors>
        <TypingIndicator names!={Wire.names((here.members!)(), (here.typing!)())} />
    </section>
}
```

A status (`away`, the card a page has open) is a word the page says, from a handler or an effect's
apply: `create_effect!(|| open!(), |card| (here.status!)(Board.status_of(card)))`
(examples/board).

Who a member is (their key, their name) is always the server's say: the channel's check gives it,
from the middleware's context. The page's tab id is its hub's (the same across reconnects and
reloads), and the room tells the page its own key and tab first (`Welcome`), then who is here.

How it holds together: a tab joins as its subscription opens (`on_open!`: its key and tab, then a
snapshot) and leaves when it ends (`on_close!`): at once when the page dropped the room's
subscription while the tab stays (`Dropped`: it went to another room, D-057), after a 5 s grace
when the tab's stream went (`Gone`: a page that reloads or reconnects doesn't flicker out and in);
the host tells a tab's hooks in order, a subscription's end before a new one's start. A page says it is here every 15 s (`Here`, with its status), so a tab whose page vanished
without a word (a laptop shut, a network gone) is swept out 75 s after its last word, however long
its connection lingers (a browser may hold a hidden tab's timers back to once a minute). Each
change reads the room from `Kv`, sweeps it, changes it and swaps it back (`Kv.swap!`, read again if
another changed it first, so two tabs joining at once both count), then publishes what changed on
the channel, numbered; a page that misses a number asks for a snapshot again (`Endpoint.resync!`).
Typing and cursors are said and passed on, never kept (a cursor latest-wins). A room nobody speaks
in for a quarter of an hour is forgotten.

## `<AvatarStack>`

| Prop | |
|---|---|
| `faces! : () => List(Stack.Face)` | who is here, in order: `{ key, name, image, color, status }` (`Wire.face` makes one from a member). A face whose `image` is `""` shows initials on its `color` (or, when that is `""` too, a colour from its key) |
| `max : U64` | how many places, the `+N` included (5 when not given) |
| `label : Str` | what a screen reader hears for the stack (when not given: `"Ann, Bo and 2 others are here"`) |

A status (`away`, `busy`, any word) is a class, `status-away`, and a dot: green, or orange for `away`,
red for `busy`. One who comes grows in, one who goes fades out. A "who's viewing this page" stack is
one whose room is the page's path.

## `<TypingIndicator>`

| Prop | |
|---|---|
| `names! : () => List(Str)` | who is typing (`Wire.names(members, keys)`) |
| `say : List(Str) -> Str` | the sentence (`Typing.sentence`, in English, when not given) |

Three dots that bob, and the sentence. It keeps its line's height when no one is typing, so nothing
under it jumps, and a screen reader hears it change (`aria-live="polite"`).

## `<LiveCursors>`

| Prop | |
|---|---|
| `cursors! : () => List(LiveCursors.Pointer)` | others' cursors, `{ key, name, color, x, y, idle }`, `x` and `y` shares of the area (`Wire.pointers(members, cursors)`) |
| `children : List(Html)` | the area they point at |

Each cursor is an arrow in its member's colour with their name beside it. It glides between the
places it is sent, fades when idle, and takes no pointer events. Drawing works today, and a room
passes on what `here.moved!` says; sending your own needs the pointer's place in a handler, which
the platform doesn't give yet (PROPOSALS.md, W1).

## The stores

Called in a component, as `create_signal!` is (`components/Presence.rocx`):

| Store | Gives |
|---|---|
| `join!(channel)` | the room on a route's channel, joined while the component is there: what `create_room!` gives, fed by the channel, and what this tab says: `status!(word)`, `typed!()` and `done!()` (a typist, every 3 s at most), `moved!({ x, y })`, `away!()`; it says it is here every 15 s |
| `create_room!(on_gap!)` | all of these at once, fed by `heard!(event)`: `members!`, `synced!`, `me!` (`{ key, tab }`), `typing!` (keys, your own left out), `cursors!` (others'), `lost!`; one who leaves stops typing and loses their cursor |
| `create_presence!(on_gap!)` | `members!`, `synced!`, `receive!(message)`, `lost!` |
| `create_typing!(ttl)` | `who!`, `started!(key)`, `stopped!(key)` |
| `create_typist!(every, send!)` | `typed!()`, `done!()`; `send!` is given `Started` or `Stopped` |
| `create_cursors!({ idle, forget })` | `shown!`, `moved!(move)`, `gone!(key)` |

Call a store once a handler. A write applies when its handler is done (Solid 2.0's batching), so a
second call in the same handler sees the store as it was before the first, and the first is lost. A
channel hands each event to a handler of its own, so a page fed by one never does; a page that makes
several events at once sends each from a handler of its own (`set_timeout!(0, …)`).

The browser has no clock yet, so a store keeps its own: a timer that ticks every quarter second, and
only while something can expire.

## Styling

`--avatar-size` (2rem), `--avatar-overlap`, `--avatar-ring` (the ring between faces: the page's
background), `--avatar-font`, `--avatar-more`, `--avatar-status`, `--avatar-away`, `--avatar-busy`;
`--typing-color`, `--typing-size`; `--cursor-glide` (0.12s), `--cursor-font`. Motion stops under
`prefers-reduced-motion`.

## Status

Works today:

- the package: its `expect`s (`roc test packages/presence/main.roc`);
- the three components and the stores, built by `rocx build` into an app, both halves type-checked;
- the room on a channel (`PresenceServer`, imported from the package): in examples/board, two people
  in browsers of their own each see the other, on the tab's one stream with the board's own channel,
  see which card each has open (the status), and see a third who closes their browser leave once
  the grace is up.

Waits on a proposal (PROPOSALS.md):

- sending your own cursor (W1), a clock in the browser (W2), `away` when a tab is hidden (W3);
- the app's own metadata type on the wire, instead of `Wire.Meta` (R1).

Done since it was proposed: the glue on channels (C1 to C9, D-020), a package's server modules
(D-033: the package names the server platform), and presence without a database write per beat
(S1: the room is kept in `Kv`, never in Postgres).
