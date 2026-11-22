## Email for Roc Solid's server, as a plugin (`Email.plugin`): messages sent over SMTP (`Smtp`, on
## the platform's `Tcp`: STARTTLS or TLS from the start, AUTH PLAIN), as text or text and HTML; or,
## with no SMTP server, kept in the server's memory for the dev mailbox (`Mailbox`, `/__rocx/mail`
## under `--dev`), drawn in packages/admin's look. It names the server platform, so only an app on
## it names this package; the browser's half doesn't see it.
package [Email, Mailbox, Smtp] { admin: "../admin/main.roc", crypto: "../crypto/main.roc", jobs: "../jobs/main.roc", pf: platform "../../server/platform/main.roc" }
