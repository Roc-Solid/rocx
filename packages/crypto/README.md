# crypto

Hashes, MACs, key derivation and the encodings their bytes travel in, for Roc Solid apps: SHA-256,
HMAC-SHA256, HKDF-SHA256, Base64 and hexadecimal. Plain Roc on no platform, so a server, a page in
the browser and an `expect` all use the same code.

```roc
import crypto.Base64
import crypto.Hkdf
import crypto.Hmac
import crypto.Sha256

digest = Sha256.hex(token.to_utf8())                                # 64 hex digits; Sha256.hash: 32 bytes
key = Hkdf.sha256(secret, salt, "links".to_utf8(), 32)?             # Try(List(U8), [TooLong])
signature = Base64.url_encode(Hmac.sha256(key, message))            # a link's signature
Hmac.verify_sha256(key, message, Base64.url_decode(given) ?? [])     # compared in constant time
```

## Installing

Name the package in the app's header, beside the platform:

```roc
app [program] { pf: platform "../server/platform/main.roc", crypto: "../packages/crypto/main.roc" }
```

## Modules

| Module | What it does |
|---|---|
| `Sha256` | `hash` (32 bytes), `hex` (64 lowercase digits), `chunks` (the digest of pieces, without joining them); on Roc's builtin `Crypto.SHA256` |
| `Hmac` | `sha256(key, message)`; `verify_sha256(key, message, signature)`; `equal`, which compares two byte lists to their end whatever their first difference, so the time taken doesn't tell a forger how much of a signature was right |
| `Hkdf` | `sha256(key, salt, info, length)`, and its two steps, `extract` and `expand`: keys of their own from one secret (a link-signing key from `APP_SECRET`, say) |
| `Base64` | `encode` / `decode` (standard, padded), `encode_unpadded`, `url_encode` / `url_decode` (the URL alphabet, unpadded: tokens in links), `url_encode_padded`, `lines` (MIME's 76-character lines) |
| `Hex` | `encode` (lowercase), `decode` (either case) |

Decoding is strict, so one text means one value: only the alphabet asked for, no spaces or line
breaks, padding left out or exactly right, and the unused bits of the last character zero.

## Checked against

Each module's `expect`s hold it to its published vectors: NIST's SHA-256 examples (FIPS 180-4), every
test case of RFC 4231 (HMAC), RFC 5869's SHA-256 cases (HKDF), and RFC 4648's (Base64, hex).
`roc test packages/crypto/main.roc` runs them; `server/test/server.test.mjs` also checks them
against Node's `crypto` from a running server.

## Used by

`packages/s3` (its signatures), `packages/push` (Web Push's HKDF and base64url keys) and
`packages/mcp` (images, audio and blobs as Base64): each names this package itself, so an app that
names one of them doesn't name this one too.

## Not here

What needs the host stays on the server platform: `AesGcm` (AES-256-GCM, `ring`'s) and `Random`
(bytes from the system's generator). A key for `AesGcm` comes from `Random.bytes!(32)`, or from the
app's secret through `Hkdf`.
