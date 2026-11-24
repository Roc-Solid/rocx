# auth

Sign-in for Roc Solid apps, as a plugin (D-072): by a link mailed to an address, or at a provider
(Google, GitHub, any OpenID Connect one). Sessions are kept in the app's database (Postgres, SQLite
or Turso), as their token's hash. Middleware hands the signed-in user on to the routes.

The package has no pages. The app's sign-in page posts to it and links to it, the app mails the
links (packages/email), and the app's `admit!` says who gets in and which of its users they are.
What the package does is the part that is easy to get wrong: tokens, their hashes, their expiry and
single use, cookies, OAuth's state, PKCE and nonce, the ID token's checks, and where a sign-in may
send the browser after.

The docs site's page, `/ecosystem/auth`, is the guide; this is the reference. `example/` is an app
that uses all of it, and its tests (`example/test`) run it on SQLite and on Postgres.

## Installing it

1. Name the package in the app's header (it names the server platform, so only the server's half
   of an app sees it), and list its plugin with the app's `admit!`:

   ```roc
   app [program] { auth: "../packages/auth/main.roc", email: "../packages/email/main.roc", pf: platform "../server/platform/main.roc" }

   program = App.program({
       init!: |_started| Ok({}),
       middleware: Middleware.same_origin({}),
       plugins: [
           Email.plugin({ from: "Acme <hello@example.com>" }),
           Auth.plugin({ admit!: Accounts.admit!, providers: [Auth.google, Auth.github], link_page: "/sign-in/link" }),
       ],
       database: Sqlite("data/app.db"),
   })
   ```

2. Write `admit!`: given who is signing in (`Auth.Identity`), the app's id for its user, or why not.

   ```roc
   admit! : Auth.Identity => Try(Str, Str)
   admit! = |identity|
       match identity.user {
           Known(user) => Ok(user)                         # this identity signed in before
           New => user_for_address!(identity.email)        # find or make the app's user
       }
   ```

3. Name the middleware in the routes that need a signed-in user:

   ```roc
   signed_in : Middleware({}, { user : Str })
   signed_in = Auth.required(|{}, session| { user: session.user })
   ```

4. Write the sign-in page: a form whose endpoint calls `Auth.link!` and mails the URL, a link per
   provider (`Auth.providers!`), and, with `link_page`, the page a mailed link opens.

## The plugin's options

```roc
Auth.Options := {
    admit! : Auth.Identity => Try(Str, Str),   # who gets in (required)
    at : Str ?? "/auth",                       # where the plugin's endpoints are
    sign_in : Str ?? "/sign-in",               # the app's sign-in page
    home : Str ?? "/",                         # where a sign-in goes when it wasn't going anywhere
    providers : List(Auth.Provider) ?? [],     # where else one may sign in
    session_days : U64 ?? 30,                  # how long a session lasts
    link_minutes : U64 ?? 15,                  # how long a mailed link is good for
    link_page : Str ?? "",                     # the app's page a mailed link opens ("": /auth/link)
    cookie : Str ?? "session",                 # the session cookie's name
}
```

`admit!` runs inside the transaction that starts the session, with the identity's row. What it
writes (a new user's row, a welcome job it queues) stays only if the sign-in does. Keep anything
slow (a fetch) out of it. On Turso, a transaction that loses to another's write runs again, and
`admit!` with it.

## Signing in

**By a mailed link.** `Auth.link!(email, then)` keeps a link (its token's hash, the address, where it
goes after, until when) and gives the URL to mail. The app sends it, as it likes. A link works once,
for `link_minutes`.

- With `link_page`, the URL opens the app's page, which shows whom it signs in
  (`Auth.link_for!(token)`, which doesn't use it) and posts the token to `/auth/link` from a button.
  A mail scanner that opens every link in a message then can't use one up.
- Without it, the URL is `/auth/link?token=…`, and opening it signs in.

**At a provider.** The app's button links to `/auth/<provider>?then=…`. The plugin keeps a state, a
PKCE verifier and a nonce in a cookie for ten minutes, and sends the browser to the provider.
Back at `/auth/<provider>/callback`, the state must be the one the browser kept. The code is traded
at the provider's token endpoint (with the verifier and the client's secret), and who signed in is
read: from the ID token (OpenID Connect: its issuer, audience, expiry and nonce checked; its address
taken only when the provider says it is verified), or from GitHub's API (the user, and their
primary verified address).

