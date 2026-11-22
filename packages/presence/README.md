# presence

Who is here, for Roc Solid apps: who is in a room right now, with a name, a colour, a picture and
a status each; who joined and who left; who is typing; and where everyone's cursor is. A member in
two tabs is one face, and leaves when the last tab does. A page that closes leaves at once (after a
few seconds' grace, so a reconnect doesn't flicker); one that vanishes without a word (a laptop
shut, a network gone) is swept out when its heartbeats stop.

```roc
import presence.AvatarStack
import presence.TypingIndicator
import presence.Presence
import presence.Wire

here = Presence.create_room!(|| {})

<AvatarStack faces!={(here.members!)().map(Wire.face)} max={4} />
<TypingIndicator names!={Wire.names((here.members!)(), (here.typing!)())} />
```

The server keeps each room itself, as an actor: one server instance, so there is no broker to run.

## Three parts

**The logic is a Roc package** (`main.roc`): plain Roc on no platform, so the server's stream and
the browser's components run the same code. Its tests run on a clock they are given (`now`, in
milliseconds), so a timeout is tested without waiting for one.

| Module | What it does |
|---|---|
| `Room` | The room, as the server keeps it: `join`, `update` (new metadata), `heartbeat`, `leave` (gone after `grace`, unless back by then), `sweep` (tabs unheard for `timeout` go). Each answers the changes others should hear, `Joined`, `Left`, `Changed`, and numbers the room's state (`version`). `signal` does what a `Signal` says; `deadline` is when the next sweep could find someone; `save`/`load` for JSON. `Room.defaults`: a 75 s timeout, a 5 s grace, a beat every 15 s (`beat_every`) |
| `Mirror` | A page's copy: takes a `Snapshot` and the numbered `Delta`s after it; drops what is older than its snapshot, and answers `Err(Gap)` when a number is skipped. A snapshot after a reconnect answers what changed meanwhile |
| `Diff` | `between(before, after)`: who left, joined and changed; `apply` one change to a list |
| `Throttle` | At most one send every `every` ms, the first at once, the latest held and sent when due (`push`, `flush`): a cursor at 20 a second ends where the pointer stopped |
| `Cursors` | Others' cursors: `place` (a pointer's pixels as shares of the area, 0 to 1, to thousandths), `moved`, `gone`, `shown` (idle after a while), `sweep` (forgotten after longer), `coalesce` (a burst, one per member), `percent` |
| `Typing` | Who is typing: `started` (a ping, which lasts `ttl`), `stopped`, `who`, `deadline`; `sentence`: `"Ann and Bo are typing…"` |
| `Typist` | A page's own side: `typed(now)` says when to ping (at once, then at most every `every`), `done` when to say it stopped, `rest` after a quiet spell |
| `Stack` | An avatar stack's arithmetic: `split` (who fits, and `+N`), `initials` (`"Ada Lovelace"` is `"AL"`), `color` (the same key, the same colour, from a palette white text reads on), `names`, `label` |
| `Wire` | What a room's stream sends, `Event`: `Welcome` (the page's key and tab), `Presence(Snapshot \| Delta)`, `Typing`, `Moved`, `Away`; the metadata it carries (`Meta`: name, image, color, status); `face`, `names`, `pointers` to feed the components |

`roc test packages/presence/main.roc` runs their `expect`s.

**The components and the browser's stores are `.rocx` files** (`components/`). They import the
platform's `Html` and `Solid`, so, as with charts, `rocx build` copies them into each app that names
the package (`Generated/presence/`), where `pf` is whichever platform each half is on. Name the
package in the app's header, by its directory's name:

```roc
app [program] { presence: "../packages/presence/main.roc", pf: platform "…" }
```

**The server's side is `server/PresenceServer.roc`.** It imports `Actor`, `Live`, `Random` and
`Time`, which only the server's platform has, and `rocx build` doesn't copy a package's server modules yet (see
PROPOSALS.md, "Server-only modules in packages"). For now, copy it into the app, beside `main.roc`,
and import it from there (`import ../PresenceServer` in a route file).

## Wiring a room, today

A room is an endpoint that streams its events, two that take a page's posts (its beat, and who is
typing), and a component, which sends those from its handlers with `Endpoint.send!`.

```roc
# routes/presence/[room]/+server.roc: this tab is in the room, as the member the middleware says
import pf.Server
import pf.Endpoint
import pf.Events
import presence.Wire
import ../../../PresenceServer

events! : { request : Server.Request, params : { room : Str }, context : { member : Str } } => Try(Events(Wire.Event(Wire.Meta)), Endpoint.Refusal)
events! = |{ params, context, .. }|
    Ok(PresenceServer.stream(params.room, { key: context.member, meta: { name: context.member, image: "", color: "", status: "" } }))
```

```roc
# routes/presence/[room]/beat/+server.roc: this tab is still here (and, if the room had swept it
# out, here again)
import pf.Server
import pf.Endpoint
import ../../../../PresenceServer

post! : { request : Server.Request, params : { room : Str }, context : { member : Str }, body : { tab : Str } } => Try({}, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
    _ = PresenceServer.join!(params.room, { key: context.member, tab: body.tab, meta: { name: context.member, image: "", color: "", status: "" } })
    Ok({})
}
```

```roc
# routes/presence/[room]/typing/+server.roc: this page's member is typing, or stopped
import pf.Server
import pf.Endpoint
import ../../../../PresenceServer

post! : { request : Server.Request, params : { room : Str }, context : { member : Str }, body : { typing : Bool } } => Try({}, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
    PresenceServer.typing!(params.room, context.member, body.typing)
    Ok({})
}
```

