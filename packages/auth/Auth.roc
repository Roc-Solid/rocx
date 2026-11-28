import pf.AesGcm
import pf.Db
import pf.Endpoint
import pf.Env
import pf.Http
import pf.Log
import pf.Middleware
import pf.Plugin
import pf.Random
import pf.Server
import pf.Time
import crypto.Base64
import crypto.Uuid
import AuthStore
import Rules
import Totp
import "migrations/0001_auth.sql" as table : Str
import "migrations/0002_impersonation.sql" as impersonation : Str
import "migrations/0003_two_factor.sql" as two_factor_tables : Str
import "migrations/0004_two_factor_misses.sql" as two_factor_misses : Str
import "migrations/0005_roles.sql" as roles_table : Str
import "migrations/0006_users.sql" as users_table : Str

## Sign-in for Roc Solid apps (D-072): by a link mailed to an address, or at a provider (Google,
## GitHub, any OpenID Connect one); sessions kept as their token's hash in the app's database;
## middleware that hands the signed-in user on. It has no pages: the app's sign-in page posts to its
## steps and links to them, and the app's `admit!` says who gets in. With `two_factor`, a user who
## turned it on gives a code from an authenticator app (or a recovery code) after that.
##
## ```roc
## plugins: [Auth.plugin({ providers: Accounts.providers })]   # its tables and settings
## ```
##
## Its steps are the app's routes (D-116): a route file under `at` (`routes/auth/` for `/auth`)
## for each, calling its handler, behind the middleware of the folder it is in (which must let a
## signed-out request through: these are how one signs in):
##
## ```roc
## # routes/auth/[provider]/+server.roc: GET <at>/<provider>?then=…, off to a provider
## respond! = |{ request, params, .. }| Auth.provider_route!(request, Accounts.providers, params.provider)
## # routes/auth/[provider]/callback/+server.roc: GET, back from it (the redirect URI to register)
## respond! = |{ request, params, .. }| Auth.callback_route!(request, Accounts.providers, params.provider, Accounts.admit!)
## # routes/auth/link/+server.roc: GET|POST <at>/link?token=…, a mailed link, used once
## respond! = |{ request, .. }| Auth.link_route!(request, Accounts.admit!)
## # routes/auth/code/+server.roc: POST, a sign-in's second factor, from the app's `code_page`
## respond! = |{ request, .. }| Auth.code_route!(request)
## # routes/auth/sign-out/+server.roc: POST
## respond! = |{ request, .. }| Auth.sign_out_route!(request)
## # routes/auth/dev/+server.roc: POST, any address, under --dev only (404 otherwise)
## respond! = |{ request, .. }| Auth.dev_route!(request, Accounts.admit!)
## ```
##
## An app lists only the steps it uses. Each answers with a redirect: where the browser was going, or
## the app's sign-in page with why not (`?error=link|refused|provider|state|unavailable|attempts|locked|timeout`,
## and `&reason=` for `refused` and `provider`), or the code page after a wrong code (`?error=code`);
## a method it doesn't take, 405.
Auth := [].{

	## Who is signing in, as the plugin hands them to `admit!`: the provider ("email" for a link or
	## the dev sign-in), who they are there (the address, or the provider's own id for them), their
	## address (lower-cased; "" when the provider has none it says is verified), their name (or ""),
	## the user this identity signed in as before (`Known`), if it has, and where the sign-in goes
	## after (`then`: an invite's page, say, which `admit!` may act on).
	Identity : { provider : Str, subject : Str, email : Str, name : Str, user : [New, Known(Str)], then : Str }

	## A signed-in session: the app's id for the user it acts as, the session's own id (for
	## `revoke!`), when it ends (milliseconds since 1970), and who really signed in (`real_user`: the
	## same as `user`, but while an admin impersonates someone, `impersonate!`). Check permissions
	## with `user`; record who did what, and guard what only the person themselves may change (their
	## password, their sessions), with `real_user`.
	Session : { user : Str, id : Str, expires_ms : I64, real_user : Str }

	## Whether a request is signed in, as `optional` hands it on.
	Signed : [SignedOut, SignedIn(Auth.Session)]

	## A provider to sign in at: its name (its endpoints are `<at>/<name>` and
	## `<at>/<name>/callback`, the redirect URI to register with it), the label for the app's
	## button, how it says who signed in (`Oidc`: an ID token from one of these issuers; `GitHub`:
	## its API at this URL), its endpoints, the scopes asked for, more parameters for its
	## authorization endpoint (`params`), and the environment variables that hold the app's client
	## id and secret there. `Auth.google`, `Auth.github` and `Auth.oidc` make
	## one; a record update changes any part (`{ ..Auth.google, client_id_env: "ACME_GOOGLE_ID" }`).
	Provider : {
		name : Str,
		label : Str,
		flow : [Oidc(List(Str)), GitHub(Str)],
		authorize_url : Str,
		token_url : Str,
		scopes : List(Str),
		params : List((Str, Str)),
		client_id_env : Str,
		client_secret_env : Str,
	}

	## The plugin's options:
	## - `at`: where the app's route files for its steps are (`/auth`: `routes/auth/`), which its
	##   links and a provider's redirect URI are made with.
	## - `sign_in`: the app's sign-in page, where a signed-out request (`required`) and a sign-in
	##   that failed go (`/sign-in`).
	## - `home`: where a sign-in goes when it wasn't going anywhere (`/`).
	## - `providers`: where else one may sign in (none: links alone): the list the app's provider
	##   routes are given too, so keep it in a module they import (`Accounts.providers`).
	## - `session_ms`: how long a session lasts (30 days); one used in its second half is kept for
	##   as long again.
	## - `link_ms`: how long a mailed link is good for (15 minutes).
	## - `link_page`: the app's page a mailed link opens (`/sign-in/link`), which shows whom it signs
	##   in (`link_for!`) and posts its token to `<at>/link` from a button. A mail scanner that
	##   follows every link in a message then can't use one up. "" (the default): the link goes
	##   straight to `<at>/link`, and opening it signs in.
	## - `cookie`: the session cookie's name (`session`, `__Host-session` on HTTPS).
	## - `refusal`: the words of the 401 `required` answers a signed-out request that isn't a page's
	##   GET ("Sign in first.").
	## - `two_factor`: whether a user may turn on two-factor sign-in (`two_factor_start!`): then a
	##   sign-in of theirs, every way, waits for a code from their authenticator app, or a recovery
	##   code, at `code_page`. Off (the default), nobody is asked.
	## - `code_page`: the app's page a sign-in waiting for its code goes to (`/sign-in/code`), which
	##   posts `code` (and `then`) to `<at>/code`. It must not need a signed-in user.
	## - `issuer`: the name authenticator apps show beside the account ("" (the default): the
	##   public URL's host).
	## - `key_env`: the environment variable with the app's secret (`APP_SECRET`), at least 32
	##   characters (`openssl rand -hex 32`), from which the key that seals each authenticator's
	##   secret is derived. With `two_factor`, the server doesn't start without it, but under `--dev`,
	##   where a development secret stands in (on the log).
	Options := {
		at : Str ?? "/auth",
		sign_in : Str ?? "/sign-in",
		home : Str ?? "/",
		providers : List(Auth.Provider) ?? [],
		session_ms : U64 ?? 2_592_000_000,
		link_ms : U64 ?? 900_000,
		link_page : Str ?? "",
		cookie : Str ?? "session",
		refusal : Str ?? "Sign in first.",
		two_factor : Bool ?? Bool.False,
		code_page : Str ?? "/sign-in/code",
		issuer : Str ?? "",
		key_env : Str ?? "APP_SECRET",
	}

	## What the plugin keeps for the functions and middleware an app calls (`Plugin.keep!`).
	Settings : {
		at : Str,
		sign_in : Str,
		home : Str,
		session_ms : I64,
		link_ms : I64,
		link_page : Str,
		cookie : Str,
		refusal : Str,
		providers : List({ name : Str, label : Str, client_id_env : Str }),
		two_factor : Bool,
		code_page : Str,
		issuer : Str,
		key_env : Str,
	}

	## Whether a user's two-factor sign-in is on: `Off`; `Pending` (an authenticator started, waiting
	## for its first code: `two_factor_confirm!`); or `On`, since when (milliseconds since 1970), with
	## how many unused recovery codes they have.
	TwoFactor : [Off, Pending, On({ since_ms : I64, recovery_codes : U64 })]

	## One of the app's users, as the package keeps them (`user_for!`): their id (a version 7 UUID),
	## their address as it is now (lower-cased), and when they were made (milliseconds since 1970).
	User : { id : Str, email : Str, created_ms : I64 }

	## The auth plugin: its tables (`auth/0001_auth` to `auth/0006_users`, the same on
	## SQLite and Postgres) and its settings, kept at start for its handlers and middleware. No
	## routes (D-116): the app's route files call its handlers (`provider_route!` and the rest). It
	## needs a database; with `two_factor`, the app's secret too (it won't start without it, but
	## under `--dev`).
	plugin : Auth.Options -> Plugin.Value(context)
	plugin = |options| {
		settings = settings_of(options)
		{
			name: "auth",
			migrations: [{ name: "0001_auth", sql: table }, { name: "0002_impersonation", sql: impersonation }, { name: "0003_two_factor", sql: two_factor_tables }, { name: "0004_two_factor_misses", sql: two_factor_misses }, { name: "0005_roles", sql: roles_table }, { name: "0006_users", sql: users_table }],
			starts: [
				|_context| {
					Plugin.keep!("auth:settings", Json.to_str(settings))
					if settings.two_factor {
						# The key, checked now rather than at someone's first code.
						_ = sealing_key!(settings)?
						if Env.var!(settings.key_env).map_ok(|text| text.trim().is_empty()) ?? Bool.True {
							Log.warn!("auth: two-factor secrets are sealed under a development key, as ${settings.key_env} isn't set (under --dev only)", { env: settings.key_env })
						}
					}
					Ok({})
				},
			],
			needs: [Database],
			# Under --dev, the way in (D-111): the app's sign-in page.
			links: [{ label: "Sign in", path: settings.sign_in }],
		}
	}

	## A provider's first step, `GET <at>/<provider>?then=…` (`routes/auth/[provider]/+server.roc`,
	## D-116): off to the provider called `name` among `providers` (the plugin's list,
	## `Accounts.providers`), which asks who is signing in. 404 for a name none of them has; 405 for a
	## method but GET.
	provider_route! : Server.Request, List(Auth.Provider), Str => Server.Response
	provider_route! = |request, providers, name|
		taking!(
			request,
			["GET"],
			|{}|
				match providers.find_first(|provider| provider.name == name) {
					Ok(provider) => away!(settings!({}), provider, request)
					Err(_) => Server.refused(404, "Not found")
				},
		)

	## Back from the provider called `name`, `GET <at>/<provider>/callback`
	## (`routes/auth/[provider]/callback/+server.roc`: the redirect URI to register with it): who
	## signed in there, given to `admit!`, then signed in (or asked for their second factor), and on
	## to where they were going. 404 for a name none of `providers` has; 405 for a method but GET.
	##
	## `admit!` says who gets in, here, by a link (`link_route!`) and by the dev sign-in
	## (`dev_route!`): given who is signing in, the app's id for its user, or why not (shown on the
	## sign-in page). It runs inside the transaction that starts the session: what it writes (a new
	## user's row, a request to join a waiting list, a job it queues) commits with the session, or
	## with its refusal, and a database error rolls all of it back. Keep anything slow (a fetch) out
	## of it. An app that signs people in its own way (a password it checks, a name picked) calls
	## `sign_in!` instead, and has no routes for these.
	callback_route! : Server.Request, List(Auth.Provider), Str, (Auth.Identity => Try(Str, Str)) => Server.Response
	callback_route! = |request, providers, name, admit!|
		taking!(
			request,
			["GET"],
			|{}|
				match providers.find_first(|provider| provider.name == name) {
					Ok(provider) => back!(settings!({}), admit!, provider, request)
					Err(_) => Server.refused(404, "Not found")
				},
		)

	## A mailed link, `GET|POST <at>/link?token=…` (`routes/auth/link/+server.roc`), used once: the
	## address it was sent to, given to `admit!` (as `callback_route!` says), then signed in. With
	## `link_page`, the link opens the app's page, which posts its token here. 405 for a method but
	## GET and POST.
	link_route! : Server.Request, (Auth.Identity => Try(Str, Str)) => Server.Response
	link_route! = |request, admit!| taking!(request, ["GET", "POST"], |{}| linked!(settings!({}), admit!, request))

	## The dev sign-in, `POST <at>/dev` (`routes/auth/dev/+server.roc`): under `--dev`, any address
	## posted (`email`, `then`), as if a provider had checked it, given to `admit!` and signed in, as
	## a link would; without `--dev`, 404, as if there were no such route. For trying an app and for
	## its tests, which need no mail and no provider; a server started with `--dev` lets anyone in as
	## anyone, so never start one that way where others can reach it. 405 for a method but POST.
	dev_route! : Server.Request, (Auth.Identity => Try(Str, Str)) => Server.Response
	dev_route! = |request, admit!| taking!(request, ["POST"], |{}| dev!(settings!({}), admit!, request))

	## Signing out, `POST <at>/sign-out` (`routes/auth/sign-out/+server.roc`): the session ended, its
	## cookie gone, and on to `then` (a form's field), else home. 405 for a method but POST.
	sign_out_route! : Server.Request => Server.Response
	sign_out_route! = |request| taking!(request, ["POST"], |{}| left!(settings!({}), request))

	## A sign-in's second factor, `POST <at>/code` (`routes/auth/code/+server.roc`), from the app's
	## `code_page`: the code (or a recovery code) checked, then signed in, else back to the page. 405
	## for a method but POST.
	code_route! : Server.Request => Server.Response
	code_route! = |request| taking!(request, ["POST"], |{}| coded!(settings!({}), request))

	## Google (OpenID Connect): `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, from an OAuth client
	## of the "Web application" kind whose redirect URI is `<public URL>/auth/google/callback`. It
	## asks which account (`prompt=select_account`), for someone signed in to several.
	google : Auth.Provider
	google = {
		name: "google",
		label: "Google",
		flow: Oidc(["https://accounts.google.com", "accounts.google.com"]),
		authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
		token_url: "https://oauth2.googleapis.com/token",
		scopes: ["openid", "email", "profile"],
		params: [("prompt", "select_account")],
		client_id_env: "GOOGLE_CLIENT_ID",
		client_secret_env: "GOOGLE_CLIENT_SECRET",
	}

	## GitHub (OAuth, then its API for the user and their verified primary address):
	## `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`, from an OAuth app whose callback URL is
	## `<public URL>/auth/github/callback`.
	github : Auth.Provider
	github = {
		name: "github",
		label: "GitHub",
		flow: GitHub("https://api.github.com"),
		authorize_url: "https://github.com/login/oauth/authorize",
		token_url: "https://github.com/login/oauth/access_token",
		scopes: ["read:user", "user:email"],
		params: [],
		client_id_env: "GITHUB_CLIENT_ID",
		client_secret_env: "GITHUB_CLIENT_SECRET",
	}

	## Any OpenID Connect provider, by its issuer and endpoints (its
	## `/.well-known/openid-configuration` lists them), asking for `openid email profile`.
	oidc : { name : Str, label : Str, issuer : Str, authorize_url : Str, token_url : Str, client_id_env : Str, client_secret_env : Str } -> Auth.Provider
	oidc = |given| {
		name: given.name,
		label: given.label,
		flow: Oidc([given.issuer]),
		authorize_url: given.authorize_url,
		token_url: given.token_url,
		scopes: ["openid", "email", "profile"],
		params: [],
		client_id_env: given.client_id_env,
		client_secret_env: given.client_secret_env,
	}

	## A sign-in link for `email` that goes on to `then` (a path of this site, else `home`): the URL
	## to mail them (to `link_page`, or to `<at>/link`), good once, for `link_ms`. The app sends it, as it likes (packages/email,
	## from a job). `NotAnAddress` when `email` isn't one.
	link! : Str, Str => Try(Str, [NotAnAddress, DbErr(Str), ..others])
	link! = |given, then| {
		settings = settings!({})
		email = Rules.address(given)?
		token = Rules.token(Random.bytes!(32))
		AuthStore.link!({ id: Rules.hash(token), email: email, then: Rules.path(then, settings.home), expires: now!({}) + settings.link_ms })?
		page = if (settings.link_page.is_empty()) "${settings.at}/link" else settings.link_page
		Ok(Rules.url("${Env.public_url!({})}${page}", [("token", token)]))
	}

	## Whom a mailed link signs in, and where it goes after, while it is good, without using it: what
	## the app's `link_page` shows before its button posts the token. `Gone` once it has been used or
	## has expired.
	link_for! : Str => Try({ email : Str, then : Str }, [Gone])
	link_for! = |token|
		if Rules.is_token(token) {
			match AuthStore.peek_link!(Rules.hash(token), now!({})) {
				Ok(Found(link)) => Ok({ email: link.email, then: link.return_to })
				Ok(Missing) => Err(Gone)
				Err(DbErr(why)) => {
					Log.error!("auth: a link couldn't be read", { error: why })
					Err(Gone)
				}
				Err(BadRow(why)) => {
					Log.error!("auth: a link couldn't be read", { error: why })
					Err(Gone)
				}
			}
		} else {
			Err(Gone)
		}

	## The session a request's cookie holds, if it holds one that hasn't ended. While an admin
	## impersonates someone (`impersonate!`, until its time is up), its `user` is theirs and its
	## `real_user` the admin's.
	session! : Server.Request => Try(Auth.Session, [SignedOut])
	session! = |request| {
		settings = settings!({})
		now = now!({})
		match Server.cookie(request, Rules.cookie(settings.cookie, https!({}))) {
			Ok(token) if Rules.is_token(token) =>
				match AuthStore.find!(Rules.hash(token), now) {
					Ok(Found(row)) => Ok({ user: acting(row, now), id: row.id, expires_ms: row.expires_at, real_user: row.user_id })
					Ok(Missing) => Err(SignedOut)
					Err(DbErr(why)) => unread!(why)
					Err(BadRow(why)) => unread!(why)
				}
			_ => Err(SignedOut)
		}
	}

	## Middleware that hands on whether the request is signed in (`add` puts it in the context), and
	## keeps a session used in its second half for as long again.
	optional : (ctx, Auth.Signed -> out) -> Middleware(ctx, out)
	optional = |add|
		Middleware.make(
			|request, given, next!|
				match Auth.session!(request) {
					Ok(session) => kept!(request, session, next!(request, add(given, SignedIn(session))))
					Err(SignedOut) => next!(request, add(given, SignedOut))
				},
		)

	## Middleware that lets a signed-in request through, handing on its session (`add` puts it in
	## the context); a signed-out one is answered as `signed_out!` says.
	required : (ctx, Auth.Session -> out) -> Middleware(ctx, out)
	required = |add|
		Middleware.make(
			|request, given, next!|
				match Auth.session!(request) {
					Ok(session) => kept!(request, session, next!(request, add(given, session)))
					Err(SignedOut) => Auth.signed_out!(request)
				},
		)

	## `required`, with a step that may read the database: `load!` turns the session into what the
	## routes are handed (the app's user's row, say). `SignedOut` from it (the user is gone) ends the
	## session and answers as a signed-out request; `Answer(response)` answers with that and keeps
	## the session (the database couldn't be read just then).
	required_with : (ctx, Auth.Session => Try(out, [SignedOut, Answer(Server.Response)])) -> Middleware(ctx, out)
	required_with = |load!|
		Middleware.make(
			|request, given, next!|
				match Auth.session!(request) {
					Ok(session) =>
						match load!(given, session) {
							Ok(handed) => kept!(request, session, next!(request, handed))
							Err(SignedOut) => Auth.sign_out!(request, Auth.signed_out!(request))
							Err(Answer(answer)) => answer
						}
					Err(SignedOut) => Auth.signed_out!(request)
				},
		)

	## What `required` answers a signed-out request: a page's GET goes to the sign-in page (or to
	## the code page, when this browser's sign-in waits for its code), with `?then=` to come back;
	## anything else is a 401 with the plugin's `refusal`. For an app's own middleware that finds the
	## request signed out after all.
	signed_out! : Server.Request => Server.Response
	signed_out! = |request| {
		settings = settings!({})
		if Server.wants_html(request) and request.method == "GET" {
			waits = if (settings.two_factor) Auth.waiting!(request).is_ok() else Bool.False
			Server.redirect(Rules.url(if (waits) settings.code_page else settings.sign_in, [("then", here(request))]))
		} else {
			Server.refused(401, settings.refusal)
		}
	}

	## `answer`, with `session` (the request's) kept for as long again when it is in its second half,
	## as `required` and `optional` keep it: for an app's own middleware that reads `session!`.
	renew! : Server.Request, Auth.Session, Server.Response => Server.Response
	renew! = |request, session, answer| kept!(request, session, answer)

	## Where a sign-in may go after: `then` if it is a path of this site, else the plugin's `home`.
	## For an app's own way in (`sign_in!` after a password it checked).
	path! : Str => Str
	path! = |then| Rules.path(then, settings!({}).home)

	## `answer`, with a new session for `user` (the app's id for them) in its cookie: for an app's
	## own way in (a sign-up form that signs in at once, a test). When `user` has two-factor sign-in
	## on, the cookie holds a sign-in waiting for their code instead: the next page that needs them
	## signed in goes to the code page.
	sign_in! : Server.Response, Str => Try(Server.Response, [DbErr(Str), ..others])
	sign_in! = |answer, user| {
		settings = settings!({})
		token = Rules.token(Random.bytes!(32))
		now = now!({})
		https = https!({})
		asks = if (settings.two_factor) AuthStore.two_factor_on!(user)? else Bool.False
		if asks {
			AuthStore.wait!({ id: Rules.hash(token), user: user, then: settings.home, now: now, expires: now + Rules.code_ms })?
			Ok(Server.set_cookie(answer, Rules.cookie(settings.cookie, https), token, cookie_opts(https, Rules.code_ms)))
		} else {
			AuthStore.start!({ id: Rules.hash(token), user: user, now: now, expires: now + settings.session_ms })?
			Ok(with_session(answer, settings, https, token))
		}
	}

	## `answer`, with the request's session (if any) ended and a new one for `user` in its cookie: a
	## person picked anew, in one step (one `Set-Cookie`).
	switch! : Server.Request, Server.Response, Str => Try(Server.Response, [DbErr(Str), ..others])
	switch! = |request, answer, user| {
		settings = settings!({})
		match Server.cookie(request, Rules.cookie(settings.cookie, https!({}))) {
			Ok(token) if Rules.is_token(token) => {
				_ = AuthStore.end!(Rules.hash(token))?
				{}
			}
			_ => {}
		}
		Auth.sign_in!(answer, user)
	}

	## The request's session acts as `user` for `ms` (impersonation: an admin seeing the app as
	## someone sees it, to help them). Who may do it is the app's to check first. The session stays
	## the admin's (`real_user`): signing out, or `stop_impersonating!`, or the time running out ends
	## it. On the log, with both users.
	impersonate! : Server.Request, Str, U64 => Try({}, [SignedOut, DbErr(Str), ..others])
	impersonate! = |request, user, ms| {
		session = Auth.session!(request)?
		until = now!({}) + ms.to_i64_wrap()
		_ = AuthStore.act!(session.id, Text(user), Int(until))?
		Log.info!("auth: impersonating", { real_user: session.real_user, acting_as: user, until_ms: until })
		Ok({})
	}

	## The request's session acts as its own user again.
	stop_impersonating! : Server.Request => Try({}, [SignedOut, DbErr(Str), ..others])
	stop_impersonating! = |request| {
		session = Auth.session!(request)?
		_ = AuthStore.act!(session.id, Null, Null)?
		if Auth.impersonating(session) {
			Log.info!("auth: impersonating ended", { real_user: session.real_user, acting_as: session.user })
		}
		Ok({})
	}

	## Whether a session is an admin's acting as someone else.
	impersonating : Auth.Session -> Bool
	impersonating = |session| session.user != session.real_user

	## `answer`, with the request's session ended and its cookie gone.
	sign_out! : Server.Request, Server.Response => Server.Response
	sign_out! = |request, answer| {
		settings = settings!({})
		https = https!({})
		name = Rules.cookie(settings.cookie, https)
		match Server.cookie(request, name) {
			Ok(token) if Rules.is_token(token) =>
				match (AuthStore.end!(Rules.hash(token)), AuthStore.end_waiting!(Rules.hash(token))) {
					(Ok(_), Ok(_)) => {}
					(Err(DbErr(why)), _) | (_, Err(DbErr(why))) => Log.error!("auth: a session couldn't be ended", { error: why })
				}
			_ => {}
		}
		Server.clear_cookie(answer, name, cookie_opts(https, 0))
	}

	## Ends every session of `user` (signing out everywhere, or after their password or address
	## changed), and every sign-in of theirs waiting for a code: how many sessions ended. The request's own cookie stays on the browser, holding a session
	## that is gone: answer with `sign_out!` too, to clear it.
	sign_out_everywhere! : Str => Try(U64, [DbErr(Str), ..others])
	sign_out_everywhere! = |user| AuthStore.end_all!(user)

	## `user`'s sessions that haven't ended, the newest first: each one's id (for `revoke!`), when
	## it began and when it ends, and whom it acts as while impersonating (`""` otherwise).
	sessions! : Str => Try(List({ id : Str, created_ms : I64, expires_ms : I64, acting_as : Str }), [DbErr(Str), BadRow(Str), ..others])
	sessions! = |user| {
		now = now!({})
		rows = AuthStore.of_user!(user, now)?
		Ok(rows.map(|row| { id: row.id, created_ms: row.created_at, expires_ms: row.expires_at, acting_as: if (acting(row, now) == row.user_id) "" else acting(row, now) }))
	}

	## Ends `user`'s session `id` (one of `sessions!`), and no one else's: how many ended (0 or 1).
	revoke! : Str, Str => Try(U64, [DbErr(Str), ..others])
	revoke! = |user, id| AuthStore.revoke!(user, id)

	## The identities `user` has signed in with: each provider, their id there, the address it gave.
	identities! : Str => Try(List({ provider : Str, subject : Str, email : Str }), [DbErr(Str), BadRow(Str), ..others])
	identities! = |user| AuthStore.identities!(user)

	## For `admit!`: the id of the user `identity` is, made if it is no one yet. An identity that
	## signed in before (`Known`) is its user, whose address becomes the one the provider gives now if
	## it changed and no other user has it (their mailed links to the old one end: an address given
	## up may be someone else's later). A new identity is the user with its address (signed in
	## before another way: a mailed link, another provider), else a new user, a version 7 UUID
	## (crypto's `Uuid`). `NoAddress` when a new identity has none (a provider that gave no
	## verified address), for the app to refuse. Inside `admit!`, it is part of the sign-in's
	## transaction: the user it made stays, whether `admit!` then lets them in or refuses them; a
	## database error undoes it.
	user_for! : Auth.Identity => Try(Str, [NoAddress, DbErr(Str), BadRow(Str), ..others])
	user_for! = |identity| {
		now = now!({})
		match identity.user {
			Known(user) => {
				if !identity.email.is_empty() {
					kept =
						match AuthStore.user!(user)? {
							Found(row) if row.email != identity.email => AuthStore.readdress!(user, identity.email)
							Found(_) => Ok(0)
							Missing => {
								# A user from before the package kept them (an app's own id): kept now.
								made = AuthStore.make_user!({ id: user, email: identity.email, now })?
								if made == 0 {
									Log.warn!("auth: a user's address is another user's, so the package keeps no row for them", { user, email: identity.email })
								}
								Ok(made)
							}
						}
					_ = kept?
				}
				Ok(user)
			}
			New => {
				if identity.email.is_empty() {
					return Err(NoAddress)
				}
				addressed!(identity.email, now)
			}
		}
	}

	## The id of the user with address `email` (any case, spaces around it trimmed), made if there is
	## none: for an app that names someone before they sign in (an invitation to them, an admin
	## letting them in ahead, a test account the app's own link signs in as). Their first sign-in
	## with that verified address finds them (`user_for!`). `NotAnAddress` for text that isn't one.
	user_with_address! : Str => Try(Str, [NotAnAddress, DbErr(Str), BadRow(Str), ..others])
	user_with_address! = |email| {
		address = Rules.address(email)?
		addressed!(address, now!({}))
	}

	## The user with id `id`; `NotFound` if there is none (never made, or forgotten).
	user! : Str => Try(Auth.User, [NotFound, DbErr(Str), BadRow(Str), ..others])
	user! = |id|
		match AuthStore.user!(id)? {
			Found(row) => Ok(user_of(row))
			Missing => Err(NotFound)
		}

	## The user with address `email` (any case, spaces around it trimmed); `NotFound` if there is
	## none, or it isn't an address.
	user_by_email! : Str => Try(Auth.User, [NotFound, DbErr(Str), BadRow(Str), ..others])
	user_by_email! = |email|
		match Rules.address(email) {
			Ok(address) =>
				match AuthStore.user_by_email!(address)? {
					Found(row) => Ok(user_of(row))
					Missing => Err(NotFound)
				}
			Err(NotAnAddress) => Err(NotFound)
		}

	## Forgets user `id`, all at once (a transaction), for the app deleting them: their row, their
	## sessions (an admin acting as them goes back to being themselves), the mailed links on their
	## way to them, their identities, authenticator, recovery codes and sign-ins waiting for a code,
	## and their grants of roles (`Roles.forget!`). What names them in others' rows (who granted a
	## role) stays, naming no one now; the app's own tables are the app's to clear. Signing in again
	## later makes a new user.
	forget! : Str => Try({}, [DbErr(Str), ..others])
	forget! = |id| {
		Db.transaction!(|{}| AuthStore.forget_user!(id))?
		Log.info!("auth: user forgotten", { user: id })
		Ok({})
	}

	## The providers the app's sign-in page can offer, for its buttons: those whose client id is
	## set, each with its label and where its button goes (add `?then=` to come back somewhere).
	providers! : {} => List({ name : Str, label : Str, path : Str })
	providers! = |{}| {
		settings = settings!({})
		var $offered = []
		for provider in settings.providers {
			if !(Env.var!(provider.client_id_env) ?? "").trim().is_empty() {
				$offered = $offered.append({ name: provider.name, label: provider.label, path: "${settings.at}/${provider.name}" })
			}
		}
		$offered
	}

	## Whether the dev sign-in (`POST <at>/dev`, any address) is open: under `--dev` only.
	dev_sign_in! : {} => Bool
	dev_sign_in! = |{}| Env.dev!({})

	## Whether `user`'s two-factor sign-in is on (`Auth.TwoFactor`): for the app's account page,
	## and for a route only some users may use with it on (an admin's), which the app decides.
	two_factor! : Str => Try(Auth.TwoFactor, [DbErr(Str), BadRow(Str), ..others])
	two_factor! = |user|
		match AuthStore.authenticator!(user)? {
			Missing => Ok(Off)
			Found(row) =>
				match row.enabled_at {
					Some(since) => Ok(On({ since_ms: since, recovery_codes: AuthStore.recovery_left!(user)? }))
					Null => Ok(Pending)
				}
		}

	## Starts turning on `user`'s two-factor sign-in: a new authenticator secret (20 random bytes),
	## kept sealed, waiting for its first code (`two_factor_confirm!`), in place of one that was
	## waiting. What the app shows them: the secret in Base32, in groups of four, for an app that
	## can't scan, and the `otpauth://` URI, as a QR code, which names the plugin's `issuer` and
	## `account` (their address, say). `AlreadyOn` when it is; `NotOffered` when the plugin's
	## `two_factor` is off.
	two_factor_start! : Str, Str => Try({ secret : Str, uri : Str }, [AlreadyOn, NotOffered, DbErr(Str), BadRow(Str), ..others])
	two_factor_start! = |user, account| {
		settings = settings!({})
		key = sealing_key!(settings).map_err(|_| NotOffered)?
		secret = Random.bytes!(20)
		sealed = AesGcm.seal!(key, Rules.sealed_plain(secret, user)).map_err(|_| NotOffered)?
		kept = Db.transaction!(|{}| AuthStore.pending!({ user: user, secret: Base64.url_encode(sealed), now: now!({}) }))?
		if kept == 0 {
			Err(AlreadyOn)
		} else {
			Ok({ secret: Totp.grouped(secret), uri: Totp.uri({ issuer: issuer!(settings), account: account, secret: secret }) })
		}
	}

	## The authenticator `two_factor_start!` made for `user`, while it waits for its first code: its
	## secret and URI again (`account` as there), for their page shown again (reloaded, or after a
	## wrong code). Once it is on, never: `NotPending`.
	two_factor_pending! : Str, Str => Try({ secret : Str, uri : Str }, [NotPending, DbErr(Str), BadRow(Str), ..others])
	two_factor_pending! = |user, account| {
		settings = settings!({})
		match AuthStore.authenticator!(user)? {
			Found(row) if row.enabled_at == Null =>
				match opened!(settings, row.secret, user) {
					Ok(secret) => Ok({ secret: Totp.grouped(secret), uri: Totp.uri({ issuer: issuer!(settings), account: account, secret: secret }) })
					Err(Unopened) => Err(NotPending)
				}
			_ => Err(NotPending)
		}
	}

	## Turns on `user`'s two-factor sign-in, given the first code their app shows for the secret
	## `two_factor_start!` made: their ten recovery codes, each good once in place of a code (show
	## them once: only their hashes are kept). `WrongCode` when it isn't the code now (or a step
	## either side); `NotStarted` when nothing was started; `AlreadyOn` when it is.
	two_factor_confirm! : Str, Str => Try(List(Str), [WrongCode, NotStarted, AlreadyOn, DbErr(Str), BadRow(Str), ..others])
	two_factor_confirm! = |user, code| {
		settings = settings!({})
		now = now!({})
		match AuthStore.authenticator!(user)? {
			Missing => Err(NotStarted)
			Found(row) =>
				match row.enabled_at {
					Some(_) => Err(AlreadyOn)
					Null => {
						secret = opened!(settings, row.secret, user).map_err(|_| NotStarted)?
						step = Totp.matching(secret, Rules.typed(code), Totp.step(now), 0).map_err(|_| WrongCode)?
						codes = recovery_codes!({})
						enabled = Db.transaction!(
							|{}| {
								changed = AuthStore.enable!(user, now, step)?
								if changed == 1 {
									AuthStore.recovery_codes!(user, codes.map(|each| Rules.hash(Rules.typed(each))), now)?
								}
								Ok(changed)
							},
						)?
						if enabled == 1 {
							Log.info!("auth: two-factor sign-in turned on", { user: user })
							Ok(codes)
						} else {
							Err(AlreadyOn)
						}
					}
				}
		}
	}

	## Turns `user`'s two-factor sign-in off, given a code their app shows now, or one of their
	## recovery codes: their secret and recovery codes gone. `WrongCode` when it is neither;
	## `NotOn` when it isn't on; `TooManyTries` when they have given ten wrong codes in a row, here,
	## at a sign-in or for new recovery codes, the last less than a quarter of an hour ago (the code
	## isn't looked at).
	two_factor_disable! : Str, Str => Try({}, [WrongCode, NotOn, TooManyTries, DbErr(Str), BadRow(Str), ..others])
	two_factor_disable! = |user, code| {
		_ = checked!(settings!({}), user, code)?
		AuthStore.disable!(user)?
		Log.info!("auth: two-factor sign-in turned off", { user: user })
		Ok({})
	}

	## New recovery codes for `user`, in place of those they had, given a code their app shows now
	## (or a recovery code): ten more, each good once (show them once). `WrongCode`, `NotOn` and
	## `TooManyTries` as for `two_factor_disable!`.
	two_factor_regenerate! : Str, Str => Try(List(Str), [WrongCode, NotOn, TooManyTries, DbErr(Str), BadRow(Str), ..others])
	two_factor_regenerate! = |user, code| {
		_ = checked!(settings!({}), user, code)?
		codes = recovery_codes!({})
		AuthStore.recovery_codes!(user, codes.map(|each| Rules.hash(Rules.typed(each))), now!({}))?
		Log.info!("auth: recovery codes made anew", { user: user })
		Ok(codes)
	}

	## The sign-in this browser has waiting for its code, if it has one that hasn't expired: whose
	## it is, where it goes after, and how many more wrong codes it may have. For the app's
	## `code_page` (which may show whom it signs in).
	waiting! : Server.Request => Try({ user : Str, then : Str, tries_left : U64 }, [SignedOut])
	waiting! = |request| {
		settings = settings!({})
		match Server.cookie(request, Rules.cookie(settings.cookie, https!({}))) {
			Ok(token) if Rules.is_token(token) =>
				match AuthStore.waiting!(Rules.hash(token), now!({})) {
					Ok(Found(row)) => Ok({ user: row.user_id, then: row.return_to, tries_left: (Rules.code_tries - row.attempts).to_u64_wrap() })
					Ok(Missing) => Err(SignedOut)
					Err(DbErr(why)) | Err(BadRow(why)) => {
						Log.error!("auth: a sign-in waiting for its code couldn't be read", { error: why })
						Err(SignedOut)
					}
				}
			_ => Err(SignedOut)
		}
	}
}

