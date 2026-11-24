# qr

QR codes in plain Roc: text in, a code out, drawn as SVG. A page shows one with `<QrCode>`, the
server draws one into an email or an image of its own (`Qr.svg`), and rocx prints one in the
terminal (`rocx dev --android --lan`'s, for a phone on Wi-Fi). It is plain Roc, on no platform: the
browser, the server and a test run the same code.

## Installing

Name it in the app's header, then import what you use:

```roc
app [program] { pf: platform "../server/platform/main.roc", qr: "../packages/qr/main.roc" }
```

```roc
import qr.Qr
import qr.QrCode
```

`rocx build` copies `components/QrCode.rocx` into the app (`Generated/qr/`), since a package can't
import a platform's `Html` for the server and the browser at once.

## A code on a page

```rocx
<QrCode text={"https://example.com/join/${room!()}"} label="Join the room" class="join-code" />
```

| Prop | What |
|---|---|
| `text` | What the code says: a URL, mostly. A getter, as every value prop is: the code follows it. |
| `level` | How much of the code may be damaged and still read: `Low` (about 7%), `Medium` (15%, unless it says), `Quartile` (25%) or `High` (30%). The more, the bigger the code. |
| `label` | What it is, for screen readers. "QR code" unless it says. |
| `class` | Classes for the `<svg>`, beside `qr-code`. |

It is an `<svg>` as wide as its box, square, black on white with a quiet zone of four modules
around it, which readers need: give its box a width. The colours are CSS (`.qr-light`, `.qr-dark`),
but keep them dark on light, with contrast: most readers read nothing else. Text too long for a code
(more than `Qr.capacity(level)` bytes) shows an empty code whose label says so.

## A code anywhere else

```roc
match Qr.encode("https://example.com", Medium) {
    Ok(code) => Qr.svg(code)          # an SVG document: an email's image, a file
    Err(TooLong) => …
}
```

- `Qr.encode(text, level)`: the code (`{ size, dark }`: its side in modules and its modules row by
  row, dark `Bool.True`), at the smallest version (1 to 40) that holds the text's UTF-8 bytes; or
  `Err(TooLong)`.
- `Qr.svg(code)`: an SVG document, a module a unit, the quiet zone included.
- `Qr.path(code)` and `Qr.view_box(code)`: the dark modules as one path's `d`, and its `viewBox`, for
  markup of your own (what `<QrCode>` draws).
- `Qr.terminal(code)`: for a terminal, two rows of modules a line, coloured black on white by ANSI
  escapes whatever the terminal's colours.
- `Qr.pbm(code)`: a PBM image, a module a pixel.
- `Qr.is_dark(code, x, y)`, `Qr.capacity(level)`: a module, and the most bytes a level holds
  (2,953 at `Low`, 2,331 at `Medium`, 1,663 at `Quartile`, 1,273 at `High`).

## How it is made

ISO/IEC 18004, after Project Nayuki's reference encoder: byte mode (the text's UTF-8 bytes), the
standard's error correction blocks for each version and level (Reed–Solomon over GF(256)), the
finder, timing and alignment patterns, version information from version 7, and of the eight masks
the one with the lowest penalty by the standard's four rules.

## Tests

`roc test packages/qr/main.roc`: the standard's numbers (format and version bits, capacities, the
alignment patterns' places, the generator). `packages/qr/test/decode.sh` reads back with a reader
(zbar, from Nix) a code at every version and level, each as full as it can be: 160 codes, every one
read back as its text. Run it after a change to the encoder.