**Under `--dev`.** `POST /auth/dev` with an `email` signs that address in, as a link would. Without
`--dev` there is no such endpoint. `Auth.dev_sign_in!` says whether it is open, for the page.

Each way ends the same: the identity (`provider`, `subject`) is looked up, `admit!` is asked, the
identity is recorded as the user's, a session starts, and the browser goes on to `then` with the
session cookie. `then` is a path of this site, or `home`: never another site.

## Who is signing in

```roc
Auth.Identity : { provider : Str, subject : Str, email : Str, name : Str, user : [New, Known(Str)] }
```

| Field | Is |
| --- | --- |
| `provider` | `"email"` for a link or the dev sign-in, else the provider's name (`"google"`) |
| `subject` | who they are there: the address for `"email"`, the provider's own id for them otherwise |
| `email` | their address, lower-cased; `""` when the provider has none it says is verified |
| `name` | their name, or `""` |
| `user` | `Known(user)`: the app's user this identity signed in as before; `New` otherwise |

An identity that signed in before is `Known`, even if its address changed since. A new one is the
app's to place: the user with that address, a new user, or a refusal (`Err("why")`, shown on the
sign-in page).

## Sessions and middleware

```roc
Auth.Session : { user : Str, id : Str, expires_ms : I64 }
Auth.Signed : [SignedOut, SignedIn(Auth.Session)]

Auth.required : (ctx, Auth.Session -> out) -> Middleware(ctx, out)
Auth.optional : (ctx, Auth.Signed -> out) -> Middleware(ctx, out)
Auth.session! : Server.Request => Try(Auth.Session, [SignedOut])
```

- `required` lets a signed-in request through, handing its session on (the function puts it in
  the context). A signed-out page's GET goes to the sign-in page, `?then=` the page; anything else
  is a 401.
- `optional` hands on whether the request is signed in.
- Both keep a session used in its second half for as long again: its row and its cookie, at most
  once a half, so a request doesn't write.

