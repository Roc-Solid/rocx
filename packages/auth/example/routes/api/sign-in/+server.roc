import pf.Server
import pf.Endpoint
import pf.Log
import auth.Auth
import email.Email

## GET /api/sign-in: what the page offers besides an address: the providers set up, and whether the dev
## sign-in is open (under `--dev`).
get! : { request : Server.Request, params : {}, context : {} } => Try({ providers : List({ name : Str, label : Str, path : Str }), dev : Bool }, Endpoint.Refusal)
get! = |_| Ok({ providers: Auth.providers!({}), dev: Auth.dev_sign_in!({}) })

## POST /api/sign-in, from its form: a sign-in link mailed to `email` (packages/email: the dev mailbox
## when the server has no SMTP server), going on to `then`.
post! : { request : Server.Request, params : {}, context : {}, body : { email : Str, then : Str } } => Try({ sent : Str }, Endpoint.Refusal)
post! = |{ body, .. }|
	match Auth.link!(body.email, body.then) {
		Ok(url) => {
			to = body.email.trim()
			sent = Email.send!({
				to: to,
				subject: "Your sign-in link",
				text: "Open this link to sign in:\n\n${url}\n\nIt works once, for the next 15 minutes. If you didn't ask for it, ignore this email.\n",
				html: "<p><a href=\"${url}\">Sign in</a></p><p>It works once, for the next 15 minutes. If you didn't ask for it, ignore this email.</p>",
			})
			match sent {
				Ok({}) => Ok({ sent: to })
				Err(EmailErr(why)) => {
					Log.error!("example: a sign-in link couldn't be mailed", { error: why })
					Err(Status(503, "The email couldn't be sent just now. Try again in a minute."))
				}
			}
		}
		Err(NotAnAddress) => Err(BadRequest("That isn't an email address."))
		Err(DbErr(why)) => Err(Status(503, why))
	}
