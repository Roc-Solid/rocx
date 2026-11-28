# presence: proposals

What `packages/presence` still waits on: one platform question (C8) and the user's calls. What was
asked before and is built is listed first, so its letters still mean something.

## Built

- **The channels asks, C1 to C7 and C9 (D-020).** A page says things on its room's channel
  (`Endpoint.say!`, the route's `receive!`, over `POST /rocx/live/send`). Who is here comes first on
  each subscribe (`on_open!`'s messages). A tab joins and leaves with its subscription (`on_open!`,
  `on_close!`). A tab's id stays the same across reconnects and reloads. Who a subscriber is comes
  from the channel's check (`Channel.allow`), never the page. A subscriber that falls behind gets a
  resync, and a page that sees a gap asks for one (`Endpoint.resync!`). A cursor is latest-wins
  (`Endpoint.publish_latest!`). A channel's messages keep their order.
- **A page that drops the room leaves at once (D-057).** `on_close!` is told `Dropped` (the page
  unsubscribed while the tab stays) or `Gone` (the stream went). Presence quits at once on
  `Dropped` (`Room.quit`) and keeps the grace on `Gone`.
- **Server-only modules in packages (D-033).** The package names the server platform for
  `PresenceServer`; `browser.roc` lists what the browser compiles.
- **S1, a room in memory only.** The room is kept in `Kv` (D-028), never in the database. Actors
  are no longer involved.
- **W1, W3 and R1 (D-055).** The pointer's place (`on:pointermove.point`, `create_pointer!`,
  `<LiveCursors on_move!>`); whether the page shows
  (`<Document on:visibilitychange.visible={here.visible!} />`, the app's line); the app's own
  `data : d` in `Wire.Meta(d)`, typed end to end. W2, a clock in the browser (`Time.now_millis!`),
  landed before.
- **A closed status and the page's own `data` (2026-11-26).** `Stack.Status` is `Online`, `Away`,
  `Busy` or `Offline`. The page changes its member's `data` (`Update(d)`, `join!`'s `update!`), up to
  `PresenceServer.max_data`.

---

## C8. The stream as the heartbeat

**The host's half is built (D-020).** `/rocx/live` writes `: beat` every `--live-beat-ms` (15 s).
A connection that leaves what the server sent unacknowledged for 20 s is dropped (Linux's
`TCP_USER_TIMEOUT`, macOS's `TCP_RXT_CONNDROPTIME`). So a vanished tab's subscriptions end about
20 s after a beat, and `on_close!` is told `Gone`. The operating system acknowledges for a hidden
tab, so a hidden tab stays.

**Presence's half is open.** A page still says it is here every 15 s (`Here`), and the room sweeps
out a tab unheard for 75 s. The timeout is that long because a browser may hold a hidden tab's
timers back to once a minute. With the host's half, the page's beats could go.

**Options.**

1. Keep the page's beats (today). A POST per tab every 15 s; the 75 s timeout backs up a missed
   `on_close!`.
2. No page beats. A tab stays until its `on_close!`; `Room`'s timeout becomes a long backstop
   (minutes). A status and `data` are still said when they change. What goes: a beat's saying of
   `data` again when the room has other data for the member (it swept the tab out, or another of
   the member's tabs said its own).
3. Beats only as a backstop: one a minute, and a timeout to match.

**Recommended.** 2. **Depends on it.** `Room.defaults`, `Room.beat_every`, `join!`'s beat.
**Undo.** Turn the beat back on.

---

## Open questions (for the user)

1. **"Who's viewing this page."** Should a page's room be its path by default (a store that reads
   `Router.location!`), or should the app always name the room? The app names it today, with a
   route of its own. A package adds no routes (D-116), so a room by path would still need one route
   file in the app, its param the page's path.
2. **The timeout** (C8). Keep the page's beats and the 75 s timeout, or rely on the stream's end?
