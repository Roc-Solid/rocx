## packages/auth's example: an app whose people sign in by a mailed link, or at a provider, and
## whose own table of users `Accounts.admit!` fills. The plugin brings its tables (D-072), the
## package its handlers, which the app's routes in routes/auth/ call (D-116: a link and a provider
## coming back, the code, signing out, the dev sign-in), and the middleware `Middlewares` names
## (each group's `+middleware.roc` puts one around its routes). Its pages are its own: a home page that says who is signed in,
## a sign-in page (an address, the providers set up, and the dev sign-in under `--dev`), and the page
## a mailed link opens, whose button signs in (so a mail scanner that opens the link can't use it).
## An admin (`ADMIN_EMAILS`) may act as anyone for half an hour (`/impersonate`), to see the app as
## they do. Anyone may turn on two-factor sign-in (`/two-factor`: a code from an authenticator app
## after the link or the provider, or a recovery code), which `/admin` asks its admins to have;
## its secrets are sealed under a key from `APP_SECRET`. Roles (`Roles`, D-127): an admin gives
## someone Pro as a gift, for good or for days (`/roles/grant`), and ends it (`/roles/revoke`);
## anyone may start a two-week trial once (`/trial`); `/roles` lists one's grants, past ones too,
## and `/pro` is for those who hold it.
app [program] { auth: "../main.roc", crypto: "../../crypto/main.roc", email: "../../email/main.roc", pf: platform "../../../server/platform/main.roc" }

import auth.Auth
import email.Email
import Generated/App
import Accounts

program = App.program({
	init!: |_started| Ok({}),
	plugins: [
		Email.plugin({ from: "Example <example@example.com>" }),
		Auth.plugin({ providers: Accounts.providers, link_page: "/sign-in/link", refusal: "Sign in first, at /sign-in.", two_factor: Bool.True, issuer: "Auth example" }),
	],
	database: Sqlite("data/auth.db"),
})
