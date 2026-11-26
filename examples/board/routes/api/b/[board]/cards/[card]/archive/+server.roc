import pf.Server
import pf.Endpoint
import ../../../../../../../Lease
import ../../../../../../../Middlewares
import ../../../../../../../News
import ../../../../../../../Store

middleware = Middlewares.writer

## POST /api/b/<board>/cards/<card>/archive (`archived`: `"true"` or `"false"`): the card off the board
## (kept, with its place in its column, in the board's archive), or back where it was.
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : { archived : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	Lease.editable!(params.card, context.me)?
	archived = body.archived == "true"
	match Store.card!(params.board, params.card) {
		Err(problem) => Err(Store.refused!(problem))
		Ok(card) =>
			match Store.set_archived!(params.board, params.card, archived) {
				Ok({}) => {
					News.tell!(params.board, context.me, if (archived) "archived “${card.title}”" else "brought back “${card.title}”")
					Ok(if (archived) "archived" else "restored")
				}
				Err(problem) => Err(Store.refused!(problem))
			}
	}
}
