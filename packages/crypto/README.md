# crypto

Hashes, MACs, key derivation and the encodings their bytes travel in, for Roc Solid apps: SHA-256,
HMAC-SHA256, HKDF-SHA256, Base64 and hexadecimal. It is plain Roc on no platform, so the server, a
page in the browser and an `expect` all run the same code.

The user guide is the docs site's [Crypto page](https://roc-solid.github.io/ecosystem/crypto); the
server platform's [crypto page](https://roc-solid.github.io/platform/crypto) shows it with the
platform's `Random` and `AesGcm`, for tokens, signed links and sealed secrets.

## Installing it

Name the package in the app's header, beside the platform:

```roc
app [program] { crypto: "../packages/crypto/main.roc", pf: platform "../server/platform/main.roc" }
```

Then import the modules you use:

```roc
import crypto.Base64
import crypto.Hkdf
import crypto.Hmac
import crypto.Sha256

digest = Sha256.hex(token.to_utf8())                                # 64 hex digits; Sha256.hash gives 32 bytes
key = Hkdf.sha256(secret, salt, "links".to_utf8(), 32)?             # Try(List(U8), [TooLong])
signature = Base64.url_encode(Hmac.sha256(key, message))            # a link's signature
Hmac.verify_sha256(key, message, Base64.url_decode(given) ?? [])    # compared in constant time
```

## API

| Module | Function | What it does |
|---|---|---|
| `Sha256` | `hash : List(U8) -> List(U8)` | The 32-byte digest. |
| | `hex : List(U8) -> Str` | The digest as 64 lowercase hex digits, as `sha256sum` and AWS SigV4 write it. |
| | `chunks : List(List(U8)) -> List(U8)` | The digest of the pieces one after another, without joining them first. |
| | `block_size : U64` | 64, the bytes SHA-256 works on at a time (HMAC pads its key to this). |
| `Hmac` | `sha256 : List(U8), List(U8) -> List(U8)` | The 32-byte HMAC-SHA256 of a message (second) under a key (first). |
| | `verify_sha256 : List(U8), List(U8), List(U8) -> Bool` | Whether a signature (third) is the HMAC of the message under the key, compared with `equal`. |
| | `equal : List(U8), List(U8) -> Bool` | Whether two byte lists are the same, in constant time (see below). |
| `Hkdf` | `sha256 : List(U8), List(U8), List(U8), U64 -> Try(List(U8), [TooLong])` | `length` bytes of key material from a key, a salt and an `info` (the key's purpose): `expand(extract(key, salt), info, length)`. At most 255 × 32 = 8160 bytes; more is `TooLong`. |
| | `extract : List(U8), List(U8) -> List(U8)` | The 32-byte pseudorandom key of a key and a salt. An empty salt means 32 zero bytes, as the RFC says. |
| | `expand : List(U8), List(U8), U64 -> Try(List(U8), [TooLong])` | `length` bytes from a pseudorandom key and `info`. |
| `Base64` | `encode : List(U8) -> Str` | The standard alphabet (`+`, `/`), padded with `=`. |
| | `encode_unpadded : List(U8) -> Str` | The standard alphabet, without padding. |
| | `url_encode : List(U8) -> Str` | The URL and filename alphabet (`-`, `_`), without padding: tokens in links. |
| | `url_encode_padded : List(U8) -> Str` | The URL alphabet, padded. |
| | `decode : Str -> Try(List(U8), [InvalidBase64])` | Standard Base64, padded or not. |
| | `url_decode : Str -> Try(List(U8), [InvalidBase64])` | URL-alphabet Base64, padded or not. |
| | `lines : List(U8) -> Str` | `encode`, in lines of 76 characters split by CRLF, as MIME wants a body. |
| `Hex` | `encode : List(U8) -> Str` | Two lowercase digits per byte. |
| | `decode : Str -> Try(List(U8), [InvalidHex])` | Either case; nothing else (no `0x`, no spaces). |

**Constant time.** `Hmac.equal` compares two lists of the same length to the end, whatever their
first difference, so the time it takes doesn't tell a forger how much of a signature was right.
Lists of different lengths are unequal at once: a signature's length is no secret.

**Strict decoding.** Each value has exactly one text: only the alphabet asked for, no spaces or line
breaks, padding either left out or exactly right, and the unused bits of the last character zero.

## How it is tested

Each module's `expect`s check it against published test vectors: NIST's SHA-256 examples (FIPS
180-4), every test case of RFC 4231 (HMAC), RFC 5869's SHA-256 cases (HKDF), and RFC 4648's (Base64,
hex). `roc test packages/crypto/main.roc` runs them (`just test-rocx` runs every package's). The
server platform's tests (`server/test/server.test.mjs`) also compare each module with Node's
`crypto`, through a running server. `Sha256` wraps Roc's builtin `Crypto.SHA256`.

## Used by

`packages/storage` (S3's signatures, and the app's signed URLs), `packages/push` (Web Push's HKDF and
base64url keys), `packages/email` (Base64 for SMTP sign-in and MIME bodies) and `packages/mcp`
(images, audio and blobs as Base64). Each names this package in its own header, so an app that uses
one of them doesn't have to name this one too.

## What isn't here

- Encryption and random bytes need the operating system, so they are the server platform's:
  `AesGcm` (AES-256-GCM, by the host) and `Random` (bytes from the system's secure generator). A key
  for `AesGcm` comes from `Random.bytes!(32)`, or from the app's secret through `Hkdf`.
- Password hashing (bcrypt, scrypt, Argon2): not yet. SHA-256 and HKDF are too fast for passwords.
- Public-key cryptography (ECDSA signatures, ECDH key exchange): not yet.
