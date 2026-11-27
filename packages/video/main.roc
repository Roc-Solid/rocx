## Video: motion made of an app's own components, played in a page or rendered to a file. A
## composition is a component that reads the frame (`Player.clock!`) and shows what that moment
## looks like; `<Player>` plays it live, and `rocx render` films it, a frame at a time, into an MP4
## or a WebM. When a component changes, its video does too.
##
## `Timeline` is the arithmetic of a moment: how far along a span a frame is, eased, sprung, or
## through keyframes; it is plain Roc, on no platform. The components (`<Player>`, `<Sequence>`)
## are in `components/`: `rocx build` copies them into each app that names this package, since a
## package can't import a platform's `Html` for both of an app's halves at once. See README.md.
package [Timeline] {}