The cookie holds a random token (32 bytes). The table holds its SHA-256, so the table alone signs no
one in. It is `HttpOnly`, `SameSite=Lax`, for the whole site, and on HTTPS (the server's public URL)
`Secure` and named `__Host-session`, so no other site under the same domain can set it.

## Providers

```roc
Auth.Provider : {
    name : Str,                                 # its endpoints: /auth/<name>, /auth/<name>/callback
    label : Str,                                # for the app's button
    flow : [Oidc(List(Str)), GitHub(Str)],      # the ID token's issuers, or GitHub's API
    authorize_url : Str,
    token_url : Str,
    scopes : List(Str),
    client_id_env : Str,                        # the environment variables with the client's id
    client_secret_env : Str,                    # and secret
}
```

| Provider | Environment | Redirect URI to register |
| --- | --- | --- |
| `Auth.google` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | `<public URL>/auth/google/callback` |
| `Auth.github` | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | `<public URL>/auth/github/callback` |
| `Auth.oidc({ name, label, issuer, authorize_url, token_url, client_id_env, client_secret_env })` | as given | `<public URL>/auth/<name>/callback` |

The public URL is the server's (`--public-url`, `PUBLIC_URL`), never a request's `Host`. A record
update changes any part: `{ ..Auth.google, client_id_env: "ACME_GOOGLE_ID" }`. A provider whose client
id is empty isn't offered (`Auth.providers!` leaves it out), and its endpoint sends the browser back
to the sign-in page saying so. The names `link`, `dev` and `sign-out` are the plugin's own.

## The endpoints

Each answers with a redirect.

| Endpoint | Does |
| --- | --- |
| `GET /auth/link?token=…`, `POST /auth/link` (`token`) | uses a mailed link: signed in, on to where it was going |
| `GET /auth/<provider>?then=…` | off to the provider |
| `GET /auth/<provider>/callback` | back from it: signed in, on to `then` |
| `POST /auth/sign-out` (`then`) | the session ended, its cookie gone, on to `then` (else `home`) |
| `POST /auth/dev` (`email`, `then`) | under `--dev` only: that address signed in |

A sign-in that fails goes to the app's sign-in page with why, and where it was going (`&then=`):

| `?error=` | Means |
| --- | --- |
| `link` | the link has been used, has expired, or isn't one |
| `refused` | `admit!` said no; `&reason=` is what it said |
| `provider` | the provider refused, couldn't be reached, or isn't set up; `&reason=` says which |
| `state` | back from a provider without the state this browser kept: too late, or another browser |
| `unavailable` | the database couldn't take it (on the log) |

## The API

| Function | Does |
| --- | --- |
| `plugin : Options -> Plugin.Value(context, ctx)` | the plugin: its endpoints, its tables, its settings |
| `link! : Str, Str => Try(Str, [NotAnAddress, DbErr(Str), ..])` | a sign-in link for an address, going on to `then`: the URL to mail |
| `link_for! : Str => Try({ email, then }, [Gone])` | whom a link signs in, without using it |
| `session! : Server.Request => Try(Session, [SignedOut])` | the request's session |
| `required`, `optional` | the middleware |
| `sign_in! : Server.Response, Str => Try(Server.Response, [DbErr(Str), ..])` | a new session for a user on an answer (the app's own way in) |
| `sign_out! : Server.Request, Server.Response => Server.Response` | the request's session ended, its cookie gone |
| `sign_out_everywhere! : Str => Try(U64, [DbErr(Str), ..])` | every session of a user ended |
| `sessions! : Str => Try(List({ id, created_ms, expires_ms }), …)` | a user's sessions, the newest first |
| `revoke! : Str, Str => Try(U64, [DbErr(Str), ..])` | one of a user's sessions ended |
| `identities! : Str => Try(List({ provider, subject, email }), …)` | the identities a user signs in with |
| `providers! : {} => List({ name, label, path })` | the providers set up, for the sign-in page's buttons |
| `dev_sign_in! : {} => Bool` | whether `POST /auth/dev` is open (`--dev`) |
| `google`, `github`, `oidc` | providers |

`Rules` holds what is plain Roc, with its `expect`s: where a sign-in may go after (`path`), a token's
shape and hash, the cookies' names, an address as it is kept, the state cookie, PKCE's challenge,
the URL to a provider, an ID token's claims, GitHub's answers. `AuthStore` holds the statements.

## The tables

`auth/0001_auth`, the same on SQLite and on Postgres (times are milliseconds, given by the package):

- `auth_sessions`: `id` (the token's hash), `user_id`, `created_at`, `expires_at`;
- `auth_links`: `id` (the token's hash), `email`, `return_to`, `expires_at`;
- `auth_identities`: `provider`, `subject`, `user_id`, `email`, `created_at`.

Expired sessions and links are swept as sessions start.

## Safety

- **Tokens** are 32 random bytes. Only their SHA-256 is kept, so a leaked table signs no one in.
  A link is used and deleted in one statement, so two clicks at once can't both use it.
- **Cookies** are `HttpOnly` and `SameSite=Lax`, and `__Host-` and `Secure` on HTTPS. The posts the
  plugin answers come from the app's pages: list `Middleware.same_origin({})` in the app's
  middleware, as `rocx new` does, so another site's form is refused.
- **Where a sign-in goes after** is a path of this site, or `home`: never `//elsewhere`,
  `https://…` or a line break.
- **OAuth**: the state is compared in constant time and the state cookie goes whatever happens. PKCE
  (S256) binds the code to this browser, and the nonce binds the ID token to it. The ID token comes
  straight from the provider's token endpoint over TLS, which OpenID Connect accepts in place of
  checking its signature (Core 1.0, 3.1.3.7). Its issuer, audience, expiry and nonce are checked.
- **Rate limits** are the app's: packages/guard on the sign-in page's endpoint, per address and per
  client (`Guard.rate_limit`), so nobody mails an address a hundred links.
- **Links in mail** go to the server's public URL, never to a request's `Host`, which whoever asks
  can set.

## Status

Built and tested (D-072): links, the link page, Google, GitHub, OpenID Connect, the dev sign-in,
sessions, the middleware. Not yet: passwords (they need a slow hash, Argon2, from the host), passkeys
(P-256 from the host), discovery of a provider's endpoints from its issuer. PROPOSALS.md has them.
