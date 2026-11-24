import pf.Server
import pf.Endpoint
import auth.Auth
import ../../Board
import ../../Store

## GET /join: everyone who has joined, the joining page's quick picks.
get! : { request : Server.Request, params : {}, context : {} } => Try(List(Board.Person), Endpoint.Refusal)
get! = |_|
	match Store.people!({}) {
		Ok(people) => Ok(people)
		Err(DbErr(why)) => Err(Store.refused!(DbErr(why)))
		Err(BadRow(why)) => Err(Store.refused!(BadRow(why)))
	}

## POST /join, from the joining page (`name`, `color`, and `then`, where to go after): you are that
## person now, and on to `then`. A name someone has already is theirs: you are them now, in the
## colour you picked. Who you are is a session (packages/auth): `Auth.sign_in!` starts one for the
## person and sets its cookie, `board_session`, which holds a random token (the person's id stays on
## the server). The session you had is ended first (`Auth.sign_out!`), so a browser has one.
post! : { request : Server.Request, params : {}, context : {}, body : { name : Str, color : Str, then : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ request, body, .. }|
	match Board.person_name_of(body.name) {
		Err(why) => Err(BadRequest(why))
		Ok(name) =>
			if !Board.colors.contains(body.color) {
				Err(BadRequest("Pick one of the colours."))
			} else {
				match Store.join!(name, body.color) {
					Ok(me) =>
						match Auth.sign_in!(Auth.sign_out!(request, Server.redirect(Board.after_join(body.then))), me.id) {
							Ok(answer) => Err(Answer(answer))
							Err(DbErr(why)) => Err(Store.refused!(DbErr(why)))
						}
					Err(problem) => Err(Store.refused!(problem))
				}
			}
	}
