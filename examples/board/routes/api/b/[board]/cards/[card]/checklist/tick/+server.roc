import pf.Server
import pf.Endpoint
import ../../../../../../../../Board
import ../../../../../../../../Lease
import ../../../../../../../../Middlewares
import ../../../../../../../../News
import ../../../../../../../../Store

middleware = Middlewares.writer

## POST /api/b/<board>/cards/<card>/checklist/tick (`item`, `done`: `"true"` or `"false"`): a line of
## the card's checklist ticked, or not.
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : Board.Tick } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	Lease.editable!(params.card, context.me)?
	match Store.tick_item!(params.board, params.card, body.item, body.done == "true") {
		Ok({}) => {
			News.tell!(params.board, context.me, "")
			Ok("ticked")
		}
		Err(problem) => Err(Store.refused!(problem))
	}
}
