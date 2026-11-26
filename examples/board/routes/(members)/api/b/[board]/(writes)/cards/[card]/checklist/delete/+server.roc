import pf.Server
import pf.Endpoint
import ../../../../../../../../../../Lease
import ../../../../../../../../../../Middlewares
import ../../../../../../../../../../News
import ../../../../../../../../../../Store

## POST /api/b/<board>/cards/<card>/checklist/delete (`item`): a line of the card's checklist gone.
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : { item : Str } } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	Lease.editable!(params.card, context.me)?
	match Store.delete_item!(params.board, params.card, body.item) {
		Ok({}) => {
			News.tell!(params.board, context.me, "")
			Ok("deleted")
		}
		Err(problem) => Err(Store.refused!(problem))
	}
}
