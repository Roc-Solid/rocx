import pf.Server
import pf.Endpoint
import ../../../../../../../../../Board
import ../../../../../../../../../Lease
import ../../../../../../../../../Middlewares
import ../../../../../../../../../News
import ../../../../../../../../../Store

## POST /api/b/<board>/cards/<card>/labels (`label`, a key of `Board.labels`; `on`: `"true"` or
## `"false"`): the card with that label, or without it. It says which, rather than "the other way",
## so sending it twice is sending it once: a page shows it at once, before this answers.
post! : { request : Server.Request, params : { board : Str, card : Str }, context : Middlewares.Member, body : Board.LabelSet } => Try(Str, Endpoint.Refusal)
post! = |{ params, context, body, .. }| {
	Lease.editable!(params.card, context.me)?
	if !Board.labels.any(|label| label.key == body.label) {
		Err(BadRequest("There's no label called that."))
	} else {
		match Store.set_label!(params.board, params.card, body.label, body.on == "true") {
			Ok({}) => {
				News.tell!(params.board, context.me, "")
				Ok("labelled")
			}
			Err(problem) => Err(Store.refused!(problem))
		}
	}
}
