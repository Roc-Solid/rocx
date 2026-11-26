# {{title}}

A Roc Solid app, made by `rocx new`. People sign in by a link mailed to them, or at Google or
GitHub once you set those up, and with a code from an authenticator app too once they turn on
two-factor sign-in. Sessions, mail, security headers and a limit on sign-in mail are set up from the
first commit.

The guide to Roc Solid is at [roc-solid.github.io](https://roc-solid.github.io/).

## Run it

```sh
rocx dev
```

That builds the app, starts it at http://localhost:8080 (`--port` for another), and builds again
and reloads the page when you save a file. Under `rocx dev`:

- **Mail lands in the dev mailbox**, http://localhost:8080/__rocx/mail, while `SMTP_URL` isn't
  set: open a sign-in link from there.
- **The dev sign-in is open.** The sign-in page has a form that signs any address in at once, so
  you can be anyone while you work. Without `--dev` it isn't there.

## What each file is

| File | What it is |
| --- | --- |
| `main.roc` | The server's program: the middleware, the plugins (mail and sign-in), the database |
| `Middlewares.roc` | What requests go through: `default` (every request), `signed_in`, `anyone`, `mail_limit` |
| `Accounts.roc` | The app's users: who may sign in (`admit!`), and reading a user (`user!`) |
| `migrations/` | The database's tables, as SQL, applied in order as the server starts |
| `routes/` | The pages and endpoints: a folder each, its path the URL |
| `routes/+layout.rocx` | The document around every page, and the app's look (colours, light and dark) |
| `routes/+error.rocx` | What a missing page (404) or a failed one (500) shows |
| `routes/+page.rocx` | The front page |
| `routes/api/me/+server.roc` | Who is signed in, for the bar at the top |
| `routes/sign-in/` | The sign-in page, the endpoint that mails a link (`mail/`), the page a link opens (`link/`), and the page that asks for a two-factor code (`code/`) |
| `routes/account/` | A page for signed-in people only: your address, where you're signed in, signing out everywhere, and two-factor sign-in (its forms post to `two-factor/`) |
| `components/Nav.rocx` | The bar at the top: a component, with its stories and tests |
| `.rocx-version` | The version of Roc Solid this app builds with |
| `.rocx` | A link to that version, which every `rocx` command makes (not committed) |

In `routes/`, `+page.rocx` is a page, `+server.roc` its endpoints (what the page reads and what its
forms post), and `+layout.rocx` wraps the pages below it. `rocx build` writes `Generated/` from them
(the routes, `Api`, `Paths`): don't edit it, and don't commit it.

A file's `middleware = Middlewares.signed_in` lets only signed-in people through. A signed-out page
visit goes to the sign-in page, and comes back after; anything else is refused (401). A page that
names no middleware runs behind its `+server.roc`'s, so `routes/account/+server.roc`'s line guards
the account page too. A layout's middleware would guard nothing, so `rocx build` refuses one.

## Mail

Under `rocx dev`, without `SMTP_URL`, nothing is sent: each message is kept for the dev mailbox, and
the log says so. A server started without `--dev` needs `SMTP_URL`: without it, it doesn't start
(the log says why), rather than lose every sign-in link. To send mail, set these where the server
runs:

| Variable | What it is |
| --- | --- |
| `SMTP_URL` | Your mail service: `smtps://user:password@smtp.example.com` (TLS from the start), or `smtp://user:password@smtp.example.com:587?tls=required` (STARTTLS) |
| `PUBLIC_URL` | Where people reach the app, `https://app.example.com`: the links in the mail point there |

Who mail is from is `main.roc`'s `from`. Change `hello@example.com` to an address your mail service
lets you send from. (`MAIL_FROM`, when it is set, wins over `from`.)

## The database

`main.roc`'s `database:` line says which:

| Line | The database |
| --- | --- |
| `Sqlite("data/app.db")` | SQLite: a file beside where the server starts (`data/` is made) |
| `Turso("data/app.db")` | Turso's engine on the same kind of file: writes at once (MVCC) |
| `Postgres` | Postgres, at `DATABASE_URL` (`postgres://user:password@host/database`) |

`DATABASE_URL` moves a SQLite or Turso file elsewhere too: `sqlite:/srv/app/app.db`.

To add a table, add the next migration (`migrations/0002_….sql`). The server applies new ones as
it starts, once each. Read and write with `Db.all!`, `Db.one!` and `Db.run!` in an endpoint.
`rocx check --sql` checks each statement against your database's engine, and each row against its
Roc type.

To move to another database, change the line. The migration this app starts with works on all
three (text ids, times as `bigint` milliseconds), and so does packages/auth's. Keep yours that way
if you may move. The data doesn't move with it: copy it over yourself.

## Two-factor sign-in

Anyone may turn it on from their account page: it shows a QR code for their authenticator app
(1Password, Google Authenticator, a phone's passwords app) and the key as text, and the app's first
code turns it on and shows ten recovery codes, once. From then on, after their link or provider,
signing in waits at `/sign-in/code` for the code the app shows, or a recovery code. Five wrong codes
end that sign-in. Turning it off takes a code too.

Each authenticator's secret is kept sealed under a key derived from `APP_SECRET`, which the server
needs to start (but under `rocx dev`, where a development secret stands in). Make one with
`openssl rand -hex 32`, set it where the server runs, and keep it: if it changes, everyone's codes
stop working, and only their recovery codes sign them in. `main.roc`'s `two_factor: Bool.True`
offers it; `issuer` is the name the apps show beside the address. To ask some users to have it on
(admins, say), check `Auth.two_factor!(user)` in their routes.

## Signing in with Google or GitHub

Each provider is offered on the sign-in page once its variables are set. Register the app with the
provider, giving it the redirect URI, then set the two variables where the server runs:

| Provider | Register at | Redirect URI | Variables |
| --- | --- | --- | --- |
| Google | Google Cloud console, APIs and services, Credentials: an OAuth client for a web application | `<PUBLIC_URL>/auth/google/callback` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` |
| GitHub | GitHub, Settings, Developer settings, OAuth Apps | `<PUBLIC_URL>/auth/github/callback` | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` |

Under `rocx dev` the public URL is `http://localhost:8080`. Someone signing in at a provider for the
first time is the user with that address, or a new one (`Accounts.admit!`). Another OpenID Connect
provider is one line: see the auth page in the guide.

## Going live

```sh
rocx build . --release out/ --target x64musl     # or arm64musl, for a Linux server on arm64
```

`out/` then holds what you deploy: `server`, a single executable for Linux, and `static/`, the
browser's files. Copy `out/` to the server and start it there:

```sh
PUBLIC_URL=https://app.example.com SMTP_URL=smtps://… APP_SECRET=… ./server --static static
```

`APP_SECRET` is the secret two-factor sign-in's key comes from (`openssl rand -hex 32`, once, and
kept): without it the server doesn't start.

On SQLite or Turso the database is `data/app.db` beside where it starts: keep that folder between
deploys, and back it up (or point `DATABASE_URL` at a file elsewhere).

It listens on 127.0.0.1:8080 (`--port`, `--host`), over plain HTTP. Put a proxy that speaks HTTPS
in front of it. [Caddy](https://caddyserver.com) gets and renews the certificate itself:

```
app.example.com {
	reverse_proxy 127.0.0.1:8080
}
```

On HTTPS the session cookie is `Secure`, and named `__Host-{{name}}_session`.

The sign-in mail's limit counts each client by its address. `Middlewares.proxies` is
`Proxies(Ip.private)`: the address the connection came from, unless that is a proxy on this machine
or in a private network (Caddy, a load balancer), and then the one it adds to `X-Forwarded-For`.
With no proxy in front, a client's own `X-Forwarded-For` is never believed. Behind a proxy with a
public address, name its ranges (`Proxies(Ip.cidrs(["203.0.113.0/24"]))`) or say how many proxies
there are (`Hops(1)`): otherwise every client counts as that proxy.

## Tests

```sh
rocx test
```

builds the app and runs its Roc `expect`s: `components/Nav.rocx`'s render the bar and look for its
links and buttons, `Accounts.roc`'s check `ago`. Put an `expect` beside any function or pure
component. `rocx check` type-checks both halves of the app (the server, and the browser's), and
`rocx check --sql` checks the SQL. A CI job can run all three.

Under `rocx dev`, each component's `<story>` (two of the bar's, in `Nav.rocx`) is a page in a
catalog at http://localhost:8080/__rocx/stories.

## Upgrading

```sh
rocx upgrade
```

installs the newest version of Roc Solid, and writes it to `.rocx-version`. Commit that file: anyone
who builds the app gets the same version. `rocx upgrade <version>` picks one.

## More

- [Getting started](https://roc-solid.github.io/), and the guide's pages on
  [routing](https://roc-solid.github.io/routing), [components](https://roc-solid.github.io/components)
  and [the database](https://roc-solid.github.io/platform/database)
- [Sign-in (packages/auth)](https://roc-solid.github.io/ecosystem/auth),
  [mail](https://roc-solid.github.io/ecosystem/email), and
  [rate limits and security headers (packages/guard)](https://roc-solid.github.io/ecosystem/guard)
