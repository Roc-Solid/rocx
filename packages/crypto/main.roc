## Crypto: hashes, MACs, key derivation, and the encodings their bytes travel in. SHA-256
## (`Sha256`), HMAC-SHA256 (`Hmac`, with a comparison that takes the same time however much
## matched), HKDF-SHA256 (`Hkdf`), Base64 in both alphabets (`Base64`) and hexadecimal (`Hex`).
## It is plain Roc, on no platform, so a server, a page in the browser and an `expect` use the same
## code, and each module is checked against its RFC's own test vectors. What needs the host stays
## on the server platform: `AesGcm` (encryption), `P256` (ES256 signatures, ECDH) and `Random`
## (bytes from the system). See README.md.
package [Base64, Hex, Hkdf, Hmac, Sha256] {}
