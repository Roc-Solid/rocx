import pf.Server
import pf.Endpoint
import ../../../Board
import ../../../Middlewares
import ../../../Store

## GET /api: who is asking, and every board: what the front page shows.
get! : { request : Server.Request, params : {}, context : Middlewares.Member } => Try({ me : Board.Person, boards : List(Board.Summary) }, Endpoint.Refusal)
get! = |{ context, .. }|
	match Store.boards!({}) {
		Ok(boards) => Ok({ me: context.me, boards })
		Err(problem) => Err(Store.refused!(problem))
	}

## POST /api, from the front page's form (`name`): a new board, with three columns, and on to it.
post! : { request : Server.Request, params : {}, context : Middlewares.Member, body : { name : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ body, .. }|
	match Board.board_name_of(body.name) {
		Err(why) => Err(BadRequest(why))
		Ok(name) => {
			slug = Board.slug_of(name)
			if slug.is_empty() {
				Err(BadRequest("A board's name needs a letter or a digit in it."))
			} else {
				match Store.create_board!(slug, name) {
					Ok({}) => Err(Answer(Server.redirect("/b/${slug}")))
					Err(Taken) => Err(Conflict("There is a board called that already."))
					Err(DbErr(why)) => Err(Store.refused!(DbErr(why)))
				}
			}
		}
	}
