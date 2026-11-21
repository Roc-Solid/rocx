import pf.Server
import pf.Endpoint
import ../../../Generated/Paths

## POST /members/join, from the joining page's form (`name=Ada`, read as `{ name : Str }`): the
## `member` cookie, and on to the members' page.
post! : { request : Server.Request, params : {}, context : c, body : { name : Str } } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	if body.name.trim().is_empty() {
		Err(BadRequest("a member has a name"))
	} else {
		Err(Answer(Server.with_cookie(Server.redirect(Paths.members), "member", body.name.trim())))
	}
