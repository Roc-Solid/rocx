import pf.Env
import pf.Middleware
import pf.Server
import auth.Auth
import guard.RateLimit
import guard.Security
import mcp.Auth as McpAuth
import Account
import Address
import guard.Guard
import Store

## What requests go through. `default` runs around every one (main.roc names it); a route file names
## the one for its own route (`middleware = Middlewares.signed_in`), which runs inside it. There are
## three ways in, each handing on who is asking (`Me`):
##
## - `signed_in`, for pages: a session (packages/auth's), or a browser is sent to sign in;
## - `api`, for the JSON API under /api: a personal access token, or the session;
## - `agent`, for MCP (Agents.roc mounts it at /mcp): a personal access token, nothing else.
##
## packages/mcp's `Auth` (`McpAuth` here) reads a bearer token; packages/auth's `Auth` is sign-in.
Middlewares := [].{

	## Who is asking, as a signed-in route is handed it: the person, and how they came. `token` is
	## the id of the personal access token the request carried (`""` for the session cookie: the
	## person in their browser), and `read_only` whether it may only read. Every write checks that
	## (`Notebook.writer`), whichever way it came.
	Me : { person : Store.Person, token : Str, read_only : Bool }

	## Around every request: a change sent by another site's page is refused (403), and every answer
	## has packages/guard's security headers (a Content-Security-Policy that lets the page run its
	## own scripts and WebAssembly, and nothing else), but the OpenAPI page, which loads Scalar from
	## jsDelivr.
	default : Middleware({}, {})
	default = Middleware.same_origin({}).then(Middlewares.security)

	## guard's headers, but on `/openapi.html`.
	security : Middleware({}, {})
	security = Middleware.make(
		|request, context, next!|
			if request.path == "/openapi.html" {
				next!(request, context)
			} else {
				Middleware.run!(Guard.security_headers(Security.defaults), request, context, next!)
			},
	)

	## Pages: someone signed in (packages/auth's `Auth.required`, which keeps a session in use going).
	## A browser asking for a page is sent to sign in, and back here after; anything else is refused
	## (401). Then the session's person, which a session whose person isn't there ends.
	signed_in : Middleware({}, Middlewares.Me)
	signed_in = Auth.required(|{}, session| session).then(Middlewares.person)

	## The person a session signs in, handed on as `Me`. A session whose person isn't there is ended,
	## and the request is answered as a signed-out one.
	person : Middleware(Auth.Session, Middlewares.Me)
	person = Middleware.make(
		|request, session, next!|
			match Store.person!(session.user) {
				Ok(found) => next!(request, { person: found, token: "", read_only: Bool.False })
				Err(NotFound) =>
					if Server.wants_html(request) and request.method == "GET" {
						Auth.sign_out!(request, Server.redirect("/sign-in"))
					} else {
						Auth.sign_out!(request, Server.refused(401, "Sign in first."))
					}
				Err(problem) => {
					_ = Store.refused!(problem)
					Server.refused(500, "Your notes couldn't be read just now; try again.")
				}
			},
	)

	## The JSON API: a personal access token (`Authorization: Bearer acme_pat_…`), or the session
	## (the API is the app's own too). Neither: 401, saying how to send one. A token that isn't good
	## is refused, rather than passed over for the session.
	api : Middleware({}, Middlewares.Me)
	api = Middleware.make(
		|request, {}, next!|
			match McpAuth.bearer(request.headers) {
				Ok(token) =>
					match Account.bearer!(token) {
						Ok(found) => next!(request, found)
						Err(Refused) => unauthorized
					}
				Err(NoToken) =>
					match Account.session!(request) {
						Ok(found) => next!(request, { person: found, token: "", read_only: Bool.False })
						Err(SignedOut) => unauthorized
					}
			},
	)

	## MCP: a personal access token alone. A browser's cookie isn't enough: an AI client acts for
	## you only with a token you made for it, and can revoke.
	agent : Middleware({}, Middlewares.Me)
	agent = Middleware.make(
		|request, {}, next!|
			match McpAuth.bearer(request.headers) {
				Ok(token) =>
					match Account.bearer!(token) {
						Ok(found) => next!(request, found)
						Err(Refused) => unauthorized
					}
				Err(NoToken) => unauthorized
			},
	)

	## MCP calls: 120 a minute for each token, and then one each half second (packages/guard's token
	## bucket), so an agent stuck in a loop can't flood the database. `NOTES_MCP_PER_MINUTE` says
	## otherwise (the tests make it small).
	agent_limit : Middleware(Middlewares.Me, Middlewares.Me)
	agent_limit = Middleware.make(
		|request, me, next!| {
			limit = U64.from_str(Env.var!("NOTES_MCP_PER_MINUTE") ?? "") ?? 120
			Middleware.run!(Guard.rate_limit("mcp", RateLimit.per_minute(limit), |_, asking| asking.token), request, me, next!)
		},
	)

	## Sign-in links: 5 an hour to each address, and then one each 12 minutes, so nobody can fill
	## someone's inbox with links. Counted by the address the link is for, not the client's: the
	## inbox is what needs keeping.
	mail_limit : Middleware({}, {})
	mail_limit = Middlewares.posts_only(Guard.rate_limit("sign-in mail", RateLimit.per_hour(5), |request, _| Middlewares.address_in(request)))

	## `guard` around requests that change something (`POST`, …); the rest pass by it.
	posts_only : Middleware(c, c) -> Middleware(c, c)
	posts_only = |guard| Middleware.make(|request, context, next!| if (Server.changes(request)) Middleware.run!(guard, request, context, next!) else next!(request, context))

	## The address a sign-in form (or JSON) was sent for, as `Address.of` reads it; `""` (not counted)
	## when there is none, which the endpoint refuses anyway.
	address_in : Server.Request -> Str
	address_in = |request| {
		body = Server.text_of(request)
		given =
			if body.starts_with("{") {
				parsed : Try({ email : Str }, [InvalidJson(Str)])
				parsed = Json.parse(body)
				parsed.map_ok(|sent| sent.email) ?? ""
			} else {
				Server.form_fields(body).find_first(|field| field.name == "email").map_ok(|field| field.value) ?? ""
			}
		Address.of(given) ?? ""
	}
}

## Not signed in, or a token that isn't good: 401, and how to send one.
unauthorized : Server.Response
unauthorized =
	Server.response(
		401,
		[{ name: "www-authenticate", value: "Bearer realm=\"Notes\"" }, { name: "content-type", value: "text/plain; charset=utf-8" }],
		"Unauthorized: send a personal access token (Authorization: Bearer acme_pat_…). Make one in Settings.",
	)
