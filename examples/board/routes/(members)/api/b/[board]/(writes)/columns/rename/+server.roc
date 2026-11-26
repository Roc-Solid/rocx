import pf.Server
import pf.Endpoint
import ../../../../../../../../Board
import ../../../../../../../../Middlewares
import ../../../../../../../../News
import ../../../../../../../../Store

## POST /api/b/<board>/columns/rename (`column`, `name`): a column called something else.
post! : { request : Server.Request, params : { board : Str }, context : Middlewares.Member, body : { column : Str, name : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }|
	match Board.column_name_of(body.name) {
		Err(why) => Err(BadRequest(why))
		Ok(name) =>
			match Store.rename_column!(params.board, body.column, name) {
				Ok(old) => {
					News.tell!(params.board, context.me, "renamed the column ${old} to ${name}")
					Ok("renamed")
				}
				Err(problem) => Err(Store.refused!(problem))
			}
	}
