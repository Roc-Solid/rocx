## QR codes: `Qr.encode(text, level)` makes a code's modules in plain Roc (byte mode, versions 1 to
## 40, the four error correction levels), and draws it as SVG (`svg`, or `path` and `view_box` for
## markup of your own), for a terminal (`terminal`) or as a PBM image (`pbm`). It is plain Roc, on
## no platform, so a page in the browser, the server (an email's image) and rocx itself (`rocx dev
## --android --lan`'s code for a phone on Wi-Fi) use the same code.
##
## The component (`<QrCode>`) is in `components/`: `rocx generate` (and so `rocx dev` and `rocx
## build`) copies it into each app that names this package, since a package can't import a
## platform's `Html` for both apps at once. See README.md.
package [Qr] {}
