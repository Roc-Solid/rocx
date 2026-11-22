import pf.Server
import pf.Endpoint
import ../../Board
import ../../Middlewares
import ../../Store

## GET /join: everyone who has joined, the joining page's quick picks.
get! : { request : Server.Request, params : {}, context : {} } => Try(List(Board.Person), Endpoint.Refusal)
get! = |_|
	match Store.people!({}) {
		Ok(people) => Ok(people)
		Err(DbErr(why)) => Err(Store.refused!(DbErr(why)))
		Err(BadRow(why)) => Err(Store.refused!(BadRow(why)))
	}

## POST /join, from the joining page (`name`, `color`, and `then`, where to go after): the cookie
## that says who you are, for a year, and on to `then`. A name someone has already is theirs: you
## are them now, in the colour you picked.
post! : { request : Server.Request, params : {}, context : {}, body : { name : Str, color : Str, then : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match Board.person_name_of(body.name) {
		Err(why) => Err(BadRequest(why))
		Ok(name) =>
			if !Board.colors.contains(body.color) {
				Err(BadRequest("Pick one of the colours."))
			} else {
				match Store.join!(name, body.color) {
					Ok(me) => {
						kept = { ..Server.cookie_defaults, max_age_s: 365 * 86_400 }
						Err(Answer(Server.set_cookie(Server.redirect(Board.after_join(body.then)), Middlewares.cookie, me.id, kept)))
					}
					Err(problem) => Err(Store.refused!(problem))
				}
			}
	}
