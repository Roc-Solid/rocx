import pf.Server
import pf.Endpoint
import ../../../../Board
import ../../../../Middlewares
import ../../../../News
import ../../../../Store

middleware = Middlewares.writer

## POST /b/<board>/columns (`name`): a new column, after the last.
post! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member, body : { name : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	match Board.column_name_of(body.name) {
		Err(why) => Err(BadRequest(why))
		Ok(name) =>
			match Store.add_column!(params.board, name) {
				Ok({}) => {
					News.tell!(params.board, context.me, "added the column ${name}")
					Ok("added")
				}
				Err(problem) => Err(Store.refused!(problem))
			}
	}