## The settings an app's options make.
settings_of : Auth.Options -> Auth.Settings
settings_of = |options| {
	at: if (options.at.ends_with("/")) options.at.drop_suffix("/") else options.at,
	sign_in: options.sign_in,
	home: options.home,
	session_ms: options.session_ms.to_i64_wrap(),
	link_ms: options.link_ms.to_i64_wrap(),
	link_page: options.link_page,
	cookie: options.cookie,
	refusal: options.refusal,
	providers: options.providers.map(|provider| { name: provider.name, label: provider.label, client_id_env: provider.client_id_env }),
	two_factor: options.two_factor,
	code_page: options.code_page,
	issuer: options.issuer,
	key_env: options.key_env,
}

## `answer!` for a request whose method is one of `methods` (GET takes HEAD too), else 405.
taking! : Server.Request, List(Str), ({} => Server.Response) => Server.Response
taking! = |request, methods, answer!| {
	asked = if (request.method == "HEAD") "GET" else request.method
	if (methods.contains(asked)) answer!({}) else Endpoint.not_allowed(request, methods)
}

## The settings when the plugin isn't listed (or hasn't started): its options' defaults.
defaults : Auth.Settings
defaults = { at: "/auth", sign_in: "/sign-in", home: "/", session_ms: 30 * 86_400_000, link_ms: 15 * 60_000, link_page: "", cookie: "session", refusal: "Sign in first.", providers: [], two_factor: Bool.False, code_page: "/sign-in/code", issuer: "", key_env: "APP_SECRET" }

