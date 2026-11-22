import pf.Server
import pf.Endpoint
import ../../Middlewares
import ../../Store
import ../../Generated/Paths

## POST /me, from the "Who are you?" page: the cookie that says who you are (a year, this site
## only, not readable by scripts), and on to the front page; `person=""` forgets it.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : { person : Str } } => Try({}, Endpoint.Refusal)
post! = |{ body, .. }|
	if body.person.is_empty() {
		Err(Answer(Server.clear_cookie(Server.redirect(Paths.root), Middlewares.cookie, Server.cookie_defaults)))
	} else if Store.is_person!(body.person).map_err(Store.refusal)? {
		kept = { ..Server.cookie_defaults, max_age_s: 365 * 86_400 }
		Err(Answer(Server.set_cookie(Server.redirect(Paths.root), Middlewares.cookie, body.person, kept)))
	} else {
		Err(BadRequest("Pick someone on the team."))
	}
