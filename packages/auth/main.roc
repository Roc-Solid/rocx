## Auth: sign-in for Roc Solid apps, as a plugin (D-072). `Auth` is the plugin, its endpoints, its
## middleware and the functions an app calls; `AuthStore` its statements, the same on SQLite and on
## Postgres (`migrations/`); `Rules` what is plain Roc, with its `expect`s (where a sign-in may go
## after, tokens and their hashes, the cookies, the OAuth state, PKCE, an ID token's claims,
## GitHub's answers, recovery codes); `Totp` authenticator apps' codes (RFC 6238, D-081). It names
## the server platform, so only the server's half of an app sees it.
## README.md is the reference; PROPOSALS.md says what comes next.
package [Auth, AuthStore, Rules, SignInError, Totp] { crypto: "../crypto/main.roc", pf: platform "../../server/platform/main.roc" }
