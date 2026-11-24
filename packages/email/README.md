# email

Email for a Roc Solid app's server, as a plugin: messages over SMTP, as text or as text and HTML.
With no SMTP server set, a message is kept in the server's memory instead, and the dev mailbox shows
it, so development sends nothing.

The package names the server platform, so only the server's half of an app uses it; the browser's
half doesn't see it. The user guide is the docs site's
[Email page](https://roc-solid.github.io/ecosystem/email); this file is the reference.

## Installing it

Name the package in the app's header, and list its plugin. Send from a job (packages/jobs), so a
failed send is tried again and the request doesn't wait:

```roc
# main.roc
app [program] { email: "../packages/email/main.roc", jobs: "../packages/jobs/main.roc", pf: platform "../server/platform/main.roc" }

import email.Email
import jobs.Job
import Generated/App
import Middlewares

program = App.program({
    init!: |started| Ok({ facts: started }),
    middleware: Middlewares.default,
    plugins: [Job.plugin({ jobs: App.jobs }), Email.plugin({})],
})
```

```roc
# Jobs.roc: rocx build finds the kind and lists it in App.jobs
import email.Email
import jobs.Job

Jobs := [].{
    welcome : Job.Kind(_, { to : Str })
    welcome = Job.define("welcome", |_context, { to }|
        match Email.send!({ to, subject: "Welcome", text: "…", html: "<p>…</p>" }) {
            Ok({}) => Ok({})
            Err(EmailErr(why)) => Err(why)
        })
}
```

## API

### `Email`

```roc
Email.Message : { to : Str, subject : Str, text : Str, html : Str }
Email.send! : Email.Message => Try({}, [EmailErr(Str)])

Email.Options := {
    from : Str ?? "",                              # "": MAIL_FROM, or else "rocx <rocx@localhost>"
    smtp_url! : ({} => Str) ?? (reads SMTP_URL),   # "": no SMTP server; mail is kept for the mailbox
}
Email.plugin : Email.Options -> Plugin.Value(context, ctx)
```

**`send!`** sends one message and waits for the SMTP server's answer: `Ok({})`, or `EmailErr(why)`
when an address can't be read, or the server refuses the message or can't be reached. `to` is one
address, bare (`ada@example.com`) or with a name (`Ada Lovelace <ada@example.com>`); `from` takes
the same forms. `html` may be `""`, for text alone.

With no SMTP server, `send!` keeps the message for the dev mailbox, logs
`email: kept, not sent (no SMTP_URL)` at info with `to` and `subject` as fields, and answers
`Ok({})`. That is true without `--dev` too: set `SMTP_URL` wherever the app should really send.

**`plugin`** adds:

- **Its settings, read once at start.** `from`, or else `MAIL_FROM`, or else `rocx <rocx@localhost>`;
  and the SMTP server's URL from `smtp_url!`, which reads `SMTP_URL` unless the app gives a function
  of its own (a secret kept in a vault).
- **A check of the SMTP server** (`email.smtp`), once the server has started: it connects (TLS and
  all) and says goodbye, and logs whether the server answered. A wrong URL shows then, not at the
  first email. A server that doesn't answer doesn't stop the app.
- **The dev mailbox's paths**, answered before the app, under `--dev` (its JSON under `--debug`
  too). See below.

Without the plugin, `send!` still works, reading `SMTP_URL` and `MAIL_FROM` itself on each send; only
the mailbox's pages and the check are missing.

### `Smtp`

| Function | What it does |
|---|---|
| `Url : { tls : [Implicit, Required, Opportunistic, Never], host : Str, port : U16, user : Str, password : Str }` | Where to send, and how. |
| `parse : Str -> Try(Url, Str)` | An `SMTP_URL`, or what is wrong with it. |
| `send! : Url, Str, Str, Str => Try({}, Str)` | Hands a message (its lines ending in CRLF) to the server, from one bare address to another. |
| `check! : Url => Try({}, Str)` | Whether the server answers: its greeting, TLS if asked for, and a goodbye. |

### `Mailbox`

