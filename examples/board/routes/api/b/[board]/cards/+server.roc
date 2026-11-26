import pf.Server
import pf.Endpoint
import ../../../../../Board
import ../../../../../Middlewares
import ../../../../../News
import ../../../../../Store

middleware = Middlewares.writer

## POST /api/b/<board>/cards (`column`, `title`): a new card at the end of a column.
post! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member, body : { column : Str, title : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	match Board.title_of(body.title) {
		Err(why) => Err(BadRequest(why))
		Ok(title) =>
			match Store.add_card!(params.board, body.column, title) {
				Ok(column) => {
					News.tell!(params.board, context.me, "added “${title}” to ${column}")
					Ok("added")
				}
				Err(problem) => Err(Store.refused!(problem))
			}
	}
