## Virtual lists: a list of any length that renders only the rows that show. `Rows` is the
## arithmetic (which rows a scrolled box shows); it is plain Roc, on no platform.
##
## The component (`<VirtualList>`) is in `components/`: `rocx generate` copies it into each app that
## names this package, since a package can't import a platform's `Html` for both apps at once. It is
## made of the platform's `<Repeat>` and `on:viewport`. See README.md.
package [Rows] {}
