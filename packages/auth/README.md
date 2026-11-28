# auth

Sign-in for Roc Solid apps, as a plugin (D-072): by a link mailed to an address, or at a provider
(Google, GitHub, any OpenID Connect one), and for those who turn it on, a code from an authenticator
app after that (two-factor sign-in, D-081). What a user holds, and why, is `Roles` (D-127): the
app's own tags, granted, revoked and kept as a history. Sessions are kept in the app's database (Postgres,
SQLite or Turso), as their token's hash. Middleware hands the signed-in user on to the routes.

The package has no pages and no routes of its own. Its steps (a mailed link, a provider and back,
the code, signing out, the dev sign-in) are handlers the app's route files call (D-116); the app's
sign-in page posts to them and links to them, the app mails the links (packages/email), and the
app's `admit!`, given to those routes, says who gets in and which of its users they are.
What the package does is the part that is easy to get wrong: tokens, their hashes, their expiry and
single use, cookies, OAuth's state, PKCE and nonce, the ID token's checks, where a sign-in may
send the browser after, and authenticator codes (sealed secrets, a code good once, recovery codes,
a limit on wrong codes).

The docs site's page, `/ecosystem/auth`, is the guide; this is the reference. `example/` is an app
that uses all of it, and its tests (`example/test`) run it on SQLite and on Postgres.

## Installing it

1. Name the package in the app's header (it names the server platform, so only the server's half
   of an app sees it), and list its plugin (its tables and settings) with the app's providers:

   ```roc
   app [program] { auth: "../packages/auth/main.roc", email: "../packages/email/main.roc", pf: platform "../server/platform/main.roc" }

   program = App.program({
       init!: |_started| Ok({}),
       plugins: [
           Email.plugin({ from: "Acme <hello@example.com>" }),
           Auth.plugin({ providers: Accounts.providers, link_page: "/sign-in/link" }),
       ],
       database: Sqlite("data/app.db"),
   })
   ```

