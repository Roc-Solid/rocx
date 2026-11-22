import pf.Env
import pf.Kv
import pf.Log
import pf.Random
import pf.Server
import pf.Time
import crypto.Base64
import email.Email
import crypto.Hkdf
import Session
import Store
import Token

## Signing in and who is asking: the effects around the rules in Session.roc and Token.roc.
##
## - **A sign-in link** is a random token, mailed (packages/email's `Email.send!`: the dev mailbox
##   when the server has no SMTP server) and kept in `Kv` by its hash, for 15 minutes. Kv because a link is short-lived
##   and good once: `Kv.take!` reads it and forgets it in one atomic step, so two clicks at once
##   can't both sign in, and its time to live forgets it with nothing to clean up. A restart forgets
##   the links on their way, which only means asking for another; a table in the database would keep
##   them, and need a job to sweep the old ones out.
## - **A session** is a signed cookie (Session.roc), so the server keeps none.
## - **A personal access token** is kept as its hash, in the database (it must outlive a restart).
Account := [].{

	## What `Kv` keeps for a link that is on its way: who it signs in, and where they were going.
	Link : { email : Str, then : Str }

	## Mails `email` a link that signs them in and takes them to `then` (a path of this site), good
	## for 15 minutes (`NOTES_LINK_TTL_MS` says otherwise), and once.
	send_link! : Str, Str => Try({}, [EmailErr(Str)])
	send_link! = |email, then| {
		token = Token.link(Random.bytes!(32))
		ttl_ms = Account.link_ttl_ms!({})
		Kv.set!(link_key(token), { email: email, then: Account.path_of(then) }, { ttl_ms: ttl_ms })
		url = "${Account.origin!({})}/sign-in/link?token=${token}"
		minutes = (ttl_ms // 60_000).to_str()
		Email.send!({
			to: email,
			subject: "Your sign-in link for Notes",
			text: "Open this link to sign in to Notes:\n\n${url}\n\nIt works once, for the next ${minutes} minutes. If you didn't ask for it, ignore this email: nobody can sign in without the link.\n",
			html: "<p>Open this link to sign in to Notes:</p><p><a href=\"${url}\">Sign in to Notes</a></p><p>It works once, for the next ${minutes} minutes. If you didn't ask for it, ignore this email: nobody can sign in without the link.</p>",
		})
	}

	## How long a link is good for.
	link_ttl_ms! : {} => U64
	link_ttl_ms! = |{}| U64.from_str(Env.var!("NOTES_LINK_TTL_MS") ?? "") ?? 15 * 60_000

	## Who a link signs in, while it is good: what its page asks you to confirm. Looking doesn't use
	## it, so a mail scanner that follows links doesn't spend yours.
	link_for! : Str => Try(Account.Link, [Gone])
	link_for! = |token|
		if Token.is_link(token) {
			found : Try(Account.Link, [NotFound, BadValue(Str)])
			found = Kv.get!(link_key(token))
			found.map_err(|_| Gone)
		} else {
			Err(Gone)
		}

	## Uses a link: who it signs in, and never again.
	use_link! : Str => Try(Account.Link, [Gone])
	use_link! = |token|
		if Token.is_link(token) {
			taken : Try(Account.Link, [NotFound, BadValue(Str)])
			taken = Kv.take!(link_key(token))
			taken.map_err(|_| Gone)
		} else {
			Err(Gone)
		}

	## Where the app is, for links in email and the MCP server's address: the server's public URL
	## (`PUBLIC_URL`, or where it listens). Never the request's `Host`, which whoever asks for a link
	## can set: a link to their own site, mailed to you, would hand them your token.
	origin! : {} => Str
	origin! = |{}| Env.public_url!({})

	## A path of this site to go to after signing in: `then` if it is one (`/notes/4`), else `/`; never
	## another site (`//elsewhere.example`), so a link can't send you off after you sign in.
	path_of : Str -> Str
	path_of = |then| if (then.starts_with("/") and !then.starts_with("//") and !then.contains("\\")) then else "/"

	## `answer`, with the cookie that signs `person` in, for 30 days.
	signed_in! : Server.Response, Store.Person => Server.Response
	signed_in! = |answer, person| {
		expires = Time.now_millis!({}) + Session.lifetime_ms
		value = Session.sign(key!({}), { person: person.id, epoch: person.epoch, expires })
		Server.set_cookie(answer, Session.cookie, value, { ..Server.cookie_defaults, max_age_s: Session.lifetime_ms // 1000 })
	}

	## `answer`, with the session cookie gone.
	signed_out : Server.Response -> Server.Response
	signed_out = |answer| Server.clear_cookie(answer, Session.cookie, Server.cookie_defaults)

	## Who a request's session cookie signs in: a cookie the server signed, still good, of someone
	## who hasn't signed out everywhere since.
	session! : Server.Request => Try(Store.Person, [SignedOut])
	session! = |request|
		match Server.cookie(request, Session.cookie) {
			Ok(value) =>
				match Session.verify(key!({}), value, Time.now_millis!({})) {
					Ok(claim) =>
						match Store.person!(claim.person) {
							Ok(person) if person.epoch == claim.epoch => Ok(person)
							_ => Err(SignedOut)
						}
					Err(_) => Err(SignedOut)
				}
			Err(Missing) => Err(SignedOut)
		}

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

## The key in `Kv` for a link: its token's hash, so not even the server's memory holds a token that
## signs anyone in.
link_key : Str -> Str
link_key = |token| "notes:link:${Token.hash(token)}"

## The key sessions are signed with: derived from `NOTES_SECRET` (HKDF, packages/crypto), or, when
## that isn't set, made at random the first time it is needed and kept in the server's memory, so a
## restart signs everyone out (the log says so).
key! : {} => List(U8)
key! = |{}| {
	secret =
		match Env.var!("NOTES_SECRET") {
			Ok(given) if !given.trim().is_empty() => given.to_utf8()
			_ => {
				made = Base64.url_encode(Random.bytes!(32))
				match Kv.add!("notes:secret", made, {}) {
					Ok({}) => Log.warn!("notes: NOTES_SECRET isn't set, so sessions are signed with a key made now; a restart signs everyone out", {})
					Err(Exists) => {}
				}
				kept : Try(Str, [NotFound, BadValue(Str)])
				kept = Kv.get!("notes:secret")
				(kept ?? made).to_utf8()
			}
		}
	Hkdf.sha256(secret, "acme-notes".to_utf8(), "session cookie".to_utf8(), 32) ?? secret
}

expect Account.path_of("/notes/4?x=1") == "/notes/4?x=1"
expect Account.path_of("//elsewhere.example/") == "/"
expect Account.path_of("https://elsewhere.example/") == "/"
expect Account.path_of("/\\elsewhere.example") == "/"
expect Account.path_of("") == "/"
