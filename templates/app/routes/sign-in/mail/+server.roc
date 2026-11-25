import pf.Server
import pf.Endpoint
import pf.Log
import auth.Auth
import email.Email
import ../../../Middlewares

## Limited per client and per address (packages/guard), so this route counts mails, not page loads.
middleware = Middlewares.mail_limit

## POST /sign-in/mail, from the sign-in page's form: a link that signs `email` in, mailed to it
## (over SMTP_URL; without it, under `rocx dev`, to the dev mailbox), going on to `then` after. The
## answer is the same whether the address has an account, so it tells nobody who uses the app.
post! : { request : Server.Request, params : {}, context : {}, body : { email : Str, then : Str } } => Try({ sent : Str }, Endpoint.Refusal)
post! = |{ body, .. }| {
	to = body.email.trim().with_ascii_lowercased()
	match Auth.link!(to, body.then) {
		Ok(url) =>
			match Email.send!(message(to, url)) {
				Ok({}) => Ok({ sent: to })
				Err(EmailErr(why)) => {
					Log.error!("sign-in: a link couldn't be mailed", { error: why })
					Err(Status(503, "The email couldn't be sent just now. Try again in a minute."))
				}
			}
		Err(NotAnAddress) => Err(BadRequest("That isn't an email address."))
		Err(DbErr(why)) => {
			Log.error!("sign-in: a link couldn't be kept", { error: why })
			Err(Status(503, "A sign-in link couldn't be made just now. Try again in a minute."))
		}
	}
}

## The mail with the link `url` in it, to `to`.
message : Str, Str -> { to : Str, subject : Str, text : Str, html : Str }
message = |to, url| {
	to: to,
	subject: "Sign in to {{title}}",
	text: "Open this link to sign in to {{title}}:\n\n${url}\n\nIt works once, for the next 15 minutes. If you didn't ask for it, ignore this email.\n",
	html: "<p><a href=\"${url}\">Sign in to {{title}}</a></p><p>It works once, for the next 15 minutes. If you didn't ask for it, ignore this email.</p>",
}
