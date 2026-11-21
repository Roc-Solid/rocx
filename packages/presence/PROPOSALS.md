# presence: proposals

What `packages/presence` needs from outside its folder. Nothing here is built: each section is a
problem, the options considered, the change recommended, what in the package depends on it, and
how it could be undone. Everything the package has today works without these; where it works around
one, the section says how.

The channels asks are first, collected under one heading so they can be forwarded as a group.

---

## Channels asks (for rocx-3a)

Written against the channels brief (D-020: typed channels with a permission check over the
middleware context, `Channel.publish!` on `Live`, one stream per tab at `/rocx/live`, a hub in
runtime.js, `Channel.subscribe!(chan, params, |event| …)` with `Message`, `Resync`, `Refused`,
`Ended`). Presence is meant to sit on top of it: a presence channel for who is here, and a
high-rate channel for cursors. Each ask says what presence does without it.

What presence sends today, over one endpoint's events (see "Today's glue" at the end of this file),
is what it would send over a channel: `Wire.Event`, a JSON union of `Welcome`, `Presence(Snapshot |
Delta)`, `Typing`, `Moved` and `Away`. The ask list is ordered by how much it matters.

### C1. Messages from the page to the server, over a channel

**Problem.** Typing pings, cursor moves and heartbeats go from a page to the room. Without
WebSockets, today that is a server function per message (`beat!`, `typing!`, a `moved!` 20 times a
second), each its own POST, named and checked separately from the channel the room's events come
on: two permission checks to keep in step, and the room's name trusted from the page twice.

**Options.**
1. Server functions, as today: works, but each is checked on its own, and a cursor is a request per
   move.
2. `Channel.send!(chan, params, message)` in the browser: a POST to `/rocx/live/send` with the
   channel's name, its params and the message, checked by the channel's own check, and handed to a
   handler the channel defines. The hub may batch a frame's sends into one POST.
3. A WebSocket: ruled out by D-020.

**Recommended.** 2, with the hub batching. A channel may define what it takes from pages:

```roc
# the app (server's copy keeps receive!; the browser's keeps the name and the types)
lobby : Channel({ room : Str }, Wire.Event(Wire.Meta), Wire.Said)
lobby = channel!({
    check!: |{ room }, context| if context.member != "" Ok(member_of(context)) else Err(Forbidden),
    receive!: |{ room }, who, said|
        match said {
            Beat({ tab }) => PresenceServer.join!(room, { key: who.key, tab, meta: who.meta })
            Typing(on) => PresenceServer.typing!(room, who.key, on)
            Moved(point) => PresenceServer.moved!(room, who.key, point)
        },
})

# in a component
Channel.send!(lobby, { room }, Moved({ x, y }))
```

Wire: `POST /rocx/live/send`, body `[{ "channel": "lobby.lobby", "params": {…}, "message": {…} }, …]`
(a batch), answered 204, or 403 per refused item (`{ "refused": [index, why] }`).

**Depends on it.** `Wire.Said` (to add, small), the stores' `typed!`/beats, the sending side of
`<LiveCursors>`.
**Undo.** Remove the route and `Channel.send!`; pages go back to server functions.

### C2. Who is here, on every (re)subscribe: a snapshot hook

**Problem.** The hub sends `Resync` on each connect, so a subscriber reloads. For presence, reloading
means "send me who is here now", on the same stream, before any change that comes after it, or the
page's copy can't tell old changes from new ones.

**Options.**
1. The page calls a server function for the snapshot on `Resync`. Racy: changes published between
   the snapshot's read and the stream's (re)open are lost or doubled, unless every message is
   numbered and the page buffers (which `Mirror` can do, but only if the snapshot carries a
   version and arrives after listening started).
2. A channel hook the server runs when a subscription opens, after it listens: its answer is sent
   first, on the stream. Presence answers `Presence(Snapshot({ version, members }))`; later
   `Delta`s are numbered after it, and `Mirror` drops the older ones.

**Recommended.** 2:

