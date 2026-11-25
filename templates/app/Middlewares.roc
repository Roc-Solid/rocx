import pf.Log
import pf.Middleware
import pf.Server
import auth.Auth
import guard.ClientIp
import guard.Guard
import guard.RateLimit
import guard.Security
import Accounts

## What requests go through. `default` runs around every one (main.roc names it). A route file names
## one of the others for its own route (`middleware = Middlewares.signed_in`), which runs inside it.
Middlewares := [].{

	## What a signed-in route is handed: the user, and the id of the session they came with.
	Me : { user : Accounts.User, session : Str }

	## What a route anyone may use is handed: whether the request is signed in.
	Visitor : { signed : Auth.Signed }

	## Around every request: a post from another site's page is refused (403), and every answer
	## carries security headers (packages/guard: a Content-Security-Policy that lets pages run the
	## site's own scripts and nothing else, HSTS, and the rest). Under `--dev` the CSP only reports.
	default : Middleware({}, {})
	default = Middleware.same_origin({}).then(Guard.security_headers(Security.defaults))

	## Signed-in requests only, with their user's row read. Signed out, a page goes to the sign-in
	## page (and comes back after); anything else is a 401. A session whose user is gone ends, and is
	## answered the same; a database that can't be read just now is a 500, the session kept.
	signed_in : Middleware({}, Middlewares.Me)
	signed_in = Auth.required_with(
		|{}, session|
			match Accounts.user!(session.user) {
				Ok(Found(user)) => Ok({ user: user, session: session.id })
				Ok(Missing) => Err(SignedOut)
				Err(DbErr(why)) | Err(BadRow(why)) => {
					Log.error!("accounts: a user couldn't be read", { error: why })
					Err(Answer(Server.refused(500, "Your account couldn't be read just now. Try again in a minute.")))
				}
			},
	)

	## Anyone, signed in or not.
	anyone : Middleware({}, Middlewares.Visitor)
	anyone = Auth.optional(|{}, signed| { signed: signed })

	## Sign-in mail: 5 a minute from each client, and 5 an hour to each address, so nobody can fill
	## someone's inbox with links. A limited post is answered 429, or a plain form goes back to its
	## page saying when to try again.
	mail_limit : Middleware({}, {})
	mail_limit =
		Guard.rate_limit("sign-in mail from a client", RateLimit.per_minute(5), Guard.ip(Middlewares.proxies))
			.then(Guard.rate_limit("sign-in mail to an address", RateLimit.per_hour(5), |request, _| Middlewares.address_in(request)))

	## Who a client is, for the rate limits: the server sits behind one proxy (Caddy, a load
	## balancer) that adds the client's address to `X-Forwarded-For`. With no proxy in front, write
	## `Direct`, or a client can name any address it likes.
	proxies : ClientIp.Trust
	proxies = Hops(1)

	## The address a sign-in form (or JSON) was posted for, lower-cased; "" (not counted) when there
	## is none, which the endpoint refuses anyway.
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
		given.trim().with_ascii_lowercased()
	}
}
