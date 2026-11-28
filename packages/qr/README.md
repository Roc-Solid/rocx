# qr

QR codes in plain Roc: text in, a code out, drawn as SVG. A page shows one with `<QrCode>`, the
server draws one into an email or a file with `Qr.svg`, and rocx prints one in the terminal. The
encoder runs on no platform, so the browser, the server, rocx and a test all run the same code.
The user guide, with a live demo, is the docs site's
[QR codes page](https://roc-solid.github.io/ecosystem/qr); this file is the reference.

## Installing it

Name the package in the app's header, then import what you use:

```roc
app [program] { pf: platform "../server/platform/main.roc", qr: "../packages/qr/main.roc" }
```

```roc
import qr.Qr       # the encoder and its drawings
import qr.QrCode   # the component, in a .rocx file
```

The package's `main.roc` exposes `Qr` alone. The component is `components/QrCode.rocx`:
`rocx generate` (which `rocx dev` and `rocx build` run first) copies it into each app that names
the package, as `Generated/qr/QrCode.roc`, since a package can't import the platform's `Html` for
the server and the browser at once. It is not a plugin: there is nothing to register.

## A code on a page

```rocx
<QrCode text={"https://example.com/join/${room!()}"} label="Join the room" class="join-code" />
```

`QrCode` is an effectful component (`view!`). It encodes the text in a memo, so the code follows
`text` and `level` as they change.

| Prop | Type | Default | What it is |
|---|---|---|---|
| `text` | `Str` | (required) | What the code says: usually a URL. A getter, as every value prop of an effectful component is. |
| `level` | `Qr.Level` | `Medium` | How much of the code may be damaged and still read: `Low` (about 7%), `Medium` (15%), `Quartile` (25%) or `High` (30%). The higher, the bigger the code. |
| `label` | `Str` | `"QR code"` | What the code is, for screen readers (`aria-label`, with `role="img"`). |
| `class` | `Str` | `""` | More classes for the `<svg>`, besides `qr-code`. |

It renders an `<svg class="qr-code">` that is square and as wide as its box (give the box a width),
with a `<rect class="qr-light">` behind a `<path class="qr-dark">`. It is black on white with a
quiet zone of four modules around it, which readers need. The colours are CSS, but keep them dark on
light with good contrast: most readers read nothing else.

Text longer than `Qr.capacity(level)` bytes draws an empty code, and the label becomes
`"<label>: the text is too long for a QR code"`.

## A code anywhere else

```roc
match Qr.encode("https://example.com", Medium) {
	Ok(code) => Qr.svg(code)   # an SVG document: an email's image, a file
	Err(TooLong) => …
}
```

| Function | What it does |
|---|---|
| `encode : Str, Level -> Try(Code, [TooLong])` | The text's UTF-8 bytes as a code at that level, at the smallest version (1 to 40) that holds them; or `Err(TooLong)`. |
| `svg : Code -> Str` | An SVG document, one unit per module, the quiet zone included, black on white. |
| `path : Code -> Str` and `view_box : Code -> Str` | The dark modules as one SVG path's `d` (each row's run of dark modules a rectangle), and its `viewBox` (`0 0 <side> <side>`, quiet zone included), for an `<svg>` of your own. `<QrCode>` draws these. |
| `terminal : Code -> Str` | Text for a terminal: two rows of modules per line (half blocks), coloured black on bright white by ANSI escapes whatever the terminal's own colours, quiet zone included. |
| `pbm : Code -> Str` | A PBM image (`P1`), one pixel per module, quiet zone included. The test reads these back. |
| `is_dark : Code, U64, U64 -> Bool` | Whether the module at column `x`, row `y` is dark; outside the code (the quiet zone), `Bool.False`. |
| `capacity : Level -> U64` | The most bytes a code holds at that level: 2,953 at `Low`, 2,331 at `Medium`, 1,663 at `Quartile`, 1,273 at `High` (version 40). |

The types:

- `Level : [Low, Medium, Quartile, High]`
- `Code : { size : U64, dark : List(Bool) }`: its side in modules, and its modules row by row,
  `Bool.True` for dark. The quiet zone isn't in it; the drawing functions add it.

`Qr` also exposes the encoder's steps (`version_for`, `bytes_held` and the rest), which the tests
and the site's demo use; an app needs only the functions above.

rocx itself uses `Qr.terminal`: `rocx dev --android --lan` prints a code a phone on the same Wi-Fi
scans, and `rocx qr <text>` prints a code of any text (`rocx qr --pbm <text>` writes a PBM).

## How it is made

The encoder follows ISO/IEC 18004, step by step as Project Nayuki's reference encoder takes them:

1. Byte mode: the text's UTF-8 bytes, at the smallest version that holds them.
2. Reed–Solomon error correction over GF(256), in the blocks the standard sets for each version and
   level, interleaved.
3. The finder, timing and alignment patterns, and version information from version 7 on.
4. Each of the eight masks, scored by the standard's four penalty rules; the lowest wins.

A version is 21 modules a side at version 1, and 4 more for each version after it, up to 177 at
version 40.

## Tests

- `roc test packages/qr/main.roc`: the standard's numbers (format and version bits, capacities,
  where the alignment patterns go, the generator polynomial).
- `packages/qr/test/decode.sh`: builds `test/codes.roc`, which makes a code at every version and
  level, each filled to capacity, and has a reader (zbar, from Nix) read each back. All 160 codes
  read back as their text. Run it after a change to the encoder.

## Not yet

Byte mode is the only mode (numeric and alphanumeric modes would fit digits or upper-case text in a
smaller code); the level is never raised for free when the version has room; no logo in the middle;
no Kanji, ECI, structured append or micro QR codes. `PROPOSALS.md` sketches each.
