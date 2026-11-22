import pf.Server
import pf.Endpoint
import ../../../../Board
import ../../../../Middlewares
import ../../../../News
import ../../../../Store

middleware = Middlewares.writer

## POST /b/<board>/move: a card put in a column, before another card (`before`; `""`: at the end).
## The page sends it as it is dropped (`use_action!`), and shows it there before this answers. Its
## rank is worked out here, from the board as it is now (`Store.move!`): a card dropped before one
## that someone else has just moved away goes to the end of the column instead.
post! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member, body : Board.Move } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	if body.card == body.before {
		Err(BadRequest("A card can't go before itself."))
	} else {
		match Store.move!(params.board, body) {
			Ok(moved) => {
				News.tell!(params.board, context.me, "moved “${moved.title}” to ${moved.column}")
				Ok("moved")
			}
			Err(problem) => Err(Store.refused!(problem))
		}
	}
