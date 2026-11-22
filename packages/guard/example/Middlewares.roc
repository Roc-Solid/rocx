import pf.Middleware
import pf.Server
import guard.RateLimit
import guard.Security
import guard.Guard
import Features

Middlewares := [].{

	Context : { facts : Str, user : Str }

	## Every request: who is signed in, then the guards.
	default : Middleware({ facts : Str }, Context)
	default =
		signed_in
			.then(Guard.security_headers(Security.defaults))
			.then(Guard.body_limit(1_000_000))
			.then(Guard.maintenance({ flag: Features.maintenance, message: "Back soon.", retry_after_s: 600, except: ["/admin"] }))
			.then(Guard.under("/api", Middlewares.api_limit))

	## 5 a minute from each client, behind one proxy.
	login_limit : Middleware(Context, Context)
	login_limit = Guard.rate_limit("login", RateLimit.per_minute(5), Guard.ip(Hops(1)))

	## 100 a minute for each user, or each address when signed out.
	api_limit : Middleware(Context, Context)
	api_limit = Guard.rate_limit("api", RateLimit.per_minute(100), Guard.user(|context| context.user, Hops(1)))

	## Only for those with the new checkout on.
	beta : Middleware(Context, Context)
	beta = Guard.feature(Features.new_checkout, |context| { user: context.user, groups: [] })

	## Only for the app's admins (ada): anyone else is answered 403.
	admins : Middleware(Context, Context)
	admins = Middleware.make(|request, context, next!| if (context.user == "ada") next!(request, context) else Server.refused(403, "Admins only."))
}

## Who is signed in: the `user` cookie, handed on as `context.user`. A stand-in for the app's own
## sign-in: the cookie isn't signed, so anyone can claim any name. A real app reads its session.
signed_in : Middleware({ facts : Str }, Middlewares.Context)
signed_in = Middleware.make(|request, context, next!| next!(request, { facts: context.facts, user: Server.cookie(request, "user") ?? "" }))