| Function | What it does |
|---|---|
| `Message : { at : I64, from : Str, to : Str, subject : Str, text : Str, html : Str, raw : Str }` | A kept message; `raw` is the whole message as SMTP's DATA would carry it. |
| `keep! : Message => {}` | Keeps a message (the last 100) and tells open mailbox pages. |
| `early : List(Plugin.Early)` | The mailbox's paths, which the plugin answers before the app. |
| `respond! : Server.Request => Server.Response` | Answers one of those paths. |

## The SMTP server's URL

| URL | Connection | Default port |
|---|---|---|
| `smtps://user:password@host` | TLS from the start | 465 |
| `smtp://user:password@host?tls=required` | STARTTLS; fails if the server doesn't offer it | 587 |
| `smtp://host?tls=opportunistic` | STARTTLS if offered, plain otherwise | 25 |
| `smtp://host` | plain | 25 |

A port in the URL overrides the default. With a user in the URL the client signs in with
`AUTH PLAIN`; the user and the password are `%`-decoded.

## How it works

- **The message** (`Email.roc`): `Date`, `From`, `To`, `Subject`, `Message-ID` and `MIME-Version`
  headers, then the text alone (`text/plain`) or the text and the HTML (`multipart/alternative`).
  A subject that isn't printable ASCII is an encoded word (RFC 2047). A body that is ASCII with
  short lines is sent as it is (7bit); any other is sent as Base64 (packages/crypto's
  `Base64.lines`).
- **The client** (`Smtp.roc`) is Roc over the platform's `Tcp`: EHLO, STARTTLS or TLS from the start,
  `AUTH PLAIN`, `MAIL FROM`, one `RCPT TO`, `DATA` (lines starting with a dot are doubled), `QUIT`.
  Each send opens its own connection.
- **The dev mailbox** (`Mailbox.roc`) is drawn in packages/admin's look. Messages are kept in `Kv`
  under `email:mailbox` (the last 100, newest first), with or without a database, so a restart
  forgets them. A kept message is published on the live topic `email:mailbox`, and an open mailbox
  page, which listens to a stream of events (`/__rocx/mail?events`), updates.

The package depends on packages/admin (the mailbox's look), packages/jobs (its `Calendar`, for the
`Date` header; admin's look uses it too) and packages/crypto (Base64).

## The dev mailbox

| Path | Under | What it is |
|---|---|---|
| `GET /__rocx/mail` | `--dev` | The messages kept, newest first (when, from, to, subject), with a **Clear** button. JSON when asked for (`accept: application/json`). |
| `GET /__rocx/mail/<id>` | `--dev` | One message: its headers, its text, its HTML in a sandboxed frame (`<iframe sandbox srcdoc>`: no script runs in it, a link opens in a new tab), and the raw message. |
| `POST /__rocx/mail/clear` | `--dev` | Clears the mailbox (from its own page only: other origins get a 403). |
| `GET /__rocx/mail.json` | `--dev` or `--debug` | Every message, oldest first: `id`, `at`, `from`, `to`, `subject`, `text`, `html`, `raw`. With `--debug` alone, `/__rocx/mail` answers this JSON too. |

Without `--dev` or `--debug`, those paths are the app's. packages/testing's `waitForMail` reads the
JSON.

## Not yet

- One recipient per message: no Cc, no Bcc.
- No attachments, no Reply-To or other headers of the app's own.
- Mail kept for the mailbox lives in memory only, so a restart forgets it. That is on purpose.

## Moving from `pf.Email`

Email used to be part of the server platform. An app that used it:

- names the package in its header (`email: "…/packages/email/main.roc"`), and imports `email.Email`
  instead of `pf.Email` (route files too);
- lists the plugin, `plugins: [Email.plugin({})]`, for the dev mailbox and the check at start;
- sets `SMTP_URL` and `MAIL_FROM` in the environment (or passes `from` and `smtp_url!`) instead of
  the server's old `--smtp-url` and `--mail-from` flags, which the server now refuses, saying why.

The mailbox's paths and its JSON didn't change.
