# packages/auth: what comes next

What isn't built, each with what it needs. The user chose the order (2026-11-24): links and
providers first, passwords next, passkeys later.

## 1. Passwords

Not built. A password is kept as a slow, salted hash (Argon2id), which Roc can't compute fast enough
in the browser's or the server's Roc: the host does it, as one hosted function
(`Host.argon2id!(password, salt, params) => List(U8)`), with its twin in `native/core/src/hosted.rs`.
With it, the package adds `Auth.password!` (set or change one, signing out everywhere else) and a
`POST /auth/password` that checks an address and a password, a refusal the same whether the address
is known or not, and the guard's rate limit named in the README.

## 2. Passkeys (WebAuthn)

Not built. A passkey's signature is ECDSA on P-256, which the host doesn't have yet (packages/push
waits on the same: PROPOSALS.md there). With it: a registration ceremony and a sign-in ceremony,
each a challenge kept for a few minutes and a script the page loads (as push's is).

## 3. A provider's endpoints from its issuer

`Auth.oidc` takes the endpoints. OpenID Connect's discovery (`<issuer>/.well-known/openid-configuration`)
could find them at start, and its keys (`jwks_uri`) would let the ID token's signature be checked too,
though the code flow doesn't need it (Core 1.0, 3.1.3.7).

## 4. Moving the apps onto it

examples/notes signs in with links of its own; the private app with Google, its own sessions and its
own `__Host-` cookies. Each can move: `admit!` for what it does after an address is verified (notes:
a notebook; the private app: its access requests and invites), `link_page` for notes' page that asks
first, and `sign_out_everywhere!` for notes' "sign out everywhere".

## Open questions

- Should `rocx new` list `Guard.rate_limit` on its sign-in endpoint by default? (Recommended: yes, 5
  an hour per address and 20 a minute per client.)
