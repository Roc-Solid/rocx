# email

Email for a Roc Solid app's server, as a plugin (D-035): messages over SMTP, as text or text and
HTML; or, with no SMTP server, kept in the server's memory for the dev mailbox, so development sends
nothing. It names the server platform, so only an app on it names this package: the browser's half
doesn't see it.

```roc
# main.roc
app [program] { email: "../packages/email/main.roc", jobs: "../packages/jobs/main.roc", pf: platform "../server/platform/main.roc" }

import email.Email
import jobs.Job
import Generated/App
import Middlewares

program = App.program({
    context: |started| { facts: started },
    middleware: Middlewares.default,
    plugins: [Job.plugin({ jobs: App.jobs }), Email.plugin({})],
})
```

```roc
# Jobs.roc: send from a job, so a server that doesn't answer is tried again
welcome = Job.define("welcome", |{ to }|
    match Email.send!({ to, subject: "Welcome", text: "…", html: "<p>…</p>" }) {
        Ok({}) => Ok({})
        Err(EmailErr(why)) => Err(why)
    })
```

## The plugin

```roc
Email.Options := {
    from : Str ?? "",                              # "": MAIL_FROM, or else "rocx <rocx@localhost>"
    smtp_url! : ({} => Str) ?? (reads SMTP_URL),   # "" for none: mail is kept for the mailbox
}
Email.plugin : Email.Options -> Plugin.Value(ctx)
```

- **Where mail goes** is read when the server starts: `SMTP_URL` from the environment
  (`smtp://user:password@host:587?tls=required` for STARTTLS, `smtps://user:password@host:465` for
  TLS from the start), unless the app gives `smtp_url!`, a function that finds it elsewhere (a
  secret in a vault). **Who it is from**: `from`, or else `MAIL_FROM`.
- **A look at the SMTP server** (`email.smtp`), once the server has started: its greeting, TLS, a
  goodbye; whether it answers is on the log, so a wrong URL shows then, not at the first email. A
  server that doesn't answer doesn't stop the app.
- **The dev mailbox's paths**, before the app, only under `--dev` (its JSON under `--debug` too).

Without the plugin listed, `Email.send!` still works, reading `SMTP_URL` and `MAIL_FROM` itself;
only the mailbox's pages and the check are missing.

## Sending

`Email.send!({ to, subject, text, html })` waits for the SMTP server's answer: `Ok`, or
`EmailErr(why)` (an address it can't read, a server that refuses it or can't be reached). `html`
may be empty, for text alone. The client is Roc (`Smtp.roc`, over the platform's `Tcp`): STARTTLS
or TLS from the start, `AUTH PLAIN` when the URL has a user; a subject that isn't ASCII is encoded
(RFC 2047), a body that isn't is sent as base64 (packages/crypto's `Base64`), text and HTML as
`multipart/alternative`. With no SMTP server, the message is kept for the mailbox and logged
(`email: kept, not sent (no SMTP_URL)`, at info, with `to` and `subject`).

## The dev mailbox

Under `--dev` the plugin answers `/__rocx/mail` before the app (`Mailbox.roc`): the email kept,
newest first (when, from, to, subject), a **Clear** button (`POST /__rocx/mail/clear`), and each
message at `/__rocx/mail/<id>`: its headers, its text, its HTML in a sandboxed frame (`<iframe
sandbox srcdoc>`: no script runs in it, a link opens in a new tab), and the message whole, as SMTP's
DATA would have carried it. It is drawn in packages/admin's look. The list updates as mail comes (a
stream of events, `/__rocx/mail?events`, on the live topic `email:mailbox`). The last 100 are kept
in the server's memory (`Kv`, under `email:mailbox`), database or not, so a restart forgets them.
The JSON (oldest first: id, at, from, to, subject, text, html, raw) is at `/__rocx/mail.json`, and
at `/__rocx/mail` when asked for (`accept: application/json`); with `--debug` alone (the tests:
packages/testing reads it), only the JSON is served. Without `--dev` or `--debug`, those paths are
the app's.

## Modules

| Module | What it has |
|---|---|
| `Email` | `Message`, `send!`, and the plugin (`Options`, `plugin`) |
| `Smtp` | `Url`, `parse` (an `SMTP_URL`), `send!` (a message, as DATA), `check!` (whether a server answers) |
| `Mailbox` | the dev mailbox: `keep!`, its early paths (`early`), `respond!` |

It depends on packages/admin (the mailbox's look), packages/jobs (dates, through admin's look too)
and packages/crypto (Base64).

## Moving to it

From the platform's `pf.Email` (before D-035):

- Name the package in the app's header (`email: "…/packages/email/main.roc"`), and import
  `email.Email` instead of `pf.Email` (route files too).
- List the plugin: `plugins: [Email.plugin({})]`, for the dev mailbox and the check at start;
  `Email.plugin({ from: "Acme <hello@example.com>" })` says who mail is from in the app.
- `--smtp-url URL` and `--mail-from ADDRESS` are gone: set `SMTP_URL` and `MAIL_FROM` in the server's
  environment (as the server already read them), or pass `from` and `smtp_url!`. The server refuses
  the flags, saying so.
- The log's event for mail kept is `email: kept, not sent (no SMTP_URL)`, with `to` and `subject` as
  fields (D-056), and the check's is what it says, with `check=email.smtp` (it was `rocx mail …`).
- The mailbox's paths and its JSON are as they were, so packages/testing and tests reading
  `/__rocx/mail.json` change nothing.

## Limits, for now

- No attachments, Cc or Bcc.
- Mail kept for the mailbox is in memory only: a restart forgets it, on purpose.
