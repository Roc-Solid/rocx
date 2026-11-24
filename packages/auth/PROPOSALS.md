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

## 4. What moving the apps onto it found (2026-11-24)

Done: notes (links, `link_page`), uptime and plate (their own password, then `Auth.sign_in!`), tasks
and board (a person picked, kept as a session), and the private app (Google, the dev sign-in, its
access requests and invites in `admit!`). journal's reader and quiz's visitor stay cookies of their
own (an anonymous id, no one signing in). Each move came with friction, none of it blocking; each
of these is small:

- **What `required` answers a signed-out request, public** (`Auth.signed_out!(request)`), so an app's
  next middleware (board's, notes', which load the app's user and may find none) answers the same.
- **The 401's words** as an option (`refusal`): board said "Join first", notes' API sends
  `www-authenticate`. Today it is always "Sign in first."
- **`required` with an effectful step** (`required_with!(load!)`: the session to the app's user, or
  a refusal), so loading the user isn't a second middleware.
- **Renewing from an app's own middleware** (`Auth.renew!(request, session, answer)`): notes' `api`
  reads `Auth.session!` and so never keeps a session going.
- **`Auth.path!(then)`**: the plugin's rule for where a sign-in may go after (its `home`), for an
  app's own way in (uptime and plate import `auth.Rules` for it now).
- **Switching person** (`Auth.switch!(request, answer, user)`): tasks and board end the old session
  and start a new one, which sends two `Set-Cookie`s for one name (browsers apply them in order).
- **A failed link keeps `then`** (`/sign-in?error=link&then=…`).
- **The error codes' words in a module with no platform** (`browser.roc`, as packages/push has), so a
  sign-in page that runs in the browser needn't write them again (the example's `Problem`, notes'
  `problem_of`, the private app's login endpoint).
- **`sign_out_everywhere!` leaves this browser's cookie**: say so, or take the request too.
- **Two modules named `Auth`** (packages/mcp's reads a bearer token): an app with both aliases one
  (`import mcp.Auth as McpAuth`). Renaming mcp's (`Bearer`) would end that.
- **Nested transactions.** `admit!` runs in a transaction, and an app's helper that opens its own
  (`Db.transaction!` inside it) fails: they don't nest. The private app's `Access.request!` had to
  stop opening one. A platform change (D-0xx): an inner `Db.transaction!` as a savepoint (SQLite
  and Postgres have them; Turso's MVCC to check).

## Open questions

- Should `rocx new` list `Guard.rate_limit` on its sign-in endpoint by default? (Recommended: yes, 5
  an hour per address and 20 a minute per client.)