```roc
channel!({ check!, on_open!: |params, who| PresenceServer.snapshot!(params.room), … })
# the hub: Resync, then the on_open! message, then the channel's messages, in that order
```

**Depends on it.** `Mirror` (already numbers, already drops what is older than its snapshot),
`Presence.create_room!`.
**Undo.** Drop the hook; pages fetch a snapshot themselves (option 1).

### C3. A subscription's end, told to the server: join and leave with the stream

**Problem.** A tab is in a room while its page is open. The stream is the best evidence of that: when
it ends (the tab closed, navigated away, the hub reconnected with a new query), the tab should leave,
at once. Today's glue leaves when its endpoint's loop sees `Gone`. On `/rocx/live`, one stream
carries many subscriptions, and a subscription can end while the stream goes on (the page stopped
subscribing, or its check failed at a beat).

**Recommended.** Two optional hooks per channel, run on the server in the stream's call:
`on_open!(params, who, tab)` (C2's) and `on_close!(params, who, tab, why)`, `why` being
`[Unsubscribed, Gone, Refused(Str)]`. `on_close!` runs for every subscription when the stream ends,
however it ends (a crash too: the host runs it as it leaves `Live` rooms today). Presence calls
`Room.leave` in it, whose grace (5 s) covers the hub's reconnect after a change of subscriptions.

**Depends on it.** Leaving at once instead of at the next missed beat.
**Undo.** Without it, presence leans on heartbeats alone (75 s to notice a closed tab).

### C4. A tab id, the same across the hub's reconnects

**Problem.** One member in two tabs is one face in the stack, and leaves when the last tab does
(`Room` keeps tabs per member). A tab needs an id. The hub reconnects whenever the subscriptions
change; if each connection were a new tab, every reconnect would be a leave and a join (the grace
hides it, but the room churns).

**Recommended.** The hub makes a random id once per tab (`crypto.getRandomValues`, kept in
`sessionStorage` so a reload keeps it too), sends it in `/rocx/live`'s query (`?tab=…`), and the
server hands it to `on_open!`/`on_close!` and to `receive!` (C1). It identifies a tab, not a
person: a tab id from another member names nothing of theirs, since `Room` keys tabs by the member
the check says.

**Depends on it.** Today the stream makes a tab id (`Welcome`) and the page echoes it in its beats.
**Undo.** Back to the stream's own id.

### C5. Who a subscriber is, from the check

**Problem.** A member's key and metadata (name, avatar, colour) must be the server's say. A page that
could send its own name could be anyone.

**Recommended.** A channel's check answers who the subscriber is (`Try(who, Refusal)`), and the hooks
and `receive!` are given it. `who` stays on the server; the page learns its own key from the
presence snapshot or a `Welcome`.

**Depends on it.** `PresenceServer` today takes the key and metadata from the endpoint's context.
**Undo.** Each hook reads `Server.context!({})` itself.

### C6. Lagging subscribers get `Resync`, never a silent gap

**Problem.** `Live`'s broadcast keeps 256 messages per topic; a listener further behind loses the
oldest (`RecvError::Lagged(_) => continue` in `server/host/src/hosted.rs`). For presence a lost
`Left` is a ghost until the next snapshot. `Mirror` notices a skipped version (`Err(Gap)`), but the
page can do nothing about it except reconnect.

**Recommended.** When a subscription's listener lags, the hub's stream sends that subscription
`Resync` (and C2's snapshot), not the messages after the gap. And a way for a page to ask for it:
`Channel.resync!(chan, params)` (the hub re-runs `on_open!` for that subscription, or reconnects).
`Presence.create_room!`'s `on_gap!` would call it.

**Depends on it.** `Mirror`'s `Gap` (built, tested), `create_room!(on_gap!)`.
**Undo.** Pages reconnect on a gap.

### C7. Volatile, latest-wins messages for high-rate channels

**Problem.** A cursor is sent 20 times a second per member (`Throttle.new(50)`). Only its latest
place matters. Queued behind a slow subscriber, old places are worse than none; and a lagging cursor
channel shouldn't cost a `Resync`.

**Recommended.** A channel option, `delivery: Latest(|message| key)`: the server keeps, per
subscriber, only the newest unsent message per key (`Cursors.coalesce` is that function, tested),
and a lag drops the older ones without `Resync`. The hub may coalesce a frame's `Channel.send!`s
the same way before posting (C1).

**Depends on it.** Cursors at scale. Today's glue forwards every move.
**Undo.** The option goes; every message is delivered.

### C8. The stream is the heartbeat (host liveness)

**Problem.** A tab whose network vanished never closes its stream: no FIN arrives, and a server that
sends nothing on an idle stream never finds out. So presence asks pages to beat. But browsers hold a
hidden tab's timers back to once a minute (Chrome's intensive throttling), so a page's beat can be
60 s late, and the timeout has to be longer than that (75 s today): a vanished tab stays 75 s.

**Options.**
1. Page beats (today): simple; slow to notice, and costs a request per tab every 15 s.
2. The host writes a keep-alive comment (`: beat\n\n`) on `/rocx/live` every 15 s, with a deadline:
   `TCP_USER_TIMEOUT` (Linux) or `TCP_RXT_CONNDROPTIME` (macOS) of about 20 s, or a write timeout
   on the flush, so a stream whose client stopped acknowledging fails, and its call ends (C3's
   `on_close!(…, Gone)` runs). The operating system acknowledges for a hidden tab, so a hidden tab
   stays; a dead one is gone in about 35 s, and no page runs a timer.

**Recommended.** 2. Then presence's default becomes: no page beats; `Room`'s timeout stays as a
backstop for a stream that crashed without running its hooks.

**Depends on it.** `Room.defaults` (75 s) and the page's beat (`Room.beat_every`).
**Undo.** Turn the comment and the deadline off; pages beat again.

### C9. Ordering

**Ask.** Messages on one channel and params arrive in the order they were published. `Live` keeps
order per topic, and presence publishes its changes in the room actor's turn, so the numbers
`Mirror` checks arrive in order; the hub must keep that order through its dispatch (one queue per
subscription, not a `Promise` per message).

---

## Server-only modules in packages

**Problem.** Presence's server side (`server/PresenceServer.roc`: the room actor, the stream, the
publishing) imports `pf.Actor`, `pf.Live`, `pf.Events`, `pf.Time`, `pf.Random`. A Roc package can
name a platform only if it is the app's own, and a Roc Solid app is two apps (the browser's on
web/platform, the server's on server/platform), so a package can't `import pf.Live`. Today only
`components/*.rocx` get the copy treatment (`rocx build` writes them into the app's
`Generated/<alias>/`, where `pf` is each half's platform), and they are copied into both halves.

**Options.**
1. Apps copy the server modules by hand (what the scratch app does, and what README.md says for now).
   Works; copies go stale.
2. `rocx build` copies a package's `server/*.roc` (and `server/*.rocx`) into the **server half only**:
   `Generated/<alias>/<Module>.roc`, linked as components are (`import presence.PresenceServer` →
   `import ../Generated/presence/PresenceServer`). The browser's copy (`--client`) leaves them out.
   A page may import one for its server functions and route files' server parts: the browser's copy
   already drops imports that only stripped code used (checked in the scratch app: `import
   ../PresenceServer` in `+page.rocx`, used only inside `server!(…)`, is gone from the browser's
   copy, and the browser's half type-checks). An import that the browser's copy still uses is an
   error, said by rocx build: "presence.PresenceServer is the server's: use it in a server function,
   an endpoint or middleware".
3. Make the platforms one package the compiler can name from both halves: a compiler change, much
   bigger, and not needed for this.
4. Separate packages per half (`presence-server`): two packages to version and name in two headers,
   and the shared types (`Wire`) in a third.

**Recommended.** 2. In bin/rocx.mjs, `componentPackages` also collects `server/*.roc{,x}` (as
`serverPaths`); `build` writes them into `Generated/<alias>/` when building the server's half, skips
them in the `--client` copy, and `linkComponents` links `import <alias>.<Module>` for both kinds. The
browser's copy reports an import of a server module that survives stripping. Sketch:

```js
// componentPackages(dir): beside `paths` (components/*.rocx)
const server = join(root, "server");
const serverPaths = existsSync(server) ? [...files(server, ".rocx"), ...files(server, ".roc")] : [];
found.set(name, { name, own, paths, serverPaths, modules: new Set([...paths, ...serverPaths].map(moduleName)) });

// build(): the server's half writes both; the browser's copy (`client`) only `paths`, and fails on a
// surviving `import <alias>.<ServerModule>` with the message above.
```

A test beside test/packages.test.mjs's: a package with `server/Glue.roc` importing `pf.Live`; the
app's server half has `Generated/plots/Glue.roc`, its browser copy doesn't, and a page that imports
it outside a server function fails the build with the message.

**Depends on it.** `server/PresenceServer.roc` (copied by hand today).
**Undo.** Remove the second list; apps copy by hand again. Nothing else changes.

---

## Web platform asks

### W1. Where the pointer is: `on:pointermove.point`

**Problem.** A handler is given nothing (`on:click`), a field's value (`.value`), a box's `.checked`,
or a key (`.key`). Live cursors need the pointer's place over an area. There is no way to read it
from Roc today, so `<LiveCursors>` can draw others' cursors but a page can't send its own.

**Options.**
1. `on:pointermove.point={|{ x, y }| …}`: the place as shares of the element's box (0 to 1,
   `Dec`), measured against `currentTarget.getBoundingClientRect()`, so the same place on a narrow
   screen and a wide one is the same number. `on:pointerleave` (exists) for `Away`.
2. `.client` in pixels, and the box's size another way: two reads, and Roc would do the division.
3. `Browser.call!` to page JS that posts back: it answers nothing, and a round trip per move.

**Recommended.** 1. In src/transpile.mjs, `HANDLERS` gains `point: "on_point"`; web/platform/Html.roc
`on_point : Str, ({ x : Dec, y : Dec } => {}) -> Attr`; runtime.js passes
`{ x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height }` as JSON (clamped to 0..1,
three places). The server ignores it, as it does every handler.

```roc
<LiveCursors cursors!={…} on_move!={|point| move!(point)} on_leave!={away!}>
```

**Depends on it.** The sending side of `<LiveCursors>` (an `on_move!` prop, to add) and
`Throttle` (built) in a `create_pointer!` store (to add).
**Undo.** Drop `.point`; cursors are receive-only.

### W2. A clock in the browser: `Time.now_millis!`

**Problem.** Typing pings and idle cursors expire by time, and a typist pings at most every 3 s. The
browser's platform has timers but no clock. The stores keep their own: a signal a 250 ms interval
moves forward, ticking only while something can expire. It drifts when a hidden tab's timers are
held back (the clock slows, so a typist lingers until the tab is visible again, then for up to a
ping's `ttl`).

**Recommended.** `Time.now_millis! : {} => U64` on the web platform (`Date.now()`), allowed in
handlers and in an effect's apply (not in a computation, whose answer must not depend on when it
runs). The stores then read it on each event and keep a timer only to wake up (`set_timeout!` at the
next deadline: `Typing.deadline`, `Cursors.next_idle`, already built).

**Depends on it.** The stores' clocks (`components/Presence.rocx`, `tick`).
**Undo.** The stores tick again.

### W3. Whether the page is visible

**Problem.** "Away" is the natural status of a hidden tab. There is no way to know from Roc.

**Recommended.** `Browser.visible! : {} => Bool` and an `on_visibility!` effect (or a signal the
runtime writes on `visibilitychange`), so a store can `update!` the member's status to `away`.

**Depends on it.** Nothing yet; a status the app sets by hand today.
**Undo.** Drop it.

---

## Server platform asks

### S1. Actors that live in memory only

**Problem.** Today's glue keeps each room in an actor (one message at a time, crash-safe). With a
database, the platform writes an actor's state to `rocx_actors` after every turn that changes it: a
join, a leave, every beat of every tab (one per tab per 15 s: each moves a last-seen time), and a
sweep that drops someone. (A snapshot that changes nothing writes nothing, since D-021.) Presence is
gone after a restart anyway (every stream reconnects), so the writes buy nothing.

**Options.**
1. Keep it: correct, costs a write per beat.
2. An actor kind that is never written: a field `keep : [Postgres, Memory]` in `Actor.define`'s
   record (D-021). Its turns skip the read and the write; its state is its mailbox's in the host,
   which keeps such an actor awake (it can't be let go when idle and read back).
3. A general `Memory` module for apps: more general, but every user would rebuild what `Actor`
   already does (one message at a time, isolation, JSON). (`Host.lock!`, which an earlier draft of
   this option built on, is gone: D-021 has no locks.)

**Recommended.** 2. In server/platform/Actor.roc and ActorTurn.roc:

```roc
Kind(state, message, reply) : { name : Str, initial : Str -> state, receive! : …, keep : [Postgres, Memory] }
# ActorTurn.run!: for a Memory kind, the state is the host's (or initial); save! is skipped
```

**Depends on it.** `server/PresenceServer.roc`'s `kind` (one field to add).
**Undo.** The kind writes to Postgres again.

**Also, since D-021.** `Actor.after!(me, ms, Sweep)` lets a room sweep itself on a timer, rather than
on every ask and on the stream's periodic `Sweep`: a timer every so often is one that sets the next,
and a room that empties needn't set one.

### S2. Keep-alive comments on event streams

Today an `events!` stream that sends nothing is silent, so a proxy may cut it and a dead client is
never noticed (C8). Until `/rocx/live` exists, the same keep-alive and write deadline on every
`Events` stream would let today's glue notice a vanished tab without page beats.

---

## Roc compiler (the fork)

### R1. A type variable's JSON through a structural type

`Room(meta)` and `Mirror(meta)` take any metadata, and their JSON round trips work for a concrete
`meta`. Generic glue can't say so: with `where [meta.Json.Encodable([]), …]`, a record holding
`List(Room.Member(meta))` is still "missing encoder_for", so `Actor.ask!` refuses it. The glue fixes
the metadata to `Wire.Meta` (name, image, colour, status). With the fix, `PresenceServer` would take
the app's own metadata type. (Nominal types need `encoder_for`/`parser_for` of their own, which is
why `Room` has `save`/`load` to a plain record; that part is fine.)

---

## Open questions (for the user)

1. **"Who's viewing this page"**: should a page's room be its path by default (a store that reads
   `Router.location!`), or should the app always name the room? The package names it today.
2. **Metadata**: is `Wire.Meta` (name, picture, colour, status) the right fixed shape until R1, or
   should it carry one more free field (`data : Str`, JSON the app owns)?
3. **Hidden tabs**: shown as `away` automatically (W3), or left to the app?
4. **Timeout**: 75 s by default (a vanished laptop lingers that long, but a hidden tab whose timers are
   held back to once a minute stays). C8 would make it about 35 s with no page beats.

---

## Today's glue (for reference)

What works now, without any of the above: `server/PresenceServer.roc`, copied into the app's server
half by hand. The room is an actor; the actor publishes each numbered change on the room's `Live`
topic in its turn; a page's endpoint `events!` is `PresenceServer.stream(room, { key, meta })`
(key and metadata from the middleware's context); the page beats with a server function every 15 s
(`PresenceServer.join!`, which also rejoins a tab the room swept out), says it is typing with another
(`PresenceServer.typing!`), and `Presence.create_room!` takes the events. Checked in a scratch app
(rocx build, both halves type-checked, the native server and the wasm built, two pages in headless
Chromium): each member saw the other, a typing ping arrived and ran out, a closed tab's `Left` came
after the grace, and (over curl) a tab that beat once was swept out after the timeout.
