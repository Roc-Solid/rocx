## Presence on the server platform: a room as an actor, and the events a page follows it by
## (`PresenceServer`). A package that names the server platform, so that
## `roc check packages/presence/server/main.roc` checks it on its own. An app copies it in by hand
## for now: see ../README.md, and PROPOSALS.md.
package [PresenceServer] { pf: platform "../../../server/platform/main.roc", presence: "../main.roc" }
