import pf.Server
import pf.Endpoint
import ../../../../../../Board
import ../../../../../../Lease
import ../../../../../../Middlewares
import ../../../../../../News
import ../../../../../../Store

middleware = Middlewares.writer

## POST /b/<board>/cards/<card>/checklist (`text`): a new line at the end of the card's checklist.
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : { text : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	Lease.editable!(params.card, context.me)?
	match Board.item_of(body.text) {
		Err(why) => Err(BadRequest(why))
		Ok(text) =>
			match Store.add_item!(params.board, params.card, text) {
				Ok({}) => {
					News.tell!(params.board, context.me, "")
					Ok("added")
				}
				Err(problem) => Err(Store.refused!(problem))
			}
	}
}
