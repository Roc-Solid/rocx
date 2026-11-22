import pf.Server
import pf.Endpoint
import ../../../../../../Lease
import ../../../../../../Middlewares
import ../../../../../../News
import ../../../../../../Store

middleware = Middlewares.writer

## POST /b/<board>/cards/<card>/delete: an archived card gone for good. A card on the board is
## archived first: two steps, so a slip of the hand loses nothing.
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : {} } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, .. }| {
	Lease.editable!(params.card, context.me)?
	match Store.card!(params.board, params.card) {
		Err(problem) => Err(Store.refused!(problem))
		Ok(card) if !card.archived => Err(Conflict("Archive a card before deleting it."))
		Ok(card) =>
			match Store.delete_card!(params.board, params.card) {
				Ok({}) => {
					News.tell!(params.board, context.me, "deleted “${card.title}”")
					Ok("deleted")
				}
				Err(problem) => Err(Store.refused!(problem))
			}
	}
}
