# email

Email for a Roc Solid app's server, as a plugin: messages over SMTP, as text or as text and HTML, to
one recipient or several, with Cc, Bcc, Reply-To and headers of the app's own.
With no SMTP server set, under `--dev` (and `--debug`, the tests'), a message is kept in the server's
memory instead, and the dev mailbox shows it, so development sends nothing. Anywhere else a server
with no SMTP server would lose every message, so it doesn't start (D-079).

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

program = App.program({
    init!: |started| Ok({ facts: started }),
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
Email.Message := {
    to : Str,                          # one address, or several separated by commas
    subject : Str,
    text : Str,
    html : Str ?? "",                  # "": text alone
    cc : List(Str) ?? [],              # each item one address or several, as `to`
    bcc : List(Str) ?? [],             # as `cc`; named in no header
    reply_to : Str ?? "",              # "": replies go to who it is from
    headers : List((Str, Str)) ?? [],  # the app's own: ("List-Unsubscribe", "<https://…>")
}
Email.send! : Email.Message => Try({}, [EmailErr(Str)])

Email.Options := {
    from : Str ?? "",                              # unless MAIL_FROM is set; "": "rocx <rocx@localhost>"
    smtp_url! : ({} => Str) ?? (reads SMTP_URL),   # "": no SMTP server: --dev and --debug only
}
Email.plugin : Email.Options -> Plugin.Value(context)
```

**`Message`** is a record with defaults: only `to`, `subject` and `text` must be given, so
`{ to, subject, text, html }` is a message, as it was before Cc and the rest. A message the app
builds before it sends it is an `Email.Message` (a function that returns one says so in its type, or
a local is written `message : Email.Message`): a plain record type, even with the same fields, isn't
one.

- **`to`** is one address, bare (`ada@example.com`) or with a name (`Ada Lovelace <ada@example.com>`),
  or several, separated by commas, as an email's `To` header has them (RFC 5322's address list):
  `Ada <ada@example.com>, grace@example.com`. A comma inside a quoted name is the name's:
  `"Lovelace, Ada" <ada@example.com>`; unquoted, `Lovelace, Ada <ada@example.com>` is two items, and
  `Lovelace` isn't an address, so the send fails saying so. Empty places between commas are
  skipped. It must name at least one address (for mail to Bcc alone, put your own address in `to`).
  A `Str` and not a list, so every message written before Cc keeps working, and a list of people
  is one `Str.join_with(list, ", ")` away. `from` takes one address, in the same forms.
- **`cc`** are more who see the message, in its `Cc` header; each item is one address or several,
  as `to` is.
- **`bcc`** are more who get it, written as `cc` is, and named in no header: only the SMTP server is
  told (`RCPT TO`), so nobody who gets the message sees them, the dev mailbox's raw message
  included.
- **`reply_to`** is where a reply goes (a `Reply-To` header), one address or several; `""` for none,
  so replies go to who it is from.
- **`headers`** are the app's own, written after the package's, `("List-Unsubscribe",
  "<https://example.com/unsubscribe?t=…>")` say. A value that isn't printable ASCII is an encoded
  word (RFC 2047), as the subject is. Refused, so the send fails saying why: a CR or LF in a name or
  a value (it would start a header of its own: a `Bcc` that adds a recipient); a name that is empty
  or isn't printable ASCII without a space or colon; and the headers the package writes itself,
  in any case: `From`, `To`, `Cc`, `Bcc`, `Reply-To`, `Subject`, `Date`, `Message-ID`,
  `MIME-Version` and `Content-*` (give the message's field instead); and a header longer than the
  998 bytes SMTP lets a line be.
- **`html`** may be `""`, for text alone.

**`send!`** sends one message and waits for the SMTP server's answer: `Ok({})`, or `EmailErr(why)`
when an address can't be read (`to …`, `cc …`, `bcc …`, `reply_to …`, `from …`: which, and why),
`to` has none, a header is refused (`header …`), the server refuses the message or a recipient, or
can't be reached, or there is no SMTP server outside `--dev` and `--debug`. A recipient the server
refuses fails the whole message, before it goes, so nobody gets it, and a job sending it tries it
again (fix the address, or catch the error).

With no SMTP server, under `--dev` or `--debug` (`Env.dev!`, `Env.debug!`), `send!` keeps the
message for the dev mailbox, logs `email: kept, not sent (no SMTP_URL)` at info with `to` and
`subject` as fields, and answers `Ok({})`. Anywhere else it answers `EmailErr("email to …: SMTP_URL
isn't set, so email can't be sent: …")`, and the message is lost; with the plugin listed, such a
server never gets that far, as its start refuses it (below).

**`plugin`** adds:

- **Its settings, read once at start.** `MAIL_FROM` when it is set (so a deploy names the sender),
  or else `from`, or else `rocx <rocx@localhost>`;
  and the SMTP server's URL from `smtp_url!`, which reads `SMTP_URL` unless the app gives a function
  of its own (a secret kept in a vault). With no SMTP server, and neither `--dev` nor `--debug`, the
  start fails, so the server doesn't start: it logs `rocx server: can't start` with `email: SMTP_URL
  isn't set, so email can't be sent: …` and exits, rather than run and lose every email.
- **A check of the SMTP server** (`email.smtp`), once the server has started: it connects (TLS and
  all) and says goodbye, and logs whether the server answered. A wrong URL shows then, not at the
  first email. A server that doesn't answer doesn't stop the app.
- **The dev mailbox's paths**, answered before the app, under `--dev` (its JSON under `--debug`
  too). See below.

Without the plugin, `send!` still works, reading `SMTP_URL` and `MAIL_FROM` itself on each send; the
mailbox's pages, the check and the refusal at start are missing (each send fails instead).

### `Smtp`

| Function | What it does |
|---|---|
| `Url : { tls : [Implicit, Required, Opportunistic, Never], host : Str, port : U16, user : Str, password : Str }` | Where to send, and how. |
| `parse : Str -> Try(Url, Str)` | An `SMTP_URL`, or what is wrong with it. |
| `send! : Url, Str, List(Str), Str => Try({}, Str)` | Hands a message (its lines ending in CRLF) to the server, from one bare address to each of a list (a `RCPT TO` each; one refused fails it all, before the message goes). |
| `check! : Url => Try({}, Str)` | Whether the server answers: its greeting, TLS if asked for, and a goodbye. |

### `Mailbox`

| Function | What it does |
|---|---|
| `Message : { at : I64, from : Str, to : Str, cc : List(Str), bcc : List(Str), reply_to : Str, headers : List({ name : Str, value : Str }), subject : Str, text : Str, html : Str, raw : Str }` | A kept message: its addresses as the app gave them; `raw` is the whole message as SMTP's DATA would carry it (no header in it names `bcc`). |
| `keep! : Message => {}` | Keeps a message (the last 100) and tells open mailbox pages. |
| `early : List(Plugin.Early)` | The mailbox's paths, which the plugin answers before the app. |
| `respond! : Server.Request => Server.Response` | Answers one of those paths. |

## The SMTP server's URL

| URL | Connection | Default port |
|---|---|---|
| `smtps://user:password@host` | TLS from the start | 465 |
| `smtp://user:password@host?tls=required` | STARTTLS; fails if the server doesn't offer it | 587 |
| `smtp://user:password@host` | STARTTLS, required as above: a password never goes in clear | 25 |
| `smtp://host?tls=opportunistic` | STARTTLS if offered, plain otherwise (with a user: refused if not offered) | 25 |
| `smtp://host` | plain | 25 |
| `smtp://user:password@host?tls=never` | plain, the password too (a relay on this machine) | 25 |

A port in the URL overrides the default. With a user in the URL the client signs in with
`AUTH PLAIN`; the user and the password are `%`-decoded. The password goes in clear only when the
URL says `?tls=never`.

## How it works

- **The message** (`Email.roc`): `Date`, `From`, `To`, `Cc` and `Reply-To` (when it has them),
  `Subject`, `Message-ID` and `MIME-Version` headers, the app's own, then the text alone
  (`text/plain`) or the text and the HTML (`multipart/alternative`). Every address is read first
  (`addresses`: commas outside quoted names part them); a header of addresses is folded onto lines
  that start with a space before one would pass 78 bytes. A subject, a header's value, or a name in
  an address that isn't printable ASCII is an encoded word (RFC 2047), so a CR or LF in one (a name
  a user typed) can't start a header of its own. A body that is ASCII with short lines is sent as
  it is (7bit); any other is sent as Base64 (packages/crypto's `Base64.lines`).
- **The client** (`Smtp.roc`) is Roc over the platform's `Tcp`: EHLO, STARTTLS or TLS from the start,
  `AUTH PLAIN`, `MAIL FROM`, a `RCPT TO` for each address in `to`, `cc` and `bcc` (each once),
  `DATA` (lines starting with a dot are doubled), `QUIT`. Each send opens its own connection.
- **The dev mailbox** (`Mailbox.roc`) is drawn in packages/admin's look. Messages are kept in `Kv`
  under `email:mailbox` (the last 100, newest first), with or without a database, so a restart
  forgets them. A kept message is published on the live topic `email:mailbox`, and an open mailbox
  page, which listens to a stream of events (`/__rocx/mail?events`), updates.

The package depends on packages/admin (the mailbox's look), packages/jobs (its `Calendar`, for the
`Date` header; admin's look uses it too) and packages/crypto (Base64).

## The dev mailbox

| Path | Under | What it is |
|---|---|---|
| `GET /__rocx/mail` | `--dev` | The messages kept, newest first (when, from, to with how many Cc and Bcc items, subject), with a **Clear** button. JSON when asked for (`accept: application/json`). |
| `GET /__rocx/mail/<id>` | `--dev` | One message: its headers (Cc, Bcc, marked as in no header, Reply-To and the app's own when it has them), its text, its HTML in a sandboxed frame (`<iframe sandbox srcdoc>`: no script runs in it, a link opens in a new tab), and the raw message. |
| `POST /__rocx/mail/clear` | `--dev` | Clears the mailbox (from its own page only: other origins get a 403). |
| `GET /__rocx/mail.json` | `--dev` or `--debug` | Every message, oldest first: `id`, `at`, `from`, `to`, `cc`, `bcc`, `reply_to`, `headers` (`{ name, value }`s), `subject`, `text`, `html`, `raw`. With `--debug` alone, `/__rocx/mail` answers this JSON too. |

Without `--dev` or `--debug`, those paths are the app's. packages/testing's `waitForMail` reads the
JSON.

## Not yet

- No attachments.
- No groups in an address list (`undisclosed-recipients:;`), and no comments in an address
  (`ada@example.com (Ada)`).
- Mail kept for the mailbox lives in memory only, so a restart forgets it. That is on purpose.

## Moving from `pf.Email`

Email used to be part of the server platform. An app that used it:

- names the package in its header (`email: "…/packages/email/main.roc"`), and imports `email.Email`
  instead of `pf.Email` (route files too);
- lists the plugin, `plugins: [Email.plugin({})]`, for the dev mailbox and the check at start;
- sets `SMTP_URL` and `MAIL_FROM` in the environment (or passes `from` and `smtp_url!`) instead of
  the server's old `--smtp-url` and `--mail-from` flags, which the server now refuses, saying why.

The mailbox's paths and its JSON didn't change.
