## {{title}}, a Roc Solid app. People sign in by a link mailed to them, or at Google or GitHub once
## those are set up; under `rocx dev`, as any address at once; and those who turn on two-factor
## sign-in (their account page) give a code from an authenticator app too. README.md says how to run
## it, what each file is, and how to put it on a server.
##
## This is the server's program. `rocx build` writes nearly all of it from `routes/` (pages,
## layouts and endpoints, and the middleware: each `+middleware.roc` runs around the routes in its
## directory) into `Generated/App`, with `migrations/` in it. This file says the rest: the plugins
## (mail and sign-in), and the database.
app [program] { auth: "{{root}}/packages/auth/main.roc", crypto: "{{root}}/packages/crypto/main.roc", email: "{{root}}/packages/email/main.roc", guard: "{{root}}/packages/guard/main.roc", pf: platform "{{root}}/server/platform/main.roc", qr: "{{root}}/packages/qr/main.roc", testing: "{{root}}/packages/testing/main.roc" }

import auth.Auth
import email.Email
import Generated/App
import Accounts
import Middlewares

program = App.program({
	init!: |_started| Ok({}),
	plugins: [
		# Mail goes out over SMTP_URL; without it, under rocx dev, to the dev mailbox (/__rocx/mail),
		# and anywhere else the server doesn't start. Put an address here that your mail service lets
		# you send from.
		Email.plugin({ from: "{{title}} <hello@example.com>" }),
		# Signing in (packages/auth): a mailed link opens /sign-in/link, and `Accounts.admit!` says
		# which user someone is. A provider is offered once its environment variables are set.
		# Two-factor sign-in, for those who turn it on: their sign-in waits at /sign-in/code for the
		# code their authenticator app shows. Its secrets are sealed under a key from APP_SECRET:
		# set it where the server runs (`rocx dev` makes do without).
		Auth.plugin({ middleware: Middlewares.default, admit!: Accounts.admit!, providers: [Auth.google, Auth.github], link_page: "/sign-in/link", cookie: "{{name}}_session", two_factor: Bool.True, issuer: "{{title}}" }),
	],
	# Where the data is: `Sqlite("data/app.db")`, a file beside the server; `Turso("data/app.db")`,
	# the same on Turso's engine; or `Postgres`, at DATABASE_URL.
	database: Sqlite("data/app.db"),
})