2. In a module of the app's that main.roc and the routes both import (`Accounts.roc`), write the
   providers and `admit!`: given who is signing in (`Auth.Identity`), the id of their user, or why
   not. `Auth.user_for!` finds the user, or makes one ([Users](#users)):

   ```roc
   providers : List(Auth.Provider)
   providers = [Auth.google, Auth.github]

   admit! : Auth.Identity => Try(Str, Str)
   admit! = |identity|
       match Auth.user_for!(identity) {
           Ok(user) => Ok(user)                                                  # their id: a version 7 UUID
           Err(NoAddress) => Err("${identity.provider} didn't give a verified address.")
           Err(DbErr(why)) | Err(BadRow(why)) => Err("Signing in failed: ${why}")
       }
   ```

3. Add a route file for each step the app uses (D-116), under `routes/auth/` (the plugin's `at`),
   in no folder whose middleware turns a signed-out request away: these are how one signs in.
   Each is one line, calling its handler ([The routes](#the-routes)):

   ```roc
   # routes/auth/[provider]/callback/+server.roc
   import auth.Auth
   import ../../../../Accounts

   respond! = |{ request, params, .. }| Auth.callback_route!(request, Accounts.providers, params.provider, Accounts.admit!)
   ```

4. Put the middleware around the routes that need a signed-in user: a `+middleware.roc` in their
   directory guards every page, endpoint and channel in it and below it (a group, `(members)/`,
   adds nothing to their paths):

   ```roc
   # Middlewares.roc
   signed_in : Middleware({}, { user : Str })
   signed_in = Auth.required(|{}, session| { user: session.user })

   # routes/(members)/+middleware.roc
   middleware = Middlewares.signed_in
   ```

5. Write the sign-in page: a form whose endpoint calls `Auth.link!` and mails the URL, a link per
   provider (`Auth.providers!`), and, with `link_page`, the page a mailed link opens.

## The plugin's options

```roc
Auth.Options := {
    at : Str ?? "/auth",                       # where the app's route files for its steps are (routes/auth/)
    sign_in : Str ?? "/sign-in",               # the app's sign-in page
    home : Str ?? "/",                         # where a sign-in goes when it wasn't going anywhere
    providers : List(Auth.Provider) ?? [],     # where else one may sign in: the list the provider routes get too
    session_ms : U64 ?? 2_592_000_000,         # how long a session lasts (30 days)
    link_ms : U64 ?? 900_000,                  # how long a mailed link is good for (15 minutes)
    link_page : Str ?? "",                     # the app's page a mailed link opens ("": /auth/link)
    cookie : Str ?? "session",                 # the session cookie's name
    refusal : Str ?? "Sign in first.",         # the words of required's 401
    two_factor : Bool ?? Bool.False,           # may users turn on two-factor sign-in (below)
    code_page : Str ?? "/sign-in/code",        # the app's page a sign-in waiting for its code goes to
    issuer : Str ?? "",                        # the name authenticator apps show ("": the public URL's host)
    key_env : Str ?? "APP_SECRET",             # the app's secret, which the sealing key is derived from
}
```

`at` is where the app put its route files: the plugin makes its links (a mailed link's URL) and a
provider's redirect URI with it. It doesn't move the routes; the files' folder does. Keep
`providers` in a module the provider routes import too (`Accounts.providers`), so both see one list.

An app that checks a password of its own, or lets people pick who they are, has no route for a
link, a provider or the dev sign-in, so nobody signs in that way: it starts sessions with
`Auth.sign_in!` and uses the rest (the middleware, signing out, the sessions' table).

`admit!` is given to the routes that sign someone in (`callback_route!`, `link_route!`,
`dev_route!`). It runs inside the transaction that starts the session, with the identity's row.
What it writes commits with the session, or with its refusal: a new user's row and a welcome job it
queues when it lets someone in, a waiting list's row when it turns them away for now. A database
error rolls all of it back. Keep anything slow (a fetch) out of it. A helper of the app's that
opens its own `Db.transaction!` is fine inside `admit!`: it becomes a level of the sign-in's
transaction (a savepoint, D-076), whose `Err` undoes only what the helper wrote. On Turso, a
transaction that loses to another's write runs again, and `admit!` with it.

## Signing in

**By a mailed link.** `Auth.link!(email, then)` keeps a link (its token's hash, the address, where it
goes after, until when) and gives the URL to mail. The app sends it, as it likes. A link works once,
for `link_ms`.

- With `link_page`, the URL opens the app's page, which shows whom it signs in
  (`Auth.link_for!(token)`, which doesn't use it) and posts the token to `/auth/link` from a button.
  A mail scanner that opens every link in a message then can't use one up.
- Without it, the URL is `/auth/link?token=…`, and opening it signs in.

**At a provider.** The app's button links to `/auth/<provider>?then=…`. `provider_route!` keeps a
state, a PKCE verifier and a nonce in a cookie for ten minutes, and sends the browser to the provider.
Back at `/auth/<provider>/callback`, the state must be the one the browser kept. The code is traded
at the provider's token endpoint (with the verifier and the client's secret), and who signed in is
read: from the ID token (OpenID Connect: its issuer, audience, expiry and nonce checked; its address
taken only when the provider says it is verified), or from GitHub's API (the user, and their
primary verified address).

**Under `--dev`.** `POST /auth/dev` with an `email` signs that address in, as a link would. Without
`--dev` it answers 404, as if there were no such route. `Auth.dev_sign_in!` says whether it is
open, for the page.

**The app's own way.** `Auth.sign_in!(answer, user)` starts a session for a user the app has
decided on itself (a password it checked, a person picked from a list) and sets its cookie on
`answer`.

The first three ways end the same: the identity (`provider`, `subject`) is looked up, `admit!` is asked, the
identity is recorded as the user's, a session starts, and the browser goes on to `then` with the
session cookie. `then` is a path of this site, or `home`: never another site.

## Who is signing in

```roc
Auth.Identity : { provider : Str, subject : Str, email : Str, name : Str, user : [New, Known(Str)], then : Str }
```

| Field | Is |
| --- | --- |
| `provider` | `"email"` for a link or the dev sign-in, else the provider's name (`"google"`) |
| `subject` | who they are there: the address for `"email"`, the provider's own id for them otherwise |
| `email` | their address, lower-cased; `""` when the provider has none it says is verified |
| `name` | their name, or `""` |
| `user` | `Known(user)`: the app's user this identity signed in as before; `New` otherwise |
| `then` | where the sign-in goes after (a path of this site): an invite's page, say, which `admit!` may act on |

An identity that signed in before is `Known`, even if its address changed since. A new one is the
app's to place: the user with that address, a new user (both `Auth.user_for!`), or a refusal
(`Err("why")`, shown on the sign-in page).

## Users

```roc
Auth.user_for! : Auth.Identity => Try(Str, [NoAddress, DbErr(Str), BadRow(Str), ..])
Auth.user! : Str => Try(Auth.User, [NotFound, DbErr(Str), BadRow(Str), ..])            # by id
Auth.user_by_email! : Str => Try(Auth.User, [NotFound, DbErr(Str), BadRow(Str), ..])   # by address
Auth.user_with_address! : Str => Try(Str, [NotAnAddress, DbErr(Str), BadRow(Str), ..]) # made if none
Auth.forget! : Str => Try({}, [DbErr(Str), ..])                                          # the user is gone

Auth.User : { id : Str, email : Str, created_ms : I64 }
```

The package keeps the app's users (D-134), a row each in `auth_users`: an id, the address as it is
now, and when they were made. `user_for!`, called from `admit!`, gives the id of the user an
identity is:

- **An identity that signed in before** (`Known`) is its user. When the provider gives another
  address, the user's becomes it, unless another user has it; their sign-ins by a mailed link to the
  old address end then, as an address given up may be someone else's later.
- **A new identity** is the user with its address (signed in another way before: a mailed link, or
  another provider with the same verified address), else a new user. A new user's id is a version 7
  UUID (crypto's `Uuid`): text of 36 characters that sorts by when it was made.
- **No verified address** (a provider that gave none): `NoAddress`, for `admit!` to refuse.

**Someone named before they sign in** (an invitation to their address, an admin letting them in
ahead, a test account the app's own link signs in as with `sign_in!`) is `user_with_address!(email)`:
the user with that address, made if there is none. Their first sign-in with it finds them.

It is part of the sign-in's transaction, so the user it made stays whether `admit!` then lets them
in or refuses them (call it after a refusal of the app's own, if a refused person should leave no
user); a database error undoes it. An app whose ids came before the package kept users (its own table, its own ids) keeps them:
a `Known` identity whose user has no row gets one, with that id.

**What else the app knows of a person** (a profile, their organizations, what they made) is the
app's, in its own tables, by the id. Its queries may join `auth_users` for an address; only the
package writes it. With the address in one place, a new one changes nothing else, and deleting a
person is `forget!` and the app's own rows.

**`forget!(id)`** deletes everything the package keeps for the user, in one transaction: their
sessions (an admin acting as them is themselves again), mailed links on their way to them, their
identities, authenticator, recovery codes, sign-ins waiting for a code, grants of roles
(`Roles.forget!`'s), and their row. What names them in others' rows (who granted a role) stays,
naming no one now. Signing in again later makes a new user. It is on the log (`auth: user
forgotten`).

## Sessions and middleware

```roc
Auth.Session : { user : Str, id : Str, expires_ms : I64, real_user : Str }
Auth.Signed : [SignedOut, SignedIn(Auth.Session)]

Auth.required : (ctx, Auth.Session -> out) -> Middleware(ctx, out)
Auth.required_with : (ctx, Auth.Session => Try(out, [SignedOut, Answer(Server.Response)])) -> Middleware(ctx, out)
Auth.optional : (ctx, Auth.Signed -> out) -> Middleware(ctx, out)
Auth.session! : Server.Request => Try(Auth.Session, [SignedOut])
Auth.signed_out! : Server.Request => Server.Response
Auth.renew! : Server.Request, Auth.Session, Server.Response => Server.Response
```

- `required` lets a signed-in request through, handing its session on (the function puts it in
  the context). A signed-out request is answered as `signed_out!` says: a page's GET goes to the
  sign-in page, `?then=` the page; anything else is a 401 with the plugin's `refusal`.
- `required_with` does the same with a step that may read the database: it turns the session into
  what the routes are handed (the app's user's row). `SignedOut` from it (the user is gone) ends the
  session and answers as a signed-out request; `Answer(response)` answers that and keeps the
  session (the database couldn't be read just then).
- `optional` hands on whether the request is signed in.
- All three keep a session used in its second half for as long again: its row and its cookie, at
  most once a half, so a request doesn't write. An app's own middleware that reads `session!` keeps
  it going with `renew!`, and answers a request it finds signed out after all with `signed_out!`.
- `user` is whom the session acts as, `real_user` who signed in: the same, but while an admin
  impersonates someone (below).

The cookie holds a random token (32 bytes). The table holds its SHA-256, so the table alone signs no
one in. It is `HttpOnly`, `SameSite=Lax`, for the whole site, and on HTTPS (the server's public URL)
`Secure` and named `__Host-session`, so no other site under the same domain can set it.

An app's own way in: `Auth.sign_in!(answer, user)` starts a session for a user it decided on (a
password it checked, a person picked from a list); `Auth.path!(then)` is where it may go after (a
path of this site, else `home`); `Auth.switch!(request, answer, user)` ends the request's session as
it starts the new one, in one `Set-Cookie` (a person picked anew). `sign_out_everywhere!(user)` ends
a user's sessions but leaves this browser's cookie, holding one that is gone: answer with
`sign_out!` too.

## Impersonation

An admin sees the app as someone sees it, to help them:

```roc
Auth.impersonate! : Server.Request, Str, U64 => Try({}, [SignedOut, DbErr(Str), ..])
Auth.stop_impersonating! : Server.Request => Try({}, [SignedOut, DbErr(Str), ..])
Auth.impersonating : Auth.Session -> Bool
```

`impersonate!(request, user, ms)` makes the request's session act as `user` for `ms`: from then on
its `user` is theirs, and every route sees them. The session stays the admin's: `real_user` is the
admin, signing out ends it, `sessions!` lists it under the admin with `acting_as`, and it goes back
to the admin when its time runs out or on `stop_impersonating!`. Each start and stop is on the log
with both users. Who may impersonate is the app's to decide before it calls (an admin's route, as
the example's `/impersonate`, which checks `real_user` against `ADMIN_EMAILS`). Use `real_user` to
record who did what, and to guard what only the person themselves may change (their sessions, their
address, their two-factor sign-in). An admin acting as someone isn't asked for their code: no one
signs in.

## Roles

What a user holds, and why (D-127): a role is one of the app's own tags, and so is the reason it is
held, so a misspelt one is the compiler's to catch. `Roles` is a module of its own (`import
auth.Roles`); its table comes with the plugin.

```roc
Role : [Pro, Admin]              # the app's
Via : [Paid, Trial, Gift]        # why someone holds one

Roles.grant!({ user, role: Pro, via: Gift, by: admin })                          # for good
Roles.grant!({ user, role: Pro, via: Paid, by: "stripe", ends: At(period_end) })
Roles.revoke!({ user, role: Pro, via: Gift, by: admin })                          # Bool: one lasted
Roles.has!(user, Pro)                                                            # Bool
Roles.current!(user)                                                             # [Pro]: what they hold now
Roles.of!(user)                                                                  # every grant, past ones too
Roles.forget!(user)                                                              # the user is gone
```

```roc
Roles.Grant(role, via) := { user : Str, role : role, via : via, by : Str, ends : Roles.Ends ?? Never, note : Str ?? "" }
Roles.Ends : [Never, At(I64)]
Roles.Held(role, via) : { role : role, via : via, by : Str, since_ms : I64, ends : Roles.Ends, note : Str, state : Roles.State }
Roles.State : [Current, Ended, Revoked({ at_ms : I64, by : Str })]

Roles.grant! : Roles.Grant(role, via) => Try({}, [DbErr(Str), ..])
Roles.revoke! : { user : Str, role : role, via : via, by : Str } => Try(Bool, [DbErr(Str), ..])
Roles.has! : Str, role => Bool
Roles.current! : Str => Try(List(role), [DbErr(Str), BadRow(Str), ..])
Roles.of! : Str => Try(List(Roles.Held(role, via)), [DbErr(Str), BadRow(Str), ..])
Roles.forget! : Str => Try(U64, [DbErr(Str), ..])
```

- **A grant for each reason.** A user holds a role while any of their grants of it lasts, and
  there is one grant for each reason: a subscription that ends (`via: Paid`, revoked) never takes
  away a gift, and a gift isn't cut short by a payment. `revoke!` ends the grant for the reason it
  names, whoever gave it.
- **Granting again while a grant lasts changes its end** (sooner or later), its `by` and its note,
  in place: a row is one unbroken stretch, so a payment that grants until the next period's end
  each month keeps one row. A grant whose end has come is over; granting after it starts a new one.
  Two grants at once give one grant (one statement takes the open row, on SQLite and on Postgres).
- **Nothing is deleted but by `forget!`.** A grant that ran out or was revoked stays, for `of!` to
  show (what ended when, and who ended it) and for the app to ask: the example's `/trial` refuses
  someone whose grants include a trial. `forget!` is for the app's deleting of a user (`Auth.forget!`
  calls it, with the rest the package keeps for them).
- **`by` is who acted**: an admin's id, or what gave it (`"stripe"`, `"trial"`). Who may grant or
  revoke is the app's to decide before it calls, as with `impersonate!`; each is on the log (`auth:
  role granted`, `auth: role revoked`, with the user, the role and reason as JSON, and `by`).
- **`has!` is a no** when the database can't be read (and an error on the log), so what it guards
  stays shut. It reads the user it is given: give it a session's `user` for what the routes show
  (while an admin impersonates someone, theirs), and `real_user` for what only an admin may do.
- **The tags are kept as their JSON** (`"Pro"`): a tag
  renamed in the app leaves its old grants unread, so `of!` leaves them out (said on the log) and
  `has!` doesn't count them. Rename by updating the rows, as any stored value's.
- **`current!` is what a request reads**: the roles held now, each once, in one query, for the
  middleware to put beside who the request is (below). `has!` is for a check outside a request (a
  job). A role the app's tags no longer read is left out of both, and said on the log.

Paid roles are the app's to write from its payments: with packages/stripe, a function that reads the
user's subscription (`Stripe.subscription!`) and grants `via: Paid` until its period's end (a few days
more, for the card's retries) or revokes it once it has ended, run from `on_event!` for every event
about that user, and now and then for everyone who pays. It reads the state, not the event, so events
that come twice or out of order change nothing, and a missed one is made up.

### What a user may do

Roles are stored; what a user may do is not (D-132). It is a function of the app's own, from what
the request knows: the roles its middleware read once with `current!`, and anything else (a list
of admins, the org they act in). A route asks for an action, not for the roles behind it, so a
rule that changes changes in one place, and, being pure, it is tested with `expect`. The package
has no type for it: the actions, the rules and who they read are the app's.

```roc
# Middlewares.roc: who a signed-in request is, with the roles held now
Me : { user : Str, email : Str, session : Str, real_user : Str, roles : List(Role), admin : Bool }
roles = Roles.current!(session.user)       # in `Auth.required_with`'s step: one read a request

# Policy.roc: what they may do
Action : [UsePro, Impersonate]

can : { roles : List(Role), admin : Bool, .. }, Action -> Bool
can = |me, action|
	match action {
		UsePro => me.admin or me.roles.contains(Pro)
		Impersonate => me.admin
	}

need : { roles : List(Role), admin : Bool, .. }, Action -> Try({}, Endpoint.Refusal)
need = |me, action| if (can(me, action)) Ok({}) else Err(Forbidden)

# a route
Policy.need(context, UsePro)?
```

- **Who it reads is an open record** (`{ roles, admin, .. }`): a request's `Me` is one, and so is
  a record a job builds for someone outside a request (their roles read with `current!`).
- **Each action may say its own refusal**: `need` can answer a 402 that offers Pro for one and a
  404 for another, so an admin page doesn't say it is there.
- **A check about a thing** (this post, this org) is an action that carries it, `Edit(post)`,
  ruled `post.author == me.user or me.admin`: the route reads the thing, then asks.
- **A folder of routes** asks once, in its `+middleware.roc`, before any route under it.
- **Behind impersonation**, `roles` are the user acted as (what the routes show), and `admin` is
  who really signed in, so what only an admin may do stays theirs.
- **Roles that can't be read are an error, not none**: the example's middleware answers 503, so
  nobody is let through as someone holding less than they do, or more.

The example: `Policy.roc` (`UsePro`, `Administer`, `Impersonate`, `Grant`), its middleware's `Me`,
and its routes, each asking `need`.

## Two-factor sign-in

With `two_factor: Bool.True`, a user may turn on two-factor sign-in: from then on, each of their
sign-ins (a link, a provider, the dev sign-in, the app's own `sign_in!`) waits for the code their
authenticator app shows (TOTP, RFC 6238: HMAC-SHA1, 30-second steps, six digits, as every app reads
an `otpauth://` URI), or one of their recovery codes.

```roc
Auth.TwoFactor : [Off, Pending, On({ since_ms : I64, recovery_codes : U64 })]

Auth.two_factor! : Str => Try(TwoFactor, [DbErr(Str), BadRow(Str), ..])
Auth.two_factor_start! : Str, Str => Try({ secret : Str, uri : Str }, [AlreadyOn, NotOffered, DbErr(Str), BadRow(Str), ..])
Auth.two_factor_pending! : Str, Str => Try({ secret : Str, uri : Str }, [NotPending, DbErr(Str), BadRow(Str), ..])
Auth.two_factor_confirm! : Str, Str => Try(List(Str), [WrongCode, NotStarted, AlreadyOn, DbErr(Str), BadRow(Str), ..])
Auth.two_factor_disable! : Str, Str => Try({}, [WrongCode, NotOn, TooManyTries, DbErr(Str), BadRow(Str), ..])
Auth.two_factor_regenerate! : Str, Str => Try(List(Str), [WrongCode, NotOn, TooManyTries, DbErr(Str), BadRow(Str), ..])
Auth.waiting! : Server.Request => Try({ user : Str, then : Str, tries_left : U64 }, [SignedOut])
```

**Turning it on.** `two_factor_start!(user, account)` makes a secret (20 random bytes) and keeps it
sealed, waiting for its first code. The app shows the `uri` as a QR code (packages/qr's
`<QrCode>`), and the `secret` as text (Base32 in groups of four) for an app that can't scan;
`account` is what the app shows beside the issuer (their address). `two_factor_pending!` gives both
again while it waits (the page reloaded, or a wrong code). `two_factor_confirm!(user, code)` takes
the first code and turns it on: the answer is ten recovery codes (`k7qx-m2pa-r4tz-b6wd`), each good
once in place of a code. Show them once: only their hashes are kept.

**Signing in.** A user with it on isn't signed in by their link or provider: the cookie holds a
sign-in waiting for a code, for ten minutes, and the browser goes to `code_page` (`?then=` where it
was going). Meanwhile the middleware treats the request as signed out, but a page's GET goes to the
code page rather than the sign-in page. The code page posts `code` (and `then`) to `/auth/code`:

- a code the app shows now (or for the step either side, a clock a little out), later than the last
  one this user used, so a code is good once; or one of their unused recovery codes (used up, and on
  the log);
- right: a session starts under a new token (the one the browser waited with signs no one in), on
  to `then`;
- wrong: back to the code page with `?error=code`; the fifth wrong code ends the sign-in, and the
  sign-in page says `?error=attempts`;
- once the user has given ten wrong codes in a row, across sign-ins and the two calls below, their
  codes are refused for a quarter of an hour after the last, without being looked at: a code then
  ends the sign-in, and the sign-in page says `?error=locked`; once the wait is over, each wrong
  code starts it again;
- after ten minutes, or with no sign-in waiting: the sign-in page, `?error=timeout`.

`waiting!(request)` is the sign-in waiting in this browser: whose, where it goes, how many more
tries it has, for the code page to say whom it signs in. The code page must not need a signed-in
user (it would send itself to itself). A form posting to `/auth/sign-out` cancels.

**Turning it off, new recovery codes.** `two_factor_disable!(user, code)` and
`two_factor_regenerate!(user, code)` each take a code the app shows now or a recovery code. Their
wrong codes count toward the user's ten in a row; `TooManyTries` while their codes are refused (the
code isn't looked at), which a route answers with a 429.

**Who must have it.** The package doesn't decide: `two_factor!(user)` says whether it is on, and a
route that wants it (an admin's) refuses those without it, as the example's `/admin` does.

**The secret at rest** is sealed with the platform's `AesGcm` under a key derived (HKDF-SHA256)
from the app's secret, `APP_SECRET` (`key_env`), at least 32 characters (`openssl rand -hex 32`),
with the user's id sealed beside it, so a row moved to another user doesn't open. With
`two_factor`, the server doesn't start without it, but under `--dev`, where a development secret
stands in (said on the log). Changing it makes every authenticator's secret unreadable: their codes
stop working, but recovery codes still sign in (and turn it off, to set it up again).

## Providers

```roc
Auth.Provider : {
    name : Str,                                 # its routes: /auth/<name>, /auth/<name>/callback
    label : Str,                                # for the app's button
    flow : [Oidc(List(Str)), GitHub(Str)],      # the ID token's issuers, or GitHub's API
    authorize_url : Str,
    token_url : Str,
    scopes : List(Str),
    params : List((Str, Str)),                  # more for its authorization endpoint
    client_id_env : Str,                        # the environment variables with the client's id
    client_secret_env : Str,                    # and secret
}
```

| Provider | Environment | Redirect URI to register |
| --- | --- | --- |
| `Auth.google` (asks which account: `prompt=select_account`) | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | `<public URL>/auth/google/callback` |
| `Auth.github` | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | `<public URL>/auth/github/callback` |
| `Auth.oidc({ name, label, issuer, authorize_url, token_url, client_id_env, client_secret_env })` | as given | `<public URL>/auth/<name>/callback` |

The public URL is the server's (`--public-url`, `PUBLIC_URL`), never a request's `Host`. A record
update changes any part: `{ ..Auth.google, client_id_env: "ACME_GOOGLE_ID" }`. A provider whose client
id is empty isn't offered (`Auth.providers!` leaves it out), and its route sends the browser back
to the sign-in page saying so. Don't name a provider `link`, `code`, `dev` or `sign-out`: those are
the other steps' paths.

## The routes

Each step is a handler the app calls from a route file of its own (D-116), in `routes/auth/` for
the default `at`, so the middleware of the folder it is in is around it, as around any route, and
`rocx routes` lists it. An app writes only the files for the steps it uses (`rocx new`'s template
has all six). Each answers with a redirect; a method it doesn't take, 405.

```roc
Auth.provider_route! : Server.Request, List(Auth.Provider), Str => Server.Response
Auth.callback_route! : Server.Request, List(Auth.Provider), Str, (Auth.Identity => Try(Str, Str)) => Server.Response
Auth.link_route! : Server.Request, (Auth.Identity => Try(Str, Str)) => Server.Response
Auth.dev_route! : Server.Request, (Auth.Identity => Try(Str, Str)) => Server.Response
Auth.code_route! : Server.Request => Server.Response
Auth.sign_out_route! : Server.Request => Server.Response
```

| Route file: `respond! = \|{ request, .. }\| …` | Answers |
| --- | --- |
| `routes/auth/link/+server.roc`: `Auth.link_route!(request, Accounts.admit!)` | `GET /auth/link?token=…`, `POST /auth/link` (`token`): uses a mailed link: signed in, on to where it was going |
| `routes/auth/[provider]/+server.roc`: `Auth.provider_route!(request, Accounts.providers, params.provider)` | `GET /auth/<provider>?then=…`: off to the provider (404 for a name the list hasn't) |
| `routes/auth/[provider]/callback/+server.roc`: `Auth.callback_route!(request, Accounts.providers, params.provider, Accounts.admit!)` | `GET /auth/<provider>/callback`: back from it: signed in, on to `then` |
| `routes/auth/sign-out/+server.roc`: `Auth.sign_out_route!(request)` | `POST /auth/sign-out` (`then`): the session ended, its cookie gone, on to `then` (else `home`) |
| `routes/auth/dev/+server.roc`: `Auth.dev_route!(request, Accounts.admit!)` | `POST /auth/dev` (`email`, `then`): under `--dev` only (404 otherwise): that address signed in |
| `routes/auth/code/+server.roc`: `Auth.code_route!(request)` | `POST /auth/code` (`code`, `then`): a sign-in's second factor: signed in, on to `then`; or back to the code page |

The provider routes read the path's `params` too (`respond! = |{ request, params, .. }| …`). Each
file imports `auth.Auth` and the app's module (`import ../../../Accounts` from
`routes/auth/link/`). These are how one signs in, so no folder they are in may turn a signed-out
request away: keep them out of a group whose middleware is `Auth.required`.

A sign-in that fails goes to the app's sign-in page with why, and where it was going (`&then=`):

| `?error=` | Means |
| --- | --- |
| `link` | the link has been used, has expired, or isn't one |
| `refused` | `admit!` said no; `&reason=` is what it said, `&email=` the address it turned away |
| `provider` | the provider refused, couldn't be reached, or isn't set up; `&reason=` says which |
| `state` | back from a provider without the state this browser kept: too late, or another browser |
| `unavailable` | the database couldn't take it (on the log) |
| `attempts` | the fifth wrong code ended a sign-in waiting for its code |
| `locked` | the user had given ten wrong codes in a row: their codes are refused for a quarter of an hour after the last |
| `timeout` | no sign-in was waiting for a code in this browser (ten minutes went by) |

A wrong code goes back to the code page with `?error=code`.

## The API

| Function | Does |
| --- | --- |
| `plugin : Options -> Plugin.Value(context)` | the plugin: its tables and its settings (no routes, D-116) |
| `provider_route!`, `callback_route!`, `link_route!`, `code_route!`, `sign_out_route!`, `dev_route!` | the steps, for the app's route files ([The routes](#the-routes)) |
| `link! : Str, Str => Try(Str, [NotAnAddress, DbErr(Str), ..])` | a sign-in link for an address, going on to `then`: the URL to mail |
| `link_for! : Str => Try({ email, then }, [Gone])` | whom a link signs in, without using it |
| `session! : Server.Request => Try(Session, [SignedOut])` | the request's session |
| `required`, `required_with`, `optional` | the middleware |
| `signed_out! : Server.Request => Server.Response` | what `required` answers a signed-out request |
| `renew! : Server.Request, Session, Server.Response => Server.Response` | a session in its second half kept for as long again |
| `sign_in! : Server.Response, Str => Try(Server.Response, [DbErr(Str), ..])` | a new session for a user on an answer (the app's own way in) |
| `switch! : Server.Request, Server.Response, Str => Try(Server.Response, [DbErr(Str), ..])` | the request's session ended and one for a user started, in one step |
| `path! : Str => Str` | where a sign-in may go after: the path, or `home` |
| `impersonate!`, `stop_impersonating!`, `impersonating` | an admin acting as someone (above) |
| `sign_out! : Server.Request, Server.Response => Server.Response` | the request's session ended, its cookie gone |
| `sign_out_everywhere! : Str => Try(U64, [DbErr(Str), ..])` | every session of a user ended |
| `sessions! : Str => Try(List({ id, created_ms, expires_ms, acting_as }), …)` | a user's sessions, the newest first |
| `revoke! : Str, Str => Try(U64, [DbErr(Str), ..])` | one of a user's sessions ended |
| `identities! : Str => Try(List({ provider, subject, email }), …)` | the identities a user signs in with |
| `user_for! : Identity => Try(Str, [NoAddress, DbErr(Str), BadRow(Str), ..])` | for `admit!`: the id of the identity's user, made if there is none ([Users](#users)) |
| `user! : Str => Try(User, [NotFound, ..])`, `user_by_email! : Str => Try(User, [NotFound, ..])` | a user, by id or by address |
| `user_with_address! : Str => Try(Str, [NotAnAddress, DbErr(Str), BadRow(Str), ..])` | the user with an address, made if there is none: someone named before they sign in |
| `forget! : Str => Try({}, [DbErr(Str), ..])` | everything the package keeps for a user, deleted |
| `providers! : {} => List({ name, label, path })` | the providers set up, for the sign-in page's buttons |
| `dev_sign_in! : {} => Bool` | whether `POST /auth/dev` is open (`--dev`) |
| `two_factor!`, `two_factor_start!`, `two_factor_pending!`, `two_factor_confirm!`, `two_factor_disable!`, `two_factor_regenerate!`, `waiting!` | two-factor sign-in (above) |
| `google`, `github`, `oidc` | providers |

`Rules` holds what is plain Roc, with its `expect`s: where a sign-in may go after (`path`), a token's
shape and hash, the cookies' names, an address as it is kept, the state cookie, PKCE's challenge,
the URL to a provider, an ID token's claims, GitHub's answers, recovery codes and the sealing key.
`Totp` is authenticator apps' codes (`code`, `matching`, `uri`, `grouped`), checked against RFC
6238's and RFC 4226's own vectors. `AuthStore` holds the statements.
`SignInError` names no platform (`browser.roc` lists it), so a sign-in page reads it in the browser:
`SignInError.message(query)` is the sentence for `?error=` (and its `reason`), `SignInError.field`
a field of the query (`then`, `email`); the code page uses it too.

## The tables

`auth/0001_auth`, `auth/0002_impersonation`, `auth/0003_two_factor`,
`auth/0004_two_factor_misses`, `auth/0005_roles` and `auth/0006_users`, the same on SQLite and on
Postgres (times are milliseconds, given by the package):

- `auth_sessions`: `id` (the token's hash), `user_id`, `created_at`, `expires_at`, and while
  impersonating `acting_as` and `acting_until`;
- `auth_links`: `id` (the token's hash), `email`, `return_to`, `expires_at`;
- `auth_identities`: `provider`, `subject`, `user_id`, `email`, `created_at`;
- `auth_two_factor`: `user_id`, `secret` (sealed), `enabled_at` (null while it waits for its first
  code), `last_step` (the last 30-second step a code was used at), `created_at`, `misses` (wrong
  codes in a row) and `missed_at` (the last);
- `auth_recovery_codes`: `user_id`, `id` (the code's SHA-256), `created_at`;
- `auth_waiting`: `id` (the token's hash), `user_id`, `return_to`, `attempts`, `expires_at`;
- `auth_roles` (`Roles`): `id`, `user_id`, `role` and `via` (the app's tags, as JSON),
  `granted_by`, `granted_at`, `ends_at` (null: for good), `note`, `closed_at` (null on the one open
  grant for a user, role and reason: a unique index), `revoked_by` (null unless revoked).
- `auth_users` ([Users](#users)): `id` (a version 7 UUID, or an id the app had before), `email`
  (lower-cased, unique), `created_at`.

Expired sessions, links and waiting sign-ins are swept as sessions start.

## Safety

- **Tokens** are 32 random bytes. Only their SHA-256 is kept, so a leaked table signs no one in.
  A link is used and deleted in one statement, so two clicks at once can't both use it.
- **Cookies** are `HttpOnly` and `SameSite=Lax`, and `__Host-` and `Secure` on HTTPS. The posts its
  routes answer come from the app's pages: the platform refuses one another site's page sends
  (`cross_site: Refused`, the default); an app that says `cross_site: Allowed` puts
  `Middleware.same_origin({})` in the middleware of the folder its `auth/` routes are in.
- **Where a sign-in goes after** is a path of this site, or `home`: never `//elsewhere`,
  `/\elsewhere`, `https://…`, or a path with a control character in it (a tab, a line break: a
  browser drops them from a URL as it reads one, so `/<tab>/elsewhere` would go to `//elsewhere`).
- **OAuth**: the state is compared in constant time and the state cookie goes whatever happens. PKCE
  (S256) binds the code to this browser, and the nonce binds the ID token to it. The ID token comes
  straight from the provider's token endpoint over TLS, which OpenID Connect accepts in place of
  checking its signature (Core 1.0, 3.1.3.7). Its issuer, audience, expiry and nonce are checked.
- **Rate limits** are the app's: packages/guard on the sign-in page's endpoint, per address and per
  client (`Guard.rate_limit`), so nobody mails an address a hundred links. `rocx new`'s app has them:
  5 a minute from each client, 5 an hour to each address.
- **Links in mail** go to the server's public URL, never to a request's `Host`, which whoever asks
  can set.
- **Two-factor**: the secret sealed (AES-256-GCM, under a key from `APP_SECRET`), never in clear; a
  code compared in constant time, good once (the last step used is kept); recovery codes 80 random
  bits each, kept as their SHA-256, used up in one statement; five wrong codes end a sign-in, which
  waits ten minutes at most; the session that follows has a new token. A user's wrong codes are
  counted across sign-ins too, and turning it off or making new recovery codes: ten in a row and
  their codes are refused for a quarter of an hour (one more guess each quarter after that). Each
  code is counted before it is looked at, so codes sent at once can't get past the count. Whoever
  holds a user's first factor can keep them waiting that way; they couldn't sign in as them
  anyway.

## Status

Built and tested (D-072, D-077, D-081, D-127): links, the link page, Google, GitHub, OpenID Connect, the
dev sign-in, sessions, the middleware, impersonation, two-factor sign-in with an authenticator app
and recovery codes, roles. Not yet: passwords (they need a slow hash, Argon2, from the host), passkeys (a
P-256 signature verified, by the host), discovery of a provider's endpoints from its issuer.
PROPOSALS.md has them.
