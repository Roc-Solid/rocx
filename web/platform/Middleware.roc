import Server

## Code that runs around an answer. A middleware gets the request, the context so far and what
## comes next: it answers itself (a guard: a redirect, a refusal), or calls `next!` with the
## context it hands on (who is signed in), or changes what comes back (a header).
##
##     signed_in = Middleware.make(|request, context, next!|
##         match Session.user!(request) {
##             Ok(user) => next!(request, { facts: context.facts, user })
##             Err(_) => Server.redirect("/sign-in")
##         })
##
## `a.then(b)` is `a`, then `b`; `Middleware.when(Server.changes, guard)` is `guard` for some
## requests alone. Middleware is named by folder, as routes are (D-103): a `+middleware.roc` under
## `routes/` (`middleware = Middlewares.member`) runs around every page, endpoint and channel in its
## folder and the folders below it, outermost first; the one in `routes/` itself runs around every
## request for the app's routes, and one for a path nothing answers. A folder in brackets,
## `(members)`, adds nothing to the path: pages and their endpoints under `api/` share one that way.
## A plugin's routes and the OpenAPI document aren't in `routes/`: each is behind the middleware the
## app gives it (D-114: `Auth.plugin({ …, middleware: Middlewares.default })`,
## `openapi: Page(Scalar, Middlewares.default.then(Middlewares.admin))`), `Middleware.none({})` for
## none. What a middleware hands on is typed: a handler that reads `context.user` compiles only
## behind one that adds it.
Middleware(given, handed) :: { run : Server.Request, given, (Server.Request, handed => Server.Response) => Server.Response }.{

	## A middleware, from what it does.
	make : (Server.Request, given, (Server.Request, handed => Server.Response) => Server.Response) -> Middleware(given, handed)
	make = |run| { run: run }

	## No middleware: every request handed on as it came, with the context it came with. What an app
	## gives a plugin whose routes anyone may reach (`Stripe.plugin({ …, middleware: Middleware.none({}) })`).
	none : {} -> Middleware(context, context)
	none = |{}| { run: |request, context, next!| next!(request, context) }

	## `first`, then `second`: `second` gets what `first` hands on.
	then : Middleware(a, b), Middleware(b, c) -> Middleware(a, c)
	then = |first, second| {
		run_first = first.run
		run_second = second.run
		{ run: |request, context, next!| run_first(request, context, |passed, handed| run_second(passed, handed, next!)) }
	}

	## Runs it around `last!`: what answers once every middleware has passed the request on.
	run! : Middleware(given, handed), Server.Request, given, (Server.Request, handed => Server.Response) => Server.Response
	run! = |middleware, request, context, last!| {
		go = middleware.run
		go(request, context, last!)
	}

	## `guard` for the requests `asked` says, and the rest passed on as they are
	## (`Middleware.when(Server.changes, Guard.rate_limit(…))`: a limit on what changes something,
	## reads let through).
	when : (Server.Request -> Bool), Middleware(context, context) -> Middleware(context, context)
	when = |asked, guard| {
		run_guard = guard.run
		{ run: |request, context, next!| if (asked(request)) run_guard(request, context, next!) else next!(request, context) }
	}

	## A request that would change something (POST, PUT, PATCH, DELETE: a form, an endpoint's send,
	## an action) sent by another site's page refused, with a 403. A page of another site
	## can make a browser send one, with this site's cookies; a browser says which site's page did
	## (`Origin`). A client that isn't a page (`curl`) sends none, and is let through.
	same_origin : {} -> Middleware(context, context)
	same_origin = |{}|
		Middleware.make(
			|request, context, next!|
				if Server.changes(request) and !Server.same_origin(request) {
					Server.refused(403, "${request.method} ${request.path} is sent from a page of this site")
				} else {
					next!(request, context)
				},
		)

	## Every answer with these headers too.
	headers : List({ name : Str, value : Str }) -> Middleware(context, context)
	headers = |added|
		Middleware.make(
			|request, context, next!| {
				answer = next!(request, context)
				{ ..answer, headers: answer.headers.concat(added) }
			},
		)
}