## Whom a session's row acts as at `now`: the user it impersonates, while that lasts; else its own.
acting : AuthStore.Row, I64 -> Str
acting = |row, now|
	match (row.acting_as, row.acting_until) {
		(Some(user), Some(until)) if until > now => user
		_ => row.user_id
	}

## The settings the plugin kept at start.
settings! : {} => Auth.Settings
settings! = |{}|
	match Plugin.kept!("auth:settings") {
		Ok(text) => {
			parsed : Try(Auth.Settings, _)
			parsed = Json.parse(text)
			parsed ?? defaults
		}
		Err(NotFound) => defaults
	}

## Now, in milliseconds since 1970.
now! : {} => I64
now! = |{}| Time.now_millis!({}).to_i64_wrap()

## The id of the user with `address` (as kept), made at `now` if there is none: one statement makes
## it (two at once make one), then it is read back.
addressed! : Str, I64 => Try(Str, [DbErr(Str), BadRow(Str), ..others])
addressed! = |address, now| {
	_ = AuthStore.make_user!({ id: Uuid.v7(now.to_u64_wrap(), Random.bytes!(10)), email: address, now })?
	match AuthStore.user_by_email!(address)? {
		Found(row) => Ok(row.id)
		Missing => Err(DbErr("auth: the user made for an address isn't there"))
	}
}

