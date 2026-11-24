import pf.Server
import pf.Endpoint
import pf.Log
import ../../Account
import ../../Address
import ../../Middlewares

## Links are limited for each address (packages/guard: 5 an hour, then one each 12 minutes).
middleware = Middlewares.mail_limit

## Mails a sign-in link to `email` (packages/auth's `Auth.link!`, in notes' words); signing in with
## it goes on to `then` (a path of this site, or `/`). The answer says where it went. Anyone may sign
## in, and someone new gets a notebook, so the answer is the same whether the address has one
## already: it tells nobody who uses the app.
post! : { request : Server.Request, params : {}, context : {}, body : { email : Str, then : Str } } => Try({ sent : Str }, Endpoint.Refusal)
post! = |{ body, .. }|
	match Address.of(body.email) {
		Err(why) => Err(BadRequest(why))
		Ok(email) =>
			match Account.send_link!(email, body.then) {
				Ok({}) => Ok({ sent: email })
				Err(NotAnAddress) => Err(BadRequest("That doesn't look like an email address."))
				Err(EmailErr(why)) => {
					Log.error!("notes: a sign-in link couldn't be mailed", { error: why })
					Err(Status(503, "The email couldn't be sent just now. Try again in a minute."))
				}
				Err(DbErr(why)) => {
					Log.error!("notes: a sign-in link couldn't be kept", { error: why })
					Err(Status(503, "A sign-in link couldn't be made just now. Try again in a minute."))
				}
			}
	}
