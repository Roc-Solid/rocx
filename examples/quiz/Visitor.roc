import pf.Middleware
import pf.Random
import pf.Server

## Who is asking: a visitor, known by a random id in a cookie (`pinwheel`), which the server sets
## the first time someone opens a room or joins one. A room remembers its host's id and each
## player's, and nobody else ever sees them: a player is shown by a public id (`p3`) and a name.
## There are no accounts.
Visitor := [].{

	## What every route is handed: the visitor's id, `""` for someone with no cookie yet.
	Context : { visitor : Str }

	## The cookie the id is kept in.
	cookie : Str
	cookie = "pinwheel"

	## Around every request (routes/+middleware.roc; a change sent by another site's page the platform
	## refuses first): the visitor's id, from the cookie, handed on.
	middleware : Middleware({}, Visitor.Context)
	middleware = Middleware.make(|request, {}, next!| next!(request, { visitor: Server.cookie(request, Visitor.cookie) ?? "" }))

	## The visitor's id, or a new one if they have none: and whether it is new (so the answer sets
	## the cookie).
	id! : Visitor.Context => { visitor : Str, new : Bool }
	id! = |context|
		if context.visitor.is_empty() {
			{ visitor: Visitor.hex(Random.bytes!(16)), new: Bool.True }
		} else {
			{ visitor: context.visitor, new: Bool.False }
		}

	## `answer`, setting the visitor's cookie if their id is new: for a year, for this site alone,
	## out of scripts' reach.
	remembered : Server.Response, { visitor : Str, new : Bool } -> Server.Response
	remembered = |answer, { visitor, new }|
		if (new) Server.set_cookie(answer, Visitor.cookie, visitor, { ..Server.cookie_defaults, max_age_s: 365 * 86_400 }) else answer

	## Bytes as lowercase hex.
	hex : List(U8) -> Str
	hex = |bytes| {
		digits = "0123456789abcdef".to_utf8()
		Str.from_utf8_lossy(bytes.join_map(|byte| [digits.get((byte // 16).to_u64()) ?? '0', digits.get((byte % 16).to_u64()) ?? '0']))
	}
}

expect Visitor.hex([0, 15, 16, 255]) == "000f10ff"
expect Visitor.remembered(Server.redirect("/play/BKRT"), { visitor: "abc", new: Bool.False }).headers == [{ name: "location", value: "/play/BKRT" }]
expect Visitor.remembered(Server.redirect("/play/BKRT"), { visitor: "abc", new: Bool.True }).headers == [{ name: "location", value: "/play/BKRT" }, { name: "set-cookie", value: "pinwheel=abc; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax" }]
