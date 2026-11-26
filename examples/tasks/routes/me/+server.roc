import pf.Server
import pf.Endpoint
import auth.Auth
import ../../Middlewares
import ../../Store
import ../../Generated/Paths

## POST /me, from the "Who are you?" page: you are the person picked, and on to the front page;
## `person=""` forgets you. Who you are is a session (packages/auth): `Auth.sign_in!` starts one for
## the person and sets its cookie, `tasks_session`, which holds a random token (the person's id stays
## on the server). The session you had ends as it starts (`Auth.switch!`), so a browser has one.
post! : { request : Server.Request, params : {}, context : Middlewares.Context, body : { person : Str } } => Try({}, Endpoint.Refusal)
post! = |{ request, body, .. }|
	if body.person.is_empty() {
		Err(Answer(Auth.sign_out!(request, Server.redirect(Paths.root))))
	} else if Store.is_person!(body.person).map_err!(Store.refusal!)? {
		match Auth.switch!(request, Server.redirect(Paths.root), body.person) {
			Ok(answer) => Err(Answer(answer))
			Err(DbErr(why)) => Err(Store.refusal!(DbErr(why)))
		}
	} else {
		Err(BadRequest("Pick someone on the team."))
	}
