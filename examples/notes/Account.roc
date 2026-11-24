import pf.Env
import pf.Random
import pf.Server
import auth.Auth
import email.Email
import Store
import Token

## Signing in and who is asking: the app's half of packages/auth's plugin (main.roc lists it), and
## personal access tokens.
##
## - **A sign-in link** is the plugin's (`Auth.link!`): a random token, kept by its hash in the
##   database for 15 minutes, and used once (in one statement, so two clicks at once can't both
##   sign in). Notes mails it, in its own words (packages/email's `Email.send!`: the dev mailbox
##   when the server has no SMTP server). It opens /sign-in/link, whose button posts it to
##   /auth/link, so a mail scanner that follows links doesn't use it up.
## - **A session** is the plugin's too: a random token in the `notes_session` cookie, kept by its
##   hash in the database, for 30 days. `admit!` says which person a link signs in.
## - **A personal access token** is notes' own, kept as its hash in the database.
Account := [].{

	## How long a sign-in link is good for: 15 minutes (main.roc gives it to the plugin, and the mail
	## says it).
	link_ms : U64
	link_ms = 15 * 60_000

	## Mails `email` a link that signs them in and takes them to `then` (a path of this site; the
	## plugin sends anything else to `/`), good for `link_ms`, and once.
	send_link! : Str, Str => Try({}, [EmailErr(Str), NotAnAddress, DbErr(Str)])
	send_link! = |email, then| {
		url = Auth.link!(email, then)?
		minutes = (Account.link_ms // 60_000).to_str()
		Email.send!({
			to: email,
			subject: "Your sign-in link for Notes",
			text: "Open this link to sign in to Notes:\n\n${url}\n\nIt works once, for the next ${minutes} minutes. If you didn't ask for it, ignore this email: nobody can sign in without the link.\n",
			html: "<p>Open this link to sign in to Notes:</p><p><a href=\"${url}\">Sign in to Notes</a></p><p>It works once, for the next ${minutes} minutes. If you didn't ask for it, ignore this email: nobody can sign in without the link.</p>",
		})?
		Ok({})
	}

	## Who gets in, as the plugin asks at each sign-in: anyone with the address a link was mailed
	## to. Its person is the one with that address, or someone new (`Store.person_for!`, which starts
	## a new notebook with a note of welcome); the plugin keeps the person's id in the session. It
	## runs inside the transaction that starts the session, so a new person stays only if the
	## session starts.
	admit! : Auth.Identity => Try(Str, Str)
	admit! = |identity|
		if identity.email.is_empty() {
			Err("Signing in needs an email address.")
		} else {
			match Store.person_for!(identity.email) {
				Ok(person) => Ok(person.id)
				Err(problem) => {
					# Its details go to the server's log (`Store.refused!`); the sign-in page says to try again.
					_ = Store.refused!(problem)
					Err("Signing in didn't work just now. Try again in a minute.")
				}
			}
		}

	## Who a request's session signs in: the plugin's session, and its person. `SignedOut` for none,
	## or for a session whose person isn't there.
	session! : Server.Request => Try(Store.Person, [SignedOut])
	session! = |request| {
		session = Auth.session!(request)?
		Store.person!(session.user).map_err(|_| SignedOut)
	}

	## Where the app is, for the MCP server's address: the server's public URL (`PUBLIC_URL`, or
	## where it listens). Never the request's `Host`, which whoever asks can set. (The plugin makes
	## sign-in links to it too.)
	origin! : {} => Str
	origin! = |{}| Env.public_url!({})

	## A new personal access token for `person`: the token, shown once, and its row, which keeps its
	## hash.
	make_token! : Str, { name : Str, read_only : Bool } => Try(Token.Made, Store.Problem)
	make_token! = |person, { name, read_only }| {
		token = Token.personal(Random.bytes!(32))
		listed = Store.add_token!(person, { name, read_only, hash: Token.hash(token), hint: Token.hint(token) })?
		Ok({ token, listed })
	}

	## Whose a bearer token is, and whether it may write. Only a token with a personal access
	## token's shape is looked up, by its hash.
	bearer! : Str => Try({ person : Store.Person, token : Str, read_only : Bool }, [Refused])
	bearer! = |token|
		if Token.is_personal(token) {
			Store.bearer!(Token.hash(token)).map_err(|_| Refused)
		} else {
			Err(Refused)
		}
}
