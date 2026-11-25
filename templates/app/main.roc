## {{title}}, a Roc Solid app. People sign in by a link mailed to them, or at Google or GitHub once
## those are set up; under `rocx dev`, as any address at once. README.md says how to run it, what
## each file is, and how to put it on a server.
##
## This is the server's program. `rocx build` writes nearly all of it from `routes/` (pages,
## layouts and endpoints) into `Generated/App`, with `migrations/` in it. This file says the rest:
## the middleware around every request, the plugins (mail and sign-in), and the database.
app [program] { auth: "{{root}}/packages/auth/main.roc", crypto: "{{root}}/packages/crypto/main.roc", email: "{{root}}/packages/email/main.roc", guard: "{{root}}/packages/guard/main.roc", pf: platform "{{root}}/server/platform/main.roc", testing: "{{root}}/packages/testing/main.roc" }

import auth.Auth
import email.Email
import Generated/App
import Accounts
import Middlewares

program = App.program({
	init!: |_started| Ok({}),
	# Around every request: a post from another site refused, and the security headers.
	middleware: Middlewares.default,
	plugins: [
		# Mail goes out over SMTP_URL; without it, under rocx dev, to the dev mailbox (/__rocx/mail),
		# and anywhere else the server doesn't start. Put an address here that your mail service lets
		# you send from.
		Email.plugin({ from: "{{title}} <hello@example.com>" }),
		# Signing in (packages/auth): a mailed link opens /sign-in/link, and `Accounts.admit!` says
		# which user someone is. A provider is offered once its environment variables are set.
		Auth.plugin({ admit!: Accounts.admit!, providers: [Auth.google, Auth.github], link_page: "/sign-in/link", cookie: "{{name}}_session" }),
	],
	# Where the data is: `Sqlite("data/app.db")`, a file beside the server; `Turso("data/app.db")`,
	# the same on Turso's engine; or `Postgres`, at DATABASE_URL.
	database: Sqlite("data/app.db"),
})
