## Presence: who is in a room right now. The room's state machine (`Room`: join, a change of
## metadata, a heartbeat, leave, and the sweep that times out who vanished), a browser's copy of it
## (`Mirror`, which follows a snapshot and the numbered changes after it, and knows when it missed
## one), the changes between two lists of who is here (`Diff`), a sender's rate limit that keeps the
## latest value (`Throttle`, for cursors), cursors (`Cursors`), who is typing (`Typing`, and a
## page's own side of it, `Typist`), an avatar stack's arithmetic (`Stack`), and what a room's
## channel carries (`Wire`): plain Roc, on no platform, so the server and the browser run the same
## code, and its tests run on a clock they are given. And the server's side, a room on a route's
## channel (`PresenceServer`: its hooks, the room kept in `Kv`).
##
## It names the server platform, for `PresenceServer`; the browser's half sees the modules both
## halves can compile (`browser.roc`). The components (`<AvatarStack>`, `<TypingIndicator>`,
## `<LiveCursors>`) and the browser's stores (`Presence.join!`, and the stores under it) are in
## `components/`: `rocx build` copies them into each app that names this package. See README.md.
package [Cursors, Diff, Mirror, PresenceServer, Room, Stack, Throttle, Typing, Typist, Wire] { pf: platform "../../server/platform/main.roc" }
