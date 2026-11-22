## Presence as the browser's half of an app sees it: the modules that use no platform (the room's
## logic, a page's copy of it, typing, cursors, avatar stacks, the wire), which the components and a
## page use (`rocx build --client` names this header there). `main.roc` has these and the server's
## side (`PresenceServer`).
package [Cursors, Diff, Mirror, Room, Stack, Throttle, Typing, Typist, Wire] {}
