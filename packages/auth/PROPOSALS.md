# packages/auth: what comes next

What isn't built, each with what it needs. The user chose the order (2026-11-24): links and
providers first, passwords next, passkeys later. Two-factor sign-in with an authenticator app came
in between (D-081, 2026-11-25).

## 1. Passwords

Not built. A password is kept as a slow, salted hash (Argon2id), which Roc can't compute fast enough
in the browser's or the server's Roc: the host does it, as one hosted function
(`Host.argon2id!(password, salt, params) => List(U8)`), with its twin in `native/core/src/hosted.rs`.
With it, the package adds `Auth.password!` (set or change one, signing out everywhere else) and a
`POST /auth/password` that checks an address and a password, a refusal the same whether the address
is known or not, and the guard's rate limit named in the README.

## 2. Passkeys (WebAuthn)

Later (the user's order). A passkey's signature is ECDSA on P-256. The server platform has P-256
since D-080 (`P256`, for packages/push), but only signing, ECDH and making a key pair (D-097): a
passkey needs a signature verified, the next primitive (`P256.verify!`, on ring's
`ECDSA_P256_SHA256_ASN1`, since WebAuthn writes its signatures in DER, not JWS's `r` and `s`).
With it: a registration ceremony and a sign-in ceremony, each a challenge kept for a few minutes and
a script the page loads (as push's is). A passkey could also be a second factor beside the
authenticator app (§5), on the same waiting sign-in and code page.

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

## 5. Two-factor sign-in's next steps (D-081 built the first)

- **A user's wrong codes counted across sign-ins**: built (`auth/0004_two_factor_misses`,
  `Rules.locked`): ten in a row, across sign-ins, turning it off and new recovery codes, and their
  codes are refused for a quarter of an hour. Left: telling the user by mail that it happened.
- **"Trust this browser for 30 days"**: a signed, per-browser cookie the code page sets, which
  skips the code on that browser. A common ask; it weakens the second factor on a stolen laptop.
- **Requiring it for some users in the package**: today `two_factor!` answers whether it is on and
  the app's own route refuses (the example's `/admin`). A middleware that sends such a user to set
  it up (`required_two_factor(who!)`) could follow if apps write the same check.
- **A session that says how it signed in** (`Session.second_factor : Bool`): a user who turns it on
  keeps the sessions they had; an admin's route could ask for a session that passed a code.

## 6. Roles' next steps (D-127 built the first)

- **Seats an organization pays for**: a reason with a value (`via: Seat(org)`), granted by the
  org's owners, and at most so many at once. The count and the grant must be one step (two owners
  at once can't both take the last seat): a row for the org that each grant changes first, so they
  take turns on every database, and the count read from the grants after it.
- **A gate in the package**: since D-132 a check is the app's own (`Policy.need` in a route, `can`
  in a folder's `+middleware.roc`), so a package middleware would save a folder three lines;
  only if apps write the same one.
- **An admin's page** (packages/admin, as its jobs page): a user's grants, given and ended there.
- **Roles on Turso**: the open grant is a partial unique index and an upsert on it; not tried on
  Turso yet.

## Open questions

None now. (Whether `rocx new` should list `Guard.rate_limit` on its sign-in endpoint was the last:
its app does, 5 a minute from each client and 5 an hour to each address, in
`templates/app/Middlewares.roc`.)