user_of : AuthStore.UserRow -> Auth.User
user_of = |row| { id: row.id, email: row.email, created_ms: row.created_at }

## Whether the app is on HTTPS (its public URL), so its cookies are `Secure` and `__Host-`.
https! : {} => Bool
https! = |{}| Env.public_url!({}).starts_with("https://")

## A cookie's options: `Secure` on HTTPS, for `max_age_ms` (0: gone), HttpOnly, Lax, the whole site.
cookie_opts : Bool, I64 -> Server.CookieOpts
cookie_opts = |https, max_age_ms| { ..Server.cookie_defaults, secure: https, max_age_s: (max_age_ms // 1000).to_u64_wrap() }

## `answer` with the session cookie holding `token`.
with_session : Server.Response, Auth.Settings, Bool, Str -> Server.Response
with_session = |answer, settings, https, token| Server.set_cookie(answer, Rules.cookie(settings.cookie, https), token, cookie_opts(https, settings.session_ms))

## The request's path and query: where to come back to.
here : Server.Request -> Str
here = |request| if (request.query.is_empty()) request.path else "${request.path}?${request.query}"

## A session that couldn't be read is a signed-out request, and an error on the log.
unread! : Str => Try(Auth.Session, [SignedOut])
unread! = |why| {
	Log.error!("auth: a session couldn't be read", { error: why })
	Err(SignedOut)
}

## `answer`, and when the request's session is in its second half, the session kept for as long
## again: its row, and its cookie (unless the answer sets that cookie itself, as signing out does).
kept! : Server.Request, Auth.Session, Server.Response => Server.Response
kept! = |request, session, answer| {
	settings = settings!({})
	now = now!({})
	https = https!({})
	name = Rules.cookie(settings.cookie, https)
	sets = answer.headers.any(|header| header.name.with_ascii_lowercased() == "set-cookie" and header.value.starts_with("${name}="))
	if sets or !Rules.renew(session.expires_ms, now, settings.session_ms) {
		answer
	} else {
		match (Server.cookie(request, name), AuthStore.renew!(session.id, now + settings.session_ms)) {
			(Ok(token), Ok(_)) => with_session(answer, settings, https, token)
			(_, Err(DbErr(why))) => {
				Log.error!("auth: a session couldn't be kept longer", { error: why })
				answer
			}
			_ => answer
		}
	}
}

## Signing in as `who` (at `provider`), going on to `then`: `admit!` asked, in a transaction with
## the identity's row and the session's, and the session's cookie on the answer; or, for a user
## with two-factor sign-in on, a sign-in waiting for their code and the code page; or the sign-in
## page, with why not. A refusal commits too: what `admit!` wrote as it turned them away (a waiting
## list's row) stays.
signed_in! : Auth.Settings, (Auth.Identity => Try(Str, Str)), { provider : Str, subject : Str, email : Str, name : Str }, Str => Server.Response
signed_in! = |settings, admit!, who, then| {
	token = Rules.token(Random.bytes!(32))
	now = now!({})
	started = Db.transaction!(
		|{}| {
			known = AuthStore.known!(who.provider, who.subject)?
			match admit!({ provider: who.provider, subject: who.subject, email: who.email, name: who.name, user: known, then: Rules.path(then, settings.home) }) {
				Ok(user) => {
					AuthStore.linked!({ provider: who.provider, subject: who.subject, user: user, email: who.email, now: now })?
					asks = if (settings.two_factor) AuthStore.two_factor_on!(user)? else Bool.False
					if asks {
						AuthStore.wait!({ id: Rules.hash(token), user: user, then: Rules.path(then, settings.home), now: now, expires: now + Rules.code_ms })?
						Ok(Waiting)
					} else {
						AuthStore.start!({ id: Rules.hash(token), user: user, now: now, expires: now + settings.session_ms })?
						Ok(Admitted)
					}
				}
				Err(why) => Ok(TurnedAway(why))
			}
		},
	)
	match started {
		Ok(Admitted) => with_session(Server.redirect(Rules.path(then, settings.home)), settings, https!({}), token)
		Ok(Waiting) => {
			https = https!({})
			Server.set_cookie(Server.redirect(Rules.onward(settings.code_page, Rules.path(then, settings.home))), Rules.cookie(settings.cookie, https), token, cookie_opts(https, Rules.code_ms))
		}
		Ok(TurnedAway(why)) => Server.redirect(Rules.failed(settings.sign_in, { code: "refused", reason: why, email: who.email, then: then }))
		Err(DbErr(why)) => unavailable!(settings, why)
		Err(BadRow(why)) => unavailable!(settings, why)
	}
}

## A sign-in the database couldn't take: on the log, and the sign-in page says so.
unavailable! : Auth.Settings, Str => Server.Response
unavailable! = |settings, why| {
	Log.error!("auth: a sign-in failed", { error: why })
	Server.redirect(Rules.failed(settings.sign_in, { code: "unavailable", reason: "", email: "", then: "" }))
}

## `<at>/link`: a mailed link used (its token in the query, or a form's field, as a page that asks
## first posts it), signing in its address.
linked! : Auth.Settings, (Auth.Identity => Try(Str, Str)), Server.Request => Server.Response
linked! = |settings, admit!, request| {
	token = if (request.method == "POST") Rules.query(Server.text_of(request), "token") else Rules.query(request.query, "token")
	if Rules.is_token(token) {
		match AuthStore.use_link!(Rules.hash(token), now!({})) {
			Ok(Found(link)) => signed_in!(settings, admit!, { provider: "email", subject: link.email, email: link.email, name: "" }, link.return_to)
			Ok(Missing) => {
				# An expired link still has its row until the next sweep: where it was going.
				then =
					match AuthStore.return_to!(Rules.hash(token)) {
						Ok(Found(path)) => path
						_ => ""
					}
				Server.redirect(Rules.failed(settings.sign_in, { code: "link", reason: "", email: "", then: then }))
			}
			Err(DbErr(why)) => unavailable!(settings, why)
			Err(BadRow(why)) => unavailable!(settings, why)
		}
	} else {
		Server.redirect(Rules.failed(settings.sign_in, { code: "link", reason: "", email: "", then: "" }))
	}
}

## `<at>/dev`: under `--dev`, any address posted (`email`, `then`) signs in, as a link would; else
## there is no such endpoint.
dev! : Auth.Settings, (Auth.Identity => Try(Str, Str)), Server.Request => Server.Response
dev! = |settings, admit!, request|
	if Env.dev!({}) {
		body = Server.text_of(request)
		then = Rules.query(body, "then")
		match Rules.address(Rules.query(body, "email")) {
			Ok(email) => signed_in!(settings, admit!, { provider: "email", subject: email, email: email, name: "" }, then)
			Err(NotAnAddress) => Server.redirect(Rules.failed(settings.sign_in, { code: "refused", reason: "That isn't an email address.", email: "", then: then }))
		}
	} else {
		Server.refused(404, "Not found")
	}

## `<at>/sign-out`: the session ended, its cookie gone, and on to `then` (a form's field), else home.
left! : Auth.Settings, Server.Request => Server.Response
left! = |settings, request| Auth.sign_out!(request, Server.redirect(Rules.path(Rules.query(Server.text_of(request), "then"), settings.home)))

## Where a provider sends the browser back to.
callback! : Auth.Settings, Auth.Provider => Str
callback! = |settings, provider| "${Env.public_url!({})}${settings.at}/${provider.name}/callback"

## The state cookie's name.
state_cookie : Bool -> Str
state_cookie = |https| Rules.cookie("auth-state", https)

## `<at>/<provider>`: off to the provider, with a state, PKCE's verifier and a nonce kept in a
## cookie for ten minutes, and where to come back to (`then`).
away! : Auth.Settings, Auth.Provider, Server.Request => Server.Response
away! = |settings, provider, request| {
	then = Rules.path(Rules.query(request.query, "then"), settings.home)
	client_id = (Env.var!(provider.client_id_env) ?? "").trim()
	if client_id.is_empty() {
		Server.redirect(Rules.failed(settings.sign_in, { code: "provider", reason: "Signing in with ${provider.label} isn't set up: ${provider.client_id_env} is empty.", email: "", then: then }))
	} else {
		https = https!({})
		state = Rules.token(Random.bytes!(32))
		verifier = Rules.token(Random.bytes!(32))
		nonce = Rules.token(Random.bytes!(32))
		kept = Rules.state_value({ provider: provider.name, state: state, verifier: verifier, nonce: nonce, then: then })
		url = Rules.authorize({ authorize_url: provider.authorize_url, client_id: client_id, redirect_uri: callback!(settings, provider), scopes: provider.scopes, state: state, verifier: verifier, nonce: nonce, params: provider.params })
		Server.set_cookie(Server.redirect(url), state_cookie(https), kept, cookie_opts(https, 600_000))
	}
}

## `<at>/<provider>/callback`: back from the provider. The state it brings must be the one the
## browser kept (else `?error=state`); its code is traded for who signed in, who is then signed in.
## The state cookie goes, whatever happens.
back! : Auth.Settings, (Auth.Identity => Try(Str, Str)), Auth.Provider, Server.Request => Server.Response
back! = |settings, admit!, provider, request| {
	https = https!({})
	name = state_cookie(https)
	kept =
		match Server.cookie(request, name) {
			Ok(value) => Rules.state_of(value)
			Err(Missing) => Err(BadState)
		}
	answer =
		match kept {
			Ok(state) if state.provider == provider.name and Rules.same_state(state.state, Rules.query(request.query, "state")) => {
				refused = Rules.query(request.query, "error")
				if !refused.is_empty() {
					described = Rules.query(request.query, "error_description")
					Server.redirect(Rules.failed(settings.sign_in, { code: "provider", reason: if (described.is_empty()) refused else described, email: "", then: state.then }))
				} else {
					match who!(settings, provider, Rules.query(request.query, "code"), state) {
						Ok(who) => signed_in!(settings, admit!, { provider: provider.name, subject: who.subject, email: who.email, name: who.name }, state.then)
						Err(why) => {
							Log.warn!("auth: a sign-in at a provider failed", { provider: provider.name, error: why })
							Server.redirect(Rules.failed(settings.sign_in, { code: "provider", reason: why, email: "", then: state.then }))
						}
					}
				}
			}
			_ => Server.redirect(Rules.failed(settings.sign_in, { code: "state", reason: "", email: "", then: "" }))
		}
	Server.clear_cookie(answer, name, cookie_opts(https, 0))
}

## Who signed in at `provider`: its code traded (with PKCE's verifier) at its token endpoint, then
## the ID token read, or GitHub's API asked.
who! : Auth.Settings, Auth.Provider, Str, Rules.State => Try(Rules.Who, Str)
who! = |settings, provider, code, state| {
	client_id = (Env.var!(provider.client_id_env) ?? "").trim()
	secret = (Env.var!(provider.client_secret_env) ?? "").trim()
	traded = Http.fetch!(
		provider.token_url,
		{
			method: Post,
			headers: [("accept", "application/json")],
			body: Http.form([("grant_type", "authorization_code"), ("code", code), ("redirect_uri", callback!(settings, provider)), ("client_id", client_id), ("client_secret", secret), ("code_verifier", state.verifier)]),
			timeout_ms: 15_000,
		},
	)
	answer = traded.map_err(unreached)?
	tokens = Rules.tokens(answer.text())?
	match provider.flow {
		Oidc(issuers) => Rules.claims(tokens.id, { issuers: issuers, client_id: client_id, nonce: state.nonce, now_s: now!({}) // 1000 })
		GitHub(api) => {
			headers = [("authorization", "Bearer ${tokens.access}"), ("accept", "application/vnd.github+json"), ("user-agent", "roc-solid-auth")]
			user = Http.fetch!("${api}/user", { headers: headers, timeout_ms: 15_000 }).map_err(unreached)?
			emails = Http.fetch!("${api}/user/emails", { headers: headers, timeout_ms: 15_000 }).map_err(unreached)?
			if user.ok {
				Rules.github(user.text(), if (emails.ok) emails.text() else "[]")
			} else {
				Err("${provider.label} wouldn't say who signed in: ${user.status.to_str()}")
			}
		}
	}
}

## Why a provider couldn't be asked.
unreached : [HttpErr(Str), TimedOut, TooLarge] -> Str
unreached = |problem|
	match problem {
		HttpErr(why) => "the provider couldn't be reached: ${why}"
		TimedOut => "the provider didn't answer in time"
		TooLarge => "the provider's answer was too large"
	}

## `<at>/code`: a sign-in's second factor, posted from the app's code page (`code`, and `then`):
## the code from the user's authenticator app, or one of their recovery codes. Right: the sign-in
## becomes a session, on to `then` (else where it was going). Wrong: back to the code page saying
## so, but the fifth wrong code ends the sign-in (`attempts`). Once the user has given ten wrong
## codes in a row, across sign-ins, their codes are refused unread for a quarter of an hour after
## the last (`Rules.locked`): a code sent then ends the sign-in, the sign-in page saying to wait
## (`locked`). No sign-in waiting (it took over ten minutes, or the browser has none): the sign-in
## page says so.
coded! : Auth.Settings, Server.Request => Server.Response
coded! = |settings, request| {
	body = Server.text_of(request)
	asked = Rules.query(body, "then")
	timed_out = Server.redirect(Rules.failed(settings.sign_in, { code: "timeout", reason: "", email: "", then: asked }))
	match Server.cookie(request, Rules.cookie(settings.cookie, https!({}))) {
		Ok(token) if Rules.is_token(token) =>
			match AuthStore.waiting!(Rules.hash(token), now!({})) {
				Ok(Found(row)) => {
					then = Rules.path(if (asked.is_empty()) row.return_to else asked, settings.home)
					match checked!(settings, row.user_id, Rules.query(body, "code")) {
						Ok(how) => finished!(settings, token, row.user_id, how, then)
						Err(WrongCode) | Err(NotOn) => wrong!(settings, token, row.user_id, then)
						Err(TooManyTries) => ended!(settings, token, row.user_id, "locked", then)
						Err(DbErr(why)) | Err(BadRow(why)) => unavailable!(settings, why)
					}
				}
				Ok(Missing) => timed_out
				Err(DbErr(why)) | Err(BadRow(why)) => unavailable!(settings, why)
			}
		_ => timed_out
	}
}

## A right code: the sign-in waiting by `token` taken and a session started in its place, under a
## new token, so the one the browser held while it waited signs no one in; on to `then`.
finished! : Auth.Settings, Str, Str, [Code, Recovery], Str => Server.Response
finished! = |settings, token, user, how, then| {
	fresh = Rules.token(Random.bytes!(32))
	now = now!({})
	started = Db.transaction!(
		|{}| {
			match AuthStore.done_waiting!(Rules.hash(token))? {
				Found(row) => {
					AuthStore.start!({ id: Rules.hash(fresh), user: row.user_id, now: now, expires: now + settings.session_ms })?
					Ok(Started)
				}
				Missing => Ok(Gone)
			}
		},
	)
	match started {
		Ok(Started) => {
			if how == Recovery {
				Log.info!("auth: signed in with a recovery code", { user: user })
			}
			with_session(Server.redirect(then), settings, https!({}), fresh)
		}
		Ok(Gone) => Server.redirect(Rules.failed(settings.sign_in, { code: "timeout", reason: "", email: "", then: then }))
		Err(DbErr(why)) | Err(BadRow(why)) => unavailable!(settings, why)
	}
}

## A wrong code for the sign-in waiting by `token`: back to the code page, saying so; the fifth,
## the sign-in ended (its cookie too), and the sign-in page saying why.
wrong! : Auth.Settings, Str, Str, Str => Server.Response
wrong! = |settings, token, user, then|
	match AuthStore.missed!(Rules.hash(token)) {
		Ok(attempts) if attempts < Rules.code_tries => Server.redirect(Rules.failed(settings.code_page, { code: "code", reason: "", email: "", then: then }))
		Ok(_) => ended!(settings, token, user, "attempts", then)
		Err(DbErr(why)) | Err(BadRow(why)) => unavailable!(settings, why)
	}

## The sign-in waiting by `token` ended (its cookie cleared), and the sign-in page saying why
## (`code`: `attempts`, too many wrong codes for it; `locked`, too many in a row for the user).
ended! : Auth.Settings, Str, Str, Str, Str => Server.Response
ended! = |settings, token, user, code, then| {
	match AuthStore.end_waiting!(Rules.hash(token)) {
		Ok(_) => {}
		Err(DbErr(why)) => Log.error!("auth: a sign-in waiting for its code couldn't be ended", { error: why })
	}
	Log.warn!("auth: a sign-in ended after too many wrong codes", { user: user, why: code })
	https = https!({})
	Server.clear_cookie(Server.redirect(Rules.failed(settings.sign_in, { code: code, reason: "", email: "", then: then })), Rules.cookie(settings.cookie, https), cookie_opts(https, 0))
}

## Whether `given` is `user`'s code now (taken, so it works once) or one of their unused recovery
## codes (used up): which it was. `NotOn` when their two-factor sign-in isn't on; `TooManyTries`,
## without looking at it, when they have given `Rules.lock_tries` wrong codes in a row, the last
## less than `Rules.code_lock_ms` ago (`Rules.locked`). Each code is counted as wrong before it is
## looked at, and the count set back to 0 when it is right, so codes sent at once can't get past
## the count: one of two read at once is `WrongCode`.
checked! : Auth.Settings, Str, Str => Try([Code, Recovery], [WrongCode, NotOn, TooManyTries, DbErr(Str), BadRow(Str), ..others])
checked! = |settings, user, given| {
	now = now!({})
	match AuthStore.authenticator!(user)? {
		Missing => Err(NotOn)
		Found(row) =>
			match row.enabled_at {
				Null => Err(NotOn)
				Some(_) =>
					if Rules.locked(row.misses, row.missed_at, now) {
						Err(TooManyTries)
					} else if AuthStore.tried_code!(user, row.misses, now)? == 0 {
						Err(WrongCode)
					} else {
						how = matched!(settings, user, row, Rules.typed(given), now)?
						_ = AuthStore.right_code!(user)?
						Ok(how)
					}
			}
	}
}

## Whether `typed` is the code `user`'s authenticator (`row`, on) shows at `now`, taken so it works
## once, or one of their unused recovery codes, used up.
matched! : Auth.Settings, Str, AuthStore.Authenticator, Str, I64 => Try([Code, Recovery], [WrongCode, DbErr(Str), ..others])
matched! = |settings, user, row, typed, now|
	if Totp.is_code(typed) {
		match opened!(settings, row.secret, user) {
			Ok(secret) =>
				match Totp.matching(secret, typed, Totp.step(now), row.last_step) {
					Ok(step) => if (AuthStore.used_step!(user, step)? == 1) Ok(Code) else Err(WrongCode)
					Err(NoMatch) => Err(WrongCode)
				}
			Err(Unopened) => Err(WrongCode)
		}
	} else if Rules.is_recovery(typed) {
		if (AuthStore.use_recovery!(user, Rules.hash(typed))? == 1) Ok(Recovery) else Err(WrongCode)
	} else {
		Err(WrongCode)
	}

## The secret `user`'s authenticator row keeps sealed. `Unopened` (on the log) when the app's
## secret has changed since it was sealed, or the row isn't theirs.
opened! : Auth.Settings, Str, Str => Try(List(U8), [Unopened])
opened! = |settings, sealed, user|
	match (sealing_key!(settings), Base64.url_decode(sealed)) {
		(Ok(key), Ok(bytes)) =>
			match AesGcm.open!(key, bytes).map_ok(|plain| Rules.secret_of(plain, user)) {
				Ok(Ok(secret)) => Ok(secret)
				_ => {
					Log.error!("auth: an authenticator's secret couldn't be opened: was the app's secret changed?", { user: user, env: settings.key_env })
					Err(Unopened)
				}
			}
		_ => Err(Unopened)
	}

## The key that seals authenticators' secrets, derived from the app's secret (`key_env`), or under
## `--dev` without one, from a development secret; or why there is none.
sealing_key! : Auth.Settings => Try(List(U8), Str)
sealing_key! = |settings|
	if !settings.two_factor {
		Err("auth: two-factor sign-in isn't on (the plugin's `two_factor` option)")
	} else {
		given = (Env.var!(settings.key_env) ?? "").trim()
		if given.to_utf8().len() >= 32 {
			Ok(Rules.sealing_key(given))
		} else if !given.is_empty() {
			Err("auth: ${settings.key_env} is too short for two-factor sign-in: give it 32 characters or more (openssl rand -hex 32)")
		} else if Env.dev!({}) {
			Ok(Rules.sealing_key(Rules.dev_secret))
		} else {
			Err("auth: two-factor sign-in needs ${settings.key_env}, a secret of 32 characters or more (openssl rand -hex 32), which seals each authenticator's secret")
		}
	}

## The name authenticator apps show: the plugin's `issuer`, else the public URL's host.
issuer! : Auth.Settings => Str
issuer! = |settings|
	if settings.issuer.is_empty() {
		url = Env.public_url!({})
		match url.split_first("://") {
			Ok({ after, .. }) => after
			Err(_) => url
		}
	} else {
		settings.issuer
	}

## Ten new recovery codes.
recovery_codes! : {} => List(Str)
recovery_codes! = |{}| {
	var $codes = []
	while $codes.len() < 10 {
		$codes = $codes.append(Rules.recovery_code(Random.bytes!(10)))
	}
	$codes
}
