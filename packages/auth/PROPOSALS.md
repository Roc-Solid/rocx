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

## 4. What moving the apps onto it found (done, D-077)

Moving notes, uptime, plate, tasks, board and the private app onto the package (2026-11-24) found
some friction; the user wanted all of it gone (2026-11-25), and it is: `Auth.signed_out!` (what
`required` answers a signed-out request), the `refusal` option (its 401's words), `required_with`
(a step that reads the app's user, and may refuse or answer itself), `renew!` (for an app's own
middleware), `path!` (where a sign-in may go after), `switch!` (a person picked anew, one
`Set-Cookie`), an expired link keeping `then`, `SignInError` (the codes' sentences, on no platform),
a note on `sign_out_everywhere!` and this browser's cookie, packages/mcp's `Auth` renamed `Bearer`,
and nested transactions (D-076). And one more the user asked for: impersonation
(`impersonate!`, `stop_impersonating!`, `Session.real_user`).

## Open questions

- Should `rocx new` list `Guard.rate_limit` on its sign-in endpoint by default? (Recommended: yes, 5
  an hour per address and 20 a minute per client.)
