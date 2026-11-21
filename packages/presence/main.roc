## Presence: who is in a room right now. The room's state machine (`Room`: join, a change of
## metadata, a heartbeat, leave, and the sweep that times out who vanished), a browser's copy of it
## (`Mirror`, which follows a snapshot and the numbered changes after it, and knows when it missed
## one), the changes between two lists of who is here (`Diff`), a sender's rate limit that keeps the
## latest value (`Throttle`, for cursors), cursors (`Cursors`), who is typing (`Typing`, and a
## page's own side of it, `Typist`), an avatar stack's arithmetic (`Stack`), and what a room's
## stream sends (`Wire`). It is plain Roc, on no platform: the server's stream and the browser's
## components run the same code, and its tests run on a clock they are given.
##
## The components (`<AvatarStack>`, `<TypingIndicator>`, `<LiveCursors>`) and the browser's stores
## (`Presence.create_room!` and the others) are in `components/`: `rocx build` copies them into each
## app that names this package. The server's side (`server/PresenceServer.roc`) imports the server's
## platform, so an app copies it in for now. See README.md and PROPOSALS.md.
package [Cursors, Diff, Mirror, Room, Stack, Throttle, Typing, Typist, Wire] {}