```roc
# routes/rooms/[room]/+page.rocx
import pf.Html
import pf.Call
import pf.Endpoint
import pf.Solid exposing [set_interval!, on_settled!]
import presence.AvatarStack
import presence.TypingIndicator
import presence.LiveCursors
import presence.Presence
import presence.Room
import presence.Wire
import ../../../Generated/Api

## A page's beat, from its timer: this tab is still here.
beat! : Str, Str => {}
beat! = |room, tab| {
    _sent = Endpoint.send!(Api.post_presence_room_beat({ room: room }), { tab: tab }, Call.fetch!)
    {}
}

## This page's member is typing, or stopped, from a handler.
typing! : Str, Bool => {}
typing! = |room, typing| {
    _sent = Endpoint.send!(Api.post_presence_room_typing({ room: room }), { typing: typing }, Call.fetch!)
    {}
}

view! = |{ params }| {
    room = params.room
    here = Presence.create_room!(|| {})
    heard! : Wire.Event(Wire.Meta) => {}
    heard! = here.heard!
    typist = Presence.create_typist!(3000, |said| typing!(room, said == Started))
    on_settled!(|| Endpoint.listen!(Api.events_presence_room({ room: room }), Call.listen!, |event|
        match event {
            Event(said) => heard!(said)
            Ended => (here.lost!)()
            Failed(_) => (here.lost!)()
        }))
    on_settled!(|| {
        _ = set_interval!(Room.beat_every(Room.defaults), || beat!(room, (here.me!)().tab))
        {}
    })
    <section>
        <AvatarStack faces!={(here.members!)().map(Wire.face)} />
        <LiveCursors cursors!={Wire.pointers((here.members!)(), (here.cursors!)())}>
            <textarea aria-label="Say something" on:input={typist.typed!} on:blur={typist.done!}></textarea>
        </LiveCursors>
        <TypingIndicator names!={Wire.names((here.members!)(), (here.typing!)())} />
    </section>
}
```

`heard!` is annotated because the browser's copy of an endpoint is only its URL: the events' type is
what the page says it is. (`{ room: room }`, not `{ room }`, which on its own is a block.)

Who a member is (their key, their name) is always the server's say: the endpoints read it from the
middleware's context. The page's tab id comes from the stream
(`Welcome`), and only names a tab of the member the server says.

How it holds together: the room is an actor (one message at a time, so two tabs joining at once
both count; its state is a `Room`); the actor publishes each change, numbered, on the room's `Live`
topic as it makes it; each page's stream listens, sends a snapshot, then the changes, and the page's
`Mirror` takes them in order. A stream that ends leaves its tab; a page beats every 15 s, and a tab
whose beats stop is swept out 75 s after the last (a browser may hold a hidden tab's timers back to
once a minute).

**Channels** (D-020) have landed since, with hooks for what presence asked of them (PROPOSALS.md,
C1 to C9); this glue doesn't use them yet. On a channel, the three endpoints would be one route's
`channel!` (its `on_open!` sending the snapshot, `on_close!` leaving, `receive!` taking what pages
say), `Endpoint.subscribe!(Api.channel_presence_room({ room: room }), …)` would feed `heard!`, and
`Endpoint.say!` would replace the posts. Nothing in the components or the stores would change.

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
places it is sent, fades when idle, and takes no pointer events. Drawing works today; sending your
own needs the pointer's place in a handler, which the platform doesn't give yet (PROPOSALS.md, W1).

## The stores

Called in a component, as `create_signal!` is (`components/Presence.rocx`):

| Store | Gives |
|---|---|
| `create_room!(on_gap!)` | all of these at once, fed by `heard!(event)`: `members!`, `synced!`, `me!` (`{ key, tab }`), `typing!` (keys, your own left out), `cursors!` (others'), `lost!`; one who leaves stops typing and loses their cursor |
| `create_presence!(on_gap!)` | `members!`, `synced!`, `receive!(message)`, `lost!` |
| `create_typing!(ttl)` | `who!`, `started!(key)`, `stopped!(key)` |
| `create_typist!(every, send!)` | `typed!()`, `done!()`; `send!` is given `Started` or `Stopped` |
| `create_cursors!({ idle, forget })` | `shown!`, `moved!(move)`, `gone!(key)` |

Call a store once a handler. A write applies when its handler is done (Solid 2.0's batching), so a
second call in the same handler sees the store as it was before the first, and the first is lost. A
stream hands each event to a handler of its own, so a page fed by one never does; a page that makes
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

- the package: 97 `expect`s (`roc test packages/presence/main.roc`);
- the three components and the stores, built by `rocx build` into an app, both halves type-checked;
- `server/PresenceServer.roc`, copied into an app by hand, with the page above: in a scratch app's
  native server and headless Chromium, two members each saw the other (`"ann and bo are here"`), one
  saw the other typing, the ping ran out on its own, and a closed tab left the other's stack 8 s
  later (the 5 s grace, then the next sweep); over plain HTTP, a tab that beat once and went silent
  was swept out after the 75 s timeout.

Not done yet: the glue on channels (D-020, landed), for one stream for every room on a page, and
messages from the page without a request each.

Waits on a proposal (PROPOSALS.md):

- `rocx build` copying `server/` into the server's half (Server-only modules in packages);
- sending your own cursor (W1), a clock in the browser (W2), `away` when a tab is hidden (W3);
- presence without a database write per beat (S1);
- the app's own metadata type on the wire, instead of `Wire.Meta` (R1).
