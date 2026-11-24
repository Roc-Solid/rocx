import pf.Db
import pf.Env
import pf.Http
import pf.Log
import pf.Middleware
import pf.Plugin
import pf.Random
import pf.Server
import pf.Time
import AuthStore
import Rules
import "migrations/0001_auth.sql" as table : Str

## Sign-in for Roc Solid apps, as a plugin (D-072): by a link mailed to an address, or at a
## provider (Google, GitHub, any OpenID Connect one); sessions kept as their token's hash in the
## app's database; middleware that hands the signed-in user on. It has no pages: the app's sign-in
## page posts to it and links to it, and its own `admit!` says who gets in.
##
## ```roc
## plugins: [Auth.plugin({ admit!: Accounts.admit!, providers: [Auth.google, Auth.github] })]
## ```
##
## The plugin's endpoints, under `at` (`/auth`): `GET|POST <at>/link?token=…` (a mailed link,
## used once; with `link_page`, the link goes to the app's page, which posts its token here), `GET <at>/<provider>?then=…` (off to a provider) and `GET <at>/<provider>/callback`
## (back from it), `POST <at>/sign-out`, and `POST <at>/dev` (any address, under `--dev` only).
## Each answers with a redirect: where the browser was going, or the app's sign-in page with why
## not (`?error=link|refused|provider|state|unavailable`, and `&reason=` for `refused` and
## `provider`).
Auth := [].{

	## Who is signing in, as the plugin hands them to `admit!`: the provider ("email" for a link or
	## the dev sign-in), who they are there (the address, or the provider's own id for them), their
	## address (lower-cased; "" when the provider has none it says is verified), their name (or ""),
	## and the user this identity signed in as before (`Known`), if it has.
	Identity : { provider : Str, subject : Str, email : Str, name : Str, user : [New, Known(Str)] }

	## A signed-in session: the app's id for its user, the session's own id (for `revoke!`), and
	## when it ends (milliseconds since 1970).
	Session : { user : Str, id : Str, expires_ms : I64 }

	## Whether a request is signed in, as `optional` hands it on.
	Signed : [SignedOut, SignedIn(Auth.Session)]

	## A provider to sign in at: its name (its endpoints are `<at>/<name>` and
	## `<at>/<name>/callback`, the redirect URI to register with it), the label for the app's
	## button, how it says who signed in (`Oidc`: an ID token from one of these issuers; `GitHub`:
	## its API at this URL), its endpoints, the scopes asked for, and the environment variables that
	## hold the app's client id and secret there. `Auth.google`, `Auth.github` and `Auth.oidc` make
	## one; a record update changes any part (`{ ..Auth.google, client_id_env: "ACME_GOOGLE_ID" }`).
	Provider : {
		name : Str,
		label : Str,
		flow : [Oidc(List(Str)), GitHub(Str)],
		authorize_url : Str,
		token_url : Str,
		scopes : List(Str),
		client_id_env : Str,
		client_secret_env : Str,
	}

	## The plugin's options:
	## - `admit!`: who gets in. Given who is signing in, the app's id for its user, or why not
	##   (shown on the sign-in page). It runs inside the transaction that starts the session, so
	##   what it writes (a new user's row, a job it queues) stays only if the sign-in does; keep
	##   anything slow (a fetch) out of it.
	## - `at`: where the plugin's endpoints are (`/auth`).
	## - `sign_in`: the app's sign-in page, where a signed-out request (`required`) and a sign-in
	##   that failed go (`/sign-in`).
	## - `home`: where a sign-in goes when it wasn't going anywhere (`/`).
	## - `providers`: where else one may sign in (none: links alone).
	## - `session_days`: how long a session lasts (30); one used in its second half is kept for as
	##   long again.
	## - `link_minutes`: how long a mailed link is good for (15).
	## - `link_page`: the app's page a mailed link opens (`/sign-in/link`), which shows whom it signs
	##   in (`link_for!`) and posts its token to `<at>/link` from a button. A mail scanner that
	##   follows every link in a message then can't use one up. "" (the default): the link goes
	##   straight to `<at>/link`, and opening it signs in.
	## - `cookie`: the session cookie's name (`session`, `__Host-session` on HTTPS).
	Options := {
		admit! : Auth.Identity => Try(Str, Str),
		at : Str ?? "/auth",
		sign_in : Str ?? "/sign-in",
		home : Str ?? "/",
		providers : List(Auth.Provider) ?? [],
		session_days : U64 ?? 30,
		link_minutes : U64 ?? 15,
		link_page : Str ?? "",
		cookie : Str ?? "session",
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
		providers : List({ name : Str, label : Str, client_id_env : Str }),
	}

	## The auth plugin: its endpoints (behind the app's middleware), its tables
	## (`auth/0001_auth`, the same on SQLite and Postgres), and its settings, kept at start. It
	## needs a database.
	plugin : Auth.Options -> Plugin.Value(context, ctx)
	plugin = |options| {
		settings = settings_of(options)
		admit! = options.admit!
		at = settings.at
		away = options.providers.map(
			|provider| [
				{ method: "GET", path: "${at}/${provider.name}", kind: Endpoint, answer!: |request, _| away!(settings, provider, request) },
				{ method: "GET", path: "${at}/${provider.name}/callback", kind: Endpoint, answer!: |request, _| back!(settings, admit!, provider, request) },
			],
		)
		{
			name: "auth",
			routes: [
				{ method: "GET", path: "${at}/link", kind: Endpoint, answer!: |request, _| linked!(settings, admit!, request) },
				{ method: "POST", path: "${at}/link", kind: Endpoint, answer!: |request, _| linked!(settings, admit!, request) },
				{ method: "POST", path: "${at}/dev", kind: Endpoint, answer!: |request, _| dev!(settings, admit!, request) },
				{ method: "POST", path: "${at}/sign-out", kind: Endpoint, answer!: |request, _| signed_out!(settings, request) },
			].concat(List.join(away)),
			migrations: [{ name: "0001_auth", sql: table }],
			starts: [
				|_context| {
					Plugin.keep!("auth:settings", Json.to_str(settings))
					Ok({})
				},
			],
			needs: [Database],
		}
	}

	## Google (OpenID Connect): `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, from an OAuth client
	## of the "Web application" kind whose redirect URI is `<public URL>/auth/google/callback`.
	google : Auth.Provider
	google = {
		name: "google",
		label: "Google",
		flow: Oidc(["https://accounts.google.com", "accounts.google.com"]),
		authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
		token_url: "https://oauth2.googleapis.com/token",
		scopes: ["openid", "email", "profile"],
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
		client_id_env: given.client_id_env,
		client_secret_env: given.client_secret_env,
	}

	## A sign-in link for `email` that goes on to `then` (a path of this site, else `home`): the URL
	## to mail them (to `link_page`, or to `<at>/link`), good once, for `link_minutes`. The app sends it, as it likes (packages/email,
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

	## The session a request's cookie holds, if it holds one that hasn't ended.
	session! : Server.Request => Try(Auth.Session, [SignedOut])
	session! = |request| {
		settings = settings!({})
		match Server.cookie(request, Rules.cookie(settings.cookie, https!({}))) {
			Ok(token) if Rules.is_token(token) =>
				match AuthStore.find!(Rules.hash(token), now!({})) {
					Ok(Found(row)) => Ok({ user: row.user_id, id: row.id, expires_ms: row.expires_at })
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
	## the context); a signed-out one goes to the sign-in page (a page's GET, with `?then=` to come
	## back), or is refused with a 401.
	required : (ctx, Auth.Session -> out) -> Middleware(ctx, out)
	required = |add|
		Middleware.make(
			|request, given, next!|
				match Auth.session!(request) {
					Ok(session) => kept!(request, session, next!(request, add(given, session)))
					Err(SignedOut) =>
						if Server.wants_html(request) and request.method == "GET" {
							Server.redirect(Rules.url(settings!({}).sign_in, [("then", here(request))]))
						} else {
							Server.refused(401, "Sign in first.")
						}
				},
		)

	## `answer`, with a new session for `user` (the app's id for them) in its cookie: for an app's
	## own way in (a sign-up form that signs in at once, a test).
	sign_in! : Server.Response, Str => Try(Server.Response, [DbErr(Str), ..others])
	sign_in! = |answer, user| {
		settings = settings!({})
		token = Rules.token(Random.bytes!(32))
		now = now!({})
		AuthStore.start!({ id: Rules.hash(token), user: user, now: now, expires: now + settings.session_ms })?
		Ok(with_session(answer, settings, https!({}), token))
	}

	## `answer`, with the request's session ended and its cookie gone.
	sign_out! : Server.Request, Server.Response => Server.Response
	sign_out! = |request, answer| {
		settings = settings!({})
		https = https!({})
		name = Rules.cookie(settings.cookie, https)
		match Server.cookie(request, name) {
			Ok(token) if Rules.is_token(token) =>
				match AuthStore.end!(Rules.hash(token)) {
					Ok(_) => {}
					Err(DbErr(why)) => Log.error!("auth: a session couldn't be ended", { error: why })
				}
			_ => {}
		}
		Server.clear_cookie(answer, name, cookie_opts(https, 0))
	}

	## Ends every session of `user` (signing out everywhere, or after their password or address
	## changed): how many ended.
	sign_out_everywhere! : Str => Try(U64, [DbErr(Str), ..others])
	sign_out_everywhere! = |user| AuthStore.end_all!(user)

	## `user`'s sessions that haven't ended, the newest first: each one's id (for `revoke!`), when
	## it began and when it ends.
	sessions! : Str => Try(List({ id : Str, created_ms : I64, expires_ms : I64 }), [DbErr(Str), BadRow(Str), ..others])
	sessions! = |user| {
		rows = AuthStore.of_user!(user, now!({}))?
		Ok(rows.map(|row| { id: row.id, created_ms: row.created_at, expires_ms: row.expires_at }))
	}

	## Ends `user`'s session `id` (one of `sessions!`), and no one else's: how many ended (0 or 1).
	revoke! : Str, Str => Try(U64, [DbErr(Str), ..others])
	revoke! = |user, id| AuthStore.revoke!(user, id)

	## The identities `user` has signed in with: each provider, their id there, the address it gave.
	identities! : Str => Try(List({ provider : Str, subject : Str, email : Str }), [DbErr(Str), BadRow(Str), ..others])
	identities! = |user| AuthStore.identities!(user)

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
}

## The settings an app's options make.
settings_of : Auth.Options -> Auth.Settings
settings_of = |options| {
	at: if (options.at.ends_with("/")) options.at.drop_suffix("/") else options.at,
	sign_in: options.sign_in,
	home: options.home,
	session_ms: (options.session_days * 86_400_000).to_i64_wrap(),
	link_ms: (options.link_minutes * 60_000).to_i64_wrap(),
	link_page: options.link_page,
	cookie: options.cookie,
	providers: options.providers.map(|provider| { name: provider.name, label: provider.label, client_id_env: provider.client_id_env }),
}

## The settings when the plugin isn't listed (or hasn't started): its options' defaults.
defaults : Auth.Settings
defaults = { at: "/auth", sign_in: "/sign-in", home: "/", session_ms: 30 * 86_400_000, link_ms: 15 * 60_000, link_page: "", cookie: "session", providers: [] }

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
## the identity's row and the session's, and the session's cookie on the answer; or the sign-in
## page, with why not.
signed_in! : Auth.Settings, (Auth.Identity => Try(Str, Str)), { provider : Str, subject : Str, email : Str, name : Str }, Str => Server.Response
signed_in! = |settings, admit!, who, then| {
	token = Rules.token(Random.bytes!(32))
	now = now!({})
	started = Db.transaction!(
		|{}| {
			known = AuthStore.known!(who.provider, who.subject)?
			user = admit!({ provider: who.provider, subject: who.subject, email: who.email, name: who.name, user: known }).map_err(|why| Refused(why))?
			AuthStore.linked!({ provider: who.provider, subject: who.subject, user: user, email: who.email, now: now })?
			AuthStore.start!({ id: Rules.hash(token), user: user, now: now, expires: now + settings.session_ms })?
			Ok(user)
		},
	)
	match started {
		Ok(_) => with_session(Server.redirect(Rules.path(then, settings.home)), settings, https!({}), token)
		Err(Refused(why)) => Server.redirect(Rules.failed(settings.sign_in, "refused", why, then))
		Err(DbErr(why)) => unavailable!(settings, why)
		Err(BadRow(why)) => unavailable!(settings, why)
	}
}

## A sign-in the database couldn't take: on the log, and the sign-in page says so.
unavailable! : Auth.Settings, Str => Server.Response
unavailable! = |settings, why| {
	Log.error!("auth: a sign-in failed", { error: why })
	Server.redirect(Rules.failed(settings.sign_in, "unavailable", "", ""))
}

## `<at>/link`: a mailed link used (its token in the query, or a form's field, as a page that asks
## first posts it), signing in its address.
linked! : Auth.Settings, (Auth.Identity => Try(Str, Str)), Server.Request => Server.Response
linked! = |settings, admit!, request| {
	token = if (request.method == "POST") Rules.query(Server.text_of(request), "token") else Rules.query(request.query, "token")
	if Rules.is_token(token) {
		match AuthStore.use_link!(Rules.hash(token), now!({})) {
			Ok(Found(link)) => signed_in!(settings, admit!, { provider: "email", subject: link.email, email: link.email, name: "" }, link.return_to)
			Ok(Missing) => Server.redirect(Rules.failed(settings.sign_in, "link", "", ""))
			Err(DbErr(why)) => unavailable!(settings, why)
			Err(BadRow(why)) => unavailable!(settings, why)
		}
	} else {
		Server.redirect(Rules.failed(settings.sign_in, "link", "", ""))
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
			Err(NotAnAddress) => Server.redirect(Rules.failed(settings.sign_in, "refused", "That isn't an email address.", then))
		}
	} else {
		Server.refused(404, "Not found")
	}

## `<at>/sign-out`: the session ended, its cookie gone, and on to `then` (a form's field), else home.
signed_out! : Auth.Settings, Server.Request => Server.Response
signed_out! = |settings, request| Auth.sign_out!(request, Server.redirect(Rules.path(Rules.query(Server.text_of(request), "then"), settings.home)))

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
		Server.redirect(Rules.failed(settings.sign_in, "provider", "Signing in with ${provider.label} isn't set up: ${provider.client_id_env} is empty.", then))
	} else {
		https = https!({})
		state = Rules.token(Random.bytes!(32))
		verifier = Rules.token(Random.bytes!(32))
		nonce = Rules.token(Random.bytes!(32))
		kept = Rules.state_value({ provider: provider.name, state: state, verifier: verifier, nonce: nonce, then: then })
		url = Rules.authorize({ authorize_url: provider.authorize_url, client_id: client_id, redirect_uri: callback!(settings, provider), scopes: provider.scopes, state: state, verifier: verifier, nonce: nonce })
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
					Server.redirect(Rules.failed(settings.sign_in, "provider", if (described.is_empty()) refused else described, state.then))
				} else {
					match who!(settings, provider, Rules.query(request.query, "code"), state) {
						Ok(who) => signed_in!(settings, admit!, { provider: provider.name, subject: who.subject, email: who.email, name: who.name }, state.then)
						Err(why) => {
							Log.warn!("auth: a sign-in at a provider failed", { provider: provider.name, error: why })
							Server.redirect(Rules.failed(settings.sign_in, "provider", why, state.then))
						}
					}
				}
			}
			_ => Server.redirect(Rules.failed(settings.sign_in, "state", "", ""))
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
